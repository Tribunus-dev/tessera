import Foundation
import CoreFoundation

// MARK: - MaterialReceiptPayload

/// Marker protocol for lightweight material receipt payloads.
///
/// Document receipts (``Receipt``) use the full C2PA manifest + block
/// AST approach with a per-document receipt chain. Material receipts
/// use typed structs conforming to this protocol: they are lightweight
/// operation records (no C2PA manifest, no block AST snapshot, no
/// chain linkage) and are signed with the same ed25519 key.
///
/// The distinction between the two paths is intentional:
/// - Document receipts carry detailed mutation history for the WYSIWYG
///   undo stack and the per-document receipt drawer.
/// - Material receipts carry just enough detail to reconstruct what
///   happened (the action, the affected entity, the changed fields).
///
/// Each conforming type must provide a static ``receiptType`` that
/// is the string stored in `graph_receipts.receipt_type`.
public protocol MaterialReceiptPayload: Codable, Sendable {
    /// The `receipt_type` string written to `graph_receipts`.
    /// Must be unique within the material.
    static var receiptType: String { get }

    /// The affected entity's UUID.
    var entityID: UUID { get }
}

extension MaterialReceiptPayload {
    /// Convert to the `[String: JSONValue]` map used by the data layer.
    /// The implementation encodes `self` to JSON and extracts the top-level
    /// keys so the result is what would be stored in `graph_receipts.payload`.
    public func toJSONPayload() throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(self)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaterialReceiptPayloadError.encodingFailed
        }
        var result: [String: JSONValue] = [:]
        for (key, value) in json {
            result[key] = JSONValue.fromAny(value)
        }
        return result
    }

    /// The ``receiptType`` value for this payload type.
    public var receiptType: String { Self.receiptType }
}

// MARK: - Errors

public enum MaterialReceiptPayloadError: Error, Sendable {
    case encodingFailed
    case decodingFailed
}

// MARK: - JSONValue from Any

extension JSONValue {
    /// Convert a decoded JSON value (from JSONSerialization) to a JSONValue.
    /// JSONSerialization produces `NSNull`, `NSNumber`, `NSString`, `NSArray`,
    /// or `NSDictionary`. We need to convert these to our domain types.
    fileprivate static func fromAny(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            // NSNumber: check if it's a bool first (bool is bridged specially).
            // Use CFBooleanGetTypeID which is available from CoreFoundation.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            // Then it's a number.
            return .number(n.doubleValue)
        case let a as [Any]:
            return .array(a.map { fromAny($0) })
        case let d as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in d { obj[k] = fromAny(v) }
            return .object(obj)
        default:
            return .null
        }
    }
}

// MARK: - Note Receipt Payloads

/// Payload for note edit receipts.
public enum NoteAction: String, Codable {
    case create, updateContent, updateTitle, delete
}

/// A note edit receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "title": "string", "delta": "string?"}
/// ```
public struct NoteEditReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "note_edit"

    public let entityID: UUID
    public let action: NoteAction
    public let title: String?
    public let delta: String?

    public init(entityID: UUID, action: NoteAction, title: String? = nil, delta: String? = nil) {
        self.entityID = entityID
        self.action = action
        self.title = title
        self.delta = delta
    }
}

// MARK: - Email Receipt Payloads

/// Payload for email operation receipts.
public enum EmailAction: String, Codable {
    case send, receive, delete, flag
}

/// An email receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "send", "emailID": "uuid", "threadID": "uuid",
///  "to": ["email"], "subject": "string?", "flagged": "bool?"}
/// ```
public struct EmailReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "email_operation"

    public let entityID: UUID
    public let action: EmailAction
    public let emailID: UUID
    public let threadID: UUID?
    public let to: [String]
    public let subject: String?
    public let flagged: Bool?

    public init(
        entityID: UUID,
        action: EmailAction,
        emailID: UUID,
        threadID: UUID? = nil,
        to: [String] = [],
        subject: String? = nil,
        flagged: Bool? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.emailID = emailID
        self.threadID = threadID
        self.to = to
        self.subject = subject
        self.flagged = flagged
    }
}

// MARK: - Contact Receipt Payloads

/// Payload for contact operation receipts.
public enum ContactAction: String, Codable {
    case create, update, delete, link
}

/// A contact receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "contactID": "uuid",
///  "fieldsChanged": ["field_name"], "linkedTo": "uuid?"}
/// ```
public struct ContactReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "contact_operation"

    public let entityID: UUID
    public let action: ContactAction
    public let contactID: UUID
    public let fieldsChanged: [String]
    public let linkedTo: UUID?

    public init(
        entityID: UUID,
        action: ContactAction,
        contactID: UUID,
        fieldsChanged: [String] = [],
        linkedTo: UUID? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.contactID = contactID
        self.fieldsChanged = fieldsChanged
        self.linkedTo = linkedTo
    }
}

// MARK: - Task Receipt Payloads

/// Payload for task operation receipts.
public enum TaskAction: String, Codable {
    case create, update, complete, delete
}

/// A task receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "taskID": "uuid",
///  "fieldsChanged": ["field_name"], "newValue": "any?"}
/// ```
public struct TaskReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "task_operation"

    public let entityID: UUID
    public let action: TaskAction
    public let taskID: UUID
    public let fieldsChanged: [String]
    public let newValue: JSONValue?

    public init(
        entityID: UUID,
        action: TaskAction,
        taskID: UUID,
        fieldsChanged: [String] = [],
        newValue: JSONValue? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.taskID = taskID
        self.fieldsChanged = fieldsChanged
        self.newValue = newValue
    }
}

// MARK: - Reminder Receipt Payloads

/// Payload for reminder operation receipts.
public enum ReminderAction: String, Codable {
    case create, complete, delete
}

/// A reminder receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "reminderID": "uuid",
///  "title": "string?", "due": "datetime?"}
/// ```
public struct ReminderReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "reminder_operation"

    public let entityID: UUID
    public let action: ReminderAction
    public let reminderID: UUID
    public let title: String?
    public let due: Date?

    public init(
        entityID: UUID,
        action: ReminderAction,
        reminderID: UUID,
        title: String? = nil,
        due: Date? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.reminderID = reminderID
        self.title = title
        self.due = due
    }

    // Custom Codable to serialize Date as ISO-8601 string.
    private enum CodingKeys: String, CodingKey {
        case entityID = "entityID"
        case action
        case reminderID = "reminderID"
        case title
        case due
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decode(UUID.self, forKey: .entityID)
        action = try container.decode(ReminderAction.self, forKey: .action)
        reminderID = try container.decode(UUID.self, forKey: .reminderID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .due) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            due = formatter.date(from: dateString)
        } else {
            due = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(action, forKey: .action)
        try container.encode(reminderID, forKey: .reminderID)
        try container.encodeIfPresent(title, forKey: .title)
        if let due {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: due), forKey: .due)
        }
    }
}

// MARK: - Calendar Receipt Payloads

/// Payload for calendar event operation receipts.
public enum CalendarAction: String, Codable {
    case create, update, delete, respond
}

/// Response status for calendar event RSVP.
public enum CalendarResponse: String, Codable {
    case accepted, declined, tentative
}

/// A calendar event receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "eventID": "uuid",
///  "title": "string?", "fieldsChanged": ["field_name"],
///  "response": "accepted" | "declined" | "tentative" | null}
/// ```
public struct CalendarReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "calendar_event_operation"

    public let entityID: UUID
    public let action: CalendarAction
    public let eventID: UUID
    public let title: String?
    public let fieldsChanged: [String]
    public let response: CalendarResponse?

    public init(
        entityID: UUID,
        action: CalendarAction,
        eventID: UUID,
        title: String? = nil,
        fieldsChanged: [String] = [],
        response: CalendarResponse? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.eventID = eventID
        self.title = title
        self.fieldsChanged = fieldsChanged
        self.response = response
    }
}

// MARK: - Sheet Receipt Payloads

/// Payload for sheet operation receipts.
public enum SheetAction: String, Codable {
    case cellEdit, create, delete
}

/// A sheet receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "cell_edit", "sheetID": "uuid",
///  "cell": "A1", "oldValue": "any?", "newValue": "any?"}
/// ```
public struct SheetReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "sheet_operation"

    public let entityID: UUID
    public let action: SheetAction
    public let sheetID: UUID
    public let cell: String?
    public let oldValue: JSONValue?
    public let newValue: JSONValue?

    public init(
        entityID: UUID,
        action: SheetAction,
        sheetID: UUID,
        cell: String? = nil,
        oldValue: JSONValue? = nil,
        newValue: JSONValue? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.sheetID = sheetID
        self.cell = cell
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

// MARK: - Slide Receipt Payloads

/// Payload for slide operation receipts.
public enum SlideAction: String, Codable {
    case create, update, delete, export
}

/// A slide receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "create", "deckID": "uuid",
///  "slideID": "uuid?", "fieldsChanged": ["field_name"]}
/// ```
public struct SlideReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "slide_operation"

    public let entityID: UUID
    public let action: SlideAction
    public let deckID: UUID
    public let slideID: UUID?
    public let fieldsChanged: [String]

    public init(
        entityID: UUID,
        action: SlideAction,
        deckID: UUID,
        slideID: UUID? = nil,
        fieldsChanged: [String] = []
    ) {
        self.entityID = entityID
        self.action = action
        self.deckID = deckID
        self.slideID = slideID
        self.fieldsChanged = fieldsChanged
    }
}

// MARK: - Code Receipt Payloads

/// Payload for code file operation receipts.
public enum CodeAction: String, Codable {
    case fileWrite, fileDelete, watchUpdate
}

/// A code file receipt payload.
///
/// ```json
/// {"entityID": "uuid", "action": "file_write", "fileID": "uuid",
///  "path": "string", "delta": "string?"}
/// ```
public struct CodeReceiptPayload: MaterialReceiptPayload {
    public static let receiptType = "code_file_operation"

    public let entityID: UUID
    public let action: CodeAction
    public let fileID: UUID
    public let path: String
    public let delta: String?

    public init(
        entityID: UUID,
        action: CodeAction,
        fileID: UUID,
        path: String,
        delta: String? = nil
    ) {
        self.entityID = entityID
        self.action = action
        self.fileID = fileID
        self.path = path
        self.delta = delta
    }
}
