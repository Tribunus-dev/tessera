import XCTest
@testable import TesseraCore

/// Tests for the destination-aware starter prompts (review #1 of the
/// agent-ux-fatigue Tessera Studio audit). The mapping is the heart of
/// the empty-canvas fix; tests pin the count per context and the
/// uniqueness of prompt ids so a refactor that drops a case or copies
/// an id across contexts fails the build.
final class DestinationStarterPromptsTests: XCTestCase {

    /// Stable list for tests. The production API does not expose this as
    /// ``CaseIterable`` because adding a case to the enum should be a
    /// conscious change; tests iterate the explicit list so a forgotten
    /// case in the switch is caught by the test, not the build.
    private static let allContexts: [DestinationStarterPrompts.Context] = [
        .workflows, .tasks, .calendar, .notes, .code, .docs, .sheets,
        .slides, .email, .contacts, .reminders, .collab, .intelligence,
        .neutral,
    ]

    func testEveryContextReturnsThreeToFivePrompts() {
        for context in Self.allContexts {
            let prompts = DestinationStarterPrompts.prompts(for: context)
            XCTAssertGreaterThanOrEqual(
                prompts.count, 3,
                "context \(context) returned fewer than 3 prompts (got \(prompts.count))"
            )
            XCTAssertLessThanOrEqual(
                prompts.count, 5,
                "context \(context) returned more than 5 prompts (got \(prompts.count))"
            )
        }
    }

    func testEveryPromptHasNonEmptyText() {
        for context in Self.allContexts {
            for prompt in DestinationStarterPrompts.prompts(for: context) {
                XCTAssertFalse(
                    prompt.text.trimmingCharacters(in: .whitespaces).isEmpty,
                    "context \(context) has a prompt with empty text: id=\(prompt.id)"
                )
            }
        }
    }

    func testEveryPromptHasUniqueIdPerContext() {
        for context in Self.allContexts {
            let ids = DestinationStarterPrompts.prompts(for: context).map(\.id)
            let unique = Set(ids)
            XCTAssertEqual(
                ids.count, unique.count,
                "context \(context) has duplicate prompt ids: \(ids)"
            )
        }
    }

    func testPromptIdsAreNamespacedByContext() {
        // Helps the team grep prompt ids in analytics events without
        // context-prefix collisions across surfaces.
        var seenIds: [String: DestinationStarterPrompts.Context] = [:]
        for context in Self.allContexts {
            for prompt in DestinationStarterPrompts.prompts(for: context) {
                if let prior = seenIds[prompt.id] {
                    XCTFail(
                        "prompt id '\(prompt.id)' is used by both \(prior) and \(context)"
                    )
                }
                seenIds[prompt.id] = context
            }
        }
    }

    func testHeaderLinesAreNonEmpty() {
        XCTAssertFalse(DestinationStarterPrompts.headerLine.isEmpty)
        XCTAssertFalse(DestinationStarterPrompts.whatsNextLine.isEmpty)
    }

    func testNeutralContextIsTheFallback() {
        // The macOS ContentView maps `Destination == nil` to `.neutral`;
        // any caller that forgets to map still gets a usable list.
        let neutral = DestinationStarterPrompts.prompts(for: .neutral)
        XCTAssertGreaterThanOrEqual(neutral.count, 3)
    }

    func testPromptsListRendersWithoutCrash() {
        // The view is a SwiftUI struct; rendering a single instance is
        // not feasible in a unit test, but constructing the array and
        // the closure type asserts the public API stays usable.
        let view = DestinationStarterPromptsList(
            context: .workflows,
            onSelect: { _ in }
        )
        _ = view.body
    }
}
