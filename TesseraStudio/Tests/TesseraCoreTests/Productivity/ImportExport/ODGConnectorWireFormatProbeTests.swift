import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ODGConnectorWireFormatProbeTests
//
// QUARANTINED EMPIRICAL PROBE (doctrine rule 10). Shells out to a real
// `soffice` to re-verify ODGBridgeFilter's `draw:type` wire-format
// mapping end to end (Drawing -> fodg -> soffice odg -> soffice fodg ->
// Drawing), through TESSERA'S OWN `ODGBridgeFilter.export`/`.import`
// code path, not just hand-authored XML.
//
// PROBE DATE / TOOL VERSION (re-run TODAY, not copied from
// ODGBridgeFilter.swift's existing doc comment - doctrine rule 10:
// "re-verification happens by re-running them, not by trusting the
// comment"):
//   - Probed: 2026-08-15
//   - `soffice --version`: LibreOffice 26.2.5.2
//     (cd7284b4cbbfeb507e630c1aac019f4157393acb), confirmed via a fresh
//     manual round trip (hand-authored fodg with four connectors typed
//     "standard"/"lines"/"curve"/no-attribute, converted fodg->odg->fodg
//     via this machine's real soffice, diffed the re-exported
//     draw:connector elements) immediately before writing this file.
//     Result CONFIRMED the existing finding: "standard" and a missing
//     attribute both round-trip to NO draw:type attribute at all;
//     "lines" and "curve" survive unchanged. Same treatment applied to
//     FlatODFWriter's draw:layer-set-under-office:master-styles rule
//     (rule 2): a layer-set placed directly under office:drawing (wrong)
//     is silently dropped by soffice's own re-export (LO substitutes its
//     4 built-in layers with no trace of the custom one); the same
//     layer-set placed under office:master-styles (right) survives.
//
// Skips cleanly when soffice is absent (`ODGBridgeFilter().isAvailable`).
// 120s allowance (DoctrineTimeout.probe) per rule 12. Rule 11's ungated
// shadow of this exact draw:type <-> ConnectorStyle contract lives in
// ODGBridgeFilterTests.swift (hand-authored fodg fixtures, no soffice).

final class ODGConnectorWireFormatProbeTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func skipIfSofficeUnavailable(_ filter: ODGBridgeFilter) throws {
        // `isAvailable` is `nonisolated` on the actor, so no await needed.
        guard filter.isAvailable else {
            throw XCTSkip("soffice not found on this machine - skipping live ODG connector wire-format probe.")
        }
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("odg-probe-\(UUID().uuidString)-\(name)")
    }

    func testConnectorStylesSurviveARealSofficeRoundTripThroughODGBridgeFilter() async throws {
        let filter = ODGBridgeFilter()
        try skipIfSofficeUnavailable(filter)

        let a = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 40, height: 40))
        let b = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 40, height: 40))
        var straight = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        straight.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 1), end: .attached(shapeID: b.id, gluePointIndex: 3), style: .straight)
        var curved = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        curved.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 2), end: .attached(shapeID: b.id, gluePointIndex: 0), style: .curved)
        var elbow = Shape(kind: .connector, geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0))
        elbow.connector = ConnectorInfo(start: .attached(shapeID: a.id, gluePointIndex: 3), end: .attached(shapeID: b.id, gluePointIndex: 1), style: .elbow)

        let drawing = Drawing.makeBlank(title: "Probe")
            .insertingShape(a).insertingShape(b)
            .insertingShape(straight).insertingShape(curved).insertingShape(elbow)

        let odgURL = tempURL("connectors.odg")
        defer { try? FileManager.default.removeItem(at: odgURL) }

        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.export(drawing, to: odgURL)
        }
        let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.import(from: odgURL)
        }

        let connectors = roundTripped.shapes.filter { $0.kind == .connector }
        XCTAssertEqual(connectors.count, 3, "all three connector shapes must survive the round trip")

        let styles = Set(connectors.compactMap { $0.connector?.style })
        XCTAssertEqual(styles, [.straight, .curved, .elbow], "every connector style must round-trip through a real soffice conversion, matching the confirmed draw:type wire vocabulary")
    }

    func testCustomLayerSurvivesARealSofficeRoundTripThroughODGBridgeFilter() async throws {
        let filter = ODGBridgeFilter()
        try skipIfSofficeUnavailable(filter)

        let drawing = Drawing.makeBlank(title: "Layer Probe").addingLayer(DrawLayer(name: "ProbeCustomLayer"))
        let odgURL = tempURL("layers.odg")
        defer { try? FileManager.default.removeItem(at: odgURL) }

        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.export(drawing, to: odgURL)
        }
        let roundTripped = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.import(from: odgURL)
        }

        XCTAssertTrue(roundTripped.layers.contains { $0.name == "ProbeCustomLayer" }, "a custom layer must survive a real soffice round trip when draw:layer-set is placed under office:master-styles (FlatODFWriter's empirically-confirmed rule 2)")
    }
}
