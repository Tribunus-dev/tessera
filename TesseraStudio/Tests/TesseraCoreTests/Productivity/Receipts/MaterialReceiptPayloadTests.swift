import XCTest
@testable import TesseraCore

// MARK: - MaterialReceiptPayloadTests
//
// Contract: MaterialReceiptPayload.swift's own doc comments - "Each
// conforming type must provide a static receiptType that is the string
// stored in graph_receipts.receipt_type"; `toJSONPayload()` - "encodes
// self to JSON and extracts the top-level keys so the result is what
// would be stored in graph_receipts.payload."

final class MaterialReceiptPayloadTests: DoctrineTestCase {

    // MARK: - toJSONPayload() round-trips every field as a top-level key

    func testNoteEditReceiptPayloadToJSONPayloadCarriesEveryField() throws {
        let entityID = UUID()
        let payload = NoteEditReceiptPayload(entityID: entityID, action: .updateContent, title: "My Note", delta: "diff")
        let json = try payload.toJSONPayload()
        XCTAssertEqual(json["entityID"], .string(entityID.uuidString))
        XCTAssertEqual(json["action"], .string("updateContent"))
        XCTAssertEqual(json["title"], .string("My Note"))
        XCTAssertEqual(json["delta"], .string("diff"))
    }

    func testEmailReceiptPayloadToJSONPayloadCarriesArraysAndOptionals() throws {
        let entityID = UUID()
        let emailID = UUID()
        let payload = EmailReceiptPayload(entityID: entityID, action: .send, emailID: emailID, to: ["a@example.com", "b@example.com"], subject: "Hi")
        let json = try payload.toJSONPayload()
        guard case .array(let to)? = json["to"] else { return XCTFail("expected an array") }
        XCTAssertEqual(to, [.string("a@example.com"), .string("b@example.com")])
        XCTAssertEqual(json["subject"], .string("Hi"))
    }

    func testTaskReceiptPayloadEncodesNilNewValueAsAbsentOrNull() throws {
        let payload = TaskReceiptPayload(entityID: UUID(), action: .create, taskID: UUID())
        let json = try payload.toJSONPayload()
        // Either absent from the dictionary (Codable's default nil-omits-
        // key behavior via JSONEncoder is NOT guaranteed for every type,
        // so accept either representation) or explicitly null.
        if let value = json["newValue"] {
            XCTAssertEqual(value, .null)
        }
    }

    // MARK: - receiptType (protocol extension default) matches the static value

    func testInstanceReceiptTypeMatchesTheStaticDeclaration() {
        let payload = ContactReceiptPayload(entityID: UUID(), action: .create, contactID: UUID())
        XCTAssertEqual(payload.receiptType, ContactReceiptPayload.receiptType)
        XCTAssertEqual(ContactReceiptPayload.receiptType, "contact_operation")
    }

    // MARK: - Every payload type's receiptType is a unique, documented string
    // (independent oracle, doctrine rule 7 - hand-transcribed from each
    // type's own doc comment, not derived from the types themselves).

    func testEveryPayloadTypesReceiptTypeMatchesItsDocumentedString() {
        XCTAssertEqual(NoteEditReceiptPayload.receiptType, "note_edit")
        XCTAssertEqual(EmailReceiptPayload.receiptType, "email_operation")
        XCTAssertEqual(ContactReceiptPayload.receiptType, "contact_operation")
        XCTAssertEqual(TaskReceiptPayload.receiptType, "task_operation")
        XCTAssertEqual(ReminderReceiptPayload.receiptType, "reminder_operation")
        XCTAssertEqual(CalendarReceiptPayload.receiptType, "calendar_event_operation")
        XCTAssertEqual(SheetReceiptPayload.receiptType, "sheet_operation")
        XCTAssertEqual(SlideReceiptPayload.receiptType, "slide_operation")
        XCTAssertEqual(CodeReceiptPayload.receiptType, "code_file_operation")
    }

    // MARK: - ReminderReceiptPayload: custom Codable for the Date field

    func testReminderReceiptPayloadEncodesDueAsISO8601StringAndDecodesBack() throws {
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ReminderReceiptPayload(entityID: UUID(), action: .create, reminderID: UUID(), title: "Call mom", due: due)
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue(obj?["due"] is String, "due must be encoded as an ISO-8601 string, not a raw Double timestamp")

        let decoded = try JSONDecoder().decode(ReminderReceiptPayload.self, from: data)
        XCTAssertEqual(decoded.due?.timeIntervalSince1970 ?? -1, due.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.entityID, payload.entityID)
    }

    func testReminderReceiptPayloadWithNilDueOmitsTheKeyEntirely() throws {
        let payload = ReminderReceiptPayload(entityID: UUID(), action: .complete, reminderID: UUID())
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["due"])
        let decoded = try JSONDecoder().decode(ReminderReceiptPayload.self, from: data)
        XCTAssertNil(decoded.due)
    }

    // MARK: - Round-trip identity for a representative sample (doctrine rule 2)

    func testSheetReceiptPayloadEncodeDecodeIdentity() throws {
        let payload = SheetReceiptPayload(
            entityID: UUID(), action: .cellEdit, sheetID: UUID(), cell: "B7",
            oldValue: .number(1), newValue: .number(2)
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SheetReceiptPayload.self, from: data)
        XCTAssertEqual(decoded.entityID, payload.entityID)
        // SheetAction is `String, Codable` only (no Equatable/Hashable
        // declared) - compare via rawValue rather than assuming `==` exists.
        XCTAssertEqual(decoded.action.rawValue, payload.action.rawValue)
        XCTAssertEqual(decoded.cell, payload.cell)
        XCTAssertEqual(decoded.oldValue, payload.oldValue)
        XCTAssertEqual(decoded.newValue, payload.newValue)
    }
}
