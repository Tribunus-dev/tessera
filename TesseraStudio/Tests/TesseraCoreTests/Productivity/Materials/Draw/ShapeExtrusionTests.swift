import XCTest
@testable import TesseraCore

// MARK: - ShapeExtrusionTests
//
// Contract: `ShapeExtrusion.swift`'s own header comment (item 2.17,
// "grows additively as needed, record the final field list ... for
// architect ratification") plus testing-doctrine.md rule 2 ("Value
// type: encode-decode identity, legacy-JSON decode ... byte-identical
// re-encode"). The P2-B wave opener shipped `ShapeExtrusion` with only
// `depth`/`bevelDepth`; this wave grew it additively with `metalness`/
// `roughness` (see this wave's findings file for the field-list
// reasoning) - the pinned fixture below is that ORIGINAL 2-field shape,
// proving the additive fields decode with sensible defaults rather than
// breaking already-written JSON, exactly the same contract
// `ShapeGeometry`'s `flipH`/`flipV` legacy-decode test already
// establishes for this codebase.

final class ShapeExtrusionTests: DoctrineTestCase {

    private func fixtureURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/Productivity/Materials/Draw/<this file>
        // -> Tests/TesseraCoreTests/Fixtures/shape-extrusion-p2-b.json
        let testsRoot = thisFile
            .deletingLastPathComponent() // <this file> -> Draw/
            .deletingLastPathComponent() // Draw -> Materials/
            .deletingLastPathComponent() // Materials -> Productivity/
            .deletingLastPathComponent() // Productivity -> TesseraCoreTests/
        return testsRoot.appendingPathComponent("Fixtures/shape-extrusion-p2-b.json")
    }

    // MARK: - Legacy-JSON decode (doctrine rule 2)

    func testPinnedTwoFieldFixtureDecodesWithMetalnessAndRoughnessDefaults() throws {
        let data = try Data(contentsOf: try fixtureURL())
        let decoded = try JSONDecoder().decode(ShapeExtrusion.self, from: data)

        XCTAssertEqual(decoded.depth, 10)
        XCTAssertEqual(decoded.bevelDepth, 2)
        XCTAssertEqual(decoded.metalness, 0, "absent in the pinned fixture - must fall back to the memberwise init's own default")
        XCTAssertEqual(decoded.roughness, 0.5, "absent in the pinned fixture - must fall back to the memberwise init's own default")
    }

    // MARK: - Round-trip identity (doctrine rule 2), independent of the pinned fixture

    func testEncodeDecodeIdentity() throws {
        let extrusion = ShapeExtrusion(depth: 24, bevelDepth: 3, metalness: 0.7, roughness: 0.2)
        let data = try JSONEncoder().encode(extrusion)
        let decoded = try JSONDecoder().decode(ShapeExtrusion.self, from: data)
        XCTAssertEqual(decoded, extrusion)
    }

    func testCanonicalReencodeOfAFullyPopulatedValueCarriesAllFourFields() throws {
        let extrusion = ShapeExtrusion(depth: 24, bevelDepth: 3, metalness: 0.7, roughness: 0.2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(extrusion)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["depth", "bevelDepth", "metalness", "roughness"] {
            XCTAssertTrue(json.contains(key), "canonical re-encode must always carry \(key), not omit it when it equals the default")
        }
    }

    // MARK: - Init clamps (doctrine rule 9: math gets fixtures)

    func testInitClampsMetalnessAndRoughnessTo0And1() {
        let extrusion = ShapeExtrusion(depth: 1, metalness: 4, roughness: -3)
        XCTAssertEqual(extrusion.metalness, 1)
        XCTAssertEqual(extrusion.roughness, 0)
    }

    func testInitClampsNegativeDepthAndBevelDepthToZero() {
        let extrusion = ShapeExtrusion(depth: -5, bevelDepth: -1)
        XCTAssertEqual(extrusion.depth, 0)
        XCTAssertEqual(extrusion.bevelDepth, 0)
    }
}
