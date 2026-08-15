import Foundation

// MARK: - SVGBridgeFilter

/// SVG <-> `Drawing`, split asymmetrically per this item's design
/// contract:
///
/// **Import is embedded-image fidelity only, by design, not by
/// omission.** Running `soffice --convert-to fodg` on an .svg was
/// verified (design-refinement doc section 1.18) to produce a
/// `draw:page` with a single `draw:frame`/`draw:image` - one embedded
/// raster, not decomposed native shapes. `Shape` has no image-bearing
/// `ShapeKind` (`ODGBridgeFilter`'s header explains why none of its
/// mapped kinds fit an image), so this filter does not force one:
/// `import(from:)` returns an ``ImportResult`` wrapping a `Drawing`
/// whose body holds exactly one `BlockType.image` block (the "media/
/// image block-equivalent" this item's contract names as the
/// alternative to a `Shape`) plus an explicit ``ImportFidelity`` -
/// belt-and-suspenders marking: the block's OWN type already says
/// "this is an image, not vector content," and
/// `attributes["importFidelity"]` additionally distinguishes THIS
/// lossy SVG-embedding path from an ordinary user-inserted photo,
/// which is otherwise the same block type. Shape-level SVG import
/// (native path decomposition) is explicitly out of scope here - the
/// contract defers it to a P3 native parser or Option C's `.uno:Break`,
/// a decision for 1.18 scoping, not this implementation.
///
/// **Export is the ordinary shapes bridge**, per the contract's own
/// words ("implement it the same shape as ODGBridgeFilter's export"):
/// `Drawing` -> fodg (`ODGBridgeFilter.flatODFTree(for:)`, shared, not
/// duplicated - see that function's doc comment) -> `soffice
/// --convert-to svg`. It does NOT specially handle a `Drawing` that
/// came back out of THIS type's own `import(from:)` (i.e. one holding
/// only a `.image` block, zero `.shape` blocks) - such a `Drawing`
/// exports as an EMPTY page, since there is no vector-model path to
/// carry a raw embedded image through `ODGBridgeFilter`'s shapes-only
/// tree builder. Re-emitting the original SVG bytes verbatim on that
/// path isn't part of this item's contract either.
public actor SVGBridgeFilter {

    public enum FilterError: Error, LocalizedError, Sendable, Equatable {
        case malformedDocument(String)
        case noEmbeddedImage

        public var errorDescription: String? {
            switch self {
            case .malformedDocument(let detail):
                return "SVGBridgeFilter: \(detail)"
            case .noEmbeddedImage:
                return "SVGBridgeFilter: converted document has no embedded image frame"
            }
        }
    }

    /// P1 has exactly one fidelity level - see this type's header.
    /// A distinct `RawRepresentable` type (not a bare `Bool`) so a
    /// future `.nativeShapes` case (the P3/Option-C path the contract
    /// names) is additive, not a breaking signature change.
    public enum ImportFidelity: String, Sendable, Equatable {
        case embeddedImage
    }

    public struct ImportResult: Sendable, Equatable {
        public let drawing: Drawing
        public let importFidelity: ImportFidelity
    }

    private let converter: LibreOfficeConverter
    private let reader: FlatODFReader
    private let writer: FlatODFWriter
    /// Where `import(from:)` writes the extracted raster - `nil` (the
    /// default) falls back to the system temporary directory, matching
    /// `TesseraImporter`'s own `mediaDir: URL? = nil` convention
    /// (caller decides, sensible default when it doesn't).
    private let mediaDir: URL?

    public init(
        converter: LibreOfficeConverter = LibreOfficeConverter(),
        reader: FlatODFReader = FlatODFReader(),
        writer: FlatODFWriter = FlatODFWriter(),
        mediaDir: URL? = nil
    ) {
        self.converter = converter
        self.reader = reader
        self.writer = writer
        self.mediaDir = mediaDir
    }

    /// True when the underlying `soffice` conversion is available.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    // MARK: - Import

    public func `import`(from url: URL) async throws -> ImportResult {
        let svgData = try Data(contentsOf: url)
        let fodgData = try await converter.convert(data: svgData, sourceExtension: "svg", targetExtension: "fodg")

        let targetDir = mediaDir ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        var extractedTempURL: URL?
        let baseName = url.deletingPathExtension().lastPathComponent

        // The binary-data callback fires mid-parse, on office:binary-
        // data's OWN closing tag - its sibling draw:image (the element
        // that would carry a mime-type hint) hasn't finished building
        // yet at that point, so the mime type can only be read from
        // the completed tree AFTER parse() returns (below). Bytes are
        // extracted to an extension-less temp file now and renamed
        // once the real extension is known.
        let parsed = try await reader.parse(data: fodgData) { bytes in
            let tempURL = targetDir.appendingPathComponent("tessera-svg-import-\(UUID().uuidString).tmp")
            try? bytes.write(to: tempURL)
            if extractedTempURL == nil { extractedTempURL = tempURL }
            return tempURL
        }

        guard parsed.contentType == .drawing else {
            throw FilterError.malformedDocument("converted document is not a drawing (contentType: \(parsed.contentType))")
        }
        guard let page = parsed.bodyChildren.first(where: { $0.name == "office:drawing" })?
            .firstElementChild(named: "draw:page"),
            let frame = page.elementChildren.first(where: { $0.name == "draw:frame" }),
            let image = frame.firstElementChild(named: "draw:image")
        else {
            throw FilterError.noEmbeddedImage
        }
        guard let tempURL = extractedTempURL else {
            throw FilterError.noEmbeddedImage
        }

        let ext = Self.fileExtension(forMimeType: image.attributes["draw:mime-type"])
        let imageURL = targetDir.appendingPathComponent("\(baseName)-embedded-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: tempURL, to: imageURL)

        let width = ODGBridgeFilter.parseLength(frame.attributes["svg:width"]) ?? CanvasSize.default.width
        let height = ODGBridgeFilter.parseLength(frame.attributes["svg:height"]) ?? CanvasSize.default.height

        var block = Block(type: .image)
        block.attributes["source"] = .string(imageURL.absoluteString)
        block.attributes["alt"] = .string(baseName)
        block.attributes["importFidelity"] = .string(ImportFidelity.embeddedImage.rawValue)

        var body = DocumentAST()
        body.blocks[block.id] = block
        body.rootChildren = [block.id]

        let drawing = Drawing(title: baseName, body: body, canvasSize: CanvasSize(width: width, height: height))
        return ImportResult(drawing: drawing, importFidelity: .embeddedImage)
    }

    // MARK: - Export

    /// Same tree `ODGBridgeFilter.export` builds, converted to `svg`
    /// instead of `odg` - see this type's header for what this does
    /// and does not round-trip.
    public func export(_ drawing: Drawing, to url: URL) async throws {
        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        let fodgData = try await writer.write(root) { referenced in
            throw FilterError.malformedDocument("unexpected externalized binary data reference: \(referenced.absoluteString)")
        }
        let svgData = try await converter.convert(data: fodgData, sourceExtension: "fodg", targetExtension: "svg")
        try svgData.write(to: url)
    }

    // MARK: - MIME type -> extension

    /// `draw:mime-type`'s exact attribute name/presence on a flat-ODF
    /// `draw:image` wasn't verified against a real soffice sample in
    /// this pass (see this item's report) - `nil`/unrecognized falls
    /// back to "png" (soffice's typical rasterization target for an
    /// embedded SVG per this type's header), never fails the import.
    private static func fileExtension(forMimeType mimeType: String?) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/svg+xml": return "svg"
        case "image/gif": return "gif"
        case "image/png": return "png"
        default: return "png"
        }
    }
}
