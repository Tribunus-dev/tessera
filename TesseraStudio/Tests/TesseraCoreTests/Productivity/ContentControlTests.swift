import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ContentControlTests
//
// Contract: sota-enterprise-report.md's "2.15 Forms - content controls
// as Block attributes, not a Forms material" design position +
// ContentControl.swift's own doc comment (kind/tag/title/placeholder/
// listItems/locks/binding/value field list and the `value` field's
// judgment-call rationale) + Block.swift's `Block/contentControl`
// bridge doc comment (the NOT-gated-to-one-BlockType deviation and its
// exact eligible-type list). Doctrine rule 2 (round-trip identity
// triple), rule 7 (independent-oracle totality for the eligible-type
// gating list).

final class ContentControlTests: DoctrineTestCase {

    // MARK: - ContentControlKind totality (independent oracle, doctrine rule 7)

    func testContentControlKindHasExactlyTheSevenDocumentedCases() {
        // Hand-transcribed from the design contract's own field list
        // ("kind: richText|plainText|comboBox|dropDownList|datePicker|
        // checkBox|picture") - not ContentControlKind.allCases fed back
        // into itself.
        let expected: Set<String> = [
            "richText", "plainText", "comboBox", "dropDownList", "datePicker", "checkBox", "picture",
        ]
        XCTAssertEqual(Set(ContentControlKind.allCases.map(\.rawValue)), expected)
    }

    // MARK: - ContentControl round-trip identity (rule 2)

    func testContentControlEncodeDecodeIdentityWithOnlyRequiredFields() throws {
        let control = ContentControl(kind: .plainText, tag: "firstName")
        let data = try JSONEncoder().encode(control)
        let decoded = try JSONDecoder().decode(ContentControl.self, from: data)
        XCTAssertEqual(decoded, control)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.placeholder)
        XCTAssertTrue(decoded.listItems.isEmpty)
        XCTAssertEqual(decoded.locks, ContentControlLocks())
        XCTAssertNil(decoded.binding)
        XCTAssertNil(decoded.value)
    }

    func testContentControlEncodeDecodeIdentityWithEveryFieldPresentAcrossAllKinds() throws {
        let controls: [ContentControl] = [
            ContentControl(kind: .richText, tag: "bio", title: "Biography", placeholder: "Tell us about yourself"),
            ContentControl(kind: .plainText, tag: "firstName", title: "First name", value: nil),
            ContentControl(
                kind: .comboBox, tag: "country", listItems: ["USA", "Canada", "Mexico"],
                locks: ContentControlLocks(contentLocked: false, deletionLocked: true), value: "Canada"
            ),
            ContentControl(
                kind: .dropDownList, tag: "status", listItems: ["Draft", "Final"],
                binding: "/root/status", value: "Final"
            ),
            ContentControl(kind: .datePicker, tag: "signedOn", value: "2026-08-16"),
            ContentControl(
                kind: .checkBox, tag: "agree", locks: ContentControlLocks(contentLocked: true, deletionLocked: false), value: "true"
            ),
            ContentControl(kind: .picture, tag: "logo", value: "assets/logo.png"),
        ]
        for control in controls {
            let data = try JSONEncoder().encode(control)
            let decoded = try JSONDecoder().decode(ContentControl.self, from: data)
            XCTAssertEqual(decoded, control, "round trip must be identity for kind \(control.kind.rawValue)")
        }
    }

    func testContentControlLocksEncodeDecodeIdentity() throws {
        let locks = ContentControlLocks(contentLocked: true, deletionLocked: false)
        let data = try JSONEncoder().encode(locks)
        let decoded = try JSONDecoder().decode(ContentControlLocks.self, from: data)
        XCTAssertEqual(decoded, locks)
    }

    func testContentControlLocksDefaultsToBothUnlocked() {
        let locks = ContentControlLocks()
        XCTAssertFalse(locks.contentLocked)
        XCTAssertFalse(locks.deletionLocked)
    }

    // MARK: - Legacy-JSON back-compat: an old Block with no contentControl
    // attribute decodes to nil (doctrine rule 2's "legacy-JSON decode" leg)

    func testOldBlockJSONWithNoContentControlAttributeDecodesContentControlAsNil() throws {
        // Shaped exactly like a pre-2.15 `.paragraph` block on the wire -
        // no "contentControl" key anywhere in attributes, matching every
        // real document persisted before this wave.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","type":"paragraph","attributes":{},"content":[{"text":"hello","annotations":[]}],"children":[],"parentID":null}
        """
        let decoded = try JSONDecoder().decode(Block.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.contentControl, "a legacy block with no contentControl attribute must decode to nil, not throw or default to a synthesized control")
        XCTAssertEqual(decoded.content.first?.text, "hello", "sanity: the rest of the legacy block must still decode normally")
    }

    func testOldBlockJSONWithUnrelatedAttributesDecodesContentControlAsNilWithoutDisturbingThem() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","type":"heading","attributes":{"level":2},"content":[],"children":[],"parentID":null}
        """
        let decoded = try JSONDecoder().decode(Block.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.contentControl)
        XCTAssertEqual(decoded.attributes["level"]?.numberValue, 2, "an unrelated pre-existing attribute must survive untouched")
    }

    // MARK: - Block.contentControl bridge round-trip (mirrors Block.media's
    // own bridge-test duplication in MediaBlockTests.swift)

    func testBlockContentControlBridgeRoundTripsOnAnEligibleBlockType() {
        var block = Block(type: .paragraph)
        let control = ContentControl(kind: .plainText, tag: "firstName", placeholder: "Enter your name")

        block.contentControl = control

        XCTAssertEqual(block.contentControl, control)
        XCTAssertNotNil(block.attributes["contentControl"], "the bridge persists through attributes[\"contentControl\"]")
    }

    func testBlockContentControlBridgeClearsAttributeWhenSetToNil() {
        var block = Block(type: .tableCell)
        block.contentControl = ContentControl(kind: .checkBox, tag: "agree")
        XCTAssertNotNil(block.attributes["contentControl"])

        block.contentControl = nil

        XCTAssertNil(block.contentControl)
        XCTAssertNil(block.attributes["contentControl"])
    }

    func testBlockContentControlBridgeReadsNilWhenAttributesHaveNoContentControlKey() {
        let block = Block(type: .listItem)
        XCTAssertNil(block.contentControl, "an eligible block with no attributes[\"contentControl\"] yet is \"no control attached\", not corrupted data")
    }

    func testBlockContentControlBridgeIsNoOpOnAnIneligibleBlockType() {
        var block = Block(type: .table) // structural container - see Block.contentControlEligibleTypes
        block.contentControl = ContentControl(kind: .plainText, tag: "x")

        XCTAssertNil(block.contentControl, "reading .contentControl off an ineligible block type must return nil regardless of attributes contents")
        XCTAssertNil(block.attributes["contentControl"], "setting .contentControl on an ineligible block type must not write attributes either")
    }

    func testBlockContentControlBridgeReadsNilOnIneligibleBlockEvenIfAttributeWasSomehowPresent() {
        // Defensive: a block that carries the raw attribute key (e.g. an
        // imported/foreign document, or a type migrated away from
        // eligibility) but whose CURRENT type is ineligible must still
        // read nil - matching every other bridge's "type gate wins over
        // attribute presence" contract (Block/shape's own doc comment).
        var block = Block(type: .paragraph)
        block.contentControl = ContentControl(kind: .plainText, tag: "x")
        block.type = .divider // ineligible

        XCTAssertNil(block.contentControl)
    }

    // MARK: - Block.contentControlEligibleTypes totality (independent oracle,
    // doctrine rule 7) - pinned against the exact list this file's own
    // Block.swift doc comment names, not contentControlEligibleTypes fed
    // back into itself.

    func testContentControlEligibleTypesMatchesTheIndependentlyPinnedList() {
        let expectedEligible: Set<BlockType> = [.paragraph, .heading, .listItem, .tableCell, .quote, .callout]
        XCTAssertEqual(Block.contentControlEligibleTypes, expectedEligible)
    }

    func testEveryEligibleBlockTypeHostsAContentControlRoundTrip() {
        for type in Block.contentControlEligibleTypes {
            var block = Block(type: type)
            let control = ContentControl(kind: .plainText, tag: "field-\(type.rawValue)")
            block.contentControl = control
            XCTAssertEqual(block.contentControl, control, "eligible type \(type.rawValue) must host a content control")
        }
    }

    func testEveryIneligibleBlockTypeRejectsAContentControl() {
        let ineligible = Set(BlockType.allCases).subtracting(Block.contentControlEligibleTypes)
        for type in ineligible {
            var block = Block(type: type)
            block.contentControl = ContentControl(kind: .plainText, tag: "x")
            XCTAssertNil(block.contentControl, "ineligible type \(type.rawValue) must never host a content control")
        }
    }
}
