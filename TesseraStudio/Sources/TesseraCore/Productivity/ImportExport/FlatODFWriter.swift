import Foundation

// MARK: - FlatODFWriter

/// Serializes a ``FlatODFElement`` tree - the same intermediate
/// structure ``FlatODFReader`` produces via `Result.root` - back to
/// flat-ODF XML bytes. Recurses the tree emitting UTF-8 straight
/// into an accumulating `Data` buffer rather than building one
/// `String` for the whole document and encoding it once at the end:
/// the same memory concern that makes the reader stream
/// (`docs/.scratch/sota-bridge-report.md`: a 2.7MB fodp template,
/// image-heavy decks embed media as base64 in the XML itself)
/// applies symmetrically going back out, since `binaryDataResolver`
/// re-inlines each externalized blob as base64 text - only one
/// blob's base64 is ever materialized at a time, not the whole
/// document's.
///
/// Applies the two rules `sota-bridge-report.md` found empirically
/// (neither is optional - both cause LibreOffice to silently corrupt
/// or drop content on the way back in, regardless of where in the
/// input tree they were found):
///  1. A document containing any `table:formula` attribute must
///     declare `xmlns:of` on its root element, or LO reads the
///     formula prefix as literal text and doubles it on next save
///     (`of:=of:=SUM(...)`).
///  2. `draw:layer-set` must be a child of `office:master-styles`,
///     not `office:body` - misplaced, LO silently drops custom
///     layers and reassigns their shapes to the "layout" layer.
public actor FlatODFWriter {

    public enum WriterError: Error, LocalizedError, Sendable, Equatable {
        case binaryDataUnavailable(url: URL, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .binaryDataUnavailable(let url, let underlying):
                return "FlatODFWriter: could not resolve externalized binary data at \(url.absoluteString): \(underlying)"
            }
        }
    }

    private static let ofNamespaceURI = "urn:oasis:names:tc:opendocument:xmlns:of:1.2"

    public init() {}

    /// Serialize `root` to flat-ODF XML. `binaryDataResolver` is the
    /// inverse of ``FlatODFReader``'s `binaryDataHandler`: given the
    /// `URL` recorded on an `office:binary-data` element via
    /// ``FlatODFElement/externalizedBinaryDataKey``, return its
    /// bytes so they can be re-inlined as base64. An element without
    /// that key (a tree built by hand with the base64 already
    /// present as a `.text` child) writes straight through without
    /// calling the resolver.
    public func write(_ root: FlatODFElement, binaryDataResolver: @escaping @Sendable (URL) throws -> Data) throws -> Data {
        let normalized = Self.normalizeLayerSetPlacement(Self.normalizeFormulaNamespace(root))
        var buffer = Data()
        buffer.append(contentsOf: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8)
        try Self.writeElement(normalized, into: &buffer, binaryDataResolver: binaryDataResolver)
        return buffer
    }

    // MARK: - Element serialization

    private static func writeElement(
        _ element: FlatODFElement,
        into buffer: inout Data,
        binaryDataResolver: @Sendable (URL) throws -> Data
    ) throws {
        if element.name == "office:binary-data",
           let href = element.attributes[FlatODFElement.externalizedBinaryDataKey],
           let url = URL(string: href) {
            buffer.append(contentsOf: openTag(element, excluding: [FlatODFElement.externalizedBinaryDataKey], selfClose: false).utf8)
            do {
                let bytes = try binaryDataResolver(url)
                buffer.append(contentsOf: bytes.base64EncodedString().utf8)
            } catch {
                throw WriterError.binaryDataUnavailable(url: url, underlying: String(describing: error))
            }
            buffer.append(contentsOf: "</\(element.name)>".utf8)
            return
        }

        guard !element.children.isEmpty else {
            buffer.append(contentsOf: openTag(element, excluding: [], selfClose: true).utf8)
            return
        }

        buffer.append(contentsOf: openTag(element, excluding: [], selfClose: false).utf8)
        for child in element.children {
            switch child {
            case .element(let childElement):
                try writeElement(childElement, into: &buffer, binaryDataResolver: binaryDataResolver)
            case .text(let text):
                buffer.append(contentsOf: escapeText(text).utf8)
            }
        }
        buffer.append(contentsOf: "</\(element.name)>".utf8)
    }

    private static func openTag(_ element: FlatODFElement, excluding: Set<String>, selfClose: Bool) -> String {
        let attributeString = element.attributes
            .filter { !excluding.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(escapeAttribute($0.value))\"" }
            .joined()
        return "<\(element.name)\(attributeString)\(selfClose ? "/>" : ">")"
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Empirically-learned rule 1: xmlns:of on formula documents

    private static func normalizeFormulaNamespace(_ root: FlatODFElement) -> FlatODFElement {
        guard root.attributes["xmlns:of"] == nil, containsFormula(root) else { return root }
        var patched = root
        patched.attributes["xmlns:of"] = ofNamespaceURI
        return patched
    }

    private static func containsFormula(_ element: FlatODFElement) -> Bool {
        if element.attributes["table:formula"] != nil { return true }
        return element.elementChildren.contains { containsFormula($0) }
    }

    // MARK: - Empirically-learned rule 2: draw:layer-set under office:master-styles

    private static func normalizeLayerSetPlacement(_ root: FlatODFElement) -> FlatODFElement {
        guard let masterStyles = root.firstElementChild(named: "office:master-styles") else {
            // No master-styles container at all - a stray layer-set
            // elsewhere has no legal home to move it to; out of scope
            // to synthesize a whole container for a case that
            // shouldn't arise from a real fodg tree.
            return root
        }
        if masterStyles.firstElementChild(named: "draw:layer-set") != nil {
            return root
        }
        var extracted: FlatODFElement?
        let stripped = removingLayerSet(from: root, found: &extracted)
        guard let layerSet = extracted else { return root }
        return insertingLayerSet(layerSet, intoMasterStylesOf: stripped)
    }

    private static func removingLayerSet(from element: FlatODFElement, found: inout FlatODFElement?) -> FlatODFElement {
        var element = element
        var newChildren: [FlatODFNode] = []
        newChildren.reserveCapacity(element.children.count)
        for child in element.children {
            switch child {
            case .element(let childElement):
                if found == nil && childElement.name == "draw:layer-set" {
                    found = childElement
                    continue
                }
                newChildren.append(.element(removingLayerSet(from: childElement, found: &found)))
            case .text:
                newChildren.append(child)
            }
        }
        element.children = newChildren
        return element
    }

    private static func insertingLayerSet(_ layerSet: FlatODFElement, intoMasterStylesOf root: FlatODFElement) -> FlatODFElement {
        var root = root
        root.children = root.children.map { node in
            guard case .element(var masterStyles) = node, masterStyles.name == "office:master-styles" else {
                return node
            }
            masterStyles.children.insert(.element(layerSet), at: 0)
            return .element(masterStyles)
        }
        return root
    }
}
