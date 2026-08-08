import XCTest
@testable import TesseraCore

@MainActor
final class DocEditorViewModelTests: XCTestCase {

    private func makeDoc(title: String = "Hello") -> Doc {
        Doc(title: title, body: .empty)
    }

    private func makeEditor(doc: Doc? = nil) -> DocEditorViewModel {
        let d = doc ?? makeDoc()
        return DocEditorViewModel(doc: d, store: DocStore(dataLayer: TesseraDataLayer()), userID: UUID())
    }

    func testInitialState() {
        let doc = makeDoc(title: "Hi")
        let editor = makeEditor(doc: doc)
        XCTAssertEqual(editor.doc.title, "Hi")
        XCTAssertEqual(editor.draftTitle, "Hi")
        XCTAssertEqual(editor.draftTag, "")
        XCTAssertFalse(editor.isSaving)
        XCTAssertNil(editor.lastError)
    }

    func testSetDocumentLocal() {
        let editor = makeEditor()
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "new")])
        ast.rootChildren = [bid]
        editor.setDocumentLocal(ast)
        XCTAssertEqual(editor.document, ast)
        // doc.body unchanged until commit
        XCTAssertEqual(editor.doc.body, .empty)
    }

    func testRefreshReplacesDoc() {
        let editor = makeEditor(doc: makeDoc(title: "old"))
        let newDoc = Doc(title: "new", body: .empty)
        editor.refresh(with: newDoc)
        XCTAssertEqual(editor.doc.title, "new")
        XCTAssertEqual(editor.draftTitle, "new")
    }

    func testDisplayTitleOnDoc() {
        XCTAssertEqual(Doc(title: "  hi  ", body: .empty).displayTitle, "hi")
    }
}
