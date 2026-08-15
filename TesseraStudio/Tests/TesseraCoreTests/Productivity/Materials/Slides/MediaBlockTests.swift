import XCTest
@testable import TesseraCore

/// Tests for the `MediaBlock` data model: JSON round-trip for both
/// `MediaKind` cases (with and without optional fields set), and the
/// `Block.media` `attributes["media"]` bridge - mirrors
/// `ChartSpecTests.swift`'s Block + Chart bridge tests.
final class MediaBlockTests: XCTestCase {

    // MARK: - MediaBlock round-trip

    func testAudioMediaBlockRoundTripsWithOptionalFieldsSet() throws {
        let media = MediaBlock(
            kind: .audio,
            sourceURL: "media/narration.m4a",
            durationSeconds: 12.5,
            posterImageURL: nil,
            autoplay: true,
            loop: false
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
        XCTAssertEqual(decoded, media)
        XCTAssertEqual(decoded.kind, .audio)
        XCTAssertEqual(decoded.durationSeconds, 12.5)
        XCTAssertNil(decoded.posterImageURL)
    }

    func testVideoMediaBlockRoundTripsWithOptionalFieldsSet() throws {
        let media = MediaBlock(
            kind: .video,
            sourceURL: "media/clip.mp4",
            durationSeconds: 90,
            posterImageURL: "media/clip-poster.jpg",
            autoplay: false,
            loop: true
        )
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
        XCTAssertEqual(decoded, media)
        XCTAssertEqual(decoded.kind, .video)
        XCTAssertEqual(decoded.posterImageURL, "media/clip-poster.jpg")
    }

    func testMediaBlockRoundTripsWithoutOptionalFieldsSet() throws {
        let media = MediaBlock(kind: .video, sourceURL: "media/clip.mp4")
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
        XCTAssertEqual(decoded, media)
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertNil(decoded.posterImageURL)
        XCTAssertFalse(decoded.autoplay)
        XCTAssertFalse(decoded.loop)
    }

    func testEveryMediaKindRoundTrips() throws {
        for kind in MediaKind.allCases {
            let media = MediaBlock(kind: kind, sourceURL: "media/asset")
            let data = try JSONEncoder().encode(media)
            let decoded = try JSONDecoder().decode(MediaBlock.self, from: data)
            XCTAssertEqual(decoded.kind, kind, "round-trip failed for \(kind)")
        }
    }

    // MARK: - Block + Media bridge

    func testMediaBlockRoundTripsThroughAttributes() {
        let media = MediaBlock(
            kind: .video,
            sourceURL: "media/clip.mp4",
            durationSeconds: 42,
            posterImageURL: "media/clip-poster.jpg",
            autoplay: true,
            loop: true
        )
        var block = Block(type: .media)
        block.media = media
        XCTAssertEqual(block.type, .media)
        XCTAssertEqual(block.media, media)
        XCTAssertNotNil(block.attributes["media"])

        block.media = nil
        XCTAssertNil(block.attributes["media"])
        XCTAssertNil(block.media)
    }

    func testMediaBridgeIsNilForNonMediaBlockOrMissingAttribute() {
        XCTAssertNil(Block(type: .paragraph).media)
        XCTAssertNil(Block(type: .media).media, "no attributes[\"media\"] set yet - treated as 'no media', not corrupted data")
    }

    func testSettingMediaOnNonMediaBlockIsANoOp() {
        var block = Block(type: .paragraph)
        block.media = MediaBlock(kind: .audio, sourceURL: "media/narration.m4a")
        XCTAssertNil(block.media)
        XCTAssertNil(block.attributes["media"])
    }

    func testMediaBlockSurvivesDocumentASTRoundTrip() throws {
        var block = Block(type: .media)
        block.media = MediaBlock(kind: .audio, sourceURL: "media/narration.m4a", loop: true)
        let doc = DocumentAST(blocks: [block.id: block], rootChildren: [block.id])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentAST.self, from: data)
        XCTAssertEqual(decoded.blocks[block.id]?.media?.kind, .audio)
        XCTAssertEqual(decoded.blocks[block.id]?.media?.loop, true)
        XCTAssertEqual(decoded.rootChildren, [block.id])
    }
}
