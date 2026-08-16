import Foundation

//===----------------------------------------------------------------------===//
//  MacroCompatLayer.swift
//  Tessera Studio
//
//  P2-D item 2.13: parse + preserve + agent-assisted rewrite. NEVER
//  execute - a hard line, not a scope note. Nothing in this file (or
//  anywhere in this track) runs a macro; there is no `macro_run` tool at
//  any tier, ever (testing-doctrine.md rule 5 pins this as a trap test).
//
//  Four-step pipeline over an already-preserved `vbaProject.bin`:
//   (a) confirm the preserved bytes are present (`preservedVBAProjectBytes`)
//   (b) OVBADecompressor over each module's compressed source
//   (c) VBAOutlineParser over each decompressed module
//   (d) translate(_:) -> TranslatedMacroPlaybook (a STORED playbook
//       artifact per the architect's ratified decision - studio-
//       expansion-plan.md section 8 row 16 - not a one-shot chat plan)
//
//  Steps (a)-(c) need to get from "raw vbaProject.bin bytes" to "per-
//  module decompressed source text", which the design contract's own
//  text glosses over as "OVBADecompressor over each module stream" as
//  though the module streams arrive pre-separated. In the real format
//  they do not: `vbaProject.bin` is an OLE/CFBF compound file ([MS-CFB]),
//  and each module's own stream additionally carries an opaque
//  `PerformanceCache` prefix (compiled p-code, NOT MS-OVBA data) before
//  the actual `CompressedContainer` begins - the real boundary is only
//  recorded in the `dir` stream's `MODULEOFFSET` record ([MS-OVBA]
//  2.3.4.2), a second compressed record format this track's file list
//  has no room for and whose exact tag bytes this agent does not have
//  high-confidence recall of (unlike the CFBF container format itself,
//  which is used far more broadly and is implemented here). Rather than
//  risk silently-wrong offsets from misremembered tag constants, this
//  file locates each module's `CompressedContainer` by scanning for the
//  `0x01` signature byte followed by a structurally valid chunk header
//  AND confirming the remainder actually decompresses without error -
//  see `decompressedSourceText(fromModuleStream:)`. This is a deliberate
//  design judgment call, recorded in this wave's findings file for
//  architect ratification; full `dir`-stream `MODULEOFFSET` parsing is
//  the named follow-up for byte-exact fidelity.
//===----------------------------------------------------------------------===//

// MARK: - MacroHostKind

/// Which OOXML host document a `vbaProject.bin` was preserved from - the
/// package-relative preserved-part key differs per host (`PreservedParts`'s
/// own doc comment: `"word/vbaProject.bin"`, and this type's own `xl:`/
/// `ppt:` siblings). This wave's landed infrastructure (`Doc.preservedParts`,
/// `DocReceiptType.translateMacro`) only reaches `.word` end to end - see
/// this wave's findings file for the `.excel`/`.powerpoint` gap (no
/// `Sheet.preservedParts`/`SlideDeck.preservedParts` field exists yet).
/// The pure pipeline below is host-agnostic regardless: any of the three
/// works once given the right `PreservedParts` bag.
public enum MacroHostKind: String, Codable, Sendable, CaseIterable {
    case word
    case excel
    case powerpoint

    /// The exact OOXML package-relative path this host stores its VBA
    /// project binary under - real Office package paths, not an invented
    /// naming scheme, so a preserved part round-trips byte-for-byte back
    /// to the SAME zip entry name it was read from.
    public var preservedPartKey: String {
        switch self {
        case .word: return "word/vbaProject.bin"
        case .excel: return "xl/vbaProject.bin"
        case .powerpoint: return "ppt/vbaProject.bin"
        }
    }
}

// MARK: - TranslatedMacroPlaybook

/// The stored playbook artifact `MacroCompatLayer.translate` produces for
/// one VBA module - per the architect's ratified decision (studio-
/// expansion-plan.md section 8 row 16: "stored playbook for
/// `macro_translate`", superseding this item's own SOTA-report "open
/// question for architect"). No existing "self-improving learning loop"
/// playbook shape fits here: `TesseraReasoningPlaybookStore` (grep hit for
/// "Playbook" in `Sources/TesseraCore`) is a GLOBAL, file-backed
/// `[problemClass: [strategy]]` store with no per-entity identity and no
/// receipt - the wrong shape for a per-Doc, per-module, receipted
/// artifact. This is the minimal value type the design contract's own
/// fallback names: `sourceModuleName`, `humanSummary`,
/// `suggestedToolCalls: [String]` (tool names/args this macro's outline
/// suggests, NEVER executed - just suggested), plus `calledAPIs` carried
/// through so the stored artifact is self-contained (a reader doesn't
/// need the original outline to see why a suggestion was made).
///
/// Deliberately has no timestamp of its own: this is a pure, deterministic
/// value (same outline in, same playbook out) - whatever wraps it for
/// storage (see this wave's wiringNotes) stamps `Doc.updatedAt` the same
/// way every other DocStore mutation already does, rather than this type
/// reading the wall clock itself.
public struct TranslatedMacroPlaybook: Codable, Sendable, Hashable {
    public var sourceModuleName: String
    public var humanSummary: String
    public var suggestedToolCalls: [String]
    public var calledAPIs: [String]

    public init(
        sourceModuleName: String,
        humanSummary: String,
        suggestedToolCalls: [String],
        calledAPIs: [String]
    ) {
        self.sourceModuleName = sourceModuleName
        self.humanSummary = humanSummary
        self.suggestedToolCalls = suggestedToolCalls
        self.calledAPIs = calledAPIs
    }
}

// MARK: - MacroCompatLayerError

public enum MacroCompatLayerError: Error, Equatable, Sendable {
    /// Step (a): the doc has no preserved bytes under the expected key.
    case noPreservedVBAProject(key: String)
    /// Step (b)/(c): the OLE compound file parsed, but no stream under
    /// its `VBA` storage decompressed into a plausible module.
    case noExtractableModules
    case cfbf(CFBFReaderError)
}

// MARK: - MacroCompatLayer

public enum MacroCompatLayer {

    // MARK: Step (a): locate the preserved bytes

    /// Confirms/extracts the preserved `vbaProject.bin` bytes for a given
    /// host kind. Throws rather than returning `nil` - "confirm... are
    /// present" is the step's own job, so an absent part is this step's
    /// own failure mode, not a downstream one.
    public static func preservedVBAProjectBytes(
        in preservedParts: PreservedParts?,
        hostKind: MacroHostKind
    ) throws -> Data {
        let key = hostKind.preservedPartKey
        guard let parts = preservedParts, let data = parts[key], !data.isEmpty else {
            throw MacroCompatLayerError.noPreservedVBAProject(key: key)
        }
        return data
    }

    // MARK: Steps (a)-(c) combined: preserved bytes -> outlines

    /// Runs steps (b) and (c) over every module stream found in a raw
    /// `vbaProject.bin` blob: CFBF-extracts the `VBA` storage's streams,
    /// decompresses each candidate module's source (see the file header
    /// for the signature-scan boundary-detection rationale), then runs
    /// the light outline parse. Streams that are not plausible module
    /// streams (`dir`, `_VBA_PROJECT`, `__SRP_*` caches) are skipped, not
    /// reported as errors - their absence from the result is the
    /// expected, correct outcome. Throws only when NO module could be
    /// extracted at all.
    public static func moduleOutlines(fromVBAProjectBin data: Data) throws -> [VBAModuleOutline] {
        let streams: [String: Data]
        do {
            streams = try CFBFReader.streams(in: data, underStorage: "VBA")
        } catch let error as CFBFReaderError {
            throw MacroCompatLayerError.cfbf(error)
        }

        var outlines: [VBAModuleOutline] = []
        for streamName in streams.keys.sorted() {
            guard Self.isModuleStream(named: streamName) else { continue }
            guard let streamData = streams[streamName],
                  let sourceText = Self.decompressedSourceText(fromModuleStream: streamData) else { continue }
            outlines.append(VBAOutlineParser.parse(source: sourceText, fallbackModuleName: streamName))
        }
        guard !outlines.isEmpty else { throw MacroCompatLayerError.noExtractableModules }
        return outlines
    }

    /// Stream names inside the `VBA` storage that are project metadata,
    /// never a code module: `dir` (the module directory record stream),
    /// `_VBA_PROJECT` (a binary VBE-version marker), and `__SRP_n`
    /// (compiler cache streams VBE regenerates on open).
    static func isModuleStream(named name: String) -> Bool {
        if name == "dir" || name == "_VBA_PROJECT" { return false }
        if name.hasPrefix("__SRP_") { return false }
        return true
    }

    /// Locates and decompresses the `CompressedContainer` embedded in a
    /// raw module stream (see file header: signature-scan, not a `dir`-
    /// stream `MODULEOFFSET` lookup). Returns `nil` - not a throw - when
    /// no valid container could be found; the caller treats that stream
    /// as unextractable and moves on rather than failing the whole batch.
    static func decompressedSourceText(fromModuleStream streamBytes: Data) -> String? {
        let bytes = [UInt8](streamBytes)
        var searchStart = 0
        while searchStart < bytes.count {
            guard let signatureIndex = bytes[searchStart...].firstIndex(of: 0x01) else { return nil }
            if let text = Self.tryDecompress(bytes: bytes, from: signatureIndex) {
                return text
            }
            searchStart = signatureIndex + 1
        }
        return nil
    }

    private static func tryDecompress(bytes: [UInt8], from offset: Int) -> String? {
        guard offset + 3 <= bytes.count else { return nil }
        let header = UInt16(bytes[offset + 1]) | (UInt16(bytes[offset + 2]) << 8)
        let chunkSignature = UInt8((header >> 12) & 0x7)
        guard chunkSignature == 0b011 else { return nil }
        guard let decompressed = try? OVBADecompressor.decompress(Data(bytes[offset...])) else { return nil }
        guard !decompressed.isEmpty else { return nil }
        return String(decoding: decompressed, as: UTF8.self)
    }

    // MARK: Step (d): translate

    /// Produces the stored playbook artifact for one module's outline.
    /// Deterministic and pure - no wall clock, no randomness - so the
    /// same outline always yields byte-identical output (round-trip
    /// identity, testing-doctrine.md rule 2).
    public static func translate(_ outline: VBAModuleOutline) -> TranslatedMacroPlaybook {
        TranslatedMacroPlaybook(
            sourceModuleName: outline.moduleName,
            humanSummary: Self.humanSummary(for: outline),
            suggestedToolCalls: Self.suggestedToolCalls(for: outline),
            calledAPIs: outline.calledAPIs
        )
    }

    public static func translate(_ outlines: [VBAModuleOutline]) -> [TranslatedMacroPlaybook] {
        outlines.map(Self.translate)
    }

    private static func humanSummary(for outline: VBAModuleOutline) -> String {
        var parts: [String] = []
        if let docComment = outline.docComment, !docComment.isEmpty {
            parts.append(docComment)
        }
        if outline.subroutines.isEmpty {
            parts.append("Module '\(outline.moduleName)' declares no recognizable Sub/Function routines.")
        } else {
            let signatures = outline.subroutines.map { routine -> String in
                let paramList = routine.parameters.joined(separator: ", ")
                let returnClause = routine.returnType.map { " As \($0)" } ?? ""
                return "\(routine.kind.rawValue) \(routine.name)(\(paramList))\(returnClause)"
            }
            parts.append("Module '\(outline.moduleName)' declares \(outline.subroutines.count) routine(s): \(signatures.joined(separator: "; ")).")
        }
        if !outline.calledAPIs.isEmpty {
            parts.append("Calls: \(outline.calledAPIs.joined(separator: ", ")).")
        }
        parts.append("Parsed and translated only - this macro was never executed.")
        return parts.joined(separator: " ")
    }

    /// Fixed, documented heuristic mapping from a called-API pattern to a
    /// migration note - NOT an executable plan, and NOT a claim that
    /// Tessera has a tool for any of these; every entry is a manual-
    /// review pointer, matching ONLYOFFICE/Google's own "user validates"
    /// framing for their VBA converters (this item's own SOTA evidence).
    static let calledAPIGuidance: [String: String] = [
        "Shell": "process execution (Shell) has no Tessera agent tool equivalent - review manually",
        "ShellExecute": "process execution (ShellExecute) has no Tessera agent tool equivalent - review manually",
        "WinExec": "process execution (WinExec) has no Tessera agent tool equivalent - review manually",
        "CreateObject": "COM automation (CreateObject) - if the target is Word/Excel/PowerPoint, use the matching doc_*/sheet_*/slide_* tool surface instead",
        "GetObject": "COM automation (GetObject) - if the target is Word/Excel/PowerPoint, use the matching doc_*/sheet_*/slide_* tool surface instead",
        "Environ": "environment variable access (Environ) has no Tessera agent tool equivalent - review manually",
        "Kill": "filesystem delete (Kill) has no Tessera agent tool equivalent - review manually",
        "FileCopy": "filesystem copy (FileCopy) has no Tessera agent tool equivalent - review manually",
        "URLDownloadToFile": "network fetch (URLDownloadToFile) has no Tessera agent tool equivalent - review manually",
        "SendKeys": "UI automation (SendKeys) has no Tessera agent tool equivalent - identify the actual goal and use a direct tool call instead",
        "RegRead": "Windows registry access (RegRead) has no Tessera agent tool equivalent - likely drop on migration",
        "RegWrite": "Windows registry access (RegWrite) has no Tessera agent tool equivalent - likely drop on migration",
        "RegDelete": "Windows registry access (RegDelete) has no Tessera agent tool equivalent - likely drop on migration",
        "Declare ... Lib (Win32 API)": "raw Win32 API declaration - almost certainly has no Tessera agent tool equivalent, flag for manual rewrite",
    ]

    private static func suggestedToolCalls(for outline: VBAModuleOutline) -> [String] {
        var suggestions: [String] = []
        for api in outline.calledAPIs {
            if let guidance = calledAPIGuidance[api] {
                suggestions.append(guidance)
            }
        }
        if suggestions.isEmpty {
            suggestions.append("no recognized automation APIs found - this module's routines are likely safe to review and rewrite by hand as direct doc_*/sheet_*/slide_* tool calls")
        }
        return suggestions
    }
}

// MARK: - CFBFReaderError

/// Thrown by ``CFBFReader`` when a blob does not conform to the
/// [MS-CFB] Compound File Binary Format, or uses a feature this minimal,
/// read-only reader does not implement.
public enum CFBFReaderError: Error, Equatable, Sendable {
    case notACompoundFile
    case unsupportedVersion(major: UInt16)
    case unsupportedSectorShift(UInt16)
    /// More than 109 FAT sectors: the file's FAT sector list would need
    /// the DIFAT sector CHAIN (header holds only the first 109 entries
    /// inline). Every real `vbaProject.bin` (tens of KB) fits well under
    /// this; a file that doesn't is refused rather than silently
    /// truncated.
    case tooManyFATSectors
    case corrupt(String)
    case storageNotFound(String)
}

// MARK: - CFBFReader

/// A minimal, read-only [MS-CFB] Compound File Binary reader: enough to
/// extract every stream directly under a named top-level storage (e.g.
/// `"VBA"`) from a `vbaProject.bin` blob. NOT a general-purpose OLE
/// library - no write support, no DIFAT sector chain (see
/// `CFBFReaderError.tooManyFATSectors`), no CLSID/timestamp surfacing.
/// Every malformed-input path throws rather than trapping.
enum CFBFReader {
    private static let endOfChain: UInt32 = 0xFFFFFFFE
    private static let freeSect: UInt32 = 0xFFFFFFFF
    private static let noStream: UInt32 = 0xFFFFFFFF
    private static let headerSize = 512
    private static let direntrySize = 128

    private struct Header {
        var sectorSize: Int
        var miniSectorSize: Int
        var numFATSectors: Int
        var firstDirSector: UInt32
        var miniStreamCutoff: Int
        var firstMiniFATSector: UInt32
        var numMiniFATSectors: Int
        var difat: [UInt32]
    }

    private struct DirEntry {
        var name: String
        var objectType: UInt8
        var leftSibling: UInt32
        var rightSibling: UInt32
        var child: UInt32
        var startingSector: UInt32
        var streamSize: Int
    }

    /// Extracts every STREAM entry directly under `storageName` (a
    /// top-level child of the root storage), keyed by the stream's own
    /// short name (not a full "Storage/Name" path - callers of this
    /// reader only ever need one storage's worth of children).
    static func streams(in data: Data, underStorage storageName: String) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw CFBFReaderError.notACompoundFile }
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard Array(bytes[0..<8]) == signature else { throw CFBFReaderError.notACompoundFile }

        let header = try Self.parseHeader(bytes)
        let sectorSize = header.sectorSize

        func regularSector(_ index: Int) throws -> Data {
            let byteOffset = sectorSize * (index + 1)
            guard byteOffset >= 0, byteOffset + sectorSize <= bytes.count else {
                throw CFBFReaderError.corrupt("sector \(index) out of range")
            }
            return Data(bytes[byteOffset..<(byteOffset + sectorSize)])
        }

        // Regular FAT: the header's DIFAT lists FAT sector indices directly.
        var fatBytes = Data()
        for sectorIndex in header.difat where sectorIndex != freeSect {
            fatBytes.append(try regularSector(Int(sectorIndex)))
        }
        let fat = Self.parseUInt32Array(fatBytes)

        func readChainToEnd(startSector: UInt32, using table: [UInt32], sectorReader: (Int) throws -> Data) throws -> Data {
            guard startSector != noStream, startSector != endOfChain else { return Data() }
            var result = Data()
            var sector = startSector
            var guardCount = 0
            while sector != endOfChain {
                guardCount += 1
                guard guardCount <= table.count + 1 else { throw CFBFReaderError.corrupt("sector chain cycle") }
                guard Int(sector) < table.count else { throw CFBFReaderError.corrupt("sector \(sector) outside FAT") }
                result.append(try sectorReader(Int(sector)))
                sector = table[Int(sector)]
            }
            return result
        }

        // Directory stream: fixed-size (128-byte) entries, chain length
        // determined purely by ENDOFCHAIN (v3 files leave the header's
        // own "number of directory sectors" field unused).
        let directoryBytes = try readChainToEnd(startSector: header.firstDirSector, using: fat, sectorReader: regularSector)
        guard !directoryBytes.isEmpty, directoryBytes.count % direntrySize == 0 else {
            throw CFBFReaderError.corrupt("empty or misaligned directory stream")
        }
        let directoryEntryBytes = [UInt8](directoryBytes)
        let entryCount = directoryEntryBytes.count / direntrySize
        var entries: [DirEntry] = []
        entries.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            entries.append(try Self.parseDirEntry(directoryEntryBytes, at: i * direntrySize))
        }

        guard let rootIndex = entries.firstIndex(where: { $0.objectType == 5 }) else {
            throw CFBFReaderError.corrupt("no root storage entry")
        }
        let root = entries[rootIndex]

        // Mini FAT + mini stream (the root entry's own regular-FAT stream).
        let miniStreamBytes = try readChainToEnd(startSector: root.startingSector, using: fat, sectorReader: regularSector)
        let miniFATBytes = try readChainToEnd(startSector: header.firstMiniFATSector, using: fat, sectorReader: regularSector)
        let miniFAT = Self.parseUInt32Array(miniFATBytes)
        let miniSectorSize = header.miniSectorSize

        func miniSector(_ index: Int) throws -> Data {
            let byteOffset = miniSectorSize * index
            guard byteOffset >= 0, byteOffset + miniSectorSize <= miniStreamBytes.count else {
                throw CFBFReaderError.corrupt("mini sector \(index) out of range")
            }
            return miniStreamBytes.subdata(in: byteOffset..<(byteOffset + miniSectorSize))
        }

        func siblings(of id: UInt32, into result: inout [DirEntry]) throws {
            guard id != noStream else { return }
            guard Int(id) < entries.count else { throw CFBFReaderError.corrupt("dangling sibling id \(id)") }
            let entry = entries[Int(id)]
            try siblings(of: entry.leftSibling, into: &result)
            result.append(entry)
            try siblings(of: entry.rightSibling, into: &result)
        }

        var rootChildren: [DirEntry] = []
        try siblings(of: root.child, into: &rootChildren)
        guard let storageEntry = rootChildren.first(where: { $0.objectType == 1 && $0.name.caseInsensitiveCompare(storageName) == .orderedSame }) else {
            throw CFBFReaderError.storageNotFound(storageName)
        }

        var storageChildren: [DirEntry] = []
        try siblings(of: storageEntry.child, into: &storageChildren)

        var result: [String: Data] = [:]
        for entry in storageChildren where entry.objectType == 2 {
            if entry.streamSize == 0 {
                result[entry.name] = Data()
                continue
            }
            let content: Data
            if entry.streamSize < header.miniStreamCutoff {
                content = try readChainToEnd(startSector: entry.startingSector, using: miniFAT, sectorReader: miniSector)
            } else {
                content = try readChainToEnd(startSector: entry.startingSector, using: fat, sectorReader: regularSector)
            }
            guard content.count >= entry.streamSize else {
                throw CFBFReaderError.corrupt("stream '\(entry.name)' shorter than its declared size")
            }
            result[entry.name] = content.prefix(entry.streamSize)
        }
        return result
    }

    // MARK: - Header

    private static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        let majorVersion = Self.u16(bytes, 26)
        guard majorVersion == 3 || majorVersion == 4 else {
            throw CFBFReaderError.unsupportedVersion(major: majorVersion)
        }
        let sectorShift = Self.u16(bytes, 30)
        guard sectorShift == 9 || sectorShift == 12 else {
            throw CFBFReaderError.unsupportedSectorShift(sectorShift)
        }
        let miniSectorShift = Self.u16(bytes, 32)
        let numFATSectors = Int(Self.u32(bytes, 44))
        guard numFATSectors <= 109 else { throw CFBFReaderError.tooManyFATSectors }
        let firstDirSector = Self.u32(bytes, 48)
        let miniStreamCutoff = Int(Self.u32(bytes, 56))
        let firstMiniFATSector = Self.u32(bytes, 60)
        let numMiniFATSectors = Int(Self.u32(bytes, 64))

        var difat: [UInt32] = []
        difat.reserveCapacity(numFATSectors)
        for i in 0..<numFATSectors {
            let value = Self.u32(bytes, 76 + i * 4)
            guard value != freeSect else { continue }
            difat.append(value)
        }

        return Header(
            sectorSize: 1 << Int(sectorShift),
            miniSectorSize: 1 << Int(miniSectorShift),
            numFATSectors: numFATSectors,
            firstDirSector: firstDirSector,
            miniStreamCutoff: miniStreamCutoff,
            firstMiniFATSector: firstMiniFATSector,
            numMiniFATSectors: numMiniFATSectors,
            difat: difat
        )
    }

    // MARK: - Directory entry

    private static func parseDirEntry(_ bytes: [UInt8], at base: Int) throws -> DirEntry {
        guard base + direntrySize <= bytes.count else {
            throw CFBFReaderError.corrupt("directory entry out of range")
        }
        let nameLengthBytes = Int(Self.u16(bytes, base + 64))
        // nameLengthBytes counts the trailing UTF-16 NUL; a length of 0
        // means an unused/empty slot.
        let nameCharCount = max(0, nameLengthBytes / 2 - (nameLengthBytes > 0 ? 1 : 0))
        var nameUnits: [UInt16] = []
        nameUnits.reserveCapacity(nameCharCount)
        for i in 0..<nameCharCount {
            nameUnits.append(Self.u16(bytes, base + i * 2))
        }
        let name = String(decoding: nameUnits, as: UTF16.self)
        let objectType = bytes[base + 66]
        let leftSibling = Self.u32(bytes, base + 68)
        let rightSibling = Self.u32(bytes, base + 72)
        let child = Self.u32(bytes, base + 76)
        let startingSector = Self.u32(bytes, base + 116)
        let sizeLow = Self.u32(bytes, base + 120)
        return DirEntry(
            name: name,
            objectType: objectType,
            leftSibling: leftSibling,
            rightSibling: rightSibling,
            child: child,
            startingSector: startingSector,
            streamSize: Int(sizeLow)
        )
    }

    // MARK: - Byte helpers

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func parseUInt32Array(_ data: Data) -> [UInt32] {
        let bytes = [UInt8](data)
        let count = bytes.count / 4
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(Self.u32(bytes, i * 4))
        }
        return result
    }
}
