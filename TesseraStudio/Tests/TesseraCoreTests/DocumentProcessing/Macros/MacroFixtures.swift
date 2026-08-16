import Foundation
@testable import TesseraCore

// MARK: - MacroFixtures
//
// TEST-ONLY fixture builders shared by OVBADecompressorTests,
// VBAOutlineParserTests, and MacroCompatLayerTests. NONE of this is
// extracted from a real Microsoft-produced file - this agent had no
// reference access to a real `vbaProject.bin` sample. Every byte these
// functions produce is hand-written against the public [MS-OVBA] /
// [MS-CFB] specifications (a documented, honest provenance choice per
// this wave's item 5 instruction: "document your test vector's
// provenance honestly - hand-constructed vs a real MS-OVBA sample").
//
// `makeLiteralOnlyOVBAContainer` and `makeMinimalVBAProjectBin` were
// developed and round-trip-verified against this track's own
// `OVBADecompressor`/`CFBFReader` implementation via a standalone
// `swiftc`-compiled script in the scratchpad (not `swift build`/`swift
// test` - a throwaway multi-file compile outside the shared package),
// exercising: literal-only + multi-chunk containers, a hand-worked
// copy-token example, 1/2/3-module CFBF fixtures (crossing the 4-
// entries-per-directory-sector boundary), and a >4096-byte module that
// forces the regular-FAT stream path rather than the mini-stream path.
// That script is not part of this PR; these functions are its
// production-bound output.

/// TEST-ONLY: encodes `plaintext` as a spec-compliant [MS-OVBA]
/// `CompressedContainer` (2.4.1) using ONLY literal tokens (every flag
/// bit 0) - a legal, degenerate encoding (compression is not mandatory
/// token-by-token). Chunked at 3000 source bytes per chunk rather than
/// the spec's 4096 decompressed-byte chunk size: an all-literal encoding
/// carries one flag byte per 8 literal bytes, so a full 4096-byte chunk
/// would need 4096 + 512 = 4608 on-wire bytes, overflowing the 12-bit
/// `CompressedChunkSize` field (max representable value 4095) - a real
/// encoder sidesteps this by using SOME copy tokens (or the separate
/// "raw chunk" flag) once literal-only stops fitting; this fixture
/// builder only ever needs literal tokens, so it just chunks smaller.
func makeLiteralOnlyOVBAContainer(_ plaintext: Data) -> Data {
    precondition(!plaintext.isEmpty, "use a dedicated hand-built fixture for the empty-container case")
    var result = Data([0x01])
    let bytes = [UInt8](plaintext)
    var chunkStart = 0
    let maxPerChunk = 3000
    while chunkStart < bytes.count {
        let chunkEnd = min(chunkStart + maxPerChunk, bytes.count)
        let chunkBytes = Array(bytes[chunkStart..<chunkEnd])
        var tokenData = Data()
        var i = 0
        while i < chunkBytes.count {
            let groupEnd = min(i + 8, chunkBytes.count)
            tokenData.append(0x00)
            tokenData.append(contentsOf: chunkBytes[i..<groupEnd])
            i = groupEnd
        }
        let sizeField = UInt16(tokenData.count - 1)
        let header: UInt16 = 0x8000 | (0b011 << 12) | sizeField
        result.append(UInt8(header & 0xFF))
        result.append(UInt8((header >> 8) & 0xFF))
        result.append(tokenData)
        chunkStart = chunkEnd
    }
    return result
}

/// TEST-ONLY: one module's worth of input to `makeMinimalVBAProjectBin`.
/// `prefixGarbage` stands in for the real format's opaque
/// `PerformanceCache` bytes that precede a module's actual
/// `CompressedContainer` in a real `vbaProject.bin` (see
/// `MacroCompatLayer.swift`'s file-header doc comment) - non-default so
/// every fixture exercises `decompressedSourceText`'s signature-scan
/// boundary detection, not just the zero-offset case.
struct MacroFixtureModule {
    var streamName: String
    var sourceText: String
    var prefixGarbage: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
}

private func fixtureU16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

private func fixtureU32LE(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

/// TEST-ONLY: builds a minimal, spec-valid [MS-CFB] compound file
/// containing a `VBA` storage with one stream per `modules` entry, each
/// holding `prefixGarbage + makeLiteralOnlyOVBAContainer(sourceText)`.
/// Handles BOTH real CFBF branches a `vbaProject.bin` reader must
/// support: modules under the 4096-byte mini-stream cutoff go through
/// the mini-stream/mini-FAT path, modules at or above it get their own
/// regular-sector chain - `CFBFReader` picks the branch per module from
/// the directory entry's own declared `streamSize`, exactly as the real
/// format requires.
func makeMinimalVBAProjectBin(modules: [MacroFixtureModule]) -> Data {
    let endOfChain: UInt32 = 0xFFFFFFFE
    let freeSect: UInt32 = 0xFFFFFFFF
    let noStream: UInt32 = 0xFFFFFFFF
    let sectorSize = 512
    let miniSectorSize = 64
    let miniStreamCutoff = 4096

    var moduleContents: [Data] = []
    for m in modules {
        let compressed = makeLiteralOnlyOVBAContainer(Data(m.sourceText.utf8))
        moduleContents.append(m.prefixGarbage + compressed)
    }

    var smallIndices: [Int] = []
    var largeIndices: [Int] = []
    for (i, content) in moduleContents.enumerated() {
        if content.count < miniStreamCutoff { smallIndices.append(i) } else { largeIndices.append(i) }
    }

    var miniStreamBlob = Data()
    var moduleStartSector = [Int](repeating: 0, count: moduleContents.count)
    for i in smallIndices {
        let content = moduleContents[i]
        let start = miniStreamBlob.count / miniSectorSize
        moduleStartSector[i] = start
        miniStreamBlob.append(content)
        let pad = (miniSectorSize - (content.count % miniSectorSize)) % miniSectorSize
        miniStreamBlob.append(Data(repeating: 0, count: pad))
    }
    let totalMiniSectors = miniStreamBlob.count / miniSectorSize

    var miniFAT = [UInt32](repeating: freeSect, count: totalMiniSectors)
    var idx = 0
    for i in smallIndices {
        let content = moduleContents[i]
        let paddedLen = ((content.count + miniSectorSize - 1) / miniSectorSize) * miniSectorSize
        let k = paddedLen / miniSectorSize
        for j in 0..<k {
            miniFAT[idx + j] = (j == k - 1) ? endOfChain : UInt32(idx + j + 1)
        }
        idx += k
    }

    let moduleCount = modules.count
    let entryCount = 2 + moduleCount
    let dirSectorCount = (entryCount + 3) / 4

    var nextSector = 0
    let fatSector = nextSector; nextSector += 1
    let firstDirSector = nextSector; nextSector += dirSectorCount
    let miniStreamSectorCount = miniStreamBlob.isEmpty ? 0 : (miniStreamBlob.count + sectorSize - 1) / sectorSize
    let firstMiniStreamSector = nextSector; nextSector += miniStreamSectorCount
    let miniFATByteCount = miniFAT.count * 4
    let miniFATSectorCount = miniFATByteCount == 0 ? 0 : (miniFATByteCount + sectorSize - 1) / sectorSize
    let firstMiniFATSector = nextSector; nextSector += miniFATSectorCount

    var largeModuleFirstSector: [Int: Int] = [:]
    var largeModuleSectorCount: [Int: Int] = [:]
    for i in largeIndices {
        let content = moduleContents[i]
        let sectorCount = (content.count + sectorSize - 1) / sectorSize
        largeModuleFirstSector[i] = nextSector
        largeModuleSectorCount[i] = sectorCount
        moduleStartSector[i] = nextSector
        nextSector += sectorCount
    }
    let totalSectors = nextSector

    var fat = [UInt32](repeating: freeSect, count: totalSectors)
    fat[fatSector] = 0xFFFFFFFD // FATSECT
    for i in 0..<dirSectorCount {
        let s = firstDirSector + i
        fat[s] = (i == dirSectorCount - 1) ? endOfChain : UInt32(s + 1)
    }
    for i in 0..<miniStreamSectorCount {
        let s = firstMiniStreamSector + i
        fat[s] = (i == miniStreamSectorCount - 1) ? endOfChain : UInt32(s + 1)
    }
    for i in 0..<miniFATSectorCount {
        let s = firstMiniFATSector + i
        fat[s] = (i == miniFATSectorCount - 1) ? endOfChain : UInt32(s + 1)
    }
    for i in largeIndices {
        let start = largeModuleFirstSector[i]!
        let count = largeModuleSectorCount[i]!
        for j in 0..<count {
            let s = start + j
            fat[s] = (j == count - 1) ? endOfChain : UInt32(s + 1)
        }
    }

    func nameBytes(_ name: String, slotSize: Int) -> [UInt8] {
        var units = Array(name.utf16)
        units.append(0)
        var bytes: [UInt8] = []
        for u in units { bytes.append(contentsOf: fixtureU16LE(u)) }
        while bytes.count < slotSize { bytes.append(0) }
        return Array(bytes.prefix(slotSize))
    }

    func direntryBytes(name: String, objectType: UInt8, left: UInt32, right: UInt32, child: UInt32, startSector: UInt32, streamSize: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 128)
        let nameLenBytes = UInt16((name.utf16.count + 1) * 2)
        let nb = nameBytes(name, slotSize: 64)
        for i in 0..<64 { b[i] = nb[i] }
        let ln = fixtureU16LE(nameLenBytes)
        b[64] = ln[0]; b[65] = ln[1]
        b[66] = objectType
        b[67] = 1
        let l = fixtureU32LE(left); for i in 0..<4 { b[68 + i] = l[i] }
        let r = fixtureU32LE(right); for i in 0..<4 { b[72 + i] = r[i] }
        let c = fixtureU32LE(child); for i in 0..<4 { b[76 + i] = c[i] }
        let ss = fixtureU32LE(startSector); for i in 0..<4 { b[116 + i] = ss[i] }
        let sz = fixtureU32LE(UInt32(streamSize)); for i in 0..<4 { b[120 + i] = sz[i] }
        return b
    }

    var directoryBytes: [UInt8] = []
    directoryBytes.append(contentsOf: direntryBytes(
        name: "Root Entry", objectType: 5, left: noStream, right: noStream, child: 1,
        startSector: UInt32(firstMiniStreamSector), streamSize: miniStreamBlob.count
    ))
    directoryBytes.append(contentsOf: direntryBytes(
        name: "VBA", objectType: 1, left: noStream, right: noStream, child: moduleCount > 0 ? 2 : noStream,
        startSector: noStream, streamSize: 0
    ))
    for (i, m) in modules.enumerated() {
        let entryIndex = 2 + i
        let rightSibling: UInt32 = (i < moduleCount - 1) ? UInt32(entryIndex + 1) : noStream
        directoryBytes.append(contentsOf: direntryBytes(
            name: m.streamName, objectType: 2, left: noStream, right: rightSibling, child: noStream,
            startSector: UInt32(moduleStartSector[i]), streamSize: moduleContents[i].count
        ))
    }
    while directoryBytes.count < dirSectorCount * 512 {
        directoryBytes.append(contentsOf: [UInt8](repeating: 0, count: 128))
    }

    var file = Data(count: sectorSize)
    func sectorOffset(_ s: Int) -> Int { sectorSize * (s + 1) }
    file.append(Data(count: totalSectors * sectorSize))

    func write(_ bytes: [UInt8], at offset: Int) {
        for (i, b) in bytes.enumerated() { file[offset + i] = b }
    }
    func write(_ data: Data, at offset: Int) { write([UInt8](data), at: offset) }

    var fatBytes: [UInt8] = []
    for v in fat { fatBytes.append(contentsOf: fixtureU32LE(v)) }
    while fatBytes.count < sectorSize { fatBytes.append(0) }
    write(fatBytes, at: sectorOffset(fatSector))

    write(directoryBytes, at: sectorOffset(firstDirSector))

    var miniStreamPadded = miniStreamBlob
    while miniStreamPadded.count < miniStreamSectorCount * sectorSize { miniStreamPadded.append(0) }
    write(miniStreamPadded, at: sectorOffset(firstMiniStreamSector))

    var miniFATBytes: [UInt8] = []
    for v in miniFAT { miniFATBytes.append(contentsOf: fixtureU32LE(v)) }
    while miniFATBytes.count < miniFATSectorCount * sectorSize { miniFATBytes.append(0) }
    if miniFATSectorCount > 0 {
        write(miniFATBytes, at: sectorOffset(firstMiniFATSector))
    }

    for i in largeIndices {
        let start = largeModuleFirstSector[i]!
        let count = largeModuleSectorCount[i]!
        var padded = moduleContents[i]
        while padded.count < count * sectorSize { padded.append(0) }
        write(padded, at: sectorOffset(start))
    }

    var header = [UInt8](repeating: 0, count: sectorSize)
    let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    for i in 0..<8 { header[i] = signature[i] }
    header[24] = 0x3E; header[25] = 0x00
    header[26] = 0x03; header[27] = 0x00
    header[28] = 0xFE; header[29] = 0xFF
    header[30] = 0x09; header[31] = 0x00
    header[32] = 0x06; header[33] = 0x00
    let numFAT = fixtureU32LE(1); for i in 0..<4 { header[44 + i] = numFAT[i] }
    let fds = fixtureU32LE(UInt32(firstDirSector)); for i in 0..<4 { header[48 + i] = fds[i] }
    let cutoff = fixtureU32LE(UInt32(miniStreamCutoff)); for i in 0..<4 { header[56 + i] = cutoff[i] }
    let fmfs = fixtureU32LE(miniFATSectorCount > 0 ? UInt32(firstMiniFATSector) : endOfChain); for i in 0..<4 { header[60 + i] = fmfs[i] }
    let nmfs = fixtureU32LE(UInt32(miniFATSectorCount)); for i in 0..<4 { header[64 + i] = nmfs[i] }
    let fdifs = fixtureU32LE(endOfChain); for i in 0..<4 { header[68 + i] = fdifs[i] }
    let d0 = fixtureU32LE(UInt32(fatSector)); for i in 0..<4 { header[76 + i] = d0[i] }
    for slot in 1..<109 {
        let f = fixtureU32LE(freeSect)
        for i in 0..<4 { header[76 + slot * 4 + i] = f[i] }
    }
    write(header, at: 0)

    return file
}
