import XCTest
import Foundation
@testable import TesseraCore

// MARK: - MediaBlockTests
//
// Contract sources: MediaBlock.swift's own doc comment ("Deliberately
// NOT a wrapper around any AVFoundation type... a plain data-model
// description of a media reference for Block.media/attributes["media"]
// to persist") and Block.swift's `.media` bridge doc comment ("Returns
// nil for non-.media blocks or malformed/missing content; setting on a
// non-.media block is a no-op" - the same convention `.shape`'s bridge
// documents, cited directly since this file mirrors `ShapeTests.swift`'s
// bridge-round-trip coverage for the same reason). Doctrine rule 2
// (round-trip identity triple for a value type).
//
// The pre-doctrine suite's own MediaBlockTests.swift (deleted 2026-08-15
// per architect directive, see AGENTS.md) covered exactly this ground
// per its landing commit message ("MediaBlock round-trips for both
// kinds with and without optional fields; the Block.media bridge
// round-trips and nils out on non-.media blocks") - this file is a
// doctrine-compliant rewrite from the CURRENT doc comments, not a
// restoration of the deleted file's bodies.

final class MediaBlockTests: DoctrineTestCase {

    // MARK: - Round-trip identity (rule 2)

    func testAudioMediaBlockEncodeDecodeIsIdentityWithOnlyRequiredFields() throws {
        let media = MediaBlock(kind: .audio, sourceURL: "assets/narration.m4a")
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
        XCTAssertEqual(decoded, media)
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertNil(decoded.posterImageURL)
        XCTAssertFalse(decoded.autoplay)
        XCTAssertFalse(decoded.loop)
    }

    func testVideoMediaBlockEncodeDecodeIsIdentityWithEveryOptionalFieldPresent() throws {
        let media = MediaBlock(
            kind: .video,
            sourceURL: "assets/demo.mp4",
            durationSeconds: 42.5,
            posterImageURL: "assets/demo-poster.png",
            autoplay: true,
            loop: true
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
        XCTAssertEqual(decoded, media)
        XCTAssertEqual(decoded.durationSeconds, 42.5)
        XCTAssertEqual(decoded.posterImageURL, "assets/demo-poster.png")
        XCTAssertTrue(decoded.autoplay)
        XCTAssertTrue(decoded.loop)
    }

    func testMediaKindHasExactlyTheTwoDocumentedCases() {
        // Independent oracle (doctrine rule 7): pinned against the
        // literal case list in MediaKind's own doc comment, not
        // MediaKind.allCases fed back into itself.
        let expected: Set<String> = ["audio", "video"]
        XCTAssertEqual(Set(MediaKind.allCases.map(\.rawValue)), expected)
    }

    // MARK: - Block.media bridge (mirrors Block.shape's own bridge tests)

    func testBlockMediaBridgeRoundTripsOnAMediaBlock() {
        var block = Block(type: .media)
        let media = MediaBlock(kind: .video, sourceURL: "assets/clip.mov", autoplay: true)

        block.media = media

        XCTAssertEqual(block.media, media)
        XCTAssertNotNil(block.attributes["media"], "the bridge persists through attributes[\"media\"], per Block.swift's doc comment")
    }

    func testBlockMediaBridgeReadsNilForANonMediaBlock() {
        var block = Block(type: .paragraph)
        // Setting on a non-.media block is documented as a no-op.
        block.media = MediaBlock(kind: .audio, sourceURL: "assets/track.mp3")

        XCTAssertNil(block.media, "reading .media off a non-.media block must return nil regardless of attributes contents")
        XCTAssertNil(block.attributes["media"], "setting .media on a non-.media block must not write attributes either")
    }

    func testBlockMediaBridgeReadsNilWhenAttributesHaveNoMediaKey() {
        let block = Block(type: .media)
        XCTAssertNil(block.media, "a .media block with no attributes[\"media\"] yet is \"no media attached\", not corrupted data")
    }

    func testBlockMediaBridgeClearsAttributeWhenSetToNil() {
        var block = Block(type: .media)
        block.media = MediaBlock(kind: .audio, sourceURL: "assets/track.mp3")
        XCTAssertNotNil(block.attributes["media"])

        block.media = nil

        XCTAssertNil(block.media)
        XCTAssertNil(block.attributes["media"])
    }
}
