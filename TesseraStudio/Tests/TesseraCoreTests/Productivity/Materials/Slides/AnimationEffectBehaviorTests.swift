import XCTest
import Foundation
@testable import TesseraCore

// MARK: - AnimationEffectBehaviorTests
//
// Ordinary behavioral coverage for AnimationEffect/AnimationEffectList
// (field presence, play-order = list order, trigger/duration/delay
// values) - contract source: AnimationEffectList.swift's own doc
// comment (studio-expansion-design-refinement-2026-08-14.md section 4
// Slides cluster item 1.20).
//
// NOTE ON FILE NAMING: per this cluster's task brief, T4 (a separate
// cluster) owns the pinned fixture / byte-identical re-encode test and
// the disabled SMILAnimationTree(flat:) forward-compat test for this
// same type - AnimationEffectList.swift's own doc comment names that
// test as `AnimationEffectListTests.testSMILAnimationTreeFlatInitializerWillExist`,
// so this file is deliberately named something OTHER than
// `AnimationEffectListTests.swift` to avoid clobbering T4's file in
// this shared checkout (the brief's own example name risked exactly
// that collision).

final class AnimationEffectBehaviorTests: DoctrineTestCase {

    // MARK: - Field presence / values

    func testAnimationEffectCarriesEveryDocumentedField() {
        let blockID = UUID()
        let effect = AnimationEffect(targetBlockID: blockID, presetID: "flyIn", trigger: .onClick, durationMS: 500, delayMS: 100)
        XCTAssertEqual(effect.targetBlockID, blockID)
        XCTAssertEqual(effect.presetID, "flyIn")
        XCTAssertEqual(effect.trigger, .onClick)
        XCTAssertEqual(effect.durationMS, 500)
        XCTAssertEqual(effect.delayMS, 100)
    }

    // MARK: - Play order = list (array) order

    func testPlayOrderIsExactlyArrayOrderWithNoSeparateOrderField() {
        let a = AnimationEffect(targetBlockID: UUID(), presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0)
        let b = AnimationEffect(targetBlockID: UUID(), presetID: "wipe", trigger: .withPrevious, durationMS: 300, delayMS: 0)
        let c = AnimationEffect(targetBlockID: UUID(), presetID: "zoom", trigger: .afterPrevious, durationMS: 300, delayMS: 0)
        let list: AnimationEffectList = [a, b, c]

        XCTAssertEqual(list.map(\.presetID), ["fade", "wipe", "zoom"], "play order is array order - reordering the array changes play order")

        let reordered: AnimationEffectList = [c, a, b]
        XCTAssertEqual(reordered.map(\.presetID), ["zoom", "fade", "wipe"])
    }

    // MARK: - Trigger vocabulary (independent oracle)

    func testAnimationTriggerHasExactlyTheThreeDocumentedCases() {
        let expected: Set<String> = ["onClick", "withPrevious", "afterPrevious"]
        XCTAssertEqual(Set(AnimationTrigger.allCases.map(\.rawValue)), expected)
    }

    // MARK: - Round trip of the effect value type (rule 2) - NOT the
    // pinned-fixture / re-encode piece, which is T4's.

    func testAnimationEffectEncodeDecodeIsIdentity() throws {
        let effect = AnimationEffect(targetBlockID: UUID(), presetID: "bounce", trigger: .withPrevious, durationMS: 750, delayMS: 250)
        let data = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(AnimationEffect.self, from: data)
        XCTAssertEqual(decoded, effect)
    }

    func testAnimationEffectListOfMultipleEffectsEncodeDecodeIsIdentity() throws {
        let list: AnimationEffectList = [
            AnimationEffect(targetBlockID: UUID(), presetID: "fade", trigger: .onClick, durationMS: 300, delayMS: 0),
            AnimationEffect(targetBlockID: UUID(), presetID: "wipe", trigger: .withPrevious, durationMS: 300, delayMS: 0),
        ]
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: data)
        XCTAssertEqual(decoded, list)
    }

    func testEmptyAnimationEffectListEncodeDecodeIsIdentity() throws {
        let list: AnimationEffectList = []
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(AnimationEffectList.self, from: data)
        XCTAssertEqual(decoded, list)
    }

    // MARK: - Grouping-rule DATA properties (the flattening precondition
    // the P2 tree constructor will rely on - testing the data shape
    // property itself, not the not-yet-built tree, per doctrine's
    // "derived-never-stored" rule 3 spirit: this property must hold of
    // any list this P1 type can validly represent for the flattening to
    // be well-defined later).

    func testAWithPreviousOrAfterPreviousEffectBelongsToTheNearestPrecedingOnClickGroup() {
        // Two onClick groups; verify "nearest preceding onClick" grouping
        // by walking the list the same way SMILAnimationTree(flat:) will
        // have to.
        let g1Click = AnimationEffect(targetBlockID: UUID(), presetID: "g1-click", trigger: .onClick, durationMS: 100, delayMS: 0)
        let g1Follow = AnimationEffect(targetBlockID: UUID(), presetID: "g1-follow", trigger: .withPrevious, durationMS: 100, delayMS: 0)
        let g2Click = AnimationEffect(targetBlockID: UUID(), presetID: "g2-click", trigger: .onClick, durationMS: 100, delayMS: 0)
        let g2Follow = AnimationEffect(targetBlockID: UUID(), presetID: "g2-follow", trigger: .afterPrevious, durationMS: 100, delayMS: 0)
        let list: AnimationEffectList = [g1Click, g1Follow, g2Click, g2Follow]

        var groups: [[AnimationEffect]] = []
        for effect in list {
            if effect.trigger == .onClick {
                groups.append([effect])
            } else {
                groups[groups.count - 1].append(effect)
            }
        }

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.presetID), ["g1-click", "g1-follow"])
        XCTAssertEqual(groups[1].map(\.presetID), ["g2-click", "g2-follow"])
    }
}
