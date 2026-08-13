import XCTest
import PostgresNIO
import CryptoKit
@testable import TesseraCore

/// Tests for ``MaterialReceiptPayload`` types and the
/// ``TesseraDataLayer/appendMaterialReceipt(_:)`` path.
///
/// Material receipts are lightweight operation records: no C2PA manifest,
/// no block AST snapshot, no receipt chain linkage. They share the same
/// ed25519 signing key as document receipts.
///
/// The JSON / Codable / typed payload tests are run unconditionally.
/// The data-store integration tests are env-gated on
/// `TESSERA_DB_INTEGRATION=1` and use ``TesseraDataStore`` directly
/// (bypassing ``TesseraDataLayer`` which requires an actor context).
final class MaterialReceiptTests: XCTestCase {

    // MARK: - MaterialReceiptPayload protocol

    func testNoteEditReceiptPayloadReceiptType() {
        let payload = NoteEditReceiptPayload(
            entityID: UUID(),
            action: .create,
            title: "My Note",
            delta: nil
        )
        XCTAssertEqual(payload.receiptType, "note_edit")
    }

    func testEmailReceiptPayloadReceiptType() {
        let payload = EmailReceiptPayload(
            entityID: UUID(),
            action: .send,
            emailID: UUID(),
            threadID: UUID(),
            to: ["alice@example.com"],
            subject: "Hello",
            flagged: true
        )
        XCTAssertEqual(payload.receiptType, "email_operation")
    }

    func testContactReceiptPayloadReceiptType() {
        let payload = ContactReceiptPayload(
            entityID: UUID(),
            action: .create,
            contactID: UUID(),
            fieldsChanged: ["name", "email"],
            linkedTo: nil
        )
        XCTAssertEqual(payload.receiptType, "contact_operation")
    }

    func testTaskReceiptPayloadReceiptType() {
        let payload = TaskReceiptPayload(
            entityID: UUID(),
            action: .create,
            taskID: UUID(),
            fieldsChanged: [],
            newValue: nil
        )
        XCTAssertEqual(payload.receiptType, "task_operation")
    }

    func testReminderReceiptPayloadReceiptType() {
        let payload = ReminderReceiptPayload(
            entityID: UUID(),
            action: .create,
            reminderID: UUID(),
            title: "Review doc",
            due: Date()
        )
        XCTAssertEqual(payload.receiptType, "reminder_operation")
    }

    func testCalendarReceiptPayloadReceiptType() {
        let payload = CalendarReceiptPayload(
            entityID: UUID(),
            action: .create,
            eventID: UUID(),
            title: "Q3 Review",
            fieldsChanged: [],
            response: nil
        )
        XCTAssertEqual(payload.receiptType, "calendar_event_operation")
    }

    func testSheetReceiptPayloadReceiptType() {
        let payload = SheetReceiptPayload(
            entityID: UUID(),
            action: .cellEdit,
            sheetID: UUID(),
            cell: "A1",
            oldValue: nil,
            newValue: .string("hello")
        )
        XCTAssertEqual(payload.receiptType, "sheet_operation")
    }

    func testSlideReceiptPayloadReceiptType() {
        let payload = SlideReceiptPayload(
            entityID: UUID(),
            action: .create,
            deckID: UUID(),
            slideID: nil,
            fieldsChanged: []
        )
        XCTAssertEqual(payload.receiptType, "slide_operation")
    }

    func testCodeReceiptPayloadReceiptType() {
        let payload = CodeReceiptPayload(
            entityID: UUID(),
            action: .fileWrite,
            fileID: UUID(),
            path: "/Users/test/main.swift",
            delta: nil
        )
        XCTAssertEqual(payload.receiptType, "code_file_operation")
    }

    // MARK: - JSON round-trip

    func testNoteEditPayloadJSONRoundTrip() throws {
        let id = UUID()
        let payload = NoteEditReceiptPayload(
            entityID: id,
            action: .updateContent,
            title: "Updated title",
            delta: "{\"insert\":\"Hello\"}"
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["entityID"]?.stringValue, id.uuidString)
        XCTAssertEqual(json["action"]?.stringValue, "updateContent")
        XCTAssertEqual(json["title"]?.stringValue, "Updated title")
        XCTAssertEqual(json["delta"]?.stringValue, "{\"insert\":\"Hello\"}")
    }

    func testEmailPayloadJSONRoundTrip() throws {
        let entityID = UUID()
        let emailID = UUID()
        let threadID = UUID()
        let payload = EmailReceiptPayload(
            entityID: entityID,
            action: .send,
            emailID: emailID,
            threadID: threadID,
            to: ["bob@example.com", "carol@example.com"],
            subject: "Re: Q3 Review",
            flagged: nil
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["entityID"]?.stringValue, entityID.uuidString)
        XCTAssertEqual(json["action"]?.stringValue, "send")
        XCTAssertEqual(json["emailID"]?.stringValue, emailID.uuidString)
        XCTAssertEqual(json["threadID"]?.stringValue, threadID.uuidString)
        // Check the 'to' array using pattern matching.
        if case .array(let toArr) = json["to"] {
            XCTAssertEqual(toArr.compactMap { $0.stringValue }, ["bob@example.com", "carol@example.com"])
        } else {
            XCTFail("expected array for 'to'")
        }
        XCTAssertEqual(json["subject"]?.stringValue, "Re: Q3 Review")
        XCTAssertNil(json["flagged"])
    }

    func testContactPayloadJSONRoundTrip() throws {
        let entityID = UUID()
        let linkedTo = UUID()
        let payload = ContactReceiptPayload(
            entityID: entityID,
            action: .link,
            contactID: entityID,
            fieldsChanged: ["name", "email"],
            linkedTo: linkedTo
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["entityID"]?.stringValue, entityID.uuidString)
        XCTAssertEqual(json["action"]?.stringValue, "link")
        XCTAssertEqual(json["linkedTo"]?.stringValue, linkedTo.uuidString)
        if case .array(let fieldsArr) = json["fieldsChanged"] {
            XCTAssertEqual(fieldsArr.compactMap { $0.stringValue }, ["name", "email"])
        } else {
            XCTFail("expected array for 'fieldsChanged'")
        }
    }

    func testTaskPayloadJSONRoundTrip() throws {
        let id = UUID()
        let payload = TaskReceiptPayload(
            entityID: id,
            action: .complete,
            taskID: id,
            fieldsChanged: ["completedAt"],
            newValue: .string("2026-08-05")
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "complete")
        if case .array(let fieldsArr) = json["fieldsChanged"] {
            XCTAssertEqual(fieldsArr.first?.stringValue, "completedAt")
        } else {
            XCTFail("expected array for 'fieldsChanged'")
        }
        XCTAssertEqual(json["newValue"]?.stringValue, "2026-08-05")
    }

    func testReminderPayloadJSONRoundTrip() throws {
        let id = UUID()
        let dueDate = Date(timeIntervalSince1970: 1_733_164_800)
        let payload = ReminderReceiptPayload(
            entityID: id,
            action: .create,
            reminderID: id,
            title: "Review Q3",
            due: dueDate
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "create")
        XCTAssertEqual(json["title"]?.stringValue, "Review Q3")
        // Due is serialized as ISO-8601 string.
        XCTAssertNotNil(json["due"]?.stringValue)
    }

    func testCalendarPayloadJSONRoundTrip() throws {
        let id = UUID()
        let payload = CalendarReceiptPayload(
            entityID: id,
            action: .respond,
            eventID: id,
            title: "Team sync",
            fieldsChanged: [],
            response: .accepted
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "respond")
        XCTAssertEqual(json["response"]?.stringValue, "accepted")
        XCTAssertEqual(json["title"]?.stringValue, "Team sync")
    }

    func testSheetPayloadJSONRoundTrip() throws {
        let id = UUID()
        let payload = SheetReceiptPayload(
            entityID: id,
            action: .cellEdit,
            sheetID: id,
            cell: "B5",
            oldValue: .string("old"),
            newValue: .number(42)
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "cellEdit")
        XCTAssertEqual(json["cell"]?.stringValue, "B5")
        XCTAssertEqual(json["oldValue"]?.stringValue, "old")
        XCTAssertEqual(json["newValue"]?.numberValue, 42)
    }

    func testSlidePayloadJSONRoundTrip() throws {
        let deckID = UUID()
        let slideID = UUID()
        let payload = SlideReceiptPayload(
            entityID: deckID,
            action: .update,
            deckID: deckID,
            slideID: slideID,
            fieldsChanged: ["title", "body"]
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "update")
        XCTAssertEqual(json["slideID"]?.stringValue, slideID.uuidString)
        if case .array(let fieldsArr) = json["fieldsChanged"] {
            XCTAssertEqual(fieldsArr.compactMap { $0.stringValue }, ["title", "body"])
        } else {
            XCTFail("expected array for 'fieldsChanged'")
        }
    }

    func testCodePayloadJSONRoundTrip() throws {
        let fileID = UUID()
        let payload = CodeReceiptPayload(
            entityID: fileID,
            action: .fileWrite,
            fileID: fileID,
            path: "/Users/test/main.swift",
            delta: "@@ -1,3 +1,4 @@"
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "fileWrite")
        XCTAssertEqual(json["path"]?.stringValue, "/Users/test/main.swift")
        XCTAssertEqual(json["delta"]?.stringValue, "@@ -1,3 +1,4 @@")
    }

    // MARK: - Codable conformance

    func testNotePayloadCodableRoundTrip() throws {
        let payload = NoteEditReceiptPayload(
            entityID: UUID(),
            action: .delete,
            title: nil,
            delta: nil
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(NoteEditReceiptPayload.self, from: data)
        XCTAssertEqual(decoded.action, .delete)
        XCTAssertNil(decoded.title)
    }

    func testTaskPayloadWithJSONValueCodableRoundTrip() throws {
        let payload = TaskReceiptPayload(
            entityID: UUID(),
            action: .update,
            taskID: UUID(),
            fieldsChanged: ["priority"],
            newValue: .object([
                "from": .string("low"),
                "to": .string("high")
            ])
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TaskReceiptPayload.self, from: data)
        XCTAssertEqual(decoded.action, .update)
        XCTAssertEqual(decoded.fieldsChanged, ["priority"])
        if case .object(let obj) = decoded.newValue {
            XCTAssertEqual(obj["from"]?.stringValue, "low")
            XCTAssertEqual(obj["to"]?.stringValue, "high")
        } else {
            XCTFail("expected object for newValue")
        }
    }

    func testReminderPayloadDateRoundTrip() throws {
        let due = Date(timeIntervalSince1970: 1_733_164_800)
        let payload = ReminderReceiptPayload(
            entityID: UUID(),
            action: .create,
            reminderID: UUID(),
            title: "Weekly sync",
            due: due
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ReminderReceiptPayload.self, from: data)
        XCTAssertNotNil(decoded.due)
        // ISO-8601 with fractional seconds has sub-millisecond precision;
        // comparing as timeInterval is sufficient for the test.
        XCTAssertEqual(
            decoded.due!.timeIntervalSince1970,
            due.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - Error cases

    func testReminderReceiptPayloadWithoutDueDate() throws {
        let payload = ReminderReceiptPayload(
            entityID: UUID(),
            action: .delete,
            reminderID: UUID(),
            title: nil,
            due: nil
        )
        let json = try payload.toJSONPayload()
        XCTAssertNil(json["title"])
        XCTAssertNil(json["due"])
    }

    func testEmailPayloadWithFlaggedState() throws {
        let payload = EmailReceiptPayload(
            entityID: UUID(),
            action: .flag,
            emailID: UUID(),
            threadID: nil,
            to: [],
            subject: nil,
            flagged: true
        )
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["action"]?.stringValue, "flag")
        XCTAssertEqual(json["flagged"]?.boolValue, true)
    }

    // MARK: - Signature verification

    func testEd25519SignatureIs64Bytes() throws {
        // ed25519 signatures are always 64 bytes (CryptoKit format).
        let key = Curve25519.Signing.PrivateKey()
        let message = "test message".data(using: .utf8)!
        let signature = try key.signature(for: message)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message))
    }

    func testMaterialReceiptSignatureRoundTrip() throws {
        // Build and verify a material receipt signature over canonical bytes.
        let key = Curve25519.Signing.PrivateKey()
        let entityID = UUID()
        let receiptType = NoteEditReceiptPayload.receiptType
        let payload: [String: JSONValue] = [
            "entityID": .string(entityID.uuidString),
            "action": .string("create"),
            "title": .string("Test"),
        ]
        let witnessedAt = Date()

        // Canonical bytes matching the format appendedMaterialReceipt would use.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let canonicalData = try encoder.encode([
            "entityID": entityID.uuidString,
            "receiptType": receiptType,
            "payload": String(data: payloadData, encoding: .utf8)!,
            "witnessedAt": ISO8601DateFormatter().string(from: witnessedAt)
        ])

        let signature = try key.signature(for: canonicalData)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: canonicalData))
    }

    // MARK: - GraphReceipt shape

    func testGraphReceiptMaterialReceiptShape() {
        // A ``GraphReceipt`` written by ``appendMaterialReceipt`` has the
        // same shape as any other receipt.
        let entityID = UUID()
        let receipt = GraphReceipt(
            id: UUID(),
            entityID: entityID,
            receiptType: NoteEditReceiptPayload.receiptType,
            payload: [
                "entityID": .string(entityID.uuidString),
                "action": .string("create"),
            ],
            signature: nil,
            witnessedAt: Date()
        )
        XCTAssertEqual(receipt.entityID, entityID)
        XCTAssertEqual(receipt.receiptType, NoteEditReceiptPayload.receiptType)
        XCTAssertNil(receipt.signature)  // nil until signing is wired
    }

    // MARK: - DataStore integration (env-gated)

    private static let envEnabled: Bool = {
        ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1"
    }()

    private static let host = ProcessInfo.processInfo.environment["TESSERA_PG_HOST"] ?? "localhost"
    private static let port = Int(ProcessInfo.processInfo.environment["TESSERA_PG_PORT"] ?? "5432") ?? 5432
    private static let user = ProcessInfo.processInfo.environment["TESSERA_PG_USER"] ?? "tessera"
    private static let pass = ProcessInfo.processInfo.environment["TESSERA_PG_PASSWORD"] ?? "tessera"
    private static let db = ProcessInfo.processInfo.environment["TESSERA_PG_DB"] ?? "tessera"

    private func requireIntegration() throws {
        guard Self.envEnabled else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping DB integration test")
        }
    }

    private func locateMigrationFile(_ name: String) -> String? {
        let candidates = [
            "tools/tessera/db/migrations/\(name)",
            "../tools/tessera/db/migrations/\(name)",
            "../../tools/tessera/db/migrations/\(name)",
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return c }
        }
        return nil
    }

    private func makeStore(database: String) async throws -> TesseraDataStore {
        let store = TesseraDataStore(configuration: .init(
            host: Self.host,
            port: Self.port,
            username: Self.user,
            password: Self.pass,
            database: database,
            minimumConnections: 1,
            maximumConnections: 2
        ))
        try await store.connect()
        return store
    }

    private func applyMigrations(to store: TesseraDataStore) async throws {
        guard let m1Path = locateMigrationFile("0001_init.sql") else {
            XCTFail("could not locate 0001_init.sql"); return
        }
        guard let m2Path = locateMigrationFile("0002_productivity_receipts.sql") else {
            XCTFail("could not locate 0002_productivity_receipts.sql"); return
        }
        let m1SQL = try String(contentsOfFile: m1Path, encoding: .utf8)
        let m2SQL = try String(contentsOfFile: m2Path, encoding: .utf8)
        try await store.applyMigrations([
            (name: "0001_init.sql", sql: m1SQL),
            (name: "0002_productivity_receipts.sql", sql: m2SQL),
        ])
    }

    func testAppendMaterialReceiptToDataStore() async throws {
        try requireIntegration()

        // Build a throwaway DB.
        let admin = try await makeStore(database: Self.db)
        let testDB = "tessera_mat_receipt_test_\(Int.random(in: 1000...99999))"
        try await admin.queryRaw(PostgresQuery(stringLiteral: "CREATE DATABASE \(testDB)"))

        let store = try await makeStore(database: testDB)
        try await applyMigrations(to: store)

        do {
            // Create a material entity first (the receipt FK references entity_id).
            let entityID = UUID()
            _ = try await store.upsertEntity(GraphEntityUpsert(
                id: entityID,
                entityType: "note",
                subtype: "markdown",
                label: "Test note",
                body: "{\"blocks\":{}}",
                sourceURL: nil,
                embedding: nil
            ))

            // Append a material receipt.
            let receipt = try await store.appendMaterialReceipt(
                entityID: entityID,
                receiptType: NoteEditReceiptPayload.receiptType,
                payload: [
                    "entityID": .string(entityID.uuidString),
                    "action": .string("create"),
                    "title": .string("Test note"),
                ]
            )

            XCTAssertEqual(receipt.entityID, entityID)
            XCTAssertEqual(receipt.receiptType, NoteEditReceiptPayload.receiptType)
            XCTAssertNotNil(receipt.id)

            // Fetch receipts and verify the new receipt is present.
            let fetched = try await store.receipts(forEntity: entityID)
            XCTAssertTrue(fetched.contains { $0.id == receipt.id })
        } catch {
            await store.close()
            try? await admin.queryRaw(
                PostgresQuery(stringLiteral: "DROP DATABASE IF EXISTS \(testDB) WITH (FORCE)")
            )
            await admin.close()
            throw error
        }
    }

    func testReceiptPayloadRoundTripsThroughDataStore() async throws {
        try requireIntegration()

        let admin = try await makeStore(database: Self.db)
        let testDB = "tessera_mat_receipt_test2_\(Int.random(in: 1000...99999))"
        try await admin.queryRaw(PostgresQuery(stringLiteral: "CREATE DATABASE \(testDB)"))

        let store = try await makeStore(database: testDB)
        try await applyMigrations(to: store)

        do {
            let entityID = UUID()
            _ = try await store.upsertEntity(GraphEntityUpsert(
                id: entityID,
                entityType: "task",
                subtype: "basic",
                label: "Buy groceries",
                body: "{}",
                sourceURL: nil,
                embedding: nil
            ))

            // Build and write a TaskReceiptPayload via toJSONPayload.
            let payload = TaskReceiptPayload(
                entityID: entityID,
                action: .complete,
                taskID: entityID,
                fieldsChanged: ["completedAt"],
                newValue: .object(["at": .string("2026-08-05T12:00:00Z")])
            )
            let jsonPayload = try payload.toJSONPayload()

            let receipt = try await store.appendMaterialReceipt(
                entityID: entityID,
                receiptType: TaskReceiptPayload.receiptType,
                payload: jsonPayload
            )

            // Fetch and verify the payload round-trips correctly.
            let fetched = try await store.receipts(forEntity: entityID)
            guard let stored = fetched.first(where: { $0.id == receipt.id }) else {
                XCTFail("receipt not found after round-trip")
                return
            }

            XCTAssertEqual(stored.receiptType, TaskReceiptPayload.receiptType)
            XCTAssertEqual(stored.payload["action"]?.stringValue, "complete")
            if case .array(let fieldsArr) = stored.payload["fieldsChanged"] {
                XCTAssertEqual(fieldsArr.first?.stringValue, "completedAt")
            } else {
                XCTFail("expected array for fieldsChanged")
            }
            if case .object(let obj) = stored.payload["newValue"] {
                XCTAssertEqual(obj["at"]?.stringValue, "2026-08-05T12:00:00Z")
            } else {
                XCTFail("expected object for newValue")
            }
        } catch {
            await store.close()
            try? await admin.queryRaw(
                PostgresQuery(stringLiteral: "DROP DATABASE IF EXISTS \(testDB) WITH (FORCE)")
            )
            await admin.close()
            throw error
        }
    }
}
