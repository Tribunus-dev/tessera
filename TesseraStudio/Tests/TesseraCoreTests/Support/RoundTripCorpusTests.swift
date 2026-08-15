import Foundation
import XCTest

// Smoke test for the round-trip fixture corpus (studio-expansion-plan.md
// 6b row 1.0): every fixture resolves, is non-empty, and is well-formed
// enough to be XML, and every declared feature tag is non-empty. Deeper
// parsing / round-trip assertions belong to the items that actually read
// these formats (FlatODFReader this batch, the bridge filters later) -
// this only guards the corpus's own plumbing.

final class RoundTripCorpusTests: XCTestCase {

    func testCorpusLoadsWithoutThrowing() throws {
        let entries = try RoundTripCorpus.load()
        XCTAssertFalse(entries.isEmpty)
    }

    func testCorpusSpansAllFourFormats() throws {
        let formats = Set(try RoundTripCorpus.load().map(\.format))
        XCTAssertEqual(formats, Set(CorpusFormat.allCases))
    }

    func testEveryFixtureIsReadableNonEmptyXML() throws {
        for entry in try RoundTripCorpus.load() {
            let data = try Data(contentsOf: entry.url)
            XCTAssertFalse(data.isEmpty, "\(entry.name) is empty")

            let text = try XCTUnwrap(
                String(data: data, encoding: .utf8),
                "\(entry.name) is not valid UTF-8"
            )
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\u{FEFF}") {
                trimmed.removeFirst()
            }
            XCTAssertTrue(trimmed.hasPrefix("<?xml"), "\(entry.name) does not start with <?xml")
        }
    }

    func testEveryFixtureDeclaresNonEmptyFeatureTags() throws {
        for entry in try RoundTripCorpus.load() {
            XCTAssertFalse(entry.featureTags.isEmpty, "\(entry.name) has no featureTags")
            for tag in entry.featureTags {
                XCTAssertFalse(
                    tag.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(entry.name) has an empty featureTag"
                )
            }
        }
    }
}
