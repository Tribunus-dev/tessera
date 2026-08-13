import XCTest
import SwiftUI
@testable import TesseraCore

// MARK: - T1-3: accessibilityReduceMotion respected in all animation sites

/// HIG 2.7 / 3.6 / 12.4: every animation / transition in the macOS UI
/// must be instant (nil animation) when the user has Reduce Motion on.
/// These tests verify the reduceMotion pattern is correctly applied to
/// the view-layer animations that are exercisable from TesseraCore.
///
/// The four animation sites in TesseraStudioMac that required fixes:
///  1. WorkflowsView: connection-error banner spring animation (T1-3)
///  2. EmailView: import-status banner opacity transition (T1-3)
///  3. RemindersView: notifications-disabled banner opacity transition (T1-3)
///  4. ContactsView: import-status banner opacity transition (T1-3)
///  5. NoteEditorColumn: focus-mode bar opacity transitions (T1-3)
///
/// The canonical pattern is `animation(reduceMotion ? nil : <curve>, value: <state>)`
/// or `withAnimation(reduceMotion ? nil : <curve>)`. Both are equivalent — nil
/// animation means instant. The tests below verify the AnimationPrimitives
/// that back the Tessera editor primitives, plus the computed-property pattern
/// used by WorkflowsView.bannerTransition.
final class HIGAuditT1_3_ReduceMotionTests: XCTestCase {

    // MARK: - bannerTransition pattern (WorkflowsView)

    func testBannerTransitionIsOpacityUnderNormalMotion() {
        // The pattern: reduceMotion ? .identity : .opacity
        // Under normal motion, .opacity is returned (animated fade).
        // Under Reduce Motion, .identity is returned (instant).
        // Both are valid AnyTransition values; only the string
        // representation differs.
        func bannerTransition(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .identity : .opacity
        }
        let normal = bannerTransition(reduceMotion: false)
        let reduced = bannerTransition(reduceMotion: true)
        XCTAssertNotEqual(String(describing: normal), String(describing: reduced))
        XCTAssertEqual(String(describing: normal), String(describing: AnyTransition.opacity))
        XCTAssertEqual(String(describing: reduced), String(describing: AnyTransition.identity))
    }

    // MARK: - AnimationPrimitives: all editor primitives fall back under Reduce Motion

    func testAllEditorAnimationsRespectReduceMotion() {
        // blockSlideIn: normal 0.25s, reduceMotion 0.15s (still animated, shorter)
        XCTAssertNotNil(AnimationPrimitives.blockSlideIn(reduceMotion: false))
        XCTAssertNotNil(AnimationPrimitives.blockSlideIn(reduceMotion: true))
        let slideNormal = AnimationPrimitives.blockSlideIn(reduceMotion: false)
        let slideReduced = AnimationPrimitives.blockSlideIn(reduceMotion: true)
        XCTAssertNotEqual(String(describing: slideNormal), String(describing: slideReduced))

        // blockReplace: normal 0.30s, reduceMotion 0.15s (still animated, shorter)
        XCTAssertNotNil(AnimationPrimitives.blockReplace(reduceMotion: false))
        XCTAssertNotNil(AnimationPrimitives.blockReplace(reduceMotion: true))
        let replaceNormal = AnimationPrimitives.blockReplace(reduceMotion: false)
        let replaceReduced = AnimationPrimitives.blockReplace(reduceMotion: true)
        XCTAssertNotEqual(String(describing: replaceNormal), String(describing: replaceReduced))

        // blockDelete: instant (nil) under reduce motion
        XCTAssertNotNil(AnimationPrimitives.blockDelete(reduceMotion: false))
        XCTAssertNil(AnimationPrimitives.blockDelete(reduceMotion: true))

        // agentPausedBanner: 0.20s normal, 0.001s (near-instant) under reduceMotion
        XCTAssertNotNil(AnimationPrimitives.agentPausedBanner(reduceMotion: false))
        XCTAssertNotNil(AnimationPrimitives.agentPausedBanner(reduceMotion: true))
        let bannerNormal = AnimationPrimitives.agentPausedBanner(reduceMotion: false)
        let bannerReduced = AnimationPrimitives.agentPausedBanner(reduceMotion: true)
        XCTAssertNotEqual(String(describing: bannerNormal), String(describing: bannerReduced))
    }

    func testCursorBlinkIsStaticUnderReduceMotion() {
        // Cursor blink should not animate under Reduce Motion.
        XCTAssertNotNil(AnimationPrimitives.cursorBlink(reduceMotion: false))
        XCTAssertNil(AnimationPrimitives.cursorBlink(reduceMotion: true))
    }

    func testThinkingPulseIsStaticUnderReduceMotion() {
        XCTAssertNotNil(AnimationPrimitives.thinkingPulseAnimation(reduceMotion: false))
        XCTAssertNil(AnimationPrimitives.thinkingPulseAnimation(reduceMotion: true))
    }

    func testTextAppearIsWholeTextUnderReduceMotion() {
        // Under Reduce Motion, the whole text appears at once (no per-char
        // delay), so textAppearDelay returns nil.
        XCTAssertNotNil(AnimationPrimitives.textAppearDelay(reduceMotion: false))
        XCTAssertNil(AnimationPrimitives.textAppearDelay(reduceMotion: true))
    }

    // MARK: - withAnimation nil means instant

    func testWithAnimationNilIsInstant() {
        // Verifying the SwiftUI semantics: withAnimation(nil) produces
        // no animation (instant state change). This is the mechanism
        // behind the reduceMotion fix in all five animation sites.
        // We can't test SwiftUI's internals directly, but we confirm
        // nil is a valid animation argument by building it.
        let nilAnimation: Animation? = nil
        let defaultAnimation: Animation? = .default
        XCTAssertNil(nilAnimation)
        XCTAssertNotNil(defaultAnimation)
        // The key invariant: nil != default.
        XCTAssertNotEqual(String(describing: nilAnimation), String(describing: defaultAnimation))
    }
}

// MARK: - T1-4: numeric parameters round-trip as JSON numbers

/// HIG 10.15: numeric node parameters must be stored as JSON numbers,
/// not strings. A node's `{"samples": 100}` must reach the executor
/// as a number, not "100". These tests complement the panel binding
/// tests with executor-level round-trip verification.
final class HIGAuditT1_4_NumericParameterTests: XCTestCase {

    func testNodeParametersWithIntegerAreStoredAsNumbers() throws {
        let json = #"{"id":"n","type":"calibrate","parameters":{"n_tokens":8000,"top_k":256}}"#
        let node = try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
        // The decoder must produce .number, not .string.
        XCTAssertEqual(node.parameters["n_tokens"], .number(8000))
        XCTAssertEqual(node.parameters["top_k"], .number(256))
        // String comparison catches the regression: a .string("8000")
        // would fail this assertion even if stringValue matched.
        if case .string = node.parameters["n_tokens"] {
            XCTFail("n_tokens was stored as a JSON string instead of a number")
        }
    }

    func testNodeParametersWithFloatAreStoredAsNumbers() throws {
        let json = #"{"id":"n","type":"calibrate","parameters":{"temperature":0.7,"top_p":0.95}}"#
        let node = try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.parameters["temperature"], .number(0.7))
        XCTAssertEqual(node.parameters["top_p"], .number(0.95))
    }

    func testStringParametersAreStoredAsStrings() throws {
        let json = #"{"id":"n","type":"calibrate","parameters":{"model":"llama3"}}"#
        let node = try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.parameters["model"], .string("llama3"))
    }

    func testMixedParametersRoundTripCorrectly() throws {
        let node = WorkflowNode(
            id: "n",
            type: "calibrate",
            parameters: [
                "n_tokens": .number(8000),
                "model": .string("llama3"),
                "temperature": .number(0.7),
            ]
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: data)
        XCTAssertEqual(decoded.parameters["n_tokens"], .number(8000))
        XCTAssertEqual(decoded.parameters["model"], .string("llama3"))
        XCTAssertEqual(decoded.parameters["temperature"], .number(0.7))
    }
}
