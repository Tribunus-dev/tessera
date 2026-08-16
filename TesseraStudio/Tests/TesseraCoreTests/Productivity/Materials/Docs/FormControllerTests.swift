import XCTest
import Foundation
@testable import TesseraCore

// MARK: - FormControllerTests
//
// Contract: sota-enterprise-report.md's "2.15 Forms" design position
// ("fill(_:in:value:) -> Block pure function resolving a content
// control's current value ... plainText/richText writes to
// block.content, checkBox/dropDownList writes a value into the
// ContentControl's own state"; "formFields(in ast: DocumentAST) ->
// [(blockID: UUID, control: ContentControl)] - lists every content
// control in a document"; "implement a MINIMAL XPath subset sufficient
// for simple element/attribute paths") + FormController.swift's own
// file header (the exact per-kind validation rules, the "which part
// wins" binding scope limit, and the documented XPath grammar). Doctrine
// rule 4 (determinism/idempotence), rule 9 (fixtures for engine math -
// here, the XPath grammar).
//
// FormController itself is pure (no DocStore); "DocStore integration is
// a separate step" per FieldController.swift's own doctrine, followed
// here exactly (this file never touches a store).

final class FormControllerTests: DoctrineTestCase {

    private func hostBlock(type: BlockType = .paragraph, id: UUID = UUID(), content: [InlineRun] = [], control: ContentControl) -> Block {
        var block = Block(id: id, type: type, content: content)
        block.contentControl = control
        return block
    }

    // MARK: - fill: .plainText / .richText write to block.content

    func testFillPlainTextReplacesHostBlockContent() {
        let block = hostBlock(control: ContentControl(kind: .plainText, tag: "firstName"))
        let filled = FormController.fill(block, in: .empty, value: "Ada Lovelace")

        XCTAssertEqual(filled.content, [InlineRun(text: "Ada Lovelace")])
        XCTAssertNil(filled.contentControl?.value, "text kinds must never write ContentControl.value")
    }

    func testFillRichTextReplacesHostBlockContentAsPlainRun() {
        // Documented P2-D simplification (file header): richText writes
        // plain InlineRun text, no run-level formatting parsed from the
        // input string.
        let block = hostBlock(control: ContentControl(kind: .richText, tag: "bio"))
        let filled = FormController.fill(block, in: .empty, value: "Loves math.")

        XCTAssertEqual(filled.content, [InlineRun(text: "Loves math.")])
    }

    func testFillPlainTextOverwritesPriorSurroundingContent() {
        var block = hostBlock(content: [InlineRun(text: "placeholder")], control: ContentControl(kind: .plainText, tag: "x"))
        block = FormController.fill(block, in: .empty, value: "new value")
        XCTAssertEqual(block.content, [InlineRun(text: "new value")])
    }

    func testFillPlainTextIsIdempotentWhenValueUnchanged() {
        let block = hostBlock(control: ContentControl(kind: .plainText, tag: "x"))
        let once = FormController.fill(block, in: .empty, value: "same")
        let twice = FormController.fill(once, in: .empty, value: "same")
        XCTAssertEqual(once, twice, "refilling an unchanged value must be a byte-identical no-op")
    }

    // MARK: - fill: .dropDownList requires exact listItems membership; state, not content

    func testFillDropDownListWithValidListItemStoresValueOnControlNotContent() {
        let label = [InlineRun(text: "Choose a plan:")]
        var block = hostBlock(content: label, control: ContentControl(kind: .dropDownList, tag: "plan", listItems: ["Free", "Pro", "Enterprise"]))
        block = FormController.fill(block, in: .empty, value: "Pro")

        XCTAssertEqual(block.contentControl?.value, "Pro")
        XCTAssertEqual(block.content, label, "the host block's own surrounding text must be untouched")
    }

    func testFillDropDownListWithValueNotInListItemsIsNoOp() {
        let block = hostBlock(control: ContentControl(kind: .dropDownList, tag: "plan", listItems: ["Free", "Pro"]))
        let filled = FormController.fill(block, in: .empty, value: "Enterprise")
        XCTAssertEqual(filled, block, "a value outside listItems must leave the block byte-for-byte unchanged")
    }

    func testFillDropDownListIsCaseSensitiveMembership() {
        let block = hostBlock(control: ContentControl(kind: .dropDownList, tag: "plan", listItems: ["Pro"]))
        let filled = FormController.fill(block, in: .empty, value: "pro")
        XCTAssertEqual(filled, block, "membership check is case-sensitive - documented per this file's own header")
    }

    func testFillDropDownListIsIdempotentWhenValueUnchanged() {
        let block = hostBlock(control: ContentControl(kind: .dropDownList, tag: "plan", listItems: ["Pro"]))
        let once = FormController.fill(block, in: .empty, value: "Pro")
        let twice = FormController.fill(once, in: .empty, value: "Pro")
        XCTAssertEqual(once, twice)
    }

    // MARK: - fill: .comboBox accepts free entry even off listItems

    func testFillComboBoxAcceptsValueNotInListItems() {
        let block = hostBlock(control: ContentControl(kind: .comboBox, tag: "country", listItems: ["USA", "Canada"]))
        let filled = FormController.fill(block, in: .empty, value: "Custom Value")
        XCTAssertEqual(filled.contentControl?.value, "Custom Value", "comboBox must accept free-entry text, unlike dropDownList")
    }

    // MARK: - fill: .checkBox accepts exactly "true"/"false"

    func testFillCheckBoxAcceptsTrueAndFalse() {
        let block = hostBlock(control: ContentControl(kind: .checkBox, tag: "agree"))
        let checked = FormController.fill(block, in: .empty, value: "true")
        XCTAssertEqual(checked.contentControl?.value, "true")
        let unchecked = FormController.fill(checked, in: .empty, value: "false")
        XCTAssertEqual(unchecked.contentControl?.value, "false")
    }

    func testFillCheckBoxRejectsAnyOtherValue() {
        let block = hostBlock(control: ContentControl(kind: .checkBox, tag: "agree"))
        let filled = FormController.fill(block, in: .empty, value: "yes")
        XCTAssertEqual(filled, block, "checkBox only accepts the literal strings \"true\"/\"false\"")
    }

    // MARK: - fill: .datePicker / .picture accept any string verbatim (state, not content)

    func testFillDatePickerStoresRawDateStringVerbatim() {
        let block = hostBlock(control: ContentControl(kind: .datePicker, tag: "signedOn"))
        let filled = FormController.fill(block, in: .empty, value: "2026-08-16")
        XCTAssertEqual(filled.contentControl?.value, "2026-08-16")
        XCTAssertTrue(filled.content.isEmpty)
    }

    func testFillPictureStoresOpaqueReferenceString() {
        let block = hostBlock(control: ContentControl(kind: .picture, tag: "logo"))
        let filled = FormController.fill(block, in: .empty, value: "assets/logo.png")
        XCTAssertEqual(filled.contentControl?.value, "assets/logo.png")
    }

    // MARK: - fill: locked controls are unconditional no-ops

    func testFillIsNoOpOnContentLockedTextControl() {
        let block = hostBlock(control: ContentControl(kind: .plainText, tag: "x", locks: ContentControlLocks(contentLocked: true)))
        let filled = FormController.fill(block, in: .empty, value: "attempted change")
        XCTAssertEqual(filled, block)
    }

    func testFillIsNoOpOnContentLockedCheckBox() {
        let block = hostBlock(control: ContentControl(kind: .checkBox, tag: "agree", locks: ContentControlLocks(contentLocked: true)))
        let filled = FormController.fill(block, in: .empty, value: "true")
        XCTAssertEqual(filled, block, "contentLocked gates every kind, not just text kinds")
    }

    // MARK: - fill: no-op when there is nothing to fill

    func testFillIsNoOpOnBlockWithNoContentControlAttached() {
        let block = Block(type: .paragraph, content: [InlineRun(text: "plain prose")])
        let filled = FormController.fill(block, in: .empty, value: "x")
        XCTAssertEqual(filled, block)
    }

    func testFillIsNoOpOnIneligibleBlockTypeEvenIfControlWasSomehowAttached() {
        // Block.contentControl's own bridge already gates this off - fill
        // composes on top of it rather than re-checking BlockType itself.
        var block = Block(type: .paragraph)
        block.contentControl = ContentControl(kind: .plainText, tag: "x")
        block.type = .table // ineligible - see Block.contentControlEligibleTypes
        let filled = FormController.fill(block, in: .empty, value: "y")
        XCTAssertEqual(filled, block)
    }

    // MARK: - resolvedValue(for:hostBlock:)

    func testResolvedValueForTextKindsReadsHostBlockContent() {
        let control = ContentControl(kind: .plainText, tag: "x")
        let block = Block(type: .paragraph, content: [InlineRun(text: "hello "), InlineRun(text: "world")])
        XCTAssertEqual(FormController.resolvedValue(for: control, hostBlock: block), "hello world")
    }

    func testResolvedValueForTextKindsWithEmptyContentIsNil() {
        let control = ContentControl(kind: .plainText, tag: "x")
        XCTAssertNil(FormController.resolvedValue(for: control, hostBlock: Block(type: .paragraph)))
    }

    func testResolvedValueForTextKindsWithNoHostBlockIsNil() {
        let control = ContentControl(kind: .plainText, tag: "x")
        XCTAssertNil(FormController.resolvedValue(for: control, hostBlock: nil))
    }

    func testResolvedValueForStateKindsReadsControlValueIgnoringHostBlock() {
        let control = ContentControl(kind: .checkBox, tag: "agree", value: "true")
        XCTAssertEqual(FormController.resolvedValue(for: control, hostBlock: nil), "true")
        XCTAssertEqual(FormController.resolvedValue(for: control, hostBlock: Block(type: .paragraph, content: [InlineRun(text: "unrelated")])), "true")
    }

    // MARK: - formFields(in:) lists every control in document order

    func testFormFieldsListsEveryControlInDocumentOrder() {
        let paraID = UUID()
        var para = Block(id: paraID, type: .paragraph)
        para.contentControl = ContentControl(kind: .plainText, tag: "first")

        let cellID = UUID()
        var cell = Block(id: cellID, type: .tableCell, parentID: nil)
        cell.contentControl = ContentControl(kind: .plainText, tag: "second")
        let tableID = UUID()
        let table = Block(id: tableID, type: .table, children: [cellID])

        let itemID = UUID()
        var item = Block(id: itemID, type: .listItem)
        item.contentControl = ContentControl(kind: .plainText, tag: "third")
        let listID = UUID()
        let list = Block(id: listID, type: .list, children: [itemID])

        let uncontrolledID = UUID()
        let uncontrolled = Block(id: uncontrolledID, type: .paragraph, content: [InlineRun(text: "no control here")])

        var ast = DocumentAST()
        ast.blocks[paraID] = para
        ast.blocks[tableID] = table
        ast.blocks[cellID] = cell
        ast.blocks[listID] = list
        ast.blocks[itemID] = item
        ast.blocks[uncontrolledID] = uncontrolled
        ast.rootChildren = [paraID, tableID, listID, uncontrolledID]

        let fields = FormController.formFields(in: ast)

        XCTAssertEqual(fields.map(\.blockID), [paraID, cellID, itemID], "must walk depth-first, skipping blocks with no control")
        XCTAssertEqual(fields.map { $0.control.tag }, ["first", "second", "third"])
    }

    func testFormFieldsReturnsEmptyForADocumentWithNoControls() {
        var ast = DocumentAST()
        let id = UUID()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "plain")])
        ast.rootChildren = [id]
        XCTAssertTrue(FormController.formFields(in: ast).isEmpty)
    }

    // MARK: - formData(in:) derived tag -> value view (doctrine rule 3)

    func testFormDataAggregatesTagToResolvedValueSkippingUnfilledControls() {
        let filledID = UUID()
        var filled = Block(id: filledID, type: .paragraph, content: [InlineRun(text: "Ada")])
        filled.contentControl = ContentControl(kind: .plainText, tag: "firstName")

        let unfilledID = UUID()
        var unfilled = Block(id: unfilledID, type: .paragraph)
        unfilled.contentControl = ContentControl(kind: .dropDownList, tag: "plan", listItems: ["Free", "Pro"])

        var ast = DocumentAST()
        ast.blocks[filledID] = filled
        ast.blocks[unfilledID] = unfilled
        ast.rootChildren = [filledID, unfilledID]

        let data = FormController.formData(in: ast)

        XCTAssertEqual(data, ["firstName": "Ada"], "an unfilled control must be ABSENT from the map, not present with an empty string")
    }

    func testFormDataReDerivesAfterAFillRatherThanCachingAnything() {
        let id = UUID()
        var block = Block(id: id, type: .paragraph)
        block.contentControl = ContentControl(kind: .plainText, tag: "x")
        var ast = DocumentAST()
        ast.blocks[id] = block
        ast.rootChildren = [id]

        XCTAssertEqual(FormController.formData(in: ast), [:])

        ast.blocks[id] = FormController.fill(block, in: ast, value: "filled")
        XCTAssertEqual(FormController.formData(in: ast), ["x": "filled"])
    }

    // MARK: - FormBindingResolver: XPath subset over a hand-built custom-XML fixture
    //
    // PROVENANCE: both fixtures below are HAND-BUILT for this test file,
    // shaped after the VSTO "bind content controls to custom XML parts"
    // walkthrough cited in ContentControl.swift's own header
    // (learn.microsoft.com/en-us/visualstudio/vsto/walkthrough-binding-
    // content-controls-to-custom-xml-parts, also sota-enterprise-report.
    // md's 2.15 evidence) - they are NOT extracted from a real produced
    // .docx's customXml/itemN.xml part. Stated plainly per this wave's
    // brief ("document their provenance honestly").

    private let employeeFixture = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <employee>
      <name>Ada Lovelace</name>
      <department>Engineering</department>
    </employee>
    """.utf8)

    private let fieldListFixture = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <root>
      <field id="a">Alpha</field>
      <field id="b">Beta</field>
    </root>
    """.utf8)

    private func parsedEmployee() -> CustomXMLElement {
        guard let root = CustomXMLParser.parse(employeeFixture) else {
            XCTFail("employeeFixture must parse")
            return CustomXMLElement(name: "", attributes: [:], children: [], text: "")
        }
        return root
    }

    private func parsedFieldList() -> CustomXMLElement {
        guard let root = CustomXMLParser.parse(fieldListFixture) else {
            XCTFail("fieldListFixture must parse")
            return CustomXMLElement(name: "", attributes: [:], children: [], text: "")
        }
        return root
    }

    func testXPathResolvesSimpleElementPath() {
        let root = parsedEmployee()
        XCTAssertEqual(FormBindingResolver.resolve("/employee/name", against: root), "Ada Lovelace")
        XCTAssertEqual(FormBindingResolver.resolve("/employee/department", against: root), "Engineering")
    }

    func testXPathResolvesToNilForAMissingElement() {
        let root = parsedEmployee()
        XCTAssertNil(FormBindingResolver.resolve("/employee/missing", against: root))
    }

    func testXPathResolvesAttributeEqualityPredicate() {
        let root = parsedFieldList()
        XCTAssertEqual(FormBindingResolver.resolve("/root/field[@id='b']", against: root), "Beta")
        XCTAssertEqual(FormBindingResolver.resolve("/root/field[@id='a']", against: root), "Alpha")
    }

    func testXPathResolvesToNilWhenNoSiblingMatchesThePredicate() {
        let root = parsedFieldList()
        XCTAssertNil(FormBindingResolver.resolve("/root/field[@id='z']", against: root))
    }

    func testXPathResolvesFinalAttributeStep() {
        let root = parsedFieldList()
        XCTAssertEqual(FormBindingResolver.resolve("/root/field[@id='b']/@id", against: root), "b")
    }

    func testXPathWithNoPredicateSelectsTheFirstMatchingSibling() {
        let root = parsedFieldList()
        XCTAssertEqual(FormBindingResolver.resolve("/root/field/@id", against: root), "a", "no predicate - first \"field\" child wins")
    }

    func testXPathRejectsRelativePaths() {
        let root = parsedEmployee()
        XCTAssertNil(FormBindingResolver.resolve("employee/name", against: root))
    }

    func testXPathRejectsDoubleSlash() {
        let root = parsedEmployee()
        XCTAssertNil(FormBindingResolver.resolve("//employee/name", against: root))
    }

    func testXPathRejectsPredicateFunctions() {
        let root = parsedFieldList()
        XCTAssertNil(FormBindingResolver.resolve("/root/field[contains(@id,'a')]", against: root))
    }

    func testXPathRejectsMultiplePredicatesOnOneStep() {
        let root = parsedFieldList()
        XCTAssertNil(FormBindingResolver.resolve("/root/field[@id='b'][@x='y']", against: root))
    }

    func testXPathRejectsAttributeStepThatIsNotFinal() {
        let root = parsedFieldList()
        XCTAssertNil(FormBindingResolver.resolve("/root/@id/field", against: root))
    }

    func testXPathRejectsWrongRootName() {
        let root = parsedEmployee()
        XCTAssertNil(FormBindingResolver.resolve("/notEmployee/name", against: root))
    }

    // MARK: - FormBindingResolver.resolve(_:in:) - end-to-end through PreservedParts

    func testResolveBindingFindsValueInACustomXMLPreservedPart() {
        var parts = PreservedParts()
        parts["customXml/item1.xml"] = fieldListFixture
        let control = ContentControl(kind: .plainText, tag: "x", binding: "/root/field[@id='b']")

        XCTAssertEqual(FormBindingResolver.resolve(control, in: parts), "Beta")
    }

    func testResolveBindingReturnsNilWhenControlHasNoBinding() {
        var parts = PreservedParts()
        parts["customXml/item1.xml"] = fieldListFixture
        let control = ContentControl(kind: .plainText, tag: "x")

        XCTAssertNil(FormBindingResolver.resolve(control, in: parts))
    }

    func testResolveBindingReturnsNilWhenNoCustomXMLPartExists() {
        let control = ContentControl(kind: .plainText, tag: "x", binding: "/root/field[@id='b']")
        XCTAssertNil(FormBindingResolver.resolve(control, in: PreservedParts()))
    }

    func testResolveBindingReturnsNilWhenThePreservedPartIsMalformedXML() {
        var parts = PreservedParts()
        parts["customXml/item1.xml"] = Data("<not><valid".utf8)
        let control = ContentControl(kind: .plainText, tag: "x", binding: "/root/field[@id='b']")

        XCTAssertNil(FormBindingResolver.resolve(control, in: parts))
    }

    func testResolveBindingIgnoresNonCustomXMLParts() {
        var parts = PreservedParts()
        // A VBA project binary sits alongside the custom XML part in the
        // same PreservedParts value (both 2.13 and 2.15 share the
        // mechanism) - the binding resolver must skip anything outside
        // "customXml/*.xml".
        parts["word/vbaProject.bin"] = Data([0x00, 0x01, 0x02])
        parts["customXml/item1.xml"] = fieldListFixture
        let control = ContentControl(kind: .plainText, tag: "x", binding: "/root/field[@id='a']")

        XCTAssertEqual(FormBindingResolver.resolve(control, in: parts), "Alpha")
    }
}
