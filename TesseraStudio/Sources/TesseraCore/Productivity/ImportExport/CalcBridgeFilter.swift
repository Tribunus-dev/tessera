import Foundation

// MARK: - CalcBridgeFilter

/// Imports and exports the Calc formats nothing else in Tessera reads
/// or writes (ODS, legacy XLS) by round-tripping through CSV via
/// `LibreOfficeConverter`, reusing `SpreadsheetDigester`'s existing,
/// already-tested CSV pipeline instead of teaching this filter to
/// parse spreadsheet formats itself.
///
/// **Why CSV, not XLSX, as the intermediate format.** `openpyxl`-based
/// XLSX handling exists on the `TesseraFormatBridge` side, but nothing
/// in this codebase turns an XLSX file into a genuine `Sheet` with
/// live formulas - `SpreadsheetDigester`'s own header comment
/// describes that as a still-unbuilt "XLSX is delegated" path (the
/// method it names, `digestWorkbook(at:)`, doesn't exist).
/// `SpreadsheetDigester.digest(fileAt:)` DOES fully handle CSV, with
/// live formula detection (`treatLeadingEqualsAsFormula`). Routing
/// through CSV means this filter needed zero new spreadsheet-parsing
/// code, just a `Sheet` -> CSV serializer for the export direction.
///
/// **Formula fidelity is asymmetric - verified empirically, not
/// assumed.** On EXPORT, a Tessera cell's `=A1*2`-style source text
/// written to CSV and converted through Calc becomes a real, live
/// formula in the resulting .ods/.xls (`LibreOfficeConverterTests
/// .testConvertCSVToODSPreservesFormulaAsLiveFormula`). On IMPORT,
/// though, `soffice --convert-to csv` always writes each cell's
/// last-COMPUTED value, never its formula source - CSV simply has no
/// way to represent "this is a formula" on output. So a `Sheet` freshly
/// exported then reimported through this filter keeps its VALUES, not
/// its formula-ness (`CalcBridgeFilterTests
/// .testExportThenImportRoundTripsValuesButNotFormulaSource` pins
/// this exact asymmetry). Importing an ODS/XLS file that already
/// contains formulas has the same limit: they arrive in Tessera as
/// their last-computed values, flattened, not as live formulas.
///
/// **Bounded scope, stated plainly:** CSV carries one sheet, no cell
/// formatting, no named ranges/validation/conditional formatting -
/// only the first/active sheet's values (and, export-only, formulas)
/// round-trip. Multi-sheet ODS/XLS workbooks and any of `Sheet`'s
/// richer metadata (0.1b-0.1d this same phase) are out of scope for
/// this P0 slice.
public actor CalcBridgeFilter {

    public enum FilterError: Error, LocalizedError, Sendable {
        case unsupportedFormat(String)
        case emptyWorkbook

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "CalcBridgeFilter: unsupported format '\(format)' (supports ods, xls)"
            case .emptyWorkbook:
                return "CalcBridgeFilter: converted file produced no sheet"
            }
        }
    }

    /// Formats this filter covers. `xlsx`/`csv`/`tsv` are NOT here -
    /// `xlsx` already imports through `TesseraFormatBridge`, csv/tsv
    /// through `SpreadsheetDigester` directly.
    public static let supportedImportFormats: [String] = ["ods", "xls"]
    public static let supportedExportFormats: [String] = ["ods", "xls"]

    private let converter: LibreOfficeConverter
    private let digester: SpreadsheetDigester

    public init(converter: LibreOfficeConverter = LibreOfficeConverter(), digester: SpreadsheetDigester = SpreadsheetDigester()) {
        self.converter = converter
        self.digester = digester
    }

    /// True when the underlying `soffice` conversion is available.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    // MARK: - Import

    /// Import an ODS or legacy XLS file's bytes as a `Sheet` (its
    /// first/active sheet only, with any formulas already flattened to
    /// their last-computed values - see this type's doc comment).
    public func importWorkbook(data: Data, format: String, title: String? = nil) async throws -> Sheet {
        let normalized = format.lowercased()
        guard Self.supportedImportFormats.contains(normalized) else {
            throw FilterError.unsupportedFormat(format)
        }
        let csvData = try await converter.convert(data: data, sourceExtension: normalized, targetExtension: "csv")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-calc-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let csvURL = workDir.appendingPathComponent("import.csv")
        try csvData.write(to: csvURL)

        let workbook = try digester.digest(fileAt: csvURL)
        guard let digestedSheet = workbook.sheets.first else {
            throw FilterError.emptyWorkbook
        }
        return digestedSheet.makeSheet(title: title)
    }

    // MARK: - Export

    /// Export a `Sheet` to ODS or legacy XLS bytes. Only cell text
    /// (literal values and formula source, e.g. `=SUM(A1:A10)`) is
    /// preserved - see this type's doc comment for what's dropped.
    public func exportWorkbook(_ sheet: Sheet, format: String) async throws -> Data {
        let normalized = format.lowercased()
        guard Self.supportedExportFormats.contains(normalized) else {
            throw FilterError.unsupportedFormat(format)
        }
        let csvData = Self.csvData(for: sheet)
        return try await converter.convert(data: csvData, sourceExtension: "csv", targetExtension: normalized)
    }

    // MARK: - CSV serialization

    /// RFC 4180 CSV: a field is quoted (with embedded quotes doubled)
    /// only when it contains the delimiter, a quote, or a newline -
    /// keeping the common case readable rather than quoting every
    /// field defensively.
    public static func csvData(for sheet: Sheet) -> Data {
        var lines: [String] = []
        for row in 0..<sheet.rowCount {
            var fields: [String] = []
            for col in 0..<sheet.columnCount {
                fields.append(csvField(sheet.cellText(row: row, col: col)))
            }
            lines.append(fields.joined(separator: ","))
        }
        let csv = lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
        return Data(csv.utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
