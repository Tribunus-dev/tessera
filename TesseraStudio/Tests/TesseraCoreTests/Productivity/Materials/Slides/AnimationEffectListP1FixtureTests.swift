import XCTest
@testable import TesseraCore

// MARK: - AnimationEffectListP1FixtureTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4,
// "Slides cluster" (via sota-writer-slides-report.md #8), the P1 item
// 1.20 AnimationEffectList entry:
//   "Schema (flat, per slide) ... Serialization contract (provable tree
//   projection) ... P1 contract test (required): commit fixture
//   Tests/.../Fixtures/animation-effect-list-p1.json (multiple click
//   groups, all three triggers, nonzero delays). Test 1 (P1): fixture
//   decodes and canonical re-encode is byte-identical. Test 2 (written at
//   P1, asserting the P2 name):
//   SMILAnimationTree(flat: decoded).flattened() == decoded - checked in
//   disabled/pending at P1, turned on at P2; the fixture file itself must
//   never be edited at P2 (load-compat is the contract)."
//
// AnimationEffectList.swift's own doc comment additionally pins the exact
// future test name this file preserves:
// `AnimationEffectListTests.testSMILAnimationTreeFlatInitializerWillExist`.
//
// This file is the ONE pre-resolved exception into a different cluster's
// (Slides) territory for this wave - see the dispatch brief. Nothing else
// under Materials/Slides/ is touched here.
//
// The pinned fixture (`Fixtures/animation-effect-list-p1.json`) is a data
// contract per doctrine bookkeeping: read-only, never edited by this file.

final class AnimationEffectListP1FixtureTests: DoctrineTestCase {

    private func fixtureURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/Productivity/Materials/Slides/<this file>
        // -> Tests/TesseraCoreTests/Fixtures/animation-effect-list-p1.json
        let testsRoot = thisFile
            .deletingLastPathComponent() // <this file> -> Slides/
            .deletingLastPathComponent() // Slides -> Materials/
            .deletingLastPathComponent() // Materials -> Productivity/
            .deletingLastPathComponent() // Productivity -> TesseraCoreTests/
        return testsRoot.appendingPathComponent("Fixtures/animation-effect-list-p1.json")
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL())
    }

    // MARK: - Test 1 (P1, required): fixture decodes, canonical re-encode is byte-identical

    func testFixtureDecodesAndCanonicalReencodeIsByteIdentical() throws {
        let original = try fixtureData()
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: original)

        XCTAssertEqual(decoded.count, 5, "the pinned fixture carries 5 effects across multiple click groups")
        XCTAssertTrue(decoded.contains { $0.trigger == .onClick }, "fixture must exercise .onClick")
        XCTAssertTrue(decoded.contains { $0.trigger == .withPrevious }, "fixture must exercise .withPrevious")
        XCTAssertTrue(decoded.contains { $0.trigger == .afterPrevious }, "fixture must exercise .afterPrevious")
        XCTAssertTrue(decoded.contains { $0.delayMS > 0 }, "fixture must exercise at least one nonzero delay")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(decoded)

        XCTAssertEqual(reencoded, original, "decode -> canonical re-encode must reproduce the pinned fixture's bytes exactly")
    }

    // MARK: - Grouping is derived from trigger order (never stored) -
    // the property the P1 schema's design note credits with making the
    // P2 tree constructor total.

    /// "every .onClick effect starts a new group; every .withPrevious/
    /// .afterPrevious effect belongs to the group opened by the nearest
    /// preceding .onClick effect; a non-empty list's first effect must be
    /// .onClick" - the exact grouping rule from AnimationEffectList.swift's
    /// header, independently re-derived here (not by calling any grouping
    /// helper on the type, since none exists yet at P1) as the oracle for
    /// the fixture's own shape.
    func testFixtureFirstEffectIsOnClickPerTheGroupingRule() throws {
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: try fixtureData())
        XCTAssertEqual(decoded.first?.trigger, .onClick,
                        "a non-empty AnimationEffectList's first effect must be .onClick - a follower with nothing preceding it has no group to join")
    }

    func testFixtureEveryWithPreviousOrAfterPreviousEffectHasAPrecedingOnClickInTheSameList() throws {
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: try fixtureData())
        var sawOnClick = false
        for effect in decoded {
            switch effect.trigger {
            case .onClick:
                sawOnClick = true
            case .withPrevious, .afterPrevious:
                XCTAssertTrue(sawOnClick, "a follower trigger must have a preceding .onClick opening its group somewhere earlier in array order")
            }
        }
    }

    // MARK: - Round-trip identity (doctrine rule 2) on a hand-built value,
    // independent of the pinned fixture.

    func testAnimationEffectEncodeDecodeIdentity() throws {
        let effect = AnimationEffect(
            targetBlockID: UUID(),
            presetID: "fade-in",
            trigger: .withPrevious,
            durationMS: 300,
            delayMS: 50
        )
        let data = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(AnimationEffect.self, from: data)
        XCTAssertEqual(decoded, effect)
    }

    // MARK: - Test 2 (written at P1, asserting the P2 name) - ENABLED
    // at P2 (item 2.1 landed: SMILAnimationTree.swift). Fixture stays
    // untouched (load-compat is the contract - see the file header);
    // this is the SAME test the P1-era comment above pinned, now doing
    // the real call instead of skipping. Also stands in for design
    // contract test (1) ("pinned fixture decodes, lifts, re-flattens,
    // re-encodes byte-identical") - the byte-identical re-encode half
    // is asserted here too, reusing the exact canonical-encoder
    // settings `testFixtureDecodesAndCanonicalReencodeIsByteIdentical`
    // (Test 1) already established, so a lift-then-reflatten that
    // silently dropped or reordered data would fail this test even if
    // `flattened() == decoded` structural equality somehow still held.
    func testSMILAnimationTreeFlatInitializerWillExist() throws {
        let original = try fixtureData()
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: original)

        let tree = SMILAnimationTree(flat: decoded)
        let reflattened = tree.flattened()
        XCTAssertEqual(reflattened, decoded, "SMILAnimationTree(flat: decoded).flattened() == decoded on the pinned P1 fixture (a legal flat list)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(reflattened)
        XCTAssertEqual(reencoded, original, "decode -> lift -> flatten -> canonical re-encode must reproduce the pinned fixture's bytes exactly")
    }
}
