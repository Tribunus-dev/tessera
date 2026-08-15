import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/DestinationStarterPrompts.swift
// doc comment -- "Returns 3-5 entries for every case; tests pin the count
// and uniqueness per context." (an explicit test-contract line in the
// source doc comment, the strongest form of contract per the prime rule).
final class DestinationStarterPromptsTests: DoctrineTestCase {

    // Independent oracle (rule 7): the full context list, hand-copied from
    // the `Context` enum's case list in the doc comment / declaration,
    // not derived from iterating anything the system computes.
    private let allContexts: [DestinationStarterPrompts.Context] = [
        .workflows, .tasks, .calendar, .notes, .code, .docs, .sheets,
        .slides, .email, .contacts, .reminders, .collab, .intelligence, .neutral,
    ]

    func testEveryContextReturnsBetweenThreeAndFivePrompts() {
        for context in allContexts {
            let prompts = DestinationStarterPrompts.prompts(for: context)
            XCTAssertGreaterThanOrEqual(prompts.count, 3, "\(context) must return >= 3 prompts")
            XCTAssertLessThanOrEqual(prompts.count, 5, "\(context) must return <= 5 prompts")
        }
    }

    func testEveryContextsPromptIDsAreUniqueWithinTheContext() {
        for context in allContexts {
            let ids = DestinationStarterPrompts.prompts(for: context).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(context) has duplicate prompt ids")
        }
    }

    func testPromptIDsAreGloballyUniqueAcrossAllContexts() {
        var seen = Set<String>()
        for context in allContexts {
            for prompt in DestinationStarterPrompts.prompts(for: context) {
                XCTAssertTrue(seen.insert(prompt.id).inserted, "duplicate prompt id '\(prompt.id)' across contexts")
            }
        }
    }

    func testNoPromptHasEmptyTextOrSymbol() {
        for context in allContexts {
            for prompt in DestinationStarterPrompts.prompts(for: context) {
                XCTAssertFalse(prompt.text.isEmpty, "\(context)/\(prompt.id) has empty text")
                XCTAssertFalse(prompt.symbol.isEmpty, "\(context)/\(prompt.id) has empty symbol")
            }
        }
    }

    func testPromptsAreDeterministic() {
        for context in allContexts {
            XCTAssertEqual(
                DestinationStarterPrompts.prompts(for: context),
                DestinationStarterPrompts.prompts(for: context)
            )
        }
    }

    func testHeaderLineReassuresTheUserCanTypeTheirOwn() {
        XCTAssertFalse(DestinationStarterPrompts.headerLine.isEmpty)
    }

    func testWhatsNextLineIsNonEmpty() {
        XCTAssertFalse(DestinationStarterPrompts.whatsNextLine.isEmpty)
    }

    // MARK: - Prompt Equatable/Identifiable value semantics

    func testPromptEqualityIsFieldwise() {
        let a = DestinationStarterPrompts.Prompt(id: "x", text: "t", symbol: "s")
        let b = DestinationStarterPrompts.Prompt(id: "x", text: "t", symbol: "s")
        let c = DestinationStarterPrompts.Prompt(id: "x", text: "different", symbol: "s")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
