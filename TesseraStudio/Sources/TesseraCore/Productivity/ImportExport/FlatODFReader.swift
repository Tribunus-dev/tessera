import Foundation

// MARK: - FlatODF tree model

/// The four flat-ODF document kinds `LibreOfficeConverter` can
/// produce (fodt/fods/fodp/fodg), read from `office:document`'s
/// `office:mimetype` attribute. `.unknown` covers a root that is
/// missing or has an unrecognized mimetype - callers decide whether
/// that's fatal; the reader itself still returns the full tree.
public enum FlatODFContentType: String, Sendable, Equatable, CaseIterable {
    case text
    case spreadsheet
    case presentation
    case drawing
    case unknown

    static func resolve(root: FlatODFElement) -> FlatODFContentType {
        if let mimetype = root.attributes["office:mimetype"] {
            if mimetype.contains("spreadsheet") { return .spreadsheet }
            if mimetype.contains("presentation") { return .presentation }
            if mimetype.contains("graphics") { return .drawing }
            if mimetype.contains("text") { return .text }
        }
        // office:mimetype is required by the ODF spec on a standalone
        // flat document, but a tree assembled by hand (a future
        // AST -> fods writer, or a test) might omit it - office:body's
        // one content child names the type just as unambiguously.
        if let contentElement = root.firstElementChild(named: "office:body")?.elementChildren.first {
            switch contentElement.name {
            case "office:spreadsheet": return .spreadsheet
            case "office:presentation": return .presentation
            case "office:drawing": return .drawing
            case "office:text": return .text
            default: break
            }
        }
        return .unknown
    }
}

/// One node in a parsed flat-ODF tree: an element or a run of
/// character data. Both live in the same ordered array
/// (``FlatODFElement/children``) rather than text having its own
/// side channel, because ODF mixes them - `text:p` interleaves
/// literal text with inline elements like `text:span`, and losing
/// that interleaving order would corrupt the paragraph on
/// re-serialization.
public enum FlatODFNode: Sendable, Equatable {
    case element(FlatODFElement)
    case text(String)
}

/// One XML element, preserving its qualified name (e.g.
/// `"table:table-cell"`, `"draw:layer-set"`) and every attribute -
/// including `xmlns:*` declarations, which `XMLParser` hands over as
/// ordinary attributes when namespace processing is off - verbatim.
/// That's deliberate: a round trip needs the source document's own
/// namespace prefixes back exactly as declared, not a parser's
/// normalized view of them.
public struct FlatODFElement: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var children: [FlatODFNode]

    public init(name: String, attributes: [String: String] = [:], children: [FlatODFNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    /// The synthetic attribute key `FlatODFReader` writes on an
    /// `office:binary-data` element in place of its externalized
    /// base64 body: the value is the `URL` the caller's
    /// `binaryDataHandler` returned for the decoded bytes. Never a
    /// real ODF attribute and never written to the wire -
    /// `FlatODFWriter` reads the referenced bytes back and drops this
    /// key when it re-inlines them as base64.
    public static let externalizedBinaryDataKey = "tessera:externalized-href"

    /// This element's direct children that are themselves elements,
    /// in document order, skipping any interleaved `.text` nodes.
    public var elementChildren: [FlatODFElement] {
        children.compactMap {
            if case let .element(element) = $0 { return element }
            return nil
        }
    }

    /// The first direct child element with the given qualified name.
    public func firstElementChild(named name: String) -> FlatODFElement? {
        elementChildren.first { $0.name == name }
    }
}

// MARK: - FlatODFReader

/// Parses a flat-ODF document (`.fodt`/`.fods`/`.fodp`/`.fodg`) into
/// a ``FlatODFElement`` tree via `XMLParser`'s SAX-style callbacks,
/// never `XMLDocument` - a template `.fodp` is already 2.7MB
/// (`docs/.scratch/sota-bridge-report.md`), and `XMLDocument` would
/// hold a second, fully-materialized copy of that on top of the
/// input `Data`. The resulting tree is still an in-memory structure
/// (this item's contract is "parse and re-serialize faithfully", not
/// a zero-allocation parser); the one place that matters is
/// `office:binary-data`, whose base64 body can individually dwarf
/// the rest of the document in an image-heavy deck - the reader
/// diverts those bytes to the caller's own storage via
/// `binaryDataHandler` instead of ever holding them as a tree node.
///
/// Peer of ``LibreOfficeConverter``: the converter turns a real ODF
/// package or a foreign format into flat XML on disk; this type
/// turns that flat XML into the structure the AST-mapping layer
/// (1.8's `LOBridgeDeckIO`, 1.18's Draw I/O) builds on. This item
/// stops at the raw tree - mapping it to `SlideDeck`/`Drawing`/etc.
/// is that later work's job.
public actor FlatODFReader {

    public enum ReaderError: Error, LocalizedError, Sendable, Equatable {
        case malformedXML(line: Int, column: Int, description: String)
        case missingRootElement

        public var errorDescription: String? {
            switch self {
            case .malformedXML(let line, let column, let description):
                return "FlatODFReader: malformed XML at line \(line), column \(column): \(description)"
            case .missingRootElement:
                return "FlatODFReader: document produced no root element"
            }
        }
    }

    /// The parsed document: its content type and the full tree,
    /// rooted at `office:document`.
    public struct Result: Sendable, Equatable {
        public let contentType: FlatODFContentType
        public let root: FlatODFElement

        /// `office:body`'s direct element children -
        /// `office:text`/`office:spreadsheet`/`office:presentation`/
        /// `office:drawing` carrying the actual document content.
        /// Plural because `FlatODFElement` doesn't special-case
        /// body's schema-imposed single-content-child rule; every
        /// real document has exactly one.
        public var bodyChildren: [FlatODFElement] {
            root.firstElementChild(named: "office:body")?.elementChildren ?? []
        }

        public init(contentType: FlatODFContentType, root: FlatODFElement) {
            self.contentType = contentType
            self.root = root
        }
    }

    public init() {}

    /// Parse `data`. `binaryDataHandler` is called once per
    /// `office:binary-data` element with its decoded bytes - store
    /// them however this codebase's other importers already store
    /// binary attachments (see `TesseraImporter`'s `mediaDir`) and
    /// return the resulting `URL`; it's recorded on that element via
    /// ``FlatODFElement/externalizedBinaryDataKey`` in place of the
    /// base64 text. This type doesn't prescribe or build a storage
    /// mechanism of its own.
    public func parse(data: Data, binaryDataHandler: @escaping @Sendable (Data) -> URL) throws -> Result {
        let builder = FlatODFTreeBuilder(binaryDataHandler: binaryDataHandler)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse() else {
            throw ReaderError.malformedXML(
                line: parser.lineNumber,
                column: parser.columnNumber,
                description: parser.parserError?.localizedDescription ?? "unknown XML parser error"
            )
        }
        guard let root = builder.root else {
            throw ReaderError.missingRootElement
        }
        return Result(contentType: FlatODFContentType.resolve(root: root), root: root)
    }
}

// MARK: - Tree builder (XMLParserDelegate)

/// Builds the ``FlatODFElement`` tree from SAX callbacks via a stack
/// of open-element frames, one per currently-nested element - the
/// same shape `CardDAVXMLParser` uses for its multistatus tree,
/// generalized from "extract a few named fields" to "keep
/// everything, faithfully, for re-serialization".
final class FlatODFTreeBuilder: NSObject, XMLParserDelegate {

    private struct Frame {
        let name: String
        var attributes: [String: String]
        var children: [FlatODFNode] = []
        var pendingText: String = ""

        mutating func flushPendingText() {
            guard !pendingText.isEmpty else { return }
            children.append(.text(pendingText))
            pendingText = ""
        }
    }

    private let binaryDataHandler: @Sendable (Data) -> URL
    private var stack: [Frame] = []
    private(set) var root: FlatODFElement?

    init(binaryDataHandler: @escaping @Sendable (Data) -> URL) {
        self.binaryDataHandler = binaryDataHandler
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        // Flush the parent's accumulated text into a `.text` node
        // BEFORE opening this child, so mixed content (e.g.
        // `text:p`'s "Hello <text:span>World</text:span>!") keeps its
        // text/element interleaving order rather than coalescing all
        // the text to one end.
        if !stack.isEmpty {
            stack[stack.count - 1].flushPendingText()
        }
        stack.append(Frame(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].pendingText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].pendingText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard var finished = stack.popLast() else { return }

        if finished.name == "office:binary-data" {
            // Diverted to caller storage, never materialized as a
            // `.text` child - see FlatODFElement.externalizedBinaryDataKey.
            let base64 = finished.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            finished.pendingText = ""
            if !base64.isEmpty, let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                let url = binaryDataHandler(bytes)
                finished.attributes[FlatODFElement.externalizedBinaryDataKey] = url.absoluteString
            }
        } else {
            finished.flushPendingText()
        }

        let built = FlatODFElement(name: finished.name, attributes: finished.attributes, children: finished.children)
        if stack.isEmpty {
            root = built
        } else {
            stack[stack.count - 1].children.append(.element(built))
        }
    }
}
