import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Contacts/Contact.swift
// doc comments (displayName's fallback chain per Subtype, NameComponents.isEmpty,
// LabeledAddress.oneLine) plus the top-level Contacts/ engine's own field
// shape (distinct from Materials/Contacts/ContactsGraphConnector.swift,
// per this cluster's ownership note).

final class ContactTests: DoctrineTestCase {

    private func makePersonContact(
        first: String? = "Ada",
        last: String? = "Example",
        nickname: String? = nil,
        organization: String? = nil
    ) -> Contact {
        Contact(
            subtype: .person,
            name: NameComponents(first: first, last: last, nickname: nickname),
            emails: [LabeledEmail(label: .work, value: "ada@example.com", isPrimary: true)],
            organization: organization
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = Contact(
            subtype: .person,
            name: NameComponents(prefix: "Dr.", first: "Ada", middle: "B", last: "Example", suffix: "Jr.", nickname: "Ace"),
            emails: [LabeledEmail(label: .work, value: "ada@example.com", isPrimary: true)],
            phones: [LabeledPhone(label: .mobile, value: "555-1234")],
            addresses: [LabeledAddress(label: .home, street: "1 Main St", city: "Springfield")],
            organization: "Acme",
            title: "Staff Engineer",
            birthday: Date(timeIntervalSince1970: 0),
            notes: "met at conference",
            sourceURL: "vcard:///contacts/1",
            linkedEntityIDs: [UUID()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try Contact.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let contact = makePersonContact()
        XCTAssertEqual(try contact.jsonData(), try contact.jsonData())
    }

    // MARK: - entityType pin

    func testEntityTypeIsPinnedToContact() {
        XCTAssertEqual(Contact.entityType, "contact")
    }

    func testSubtypeStringMirrorsSubtype() {
        XCTAssertEqual(makePersonContact().subtypeString, "person")
    }

    // MARK: - displayName fallback chain (fixtures, doctrine rule 9)

    func testDisplayNameForPersonJoinsFirstMiddleLast() {
        let contact = Contact(subtype: .person, name: NameComponents(first: "Ada", middle: "B", last: "Example"))
        XCTAssertEqual(contact.displayName, "Ada B Example")
    }

    func testDisplayNameForPersonFallsBackToNicknameWhenNoNameParts() {
        let contact = Contact(subtype: .person, name: NameComponents(nickname: "Ace"))
        XCTAssertEqual(contact.displayName, "Ace")
    }

    func testDisplayNameForPersonFallsBackToOrganizationWhenNoNameOrNickname() {
        let contact = Contact(subtype: .person, name: NameComponents(), organization: "Acme")
        XCTAssertEqual(contact.displayName, "Acme")
    }

    func testDisplayNameForPersonFallsBackToUnnamedWhenNothingSet() {
        let contact = Contact(subtype: .person, name: NameComponents())
        XCTAssertEqual(contact.displayName, "Unnamed")
    }

    func testDisplayNameForOrganizationUsesNameLast() {
        let contact = Contact(subtype: .organization, name: NameComponents(last: "Acme Inc."))
        XCTAssertEqual(contact.displayName, "Acme Inc.")
    }

    func testDisplayNameForOrganizationFallsBackToUnnamedOrganization() {
        let contact = Contact(subtype: .organization, name: NameComponents())
        XCTAssertEqual(contact.displayName, "Unnamed organization")
    }

    func testDisplayNameForGroupUsesNameLast() {
        let contact = Contact(subtype: .group, name: NameComponents(last: "Family"))
        XCTAssertEqual(contact.displayName, "Family")
    }

    func testDisplayNameForGroupFallsBackToUnnamedGroup() {
        let contact = Contact(subtype: .group, name: NameComponents())
        XCTAssertEqual(contact.displayName, "Unnamed group")
    }

    // MARK: - NameComponents.isEmpty

    func testNameComponentsIsEmptyTrueWhenAllFieldsNilOrEmpty() {
        XCTAssertTrue(NameComponents(first: "", last: nil).isEmpty)
    }

    func testNameComponentsIsEmptyFalseWhenAnyFieldSet() {
        XCTAssertFalse(NameComponents(first: "Ada").isEmpty)
    }

    // MARK: - LabeledAddress.oneLine

    func testOneLineJoinsNonEmptyComponentsWithCommas() {
        let address = LabeledAddress(label: .home, street: "1 Main St", city: "Springfield", region: "IL", postalCode: "62704")
        XCTAssertEqual(address.oneLine, "1 Main St, Springfield, IL, 62704")
    }

    func testOneLineOmitsNilOrEmptyComponents() {
        let address = LabeledAddress(label: .home, street: "1 Main St", city: "", country: "USA")
        XCTAssertEqual(address.oneLine, "1 Main St, USA")
    }
}
