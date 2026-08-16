import Foundation

//===----------------------------------------------------------------------===//
//  FormController.swift
//  Tessera Studio
//
//  Content-control resolution for Writer (P2-D item 2.15,
//  sota-enterprise-report.md's "2.15 Forms" design position). A
//  `ContentControl`'s persistent state lives on its host `Block` via
//  `Block/contentControl` (`Block.swift`); this file is where that
//  state gets RESOLVED - filled with a value, listed, or looked up
//  through a data binding.
//
//  Pure and stateless, matching FieldController/RevisionController/
//  TocController/TransformController/QueryEngine in this same wave
//  family (FieldController.swift's own file header states the doctrine
//  explicitly: "pure, stateless controller; DocStore integration is a
//  separate step" - followed here exactly): `fill` takes a `Block` and
//  a `DocumentAST` and returns a new `Block`, never touching `DocStore`.
//  A future `DocStore` integration (`fillForm(blockID:value:for:)` - see
//  this wave's wiringNotes) is the one place that both calls this and
//  appends the `doc_form_filled` receipt, only when the returned
//  `Block` actually differs from the one passed in - the exact
//  `FieldController.refresh`/`TocController.regenerate` "plain `!=`
//  check" boundary, which `fill`'s own no-op guards (see below) make
//  sufficient.
//
//  **The plainText/richText vs. everything-else split (the design
//  contract's own line, quoted verbatim in `ContentControl.swift`'s
//  header): "plainText/richText writes to block.content, checkBox/
//  dropDownList writes a value into the ContentControl's own state."**
//  Generalized here to all seven kinds via `resolvedValue(for:
//  hostBlock:)`, the single place both `fill` and `formData(in:)` read
//  the split from, so the two can never drift apart:
//    - `.plainText`/`.richText`: the control's ENTIRE reason for
//      existing is the host block's own text, so `fill` replaces
//      `hostBlock.content` outright (`FieldSpec`'s own "cached resolved
//      text lives in `content`" precedent, generalized). `.richText`
//      writes plain `InlineRun` text with no run-level formatting - this
//      codebase has no rich-text-from-a-plain-string parser at this
//      layer, and the design contract's own "Effort: M (L if full
//      native control chrome ... lands in the same wave)" line already
//      names richer authoring UI as scope this wave does not claim; a
//      future rich-text authoring surface can write directly into
//      `hostBlock.content` with real annotations without touching this
//      function's signature.
//    - `.comboBox`/`.dropDownList`/`.datePicker`/`.checkBox`/`.picture`:
//      the host block's `content` is UNTOUCHED - it may carry its own
//      surrounding label prose (e.g. "Subscribe to newsletter:" on a
//      `.listItem` hosting a checkbox) that filling the control's VALUE
//      must never overwrite. The resolved value lives in
//      `ContentControl.value` instead; a future renderer draws the
//      actual glyph/widget from it, the same "structured state,
//      renderer-derived chrome" split `Shape`/`ChartSpec`/`MediaBlock`
//      already use for THEIR always-leaf block types, generalized here
//      to a non-leaf host.
//
//  **Per-kind fill validation (judgment calls, recorded here and in
//  this wave's findings file, p2-d-findings-2.md - none of these are
//  named explicitly by the design contract's own numbered items):**
//    - `.dropDownList` requires `value` to be an exact (case-sensitive)
//      member of `control.listItems`; anything else is a no-op (`fill`
//      returns the block UNCHANGED) - the OOXML-documented distinction
//      from `.comboBox`, which accepts any string (free-entry) even
//      when `listItems` is non-empty.
//    - `.checkBox` requires `value == "true"` or `value == "false"`
//      (case-sensitive); anything else is a no-op. No tri-state
//      ("indeterminate") support - out of this wave's scope.
//    - `.datePicker`/`.picture` accept any string verbatim (no date
//      parsing/format validation, no path/URL well-formedness check) -
//      the design contract's own field list carries no format
//      constraint for either, and inventing one here would be scope
//      creep beyond "M effort".
//    - `ContentControl.locks.contentLocked == true` makes `fill` a
//      no-op for EVERY kind, not just text kinds - a locked control
//      cannot have its content OR its state value changed. This is
//      DIFFERENT from the document-level "protected fill-in-forms-only"
//      semantics the design contract's own "Open question" names (2.15's
//      recommended-yes answer, ratified studio-expansion-plan.md
//      section 8 row 16): that is a `Doc`-wide flag `DocStore`'s future
//      write methods would need to check (see this wave's wiringNotes -
//      genuinely out of THIS file's scope, since this file never sees a
//      `Doc`, only a `Block`/`DocumentAST`); `contentLocked` is the
//      PER-CONTROL `w:sdtPr/w:lock` flag, a real DOCX concept this file
//      DOES have enough context to honor directly.
//
//  **Data binding / XPath resolution.** `FormBindingResolver.resolve(_:in:)`
//  a control's `binding` XPath against every `customXml/*.xml` part in
//  a `PreservedParts` value (`DocumentProcessing/PreservedParts.swift`),
//  returning the first part that resolves the path successfully. A real
//  DOCX ties a specific `w:dataBinding` to one specific custom-XML part
//  via `w:storeItemID` (a GUID resolved through `customXml/itemPropsN.
//  xml`); `ContentControl` carries no `storeItemId` field (absent from
//  the design contract's own field list), so this file does not attempt
//  that indirection - when a document happens to carry MULTIPLE custom
//  XML parts that could each independently resolve the same XPath shape,
//  which one wins is UNSPECIFIED (dictionary iteration order). This is a
//  documented P2-D scope limit, not a bug: the design contract's own P3
//  punt trigger line calls binding resolution itself an "M effort, can
//  slip" item, and the `storeItemID` indirection is real added surface
//  beyond "simple element/attribute paths" - see `FormBindingResolver`'s
//  own doc comment for the exact supported XPath subset and why.
//===----------------------------------------------------------------------===//

// MARK: - FormController

/// Pure content-control resolution over `Block`/`DocumentAST` - peer of
/// `FieldController`: a plain namespace of static functions, no state,
/// no `DocStore` dependency. See the file header for the full design.
public enum FormController {

    /// Kinds whose resolved value lives in `ContentControl.value`
    /// rather than the host block's `content` - see the file header's
    /// "plainText/richText vs. everything-else split".
    private static let stateKinds: Set<ContentControlKind> = [
        .comboBox, .dropDownList, .datePicker, .checkBox, .picture,
    ]

    /// Fill `block`'s content control with `value`. A no-op (returns
    /// `block` unchanged) when: `block` carries no `ContentControl` (not
    /// a content-control host, or a host with none attached yet);
    /// `control.locks.contentLocked` is `true`; `value` fails the
    /// kind's own validation (`.dropDownList` membership,
    /// `.checkBox` "true"/"false"); or `value` is identical to what was
    /// already resolved (the idempotence guarantee mirroring
    /// `FieldController.refresh`'s own "no second receipt-worthy
    /// change" contract). See the file header for the exact per-kind
    /// rules.
    ///
    /// `ast` is threaded through for signature parity with
    /// `FieldController.refresh(_:in:clock:)` and to leave room for a
    /// future kind needing document context (a cross-reference-bound
    /// control, the way `.field`'s `.ref`/`.sequence` need `ast` today);
    /// no CURRENT kind reads it - every one of the seven resolves from
    /// `block`/`value` alone.
    public static func fill(_ block: Block, in ast: DocumentAST, value: String) -> Block {
        guard var control = block.contentControl else { return block }
        guard !control.locks.contentLocked else { return block }

        switch control.kind {
        case .plainText, .richText:
            guard resolvedValue(for: control, hostBlock: block) != value else { return block }
            var result = block
            result.content = [InlineRun(text: value)]
            return result

        case .dropDownList:
            guard control.listItems.contains(value) else { return block }
            guard control.value != value else { return block }
            control.value = value
            var result = block
            result.contentControl = control
            return result

        case .checkBox:
            guard value == "true" || value == "false" else { return block }
            guard control.value != value else { return block }
            control.value = value
            var result = block
            result.contentControl = control
            return result

        case .comboBox, .datePicker, .picture:
            guard control.value != value else { return block }
            control.value = value
            var result = block
            result.contentControl = control
            return result
        }
    }

    /// The control's current resolved value, reading from the right
    /// place per its kind - see the file header's split. `hostBlock` is
    /// optional so a caller holding a detached `ContentControl` (no
    /// block in hand) still resolves the state kinds; `.plainText`/
    /// `.richText` without a `hostBlock` resolve to `nil` (there is
    /// nowhere else their value could live).
    public static func resolvedValue(for control: ContentControl, hostBlock: Block?) -> String? {
        switch control.kind {
        case .plainText, .richText:
            guard let hostBlock, !hostBlock.content.isEmpty else { return nil }
            let text = hostBlock.content.map(\.text).joined()
            return text.isEmpty ? nil : text
        case .comboBox, .dropDownList, .datePicker, .checkBox, .picture:
            return control.value
        }
    }

    /// Every content control in `ast`, in document order
    /// (`DocumentAST.depthFirstOrder()` - the same collection order
    /// `TocController`'s own heading walk and `Doc.appendPlainText` use)
    /// - the listing `doc_form_fields_list` reports. A block hosting no
    /// control (including every ineligible `BlockType` - see
    /// `Block.contentControlEligibleTypes`) is skipped.
    public static func formFields(in ast: DocumentAST) -> [(blockID: UUID, control: ContentControl)] {
        var out: [(blockID: UUID, control: ContentControl)] = []
        for blockID in ast.depthFirstOrder() {
            guard let block = ast.blocks[blockID], let control = block.contentControl else { continue }
            out.append((blockID, control))
        }
        return out
    }

    /// Derived `tag -> resolved value` view across every content
    /// control in `ast` (the design contract's own "expose a derived
    /// FormData (tag -> value) view" line) - derived-never-stored
    /// (doctrine rule 3): recomputed from `formFields(in:)` +
    /// `resolvedValue(for:hostBlock:)` every call, nothing cached
    /// anywhere. A control with no resolved value yet (never filled) is
    /// absent from the result, not present with an empty string - so a
    /// caller can distinguish "not filled" from "filled with empty
    /// text" via simple key presence. A tag shared by more than one
    /// control (this type does not enforce tag uniqueness - see
    /// `ContentControl.tag`'s own doc comment) resolves to whichever
    /// one `formFields(in:)`'s document-order walk visits LAST.
    public static func formData(in ast: DocumentAST) -> [String: String] {
        var out: [String: String] = [:]
        for (blockID, control) in formFields(in: ast) {
            guard let value = resolvedValue(for: control, hostBlock: ast.blocks[blockID]) else { continue }
            out[control.tag] = value
        }
        return out
    }
}

// MARK: - FormBindingResolver

/// Resolves a content control's `binding` XPath against a preserved
/// custom-XML package part. See `FormController.swift`'s file header
/// for the "which part wins" scope limit.
///
/// **Supported XPath subset (deliberately not full XPath 1.0 - the
/// design contract's own words: "implement a MINIMAL XPath subset
/// sufficient for simple element/attribute paths ... full XPath 1.0 is
/// out of scope"):**
///   - Absolute paths only, starting with `"/"`. No relative paths, no
///     leading `"//"`.
///   - Every step is a bare element name matching `[A-Za-z_][\w.:-]*`
///     (a QName-shaped token, allowing `:` for a namespace prefix
///     exactly as it appears in the source XML - this resolver does
///     NOT do namespace-URI resolution, matching `FlatODFReader`'s own
///     `shouldProcessNamespaces = false` precedent for the same "keep
///     the source document's own prefixes" reason). No `"//"` between
///     steps, no wildcards (`"*"`), no axes (`"parent::"`,
///     `"following-sibling::"`, `".."`).
///   - At most ONE bracketed predicate per step, of the EXACT shape
///     `[@attrName='value']` or `[@attrName="value"]` - an
///     attribute-equality filter. No predicate functions
///     (`contains()`, `starts-with()`, `text()`), no `position()`, no
///     numeric predicates (`[1]`), no combined/multiple predicates.
///   - The FINAL step may instead be `@attrName` (selecting that
///     attribute's string value on the element reached by the prior
///     steps) rather than an element name - e.g. `"/root/field/@id"`.
///     An `"@..."` step anywhere but last is invalid.
///   - When the path resolves to an ELEMENT (no trailing `@attr`), the
///     result is that element's own text content, concatenated from any
///     text nodes DIRECTLY inside it (mixed content with nested
///     elements is not a case this resolver's target - a data-binding
///     source part is data, not markup-in-prose, unlike an ODF
///     `text:p`).
/// Anything outside this subset - a relative path, `"//"`, a predicate
/// function, more than one predicate, a malformed quote - returns `nil`
/// rather than guessing (the same "empty/nil is a legitimate
/// resolution, not an error" posture `FieldController` already takes
/// for data that legitimately is not there).
public enum FormBindingResolver {

    /// Resolve `control.binding` against every `customXml/*.xml` part in
    /// `preservedParts`. Returns `nil` when `control.binding` is `nil`,
    /// no custom-XML part parses, or none resolves the path - see this
    /// type's own header for the "which part wins when more than one
    /// resolves" scope limit.
    public static func resolve(_ control: ContentControl, in preservedParts: PreservedParts) -> String? {
        guard let xpath = control.binding else { return nil }
        for (path, data) in preservedParts.parts where path.hasPrefix("customXml/") && path.hasSuffix(".xml") {
            guard let root = CustomXMLParser.parse(data) else { continue }
            if let value = resolve(xpath, against: root) { return value }
        }
        return nil
    }

    /// Resolve `xpath` against an already-parsed tree. Exposed
    /// separately from ``resolve(_:in:)`` so a test can pin the parser
    /// and the path grammar independently (this wave's own hand-built
    /// fixtures use this entry point directly).
    static func resolve(_ xpath: String, against root: CustomXMLElement) -> String? {
        guard xpath.hasPrefix("/") else { return nil }
        let rawSteps = xpath.dropFirst().components(separatedBy: "/")
        guard !rawSteps.isEmpty, rawSteps.allSatisfy({ !$0.isEmpty }) else { return nil }
        var steps = rawSteps

        // The first step names the root element itself, not a child of it.
        guard let (rootName, rootPredicate) = parseStep(steps.removeFirst()), !rootName.hasPrefix("@") else { return nil }
        guard root.name == rootName, matchesPredicate(rootPredicate, on: root) else { return nil }

        var current = root
        for (index, rawStep) in steps.enumerated() {
            let isLast = index == steps.count - 1
            if rawStep.hasPrefix("@") {
                guard isLast else { return nil }
                let attrName = String(rawStep.dropFirst())
                guard !attrName.isEmpty else { return nil }
                return current.attributes[attrName]
            }
            guard let (name, predicate) = parseStep(rawStep) else { return nil }
            guard let match = current.children.first(where: { $0.name == name && matchesPredicate(predicate, on: $0) }) else { return nil }
            current = match
        }
        return current.text
    }

    /// Parses one path step into its element name plus an optional
    /// `[@attr='value']` predicate. `nil` for anything outside the
    /// documented subset.
    private static func parseStep(_ raw: String) -> (name: String, predicate: (attr: String, value: String)?)? {
        guard let bracketStart = raw.firstIndex(of: "[") else {
            return isValidName(raw) ? (raw, nil) : nil
        }
        guard raw.hasSuffix("]") else { return nil }
        let name = String(raw[raw.startIndex..<bracketStart])
        guard isValidName(name) else { return nil }

        let body = raw[raw.index(after: bracketStart)..<raw.index(before: raw.endIndex)]
        guard !body.contains("["), !body.contains("]"), body.hasPrefix("@") else { return nil }
        let afterAt = body.dropFirst()
        guard let eqIndex = afterAt.firstIndex(of: "=") else { return nil }
        let attrName = String(afterAt[afterAt.startIndex..<eqIndex])
        guard isValidName(attrName) else { return nil }

        var valuePart = afterAt[afterAt.index(after: eqIndex)...]
        guard let quote = valuePart.first, quote == "'" || quote == "\"" else { return nil }
        guard valuePart.count >= 2, valuePart.last == quote else { return nil }
        valuePart = valuePart.dropFirst().dropLast()
        guard !valuePart.contains(quote) else { return nil } // no escaped-quote support - minimal subset
        return (name, (attrName, String(valuePart)))
    }

    private static func matchesPredicate(_ predicate: (attr: String, value: String)?, on element: CustomXMLElement) -> Bool {
        guard let predicate else { return true }
        return element.attributes[predicate.attr] == predicate.value
    }

    /// A QName-shaped token: starts with a letter or underscore,
    /// continues with letters/digits/`_`/`-`/`.`/`:`.
    private static func isValidName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == ":" }
    }
}

// MARK: - CustomXMLElement / CustomXMLParser

/// One element in a parsed custom-XML data-binding part - element name,
/// attributes, direct element children, and the element's own
/// concatenated direct text (no mixed-content interleaving tracked,
/// unlike `FlatODFElement`: a data-binding source is data, not
/// markup-in-prose - see `FormBindingResolver`'s header).
struct CustomXMLElement {
    var name: String
    var attributes: [String: String]
    var children: [CustomXMLElement]
    var text: String
}

/// Parses a custom-XML package part into a ``CustomXMLElement`` tree via
/// `XMLParser`'s SAX-style callbacks - the same "never `XMLDocument`"
/// choice `FlatODFReader` documents (`ImportExport/FlatODFReader.swift`),
/// reused here for consistency even though a form's data-binding source
/// is typically small (unlike a multi-megabyte flat-ODF template).
enum CustomXMLParser {
    static func parse(_ data: Data) -> CustomXMLElement? {
        let builder = CustomXMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }
}

/// Builds the ``CustomXMLElement`` tree from SAX callbacks via a stack
/// of open-element frames - the same shape `FlatODFTreeBuilder` uses,
/// simplified: no binary-data diversion, no mixed-content ordering (see
/// `CustomXMLElement`'s own doc comment).
private final class CustomXMLTreeBuilder: NSObject, XMLParserDelegate {
    private struct Frame {
        let name: String
        var attributes: [String: String]
        var children: [CustomXMLElement] = []
        var text: String = ""
    }

    private var stack: [Frame] = []
    private(set) var root: CustomXMLElement?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(Frame(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        let built = CustomXMLElement(
            name: finished.name,
            attributes: finished.attributes,
            children: finished.children,
            text: finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if stack.isEmpty {
            root = built
        } else {
            stack[stack.count - 1].children.append(built)
        }
    }
}
