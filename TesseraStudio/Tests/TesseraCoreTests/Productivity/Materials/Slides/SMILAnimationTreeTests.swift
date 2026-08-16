import XCTest
import Foundation
@testable import TesseraCore

// MARK: - SMILAnimationTreeTests
//
// Contract source: SMILAnimationTree.swift's own doc comments, in turn
// transcribing .scratch/sota-p2-core-report.md section "2.1
// SMILAnimationTree - Impress, effort L (architect-locked)" and
// AnimationEffectList.swift's grouping-rule header (P1 item 1.20).
// Doctrine rule 7 (independent oracles): the node-type totality test
// below pins the 9 values by a hardcoded literal list, never by
// iterating SMILNodeType.allCases against itself. Doctrine rule 9
// (math gets fixtures AND properties): the totality/left-inverse
// property is exercised both as hand-built fixture cases and as a
// property test over several random-but-legal flat lists.
//
// The pinned-fixture round trip (design contract test 1) and the
// disabled-test-enable (test 2) live in
// AnimationEffectListP1FixtureTests.swift (T4's file, this wave's one
// pre-resolved exception into it - see that file's header) since the
// fixture and its byte-identical re-encode helper already live there.

final class SMILAnimationTreeTests: DoctrineTestCase {

    // MARK: - Node-type totality guard (doctrine rule 7: independent oracle)

    /// The 9 ST_TLTimeNodeType values named in the 2.1 design
    /// contract's type sketch, transcribed here independently of
    /// SMILNodeType's own declaration - a totality test must never
    /// validate a catalog against itself (rule 7's own worked example
    /// is exactly this: "the 9 SMIL node types").
    func testSMILNodeTypeHasExactlyTheNineContractNamedValues() {
        let expected: Set<String> = [
            "tmRoot", "mainSeq", "interactiveSeq",
            "clickPar", "withGroup", "afterGroup",
            "clickEffect", "withEffect", "afterEffect",
        ]
        XCTAssertEqual(Set(SMILNodeType.allCases.map(\.rawValue)), expected)
        XCTAssertEqual(SMILNodeType.allCases.count, 9)
    }

    // MARK: - init(flat:) totality (never fails on illegal input)

    /// A leading `.withPrevious` (no group open to join) must not
    /// trap or throw - the design contract's own words: "an illegal
    /// leading with/after opens an implicit group".
    func testInitFlatWithIllegalLeadingWithPreviousDoesNotTrapAndOpensAnImplicitGroup() {
        let blockID = UUID()
        let illegal: AnimationEffectList = [
            AnimationEffect(targetBlockID: blockID, presetID: "fade", trigger: .withPrevious, durationMS: 300, delayMS: 0),
        ]
        let tree = SMILAnimationTree(flat: illegal)
        // Total: reaching this line at all (no trap) is the primary
        // assertion. The synthesized group's head is reported back as
        // .onClick (see the design contract's totality note) - the
        // implicit-group behavior, not a crash and not a silently
        // dropped effect.
        let flattened = tree.flattened()
        XCTAssertEqual(flattened.count, 1)
        XCTAssertEqual(flattened.first?.trigger, .onClick)
        XCTAssertEqual(flattened.first?.targetBlockID, blockID)
    }

    /// Same totality guarantee for an illegal leading `.afterPrevious`.
    func testInitFlatWithIllegalLeadingAfterPreviousDoesNotTrapAndOpensAnImplicitGroup() {
        let blockID = UUID()
        let illegal: AnimationEffectList = [
            AnimationEffect(targetBlockID: blockID, presetID: "wipe", trigger: .afterPrevious, durationMS: 300, delayMS: 50),
        ]
        let tree = SMILAnimationTree(flat: illegal)
        let flattened = tree.flattened()
        XCTAssertEqual(flattened.count, 1)
        XCTAssertEqual(flattened.first?.trigger, .onClick)
    }

    /// The empty list is legal and must produce a valid (if content-
    /// free) tree, not a trap.
    func testInitFlatOfEmptyListProducesAnEmptyMainSeq() {
        let tree = SMILAnimationTree(flat: [])
        XCTAssertEqual(tree.flattened(), [])
        guard case let .par(rootProps, rootChildren) = tree.root else {
            return XCTFail("root must be .par")
        }
        XCTAssertEqual(rootProps.nodeType, .tmRoot)
        XCTAssertEqual(rootChildren.count, 1)
        XCTAssertEqual(rootChildren.first?.timingProps.nodeType, .mainSeq)
        XCTAssertEqual(rootChildren.first?.childNodes.count, 0)
    }

    // MARK: - flattened(init(flat: x)) == x on legal lists (fixture cases)

    private func makeEffect(
        target: UUID = UUID(), preset: String, trigger: AnimationTrigger, durationMS: Int = 300, delayMS: Int = 0
    ) -> AnimationEffect {
        AnimationEffect(targetBlockID: target, presetID: preset, trigger: trigger, durationMS: durationMS, delayMS: delayMS)
    }

    func testSingleOnClickEffectRoundTrips() {
        let list: AnimationEffectList = [makeEffect(preset: "fade", trigger: .onClick)]
        XCTAssertEqual(SMILAnimationTree(flat: list).flattened(), list)
    }

    func testOnClickFollowedByMultipleWithPreviousRoundTrips() {
        let list: AnimationEffectList = [
            makeEffect(preset: "fade", trigger: .onClick, durationMS: 500),
            makeEffect(preset: "spin", trigger: .withPrevious, durationMS: 200, delayMS: 100),
            makeEffect(preset: "grow", trigger: .withPrevious, durationMS: 150, delayMS: 0),
        ]
        XCTAssertEqual(SMILAnimationTree(flat: list).flattened(), list)
    }

    func testOnClickFollowedByMultipleAfterPreviousRoundTrips() {
        let list: AnimationEffectList = [
            makeEffect(preset: "fade", trigger: .onClick),
            makeEffect(preset: "spin", trigger: .afterPrevious, delayMS: 250),
            makeEffect(preset: "grow", trigger: .afterPrevious, delayMS: 0),
        ]
        XCTAssertEqual(SMILAnimationTree(flat: list).flattened(), list)
    }

    func testMixedWithAndAfterPreviousFollowersInOneGroupRoundTrip() {
        let list: AnimationEffectList = [
            makeEffect(preset: "fade", trigger: .onClick, durationMS: 400),
            makeEffect(preset: "spin", trigger: .withPrevious, durationMS: 300, delayMS: 50),
            makeEffect(preset: "grow", trigger: .afterPrevious, durationMS: 200, delayMS: 75),
            makeEffect(preset: "shrink", trigger: .withPrevious, durationMS: 100, delayMS: 0),
        ]
        XCTAssertEqual(SMILAnimationTree(flat: list).flattened(), list)
    }

    func testManyClickGroupsInSequenceRoundTrip() {
        let list: AnimationEffectList = (0..<6).map { i in
            makeEffect(preset: "preset-\(i)", trigger: .onClick, durationMS: 100 + i * 10)
        }
        XCTAssertEqual(SMILAnimationTree(flat: list).flattened(), list)
    }

    // MARK: - Property test (design contract test 3): several
    // random-but-legal flat lists round-trip through init(flat:)/
    // flattened(). "Legal" per the grouping rule: first effect (if
    // any) is .onClick; every other effect is one of the 3 triggers
    // with .onClick allowed to start a NEW group at any position.

    private func randomLegalFlatList(seed: Int) -> AnimationEffectList {
        var rng = SeededGenerator(seed: seed)
        let count = Int.random(in: 1...12, using: &rng)
        var out: AnimationEffectList = []
        for i in 0..<count {
            let trigger: AnimationTrigger
            if i == 0 {
                trigger = .onClick
            } else {
                trigger = [.onClick, .withPrevious, .afterPrevious].randomElement(using: &rng)!
            }
            out.append(AnimationEffect(
                targetBlockID: UUID(),
                presetID: "preset-\(seed)-\(i)",
                trigger: trigger,
                durationMS: Int.random(in: 0...2000, using: &rng),
                delayMS: Int.random(in: 0...500, using: &rng)
            ))
        }
        return out
    }

    func testPropertyRandomLegalFlatListsRoundTripThroughInitFlatAndFlattened() {
        for seed in 0..<25 {
            let list = randomLegalFlatList(seed: seed)
            let reflattened = SMILAnimationTree(flat: list).flattened()
            XCTAssertEqual(reflattened, list, "seed \(seed) failed to round-trip: \(list) != \(reflattened)")
        }
    }

    // MARK: - Design contract test 5: iterate-bearing tree encode/decode round trip

    func testIterateBearingTreeEncodeDecodeRoundTrips() throws {
        let target = AnimationTarget(blockID: UUID(), paragraphIndex: 2)
        let behaviorProps = SMILTimingProps(
            nodeType: .clickEffect, begin: [.time(offsetMS: 100)], durationMS: 300, presetID: "build-in")
        let behaviorNode = SMILNode.behavior(behaviorProps, target: target, .animate(
            attributeName: "opacity", values: ["0", "1"], from: "0", to: "1", by: nil))
        let iterateProps = SMILTimingProps(nodeType: .clickEffect, begin: [.onClick(target: nil, offsetMS: 0)])
        let iterateSpec = IterateSpec(type: .byParagraph, intervalMS: 250)
        let iterateNode = SMILNode.iterate(iterateProps, iterateSpec, children: [behaviorNode])
        let groupNode = SMILNode.par(SMILTimingProps(nodeType: .clickPar, begin: [.onClick(target: nil, offsetMS: 0)]), children: [iterateNode])
        let mainSeq = SMILNode.seq(SMILTimingProps(nodeType: .mainSeq), children: [groupNode])
        let root = SMILNode.par(SMILTimingProps(nodeType: .tmRoot), children: [mainSeq])
        let tree = SMILAnimationTree(root: root)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SMILAnimationTree.self, from: data)
        XCTAssertEqual(decoded, tree)

        // Spot-check the iterate node survived structurally, not just
        // via top-level Equatable (guards against a synthesis bug
        // that happened to still satisfy == via some degenerate case).
        guard case let .par(_, rootChildren) = decoded.root,
              case let .seq(_, seqChildren) = rootChildren[0],
              case let .par(_, groupChildren) = seqChildren[0],
              case let .iterate(_, decodedSpec, iterateChildren) = groupChildren[0]
        else {
            return XCTFail("decoded tree lost its iterate node shape")
        }
        XCTAssertEqual(decodedSpec.type, .byParagraph)
        XCTAssertEqual(decodedSpec.intervalMS, 250)
        XCTAssertEqual(iterateChildren.count, 1)
        guard case let .behavior(_, decodedTarget, decodedBehavior) = iterateChildren[0] else {
            return XCTFail("iterate's child lost its behavior shape")
        }
        XCTAssertEqual(decodedTarget, target)
        XCTAssertEqual(decodedBehavior, .animate(attributeName: "opacity", values: ["0", "1"], from: "0", to: "1", by: nil))
    }

    // MARK: - Round-trip identity (doctrine rule 2) for the smaller value types

    func testAnimationTargetEncodeDecodeIdentityWithAndWithoutParagraphIndex() throws {
        let withIndex = AnimationTarget(blockID: UUID(), paragraphIndex: 3)
        let withoutIndex = AnimationTarget(blockID: UUID())
        for target in [withIndex, withoutIndex] {
            let data = try JSONEncoder().encode(target)
            let decoded = try JSONDecoder().decode(AnimationTarget.self, from: data)
            XCTAssertEqual(decoded, target)
        }
    }

    func testSMILConditionEncodeDecodeIdentityForEveryCase() throws {
        let cases: [SMILCondition] = [
            .indefinite,
            .afterPrevious(offsetMS: 250),
            .withPrevious(offsetMS: 0),
            .onClick(target: AnimationTarget(blockID: UUID()), offsetMS: 10),
            .onClick(target: nil, offsetMS: 0),
            .time(offsetMS: 500),
        ]
        for condition in cases {
            let data = try JSONEncoder().encode(condition)
            let decoded = try JSONDecoder().decode(SMILCondition.self, from: data)
            XCTAssertEqual(decoded, condition)
        }
    }

    func testSMILBehaviorEncodeDecodeIdentityForEveryCase() throws {
        let cases: [SMILBehavior] = [
            .animate(attributeName: "x", values: ["0", "100"], from: "0", to: "100", by: nil),
            .set(attributeName: "visibility", to: "visible"),
            .animateMotion(svgPath: "M0,0 L100,100"),
            .animateColor(attributeName: "fill", from: "#000", to: "#fff", colorInterpolation: "rgb"),
            .animateTransform(transformType: "rotate", from: "0", to: "360", by: nil),
            .animateEffect(transitionType: "fly-in-left", subtype: nil, direction: "left"),
            .audio(source: "assets/click.mp3"),
            .video(source: nil),
            .command(commandType: "toggle-pause", value: nil),
        ]
        for behavior in cases {
            let data = try JSONEncoder().encode(behavior)
            let decoded = try JSONDecoder().decode(SMILBehavior.self, from: data)
            XCTAssertEqual(decoded, behavior)
        }
    }

    func testSMILTimingPropsEncodeDecodeIdentityWithEveryFieldPopulated() throws {
        let props = SMILTimingProps(
            nodeType: .clickEffect,
            begin: [.onClick(target: nil, offsetMS: 0), .time(offsetMS: 100)],
            durationMS: 400,
            repeatCount: .indefinite,
            autoReverse: true,
            accelerate: 0.2,
            decelerate: 0.3,
            fill: .freeze,
            restart: .whenNotActive,
            presetClass: "entrance",
            presetID: "fly-in-left"
        )
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(SMILTimingProps.self, from: data)
        XCTAssertEqual(decoded, props)
    }

    // MARK: - excl parse-and-preserve marker (design-judgment call, recorded in findings)

    func testExclMarkerPresetClassIsDistinctFromAnyRealPresetClass() {
        // The marker must not collide with a plausible real ODF
        // presentation:preset-class value - guards the "flagged par"
        // scheme (see SMILTimingProps.exclMarkerPresetClass's doc
        // comment) against silently misinterpreting real content as
        // an excl container.
        let plausibleRealValues = ["entrance", "exit", "emphasis", "motionpath", "verb", "misc"]
        XCTAssertFalse(plausibleRealValues.contains(SMILTimingProps.exclMarkerPresetClass))
    }
}

// MARK: - SeededGenerator
//
// A deterministic RandomNumberGenerator (doctrine rule 4: no random()
// in assertions without a fixed seed - "Injected clocks only" extends
// to injected randomness for property tests, the same spirit
// TesseraStudio's other property tests already apply). A tiny
// splitmix64-style generator - good enough for test-input diversity,
// not for anything security-sensitive.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        self.state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
