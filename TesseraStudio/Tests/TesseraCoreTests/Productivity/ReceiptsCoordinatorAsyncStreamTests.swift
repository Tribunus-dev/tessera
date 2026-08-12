import XCTest
@testable import TesseraCore

/// Tests for the `ReceiptsCoordinator.receiptStream()`
/// `AsyncStream<Receipt>` API (Wave 3B, agent-ux-fatigue
/// review #5). The stream replaces the bridge's 200ms
/// polling with a push-based observation. The tests cover:
///
/// - The stream emits each new receipt registered with the
///   coordinator.
/// - P95 latency from `register(receipt:)` to the
///   subscriber's `for await` resumption is below 100 ms
///   (the Wave 3B primary metric).
/// - The drop counter is 0 under normal use (no consumer
///   falling behind).
/// - The drop counter increments when a subscriber's
///   buffer is full (back-pressure anti-metric).
/// - Multiple subscribers each receive every emission
///   (broadcast).
final class ReceiptsCoordinatorAsyncStreamTests: XCTestCase {

    // MARK: - Factory

    /// Build a minimal ``Receipt`` for tests. The
    /// signature is a zero-byte `Data` (the tests do not
    /// exercise signature verification; ``TesseraActionVerifier``
    /// tests cover that path). The mutations are a
    /// ``setDocumentTitle`` so the test factory does not
    /// need a real ``Block`` payload.
    private func makeReceipt(
        id: UUID = UUID(),
        documentID: UUID = UUID(),
        summary: String = "test",
        timestamp: Date = Date()
    ) -> Receipt {
        Receipt(
            id: id,
            documentID: documentID,
            actor: .user(UUID()),
            mutations: [.setDocumentTitle(title: summary)],
            timestamp: timestamp,
            priorReceiptID: nil,
            signature: Data(),
            c2paManifest: nil,
            summary: summary,
            preMutationSnapshot: [:],
            voidedBy: nil
        )
    }

    // MARK: - Stream emission

    func testStreamEmitsRegisteredReceipt() async throws {
        let coord = ReceiptsCoordinator()
        let stream = await coord.receiptStream()
        let receipt = makeReceipt(summary: "first")

        // Register on a detached task so the consumer can
        // be in the for-await loop first.
        Task { await coord.register(receipt: receipt) }

        var iterator = stream.makeAsyncIterator()
        let emitted = await iterator.next()
        XCTAssertEqual(emitted?.id, receipt.id)
        XCTAssertEqual(emitted?.summary, "first")
    }

    func testStreamEmitsEveryRegisteredReceiptInOrder() async throws {
        let coord = ReceiptsCoordinator()
        let stream = await coord.receiptStream()
        let n = 10
        let receipts = (0..<n).map { makeReceipt(summary: "r\($0)") }

        Task {
            for r in receipts {
                await coord.register(receipt: r)
            }
        }

        var iterator = stream.makeAsyncIterator()
        var collected: [Receipt] = []
        for _ in 0..<n {
            if let r = await iterator.next() {
                collected.append(r)
            }
        }
        XCTAssertEqual(collected.count, n)
        XCTAssertEqual(
            collected.map(\.summary),
            receipts.map(\.summary)
        )
    }

    // MARK: - Primary metric: P95 latency

    func testP95LatencyFromRegisterToEmissionUnder100ms() async throws {
        let coord = ReceiptsCoordinator()
        let stream = await coord.receiptStream()
        let n = 50
        var latenciesMs: [Double] = []
        latenciesMs.reserveCapacity(n)

        // Pump a single receipt at a time and measure
        // the time from `register` to the iterator's
        // resumption. This is the per-receipt latency
        // the primary metric captures.
        for i in 0..<n {
            let r = makeReceipt(summary: "latency-\(i)")
            let start = DispatchTime.now()
            Task { await coord.register(receipt: r) }
            var iterator = stream.makeAsyncIterator()
            guard let emitted = await iterator.next(),
                  emitted.id == r.id else {
                XCTFail("did not receive receipt #\(i)")
                return
            }
            let end = DispatchTime.now()
            let elapsedNs = end.uptimeNanoseconds &- start.uptimeNanoseconds
            let elapsedMs = Double(elapsedNs) / 1_000_000.0
            latenciesMs.append(elapsedMs)
            _ = emitted
        }

        // P95 of the sample. Sort and pick the
        // floor(n * 0.95)-th element.
        let sorted = latenciesMs.sorted()
        let p95Index = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        let p95 = sorted[max(0, min(p95Index, sorted.count - 1))]
        XCTAssertLessThan(
            p95, 100.0,
            "P95 latency \(p95) ms exceeds 100 ms budget"
        )
    }

    // MARK: - Anti-metric: drop count

    func testDropCountIsZeroUnderNormalUse() async {
        let coord = ReceiptsCoordinator()
        let stream = await coord.receiptStream()

        // Register and consume in lock-step; consumer
        // can never fall behind.
        let n = 20
        let receipts = (0..<n).map { makeReceipt(summary: "ok-\($0)") }
        Task {
            for r in receipts {
                await coord.register(receipt: r)
            }
        }
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<n {
            _ = await iterator.next()
        }

        let drops = await coord.droppedReceiptCount
        XCTAssertEqual(drops, 0)
    }

    func testDropCountIncrementsWhenBufferFills() async {
        let coord = ReceiptsCoordinator()
        // Per-subscriber buffer is 64. Register > 64
        // receipts WITHOUT consuming; the first 64 are
        // buffered, the rest are dropped from this
        // subscriber's view.
        let stream = await coord.receiptStream()
        let n = 200
        let receipts = (0..<n).map { makeReceipt(summary: "drop-\($0)") }

        // Detached producer task; we never iterate the
        // stream so the buffer fills and the rest drop.
        Task.detached {
            for r in receipts {
                await coord.register(receipt: r)
            }
        }

        // Wait for the producer to drain. 200 yields
        // complete in well under a second; sleep 200 ms
        // to be safe.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Now consume; the first 64 should be the
        // newest 64 (the buffer is `.bufferingNewest`),
        // and the drop counter should reflect the
        // 200 - 64 = 136 drops.
        var iterator = stream.makeAsyncIterator()
        var collected: [Receipt] = []
        for _ in 0..<64 {
            if let r = await iterator.next() {
                collected.append(r)
            }
        }
        // The buffer should be saturated with the
        // newest 64; we just drained them.
        let after = await iterator.next()
        XCTAssertNil(after, "stream should be exhausted after the buffer drains")

        let drops = await coord.droppedReceiptCount
        XCTAssertGreaterThan(drops, 0,
            "back-pressure should have caused drops; got \(drops)")

        // Sanity: the surviving 64 are the LAST 64 we
        // registered (newest policy).
        XCTAssertEqual(collected.first?.summary, "drop-\(n - 64)")
        XCTAssertEqual(collected.last?.summary, "drop-\(n - 1)")
    }

    // MARK: - Broadcast

    func testMultipleSubscribersEachReceiveEmissions() async throws {
        let coord = ReceiptsCoordinator()
        let streamA = await coord.receiptStream()
        let streamB = await coord.receiptStream()

        let n = 5
        let receipts = (0..<n).map { makeReceipt(summary: "fan-\($0)") }
        Task {
            for r in receipts {
                await coord.register(receipt: r)
            }
        }

        var iterA = streamA.makeAsyncIterator()
        var iterB = streamB.makeAsyncIterator()
        var collectedA: [Receipt] = []
        var collectedB: [Receipt] = []
        for _ in 0..<n {
            if let r = await iterA.next() { collectedA.append(r) }
            if let r = await iterB.next() { collectedB.append(r) }
        }
        XCTAssertEqual(collectedA.count, n)
        XCTAssertEqual(collectedB.count, n)
        XCTAssertEqual(
            collectedA.map(\.summary),
            receipts.map(\.summary)
        )
        XCTAssertEqual(
            collectedB.map(\.summary),
            receipts.map(\.summary)
        )
    }

    // MARK: - Current snapshot

    func testCurrentReceiptsReturnsRegisteredSet() async {
        let coord = ReceiptsCoordinator()
        let r1 = makeReceipt(summary: "a")
        let r2 = makeReceipt(summary: "b")
        await coord.register(receipt: r1)
        await coord.register(receipt: r2)
        let snap = await coord.currentReceipts()
        XCTAssertEqual(snap.map(\.id), [r1.id, r2.id])
        XCTAssertEqual(snap.map(\.summary), ["a", "b"])
    }

    // MARK: - Independence: registration does not crash without subscribers

    func testRegisterWithNoSubscribersDoesNotCrash() async {
        let coord = ReceiptsCoordinator()
        await coord.register(receipt: makeReceipt())
        // No subscribers. The drop count should still be 0
        // (nothing to drop into).
        let drops = await coord.droppedReceiptCount
        XCTAssertEqual(drops, 0)
    }
}
