//===----------------------------------------------------------------------===//
//  SpreadsheetDigester.swift
//  Tessera Studio
//
//  Reads spreadsheet files off disk into sheets that CALCULATE, carrying
//  provenance for every one: which file, which bytes, which sheet, when.
//
//  The existing Python importer (tools/tessera/importers) already brings
//  xlsx in as a document, but it flattens a formula to the text
//  "=SUM(A1:A10) = 55" - readable, not live, and explicitly punted to
//  "v2" in its own docstring. Now that the engine evaluates, a digested
//  formula is stored as `=SUM(A1:A10)` and computes.
//===----------------------------------------------------------------------===//

import Foundation
import CryptoKit

// MARK: - Provenance

/// Where a digested sheet came from.
///
/// The hash is of the file's bytes, so a re-digest can tell "the same
/// file again" from "the file changed underneath us" - the question that
/// matters when a number in a model has to be traced back to a source.
public struct SourceProvenance: Codable, Sendable, Equatable, Hashable {
    /// Absolute path at digest time.
    public let sourcePath: String
    /// SHA-256 of the file's bytes, lowercase hex.
    public let sourceSHA256: String
    public let sourceByteCount: Int
    /// The file's own modification date, when the filesystem reports one.
    public let sourceModifiedAt: Date?
    /// Detected format: `csv`, `tsv`, or `xlsx`.
    public let format: String
    /// Which sheet within the source, for multi-sheet workbooks.
    public let sheetName: String?
    public let sheetIndex: Int
    /// When this digest ran.
    public let digestedAt: Date
    /// Bumped when the digester's output changes shape, so a stored
    /// provenance record says which rules produced it.
    public let digesterVersion: String

    public static let currentVersion = "1"

    public init(
        sourcePath: String,
        sourceSHA256: String,
        sourceByteCount: Int,
        sourceModifiedAt: Date?,
        format: String,
        sheetName: String?,
        sheetIndex: Int,
        digestedAt: Date = Date(),
        digesterVersion: String = SourceProvenance.currentVersion
    ) {
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.sourceModifiedAt = sourceModifiedAt
        self.format = format
        self.sheetName = sheetName
        self.sheetIndex = sheetIndex
        self.digestedAt = digestedAt
        self.digesterVersion = digesterVersion
    }

    /// One-line summary for a receipt or an audit row.
    public var summary: String {
        let file = (sourcePath as NSString).lastPathComponent
        let short = String(sourceSHA256.prefix(8))
        let sheet = sheetName.map { ":\($0)" } ?? ""
        return "\(file)\(sheet) sha256:\(short)... (\(format))"
    }
}

// MARK: - Digest results

/// One sheet's worth of digested content: a grid of SOURCE text, in the
/// same representation the Sheets surface persists, so a digested
/// formula behaves exactly like a typed one.
public struct DigestedSheet: Sendable, Equatable {
    public let provenance: SourceProvenance
    /// Row-major cells. Rows are padded to a common width.
    public let rows: [[String]]

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }

    public init(provenance: SourceProvenance, rows: [[String]]) {
        self.provenance = provenance
        self.rows = rows
    }

    /// How many cells hold a formula. Reported so a caller can tell a
    /// live model from a flat data dump.
    public var formulaCount: Int {
        rows.reduce(0) { $0 + $1.filter { SheetWorkbook.isFormula($0) }.count }
    }
}

/// Everything digested from one file.
public struct DigestedWorkbook: Sendable, Equatable {
    public let sheets: [DigestedSheet]
    public var provenance: SourceProvenance? { sheets.first?.provenance }

    public init(sheets: [DigestedSheet]) {
        self.sheets = sheets
    }
}

// MARK: - Digester

/// Reads spreadsheet files into `DigestedWorkbook`s.
///
/// CSV and TSV are parsed here; the delimited formats are the ones worth
/// owning, because getting quoting wrong silently corrupts data rather
/// than failing. XLSX is delegated - see `digestWorkbook(at:)`.
public struct SpreadsheetDigester: Sendable {

    /// Whether a leading `=` makes a cell a formula.
    ///
    /// True matches Excel and is what makes a digested model live. It
    /// also means a hostile file can plant formulas - the classic CSV
    /// injection vector. The blast radius here is arithmetic only: this
    /// engine has no shell, DDE, or network functions, so a planted
    /// formula can compute a wrong number but cannot execute anything.
    /// Set false to digest untrusted files as inert text.
    public var treatLeadingEqualsAsFormula: Bool

    public init(treatLeadingEqualsAsFormula: Bool = true) {
        self.treatLeadingEqualsAsFormula = treatLeadingEqualsAsFormula
    }

    // MARK: File-level

    /// Digest a delimited file (`.csv`, `.tsv`, `.txt`).
    public func digest(fileAt url: URL) throws -> DigestedWorkbook {
        let data = try Data(contentsOf: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date

        let format = Self.detectFormat(url: url)
        guard format == "csv" || format == "tsv" else {
            throw DigesterError.unsupportedFormat(format)
        }
        guard let text = Self.decodeText(data) else {
            throw DigesterError.undecodableText(path: url.path)
        }

        let provenance = SourceProvenance(
            sourcePath: url.path,
            sourceSHA256: Self.sha256(data),
            sourceByteCount: data.count,
            sourceModifiedAt: modified,
            format: format,
            sheetName: url.deletingPathExtension().lastPathComponent,
            sheetIndex: 0
        )

        let delimiter: Character = (format == "tsv") ? "\t" : ","
        let rows = Self.parseDelimited(text, delimiter: delimiter)
        return DigestedWorkbook(sheets: [
            DigestedSheet(provenance: provenance, rows: Self.padded(rows))
        ])
    }

    // MARK: Format detection

    /// Extension-based, with a tab-versus-comma sniff for `.txt`.
    public static func detectFormat(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "csv": return "csv"
        case "tsv", "tab": return "tsv"
        case "xlsx", "xlsm": return "xlsx"
        case "txt":
            // A .txt export is usually tab-delimited.
            if let sample = try? String(contentsOf: url, encoding: .utf8).prefix(4096),
               sample.contains("\t") {
                return "tsv"
            }
            return "csv"
        default: return url.pathExtension.lowercased()
        }
    }

    // MARK: Delimited parsing

    /// RFC 4180 parsing: quoted fields may contain the delimiter, line
    /// breaks, and doubled quotes.
    ///
    /// Written as an explicit state walk rather than `split`, because
    /// splitting on the delimiter silently tears quoted fields apart -
    /// and a torn field looks like plausible data rather than an error.
    public static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while index < text.endIndex {
            let ch = text[index]

            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        // Doubled quote inside a quoted field is a literal.
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case delimiter:
                    endField()
                case "\r\n":
                    // Swift grapheme-clusters CRLF into ONE Character, so
                    // matching "\r" alone never fires on a Windows export
                    // and the line ending lands inside the field instead.
                    endRow()
                case "\r", "\n":
                    endRow()
                default:
                    field.append(ch)
                }
            }
            index = text.index(after: index)
        }

        // A trailing newline ends the last row; anything else in flight
        // is a final row without a terminator.
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    /// Pad ragged rows to the widest, so the grid is rectangular. A
    /// short row means missing trailing cells, not a shorter record.
    public static func padded(_ rows: [[String]]) -> [[String]] {
        guard let width = rows.map(\.count).max(), width > 0 else { return rows }
        return rows.map { row in
            row.count == width ? row : row + Array(repeating: "", count: width - row.count)
        }
    }

    // MARK: Bytes

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// UTF-8, then UTF-16, then Latin-1. A spreadsheet export from an
    /// older tool is often not UTF-8, and refusing it outright would be
    /// worse than decoding it lossily.
    public static func decodeText(_ data: Data) -> String? {
        var bytes = data
        // Strip a UTF-8 BOM: left in place it becomes part of the first
        // header cell and silently breaks column matching.
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.count >= 3, Array(bytes.prefix(3)) == bom {
            bytes = bytes.dropFirst(3)
        }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if let s = String(data: bytes, encoding: .utf16) { return s }
        return String(data: bytes, encoding: .isoLatin1)
    }
}

// MARK: - Hydration

extension DigestedSheet {

    /// Build a `Sheet` from this digest.
    ///
    /// Cells carry SOURCE text, the same representation a typed edit
    /// persists, so `SheetWorkbook` computes a digested formula exactly
    /// as it computes a typed one. The provenance travels on the sheet
    /// rather than in a side table: a number that cannot be traced back
    /// to its file is the problem this whole path exists to solve.
    public func makeSheet(title: String? = nil) -> Sheet {
        let name = title
            ?? provenance.sheetName
            ?? (provenance.sourcePath as NSString).lastPathComponent
        var sheet = Sheet.makeBlank(
            title: name,
            rows: Swift.max(rowCount, 1),
            cols: Swift.max(columnCount, 1)
        )
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() where !text.isEmpty {
                sheet = sheet.settingCellText(row: r, col: c, text)
            }
        }
        sheet.provenance = provenance
        return sheet
    }
}

extension SpreadsheetDigester {

    /// Digest a file and persist every sheet it contains.
    ///
    /// Each sheet is upserted through ``SheetStore``, so the import
    /// rides the same receipt backbone as every other mutation instead
    /// of writing behind its back.
    @discardableResult
    public func hydrate(fileAt url: URL, into store: SheetStore) async throws -> [Sheet] {
        let workbook = try digest(fileAt: url)
        var saved: [Sheet] = []
        for digested in workbook.sheets {
            saved.append(try await store.upsert(digested.makeSheet()))
        }
        return saved
    }

    /// Digest every delimited file in a directory.
    ///
    /// Failures are collected rather than thrown: one unreadable file in
    /// a folder of fifty should not abandon the other forty-nine. The
    /// caller gets both halves and decides.
    public func hydrate(
        directoryAt url: URL,
        into store: SheetStore
    ) async -> (sheets: [Sheet], failures: [(path: String, error: String)]) {
        var sheets: [Sheet] = []
        var failures: [(path: String, error: String)] = []

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in candidates.sorted(by: { $0.path < $1.path }) {
            let format = Self.detectFormat(url: file)
            guard format == "csv" || format == "tsv" else { continue }
            do {
                sheets.append(contentsOf: try await hydrate(fileAt: file, into: store))
            } catch {
                failures.append((file.path, error.localizedDescription))
            }
        }
        return (sheets, failures)
    }
}

// MARK: - Errors

public enum DigesterError: Error, LocalizedError, Equatable {
    case unsupportedFormat(String)
    case undecodableText(path: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Cannot digest a '\(format)' file here. CSV and TSV are read directly; XLSX goes through the import pipeline."
        case .undecodableText(let path):
            return "Could not decode \(path) as text in any supported encoding."
        }
    }
}
