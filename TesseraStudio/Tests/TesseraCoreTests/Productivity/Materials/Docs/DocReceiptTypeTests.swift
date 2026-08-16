import XCTest
@testable import TesseraCore

// MARK: - DocReceiptTypeTests
//
// Contract: DocReceiptType.swift's own doc comments name every case's
// exact wire string ("doc_upsert", "doc_body_changed", ...) - these are
// the strings written to `graph_receipts.receipt_type`, so a rename here
// is a silent wire-format break for every historical receipt. Per
// doctrine rule 7 (independent oracles), the totality check below pins
// against a list hand-copied from the source file's comments, NOT derived
// by iterating `DocReceiptType.allCases` and checking self-consistency.
//
// NOTE: `DocReceiptType` declares `String, Codable, Sendable,
// CaseIterable` only - no Equatable/Hashable - so every comparison below
// goes through `.rawValue` (a `String`, which IS Equatable/Hashable)
// rather than `==`/dictionary-keying on the enum itself.

final class DocReceiptTypeTests: DoctrineTestCase {

    /// Hand-transcribed from DocReceiptType.swift - the independent
    /// oracle. Order matches the source file top-to-bottom. An array of
    /// pairs (not a `[DocReceiptType: String]` dictionary) because
    /// DocReceiptType is not Hashable.
    private static let expectedPairs: [(DocReceiptType, String)] = [
        (.upsert, "doc_upsert"),
        (.updateBody, "doc_body_changed"),
        (.revisionAccepted, "doc_revision_accepted"),
        (.revisionRejected, "doc_revision_rejected"),
        (.fieldsRefreshed, "doc_fields_refreshed"),
        (.findReplace, "doc_find_replace"),
        (.defineStyle, "doc_style_defined"),
        (.deleteStyle, "doc_style_deleted"),
        (.archive, "doc_archived"),
        (.unarchive, "doc_unarchived"),
        (.trash, "doc_trashed"),
        (.restore, "doc_restored"),
        (.delete, "doc_delete"),
        (.favorite, "doc_favorited"),
        (.unfavorite, "doc_unfavorited"),
        (.tagChange, "doc_tags_changed"),
        (.tagAdded, "doc_tag_added"),
        (.tagRemoved, "doc_tag_removed"),
        (.link, "doc_link_created"),
        (.unlink, "doc_link_deleted"),
        (.import, "doc_imported"),
        (.insertNote, "doc_note_inserted"),
        (.deleteNote, "doc_note_deleted"),
        (.addComment, "doc_comment_added"),
        (.commentReplied, "doc_comment_replied"),
        (.commentResolved, "doc_comment_resolved"),
        (.commentDeleted, "doc_comment_deleted"),
    ]

    func testEveryCaseHasItsDocumentedRawValue() {
        for (receiptType, expected) in Self.expectedPairs {
            XCTAssertEqual(receiptType.rawValue, expected)
        }
    }

    /// Guards against a case being added or removed without updating the
    /// independent oracle above - the totality half of doctrine rule 7.
    func testCaseCountMatchesTheIndependentlyPinnedList() {
        XCTAssertEqual(DocReceiptType.allCases.count, Self.expectedPairs.count,
                        "a new/removed DocReceiptType case must be reflected in this test's independently-pinned list, not just in the enum")
    }

    func testEveryCaseIterableCaseIsCoveredByThePinnedList() {
        let pinnedRawValues = Set(Self.expectedPairs.map(\.1))
        for receiptType in DocReceiptType.allCases {
            XCTAssertTrue(pinnedRawValues.contains(receiptType.rawValue),
                           "\(receiptType.rawValue) is missing from the independently-pinned oracle list")
        }
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testEveryCaseEncodesAndDecodesToItself() throws {
        for receiptType in DocReceiptType.allCases {
            let data = try JSONEncoder().encode(receiptType)
            let decoded = try JSONDecoder().decode(DocReceiptType.self, from: data)
            XCTAssertEqual(decoded.rawValue, receiptType.rawValue)
        }
    }

    func testRawValuesAreAllUnique() {
        let rawValues = DocReceiptType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "no two DocReceiptType cases may share a wire string")
    }
}
