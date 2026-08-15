import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - SlideLayoutSpecTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4 "Slides cluster" item 1.9 ("extend SlideLayoutSpec.builtins
// with the LO AutoLayout catalog (~25) as DATA; add idx... apply-layout
// is ONE receipted mutation matching blocks by idx then type, NEVER
// deleting unmatched content") and item 1.7 ("SlideLayoutSpec gains
// optional normalized frameU rects on placeholders").

final class SlideLayoutSpecTests: DoctrineTestCase {

    // MARK: - Catalog size (~25, per the design contract)

    func testBuiltinsCatalogHasExactlyTwentyFiveEntries() {
        // 4 SlideLayout-backed defaults + 21 AutoLayout catalog entries.
        XCTAssertEqual(SlideLayoutSpec.builtins.count, 25)
    }

    func testBuiltinsHaveNoDuplicateIDs() {
        let ids = SlideLayoutSpec.builtins.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryFourSlideLayoutCasesHasAMatchingBuiltinID() {
        let builtinIDs = Set(SlideLayoutSpec.builtins.map(\.id))
        for layout in SlideLayout.allCases {
            XCTAssertTrue(builtinIDs.contains(layout.rawValue), "SlideLayout.\(layout) must have a matching builtin entry (default(for:) depends on it)")
        }
    }

    func testDefaultForEachSlideLayoutCaseReturnsTheMatchingBuiltin() {
        XCTAssertEqual(SlideLayoutSpec.default(for: .title).id, SlideLayout.title.rawValue)
        XCTAssertEqual(SlideLayoutSpec.default(for: .titleAndContent).id, SlideLayout.titleAndContent.rawValue)
        XCTAssertEqual(SlideLayoutSpec.default(for: .image).id, SlideLayout.image.rawValue)
        XCTAssertEqual(SlideLayoutSpec.default(for: .blank).id, SlideLayout.blank.rawValue)
    }

    // MARK: - idx identity (scoped per spec, per SlideLayoutPlaceholder's doc comment)

    func testEveryContentSlotWithinASpecHasAUniqueIdx() {
        for spec in SlideLayoutSpec.builtins {
            let slots = contentSlots(of: spec)
            let idxValues = slots.compactMap(\.idx)
            XCTAssertEqual(idxValues.count, slots.count, "\(spec.id): every content slot must carry an idx")
            XCTAssertEqual(idxValues.count, Set(idxValues).count, "\(spec.id): idx values must be unique within the spec")
        }
    }

    func testToggleWrapperPlaceholdersAreNeverThemselvesAContentSlot() {
        // ".toggle is reserved for the wrapping container, never a
        // content slot" - SlideLayoutSpec.swift's own doc comment.
        for spec in SlideLayoutSpec.builtins {
            for placeholder in spec.placeholders where placeholder.blockType == .toggle {
                XCTAssertFalse(placeholder.children.isEmpty, "\(spec.id): a .toggle root with no children would itself be an (invalid) content slot")
            }
        }
    }

    // MARK: - frameU (SUSPECTED CODE BUG, per task brief + audit item 1.7)

    func testAllBuiltinSlideLayoutPlaceholdersHaveFrameU() {
        let allSlots = SlideLayoutSpec.builtins.flatMap(contentSlots(of:))
        let missingFrameU = allSlots.filter { $0.frameU == nil }

        XCTAssertTrue(missingFrameU.isEmpty, "\(missingFrameU.count) of \(allSlots.count) content slots have no frameU")
    }

    // MARK: - Round trip (rule 2)

    func testSlideLayoutPlaceholderEncodeDecodeIsIdentityIncludingFrameU() throws {
        let placeholder = SlideLayoutPlaceholder(
            blockType: .heading, idx: 0, name: "Title",
            frameU: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2)
        )
        let data = try JSONEncoder().encode(placeholder)
        let decoded = try JSONDecoder().decode(SlideLayoutPlaceholder.self, from: data)
        XCTAssertEqual(decoded, placeholder)
    }

    func testSlideLayoutSpecEncodeDecodeIsIdentity() throws {
        let spec = SlideLayoutSpec.titleAndContent
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(SlideLayoutSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }

    // MARK: - Helper

    /// The leaf content slots of a spec: its single top-level
    /// placeholder's children when it wraps any, else the placeholder
    /// itself - mirrors SlideStore.applyingLayout's own `targetSlots`
    /// derivation (matching this cluster's understanding of the
    /// contract, not a copy of private implementation logic - the
    /// shape is stated in this type's own header comment: "every
    /// SlideLayoutSpec.builtins entry has exactly one top-level
    /// placeholder").
    private func contentSlots(of spec: SlideLayoutSpec) -> [SlideLayoutPlaceholder] {
        guard let top = spec.placeholders.first else { return [] }
        return top.children.isEmpty ? [top] : top.children
    }
}
