import XCTest
import Foundation
@testable import TesseraCore

// MARK: - TransitionSpecTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4 "Slides cluster" item 1.6 ("~34 presets: OOXML's 20
// canonical + LO extras... engine .tween|.mask|.gpu... REQUIRED
// fallbackID on every gpu entry"). Doctrine rule 7 (independent
// oracle): the audit explicitly flags a totality test that iterates
// TransitionCatalog's own list as circular and worthless
// (docs/p1-post-claim-audit-2026-08-15.md item 1.6 and Class C item
// 15). The 20-tag list below is pinned from ECMA-376 5th ed. Part 1
// section 19.3.3's `EG_SlideTransition` group (the 20 canonical
// `p:transition` child elements every OOXML-conformant slide engine
// supports) - independent knowledge, not read off TransitionCatalog's
// own `buildEntries()`.

final class TransitionSpecTests: DoctrineTestCase {

    /// Rule 7 independent oracle: ECMA-376's 20 canonical
    /// `EG_SlideTransition` child element (wire tag) names, hardcoded
    /// from the OOXML spec/refinement doc - NOT derived by asking
    /// TransitionCatalog for its own list.
    private static let canonicalOOXMLTransitionTags: Set<String> = [
        "blinds", "checker", "circle", "comb", "cover", "cut", "diamond",
        "dissolve", "fade", "newsflash", "plus", "pull", "push", "random",
        "randomBar", "split", "strips", "wedge", "wheel", "wipe",
    ]

    // MARK: - Totality (independent oracle)

    func testEveryCanonicalOOXMLTransitionTagMapsToExactlyOneCatalogEntry() {
        for tag in Self.canonicalOOXMLTransitionTags {
            let matches = TransitionCatalog.entries.filter { $0.ooxmlTag == tag }
            XCTAssertEqual(matches.count, 1, "OOXML tag '\(tag)' should map to exactly one TransitionCatalog entry, found \(matches.count)")
        }
    }

    func testCatalogContainsAtLeastAllTwentyCanonicalOOXMLTags() {
        let catalogTags = Set(TransitionCatalog.entries.compactMap(\.ooxmlTag))
        XCTAssertTrue(Self.canonicalOOXMLTransitionTags.isSubset(of: catalogTags))
    }

    func testIDForOOXMLTagResolvesForEveryCanonicalTag() {
        for tag in Self.canonicalOOXMLTransitionTags {
            XCTAssertNotNil(TransitionCatalog.id(forOOXMLTag: tag), "id(forOOXMLTag:) should resolve '\(tag)'")
        }
    }

    // MARK: - GPU fallback contract (rule 5, trap stays pinned)

    func testEveryGPUEntrysFallbackResolvesToARealCatalogEntry() {
        for spec in TransitionCatalog.entries {
            guard case .gpu(_, let fallbackID) = spec.engine else { continue }
            XCTAssertNotNil(TransitionCatalog.spec(forID: fallbackID), "\(spec.id)'s fallbackID '\(fallbackID)' must resolve in the catalog")
        }
    }

    func testNoGPUEntrysFallbackChainsToAnotherGPUEntry() {
        // "the fallback of a fallback" degenerate case: a gpu entry's
        // fallback must itself be non-gpu, so playback never has to
        // chase a second hop.
        for spec in TransitionCatalog.entries {
            guard case .gpu(_, let fallbackID) = spec.engine else { continue }
            guard let fallbackSpec = TransitionCatalog.spec(forID: fallbackID) else {
                return XCTFail("\(spec.id)'s fallback '\(fallbackID)' does not resolve")
            }
            if case .gpu = fallbackSpec.engine {
                XCTFail("\(spec.id)'s fallback '\(fallbackID)' is itself a .gpu entry - fallback chains must terminate in one hop")
            }
        }
    }

    func testAtLeastOneGPUEntryExistsSoTheFallbackTestsAreNotVacuous() {
        let gpuEntries = TransitionCatalog.entries.filter {
            if case .gpu = $0.engine { return true }
            return false
        }
        XCTAssertFalse(gpuEntries.isEmpty)
    }

    // MARK: - validate(_:) - fixture-constructed catalogs (rule 9's fixture half)

    func testValidateThrowsDanglingFallbackForAGPUEntryWhoseFallbackIDDoesNotResolve() {
        let broken = [
            TransitionSpec(id: "onlyEntry", name: "Only", engine: .gpu(presetID: "x", fallbackID: "doesNotExist"), durationDefaultMS: 100),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            XCTAssertEqual(error as? TransitionCatalogError, .danglingFallback(gpuID: "onlyEntry", fallbackID: "doesNotExist"))
        }
    }

    func testValidateThrowsDuplicateIDForTwoEntriesSharingAnID() {
        let broken = [
            TransitionSpec(id: "dup", name: "A", engine: .tween, durationDefaultMS: 100),
            TransitionSpec(id: "dup", name: "B", engine: .tween, durationDefaultMS: 100),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            XCTAssertEqual(error as? TransitionCatalogError, .duplicateID("dup"))
        }
    }

    func testValidateThrowsDuplicateOOXMLTagForTwoEntriesSharingATag() {
        let broken = [
            TransitionSpec(id: "a", name: "A", engine: .tween, durationDefaultMS: 100, ooxmlTag: "fade"),
            TransitionSpec(id: "b", name: "B", engine: .tween, durationDefaultMS: 100, ooxmlTag: "fade"),
        ]
        XCTAssertThrowsError(try TransitionCatalog.validate(broken)) { error in
            XCTAssertEqual(error as? TransitionCatalogError, .duplicateOOXMLTag("fade"))
        }
    }

    func testValidateAcceptsAWellFormedMinimalCatalog() {
        let good = [
            TransitionSpec(id: "a", name: "A", engine: .tween, durationDefaultMS: 100),
            TransitionSpec(id: "b", name: "B", engine: .gpu(presetID: "b", fallbackID: "a"), durationDefaultMS: 100),
        ]
        XCTAssertNoThrow(try TransitionCatalog.validate(good))
    }

    // MARK: - No duplicate ids/tags in the live catalog

    func testLiveCatalogHasNoDuplicateIDs() {
        let ids = TransitionCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Round trip (rule 2)

    func testTransitionSpecEncodeDecodeIsIdentity() throws {
        let spec = TransitionSpec(id: "cube", name: "Cube", engine: .gpu(presetID: "cube", fallbackID: "wipe"), durationDefaultMS: 1000)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TransitionSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }

    func testTransitionEngineTweenAndMaskEncodeDecodeIsIdentity() throws {
        for engine: TransitionEngine in [.tween, .mask] {
            let data = try JSONEncoder().encode(engine)
            let decoded = try JSONDecoder().decode(TransitionEngine.self, from: data)
            XCTAssertEqual(decoded, engine)
        }
    }
}
