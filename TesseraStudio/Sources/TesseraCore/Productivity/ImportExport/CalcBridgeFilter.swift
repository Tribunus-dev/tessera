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

        // P2b: table:data-pilot-tables round-trip (import direction -
        // see "Pivot fods round-trip" below for the export/encode
        // half and its own scope note). A malformed individual
        // table:data-pilot-table (unparseable source range, etc.) is
        // skipped rather than failing the whole import - one bad
        // pivot definition should not block the sheet's cell data from
        // ever importing.
        if let pilotTables = spreadsheet.firstElementChild(named: "table:data-pilot-tables") {
            let definitions = pilotTables.elementChildren
                .filter { $0.name == "table:data-pilot-table" }
                .compactMap { pivotDefinition(from: $0) }
            if !definitions.isEmpty {
                sheet.pivotDefinitions = definitions
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
                if cellElement.name == "table:table-cell", let rawText = cellSourceText(cellElement), !rawText.isEmpty {
                    // Gap item b, final step: a legacy-imported formula
                    // that would spill under Tessera's modern dynamic-
                    // array semantics gets the `@` implicit-intersection
                    // prefix `wouldSpillAsTopLevelResult` was built (P2-0)
                    // to detect, now that `@` itself is a real, evaluable
                    // operator (see Lexer/Parser/Evaluator's own P2b
                    // changes) - see `legacySpillGuarded`'s doc comment.
                    let text = legacySpillGuarded(rawText)
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

// MARK: - Legacy-import @-prefixing (1.21 dynamic-array completion, item 2 -
// UNBLOCKED at P2-B gap item b)

/// A formula that would produce a spilling dynamic-array result under
/// Tessera's MODERN evaluation semantics, but was imported from a
/// LEGACY source (any ODS/XLS this bridge reads) that expects old
/// single-cell-return behavior, should not start silently spilling into
/// its neighbour cells on import.
///
/// **History (P2-0 -> P2-B).** P2-0 shipped `wouldSpillAsTopLevelResult`
/// below as DETECTION ONLY: the marking half was BLOCKED because
/// Tessera's formula grammar had no `@` token at all -
/// `Lexer.swift`'s `scanToken()` fell through to `default` and threw
/// `LexError("Unexpected character '@'")` for any input containing it,
/// so inserting a literal `@` into an imported formula would have
/// turned a working formula into a parse error on every subsequent
/// evaluation - strictly worse than leaving it to spill. See
/// `TesseraStudio/docs/.scratch/p2-0-findings-a.md` for the full
/// original reasoning. P2-B gap item b added the real `@` operator
/// (`Lexer`/`Parser`/`Evaluator`, all outside this file) and wires the
/// marking half in below (`legacySpillGuarded`, called from
/// `mapRows(of:)`'s formula-cell branch).
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

    /// The marking half (gap item b): inserts an `@` implicit-
    /// intersection prefix right after `text`'s leading "=" when
    /// `wouldSpillAsTopLevelResult` says it would otherwise spill,
    /// preserving the legacy single-cell-return behavior the workbook's
    /// original (pre-Tessera) author relied on.
    ///
    /// **No separate "already has an explicit @" check is needed to
    /// avoid double-prefixing.** Once `@` is a real prefix operator
    /// (`Parser.parseUnary`), an already-`@`-prefixed formula's
    /// top-level AST is `.unary(op: .implicitIntersection, ...)` -
    /// which `wouldSpillAsTopLevelResult`'s own switch does not match
    /// (only `.function`/`.range` do), so it already reads as "would
    /// not spill" and this function leaves it untouched. Idempotent by
    /// construction, not by a redundant guard.
    ///
    /// A non-formula value, or a formula this static check cannot
    /// resolve, passes through unchanged (`wouldSpillAsTopLevelResult`'s
    /// own conservative-false contract).
    static func legacySpillGuarded(_ text: String) -> String {
        guard wouldSpillAsTopLevelResult(formulaSource: text), let eqIndex = text.firstIndex(of: "=") else { return text }
        let insertAt = text.index(after: eqIndex)
        return String(text[..<insertAt]) + "@" + String(text[insertAt...])
    }
}

// MARK: - Pivot fods round-trip (2.2b item f)

/// `table:data-pilot-table` import/export - the fods round-trip surface
/// design decision 12 names for pivot definitions (never the xlsx parts
/// directly, per `sota-p2-core-report.md` #2.2's SOTA evidence).
///
/// **Element/attribute vocabulary.** Real ODF 1.2 §9.3 names
/// (`table:data-pilot-table`, `table:source-cell-range`,
/// `table:data-pilot-field`, `table:orientation`, `table:function`,
/// `table:data-pilot-level`, `table:data-pilot-subtotals`/`-subtotal`,
/// `table:data-pilot-members`/`-member`, `table:data-pilot-groups`/
/// `-group`/`-group-member`) are used for every structural element this
/// engine's own field vocabulary maps onto directly. Four things this
/// pass could NOT verify against a real soffice-produced pivot fods
/// (the P2-0 fods migration's own probe covered plain cells/formulas,
/// not pivot tables - no probe corpus with a real pivot exists yet, and
/// building one needs UNO macro scripting to script LO into creating
/// one, out of this track's scope) get a `tessera:`-namespaced
/// attribute instead of guessing at unverified real-ODF spelling:
/// `tessera:id` (definition identity - ODF has no such concept, this
/// bridge's own round-trip needs one), `tessera:sort-*`/
/// `tessera:auto-show-*` payload attributes on `table:data-pilot-
/// sort-info`/`table:data-pilot-display-info` (the real elements are
/// spec-named per `ScDPSaveDimension`'s `sortInfo`/`autoShowInfo`, but
/// this pass could not verify their exact attribute spelling), the
/// `table:data-pilot-field-reference` element for `reference` (the real
/// ODF name for `referenceValue`; attribute spelling likewise
/// unverified), and `tessera:group-by`/`tessera:date-intervals` on
/// `table:data-pilot-groups` (the grouping element name is real ODF;
/// distinguishing numeric-vs-date and spelling the date-interval
/// multi-select is this bridge's own convention). **Recorded for
/// architect ratification** (this track's findings file has the full
/// reasoning): this pass is internally self-consistent (encode's
/// output round-trips through decode byte-for-byte on the parts that
/// matter, proven by `CalcBridgeFilterTests`'s direct encode->write->
/// parse->decode test) but is NOT yet gate-tested against a real
/// soffice-authored pivot fods the way this file's cell/formula mapping
/// is - a soffice-probe-gated test (doctrine rule 10) is the natural
/// follow-up once a real fixture exists.
///
/// **Wiring scope call.** The DECODE half is wired into the real
/// import path (`sheet(fromFlatODS:title:)` above): an imported ODS/XLS
/// with pivot tables now populates `Sheet.pivotDefinitions`. The ENCODE
/// half is a real, tested, pure function with no caller yet - this
/// file's `exportWorkbook` still exports via CSV (its own doc comment:
/// "a Sheet -> fods serializer through FlatODFWriter is a real
/// additional surface, not a trivial win"), and CSV cannot carry a
/// pivot definition at all. Wiring `dataPilotTableElement(for:)` into a
/// live byte-producing export means building that Sheet -> fods
/// serializer first - a separate, much larger surface than this one
/// item, and out of this track's file list to build. Same shape this
/// file's own `wouldSpillAsTopLevelResult` shipped in P2-0: ready
/// infrastructure, wired on the read side, waiting for its write-side
/// caller.
extension CalcBridgeFilter {

    // MARK: - Encode (SheetPivotDefinition -> FlatODFElement)

    /// One `SheetPivotDefinition` as a `table:data-pilot-table`
    /// element, ready to nest under a `table:data-pilot-tables`
    /// container alongside a sheet's `table:table` (see this
    /// extension's doc comment for the vocabulary this uses).
    static func dataPilotTableElement(for definition: SheetPivotDefinition) -> FlatODFElement {
        var attrs: [String: String] = [
            "table:name": definition.name,
            "tessera:id": definition.id.uuidString,
            "table:grand-total": grandTotalAttribute(columnGrand: definition.columnGrand, rowGrand: definition.rowGrand),
            "table:ignore-empty-rows": boolAttr(definition.ignoreEmptyRows),
            "table:show-filter-button": boolAttr(definition.filterButton),
            "table:drill-down": boolAttr(definition.drillDown),
            "tessera:repeat-if-empty": boolAttr(definition.repeatIfEmpty),
        ]
        if let grandTotalName = definition.grandTotalName { attrs["tessera:grand-total-name"] = grandTotalName }
        if let styleInfo = definition.styleInfo {
            attrs["tessera:style-name"] = styleInfo.styleName
            attrs["tessera:style-show-row-headers"] = boolAttr(styleInfo.showRowHeaders)
            attrs["tessera:style-show-column-headers"] = boolAttr(styleInfo.showColumnHeaders)
            attrs["tessera:style-show-row-stripes"] = boolAttr(styleInfo.showRowStripes)
            attrs["tessera:style-show-column-stripes"] = boolAttr(styleInfo.showColumnStripes)
            attrs["tessera:style-show-last-column"] = boolAttr(styleInfo.showLastColumn)
        }

        var children: [FlatODFNode] = []
        if let source = definition.sourceRangeRef {
            children.append(.element(FlatODFElement(
                name: "table:source-cell-range",
                attributes: ["table:cell-range-address": source.description]
            )))
        }
        if let outputCol = definition.outputTopLeftCol, let outputRow = definition.outputTopLeftRow,
           outputCol >= 0, outputRow >= 0 {
            // `CellAddr.init` traps on a negative coordinate;
            // `outputTopLeftCol`/`outputTopLeftRow` carry no such
            // validation on `SheetPivotDefinition` (unlike the source
            // range, which is guarded by `sourceRangeRef`'s own nil
            // check) - skip the target-range element defensively
            // rather than crash on a definition nobody validated.
            let anchor = CellAddr(col: outputCol, row: outputRow)
            let targetRange = RangeRef(sheet: definition.outputSheet, topLeft: anchor, bottomRight: anchor)
            children.append(.element(FlatODFElement(
                name: "table:target-range-address",
                attributes: ["table:cell-range-address": targetRange.description]
            )))
        }
        children.append(contentsOf: definition.fields.map { .element(dataPilotFieldElement(for: $0)) })

        return FlatODFElement(name: "table:data-pilot-table", attributes: attrs, children: children)
    }

    private static func dataPilotFieldElement(for field: SheetPivotField) -> FlatODFElement {
        var attrs: [String: String] = [
            "table:source-field-name": field.fieldName,
            "table:orientation": field.orientation.rawValue,
            "table:used-hierarchy": "-1",
            "tessera:subtotal-auto": boolAttr(field.subtotalAuto),
            "tessera:repeat-item-labels": boolAttr(field.repeatItemLabels),
        ]
        if let function = field.function { attrs["table:function"] = function.rawValue }

        var levelChildren: [FlatODFNode] = []
        if !field.subtotals.isEmpty {
            levelChildren.append(.element(FlatODFElement(
                name: "table:data-pilot-subtotals",
                children: field.subtotals.map { .element(FlatODFElement(name: "table:data-pilot-subtotal", attributes: ["table:function": $0.rawValue])) }
            )))
        }
        if !field.members.isEmpty {
            levelChildren.append(.element(FlatODFElement(
                name: "table:data-pilot-members",
                children: field.members.map {
                    .element(FlatODFElement(name: "table:data-pilot-member", attributes: [
                        "table:name": $0.name,
                        "table:display": boolAttr($0.visible),
                    ]))
                }
            )))
        }
        if let autoShow = field.autoShow {
            levelChildren.append(.element(FlatODFElement(name: "table:data-pilot-display-info", attributes: [
                "table:enabled": boolAttr(autoShow.enabled),
                "table:data-field": autoShow.dataFieldName,
                "table:member-count": String(autoShow.itemCount),
                "table:display-member-mode": autoShow.direction == .top ? "from-top" : "from-bottom",
            ])))
        }
        if let sort = field.sort {
            var sortAttrs = [
                "table:order": sort.ascending ? "ascending" : "descending",
                "tessera:sort-mode": sort.mode.rawValue,
            ]
            if let dataFieldName = sort.dataFieldName { sortAttrs["table:data-field"] = dataFieldName }
            levelChildren.append(.element(FlatODFElement(name: "table:data-pilot-sort-info", attributes: sortAttrs)))
        }
        if let layout = field.layout {
            levelChildren.append(.element(FlatODFElement(name: "table:data-pilot-layout-info", attributes: [
                "table:layout-mode": layout.mode.rawValue,
                "table:add-empty-lines": boolAttr(layout.addEmptyLine),
                "tessera:subtotals-at-top": boolAttr(layout.subtotalsAtTop),
            ])))
        }
        if let reference = field.reference {
            levelChildren.append(.element(FlatODFElement(name: "table:data-pilot-field-reference", attributes: [
                "tessera:reference-type": reference.rawValue,
            ])))
        }
        if let group = field.group {
            levelChildren.append(.element(dataPilotGroupsElement(for: group)))
        }
        levelChildren.append(.element(FlatODFElement(name: "table:data-pilot-level", attributes: ["table:show-empty": boolAttr(field.showEmpty)], children: [])))
        // `table:data-pilot-level` is the real ODF container for
        // subtotals/members/layout per spec; this bridge nests its
        // level-scoped children as SIBLINGS of the (attribute-only)
        // level marker rather than inside it, to keep this function
        // flat - decode reads them back from the field element
        // directly (see `pivotField(from:)`), so the exact nesting
        // depth is this bridge's own internal contract, not something
        // an external reader depends on.
        return FlatODFElement(name: "table:data-pilot-field", attributes: attrs, children: levelChildren)
    }

    private static func dataPilotGroupsElement(for group: PivotGroupSpec) -> FlatODFElement {
        switch group {
        case .numeric(let start, let end, let step):
            return FlatODFElement(name: "table:data-pilot-groups", attributes: [
                "tessera:group-by": "numeric",
                "table:step": String(step),
                "table:start-value": String(start),
                "table:end-value": String(end),
            ])
        case .date(let by):
            return FlatODFElement(name: "table:data-pilot-groups", attributes: [
                "tessera:group-by": "date",
                "tessera:date-intervals": by.map { $0.rawValue }.sorted().joined(separator: ","),
            ])
        case .members(let groups):
            return FlatODFElement(
                name: "table:data-pilot-groups",
                attributes: ["tessera:group-by": "members"],
                children: groups.map { memberGroup in
                    .element(FlatODFElement(
                        name: "table:data-pilot-group",
                        attributes: ["table:name": memberGroup.name],
                        children: memberGroup.members.map {
                            .element(FlatODFElement(name: "table:data-pilot-group-member", attributes: ["table:name": $0]))
                        }
                    ))
                }
            )
        }
    }

    // MARK: - Decode (FlatODFElement -> SheetPivotDefinition)

    /// The inverse of `dataPilotTableElement(for:)`. Returns `nil` for
    /// an element this bridge cannot make sense of (an unparseable or
    /// missing source range) rather than throwing - a single malformed
    /// pivot definition must not fail the whole sheet import (see the
    /// call site in `sheet(fromFlatODS:title:)`).
    static func pivotDefinition(from element: FlatODFElement) -> SheetPivotDefinition? {
        guard let sourceRangeString = element.firstElementChild(named: "table:source-cell-range")?.attributes["table:cell-range-address"],
              let source = try? AddressParser.parseRange(sourceRangeString) else { return nil }

        let id = element.attributes["tessera:id"].flatMap { UUID(uuidString: $0) } ?? UUID()
        let name = element.attributes["table:name"] ?? "Pivot"
        let (columnGrand, rowGrand) = grandTotals(from: element.attributes["table:grand-total"])

        var outputSheet: String?
        var outputTopLeftCol: Int?
        var outputTopLeftRow: Int?
        if let targetRangeString = element.firstElementChild(named: "table:target-range-address")?.attributes["table:cell-range-address"],
           let target = try? AddressParser.parseRange(targetRangeString) {
            outputSheet = target.sheet
            outputTopLeftCol = target.topLeft.col
            outputTopLeftRow = target.topLeft.row
        }

        var styleInfo: SheetPivotTableStyleInfo?
        if let styleName = element.attributes["tessera:style-name"] {
            styleInfo = SheetPivotTableStyleInfo(
                styleName: styleName,
                showRowHeaders: boolValue(element.attributes["tessera:style-show-row-headers"], default: true),
                showColumnHeaders: boolValue(element.attributes["tessera:style-show-column-headers"], default: true),
                showRowStripes: boolValue(element.attributes["tessera:style-show-row-stripes"], default: false),
                showColumnStripes: boolValue(element.attributes["tessera:style-show-column-stripes"], default: false),
                showLastColumn: boolValue(element.attributes["tessera:style-show-last-column"], default: false)
            )
        }

        let fields = element.elementChildren
            .filter { $0.name == "table:data-pilot-field" }
            .compactMap { pivotField(from: $0) }

        return SheetPivotDefinition(
            id: id,
            name: name,
            sheet: source.sheet,
            topLeftCol: source.topLeft.col,
            topLeftRow: source.topLeft.row,
            bottomRightCol: source.bottomRight.col,
            bottomRightRow: source.bottomRight.row,
            fields: fields,
            outputSheet: outputSheet,
            outputTopLeftCol: outputTopLeftCol,
            outputTopLeftRow: outputTopLeftRow,
            columnGrand: columnGrand,
            rowGrand: rowGrand,
            ignoreEmptyRows: boolValue(element.attributes["table:ignore-empty-rows"], default: false),
            repeatIfEmpty: boolValue(element.attributes["tessera:repeat-if-empty"], default: false),
            filterButton: boolValue(element.attributes["table:show-filter-button"], default: true),
            drillDown: boolValue(element.attributes["table:drill-down"], default: true),
            grandTotalName: element.attributes["tessera:grand-total-name"],
            styleInfo: styleInfo
        )
    }

    private static func pivotField(from element: FlatODFElement) -> SheetPivotField? {
        guard let fieldName = element.attributes["table:source-field-name"],
              let orientationRaw = element.attributes["table:orientation"],
              let orientation = SheetPivotFieldOrientation(rawValue: orientationRaw) else { return nil }
        let function = element.attributes["table:function"].flatMap { SheetPivotAggregation(rawValue: $0) }
        let showEmpty = boolValue(element.firstElementChild(named: "table:data-pilot-level")?.attributes["table:show-empty"], default: false)

        let subtotals = (element.firstElementChild(named: "table:data-pilot-subtotals")?.elementChildren ?? [])
            .compactMap { $0.attributes["table:function"].flatMap { SheetPivotAggregation(rawValue: $0) } }

        let members = (element.firstElementChild(named: "table:data-pilot-members")?.elementChildren ?? [])
            .compactMap { memberElement -> SheetPivotFieldMember? in
                guard let name = memberElement.attributes["table:name"] else { return nil }
                return SheetPivotFieldMember(name: name, visible: boolValue(memberElement.attributes["table:display"], default: true))
            }

        var autoShow: SheetPivotFieldAutoShow?
        if let displayInfo = element.firstElementChild(named: "table:data-pilot-display-info"),
           let dataFieldName = displayInfo.attributes["table:data-field"] {
            autoShow = SheetPivotFieldAutoShow(
                enabled: boolValue(displayInfo.attributes["table:enabled"], default: true),
                direction: displayInfo.attributes["table:display-member-mode"] == "from-bottom" ? .bottom : .top,
                itemCount: displayInfo.attributes["table:member-count"].flatMap { Int($0) } ?? 10,
                dataFieldName: dataFieldName
            )
        }

        var sort: SheetPivotFieldSort?
        if let sortInfo = element.firstElementChild(named: "table:data-pilot-sort-info") {
            sort = SheetPivotFieldSort(
                mode: sortInfo.attributes["tessera:sort-mode"].flatMap { SheetPivotSortMode(rawValue: $0) } ?? .name,
                ascending: sortInfo.attributes["table:order"] != "descending",
                dataFieldName: sortInfo.attributes["table:data-field"]
            )
        }

        var layout: SheetPivotFieldLayout?
        if let layoutInfo = element.firstElementChild(named: "table:data-pilot-layout-info") {
            layout = SheetPivotFieldLayout(
                mode: layoutInfo.attributes["table:layout-mode"].flatMap { SheetPivotFieldLayoutMode(rawValue: $0) } ?? .tabular,
                addEmptyLine: boolValue(layoutInfo.attributes["table:add-empty-lines"], default: false),
                subtotalsAtTop: boolValue(layoutInfo.attributes["tessera:subtotals-at-top"], default: true)
            )
        }

        let reference = element.firstElementChild(named: "table:data-pilot-field-reference")?
            .attributes["tessera:reference-type"].flatMap { SheetPivotReferenceMode(rawValue: $0) }

        let group = element.firstElementChild(named: "table:data-pilot-groups").flatMap { pivotGroupSpec(from: $0) }

        return SheetPivotField(
            fieldName: fieldName,
            orientation: orientation,
            function: function,
            subtotals: subtotals,
            subtotalAuto: boolValue(element.attributes["tessera:subtotal-auto"], default: true),
            showEmpty: showEmpty,
            repeatItemLabels: boolValue(element.attributes["tessera:repeat-item-labels"], default: false),
            layout: layout,
            members: members,
            sort: sort,
            autoShow: autoShow,
            reference: reference,
            group: group
        )
    }

    private static func pivotGroupSpec(from element: FlatODFElement) -> PivotGroupSpec? {
        switch element.attributes["tessera:group-by"] {
        case "numeric":
            guard let step = element.attributes["table:step"].flatMap(Double.init),
                  let start = element.attributes["table:start-value"].flatMap(Double.init),
                  let end = element.attributes["table:end-value"].flatMap(Double.init) else { return nil }
            return .numeric(start: start, end: end, step: step)
        case "date":
            let intervals = (element.attributes["tessera:date-intervals"] ?? "")
                .split(separator: ",")
                .compactMap { PivotDateGroupInterval(rawValue: String($0)) }
            return .date(by: Set(intervals))
        case "members":
            let groups = element.elementChildren
                .filter { $0.name == "table:data-pilot-group" }
                .compactMap { groupElement -> PivotMemberGroup? in
                    guard let name = groupElement.attributes["table:name"] else { return nil }
                    let members = groupElement.elementChildren
                        .filter { $0.name == "table:data-pilot-group-member" }
                        .compactMap { $0.attributes["table:name"] }
                    return PivotMemberGroup(name: name, members: members)
                }
            return .members(groups)
        default:
            return nil
        }
    }

    // MARK: - Small attribute helpers

    private static func boolAttr(_ value: Bool) -> String { value ? "true" : "false" }

    private static func boolValue(_ raw: String?, default defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        return raw == "true"
    }

    private static func grandTotalAttribute(columnGrand: Bool, rowGrand: Bool) -> String {
        switch (rowGrand, columnGrand) {
        case (true, true): return "both"
        case (true, false): return "row"
        case (false, true): return "column"
        case (false, false): return "none"
        }
    }

    private static func grandTotals(from raw: String?) -> (columnGrand: Bool, rowGrand: Bool) {
        switch raw {
        case "both": return (true, true)
        case "row": return (false, true)
        case "column": return (true, false)
        case "none": return (false, false)
        default: return (true, true) // SheetPivotDefinition's own documented default
        }
    }
}
