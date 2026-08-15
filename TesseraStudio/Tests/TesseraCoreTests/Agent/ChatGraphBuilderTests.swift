import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/ChatGraphBuilder.swift doc
// comment -- the fixed topology: "entry intake -> router conditional edge
// -> tessy / sky / synthesis -> __end__" and "team-up: run tessy first,
// then sky via synthesis". This file asserts the graph STRUCTURE
// (`StateGraph.nodes` / `.edges` / `.conditionalEdges` / `.entryPoint`,
// all public read-only properties) without executing any node closure --
// running a node would require driving a real `TesseraAgentLoop.run()`
// against an LLM provider, which is out of scope for a structural test.
@MainActor
final class ChatGraphBuilderTests: DoctrineTestCase {

    private func makeLoop(persona: AgentPersona) -> TesseraAgentLoop {
        TesseraAgentLoop(
            registry: TesseraToolRegistry(tools: []),
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: PlaceholderLLMProvider(),
            persona: persona
        )
    }

    // MARK: - build(): the empty/placeholder graph

    func testEmptyBuildHasAnIntakeEntryPointEdgeToEnd() {
        let graph = ChatGraphBuilder.build()
        XCTAssertEqual(graph.entryPoint, "intake")
        XCTAssertTrue(graph.nodes.contains { $0.id == "intake" })
        XCTAssertTrue(graph.edges.contains(StateGraphEdge(from: "intake", to: stateGraphEnd)))
    }

    // MARK: - build(userMessage:decision:...): the real per-turn graph

    func testFullBuildHasIntakeTessySkyNodes() {
        let graph = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: false),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        let nodeIDs = Set(graph.nodes.map(\.id))
        XCTAssertEqual(nodeIDs, ["intake", "tessy", "sky"])
    }

    func testFullBuildEntryPointIsIntake() {
        let graph = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: false),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        XCTAssertEqual(graph.entryPoint, "intake")
    }

    func testFullBuildRoutesTessyAndSkyToEnd() {
        let graph = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: false),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        XCTAssertTrue(graph.edges.contains(StateGraphEdge(from: "tessy", to: stateGraphEnd)))
        XCTAssertTrue(graph.edges.contains(StateGraphEdge(from: "sky", to: stateGraphEnd)))
    }

    func testFullBuildHasOneConditionalEdgeFromIntakeWithThreeBranches() throws {
        let graph = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: false),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        XCTAssertEqual(graph.conditionalEdges.count, 1)
        let conditional = try XCTUnwrap(graph.conditionalEdges.first)
        XCTAssertEqual(conditional.from, "intake")
        XCTAssertEqual(conditional.branches, ["tessy": "tessy", "sky": "sky", "both": "tessy"])
    }

    // MARK: - Team-up: an extra tessy -> sky edge is added

    func testTeamUpDecisionAddsATessyToSkyEdge() {
        let teamUp = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: true),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        XCTAssertTrue(teamUp.edges.contains(StateGraphEdge(from: "tessy", to: "sky")))
    }

    func testNonTeamUpDecisionHasNoTessyToSkyEdge() {
        let soloTessy = ChatGraphBuilder.build(
            userMessage: "hi",
            decision: DualAgentRoutingDecision(useTessy: true, useSky: false),
            prompt: "hi",
            tessyLoop: makeLoop(persona: .tessy),
            skyLoop: makeLoop(persona: .sky),
            onText: { _, _ in }, onToolCall: { _, _, _ in }, onFinalize: { _ in }
        )
        XCTAssertFalse(soloTessy.edges.contains(StateGraphEdge(from: "tessy", to: "sky")))
    }

    // MARK: - Hooks.init: onToolResult defaults to a no-op (doc comment:
    // "optional (default no-op) so the call site that has no use for
    // tool results (e.g. tests) can omit it")

    func testHooksOnToolResultDefaultsToANoOpThatDoesNotCrash() async {
        let hooks = ChatGraphBuilder.Hooks(
            onText: { _, _ in },
            onToolCall: { _, _, _ in },
            onFinalize: { _ in }
        )
        // Calling the default no-op must not throw or crash.
        await hooks.onToolResult(.tessy, "some_tool", .ok("x"))
    }
}
