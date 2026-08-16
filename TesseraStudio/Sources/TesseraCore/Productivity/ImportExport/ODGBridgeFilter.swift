import Foundation
import CoreGraphics

// MARK: - ODGBridgeFilter

/// `Drawing`'s ODG round trip - same three-stage bridge shape
/// `WriterBridgeFilter`/`CalcBridgeFilter` use (`LibreOfficeConverter`
/// for the real-package <-> flat-XML half, `FlatODFReader`/
/// `FlatODFWriter` for the flat-XML <-> tree half), specialized to
/// `Drawing`/`Shape` instead of `DocumentAST`/`Sheet`. Peer of 1.8's
/// `LOBridgeDeckIO` (same wave): that item maps `SlideDeck` <-> fodp;
/// this one maps `Drawing` <-> fodg - exactly the relationship
/// `FlatODFReader`'s own header comment names both items by.
///
/// **Scope, stated plainly (design-refinement doc section 1.18):**
/// only `ShapeKind`, `ShapeGeometry`'s position/size, `Drawing.layers`/
/// `Shape.layerID`, and `Shape.connector` are mapped - the contract's
/// own words are "onto ShapeKind cases + ShapeGeometry" plus the
/// layer-set and connector clauses; fill/stroke/text styling and
/// `ShapeGeometry.rotation`/`flipH`/`flipV` are NOT named there and
/// are intentionally out of scope. `canvasSize`/`canvasBackground`
/// likewise pass through untouched (they'd need the full ODF
/// page-style/master-page resolution chain - draw:page's
/// draw:master-page-name -> style:page-layout - which nothing in this
/// item's contract asks for).
///
/// **Round-trip identity, not just fidelity.** Every emitted shape
/// carries two ordinary, always-preserved ODF attributes: `draw:id`
/// (this shape's `Shape.id`, letting `draw:connector` reference it
/// with a real ODF ID/IDREF pair) and `draw:name` (a `"ts-kind:<kind>"`
/// marker). Both are standard, human-visible ODF shape properties (an
/// object's id and its display name in any ODF-consuming tool) with no
/// risk of being silently dropped by a real ODF processor - unlike,
/// say, gambling on an exact `draw:enhanced-geometry` preset-type
/// string surviving a real soffice round trip unverified. `draw:name`
/// is what lets `.arrow`/`.star`/`.freeform` (which have no distinct
/// native ODF primitive - see `elementName(for:)`) come back as the
/// same kind after a Tessera-authored round trip; a foreign ODG file
/// without this marker falls back to structural inference
/// (`shapeKind(for:)`), which only recovers `.rect`/`.ellipse`/`.line`/
/// `.polygon`/`.connector`.
public actor ODGBridgeFilter {

    public enum FilterError: Error, LocalizedError, Sendable, Equatable {
        case malformedDocument(String)

        public var errorDescription: String? {
            switch self {
            case .malformedDocument(let detail):
                return "ODGBridgeFilter: \(detail)"
            }
        }
    }

    private let converter: LibreOfficeConverter
    private let reader: FlatODFReader
    private let writer: FlatODFWriter

    public init(
        converter: LibreOfficeConverter = LibreOfficeConverter(),
        reader: FlatODFReader = FlatODFReader(),
        writer: FlatODFWriter = FlatODFWriter()
    ) {
        self.converter = converter
        self.reader = reader
        self.writer = writer
    }

    /// True when the underlying `soffice` conversion is available.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    // MARK: - Import

    public func `import`(from url: URL) async throws -> Drawing {
        let odgData = try Data(contentsOf: url)
        let fodgData = try await converter.convert(data: odgData, sourceExtension: "odg", targetExtension: "fodg")
        return try await Self.drawing(fromFodgData: fodgData, reader: reader)
    }

    /// Shared by both `import(from:)` and, indirectly, nothing else -
    /// pulled out as its own `static` (non-actor-isolated) function
    /// purely so it's independently testable against a hand-written
    /// fodg fixture without a real `soffice` conversion, the same way
    /// `CalcBridgeFilter.csvData(for:)` separates its pure half from
    /// the soffice-touching half.
    static func drawing(fromFodgData fodgData: Data, reader: FlatODFReader) async throws -> Drawing {
        let discardDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-odg-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: discardDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: discardDir) }

        let parsed = try await reader.parse(data: fodgData) { bytes in
            // No ShapeKind carries an embedded image (this file's
            // header) so any office:binary-data this document contains
            // (e.g. a draw:frame/draw:image this bridge doesn't map -
            // see the page-walk below) is never referenced again;
            // still needs *some* URL per FlatODFReader's contract, so
            // it's dropped in a throwaway directory removed on return.
            let discardURL = discardDir.appendingPathComponent(UUID().uuidString)
            try? bytes.write(to: discardURL)
            return discardURL
        }

        guard parsed.contentType == .drawing else {
            throw FilterError.malformedDocument("converted document is not a drawing (contentType: \(parsed.contentType))")
        }
        guard let page = parsed.bodyChildren.first(where: { $0.name == "office:drawing" })?
            .firstElementChild(named: "draw:page")
        else {
            throw FilterError.malformedDocument("no draw:page found in converted document")
        }

        let layerSet = parsed.root.firstElementChild(named: "office:master-styles")?
            .firstElementChild(named: "draw:layer-set")
        let layers: [DrawLayer] = (layerSet?.elementChildren ?? [])
            .compactMap { $0.attributes["draw:name"] }
            .map { DrawLayer(name: $0) }
        // `uniquingKeysWith:` (keep-first), not `uniqueKeysWithValues:`
        // - layer names come from external document content and two
        // duplicate draw:layer names must degrade, not crash the import.
        let layerIDByName = Dictionary(layers.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

        var shapes: [Shape] = []
        var drawIDToShapeID: [String: UUID] = [:]
        var connectorIndices: [(index: Int, element: FlatODFElement)] = []

        for element in page.elementChildren {
            guard let kind = shapeKind(for: element) else { continue }
            let shapeID = uuid(fromDrawID: element.attributes["draw:id"]) ?? UUID()
            if let drawID = element.attributes["draw:id"] {
                drawIDToShapeID[drawID] = shapeID
            }
            let layerID = element.attributes["draw:layer"].flatMap { layerIDByName[$0] }

            if kind == .connector {
                // A connector may reference a shape appearing LATER in
                // document order (ODF doesn't constrain this), so the
                // draw:id -> Shape.id map must be complete first -
                // resolved in a second pass below, once every shape in
                // this loop has registered its own draw:id.
                connectorIndices.append((shapes.count, element))
                shapes.append(Shape(
                    id: shapeID, kind: .connector,
                    geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
                    zIndex: shapes.count, layerID: layerID
                ))
                continue
            }

            var shape = Shape(
                id: shapeID, kind: kind, geometry: geometry(for: element, kind: kind),
                zIndex: shapes.count, layerID: layerID
            )
            if kind == .bezier {
                shape.path = Self.shapePath(for: element, boxGeometry: shape.geometry)
            }
            shapes.append(shape)
        }

        for (index, element) in connectorIndices {
            let info = connectorInfo(element, drawIDToShapeID: drawIDToShapeID)
            shapes[index].connector = info
            shapes[index].geometry = connectorGeometry(info, shapes: shapes)
        }

        var result = Drawing(layers: layers)
        for shape in shapes {
            result = result.insertingShape(shape)
        }
        return result
    }

    // MARK: - Export

    public func export(_ drawing: Drawing, to url: URL) async throws {
        let root = Self.flatODFTree(for: drawing)
        let fodgData = try await writer.write(root) { referenced in
            throw FilterError.malformedDocument("unexpected externalized binary data reference: \(referenced.absoluteString)")
        }
        let odgData = try await converter.convert(data: fodgData, sourceExtension: "fodg", targetExtension: "odg")
        try odgData.write(to: url)
    }

    /// Builds the fodg tree for `drawing`. Shared with
    /// `SVGBridgeFilter.export`/`PDFExportBridge.export`, which convert
    /// through this SAME tree to svg/pdf instead of odg - matching this
    /// item's contract ("implement [SVG export] the same shape as
    /// ODGBridgeFilter's export", and PDFExportBridge's identical
    /// "Drawing -> fodg -> soffice convert-to X" mechanism). Internal
    /// module visibility (not `private`), not a new shared file: all
    /// three bridges live in this same target, so this stays the one
    /// place shape<->ODF mapping is written, without adding a file
    /// outside this item's given list.
    static func flatODFTree(for drawing: Drawing) -> FlatODFElement {
        let orderedShapes = LayerStore.paintOrder(shapes: drawing.shapes, layers: drawing.layers)
        // `uniquingKeysWith:` for the same reason as the import-side
        // map above, even though `DrawLayer.id` collisions shouldn't
        // arise from any code path that constructs a `Drawing` today -
        // defense in depth costs nothing here.
        let layerNameByID = Dictionary(drawing.layers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shapeElements = orderedShapes.map {
            shapeElement($0, layerNameByID: layerNameByID, allShapes: orderedShapes)
        }

        let page = FlatODFElement(
            name: "draw:page",
            attributes: ["draw:name": drawing.displayTitle],
            children: shapeElements.map { .element($0) }
        )
        let drawingElement = FlatODFElement(name: "office:drawing", children: [.element(page)])
        let body = FlatODFElement(name: "office:body", children: [.element(drawingElement)])

        var rootChildren: [FlatODFNode] = []
        if !drawing.layers.isEmpty {
            let layerSet = FlatODFElement(
                name: "draw:layer-set",
                children: drawing.layers.map {
                    .element(FlatODFElement(name: "draw:layer", attributes: ["draw:name": $0.name]))
                }
            )
            rootChildren.append(.element(FlatODFElement(name: "office:master-styles", children: [.element(layerSet)])))
        }
        rootChildren.append(.element(body))

        return FlatODFElement(
            name: "office:document",
            attributes: [
                "xmlns:office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
                "xmlns:draw": "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0",
                "xmlns:svg": "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0",
                "office:version": "1.3",
                "office:mimetype": "application/vnd.oasis.opendocument.graphics",
            ],
            children: rootChildren
        )
    }

    // MARK: - Shape <-> element (export)

    private static func shapeElement(_ shape: Shape, layerNameByID: [UUID: String], allShapes: [Shape]) -> FlatODFElement {
        var attributes: [String: String] = [
            "draw:id": drawID(for: shape.id),
            "draw:name": kindMarker(for: shape.kind),
        ]
        if let layerID = shape.layerID, let name = layerNameByID[layerID] {
            attributes["draw:layer"] = name
        }

        switch shape.kind {
        case .rect, .freeform, .ellipse:
            attributes.merge(boxAttributes(shape.geometry)) { _, new in new }
        case .bezier:
            // Item 2.3's real I/O work - a real draw:path element,
            // empirically probed against soffice 26.2.5.2 (2026-08-15,
            // see ODGBezierPathWireFormatProbeTests.swift). svg:viewBox
            // spans the SAME numeric range as this shape's own local
            // path-point space (0...width, 0...height, matching
            // ShapePath's own local-coordinate convention - see
            // ShapePath.swift's header and ShapeRenderer's .bezier
            // case), so svg:d's numbers are shape.path's own points
            // written through verbatim - no rescale needed on export;
            // drawing(fromFodgData:) rescales on the way back in, since
            // a REAL soffice round trip rewrites svg:viewBox to its own
            // internal unit (confirmed empirically).
            attributes.merge(boxAttributes(shape.geometry)) { _, new in new }
            attributes["svg:viewBox"] = "0 0 \(formatUnitless(max(shape.geometry.width, 0))) \(formatUnitless(max(shape.geometry.height, 0)))"
            attributes["svg:d"] = (shape.path ?? ShapePath()).pathData
        case .line, .arrow:
            attributes.merge(lineAttributes(shape.geometry)) { _, new in new }
        case .polygon, .star:
            attributes.merge(boxAttributes(shape.geometry)) { _, new in new }
            attributes.merge(polygonAttributes(innerRatio: shape.kind == .star ? 0.45 : 1.0)) { _, new in new }
        case .connector:
            attributes.merge(connectorAttributes(shape, allShapes: allShapes)) { _, new in new }
        }
        return FlatODFElement(name: elementName(for: shape.kind), attributes: attributes)
    }

    /// No native ODF primitive distinguishes `.arrow` from `.line` or
    /// `.star`/`.freeform` from `.polygon`/`.rect` (see this file's
    /// header) - each maps onto the plain element its geometry actually
    /// matches; `draw:name`'s kind marker is what recovers the exact
    /// `ShapeKind` on the way back in.
    private static func elementName(for kind: ShapeKind) -> String {
        switch kind {
        case .rect, .freeform: return "draw:rect"
        case .bezier: return "draw:path"
        case .ellipse: return "draw:ellipse"
        case .line, .arrow: return "draw:line"
        case .polygon, .star: return "draw:polygon"
        case .connector: return "draw:connector"
        }
    }

    private static func boxAttributes(_ g: ShapeGeometry) -> [String: String] {
        [
            "svg:x": formatLength(g.x),
            "svg:y": formatLength(g.y),
            "svg:width": formatLength(max(g.width, 0)),
            "svg:height": formatLength(max(g.height, 0)),
        ]
    }

    /// `ShapeRenderer.linePath` always draws the frame's own vertical
    /// midline, left to right - matched here so a horizontal line's
    /// endpoints reconstruct exactly on re-import; a shape's `height`
    /// (a hit-box concept ODF's endpoint-pair line has no equivalent
    /// of) does NOT survive this mapping and reconstructs as 0 - an
    /// accepted, documented loss, not a bug (this item's contract does
    /// not ask for hit-box fidelity).
    private static func lineAttributes(_ g: ShapeGeometry) -> [String: String] {
        let midY = g.y + g.height / 2
        return [
            "svg:x1": formatLength(g.x),
            "svg:y1": formatLength(midY),
            "svg:x2": formatLength(g.x + g.width),
            "svg:y2": formatLength(midY),
        ]
    }

    /// A raw `draw:polygon` point list (fixed 0..1000 `svg:viewBox`,
    /// independent of the shape's real-world `svg:width`/`svg:height`)
    /// rather than a `draw:custom-shape` preset-type name - deliberately
    /// the safer of the two: a literal point list is read exactly as
    /// given by any ODF processor, with none of the "does soffice
    /// recognize this exact preset-type token" risk a named preset
    /// would carry (see this file's header). Regular N-gon math mirrors
    /// `ShapeRenderer.regularStarPath` (same vertex formula, same
    /// -pi/2 top-first orientation) purely so the imported outline
    /// LOOKS like what P0 already renders - not required for round-trip
    /// kind fidelity, which `draw:name`'s marker alone provides.
    private static func polygonAttributes(innerRatio: Double) -> [String: String] {
        let points = regularPolygonPoints(width: 1000, height: 1000, sides: 5, innerRatio: innerRatio)
            .map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }
            .joined(separator: " ")
        return ["svg:viewBox": "0 0 1000 1000", "draw:points": points]
    }

    private static func regularPolygonPoints(width: Double, height: Double, sides: Int, innerRatio: Double) -> [CGPoint] {
        guard sides >= 3 else { return [] }
        let w = CGFloat(width), h = CGFloat(height)
        let center = CGPoint(x: w / 2, y: h / 2)
        let outerR = min(w, h) / 2
        let innerR = outerR * CGFloat(innerRatio)
        let vertexCount = innerRatio < 1 ? sides * 2 : sides
        let angleStep = (2 * Double.pi) / Double(vertexCount)
        var points: [CGPoint] = []
        for i in 0..<vertexCount {
            let r = (innerRatio < 1 && i % 2 == 1) ? innerR : outerR
            let angle = angleStep * Double(i) - .pi / 2
            points.append(CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle))))
        }
        return points
    }

    /// `draw:type`'s real ODF enumeration, confirmed empirically against
    /// LibreOffice 26.2.5.2: hand-authored a fodg with four connectors
    /// typed "standard"/"lines"/"curve"/(no attribute), round-tripped
    /// each through real `soffice --convert-to odg` then `--convert-to
    /// fodg` (twice, to confirm stability), and diffed the resulting
    /// `draw:connector` elements. Only THREE values are real: "standard"
    /// is the schema default - writing it explicitly round-trips to no
    /// `draw:type` attribute at all on soffice's own re-export, same as
    /// omitting it; "lines" is the one that survives unchanged and is
    /// the correct target for `ConnectorStyle.straight` (a single
    /// straight run between each endpoint's short perpendicular stub -
    /// there is no literal "straight" token: writing `draw:type=
    /// "straight"` degrades silently to "standard", identical to
    /// writing a nonsense value like "bogus"); "curve" also survives
    /// unchanged and is `ConnectorStyle.curved`. Representative observed
    /// fragments (soffice's own re-export):
    /// `<draw:connector draw:type="lines" ... svg:d="M4000 2000h501l2998 7000h501" .../>`
    /// `<draw:connector draw:type="curve" ... svg:d="M4000 24000c1000 0 2000 1750 2000 3500s1000 3500 2000 3500" .../>`
    /// `<draw:connector ... svg:d="M4000 13000h2000v7000h2000" .../>` (no
    /// `draw:type` - this one was authored as "standard").
    private static func connectorAttributes(_ shape: Shape, allShapes: [Shape]) -> [String: String] {
        var attributes: [String: String] = ["draw:type": drawType(for: shape.connector?.style ?? .elbow)]
        guard let info = shape.connector else { return attributes }
        var byID: [UUID: Shape] = Dictionary(minimumCapacity: allShapes.count)
        for s in allShapes { byID[s.id] = s }

        func resolve(_ endpoint: ConnectorEndpoint, prefix: String) -> CGPoint {
            switch endpoint {
            case .free(let x, let y):
                return CGPoint(x: CGFloat(x), y: CGFloat(y))
            case .attached(let shapeID, let index):
                attributes["draw:\(prefix)-shape"] = drawID(for: shapeID)
                attributes["draw:\(prefix)-glue-point"] = String(index)
                guard let attachedShape = byID[shapeID], let point = ConnectorRouter.gluePoint(index, for: attachedShape) else {
                    return .zero
                }
                return point
            }
        }

        let start = resolve(info.start, prefix: "start")
        let end = resolve(info.end, prefix: "end")
        attributes["svg:x1"] = formatLength(Double(start.x))
        attributes["svg:y1"] = formatLength(Double(start.y))
        attributes["svg:x2"] = formatLength(Double(end.x))
        attributes["svg:y2"] = formatLength(Double(end.y))
        return attributes
    }

    /// The three real `draw:type` tokens - see `connectorAttributes`'s
    /// doc comment for how these were confirmed. `.elbow` writes
    /// "standard" explicitly (rather than omitting the attribute)
    /// purely so the PURE `flatODFTree`/`drawing(fromFodgData:)` half
    /// round-trips `.elbow` correctly on its own, without depending on
    /// soffice being the one to supply the default.
    private static func drawType(for style: ConnectorStyle) -> String {
        switch style {
        case .straight: return "lines"
        case .curved: return "curve"
        case .elbow: return "standard"
        }
    }

    // MARK: - Element <-> shape (import)

    private static func shapeKind(for element: FlatODFElement) -> ShapeKind? {
        if let marker = kind(fromNameMarker: element.attributes["draw:name"]) {
            return marker
        }
        switch element.name {
        case "draw:rect": return .rect
        case "draw:ellipse", "draw:circle": return .ellipse
        case "draw:line": return .line
        case "draw:polygon": return .polygon
        case "draw:path": return .bezier
        case "draw:connector": return .connector
        default:
            // draw:frame (images), draw:g (groups - Drawing's own
            // grouping is still P1 per Drawing.swift's header), and
            // any draw:custom-shape without a recognized marker are
            // all silently skipped - out of this item's contract, and
            // "malformed/foreign data degrades" rather than blocking
            // the rest of the page's shapes from importing.
            return nil
        }
    }

    private static func geometry(for element: FlatODFElement, kind: ShapeKind) -> ShapeGeometry {
        switch kind {
        case .line, .arrow:
            let x1 = parseLength(element.attributes["svg:x1"]) ?? 0
            let y1 = parseLength(element.attributes["svg:y1"]) ?? 0
            let x2 = parseLength(element.attributes["svg:x2"]) ?? x1
            let y2 = parseLength(element.attributes["svg:y2"]) ?? y1
            return ShapeGeometry(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        default:
            let x = parseLength(element.attributes["svg:x"]) ?? 0
            let y = parseLength(element.attributes["svg:y"]) ?? 0
            let width = parseLength(element.attributes["svg:width"]) ?? 0
            let height = parseLength(element.attributes["svg:height"]) ?? 0
            return ShapeGeometry(x: x, y: y, width: width, height: height)
        }
    }

    /// The inverse of `drawType(for:)`: "lines" -> `.straight`, "curve"
    /// -> `.curved`. "standard", a missing attribute, and any other
    /// value (a foreign document's own scheme, or soffice's own
    /// re-export of "standard"/an invalid token, both of which drop the
    /// attribute entirely - see `connectorAttributes`'s doc comment) all
    /// degrade to `ConnectorInfo`'s own default, `.elbow` - "malformed
    /// data degrades," matching this file's other import parsing.
    private static func connectorStyle(fromDrawType raw: String?) -> ConnectorStyle {
        switch raw {
        case "lines": return .straight
        case "curve": return .curved
        default: return .elbow
        }
    }

    private static func connectorInfo(_ element: FlatODFElement, drawIDToShapeID: [String: UUID]) -> ConnectorInfo {
        func endpoint(shapeAttr: String, glueAttr: String, xAttr: String, yAttr: String) -> ConnectorEndpoint {
            if let drawID = element.attributes[shapeAttr],
               let shapeID = drawIDToShapeID[drawID],
               let glueIndex = element.attributes[glueAttr].flatMap(Int.init) {
                return .attached(shapeID: shapeID, gluePointIndex: glueIndex)
            }
            return .free(x: parseLength(element.attributes[xAttr]) ?? 0, y: parseLength(element.attributes[yAttr]) ?? 0)
        }
        return ConnectorInfo(
            start: endpoint(shapeAttr: "draw:start-shape", glueAttr: "draw:start-glue-point", xAttr: "svg:x1", yAttr: "svg:y1"),
            end: endpoint(shapeAttr: "draw:end-shape", glueAttr: "draw:end-glue-point", xAttr: "svg:x2", yAttr: "svg:y2"),
            style: connectorStyle(fromDrawType: element.attributes["draw:type"])
        )
    }

    /// `Shape.geometry` is not `.connector`'s source of truth for
    /// rendering (`Shape.connector`'s own doc comment) - this is just a
    /// harmless, reasonable placeholder bounding box so the field is
    /// never left at a nonsensical all-zero default post-import.
    private static func connectorGeometry(_ info: ConnectorInfo, shapes: [Shape]) -> ShapeGeometry {
        var byID: [UUID: Shape] = Dictionary(minimumCapacity: shapes.count)
        for s in shapes { byID[s.id] = s }
        func point(_ endpoint: ConnectorEndpoint) -> CGPoint {
            switch endpoint {
            case .free(let x, let y):
                return CGPoint(x: CGFloat(x), y: CGFloat(y))
            case .attached(let shapeID, let index):
                guard let s = byID[shapeID], let p = ConnectorRouter.gluePoint(index, for: s) else { return .zero }
                return p
            }
        }
        let p1 = point(info.start)
        let p2 = point(info.end)
        return ShapeGeometry(
            x: Double(min(p1.x, p2.x)), y: Double(min(p1.y, p2.y)),
            width: Double(abs(p2.x - p1.x)), height: Double(abs(p2.y - p1.y))
        )
    }

    // MARK: - draw:id / draw:name markers

    private static func drawID(for id: UUID) -> String {
        "ts" + id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// The inverse of `drawID(for:)` - only recognizes IDs THIS bridge
    /// minted (the `"ts" + 32 hex chars` shape); anything else (a
    /// foreign document's own `draw:id` scheme, or none at all) simply
    /// doesn't resolve, and the caller mints a fresh `UUID` instead.
    private static func uuid(fromDrawID raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix("ts") else { return nil }
        let hex = raw.dropFirst(2)
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let s = String(hex)
        let grouped = [
            s.prefix(8),
            s.dropFirst(8).prefix(4),
            s.dropFirst(12).prefix(4),
            s.dropFirst(16).prefix(4),
            s.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: grouped)
    }

    private static func kindMarker(for kind: ShapeKind) -> String {
        "ts-kind:\(kind.rawValue)"
    }

    private static func kind(fromNameMarker raw: String?) -> ShapeKind? {
        guard let raw, raw.hasPrefix("ts-kind:") else { return nil }
        return ShapeKind(rawValue: String(raw.dropFirst("ts-kind:".count)))
    }

    // MARK: - Length units

    /// Points-per-unit for the length units real ODF documents (soffice
    /// own output included, per `FlatODFReaderTests`' fixtures) actually
    /// use for shape geometry. An unrecognized/missing unit is read as
    /// bare points rather than failing the shape - "malformed data
    /// degrades," matching this file's other parsing.
    private static func pointsPerUnit(_ unit: String) -> Double {
        switch unit {
        case "cm": return 72.0 / 2.54
        case "mm": return 72.0 / 25.4
        case "in": return 72.0
        case "pt": return 1.0
        case "pc": return 12.0
        default: return 1.0
        }
    }

    static func parseLength(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        // Walk back from the end while the character is a letter, so
        // "1.5cm" splits into number "1.5" and unit "cm" without
        // assuming the unit is exactly 2 characters (covers "in"/"pt"/
        // "pc"/"mm"/"cm" alike, and degrades to "no unit" for a bare
        // number like "12").
        var numberEnd = raw.endIndex
        while numberEnd > raw.startIndex, raw[raw.index(before: numberEnd)].isLetter {
            numberEnd = raw.index(before: numberEnd)
        }
        let numberText = String(raw[..<numberEnd])
        let unit = String(raw[numberEnd...])
        guard let magnitude = Double(numberText) else { return nil }
        return magnitude * pointsPerUnit(unit)
    }

    /// Always written in cm (4 decimal places, sub-micron precision) -
    /// the unit soffice's own ODF export uses by default, matching
    /// `FlatODFReaderTests`' fixtures.
    private static func formatLength(_ points: Double) -> String {
        String(format: "%.4fcm", points * 2.54 / 72.0)
    }

    /// A bare (unitless) number for `svg:viewBox` - unlike `svg:x`/
    /// `svg:width`/etc, ODF's `svg:viewBox` is explicitly a unitless
    /// coordinate-space extent (confirmed by every observed real
    /// `svg:viewBox` value in this file and its probes: "0 0 1000
    /// 1000", "0 0 4001 3001" - never a "4001cm"-style suffix), so this
    /// deliberately does NOT go through `formatLength`'s cm conversion.
    private static func formatUnitless(_ value: Double) -> String {
        String(value)
    }

    // MARK: - Path data (item 2.3, .bezier shapes)

    /// Recovers a `.bezier` shape's `ShapePath` from its element -
    /// either a real `draw:path` (`svg:d` present), or the
    /// curve-free-closed-shape DEMOTION soffice's own re-export applies
    /// (confirmed empirically, 2026-08-15 against LibreOffice 26.2.5.2 -
    /// see `ODGBezierPathWireFormatProbeTests.swift`): a `.bezier` whose
    /// every subpath is closed AND built only from straight segments
    /// round-trips through a real `soffice --convert-to` as a plain
    /// `draw:polygon` instead, since soffice's own internal PolyPolygon
    /// model simplifies a curve-free closed shape on export. `draw:name`
    /// still carries this bridge's own `"ts-kind:bezier"` marker
    /// regardless of which of the two elements the shape actually landed
    /// on (`shapeKind(for:)` already resolves the marker before this
    /// runs), so this function reads whichever ELEMENT the marker turned
    /// out to be attached to rather than assuming `draw:path`.
    private static func shapePath(for element: FlatODFElement, boxGeometry: ShapeGeometry) -> ShapePath {
        let target = CGRect(x: 0, y: 0, width: max(boxGeometry.width, 0), height: max(boxGeometry.height, 0))
        let raw: ShapePath
        if element.name == "draw:polygon" {
            raw = polygonShapePath(fromDrawPoints: element.attributes["draw:points"])
        } else {
            guard let d = element.attributes["svg:d"] else { return ShapePath() }
            raw = ShapePath.parsingPathData(d)
        }
        let viewBox = parsedViewBox(element.attributes["svg:viewBox"]) ?? target
        return raw.rescaled(from: viewBox, to: target)
    }

    /// The demoted-to-polygon fallback (see `shapePath(for:boxGeometry:)`'s
    /// doc comment): `draw:points` is the SAME `"x,y x,y ..."` list
    /// format `polygonAttributes`/`regularPolygonPoints` above already
    /// write for `.polygon`/`.star`, reconstructed here as one CLOSED
    /// subpath of straight `.line` segments (a demoted `.bezier` is, by
    /// construction, exactly that: every subpath was already closed and
    /// curve-free, or soffice would not have simplified it this way).
    private static func polygonShapePath(fromDrawPoints raw: String?) -> ShapePath {
        guard let raw, !raw.isEmpty else { return ShapePath() }
        let points: [ShapePathPoint] = raw.split(separator: " ").compactMap { token in
            let parts = token.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return ShapePathPoint(x: x, y: y)
        }
        guard let first = points.first else { return ShapePath() }
        var segments: [ShapePathSegment] = [.move(first)]
        segments.append(contentsOf: points.dropFirst().map { .line($0) })
        return ShapePath(subpaths: [ShapeSubpath(segments: segments, closed: true)])
    }

    /// Parses `"minX minY width height"` (ODF/SVG's own `svg:viewBox`
    /// syntax) - `nil` (not a degenerate `CGRect`) for anything
    /// malformed or absent, so callers can tell "no viewBox" apart from
    /// "a zero-size one" and choose their own fallback.
    private static func parsedViewBox(_ raw: String?) -> CGRect? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
