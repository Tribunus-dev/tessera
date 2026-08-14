import Foundation

// MARK: - WriterBridgeFilter

/// Imports the Writer formats `TesseraFormatBridge` has no reader for
/// (ODT, RTF) by converting them to DOCX via `LibreOfficeConverter`
/// first, then handing the result to `TesseraFormatBridge`'s existing
/// `_import_docx` (python-docx). DOCX and HTML already have a direct
/// `TesseraFormatBridge` path and don't go through this type at all -
/// this only covers the gap.
///
/// Peer of `TesseraImporter` (studio-expansion-plan.md 0.8's own
/// framing) in the sense that both bring an external file into
/// Tessera's model; unlike `TesseraImporter` (which creates a full
/// graph entity end to end), this returns a `DocumentAST` - the same
/// contract `TesseraFormatBridge.importFile` already has, so
/// `DocStore.importFromFile`-style callers can use either
/// interchangeably based on format.
public actor WriterBridgeFilter {

    public enum FilterError: Error, LocalizedError, Sendable {
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "WriterBridgeFilter: unsupported format '\(format)' (supports odt, rtf)"
            }
        }
    }

    /// Formats this filter covers. `docx`/`html` are NOT here - they
    /// already import directly through `TesseraFormatBridge`.
    public static let supportedImportFormats: [String] = ["odt", "rtf"]

    private let converter: LibreOfficeConverter
    private let formatBridge: TesseraFormatBridge

    public init(converter: LibreOfficeConverter = LibreOfficeConverter(), formatBridge: TesseraFormatBridge = TesseraFormatBridge()) {
        self.converter = converter
        self.formatBridge = formatBridge
    }

    /// True when the underlying `soffice` conversion is available.
    /// Callers should check this before offering odt/rtf import in the
    /// UI, the same way `TesseraFormatBridge.supportedImportFormats`
    /// gates the formats it can actually handle.
    public nonisolated var isAvailable: Bool {
        converter.isAvailable
    }

    /// Import an ODT or RTF file's bytes as a `DocumentAST`.
    public func importDocument(data: Data, format: String) async throws -> DocumentAST {
        let normalized = format.lowercased()
        guard Self.supportedImportFormats.contains(normalized) else {
            throw FilterError.unsupportedFormat(format)
        }
        let docxData = try await converter.convert(data: data, sourceExtension: normalized, targetExtension: "docx")
        let astData = try await formatBridge.importFile(data: docxData, format: "docx")
        return try DocumentAST.from(jsonData: astData)
    }
}
