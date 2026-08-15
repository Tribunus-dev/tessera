import XCTest
@testable import TesseraCore

/// A minimal, deterministic `TesseraTool` used only to exercise
/// `TesseraToolRegistry`'s own logic (lookup, override-by-name, sorted
/// enumeration) without depending on any of the ~29 real tools registered
/// on `.default` (which live outside this cluster's ownership and would
/// make this an implementation-mirroring test rather than a contract
/// test of the registry itself).
private struct StubTool: TesseraTool {
    let name: String
    let description: String
    let parameters: JSONSchema = JSONSchema()
    let defaultApprovalLevel: ApprovalLevel = .prompt

    init(name: String, description: String = "a stub tool") {
        self.name = name
        self.description = description
    }

    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        .ok("stub")
    }
}

// Contract source: Sources/TesseraCore/Agent/TesseraToolRegistry.swift doc
// comments -- lookup by name, `allTools` enumeration for the system
// prompt, and the `default(plus:)` override-by-name composition rule
// ("Extras named the same as a default tool override it").
final class TesseraToolRegistryTests: DoctrineTestCase {

    func testToolNamedFindsARegisteredTool() {
        let registry = TesseraToolRegistry(tools: [StubTool(name: "alpha")])
        XCTAssertEqual(registry.tool(named: "alpha")?.name, "alpha")
    }

    func testToolNamedReturnsNilForUnknownName() {
        let registry = TesseraToolRegistry(tools: [StubTool(name: "alpha")])
        XCTAssertNil(registry.tool(named: "beta"))
    }

    func testAllToolsIsSortedByName() {
        let registry = TesseraToolRegistry(tools: [
            StubTool(name: "zeta"), StubTool(name: "alpha"), StubTool(name: "mu"),
        ])
        XCTAssertEqual(registry.allTools.map(\.name), ["alpha", "mu", "zeta"])
    }

    func testDuplicateNamedToolsInTheInitialListLastOneWins() {
        // The init builds a `[String: any TesseraTool]` dictionary keyed
        // by name, so a later entry with the same name silently replaces
        // an earlier one.
        let registry = TesseraToolRegistry(tools: [
            StubTool(name: "alpha", description: "first"),
            StubTool(name: "alpha", description: "second"),
        ])
        XCTAssertEqual(registry.allTools.count, 1)
        XCTAssertEqual(registry.tool(named: "alpha")?.description, "second")
    }

    func testEmptyRegistryHasNoTools() {
        let registry = TesseraToolRegistry(tools: [])
        XCTAssertTrue(registry.allTools.isEmpty)
        XCTAssertNil(registry.tool(named: "anything"))
    }

    // MARK: - systemPromptToolsBlock: every tool's name + description
    // + parameter schema appears in the block

    func testSystemPromptToolsBlockListsEveryToolsNameAndDescription() {
        let registry = TesseraToolRegistry(tools: [StubTool(name: "alpha", description: "does alpha things")])
        let block = registry.systemPromptToolsBlock()
        XCTAssertTrue(block.contains("## alpha"))
        XCTAssertTrue(block.contains("does alpha things"))
    }

    func testSystemPromptToolsBlockOnEmptyRegistryHasNoToolHeadings() {
        let registry = TesseraToolRegistry(tools: [])
        XCTAssertFalse(registry.systemPromptToolsBlock().contains("## "))
    }

    // MARK: - default(plus:): extras with the same name as a default tool
    // override it (doc comment, verbatim rule)

    func testDefaultPlusExtraOverridesADefaultToolOfTheSameName() {
        // Pick a name known to exist in the real default registry.
        let defaultTool = TesseraToolRegistry.default.tool(named: "list_models")
        XCTAssertNotNil(defaultTool, "sanity: list_models is a v1 default tool")
        let override = StubTool(name: "list_models", description: "overridden for the test")
        let combined = TesseraToolRegistry.default(plus: [override])
        XCTAssertEqual(combined.tool(named: "list_models")?.description, "overridden for the test")
    }

    func testDefaultPlusExtraAddsANewToolAlongsideTheDefaults() {
        let combined = TesseraToolRegistry.default(plus: [StubTool(name: "brand_new_tool")])
        XCTAssertNotNil(combined.tool(named: "brand_new_tool"))
        // The defaults are still present.
        XCTAssertNotNil(combined.tool(named: "list_models"))
    }

    func testDefaultPlusEmptyExtrasIsEquivalentToDefault() {
        let combined = TesseraToolRegistry.default(plus: [any TesseraTool]())
        XCTAssertEqual(combined.allTools.count, TesseraToolRegistry.default.allTools.count)
    }

    // MARK: - The default registry is at least constructible and
    // non-empty (a smoke check independent of the exact tool roster,
    // which is not named in any contract this cluster located -- see
    // findings).

    func testDefaultRegistryIsNonEmpty() {
        XCTAssertFalse(TesseraToolRegistry.default.allTools.isEmpty)
    }

    func testDefaultRegistryHasNoDuplicateNames() {
        let names = TesseraToolRegistry.default.allTools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "the default registry must not silently shadow a tool name")
    }
}
