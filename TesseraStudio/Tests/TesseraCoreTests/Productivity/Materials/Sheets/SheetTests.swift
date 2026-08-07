import XCTest
@testable import TesseraCore

final class SheetTests: XCTestCase {

    // MARK: - JSON round-trip

    func testSheetRoundTripsJSON() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let original = Sheet(
            id: UUID(),
            title: "Budget 2026",
            body: .empty,
            columns: [SheetColumn(label: "A", type: .text), SheetColumn(label: "B", type: .number)],
            isArchived: false,
            isTrashed: false,
            isFavorite: true,
            tags: ["budget"],
            linkedEntityIDs: [UUID()],
            createdAt: date,
            updatedAt: date
        )
        let data = try original.jsonData()
        let decoded = try Sheet.from(jsonData: data)
        XCTAssertEqual(decoded, original)
    }

    func testEmptySheetRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let original = Sheet(id: UUID(), title: "", body: .empty, createdAt: date, updatedAt: date)
        let data = try original.jsonData()
        let decoded = try Sheet.from(jsonData: data)
        XCTAssertEqual(decoded, original)
    }

    func testSheetJSONStringRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let original = Sheet(id: UUID(), title: "Untitled", body: .empty, tags: ["x"], createdAt: date, updatedAt: date)
        let body = try original.jsonDataString()
        let decoded = try Sheet.from(jsonDataString: body)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Tag normalization

    func testNormalizeTagsLowercasesAndTrims() {
        XCTAssertEqual(Sheet.normalizeTags(["  Q3  ", "Review", "REVIEW", "  q3", "2026"]), ["q3", "review", "2026"])
    }

    func testNormalizeTagsDropsEmpties() {
        XCTAssertEqual(Sheet.normalizeTags(["", "  ", "valid"]), ["valid"])
    }

    func testNormalizeTagsPreservesOrder() {
        XCTAssertEqual(Sheet.normalizeTags(["b", "a", "c", "a"]), ["b", "a", "c"])
    }

    func testInitNormalizesTags() {
        let sheet = Sheet(tags: ["  Q3  ", "review", "Q3"])
        XCTAssertEqual(sheet.tags, ["q3", "review"])
    }

    // MARK: - Display title

    func testDisplayTitleFallsBackToUserTitle() {
        XCTAssertEqual(Sheet(title: "My Sheet", body: .empty).displayTitle, "My Sheet")
    }

    func testDisplayTitleFallsBackToUntitled() {
        XCTAssertEqual(Sheet(title: "", body: .empty).displayTitle, "Untitled")
    }

    func testDisplayTitleFallsBackToFirstHeading() {
        let hid = UUID()
        let sheet = Sheet(title: "", body: DocumentAST(blocks: [hid: Block(type: .heading, content: [InlineRun(text: "Auto")])], rootChildren: [hid]))
        XCTAssertEqual(sheet.displayTitle, "Auto")
    }

    // MARK: - makeBlank

    func testMakeBlankDimensions() {
        let sheet = Sheet.makeBlank(title: "T", rows: 3, cols: 4)
        XCTAssertEqual(sheet.rowCount, 3)
        XCTAssertEqual(sheet.columnCount, 4)
        XCTAssertEqual(sheet.cellCount, 12)
        XCTAssertEqual(sheet.columns.count, 4)
    }

    func testMakeBlankColumnLabels() {
        let sheet = Sheet.makeBlank(title: "T", rows: 1, cols: 3)
        XCTAssertEqual(sheet.columns[0].label, "A")
        XCTAssertEqual(sheet.columns[1].label, "B")
        XCTAssertEqual(sheet.columns[2].label, "C")
    }

    func testMakeBlankZeroRows() {
        let sheet = Sheet.makeBlank(title: "T", rows: 0, cols: 2)
        XCTAssertEqual(sheet.rowCount, 0)
        XCTAssertEqual(sheet.cellCount, 0)
    }

    // MARK: - Grid geometry

    func testRowColumnCountFromTable() {
        let sheet = Sheet.makeBlank(title: "T", rows: 2, cols: 3)
        XCTAssertEqual(sheet.rowCount, 2)
        XCTAssertEqual(sheet.columnCount, 3)
    }

    func testCellTextEmpty() {
        let sheet = Sheet.makeBlank(title: "T", rows: 2, cols: 2)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "")
    }

    func testCellCountEmptySheetIsZero() {
        XCTAssertEqual(Sheet(title: "T", body: .empty).cellCount, 0)
    }

    // MARK: - Entity type

    func testEntityTypeIsDocument() {
        XCTAssertEqual(Sheet.entityType, "document")
    }

    func testSubtypeIsSheet() {
        XCTAssertEqual(Sheet.subtype, "sheet")
    }

    // MARK: - SheetColumn

    func testSheetColumnDefaults() {
        let col = SheetColumn()
        XCTAssertEqual(col.label, "")
        XCTAssertNil(col.width)
        XCTAssertEqual(col.type, .text)
    }

    func testSheetColumnTypeRawValues() {
        XCTAssertEqual(SheetColumnType.text.rawValue, "text")
        XCTAssertEqual(SheetColumnType.number.rawValue, "number")
        XCTAssertEqual(SheetColumnType.date.rawValue, "date")
        XCTAssertEqual(SheetColumnType.checkbox.rawValue, "checkbox")
    }

    func testSheetColumnRoundTrips() throws {
        let col = SheetColumn(label: "Amount", width: 120, type: .number)
        let data = try JSONEncoder().encode(col)
        let decoded = try JSONDecoder().decode(SheetColumn.self, from: data)
        XCTAssertEqual(decoded, col)
    }

    // MARK: - Word count

    func testWordCountEmpty() {
        XCTAssertEqual(Sheet.wordCount(of: .empty), 0)
    }

    func testWordCountSimple() {
        let id = UUID()
        let ast = DocumentAST(blocks: [id: Block(type: .paragraph, content: [InlineRun(text: "hello world")])], rootChildren: [id])
        XCTAssertEqual(Sheet.wordCount(of: ast), 2)
    }

    // MARK: - Snippet

    func testSnippetEmptyAST() {
        XCTAssertEqual(Sheet.plainTextSnippet(from: .empty, maxLength: 200), "")
    }

    func testSnippetRespectsMaxLength() {
        let id = UUID()
        let long = String(repeating: "a", count: 500)
        let ast = DocumentAST(blocks: [id: Block(type: .paragraph, content: [InlineRun(text: long)])], rootChildren: [id])
        let snippet = Sheet.plainTextSnippet(from: ast, maxLength: 100)
        XCTAssertTrue(snippet.count <= 101)
        XCTAssertTrue(snippet.hasSuffix("…"))
    }
}
