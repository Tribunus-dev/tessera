import XCTest
import Foundation
@testable import TesseraCore

// MARK: - LOBridgeDeckIOSMILAndCustomShowTests
//
// fodp mapping coverage for P2 items 2.1 (SMIL animation timing tree
// import/export) and 2.10 (custom shows import/export), added to
// LOBridgeDeckIO.swift this wave. Contract sources: this wave's own
// "LOBridgeDeckIO + SMIL animation tree <-> fodp" / "+ Custom shows
// <-> fodp" extension headers, and .scratch/sota-p2-core-report.md's
// 2.1/2.10 design-contract sections' test lists ("an fodp fixture...
// with on-click/with/after + iterate + an interactive trigger
// importing to the expected tree shape"; "fodp round-trip of two
// [custom] shows preserves order + membership").
//
// Per testing-doctrine.md rule 10 (empirical probes are quarantined):
// this file's SMIL fixture is HAND-AUTHORED (matching real p:timing/
// anim:par shape, per this wave's design-contract allowance - "real,
// soffice-derived if practical, or hand-authored... matching real
// shape"), not soffice-derived, and this file does not shell out.
// `mapAnimationTree(fromPage:targetResolver:)`/`mapCustomShows(...)`
// are `internal` (not `public`), reached here only via `@testable
// import` - the same access LOBridgeDeckIO.swift's own `public static`
// mapping functions (`mapToSlideDeck`/`mapToFlatODFTree`) already
// establish as this file's testing seam.

final class LOBridgeDeckIOSMILAndCustomShowTests: DoctrineTestCase {

    // MARK: - Design contract test 4: fodp fixture with on-click/with/
    // after + iterate + an interactive trigger imports to the
    // expected tree shape.

    func testFodpFixtureWithOnClickWithAfterIterateAndInteractiveTriggerImportsToExpectedTreeShape() throws {
        let targetA = AnimationTarget(blockID: UUID())
        let targetB = AnimationTarget(blockID: UUID())
        let targetC = AnimationTarget(blockID: UUID())
        let targetIterate = AnimationTarget(blockID: UUID())
        let triggerShape = AnimationTarget(blockID: UUID())
        let interactiveTarget = AnimationTarget(blockID: UUID())
        let resolverTable: [String: AnimationTarget] = [
            "target-a": targetA, "target-b": targetB, "target-c": targetC,
            "target-iterate": targetIterate, "trigger-shape": triggerShape,
            "interactive-target": interactiveTarget,
        ]
        let resolver: (String) -> AnimationTarget? = { resolverTable[$0] }

        // mainSeq > one clickPar group: onClick .set, with-previous
        // .animate, after-previous .animateColor, and an iterate node
        // (by-paragraph, 0.25s interval) wrapping one .animate.
        let onClickBehavior = FlatODFElement(
            name: "anim:set",
            attributes: ["smil:targetElement": "target-a", "smil:attributeName": "visibility", "smil:to": "visible"])
        let withBehavior = FlatODFElement(
            name: "anim:animate",
            attributes: ["smil:targetElement": "target-b", "smil:attributeName": "opacity"])
        let withWrapper = FlatODFElement(
            name: "anim:par", attributes: ["presentation:node-type": "with-previous"],
            children: [.element(withBehavior)])
        let afterBehavior = FlatODFElement(
            name: "anim:animateColor",
            attributes: ["smil:targetElement": "target-c", "smil:attributeName": "fill"])
        let afterWrapper = FlatODFElement(
            name: "anim:par", attributes: ["presentation:node-type": "after-previous"],
            children: [.element(afterBehavior)])
        let iterateBehavior = FlatODFElement(
            name: "anim:animate",
            attributes: ["smil:targetElement": "target-iterate", "smil:attributeName": "opacity"])
        let iterateNode = FlatODFElement(
            name: "anim:iterate",
            attributes: ["anim:iterate-type": "by-paragraph", "anim:iterate-interval": "0.25s"],
            children: [.element(iterateBehavior)])
        let clickPar = FlatODFElement(
            name: "anim:par", attributes: ["presentation:node-type": "on-click"],
            children: [.element(onClickBehavior), .element(withWrapper), .element(afterWrapper), .element(iterateNode)])
        let mainSeq = FlatODFElement(
            name: "anim:seq", attributes: ["presentation:node-type": "main-sequence"],
            children: [.element(clickPar)])

        // interactiveSeq: one on-click group triggered by clicking
        // `trigger-shape`, wrapping one .set behavior on a DIFFERENT
        // target than the mainSeq's own effects.
        let interactiveBehavior = FlatODFElement(
            name: "anim:set",
            attributes: ["smil:targetElement": "interactive-target", "smil:attributeName": "visibility", "smil:to": "visible"])
        let interactivePar = FlatODFElement(
            name: "anim:par",
            attributes: ["presentation:node-type": "on-click", "smil:begin": "trigger-shape.click"],
            children: [.element(interactiveBehavior)])
        let interactiveSeq = FlatODFElement(
            name: "anim:seq", attributes: ["presentation:node-type": "interactive-sequence"],
            children: [.element(interactivePar)])

        let rootPar = FlatODFElement(
            name: "anim:par", attributes: ["presentation:node-type": "timing-root"],
            children: [.element(mainSeq), .element(interactiveSeq)])
        let page = FlatODFElement(name: "draw:page", children: [.element(rootPar)])

        let tree = try XCTUnwrap(LOBridgeDeckIO.mapAnimationTree(fromPage: page, targetResolver: resolver))

        guard case let .par(rootProps, rootChildren) = tree.root else {
            return XCTFail("root must be .par")
        }
        XCTAssertEqual(rootProps.nodeType, .tmRoot)
        XCTAssertEqual(rootChildren.count, 2, "mainSeq + interactiveSeq")

        // mainSeq -> clickPar -> [behavior, withGroup(behavior), afterGroup(behavior), iterate(behavior)]
        guard case let .seq(mainSeqProps, mainSeqChildren) = rootChildren[0] else {
            return XCTFail("first root child must be .seq (mainSeq)")
        }
        XCTAssertEqual(mainSeqProps.nodeType, .mainSeq)
        XCTAssertEqual(mainSeqChildren.count, 1)
        guard case let .par(groupProps, groupChildren) = mainSeqChildren[0] else {
            return XCTFail("mainSeq's child must be .par (clickPar)")
        }
        XCTAssertEqual(groupProps.nodeType, .clickPar)
        XCTAssertEqual(groupChildren.count, 4, "onClick behavior + with wrapper + after wrapper + iterate")

        guard case let .behavior(onClickProps, onClickTarget, onClickBehaviorValue) = groupChildren[0] else {
            return XCTFail("clickPar's first child must be a bare .behavior (the click-triggered effect)")
        }
        XCTAssertEqual(onClickProps.nodeType, .clickEffect)
        XCTAssertEqual(onClickTarget, targetA)
        XCTAssertEqual(onClickBehaviorValue, .set(attributeName: "visibility", to: "visible"))

        guard case let .par(withGroupProps, withGroupChildren) = groupChildren[1],
              let withInner = withGroupChildren.first,
              case let .behavior(withProps, withTarget, withBehaviorValue) = withInner
        else {
            return XCTFail("clickPar's second child must be a .par(withGroup) wrapping one .behavior")
        }
        XCTAssertEqual(withGroupProps.nodeType, .withGroup)
        XCTAssertEqual(withProps.nodeType, .withEffect)
        XCTAssertEqual(withTarget, targetB)
        XCTAssertEqual(withBehaviorValue, .animate(attributeName: "opacity", values: [], from: nil, to: nil, by: nil))

        guard case let .par(afterGroupProps, afterGroupChildren) = groupChildren[2],
              let afterInner = afterGroupChildren.first,
              case let .behavior(afterProps, afterTarget, afterBehaviorValue) = afterInner
        else {
            return XCTFail("clickPar's third child must be a .par(afterGroup) wrapping one .behavior")
        }
        XCTAssertEqual(afterGroupProps.nodeType, .afterGroup)
        XCTAssertEqual(afterProps.nodeType, .afterEffect)
        XCTAssertEqual(afterTarget, targetC)
        XCTAssertEqual(afterBehaviorValue, .animateColor(attributeName: "fill", from: nil, to: nil, colorInterpolation: nil))

        guard case let .iterate(_, iterateSpec, iterateChildren) = groupChildren[3],
              let iterateInner = iterateChildren.first,
              case let .behavior(_, iterateTarget, _) = iterateInner
        else {
            return XCTFail("clickPar's fourth child must be .iterate wrapping one .behavior")
        }
        XCTAssertEqual(iterateSpec.type, .byParagraph)
        XCTAssertEqual(iterateSpec.intervalMS, 250)
        XCTAssertEqual(iterateTarget, targetIterate)

        // interactiveSeq -> on-click par (begin: trigger-shape.click) -> one .behavior
        guard case let .seq(interactiveSeqProps, interactiveSeqChildren) = rootChildren[1] else {
            return XCTFail("second root child must be .seq (interactiveSeq)")
        }
        XCTAssertEqual(interactiveSeqProps.nodeType, .interactiveSeq)
        XCTAssertEqual(interactiveSeqChildren.count, 1)
        guard case let .par(triggerGroupProps, triggerGroupChildren) = interactiveSeqChildren[0],
              let triggerInner = triggerGroupChildren.first,
              case let .behavior(_, triggerBehaviorTarget, _) = triggerInner
        else {
            return XCTFail("interactiveSeq's child must be .par wrapping one .behavior")
        }
        XCTAssertEqual(triggerGroupProps.nodeType, .clickPar)
        XCTAssertEqual(triggerGroupProps.begin, [.onClick(target: triggerShape, offsetMS: 0)], "the interactive trigger names the clicked shape, not the ordinary next-click advance")
        XCTAssertEqual(triggerBehaviorTarget, interactiveTarget)
    }

    // MARK: - Custom shows: fodp round-trip of two shows preserves order + membership

    func testFodpRoundTripOfTwoCustomShowsPreservesOrderAndMembership() throws {
        var deck = SlideDeck.makeBlank(title: "Custom Shows Round Trip")
        deck = deck.insertingSlide(at: 1, layout: .blank)
        deck = deck.insertingSlide(at: 2, layout: .blank)
        XCTAssertEqual(deck.slideCount, 3)
        let s0 = deck.body.rootChildren[0]
        let s1 = deck.body.rootChildren[1]
        let s2 = deck.body.rootChildren[2]

        deck = deck.addingCustomShow(CustomShow(name: "Quick Tour", slideIDs: [s0, s2]))
        deck = deck.addingCustomShow(CustomShow(name: "Deep Dive", slideIDs: [s0, s1, s2, s0]))

        let flatODF = LOBridgeDeckIO.mapToFlatODFTree(deck)
        let reimported = try LOBridgeDeckIO.mapToSlideDeck(root: flatODF)

        XCTAssertEqual(reimported.slideCount, 3)
        XCTAssertEqual(reimported.effectiveCustomShows.count, 2)
        let quickTour = try XCTUnwrap(reimported.effectiveCustomShows.first { $0.name == "Quick Tour" })
        let deepDive = try XCTUnwrap(reimported.effectiveCustomShows.first { $0.name == "Deep Dive" })

        // Slide identity is regenerated on import (fresh UUIDs) - the
        // contract this test proves is ORDER and MEMBERSHIP by
        // position, matching this bridge's page-order == slide-order
        // convention (draw:page order IS slide order both ways).
        let reimportedIDs = reimported.body.rootChildren
        XCTAssertEqual(quickTour.slideIDs, [reimportedIDs[0], reimportedIDs[2]])
        XCTAssertEqual(deepDive.slideIDs, [reimportedIDs[0], reimportedIDs[1], reimportedIDs[2], reimportedIDs[0]],
                        "order AND the repeated first slide must both survive the round trip")
    }

    func testMapCustomShowsFromSettingsSkipsAPageNameWithNoMatchingSlide() {
        let deckID = UUID()
        let settings = FlatODFElement(
            name: "presentation:settings",
            children: [.element(FlatODFElement(
                name: "presentation:show",
                attributes: ["presentation:name": "Ghost Show", "presentation:pages": "Slide 1,Slide 99"]
            ))]
        )
        let shows = LOBridgeDeckIO.mapCustomShows(fromSettings: settings, nameToID: ["Slide 1": deckID])
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows.first?.slideIDs, [deckID], "an unresolvable page name is skipped, not synthesized as a dangling id")
    }

    func testMapCustomShowsToFlatODFReturnsNilForAnEmptyShowList() {
        let deck = SlideDeck.makeBlank(title: "No Shows")
        XCTAssertNil(LOBridgeDeckIO.mapCustomShows([], deck: deck), "an empty show list must produce no presentation:settings element at all")
    }
}
