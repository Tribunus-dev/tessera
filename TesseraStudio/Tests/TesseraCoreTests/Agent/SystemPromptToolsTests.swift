import XCTest
@testable import TesseraCore

// MARK: - SystemPromptStore Tests

@MainActor
final class SystemPromptStoreTests: XCTestCase {

    private var store: SystemPromptStore!
    private var tempDir: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.tempDir = tmp
        self.store = SystemPromptStore(store: TesseraLearningStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Add

    func testAddOverlayInsertsActiveOverlay() async throws {
        let overlay = SystemPromptOverlay(tag: "code-style", content: "Prefer early returns.")
        try await store.add(overlay)

        let active = await store.activeOverlays
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].tag, "code-style")
        XCTAssertEqual(active[0].content, "Prefer early returns.")
        XCTAssertFalse(active[0].outcomeBased)
        XCTAssertNil(active[0].supersededBy)
    }

    func testAddOverlayPersists() async throws {
        let overlay = SystemPromptOverlay(tag: "persistence-test", content: "Must survive reload.")
        try await store.add(overlay)

        // Re-open the store from disk.
        let reloaded = SystemPromptStore(store: TesseraLearningStore(directory: tempDir))
        let active = await reloaded.activeOverlays
        XCTAssertEqual(active.map(\.tag), ["persistence-test"])
    }

    func testAddEmptyContentIsValid() async throws {
        let overlay = SystemPromptOverlay(tag: "placeholder", content: "")
        try await store.add(overlay)

        let active = await store.activeOverlays
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(active[0].content.isEmpty)
    }

    func testAddEmptyTagThrows() async throws {
        let overlay = SystemPromptOverlay(tag: "", content: "content")
        do {
            try await store.add(overlay)
            XCTFail("Expected StoreError.overlayNotFound")
        } catch SystemPromptStore.StoreError.overlayNotFound {
            // expected
        }
    }

    // MARK: - Supersede

    func testSupersedeMovesFromActiveToHistory() async throws {
        let old = SystemPromptOverlay(tag: "old", content: "old content")
        let new = SystemPromptOverlay(tag: "new", content: "new content")
        try await store.add(old)
        try await store.add(new)

        try await store.supersede(oldID: old.id, by: new.id)

        let active = await store.activeOverlays
        XCTAssertEqual(active.map(\.tag), ["new"])
        let all = await store.allOverlays
        XCTAssertEqual(all.map(\.tag), ["new", "old"])
        XCTAssertEqual(all[1].supersededBy, new.id)
    }

    func testSupersedeNonexistentIDThrows() async throws {
        let new = SystemPromptOverlay(tag: "new", content: "")
        try await store.add(new)

        do {
            try await store.supersede(oldID: UUID(), by: new.id)
            XCTFail("Expected StoreError.overlayNotFound")
        } catch SystemPromptStore.StoreError.overlayNotFound {
            // expected
        }
    }

    func testSupersedeTargetNonexistentThrows() async throws {
        let old = SystemPromptOverlay(tag: "old", content: "")
        try await store.add(old)

        do {
            try await store.supersede(oldID: old.id, by: UUID())
            XCTFail("Expected StoreError.supersedeTargetNotFound")
        } catch SystemPromptStore.StoreError.supersedeTargetNotFound {
            // expected
        }
    }

    func testSupersedeAlreadySupersededThrows() async throws {
        let old = SystemPromptOverlay(tag: "old", content: "")
        let mid = SystemPromptOverlay(tag: "mid", content: "")
        let new = SystemPromptOverlay(tag: "new", content: "")
        try await store.add(old)
        try await store.add(mid)
        try await store.add(new)

        try await store.supersede(oldID: old.id, by: mid.id)

        do {
            try await store.supersede(oldID: old.id, by: new.id)
            XCTFail("Expected StoreError.alreadySuperseded")
        } catch SystemPromptStore.StoreError.alreadySuperseded {
            // expected
        }
    }

    // MARK: - Update

    func testUpdateChangesContent() async throws {
        let overlay = SystemPromptOverlay(tag: "test", content: "original")
        try await store.add(overlay)

        try await store.update(id: overlay.id, content: "updated", outcomeBased: true)

        let active = await store.activeOverlays
        XCTAssertEqual(active[0].content, "updated")
        XCTAssertTrue(active[0].outcomeBased)
    }

    func testUpdateNonexistentThrows() async throws {
        do {
            try await store.update(id: UUID(), content: "x")
            XCTFail("Expected StoreError.overlayNotFound")
        } catch SystemPromptStore.StoreError.overlayNotFound {
            // expected
        }
    }

    func testUpdateSupersededThrows() async throws {
        let old = SystemPromptOverlay(tag: "old", content: "")
        let new = SystemPromptOverlay(tag: "new", content: "")
        try await store.add(old)
        try await store.add(new)
        try await store.supersede(oldID: old.id, by: new.id)

        do {
            try await store.update(id: old.id, content: "cannot update superseded")
            XCTFail("Expected StoreError.alreadySuperseded")
        } catch SystemPromptStore.StoreError.alreadySuperseded {
            // expected
        }
    }

    // MARK: - Delete

    func testDeleteRemovesCompletely() async throws {
        let overlay = SystemPromptOverlay(tag: "delete-me", content: "")
        try await store.add(overlay)

        try await store.delete(id: overlay.id)

        let all = await store.allOverlays
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - asPromptSection

    func testAsPromptSectionEmpty() async {
        let section = await store.asPromptSection()
        XCTAssertEqual(section, "")
    }

    func testAsPromptSectionRendersActiveOverlays() async throws {
        try await store.add(SystemPromptOverlay(tag: "style", content: "Use early returns."))
        try await store.add(SystemPromptOverlay(tag: "safety", content: "Always validate inputs."))

        let section = await store.asPromptSection()
        XCTAssertTrue(section.contains("## [style]"))
        XCTAssertTrue(section.contains("Use early returns."))
        XCTAssertTrue(section.contains("## [safety]"))
        XCTAssertTrue(section.contains("Always validate inputs."))
    }

    func testAsPromptSectionSkipsEmptyContent() async throws {
        try await store.add(SystemPromptOverlay(tag: "placeholder", content: ""))
        let section = await store.asPromptSection()
        XCTAssertTrue(section.contains("## [placeholder]"))
        XCTAssertTrue(section.contains("(empty"))
    }

    // MARK: - Summary

    func testSummaryTracksCounts() async throws {
        try await store.add(SystemPromptOverlay(tag: "a", content: "", outcomeBased: true))
        try await store.add(SystemPromptOverlay(tag: "b", content: ""))
        try await store.add(SystemPromptOverlay(tag: "c", content: "", outcomeBased: true))
        let new = SystemPromptOverlay(tag: "d", content: "", outcomeBased: false)
        try await store.add(new)
        try await store.supersede(oldID: try XCTUnwrap((await store.allOverlays).first(where: { $0.tag == "a" }).map(\.id)), by: new.id)

        let summary = await store.summary()
        XCTAssertEqual(summary.activeCount, 3) // b, c, d
        XCTAssertEqual(summary.totalCount, 4) // all
        XCTAssertEqual(summary.outcomeBasedCount, 2) // a, c
    }
}

// MARK: - GetSystemPromptContextTool Tests

@MainActor
final class GetSystemPromptContextToolTests: XCTestCase {

    private var store: SystemPromptStore!
    private var tempDir: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.tempDir = tmp
        self.store = SystemPromptStore(store: TesseraLearningStore(directory: tmp))
        // Inject the store into the static shared slot so the tool can find it.
        TesseraToolRegistry.sharedSystemPromptStore = store
    }

    override func tearDown() async throws {
        // Clear the static shared store to avoid leaking state between tests.
        TesseraToolRegistry.sharedSystemPromptStore = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEmptyStoreReturnsNoOverlays() async throws {
        let tool = GetSystemPromptContextTool(outcomeReader: NoOpOutcomeReader())
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("(none)"))
        let count = result.data["active_overlay_count"]?.numberValue
        XCTAssertEqual(count, 0)
    }

    func testActiveOverlaysShownInOutput() async throws {
        try await store.add(SystemPromptOverlay(tag: "test-overlay", content: "Always run tests before commit."))
        try await store.add(SystemPromptOverlay(tag: "outcome-test", content: "Trust the eval.", outcomeBased: true))

        let tool = GetSystemPromptContextTool(outcomeReader: NoOpOutcomeReader())
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("## [test-overlay]"))
        XCTAssertTrue(result.output.contains("Always run tests before commit."))
        XCTAssertTrue(result.output.contains("## [outcome-test]"))
        XCTAssertTrue(result.output.contains("[outcome-based]"))
        XCTAssertTrue(result.output.contains("Trust the eval."))

        let count = result.data["active_overlay_count"]?.numberValue
        XCTAssertEqual(count, 2)
        let obCount = result.data["outcome_based_overlay_count"]?.numberValue
        XCTAssertEqual(obCount, 1)
    }

    func testIncludeOutcomesIncludesDigest() async throws {
        let tool = GetSystemPromptContextTool(outcomeReader: NoOpOutcomeReader())
        let result = try await tool.execute(arguments: [
            "include_outcomes": .bool(true),
            "outcome_limit": .number(10)
        ])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Recent tool outcomes"))
        XCTAssertTrue(result.output.contains("(no recent outcomes available)"))
    }

    func testTokenEstimateIsPositive() async throws {
        try await store.add(SystemPromptOverlay(tag: "long-content", content: String(repeating: "x", count: 200)))

        let tool = GetSystemPromptContextTool(outcomeReader: NoOpOutcomeReader())
        let result = try await tool.execute(arguments: [:])

        let estimate = result.data["total_token_estimate"]?.numberValue ?? 0
        XCTAssertGreaterThan(estimate, 0)
    }
}

// MARK: - UpdateSystemPromptTool Tests

@MainActor
final class UpdateSystemPromptToolTests: XCTestCase {

    private var store: SystemPromptStore!
    private var tempDir: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.tempDir = tmp
        self.store = SystemPromptStore(store: TesseraLearningStore(directory: tmp))
        TesseraToolRegistry.sharedSystemPromptStore = store
    }

    override func tearDown() async throws {
        TesseraToolRegistry.sharedSystemPromptStore = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Add

    func testAddCreatesOverlay() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("add"),
            "tag": .string("calibration-hint"),
            "content": .string("Always use the imatrix v2 format for calibration."),
        ])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Overlay added successfully"))
        let overlayID = result.data["overlay_id"]?.stringValue
        XCTAssertNotNil(overlayID)
        XCTAssertEqual(result.data["action"]?.stringValue, "add")
        XCTAssertEqual(result.data["active"]?.boolValue, true)

        let active = await store.activeOverlays
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].tag, "calibration-hint")
        XCTAssertEqual(active[0].content, "Always use the imatrix v2 format for calibration.")
        XCTAssertFalse(active[0].outcomeBased)
    }

    func testAddWithOutcomeBasedFlag() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("add"),
            "tag": .string("eval-guided"),
            "content": .string("Trust the PPL metric above 0.5%."),
            "outcome_based": .bool(true),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data["outcome_based"]?.boolValue, true)

        let active = await store.activeOverlays
        XCTAssertTrue(active[0].outcomeBased)
    }

    func testAddEmptyContentAllowed() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("add"),
            "tag": .string("placeholder"),
            "content": .string(""),
        ])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("(empty overlay)"))
    }

    func testAddMissingTagFails() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("add"),
            "content": .string("no tag"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("tag is required"))
    }

    func testAddMissingContentFails() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("add"),
            "tag": .string("has-no-content"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("content is required"))
    }

    // MARK: - Update

    func testUpdateModifiesExistingOverlay() async throws {
        try await store.add(SystemPromptOverlay(tag: "updateme", content: "old"))
        let id = (await store.activeOverlays)[0].id

        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("update"),
            "overlay_id": .string(id.uuidString),
            "content": .string("new content"),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data["action"]?.stringValue, "update")

        let active = await store.activeOverlays
        XCTAssertEqual(active[0].content, "new content")
    }

    func testUpdateNonexistentOverlayFails() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("update"),
            "overlay_id": .string(UUID().uuidString),
            "content": .string("x"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("overlay not found"))
    }

    // MARK: - Revert

    func testRevertSupersedesOverlayWithReplacement() async throws {
        try await store.add(SystemPromptOverlay(tag: "old", content: "old"))
        let oldID = (await store.activeOverlays)[0].id
        try await store.add(SystemPromptOverlay(tag: "new", content: "new"))
        let newID = (await store.activeOverlays)[0].id

        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("revert"),
            "overlay_id": .string(oldID.uuidString),
            "new_overlay_id": .string(newID.uuidString),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data["action"]?.stringValue, "revert")
        XCTAssertEqual(result.data["active"]?.boolValue, false)

        let active = await store.activeOverlays
        XCTAssertEqual(active.map(\.tag), ["new"])
        let all = await store.allOverlays
        XCTAssertEqual(all.first(where: { $0.tag == "old" })?.supersededBy, newID)
    }

    func testRevertBareRevertCreatesNullOverlay() async throws {
        try await store.add(SystemPromptOverlay(tag: "todelete", content: "delete me"))
        let oldID = (await store.activeOverlays)[0].id

        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("revert"),
            "overlay_id": .string(oldID.uuidString),
        ])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data["bare_revert"]?.boolValue, true)

        let active = await store.activeOverlays
        // Should have the null overlay (bare revert), not the old overlay
        XCTAssertTrue(active.allSatisfy { $0.tag.hasPrefix("revert-") })
        XCTAssertEqual(active.count, 1)
    }

    // MARK: - Invalid action

    func testInvalidActionFails() async throws {
        let tool = UpdateSystemPromptTool(overridingStore: store)
        let result = try await tool.execute(arguments: [
            "action": .string("delete"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("must be 'add', 'update', or 'revert'"))
    }
}

// MARK: - Mutation Tests

@MainActor
final class SystemPromptMutationTests: XCTestCase {

    func testSetSystemPromptOverlayShortDescription() {
        let addMutation = Mutation.setSystemPromptOverlay(
            id: UUID(),
            action: .add,
            tag: "calibration-hint",
            content: "Use PPL < 1%",
            supersededBy: nil,
            outcomeBased: true
        )
        XCTAssertTrue(addMutation.shortDescription.contains("calibration-hint"))
        XCTAssertTrue(addMutation.shortDescription.contains("add"))

        let updateMutation = Mutation.setSystemPromptOverlay(
            id: UUID(),
            action: .update,
            tag: "style",
            content: "updated",
            supersededBy: nil,
            outcomeBased: false
        )
        XCTAssertTrue(updateMutation.shortDescription.contains("update"))
        XCTAssertTrue(updateMutation.shortDescription.contains("style"))

        let revertMutation = Mutation.setSystemPromptOverlay(
            id: UUID(),
            action: .revert,
            tag: "old-overlay",
            content: "",
            supersededBy: UUID(),
            outcomeBased: false
        )
        XCTAssertTrue(revertMutation.shortDescription.contains("revert"))
    }

    func testSetSystemPromptOverlayInverseIsEmpty() {
        let mutation = Mutation.setSystemPromptOverlay(
            id: UUID(),
            action: .add,
            tag: "test",
            content: "content",
            supersededBy: nil,
            outcomeBased: false
        )
        // System-prompt overlay inverses are not in-place (no prior content stored
        // in the mutation). The store is the source of truth.
        XCTAssertTrue(mutation.inverse(preMutation: [:]).isEmpty)
    }
}
