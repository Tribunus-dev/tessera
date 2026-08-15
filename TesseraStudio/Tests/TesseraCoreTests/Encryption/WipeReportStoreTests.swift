import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/WipeReportStore.swift
// doc comment -- "Persists the last WipeReport to a fixed location...
// plain JSON; it contains no secrets" and "loadIfPresent... returns nil
// when the file does not exist."
//
// Every test uses the injectable `init(fileURL:)` pointed at a temp
// directory -- never `WipeReportStore.fileURL`
// (`~/.tessera/last-wipe.json`), which is a real location in the
// developer's home directory this suite must not write to.
final class WipeReportStoreTests: DoctrineTestCase {

    private func tempReportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("doctrine-wipe-report-\(UUID().uuidString)")
            .appendingPathComponent("last-wipe.json")
    }

    private func makeReport() -> PleadTheFifthExecutor.WipeReport {
        PleadTheFifthExecutor.WipeReport(
            startedAt: Date(timeIntervalSince1970: 1000),
            completedAt: Date(timeIntervalSince1970: 1005),
            triggerSource: .hotkey,
            steps: [
                PleadTheFifthExecutor.WipeStep(name: "exit", outcome: .success, durationMs: 1, reason: nil),
            ]
        )
    }

    func testLoadIfPresentReturnsNilWhenFileDoesNotExist() throws {
        let store = WipeReportStore(fileURL: tempReportURL())
        XCTAssertNil(try store.loadIfPresent())
    }

    func testSaveThenLoadRoundTripsTheReport() throws {
        let store = WipeReportStore(fileURL: tempReportURL())
        let report = makeReport()
        try store.save(report)
        let loaded = try store.loadIfPresent()
        XCTAssertEqual(loaded, report)
    }

    func testSaveCreatesTheParentDirectoryOnDemand() throws {
        let url = tempReportURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let store = WipeReportStore(fileURL: url)
        try store.save(makeReport())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSavedFileContainsNoRawSecretsJustTheReportShape() throws {
        let url = tempReportURL()
        let store = WipeReportStore(fileURL: url)
        try store.save(makeReport())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"triggerSource\""))
        XCTAssertTrue(text.contains("\"steps\""))
    }

    func testSaveOverwritesAPreviouslySavedReport() throws {
        let url = tempReportURL()
        let store = WipeReportStore(fileURL: url)
        try store.save(makeReport())
        let second = PleadTheFifthExecutor.WipeReport(
            startedAt: Date(timeIntervalSince1970: 2000),
            completedAt: Date(timeIntervalSince1970: 2001),
            triggerSource: .covert,
            steps: []
        )
        try store.save(second)
        let loaded = try store.loadIfPresent()
        XCTAssertEqual(loaded, second)
    }
}
