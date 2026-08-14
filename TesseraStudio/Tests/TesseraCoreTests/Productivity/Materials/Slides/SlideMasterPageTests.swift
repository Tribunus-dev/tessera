import XCTest
@testable import TesseraCore

/// `SlideMasterPage` (P0 0.7): a deck-level background/text-color
/// theme a slide can reference via `SlideMeta.masterPageID`.
/// `SlideDeckRenderer` doesn't paint it yet - this ships and tests the
/// model itself.
final class SlideMasterPageTests: XCTestCase {

    private func blankDeck() -> SlideDeck {
        SlideDeck.makeBlank(title: "Deck")
    }

    // MARK: - Storage

    func testUntouchedDeckHasNoMasterPages() {
        XCTAssertTrue(blankDeck().effectiveMasterPages.isEmpty)
    }

    func testSettingAndReadingBackAMasterPage() {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#111111", textColorHex: "#FFFFFF")
        let deck = blankDeck().settingMasterPage(master)
        XCTAssertEqual(deck.effectiveMasterPages.count, 1)
        XCTAssertEqual(deck.effectiveMasterPages[master.id.uuidString]?.name, "Dark")
    }

    func testSettingWithAnExistingIDReplacesRatherThanDuplicates() {
        let master = SlideMasterPage(name: "Dark")
        var deck = blankDeck().settingMasterPage(master)
        let renamed = SlideMasterPage(id: master.id, name: "Darker")
        deck = deck.settingMasterPage(renamed)
        XCTAssertEqual(deck.effectiveMasterPages.count, 1)
        XCTAssertEqual(deck.effectiveMasterPages[master.id.uuidString]?.name, "Darker")
    }

    func testRemovingAMasterPage() {
        let master = SlideMasterPage(name: "Dark")
        var deck = blankDeck().settingMasterPage(master)
        deck = deck.removingMasterPage(master.id)
        XCTAssertTrue(deck.effectiveMasterPages.isEmpty)
    }

    /// Removing a master a slide is USING must clear that slide's
    /// reference too - a dangling `masterPageID` would resolve to
    /// nothing forever with no way to tell "unset" from "orphaned".
    func testRemovingAMasterPageClearsSlidesThatReferencedIt() {
        let master = SlideMasterPage(name: "Dark")
        var deck = blankDeck().settingMasterPage(master)
        let rootID = deck.body.rootChildren[0]
        deck.slideMeta[rootID.uuidString] = SlideMeta(layout: .title, masterPageID: master.id)
        XCTAssertNotNil(deck.masterPage(forSlideAt: 0))

        deck = deck.removingMasterPage(master.id)
        XCTAssertNil(deck.masterPage(forSlideAt: 0))
        XCTAssertNil(deck.slideMeta[rootID.uuidString]?.masterPageID)
    }

    // MARK: - masterPage(forSlideAt:)

    func testMasterPageForSlideResolvesTheAssignedMaster() {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#000000")
        var deck = blankDeck().settingMasterPage(master)
        let rootID = deck.body.rootChildren[0]
        deck.slideMeta[rootID.uuidString] = SlideMeta(layout: .title, masterPageID: master.id)

        XCTAssertEqual(deck.masterPage(forSlideAt: 0)?.id, master.id)
    }

    func testMasterPageForSlideIsNilWhenUnassigned() {
        let deck = blankDeck().settingMasterPage(SlideMasterPage(name: "Dark"))
        XCTAssertNil(deck.masterPage(forSlideAt: 0), "the master exists but no slide references it")
    }

    func testMasterPageForSlideIsNilForOutOfRangeIndex() {
        let deck = blankDeck()
        XCTAssertNil(deck.masterPage(forSlideAt: 99))
        XCTAssertNil(deck.masterPage(forSlideAt: -1))
    }

    // MARK: - Document round-trip

    func testMasterPageSurvivesDocumentRoundTrip() throws {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: "#111111", textColorHex: "#FFFFFF")
        let deck = blankDeck().settingMasterPage(master)
        let restored = try SlideDeck.from(jsonData: deck.jsonData())
        let restoredMaster = try XCTUnwrap(restored.effectiveMasterPages[master.id.uuidString])
        XCTAssertEqual(restoredMaster.name, "Dark")
        XCTAssertEqual(restoredMaster.backgroundColorHex, "#111111")
        XCTAssertEqual(restoredMaster.textColorHex, "#FFFFFF")
    }

    func testDeckWithoutMasterPagesKeyDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "slideMeta": {}, "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"}
        """
        let decoded = try SlideDeck.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.effectiveMasterPages.isEmpty)
    }

    /// A `SlideMeta` written before `masterPageID` existed must still
    /// decode - the missing key means "no master", not a decode error.
    func testSlideMetaWithoutMasterPageIDKeyDecodesAsNil() throws {
        let json = """
        {"layout": "title", "notes": ""}
        """
        let decoded = try JSONDecoder().decode(SlideMeta.self, from: Data(json.utf8))
        XCTAssertNil(decoded.masterPageID)
    }
}
