import XCTest
@testable import TesseraCore

/// `AnimationEffectList` (P1 1.20): the flat, play-order-is-array-order
/// interim for slide animations
/// (studio-expansion-design-refinement-2026-08-14.md, Slides cluster).
/// The pinned fixture + byte-identical re-encode test are the load-compat
/// contract the P2 `SMILAnimationTree` evolution must honor; see this
/// file's own header comment on `AnimationEffectList` for the grouping
/// rule the fixture is built to exercise.
final class AnimationEffectListTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixtureURL() -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("animation-effect-list-p1.json", isDirectory: false)
    }

    private func loadFixture() throws -> AnimationEffectList {
        let data = try Data(contentsOf: fixtureURL())
        return try JSONDecoder().decode(AnimationEffectList.self, from: data)
    }

    /// Splits a flat list into groups per `AnimationEffectList`'s
    /// documented pre-order-flattening rule: every `.onClick` effect
    /// opens a new group, every follower joins the most recently opened
    /// one. Local to this test - the real splitter is
    /// `SMILAnimationTree`'s job at P2, not built here.
    private func groupedByTrigger(_ effects: AnimationEffectList) -> [[AnimationEffect]] {
        var groups: [[AnimationEffect]] = []
        for effect in effects {
            if effect.trigger == .onClick {
                groups.append([effect])
            } else {
                groups[groups.count - 1].append(effect)
            }
        }
        return groups
    }

    // MARK: - AnimationEffect / AnimationTrigger

    func testAnimationEffectStoresGivenFields() {
        let id = UUID()
        let effect = AnimationEffect(
            targetBlockID: id, presetID: "fade-in", trigger: .withPrevious,
            durationMS: 300, delayMS: 50
        )
        XCTAssertEqual(effect.targetBlockID, id)
        XCTAssertEqual(effect.presetID, "fade-in")
        XCTAssertEqual(effect.trigger, .withPrevious)
        XCTAssertEqual(effect.durationMS, 300)
        XCTAssertEqual(effect.delayMS, 50)
    }

    /// Wire-format regression: the JSON strings a decoder must accept
    /// (and an encoder must emit) for each trigger case.
    func testAnimationTriggerRawValuesAreStable() {
        XCTAssertEqual(AnimationTrigger.onClick.rawValue, "onClick")
        XCTAssertEqual(AnimationTrigger.withPrevious.rawValue, "withPrevious")
        XCTAssertEqual(AnimationTrigger.afterPrevious.rawValue, "afterPrevious")
    }

    // MARK: - Fixture shape

    /// The fixture must actually exercise the grouping rule it exists to
    /// pin - not just decode as a single flat effect. See
    /// `AnimationEffectList`'s header comment for the rule this checks.
    func testFixtureDecodesWithExpectedGrouping() throws {
        let effects = try loadFixture()
        XCTAssertEqual(effects.count, 5)
        XCTAssertEqual(effects.first?.trigger, .onClick, "a non-empty list must open with .onClick")

        let groups = groupedByTrigger(effects)
        XCTAssertGreaterThanOrEqual(groups.count, 2, "fixture must exercise at least 2 onClick groups")
        XCTAssertTrue(
            groups.contains { $0.dropFirst().contains { $0.trigger == .withPrevious } },
            "fixture must exercise a .withPrevious follower"
        )
        XCTAssertTrue(
            groups.contains { $0.dropFirst().contains { $0.trigger == .afterPrevious } },
            "fixture must exercise an .afterPrevious follower"
        )
    }

    // MARK: - Pinned serialization contract (REQUIRED)

    /// The fixture must re-encode byte-identical to its own committed
    /// contents. This IS the load-compat contract
    /// (studio-expansion-design-refinement-2026-08-14.md item 1.20:
    /// "the fixture file must never be edited at P2 - load-compat IS
    /// the contract") - a future decode of this exact file must always
    /// produce this exact JSON back out.
    func testFixtureReencodesByteIdentical() throws {
        let original = try Data(contentsOf: fixtureURL())
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: original)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(decoded)

        XCTAssertEqual(
            String(data: reencoded, encoding: .utf8), String(data: original, encoding: .utf8),
            "pinned fixture must re-encode byte-identical"
        )
        XCTAssertEqual(reencoded, original, "pinned fixture must re-encode byte-identical")
    }

    /// P2: pins the exact constructor name `SMILAnimationTree(flat:)` a
    /// P2 implementer must match
    /// (studio-expansion-design-refinement-2026-08-14.md item 1.20:
    /// "the P2 constructor SMILAnimationTree(flat:) is total and
    /// tree.flattened() is its left inverse"). Skipped, not stubbed -
    /// `SMILAnimationTree` does not exist until P2 (building it now would
    /// be P2 scope creep). This test's NAME and doc comment are the
    /// pinned contract, not its body; a P2 implementer replaces the
    /// `XCTSkip` with a real assertion once `SMILAnimationTree` exists,
    /// without renaming the test.
    func testSMILAnimationTreeFlatInitializerWillExist() throws {
        throw XCTSkip(
            "P2: SMILAnimationTree(flat: AnimationEffectList) is not implemented until P2 - "
            + "this test name pins the required initializer signature ahead of time."
        )
    }
}
