import Foundation

// MARK: - PDFExportBridge

/// `Drawing` -> PDF via the same fodg pipeline `ODGBridgeFilter`/
/// `SVGBridgeFilter` use for their own export halves: `Drawing` ->
/// fodg (`ODGBridgeFilter.flatODFTree(for:)`, shared - see that
/// function's doc comment) -> `soffice --convert-to pdf`. A separate
/// file from `ODGBridgeFilter`, per this item's contract's explicit
/// 3-file split, even though the mechanism past the final
/// `--convert-to` target extension is identical.
///
/// **Export-only.** PDF import into a native vector `Drawing` is a
/// much larger, unscoped problem (most consumer tools don't attempt it
/// either) and isn't named anywhere in this item's contract - only
/// "SVG/PDF export verified working" is.
///
/// **NOT this type's job: PNG/JPG export.** Per this item's design
/// contract, that's a native, non-soffice path
/// (`UIGraphicsImageRenderer` over `ShapeRenderer`) built in an
/// earlier wave - a different mechanism entirely, out of scope for a
/// soffice bridge file, even though the same design-doc sentence
/// mentions it alongside SVG/PDF export.
public actor PDFExportBridge {

    public enum FilterError: Error, LocalizedError, Sendable, Equatable {
        case malformedDocument(String)

        public var errorDescription: String? {
            switch self {
            case .malformedDocument(let detail):
                return "PDFExportBridge: \(detail)"
            }
        }
    }

    private let converter: LibreOfficeConverter
    private let writer: FlatODFWriter

    public init(converter: LibreOfficeConverter = LibreOfficeConverter(), writer: FlatODFWriter = FlatODFWriter()) {
        self.converter = converter
        self.writer = writer
    }

    /// True when the underlying `soffice` conversion is available.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    public func export(_ drawing: Drawing, to url: URL) async throws {
        let root = ODGBridgeFilter.flatODFTree(for: drawing)
        let fodgData = try await writer.write(root) { referenced in
            throw FilterError.malformedDocument("unexpected externalized binary data reference: \(referenced.absoluteString)")
        }
        let pdfData = try await converter.convert(data: fodgData, sourceExtension: "fodg", targetExtension: "pdf")
        try pdfData.write(to: url)
    }
}
