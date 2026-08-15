import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - SlideDeckRendererTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4 "Slides cluster" item 1.7 ("one substrate... Test:
// deterministic bitmap for a title+content fixture slide") plus
// doctrine rule 4 (determinism first), rule 8 (content, not just
// survival). Per the task brief and
// docs/p1-post-claim-audit-2026-08-15.md item 1.7 ("NO builtin layout
// currently carries frameU geometry - all multi-slot layouts render
// overlapping default bands"), this file also carries the
// contract-true "non-overlapping bands" test, expected to fail.

final class SlideDeckRendererTests: DoctrineTestCase {

    // MARK: - Bitmap helpers

    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.deviceRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private func pixelBytes(_ context: CGContext) -> Data {
        Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }

    private func pixel(_ context: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let bytesPerPixel = 4
        let offset = y * context.bytesPerRow + x * bytesPerPixel
        let ptr = context.data!.assumingMemoryBound(to: UInt8.self)
        return (ptr[offset], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
    }

    /// XCTAssertEqual's `accuracy:` overload requires `FloatingPoint`,
    /// which `UInt8` is not - this does the same "within tolerance"
    /// check for the raw pixel-byte comparisons below.
    private func assertApprox(_ actual: UInt8, _ expected: UInt8, tolerance: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(Int(actual) - Int(expected)), tolerance, "expected \(actual) to be within \(tolerance) of \(expected)", file: file, line: line)
    }

    private func titleContentDeck() -> SlideDeck {
        var deck = SlideDeck.makeEmpty(title: "Fixture Deck")
        deck = deck.insertingSlide(at: 0, layout: .title, title: "Hello")
        var master = SlideMasterPage(name: "Main", backgroundColorHex: .literal("#336699"))
        deck = deck.settingMasterPage(master)
        master = deck.effectiveMasterPages[master.id.uuidString]!
        deck.slideMeta[deck.body.rootChildren[0].uuidString] = SlideMeta(layout: .title, masterPageID: master.id)
        return deck
    }

    // MARK: - Determinism (rule 4) - FIRST, before any content assertion

    func testTwoIndependentRenderPassesOfTheSameSlideProduceByteIdenticalBitmaps() {
        let deck = titleContentDeck()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        let contextA = makeContext(width: 100, height: 100)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: contextA, rect: rect)

        let contextB = makeContext(width: 100, height: 100)
        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: contextB, rect: rect)

        XCTAssertEqual(pixelBytes(contextA), pixelBytes(contextB))
    }

    // MARK: - Content (rule 8) - known pixel coordinates, not just "did not crash"

    func testTitleSlideBackgroundPaintsTheResolvedMasterBackgroundColor() {
        let deck = titleContentDeck()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = makeContext(width: 100, height: 100)

        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: rect)

        // A corner far from the title placeholder's default band
        // (0.06, 0.05, 0.88, 0.16) must still show the plain background
        // fill: #336699 = (51, 102, 153).
        let corner = pixel(context, x: 2, y: 90)
        assertApprox(corner.r, 51)
        assertApprox(corner.g, 102)
        assertApprox(corner.b, 153)
    }

    func testSlideWithNoMasterPagePaintsPlainWhiteBackground() {
        var deck = SlideDeck.makeEmpty(title: "No Master")
        deck = deck.insertingSlide(at: 0, layout: .blank)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let context = makeContext(width: 40, height: 40)

        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: rect)

        let corner = pixel(context, x: 1, y: 1)
        assertApprox(corner.r, 255)
        assertApprox(corner.g, 255)
        assertApprox(corner.b, 255)
    }

    // MARK: - Degenerate inputs (renderer coverage shape: empty, zero rect)

    func testRenderingAnOutOfRangeSlideIndexDoesNothingToTheContext() {
        let deck = titleContentDeck()
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let context = makeContext(width: 20, height: 20)
        let before = pixelBytes(context)

        SlideDeckRenderer().render(deck: deck, slideIndex: 99, in: context, rect: rect)

        XCTAssertEqual(pixelBytes(context), before, "an out-of-range slide index must leave the context untouched")
    }

    func testRenderingIntoAZeroSizedRectDoesNotCrashAndLeavesContextUntouched() {
        let deck = titleContentDeck()
        let context = makeContext(width: 10, height: 10)
        let before = pixelBytes(context)

        SlideDeckRenderer().render(deck: deck, slideIndex: 0, in: context, rect: .zero)

        XCTAssertEqual(pixelBytes(context), before)
    }

    // MARK: - resolveFrame: SUSPECTED CODE BUG (frameU gap -> overlapping bands)

    func testMultiSlotLayoutPlaceholdersResolveToNonOverlappingFrames() {
        // "twoContent": heading@0, paragraph@1 ("Content Left"),
        // paragraph@2 ("Content Right") - two SAME-TYPE content slots
        // that must occupy visually distinct regions once frameU exists.
        let spec = SlideLayoutSpec.builtins.first { $0.id == "twoContent" }!
        let targetSlots = SlideDeckRenderer.flattenedSlots(of: spec)
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        let leftBlock = Block(type: .paragraph)
        let rightBlock = Block(type: .paragraph)

        let leftFrame = SlideDeckRenderer.resolveFrame(for: leftBlock, at: 1, targetSlots: targetSlots, rect: rect)
        let rightFrame = SlideDeckRenderer.resolveFrame(for: rightBlock, at: 2, targetSlots: targetSlots, rect: rect)

        XCTExpectFailure("SUSPECTED CODE BUG: multi-slot layouts render overlapping default bands because no builtin SlideLayoutSpec placeholder carries frameU (both same-type content slots fall back to the identical defaultFrameU(for:) rect) - contract: studio-expansion-design-refinement-2026-08-14.md section 4 Slides cluster item 1.7. Confirmed via docs/p1-post-claim-audit-2026-08-15.md item 1.7.") {
            XCTAssertNotEqual(leftFrame, rightFrame, "Content Left and Content Right must resolve to different frames, not the identical default band")
        }
    }
}
