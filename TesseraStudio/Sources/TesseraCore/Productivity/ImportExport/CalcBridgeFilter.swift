import Foundation

// MARK: - CalcBridgeFilter

/// Imports and exports the Calc formats nothing else in Tessera reads
/// or writes (ODS, legacy XLS).
///
/// **Import goes through flat ODS (fods), not CSV** (ratified decision
/// 12, executed here - P2-0 item 0.3/6). `soffice --convert-to fods`
/// produces the same flat-XML shape `FlatODFReader`/`FlatODFWriter`
/// already handle for the Draw/Impress bridges (`ODGBridgeFilter`,
/// `LOBridgeDeckIO`) and for this file's own pinned corpus fixtures
/// (`Tests/.../Fixtures/RoundTrip/basic-cells.fods`,
/// `sum-formula.fods`); this file reuses that reader's generic
/// `office:document` tree (see `sheet(fromFlatODS:title:)` below) and
/// adds ONLY the spreadsheet-schema mapping (`table:table` ->
/// `Sheet`) - not a second XML parser. The reason this migration
/// matters: `soffice --convert-to csv` always writes a formula
/// cell's last-COMPUTED value, never its source (CSV has no way to
/// spell "this is a formula" on output), so the CSV-based import this
/// file used before this migration silently flattened every formula
/// on the way in. fods carries `table:formula` per cell, so an
/// ODS/XLS file that already contains formulas now arrives in
/// Tessera with LIVE formula source (`odfFormulaToTesseraSource(_:)`
/// converts ODF's `of:=SUM([.A1:.A2])` bracket-reference grammar to
/// Tessera's own `=SUM(A1:A2)` syntax), not a flattened value.
///
/// **Export is unchanged - still CSV.** `Sheet` -> CSV -> `soffice
/// --convert-to <format>` was previously verified to turn a Tessera
/// formula's source text into a real, live ODS/XLS formula on the way
/// OUT (this file's pre-doctrine test suite, deleted 2026-08-15 per
/// `testing-doctrine.md`, pinned this as
/// `testConvertCSVToODSPreservesFormulaAsLiveFormula`); nothing about
/// that half needed fods to be correct, so it is left as-is per this
/// item's own scope note ("keep export as-is unless fods is trivially
/// better there too" - a `Sheet` -> fods serializer through
/// `FlatODFWriter` is a real additional surface, not a trivial win,
/// so it stays out of this pass). Whether a full export-then-reimport
/// cycle now preserves formula-ness end to end (export bakes a live
/// ODS formula; import, via this migration, now reads it back) is an
/// open empirical question for this file's gated soffice-probe tests
/// to confirm, not re-verified here since the pre-doctrine pin that
/// would have anchored it no longer exists.
///
/// **Bounded scope, stated plainly:** only the first/active
/// `table:table` in the converted document is mapped; multi-sheet
/// ODS/XLS workbooks, cell formatting, named ranges, data validation,
/// and conditional formatting are out of scope for this bridge (they
/// live on `Sheet`'s own richer metadata, wired by other importers).
/// The imported grid is bounded to `maxImportedRows` x
/// `maxImportedColumns` (see that constant's doc comment) so a
/// corrupt or pathological repeat count in the converted fods cannot
/// force an unbounded `Sheet.makeBlank` allocation.
public actor CalcBridgeFilter {

    public enum FilterError: Error, LocalizedError, Sendable {
        case unsupportedFormat(String)
        case emptyWorkbook
        case malformedDocument(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "CalcBridgeFilter: unsupported format '\(format)' (supports ods, xls)"
            case .emptyWorkbook:
                return "CalcBridgeFilter: converted file produced no sheet"
            case .malformedDocument(let detail):
                return "CalcBridgeFilter: \(detail)"
            }
        }
    }

    /// Formats this filter covers. `xlsx`/`csv`/`tsv` are NOT here -
    /// `xlsx` already imports through `TesseraFormatBridge`, csv/tsv
    /// through `SpreadsheetDigester` directly.
    public static let supportedImportFormats: [String] = ["ods", "xls"]
    public static let supportedExportFormats: [String] = ["ods", "xls"]

    private let converter: LibreOfficeConverter
    private let reader: FlatODFReader

    public init(converter: LibreOfficeConverter = LibreOfficeConverter(), reader: FlatODFReader = FlatODFReader()) {
        self.converter = converter
        self.reader = reader
    }

    /// True when the underlying `soffice` conversion is available.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    // MARK: - Import

    /// Import an ODS or legacy XLS file's bytes as a `Sheet` (its
    /// first/active sheet only). A cell carrying a stored ODF formula
    /// (`table:formula`) arrives with its LIVE formula source, not
    /// soffice's last-computed value - see this type's doc comment.
    public func importWorkbook(data: Data, format: String, title: String? = nil) async throws -> Sheet {
        let normalized = format.lowercased()
        guard Self.supportedImportFormats.contains(normalized) else {
            throw FilterError.unsupportedFormat(format)
        }
        let fodsData = try await converter.convert(data: data, sourceExtension: normalized, targetExtension: "fods")

        let discardDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-calc-bridge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: discardDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: discardDir) }

        let parsed = try await reader.parse(data: fodsData) { bytes in
            // Nothing this bridge maps carries embedded binary data
            // (charts/images are out of scope - see this file's doc
            // comment); still needs *some* URL per FlatODFReader's
            // contract, so it's dropped in a throwaway directory
            // removed on return, matching ODGBridgeFilter's same
            // pattern for its own out-of-scope binary content.
            let discardURL = discardDir.appendingPathComponent(UUID().uuidString)
            try? bytes.write(to: discardURL)
            return discardURL
        }
        return try Self.sheet(fromFlatODS: parsed, title: title)
    }

    // MARK: - fods -> Sheet mapping

    /// Column-repeat expansion ceiling for a content-bearing cell
    /// (`table:number-columns-repeated` on a `table:table-cell` that
    /// also carries a value/formula - a real, if unusual, ODF
    /// construct for a run of identical values). Generous for any
    /// real spreadsheet (ODF/Excel's own column ceiling is 16384)
    /// while bounding a corrupt or adversarial repeat count from
    /// allocating unbounded memory for one cell.
    static let maxRepeatExpansion = 16_384

    /// Hard ceiling on the imported grid's own dimensions - protects
    /// `Sheet.makeBlank`'s eager `rows * cols` cell allocation (and
    /// `SheetGridView`'s un-virtualized row loop) from a corrupt or
    /// pathological fods file whose LAST populated cell sits at an
    /// extreme row/column index. Generous for any sheet built through
    /// this app's own grid UI; not a claim that a real workbook with
    /// more populated rows/columns is unsupported elsewhere, only
    /// that THIS bridge caps what it will materialize in one import.
    static let maxImportedRows = 10_000
    static let maxImportedColumns = 1_000

    /// Maps a parsed flat-ODS tree's first `table:table` into a
    /// `Sheet`. Reuses `FlatODFReader`'s generic tree (see this file's
    /// doc comment) - this is the spreadsheet-schema half, not a
    /// second XML parser.
    static func sheet(fromFlatODS result: FlatODFReader.Result, title: String?) throws -> Sheet {
        guard result.contentType == .spreadsheet else {
            throw FilterError.malformedDocument("converted document is not a spreadsheet (contentType: \(result.contentType))")
        }
        guard let spreadsheet = result.bodyChildren.first(where: { $0.name == "office:spreadsheet" }),
              let table = spreadsheet.elementChildren.first(where: { $0.name == "table:table" }) else {
            throw FilterError.emptyWorkbook
        }

        let (texts, maxRow, maxCol) = mapRows(of: table)
        let rows = max(min(maxRow + 1, maxImportedRows), 1)
        let cols = max(min(maxCol + 1, maxImportedColumns), 1)

        let name = title ?? table.attributes["table:name"] ?? "Sheet1"
        var sheet = Sheet.makeBlank(title: name, rows: rows, cols: cols)
        for (r, columns) in texts where r < rows {
            for (c, text) in columns where c < cols {
                sheet = sheet.settingCellText(row: r, col: c, text)
            }
        }
        return sheet
    }

    /// Walks `table`'s `table:table-row` children into a sparse
    /// row/col -> source-text map, plus the highest populated row/col
    /// seen, WITHOUT materializing the (often enormous)
    /// `table:number-rows-repeated` runs soffice uses to compact long
    /// stretches of blank trailing rows - only the row-index counter
    /// advances for those, so a fods whose repeat count claims
    /// hundreds of thousands of blank rows costs one `Int` addition,
    /// not one allocation per row.
    private static func mapRows(of table: FlatODFElement) -> (texts: [Int: [Int: String]], maxRow: Int, maxCol: Int) {
        var texts: [Int: [Int: String]] = [:]
        var maxRow = -1
        var maxCol = -1
        var row = 0
        for rowElement in table.elementChildren where rowElement.name == "table:table-row" {
            let rowRepeat = max(1, Int(rowElement.attributes["table:number-rows-repeated"] ?? "1") ?? 1)
            var col = 0
            var rowTexts: [Int: String] = [:]
            for cellElement in rowElement.elementChildren
            where cellElement.name == "table:table-cell" || cellElement.name == "table:covered-table-cell" {
                let cellRepeat = max(1, Int(cellElement.attributes["table:number-columns-repeated"] ?? "1") ?? 1)
                if cellElement.name == "table:table-cell", let text = cellSourceText(cellElement), !text.isEmpty {
                    let expand = min(cellRepeat, maxRepeatExpansion)
                    for offset in 0..<expand {
                        rowTexts[col + offset] = text
                    }
                    maxCol = max(maxCol, col + expand - 1)
                }
                // `table:covered-table-cell` (a merged-cell placeholder)
                // carries no independent content but still consumes a
                // column slot for numbering purposes.
                col += cellRepeat
            }
            if !rowTexts.isEmpty {
                // A content-bearing row repeated more than once is not
                // something real soffice output does (repeats compact
                // runs of BLANK rows, never content) - materialize it
                // once at `row` regardless of `rowRepeat`, rather than
                // trust an unusual/corrupt file to duplicate real data
                // across a large repeat span.
                for (c, t) in rowTexts { texts[row, default: [:]][c] = t }
                maxRow = max(maxRow, row)
            }
            row += rowRepeat
        }
        return (texts, maxRow, maxCol)
    }

    /// The SOURCE text one cell contributes to the imported `Sheet` -
    /// formula source (via `odfFormulaToTesseraSource(_:)`) when
    /// `table:formula` is present, else the value proper to
    /// `office:value-type`'s own attribute for that type (`office:
    /// value`/`office:boolean-value`/`office:date-value`/`office:
    /// time-value`), NEVER the displayed `text:p` for a numeric/
    /// boolean/date cell - that text can be locale-formatted
    /// ("1,234.50") and would misparse through
    /// `CellValue.classify(_:columnType:)`. `nil` for a cell with
    /// neither a formula nor a recognized value (a genuinely empty
    /// cell, or a `table:covered-table-cell`, which never reaches
    /// this function - see `mapRows(of:)`).
    private static func cellSourceText(_ cell: FlatODFElement) -> String? {
        if let formula = cell.attributes["table:formula"] {
            return odfFormulaToTesseraSource(formula)
        }
        switch cell.attributes["office:value-type"] {
        case "float", "percentage", "currency":
            return cell.attributes["office:value"]
        case "boolean":
            guard let raw = cell.attributes["office:boolean-value"] else { return nil }
            return raw.lowercased() == "true" ? "TRUE" : "FALSE"
        case "date":
            return cell.attributes["office:date-value"].map(normalizedISO8601DateTime)
        case "time":
            // ODF's `office:time-value` is an ISO 8601 DURATION
            // ("PT02H30M00S", a span since midnight), not a
            // timestamp - `CellValue` has no time-of-day
            // representation to convert it into (only `.date(Date)`,
            // a full calendar instant), so this passes through as
            // plain text rather than guessing a calendar date to
            // attach it to.
            return cell.attributes["office:time-value"]
        case "string", nil:
            let text = cell.elementChildren
                .filter { $0.name == "text:p" }
                .map { plainText(of: $0) }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    /// Normalizes an ODF `office:date-value` (e.g. `"2026-08-15"`, a
    /// plain date verified against a real soffice CSV->ODS->fods
    /// conversion) into something
    /// `CellValue.classify(_:columnType:)`'s own `parseDate`
    /// (`CellValue.swift`, `ISO8601DateFormatter().date(from:)` under
    /// its DEFAULT options) actually accepts: that formatter requires
    /// BOTH a time-of-day AND a timezone designator, which ODF's date
    /// (as opposed to date-time) form has neither of. Left untouched,
    /// an imported date cell would silently misclassify as `.text`
    /// instead of `.date` the moment anything re-runs it through
    /// `classify` (every cell-write path does). Appends midnight
    /// (`T00:00:00`) when there is no time component, and `Z` when
    /// the time component (own or appended) carries no timezone
    /// designator - checked only in the portion AFTER `T`, so the
    /// date part's own `-` field separators are never mistaken for a
    /// negative UTC offset.
    private static func normalizedISO8601DateTime(_ raw: String) -> String {
        guard let tIndex = raw.firstIndex(of: "T") else {
            return raw + "T00:00:00Z"
        }
        let afterT = raw[raw.index(after: tIndex)...]
        guard !afterT.contains("Z"), !afterT.contains("+"), !afterT.contains("-") else {
            return raw
        }
        return raw + "Z"
    }

    /// Concatenated character data of every `.text` node under
    /// `element`, depth-first - `text:p` can nest `text:span`/
    /// `text:a`/etc. around runs of plain text (mixed content, see
    /// `FlatODFElement`'s own doc comment); this flattens all of it,
    /// dropping the markup and keeping only the characters, matching
    /// what a cell's plain-text value means for a `Sheet.tableCell`'s
    /// single `InlineRun`.
    private static func plainText(of element: FlatODFElement) -> String {
        var out = ""
        for child in element.children {
            switch child {
            case .text(let s): out += s
            case .element(let e): out += plainText(of: e)
            }
        }
        return out
    }

    // MARK: - ODF formula -> Tessera formula source

    /// Converts one ODF `table:formula` value (e.g.
    /// `"of:=SUM([.A1:.A2])"`) to the text Tessera's own formula
    /// lexer parses (e.g. `"=SUM(A1:A2)"`). ODF prefixes the formula
    /// grammar's namespace before the leading "=" (`of:` per ODF 1.2,
    /// `oooc:` in older StarOffice-flavoured files, or nothing at all
    /// in plain ODF 1.0/1.1) - dropped here - and wraps every cell/
    /// range reference in `[...]` using its own dot-separated address
    /// syntax (`[.A1]`, `[.A1:.B2]`, `[Sheet1.A1]`) instead of Excel/
    /// Tessera's bare `A1`/`A1:B2`/`Sheet1!A1` - rewritten by
    /// `convertODFReferences(_:)`. `$`-absolute markers pass through
    /// unchanged; Tessera's lexer already understands them
    /// (`Lexer.scanDollarRef`).
    static func odfFormulaToTesseraSource(_ odfFormula: String) -> String {
        guard let eqIndex = odfFormula.firstIndex(of: "=") else {
            return "=" + convertODFReferences(odfFormula)
        }
        let body = String(odfFormula[odfFormula.index(after: eqIndex)...])
        return "=" + convertODFReferences(body)
    }

    /// Rewrites every ODF `[...]` bracketed reference in `formula` to
    /// Tessera's bare A1 syntax. A `"..."` string literal is copied
    /// verbatim first - a `[` inside a quoted argument is text, not a
    /// reference - the same guard
    /// `SheetConditionalFormat.shiftedFormula` uses for the same
    /// reason.
    private static func convertODFReferences(_ formula: String) -> String {
        var out = ""
        var chars = Substring(formula)
        while let ch = chars.first {
            if ch == "\"" {
                out.append(ch)
                chars.removeFirst()
                while let c = chars.first {
                    out.append(c)
                    chars.removeFirst()
                    if c == "\"" { break }
                }
                continue
            }
            if ch == "[", let closeIndex = chars.firstIndex(of: "]") {
                let inner = chars[chars.index(after: chars.startIndex)..<closeIndex]
                out += convertODFReferenceBody(String(inner))
                chars = chars[chars.index(after: closeIndex)...]
                continue
            }
            out.append(ch)
            chars.removeFirst()
        }
        return out
    }

    /// One `[...]`'s inner text (no brackets), e.g. `.A1`, `.A1:.B2`,
    /// `Sheet1.A1:.B2`, `'My Sheet'.A1` - split on the first unquoted
    /// `:` into one or two corners.
    private static func convertODFReferenceBody(_ body: String) -> String {
        guard let colonIndex = unquotedIndex(of: ":", in: body) else {
            return convertODFCorner(body)
        }
        let left = String(body[body.startIndex..<colonIndex])
        let right = String(body[body.index(after: colonIndex)...])
        // Tessera's range grammar carries a sheet qualifier on the
        // LEFT corner only (Lexer.scanRangeRef combines a leading
        // sheet-qualified cellRef with a bare second token - see its
        // own doc comment on `Sheet1!A1:B5`). ODF repeats (or omits)
        // the sheet on the right corner; either way only its cell
        // address carries through here.
        return convertODFCorner(left) + ":" + convertODFCorner(right, includeSheet: false)
    }

    /// One reference corner: `.A1` (leading dot, no name - ODF's
    /// "this sheet" marker, simply dropped), `Sheet1.A1`,
    /// `'My Sheet'.$A$1`. `includeSheet: false` drops a sheet
    /// qualifier even when present (the range right-corner case
    /// above); `$`-prefixed sheet names (ODF's sheet-absolute marker,
    /// with no Tessera equivalent) have the `$` stripped.
    private static func convertODFCorner(_ corner: String, includeSheet: Bool = true) -> String {
        guard let dotIndex = unquotedIndex(of: ".", in: corner) else {
            // No dot - not well-formed ODF address syntax (or a named
            // range, which ODF also wraps in brackets with no dot);
            // pass through unchanged rather than guess.
            return corner
        }
        let sheetPart = String(corner[corner.startIndex..<dotIndex])
        let cellPart = String(corner[corner.index(after: dotIndex)...])
        guard includeSheet, !sheetPart.isEmpty else { return cellPart }
        let name = sheetPart.hasPrefix("$") ? String(sheetPart.dropFirst()) : sheetPart
        return name + "!" + cellPart
    }

    /// The index of the first `target` character in `s` that is NOT
    /// inside a `'...'`-quoted run (ODF's quoted-sheet-name syntax,
    /// which can itself contain `.`/`:` - e.g. `'Q1:Q2'.A1`). `nil` if
    /// `target` never appears outside quotes.
    private static func unquotedIndex(of target: Character, in s: String) -> String.Index? {
        var inQuotes = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "'" { inQuotes.toggle() }
            if c == target, !inQuotes { return i }
            i = s.index(after: i)
        }
        return nil
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

// MARK: - Legacy-import @-prefixing (1.21 dynamic-array completion, item 2)

/// Detection half of the legacy-import `@`-prefixing item this fods
/// migration unblocks (audit item, plan §3 Class B row 6): a formula
/// that would produce a spilling dynamic-array result under Tessera's
/// MODERN evaluation semantics, but was imported from a LEGACY source
/// (any ODS/XLS this bridge reads) that expects old single-cell-
/// return behavior, should not start silently spilling into its
/// neighbour cells on import.
///
/// **Why this is detection-only - the marking half is BLOCKED, not
/// implemented.** The legacy fix Excel itself ships is an explicit
/// `@` implicit-intersection prefix on the formula
/// (`Evaluator.swift`'s own doc comment names this exact operator:
/// "implicit intersection (`@` in Excel's modern engine)"). Tessera's
/// formula grammar has no such token: `Lexer.swift`'s `scanToken()`
/// has no case for `@` at all and falls through to its `default`
/// branch, which throws `LexError("Unexpected character '@'")` for
/// ANY input containing it - confirmed by reading the lexer, not
/// assumed. Inserting a literal `@` into an imported formula's source
/// text would therefore turn a working formula into a parse error on
/// every subsequent evaluation - strictly worse than leaving it to
/// spill. Adding `@` support is a `Lexer.swift`/`Parser.swift`/
/// `Evaluator.swift` change (a real operator: tokenize it, parse it
/// as a prefix marker, and have `Evaluator` route a `@`-marked
/// top-level formula through the SAME `implicitIntersection(_:at:
/// sheet:engine:)` reduction it already applies to operand-position
/// ranges) - none of those files are in this track's (0-A Calc) owned
/// file list this wave, so the fix is BLOCKED here rather than
/// applied unsafely. See `TesseraStudio/docs/.scratch/p2-0-findings-a.md`.
///
/// **What IS shipped: the detection this future fix will need**,
/// built by reusing the existing parser/AST (`FormulaParser`,
/// `FormulaAST`) rather than a second formula grammar - matching this
/// item's own instruction to reuse 1.21's machinery. Ready
/// infrastructure with no caller yet, the same shape
/// `TokenArray.swift`'s own header comment documents for itself
/// ("NOT wired into SheetEngine's live cell-evaluation path in this
/// pass... ready infrastructure for a later increment to adopt").
extension CalcBridgeFilter {

    /// The five functions `FunctionRegistry.registerArray()`
    /// (`ArrayFunctions.swift`) actually registers as array-returning.
    /// Hardcoded here rather than introspected from the registry -
    /// this codebase's "independent oracle" convention
    /// (testing-doctrine.md rule 7) for a closed, spec-known set, the
    /// same shape the OOXML-transition-totality guard test uses.
    static let arrayReturningFunctionNames: Set<String> = [
        "SEQUENCE", "TRANSPOSE", "UNIQUE", "SORT", "FILTER",
    ]

    /// Whether `formulaSource` (Tessera syntax, e.g. `"=SUM(A1:A3)"`,
    /// already converted from ODF via `odfFormulaToTesseraSource(_:)`
    /// when it came from an import) would SPILL as its OWN top-level
    /// result under Tessera's modern dynamic-array semantics - the
    /// exact condition `SheetEngine.writeResult` tests at write time
    /// (an evaluated `.array` `Value` with more than one cell: see
    /// that method's "A 1x1 array is a scalar" / "rows * cols > 1"
    /// guards). A STATIC, pre-evaluation approximation of that same
    /// runtime test:
    ///
    ///  - a top-level call to one of `arrayReturningFunctionNames`;
    ///  - a top-level bare multi-cell range reference (`=A1:A3` with
    ///    no surrounding operator/function) - everywhere else a range
    ///    appears (an operand, a function argument),
    ///    `Evaluator.evaluateScalarOperand`'s implicit-intersection
    ///    reduction already collapses it to a scalar before this
    ///    question could even arise; the TOP level of a formula is
    ///    the one position that reduction never covers.
    ///
    /// Returns `false` (conservatively: "would not spill") for a
    /// formula this static check cannot fully resolve without live
    /// evaluation against real cell data - e.g. `=IF(cond,
    /// SEQUENCE(3),1)`, whose result shape depends on `cond` - and
    /// for anything that fails to parse. `false` for a non-formula
    /// (`SheetWorkbook.isFormula` says no) too.
    static func wouldSpillAsTopLevelResult(formulaSource: String) -> Bool {
        guard SheetWorkbook.isFormula(formulaSource) else { return false }
        guard let parsed = try? FormulaParser(source: formulaSource).parse(),
              case .formula(let formula) = parsed else { return false }
        switch formula.ast {
        case .function(let name, _):
            return arrayReturningFunctionNames.contains(name.uppercased())
        case .range(let range):
            return range.width * range.height > 1
        default:
            return false
        }
    }
}
