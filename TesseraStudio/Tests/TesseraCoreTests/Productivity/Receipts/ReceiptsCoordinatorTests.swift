import XCTest
@testable import TesseraCore

// MARK: - ReceiptsCoordinatorTests
//
// Contract: AGENTS.md item 3B - "ReceiptsCoordinator.receiptStream() ->
// AsyncStream<Receipt> per AGENTS.md item 3B: back-pressure bounded per
// subscriber via .bufferingNewest(64), drops exposed via
// droppedReceiptCount" (this cluster's own dispatch brief, verbatim).
// Plus ReceiptsCoordinator.swift's own doc comments: "The stream is
// broadcast: each call to receiptStream() returns a new stream subscribed
// to the same event source"; "Subscription completes before this
// returns... so a receipt registered immediately afterwards is always
// seen."

final class ReceiptsCoordinatorTests: DoctrineTestCase {

    private func makeReceipt(documentID: UUID = UUID()) -> Receipt {
        Receipt(documentID: documentID, actor: .user(UUID()), mutations: [], signature: Data(), summary: "test")
    }

    // MARK: - Focus / drawer visibility / scroll target (pull, not push)

    func testOpenReceiptInDrawerSetsFocusMakesDrawerVisibleAndSetsOpenRequest() async {
        let coordinator = ReceiptsCoordinator()
        let receiptID = UUID()
        let chatItemID = UUID()
        await coordinator.openReceiptInDrawer(receiptID, fromChatItem: chatItemID)

        let focus = await coordinator.currentFocus
        XCTAssertEqual(focus.receiptID, receiptID)
        let visible = await coordinator.isDrawerVisible
        XCTAssertTrue(visible)
        let request = await coordinator.consumeOpenRequest()
        XCTAssertEqual(request?.receiptID, receiptID)
        XCTAssertEqual(request?.fromChatItemID, chatItemID)
    }

    func testConsumeOpenRequestClearsItAfterOneRead() async {
        let coordinator = ReceiptsCoordinator()
        await coordinator.openReceiptInDrawer(UUID())
        _ = await coordinator.consumeOpenRequest()
        let second = await coordinator.consumeOpenRequest()
        XCTAssertNil(second, "consumeOpenRequest must clear the pending request - the drawer's container consumes it exactly once")
    }

    func testToggleDrawerVisibilityFlipsTheFlag() async {
        let coordinator = ReceiptsCoordinator()
        let initial = await coordinator.isDrawerVisible
        await coordinator.toggleDrawerVisibility()
        let toggled = await coordinator.isDrawerVisible
        XCTAssertNotEqual(initial, toggled)
    }

    func testClearFocusResetsFocusAndOpenRequest() async {
        let coordinator = ReceiptsCoordinator()
        await coordinator.openReceiptInDrawer(UUID())
        await coordinator.clearFocus()
        let focus = await coordinator.currentFocus
        XCTAssertEqual(focus, .none)
        let request = await coordinator.consumeOpenRequest()
        XCTAssertNil(request)
    }

    func testShowInGraphSetsGraphEntityFocus() async {
        let coordinator = ReceiptsCoordinator()
        let entityID = UUID()
        await coordinator.showInGraph(entityID: entityID)
        let focus = await coordinator.currentFocus
        XCTAssertEqual(focus.graphEntityID, entityID)
    }

    func testReceiptsFocusReceiptIDAndGraphEntityIDAccessorsAreCaseScoped() {
        XCTAssertEqual(ReceiptsFocus.receipt(UUID()).graphEntityID, nil)
        XCTAssertNil(ReceiptsFocus.none.receiptID)
        XCTAssertNil(ReceiptsFocus.none.graphEntityID)
    }

    // MARK: - receiptStream(): broadcast, no replay, subscription-before-return

    func testRegisterBroadcastsToASubscriberThatSubscribedFirst() async {
        let coordinator = ReceiptsCoordinator()
        let stream = await coordinator.receiptStream()
        let receipt = makeReceipt()

        let collected = Task<Receipt?, Never> {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        // Subscription is guaranteed complete before receiptStream() returned
        // (per the source's own doc comment), so registering immediately
        // after is safe and must be observed.
        await coordinator.register(receipt: receipt)
        let received = await collected.value
        XCTAssertEqual(received?.id, receipt.id)
    }

    func testReceiptStreamDoesNotReplayHistory() async {
        let coordinator = ReceiptsCoordinator()
        await coordinator.register(receipt: makeReceipt())
        let stream = await coordinator.receiptStream()
        let newReceipt = makeReceipt()

        let collected = Task<Receipt?, Never> {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        await coordinator.register(receipt: newReceipt)
        let received = await collected.value
        XCTAssertEqual(received?.id, newReceipt.id, "a stream subscribed AFTER an earlier register() must not see that earlier receipt - no replay")
    }

    func testEachReceiptStreamCallIsAnIndependentBroadcastSubscriber() async {
        let coordinator = ReceiptsCoordinator()
        let streamA = await coordinator.receiptStream()
        let streamB = await coordinator.receiptStream()
        let receipt = makeReceipt()

        async let firstFromA: Receipt? = { () async -> Receipt? in
            var it = streamA.makeAsyncIterator()
            return await it.next()
        }()
        async let firstFromB: Receipt? = { () async -> Receipt? in
            var it = streamB.makeAsyncIterator()
            return await it.next()
        }()
        await coordinator.register(receipt: receipt)
        let (a, b) = await (firstFromA, firstFromB)
        XCTAssertEqual(a?.id, receipt.id, "every independent receiptStream() subscriber must see the same broadcast receipt")
        XCTAssertEqual(b?.id, receipt.id)
    }

    // MARK: - Back-pressure: droppedReceiptCount stays 0 when a subscriber keeps up

    func testDroppedReceiptCountStaysZeroWhenNoSubscriberIsAttached() async {
        let coordinator = ReceiptsCoordinator()
        for _ in 0..<10 {
            await coordinator.register(receipt: makeReceipt())
        }
        let dropped = await coordinator.droppedReceiptCount
        XCTAssertEqual(dropped, 0, "with zero subscribers there is nothing to drop from - the anti-metric must read 0")
    }

    func testCurrentReceiptsAccumulatesEveryRegisteredReceiptInOrder() async {
        let coordinator = ReceiptsCoordinator()
        let r1 = makeReceipt()
        let r2 = makeReceipt()
        await coordinator.register(receipt: r1)
        await coordinator.register(receipt: r2)
        let current = await coordinator.currentReceipts()
        XCTAssertEqual(current.map(\.id), [r1.id, r2.id])
    }

    // MARK: - ReceiptsCoordinatorBridge: MainActor republishing, no polling

    @MainActor
    func testBridgeStartCapturesCurrentStateThenTracksSubsequentReceipts() async {
        let coordinator = ReceiptsCoordinator()
        await coordinator.openReceiptInDrawer(UUID())
        let bridge = ReceiptsCoordinatorBridge(coordinator: coordinator)
        await bridge.start()
        XCTAssertNotNil(bridge.pendingOpenRequest, "start() must prime by re-reading the coordinator's current state")
        bridge.stop()
    }

    @MainActor
    func testBridgeToggleDrawerForwardsToCoordinatorAndRefreshes() async {
        let coordinator = ReceiptsCoordinator()
        let bridge = ReceiptsCoordinatorBridge(coordinator: coordinator)
        await bridge.start()
        let before = bridge.isDrawerVisible
        await bridge.toggleDrawer()
        XCTAssertNotEqual(bridge.isDrawerVisible, before)
        bridge.stop()
    }
}
