import XCTest
@testable import TesseraCore

/// `TransitionSpec` / `TransitionCatalog` / `TransitionStore` (P1 1.6,
/// studio-expansion-design-refinement-2026-08-14.md, Slides cluster).
/// The catalog is an embedded Swift literal, not a bundled JSON
/// resource (see `TransitionCatalog`'s header for why), so "the
/// catalog decodes" is tested as "the catalog round-trips through
/// Codable" plus "`TransitionCatalog.validate` accepts it" rather than
/// a fixture-file decode. `TransitionStore`'s async mutations need a
/// live data layer this test target doesn't stand up - see
/// `MasterPageStoreTests`, scoped the same way - so only construction
/// is covered here; the catalog-resolution logic `setSlideTransition`
/// depends on is pinned directly against `TransitionCatalog` below.
final class TransitionSpecTests: XCTestCase {

    // MARK: - Catalog well-formedness

    func testCatalogIsNonEmpty() {
        XCTAssertFalse(TransitionCatalog.entries.isEmpty)
    }

    /// `TransitionCatalog.entries`'s lazy first-access validation
    /// (dangling fallback / duplicate id / duplicate ooxmlTag) already
    /// runs via `preconditionFailure` on any access above - this test
    /// additionally calls `validate(_:)` directly so a failure reports
    /// as a normal test failure instead of a process crash.
    func testCatalogValidates() {
        XCTAssertNoThrow(try TransitionCatalog.validate(TransitionCatalog.entries))
    }

    func testCatalogRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(TransitionCatalog.entries)
        let decoded = try JSONDecoder().decode([TransitionSpec].self, from: data)
        XCTAssertEqual(decoded, TransitionCatalog.entries)
    }

    func testEveryEntryHasAUniqueID() {
        let ids = TransitionCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate catalog ids")
    }

    func testSpecForIDMatchesID() {
        for spec in TransitionCatalog.entries {
            XCTAssertEqual(TransitionCatalog.spec(forID: spec.id)?.id, spec.id)
        }
    }

    func testSpecForUnknownIDIsNil() {
        XCTAssertNil(TransitionCatalog.spec(forID: "not-a-real-transition-id"))
    }

    // MARK: - Contract: every gpu entry's fallback resolves

    func testEveryGPUEntryFallbackResolvesToARealCatalogID() {
        let ids = Set(TransitionCatalog.entries.map(\.id))
        var sawAtLeastOneGPUEntry = false
        for spec in TransitionCatalog.entries {
            guard case let .gpu(presetID, fallbackID) = spec.engine else { continue }
            sawAtLeastOneGPUEntry = true
            XCTAssertFalse(presetID.isEmpty, "\(spec.id): empty gpu presetID")
            XCTAssertTrue(
                ids.contains(fallbackID),
                "\(spec.id): fallbackID '\(fallbackID)' does not resolve to any catalog entry"
            )
            // The contract's whole point: a gpu preset never falls back
            // to itself (that would not be a fallback at all).
            XCTAssertNotEqual(fallbackID, spec.id, "\(spec.id): fallbackID must not be itself")
        }
        XCTAssertTrue(sawAtLeastOneGPUEntry, "catalog has no .gpu entries to test")
    }

    /// A hand-built catalog with a dangling fallback must be rejected -
    /// this is what pins "validated at catalog-construction/decode
    /// time" as actual behavior, not just a doc comment.
    func testValidateRejectsADanglingFallback() {
        let broken: [TransitionSpec] = [
            TransitionSpec(id: "onlyEntry", name: "Only", engine: .gpu(presetID: "onlyEntry", fallbackID: "doesNotExist"), durationDefaultMS: 500),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            guard case TransitionCatalogError.danglingFallback(let gpuID, let fallbackID) = error else {
                return XCTFail("expected .danglingFallback, got \(error)")
            }
            XCTAssertEqual(gpuID, "onlyEntry")
            XCTAssertEqual(fallbackID, "doesNotExist")
        }
    }

    func testValidateRejectsADuplicateID() {
        let broken: [TransitionSpec] = [
            TransitionSpec(id: "dup", name: "A", engine: .tween, durationDefaultMS: 500),
            TransitionSpec(id: "dup", name: "B", engine: .tween, durationDefaultMS: 500),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            XCTAssertEqual(error as? TransitionCatalogError, .duplicateID("dup"))
        }
    }

    func testValidateRejectsADuplicateOOXMLTag() {
        let broken: [TransitionSpec] = [
            TransitionSpec(id: "a", name: "A", engine: .tween, durationDefaultMS: 500, ooxmlTag: "fade"),
            TransitionSpec(id: "b", name: "B", engine: .tween, durationDefaultMS: 500, ooxmlTag: "fade"),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            XCTAssertEqual(error as? TransitionCatalogError, .duplicateOOXMLTag("fade"))
        }
    }

    // MARK: - Contract: every OOXML p:transition child maps to exactly one catalog id

    func testEveryOOXMLTagMapsToExactlyOneCatalogID() {
        var tagsToIDs: [String: [String]] = [:]
        for spec in TransitionCatalog.entries {
            guard let tag = spec.ooxmlTag else { continue }
            tagsToIDs[tag, default: []].append(spec.id)
        }
        XCTAssertFalse(tagsToIDs.isEmpty, "no catalog entry declared an ooxmlTag")
        for (tag, ids) in tagsToIDs {
            XCTAssertEqual(ids.count, 1, "ooxmlTag '\(tag)' maps to more than one catalog id: \(ids)")
        }
    }

    func testIDForOOXMLTagMatchesTheDeclaringEntry() {
        for spec in TransitionCatalog.entries {
            guard let tag = spec.ooxmlTag else { continue }
            XCTAssertEqual(TransitionCatalog.id(forOOXMLTag: tag), spec.id)
        }
    }

    func testIDForUnknownOOXMLTagIsNil() {
        XCTAssertNil(TransitionCatalog.id(forOOXMLTag: "not-a-real-ooxml-tag"))
    }

    /// LibreOffice-extra presets are documented as having no direct
    /// OOXML equivalent - pin that at least some entries take the
    /// `ooxmlTag: nil` branch, so this isn't accidentally vacuous.
    func testSomeEntriesHaveNoOOXMLTag() {
        XCTAssertTrue(TransitionCatalog.entries.contains { $0.ooxmlTag == nil })
    }

    // MARK: - TransitionStore construction

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = TransitionStore(dataLayer: dataLayer)
        _ = store
    }
}
