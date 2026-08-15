import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Email/EmailMessage.swift
// doc comments (Threading.normalize/stripBrackets/splitReferences,
// Folder.systemID/displayName/isSystem, EmailAddress.mailboxString/
// canonicalEmail, EmailMessage.displaySubject/snippet/isActive) plus
// docs/tessera-productivity-materials-email-design.md section 3
// (EmailMessage shape) and section 3's threading pseudocode (reproduced
// as the exact fixture cases here, doctrine rule 9: math/logic gets
// fixtures).

final class EmailMessageTests: DoctrineTestCase {

    private func makeMessage(
        id: UUID = UUID(),
        subject: String = "Q3 numbers",
        bodyPlain: String = "Here are the Q3 numbers.",
        folder: Folder = .inbox
    ) -> EmailMessage {
        EmailMessage(
            id: id,
            messageID: "abc123@example.com",
            from: EmailAddress(name: "Ada", email: "ada@example.com"),
            to: [EmailAddress(email: "bob@example.com")],
            subject: subject,
            bodyPlain: bodyPlain,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            folder: folder,
            attachments: [Attachment(filename: "report.pdf", mimeType: "application/pdf", size: 1024)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = makeMessage()
        let decoded = try EmailMessage.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testJSONDataStringRoundTripPreservesEveryField() throws {
        let original = makeMessage(folder: .custom("Work"))
        let decoded = try EmailMessage.from(jsonDataString: original.jsonDataString())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let message = makeMessage()
        XCTAssertEqual(try message.jsonData(), try message.jsonData())
    }

    // MARK: - entityType pin

    func testEntityTypeIsPinnedToEmail() {
        XCTAssertEqual(EmailMessage.entityType, "email")
    }

    // MARK: - displaySubject

    func testDisplaySubjectUsesSubjectWhenNonEmpty() {
        XCTAssertEqual(makeMessage(subject: "Hello").displaySubject, "Hello")
    }

    func testDisplaySubjectFallsBackForEmptySubject() {
        XCTAssertEqual(makeMessage(subject: "   ").displaySubject, "(no subject)")
    }

    // MARK: - snippet

    func testSnippetCollapsesNewlinesAndCapsAt80Characters() {
        let long = String(repeating: "word ", count: 40) // 200 chars
        let message = makeMessage(bodyPlain: "line one\nline two\r\n" + long)
        let snippet = message.snippet
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertLessThanOrEqual(snippet.count, 80)
    }

    // MARK: - senderDisplay

    func testSenderDisplayPrefersName() {
        let message = makeMessage()
        XCTAssertEqual(message.senderDisplay, "Ada")
    }

    func testSenderDisplayFallsBackToBareEmailWhenNameMissing() {
        var message = makeMessage()
        message.from = EmailAddress(email: "ada@example.com")
        XCTAssertEqual(message.senderDisplay, "ada@example.com")
    }

    // MARK: - hasAttachments

    func testHasAttachmentsTrueWhenAttachmentsPresent() {
        XCTAssertTrue(makeMessage().hasAttachments)
    }

    func testHasAttachmentsFalseWhenNoAttachments() {
        var message = makeMessage()
        message.attachments = []
        XCTAssertFalse(message.hasAttachments)
    }

    // MARK: - isActive (fixtures over the Folder enum, independent oracle:
    // hand-derived from the doc comment's switch, not from reading the
    // switch statement's cases back)

    func testIsActiveTrueForInboxWhenNotArchivedOrTrashed() {
        XCTAssertTrue(makeMessage(folder: .inbox).isActive)
    }

    func testIsActiveFalseForArchiveFolder() {
        XCTAssertFalse(makeMessage(folder: .archive).isActive)
    }

    func testIsActiveFalseForTrashFolder() {
        XCTAssertFalse(makeMessage(folder: .trash).isActive)
    }

    func testIsActiveFalseForInboxMessageMarkedArchived() {
        var message = makeMessage(folder: .inbox)
        message.isArchived = true
        XCTAssertFalse(message.isActive)
    }

    func testIsActiveTrueForCustomFolderWhenNotArchivedOrTrashed() {
        XCTAssertTrue(makeMessage(folder: .custom("Work")).isActive)
    }

    // MARK: - EmailAddress

    func testMailboxStringIncludesNameWhenPresent() {
        let address = EmailAddress(name: "Ada Example", email: "ada@example.com")
        XCTAssertEqual(address.mailboxString, "Ada Example <ada@example.com>")
    }

    func testMailboxStringIsBareEmailWhenNameAbsent() {
        let address = EmailAddress(email: "ada@example.com")
        XCTAssertEqual(address.mailboxString, "ada@example.com")
    }

    func testCanonicalEmailIsLowercased() {
        let address = EmailAddress(email: "Ada@Example.COM")
        XCTAssertEqual(address.canonicalEmail, "ada@example.com")
    }

    // MARK: - Folder

    func testFolderSystemIDValues() {
        XCTAssertEqual(Folder.inbox.systemID, "inbox")
        XCTAssertEqual(Folder.sent.systemID, "sent")
        XCTAssertEqual(Folder.drafts.systemID, "drafts")
        XCTAssertEqual(Folder.archive.systemID, "archive")
        XCTAssertEqual(Folder.trash.systemID, "trash")
        XCTAssertEqual(Folder.starred.systemID, "starred")
        XCTAssertEqual(Folder.custom("Work").systemID, "label:work")
    }

    func testFolderIsSystemFalseOnlyForCustom() {
        XCTAssertTrue(Folder.inbox.isSystem)
        XCTAssertFalse(Folder.custom("Work").isSystem)
    }

    // MARK: - Threading (fixture cases from the design doc's own
    // pseudocode, section 3)

    func testThreadingNormalizeUsesFirstNonEmptyReference() {
        let anchor = Threading.normalize(
            messageID: "msg3@example.com",
            inReplyTo: "msg2@example.com",
            references: ["msg1@example.com", "msg2@example.com"]
        )
        XCTAssertEqual(anchor, "msg1@example.com")
    }

    func testThreadingNormalizeFallsBackToInReplyToWhenReferencesEmpty() {
        let anchor = Threading.normalize(
            messageID: "msg3@example.com",
            inReplyTo: "msg2@example.com",
            references: []
        )
        XCTAssertEqual(anchor, "msg2@example.com")
    }

    func testThreadingNormalizeFallsBackToOwnMessageIDWhenBothEmpty() {
        let anchor = Threading.normalize(messageID: "msg1@example.com", inReplyTo: nil, references: [])
        XCTAssertEqual(anchor, "msg1@example.com")
    }

    func testThreadingNormalizeSkipsEmptyReferencesEntries() {
        let anchor = Threading.normalize(
            messageID: "msg3@example.com",
            inReplyTo: nil,
            references: ["", "msg1@example.com"]
        )
        XCTAssertEqual(anchor, "msg1@example.com")
    }

    func testThreadingStripBracketsRemovesAngleBrackets() {
        XCTAssertEqual(Threading.stripBrackets("<abc123@example.com>"), "abc123@example.com")
    }

    func testThreadingStripBracketsIsIdempotentOnBareID() {
        XCTAssertEqual(Threading.stripBrackets("abc123@example.com"), "abc123@example.com")
    }

    func testThreadingSplitReferencesStripsBracketsPerElement() {
        let refs = Threading.splitReferences("<a@example.com> <b@example.com>")
        XCTAssertEqual(refs, ["a@example.com", "b@example.com"])
    }

    func testThreadingSplitReferencesDropsEmptyElements() {
        let refs = Threading.splitReferences("  <a@example.com>   ")
        XCTAssertEqual(refs, ["a@example.com"])
    }
}
