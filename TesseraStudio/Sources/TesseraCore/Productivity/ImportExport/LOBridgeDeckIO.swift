import Foundation

// MARK: - DeckExportFormat

/// Export targets ``LOBridgeDeckIO/exportDeck(_:to:format:)`` supports
/// (refinement doc section 1 Gate 1 / section 4 Slides cluster, item
/// 1.8). Deliberately has no `.handoutPDF` case: LibreOffice's PDF
/// export filter (`impress_pdf_Export`) has a slide layout and a
/// notes-page layout, but the handout layout (several slides per
/// printed page) is a print-subsystem feature with no export-filter
/// path in any LO architecture, in-process UNO or CLI alike - there is
/// no headless way to produce it. The absence of the case IS the
/// "not supported" answer (a compile-time guarantee, exhaustively
/// switched over in `LOBridgeDeckIOTests
/// .testDeckExportFormatHasNoHandoutPDFCase`), not a runtime check
/// this type would otherwise need to remember to perform.
public enum DeckExportFormat: String, CaseIterable, Sendable {
    case odp
    case pptx
    case pdf
}

// MARK: - LOBridgeDeckIO

/// Imports ODP/PPTX slide decks as ``SlideDeck``, exports ``SlideDeck``
/// back to ODP/PPTX, and exports to PDF (refinement doc section 1 Gate
/// 1 / section 4 Slides cluster, item 1.8). Peer of
/// `WriterBridgeFilter`/`CalcBridgeFilter`: the same "convert with
/// `LibreOfficeConverter`, map with Tessera's own reader/writer" shape,
/// generalized from their python-docx/CSV intermediates to the flat-ODF
/// tree `FlatODFReader`/`FlatODFWriter` (built earlier this same P1
/// wave) hand to and from a `SlideDeck`.
///
/// Import: foreign format -> `.fodp` (`LibreOfficeConverter`) -> a
/// `FlatODFElement` tree (`FlatODFReader`) -> `SlideDeck`
/// (``mapToSlideDeck(root:titleFallback:)``). Export is the exact
/// inverse (``mapToFlatODFTree(_:)`` -> `FlatODFWriter` -> `.fodp` ->
/// `LibreOfficeConverter` -> the target format). The two mapping
/// functions are `public static` and soffice-free specifically so
/// they can be unit-tested against hand-built `FlatODFElement` trees
/// without needing LibreOffice installed - `LOBridgeDeckIOTests`
/// exercises them directly; only the end-to-end round trip and the
/// PDF smoke test need `soffice`.
///
/// **Handout-layout PDF is out of scope, not implied by "PDF deck
/// export."** See ``DeckExportFormat``'s doc comment.
///
/// **PDF export cannot request notes pages through this codebase's
/// current converter API - a real, load-bearing gap, not an oversight
/// here.** The design contract asks for `.pdf` export to route through
/// `impress_pdf_Export`'s `ExportNotesPages` JSON filter option so
/// speaker notes are included. `LibreOfficeConverter.convert(data:
/// sourceExtension:targetExtension:)` (out of this deliverable's file
/// list) takes only a bare target extension and derives the produced
/// file's path by literally appending `.\(targetExtension)` to the
/// temp input's basename - so passing a compound `soffice
/// --convert-to` value like `"pdf:impress_pdf_Export:{...}"` as
/// `targetExtension` would make `soffice` write `input.pdf` while
/// `convert(...)` looks for a file literally named
/// `input.pdf:impress_pdf_Export:{...}`, throwing
/// `outputNotProduced`. There is no other parameter on that API for
/// filter options. `exportDeck(_:to:format:)`'s `.pdf` case therefore
/// uses the same bare `--convert-to pdf` every other export uses,
/// which applies LibreOffice's DEFAULT `impress_pdf_Export` options -
/// `ExportNotesPages` is off by default (matching the LO "Export as
/// PDF" dialog's own default), so the rendered PDF will NOT include
/// speaker notes even though the notes text is genuinely present in
/// the underlying `.fodp`'s `presentation:notes` elements (see
/// ``mapToFlatODFTree(_:)``). Flagged precisely, not guessed around -
/// see the P1 1.8 task report's openQuestions.
public actor LOBridgeDeckIO {

    public enum FilterError: Error, LocalizedError, Sendable {
        case unsupportedImportFormat(String)
        case notAPresentation(FlatODFContentType)
        case missingPresentationBody

        public var errorDescription: String? {
            switch self {
            case .unsupportedImportFormat(let format):
                return "LOBridgeDeckIO: unsupported import format '\(format)' (supports odp, pptx)"
            case .notAPresentation(let contentType):
                return "LOBridgeDeckIO: converted document is not a presentation (content type: \(contentType))"
            case .missingPresentationBody:
                return "LOBridgeDeckIO: flat-ODF document has no office:presentation body"
            }
        }
    }

    /// Formats this type imports. Export has no equivalent list -
    /// `DeckExportFormat`'s closed case set is the export vocabulary,
    /// enforced by the type system rather than a runtime check.
    public static let supportedImportFormats: [String] = ["odp", "pptx"]

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

    /// Import an ODP or PPTX file at `url` as a ``SlideDeck``.
    /// Embedded pictures are written to a per-call temp directory
    /// (never cleaned up here - a `.image` block's `source` needs to
    /// stay resolvable after this call returns) and referenced by
    /// `file://` URL; durable asset storage is the caller's job, same
    /// as `FlatODFReader.parse(data:binaryDataHandler:)`'s own doc
    /// comment describes.
    public func importDeck(from url: URL) async throws -> SlideDeck {
        let sourceFormat = url.pathExtension.lowercased()
        guard Self.supportedImportFormats.contains(sourceFormat) else {
            throw FilterError.unsupportedImportFormat(sourceFormat)
        }
        let sourceData = try Data(contentsOf: url)
        let fodpData = try await converter.convert(data: sourceData, sourceExtension: sourceFormat, targetExtension: "fodp")

        let mediaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-lo-deck-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let parsed = try await reader.parse(data: fodpData) { bytes in
            let fileURL = mediaDir.appendingPathComponent("\(UUID().uuidString).bin")
            try? bytes.write(to: fileURL)
            return fileURL
        }
        return try Self.mapToSlideDeck(root: parsed.root, titleFallback: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Export

    /// Export `deck` to `url` as `format`. See this type's doc comment
    /// for the `.pdf` case's notes-page limitation.
    public func exportDeck(_ deck: SlideDeck, to url: URL, format: DeckExportFormat) async throws {
        let root = Self.mapToFlatODFTree(deck)
        let fodpData = try await writer.write(root) { blobURL in
            try Data(contentsOf: blobURL)
        }
        let outputData = try await converter.convert(data: fodpData, sourceExtension: "fodp", targetExtension: format.rawValue)
        try outputData.write(to: url)
    }
}

// MARK: - LOBridgeDeckIO + Deck <-> FlatODF mapping

extension LOBridgeDeckIO {

    // MARK: fodp -> SlideDeck

    /// Maps a parsed flat-ODF tree (`FlatODFReader.Result.root`) to a
    /// ``SlideDeck``. Pure and `soffice`-free - the real conversion
    /// happens in `importDeck(from:)`; this is the "walk the
    /// `office:presentation`" half the design contract calls out, kept
    /// separately testable against hand-built fixtures.
    ///
    /// Mapping: each `draw:page` -> one slide, its root block shaped
    /// like `SlideDeck.insertingSlide`'s own per-``SlideLayout`` model
    /// (a title-only slide is a bare heading, an image-only slide is a
    /// bare image, a blank slide is a bare paragraph, anything richer
    /// is a `.toggle` grouping heading + body paragraphs + images) -
    /// `insertingSlide` is not called directly since this is importing
    /// arbitrary external content, not inserting a known blank layout.
    /// `presentation:class="title"` -> heading; any other/no class ->
    /// paragraph; a frame containing `draw:image` -> image regardless
    /// of class. `style:master-page` -> `SlideMasterPage` via
    /// `SlideDeck.settingMasterPage` (through the `masterPages`
    /// field it manages). `presentation:notes` -> `SlideMeta.notes`.
    public static func mapToSlideDeck(root: FlatODFElement, titleFallback: String = "Untitled") throws -> SlideDeck {
        let contentType = FlatODFContentType.resolve(root: root)
        guard contentType == .presentation else {
            throw FilterError.notAPresentation(contentType)
        }
        let bodyChildren = root.firstElementChild(named: "office:body")?.elementChildren ?? []
        guard let presentation = bodyChildren.first(where: { $0.name == "office:presentation" }) else {
            throw FilterError.missingPresentationBody
        }

        var deck = SlideDeck.makeEmpty(title: deckTitle(root: root) ?? titleFallback)
        let (masterPages, masterNameToID) = buildMasterPages(root: root)
        if !masterPages.isEmpty {
            deck.masterPages = masterPages
        }

        var blocks: [UUID: Block] = [:]
        var rootChildren: [UUID] = []
        var slideMeta: [String: SlideMeta] = [:]

        for page in presentation.elementChildren where page.name == "draw:page" {
            var title: String?
            var bodyParagraphs: [String] = []
            var images: [(source: String?, alt: String)] = []
            for frame in page.elementChildren where frame.name == "draw:frame" {
                switch classify(frame: frame) {
                case .title(let text):
                    if title == nil, !text.isEmpty { title = text }
                case .body(let paragraphs):
                    bodyParagraphs.append(contentsOf: paragraphs)
                case .image(let source, let alt):
                    images.append((source, alt))
                }
            }

            let (rootBlock, extraBlocks, layout) = buildSlideBlockTree(title: title, bodyParagraphs: bodyParagraphs, images: images)
            blocks[rootBlock.id] = rootBlock
            for (id, block) in extraBlocks { blocks[id] = block }
            rootChildren.append(rootBlock.id)

            let notesText = page.firstElementChild(named: "presentation:notes")
                .map { paragraphTexts(in: $0).joined(separator: "\n") } ?? ""
            let masterID = page.attributes["draw:master-page-name"].flatMap { masterNameToID[$0] }
            slideMeta[rootBlock.id.uuidString] = SlideMeta(layout: layout, notes: notesText, masterPageID: masterID)
        }

        deck.body = DocumentAST(blocks: blocks, rootChildren: rootChildren)
        deck.slideMeta = slideMeta
        return deck
    }

    /// Best-effort resolution of a `draw:page`'s SMIL transition
    /// attribute to a ``TransitionCatalog`` id, via
    /// ``TransitionSpec/ooxmlTag``, per the design contract ("map to
    /// TransitionSpec catalog ids where a reasonable OOXML-tag match
    /// exists ... if you cannot confidently map a given transition
    /// tag, leave the slide with no transition rather than guessing").
    /// Checks the page element itself first, then the `style:style`
    /// its `draw:style-name` references - a real ODF document can
    /// carry the transition on either.
    ///
    /// **Not called from ``mapToSlideDeck(root:titleFallback:)``
    /// today.** `SlideMeta` (`SlideDeck.swift`) has `layout`, `notes`,
    /// and `masterPageID` only - no field to hold a per-slide
    /// transition id. That is the exact gap `TransitionStore.swift`'s
    /// own doc comment already documents ("Known gap - assignment is
    /// not yet persisted"); `SlideDeck.swift` is outside this
    /// deliverable's file list (shared checkout, other agents on
    /// different files this same batch), so this resolver is exposed
    /// standalone - tested directly in `LOBridgeDeckIOTests` - for
    /// whichever patch adds `SlideMeta.transitionID` to call.
    public static func resolveTransitionCatalogID(forPage page: FlatODFElement, root: FlatODFElement) -> String? {
        if let tag = page.attributes["smil:transitionType"], let id = TransitionCatalog.id(forOOXMLTag: tag) {
            return id
        }
        guard let styleName = page.attributes["draw:style-name"] else { return nil }
        let containers = [
            root.firstElementChild(named: "office:automatic-styles"),
            root.firstElementChild(named: "office:styles"),
        ].compactMap { $0 }
        for container in containers {
            guard let style = container.elementChildren.first(where: {
                $0.name == "style:style" && $0.attributes["style:name"] == styleName
            }) else { continue }
            if let tag = style.attributes["smil:transitionType"], let id = TransitionCatalog.id(forOOXMLTag: tag) {
                return id
            }
        }
        return nil
    }

    /// `office:meta`'s `dc:title` (Dublin Core, the standard ODF
    /// document-title field) - the deck-level title, distinct from any
    /// slide's own heading text.
    private static func deckTitle(root: FlatODFElement) -> String? {
        guard let metaElement = root.firstElementChild(named: "office:meta"),
              let titleElement = metaElement.firstElementChild(named: "dc:title") else { return nil }
        let text = plainText(of: titleElement).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `style:master-page` entries -> ``SlideMasterPage``, keyed by a
    /// freshly generated `UUID` (ODF master pages are name-identified,
    /// `SlideMasterPage` is UUID-identified) - `nameToID` is the
    /// bridge `mapToSlideDeck` uses to resolve each `draw:page`'s
    /// `draw:master-page-name` back to that UUID. Background color is
    /// best-effort: only resolved when `draw:style-name` names a
    /// `style:style` (searched in `office:automatic-styles` then
    /// `office:styles`) carrying a `style:drawing-page-properties`
    /// child with `draw:fill-color` - real ODF documents vary in where
    /// they place this, and only the common shape is covered here.
    private static func buildMasterPages(root: FlatODFElement) -> (pages: [String: SlideMasterPage], nameToID: [String: UUID]) {
        guard let masterStyles = root.firstElementChild(named: "office:master-styles") else { return ([:], [:]) }
        var pages: [String: SlideMasterPage] = [:]
        var nameToID: [String: UUID] = [:]
        for entry in masterStyles.elementChildren where entry.name == "style:master-page" {
            guard let odfName = entry.attributes["style:name"] else { continue }
            let id = UUID()
            nameToID[odfName] = id
            let displayName = entry.attributes["style:display-name"] ?? odfName
            let background = resolveBackgroundColor(styleName: entry.attributes["draw:style-name"], root: root)
            pages[id.uuidString] = SlideMasterPage(
                id: id,
                name: displayName,
                backgroundColorHex: background.map { .literal($0) }
            )
        }
        return (pages, nameToID)
    }

    private static func resolveBackgroundColor(styleName: String?, root: FlatODFElement) -> String? {
        guard let styleName else { return nil }
        let containers = [
            root.firstElementChild(named: "office:automatic-styles"),
            root.firstElementChild(named: "office:styles"),
        ].compactMap { $0 }
        for container in containers {
            guard let style = container.elementChildren.first(where: {
                $0.name == "style:style" && $0.attributes["style:name"] == styleName
            }) else { continue }
            if let props = style.firstElementChild(named: "style:drawing-page-properties"),
               let fill = props.attributes["draw:fill-color"] {
                return fill
            }
        }
        return nil
    }

    /// Classifies one `draw:frame` as a title placeholder, body/other
    /// text content, or a picture. A frame containing `draw:image`
    /// wins regardless of `presentation:class` - a picture placeholder
    /// frame is still a picture. Otherwise `presentation:class ==
    /// "title"` is the title; everything else (subtitle/outline/body/
    /// no class at all) is body content, matching the design
    /// contract's "approximate mapping to existing BlockType cases".
    private static func classify(frame: FlatODFElement) -> ImportedFrameContent {
        if let imageElement = frame.firstElementChild(named: "draw:image") {
            let source = imageElement.firstElementChild(named: "office:binary-data")?
                .attributes[FlatODFElement.externalizedBinaryDataKey]
                ?? imageElement.attributes["xlink:href"]
            return .image(source: source, alt: frame.attributes["draw:name"] ?? "")
        }
        let texts = paragraphTexts(in: frame).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if frame.attributes["presentation:class"] == "title" {
            return .title(texts.first ?? "")
        }
        return .body(texts)
    }

    /// Every `text:p` found anywhere under `element` (not just direct
    /// children - a real frame usually wraps them in `draw:text-box`,
    /// but some ODF variants place `text:p` directly under
    /// `draw:frame`; walking recursively covers both without needing
    /// to special-case `draw:text-box`), each flattened to its plain
    /// text via ``plainText(of:)``.
    private static func paragraphTexts(in element: FlatODFElement) -> [String] {
        var out: [String] = []
        for child in element.elementChildren {
            if child.name == "text:p" {
                out.append(plainText(of: child))
            } else {
                out.append(contentsOf: paragraphTexts(in: child))
            }
        }
        return out
    }

    /// Concatenates every `.text` node under `element`, recursing
    /// through nested elements (`text:span` and friends) so mixed
    /// content collapses to its plain reading order.
    private static func plainText(of element: FlatODFElement) -> String {
        var out = ""
        for node in element.children {
            switch node {
            case .text(let text): out += text
            case .element(let child): out += plainText(of: child)
            }
        }
        return out
    }

    /// Builds one slide's root block (+ any extra child blocks) from
    /// its classified frame content, matching `SlideDeck
    /// .insertingSlide`'s own per-``SlideLayout`` shape exactly for
    /// the single-block layouts (`.title`/`.image`/`.blank`) and
    /// generalizing its `.titleAndContent` toggle shape to also carry
    /// images - `insertingSlide`'s own `.titleAndContent` case has no
    /// image slot, but a real imported content slide often has one.
    private static func buildSlideBlockTree(
        title: String?, bodyParagraphs: [String], images: [(source: String?, alt: String)]
    ) -> (root: Block, extra: [UUID: Block], layout: SlideLayout) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasTitle = !trimmedTitle.isEmpty

        if hasTitle, bodyParagraphs.isEmpty, images.isEmpty {
            let heading = Block(type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: trimmedTitle)])
            return (heading, [:], .title)
        }
        if !hasTitle, bodyParagraphs.isEmpty, images.count == 1 {
            let image = images[0]
            let block = Block(type: .image, attributes: [
                "source": .string(image.source ?? ""),
                "alt": .string(image.alt),
            ])
            return (block, [:], .image)
        }
        if !hasTitle, bodyParagraphs.isEmpty, images.isEmpty {
            return (Block(type: .paragraph, content: []), [:], .blank)
        }

        var children: [UUID] = []
        var extra: [UUID: Block] = [:]
        if hasTitle {
            let heading = Block(type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: trimmedTitle)])
            extra[heading.id] = heading
            children.append(heading.id)
        }
        if bodyParagraphs.isEmpty {
            let paragraph = Block(type: .paragraph, content: [])
            extra[paragraph.id] = paragraph
            children.append(paragraph.id)
        } else {
            for text in bodyParagraphs {
                let paragraph = Block(type: .paragraph, content: [InlineRun(text: text)])
                extra[paragraph.id] = paragraph
                children.append(paragraph.id)
            }
        }
        for image in images {
            let imageBlock = Block(type: .image, attributes: [
                "source": .string(image.source ?? ""),
                "alt": .string(image.alt),
            ])
            extra[imageBlock.id] = imageBlock
            children.append(imageBlock.id)
        }
        let toggle = Block(type: .toggle, attributes: ["expanded": .bool(true)], children: children)
        return (toggle, extra, .titleAndContent)
    }

    // MARK: SlideDeck -> fodp

    /// Builds a flat-ODF `office:document` tree from `deck` - the
    /// exact inverse of ``mapToSlideDeck(root:titleFallback:)``. Pure
    /// and `soffice`-free; `exportDeck(_:to:format:)` hands the result
    /// to `FlatODFWriter` and then `LibreOfficeConverter`.
    ///
    /// **Master-page asymmetry, by design, not a bug.** Every export
    /// unconditionally emits one `style:master-page` named `"Default"`
    /// (with no display name or color) so every slide's
    /// `draw:master-page-name` always resolves to something, even a
    /// deck with zero custom masters. Re-importing that document
    /// therefore always picks up one extra `SlideMasterPage` named
    /// `"Default"` that the original deck never had. Harmless (the
    /// round-trip test contract only checks title/slide-count) but
    /// worth knowing before asserting `masterPages` equality across a
    /// real `soffice` round trip.
    public static func mapToFlatODFTree(_ deck: SlideDeck) -> FlatODFElement {
        var masterPageElements: [FlatODFElement] = [
            FlatODFElement(name: "style:master-page", attributes: ["style:name": "Default"]),
        ]
        var automaticStyleElements: [FlatODFElement] = []
        var masterIDToName: [String: String] = [:]

        for (idString, master) in deck.effectiveMasterPages.sorted(by: { $0.key < $1.key }) {
            let odfName = "Master_" + idString.replacingOccurrences(of: "-", with: "")
            masterIDToName[idString] = odfName
            var masterAttributes: [String: String] = ["style:name": odfName, "style:display-name": master.name]
            if let colorRef = master.backgroundColorHex, case .literal(let hex) = colorRef {
                let styleName = odfName + "-style"
                masterAttributes["draw:style-name"] = styleName
                automaticStyleElements.append(FlatODFElement(
                    name: "style:style",
                    attributes: ["style:name": styleName, "style:family": "drawing-page"],
                    children: [.element(FlatODFElement(
                        name: "style:drawing-page-properties",
                        attributes: ["draw:fill": "solid", "draw:fill-color": hex]
                    ))]
                ))
            }
            masterPageElements.append(FlatODFElement(name: "style:master-page", attributes: masterAttributes))
        }

        var pageElements: [FlatODFElement] = []
        for (index, rootID) in deck.body.rootChildren.enumerated() {
            var title: String?
            var bodyParagraphs: [String] = []
            var images: [(source: String, alt: String)] = []
            collectSlideContent(blockID: rootID, ast: deck.body, title: &title, bodyParagraphs: &bodyParagraphs, images: &images)

            var frames: [FlatODFElement] = []
            if let title, !title.isEmpty {
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: ["presentation:class": "title"],
                    children: [.element(FlatODFElement(
                        name: "draw:text-box",
                        children: [.element(FlatODFElement(name: "text:p", children: [.text(title)]))]
                    ))]
                ))
            }
            if !bodyParagraphs.isEmpty {
                let paragraphNodes: [FlatODFNode] = bodyParagraphs.map {
                    .element(FlatODFElement(name: "text:p", children: [.text($0)]))
                }
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: ["presentation:class": "outline"],
                    children: [.element(FlatODFElement(name: "draw:text-box", children: paragraphNodes))]
                ))
            }
            for image in images where !image.source.isEmpty {
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: ["draw:name": image.alt],
                    children: [.element(FlatODFElement(
                        name: "draw:image",
                        children: [.element(FlatODFElement(
                            name: "office:binary-data",
                            attributes: [FlatODFElement.externalizedBinaryDataKey: image.source]
                        ))]
                    ))]
                ))
            }

            let meta = deck.slideMeta[rootID.uuidString] ?? .default
            let pageAttributes: [String: String] = [
                "draw:name": "Slide \(index + 1)",
                "draw:master-page-name": meta.masterPageID.flatMap { masterIDToName[$0.uuidString] } ?? "Default",
            ]

            var pageChildren: [FlatODFNode] = frames.map { .element($0) }
            if !meta.notes.isEmpty {
                let notesFrame = FlatODFElement(
                    name: "draw:frame",
                    attributes: ["presentation:class": "notes"],
                    children: [.element(FlatODFElement(
                        name: "draw:text-box",
                        children: [.element(FlatODFElement(name: "text:p", children: [.text(meta.notes)]))]
                    ))]
                )
                pageChildren.append(.element(FlatODFElement(name: "presentation:notes", children: [.element(notesFrame)])))
            }
            pageElements.append(FlatODFElement(name: "draw:page", attributes: pageAttributes, children: pageChildren))
        }

        let presentationElement = FlatODFElement(name: "office:presentation", children: pageElements.map { .element($0) })
        let bodyElement = FlatODFElement(name: "office:body", children: [.element(presentationElement)])
        let masterStylesElement = FlatODFElement(name: "office:master-styles", children: masterPageElements.map { .element($0) })

        var metaChildren: [FlatODFNode] = []
        let trimmedDeckTitle = deck.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDeckTitle.isEmpty {
            metaChildren.append(.element(FlatODFElement(name: "dc:title", children: [.text(trimmedDeckTitle)])))
        }
        let metaElement = FlatODFElement(name: "office:meta", children: metaChildren)

        var rootChildren: [FlatODFNode] = [.element(metaElement)]
        if !automaticStyleElements.isEmpty {
            rootChildren.append(.element(FlatODFElement(
                name: "office:automatic-styles",
                children: automaticStyleElements.map { .element($0) }
            )))
        }
        rootChildren.append(.element(masterStylesElement))
        rootChildren.append(.element(bodyElement))

        return FlatODFElement(
            name: "office:document",
            attributes: [
                "xmlns:office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
                "xmlns:style": "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
                "xmlns:text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
                "xmlns:draw": "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0",
                "xmlns:svg": "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0",
                "xmlns:presentation": "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0",
                "xmlns:dc": "http://purl.org/dc/elements/1.1/",
                "office:version": "1.3",
                "office:mimetype": "application/vnd.oasis.opendocument.presentation",
            ],
            children: rootChildren
        )
    }

    /// Walks a slide's root block subtree collecting its first heading
    /// as the title, every other block's inline text as a body
    /// paragraph, and every `.image` block's `source`/`alt` - the
    /// exact inverse of ``buildSlideBlockTree(title:bodyParagraphs:
    /// images:)``, generalized to any block shape (not just the ones
    /// that function itself produces) since a slide's content may have
    /// been hand-edited after import.
    private static func collectSlideContent(
        blockID: UUID, ast: DocumentAST,
        title: inout String?, bodyParagraphs: inout [String], images: inout [(source: String, alt: String)]
    ) {
        guard let block = ast.blocks[blockID] else { return }
        switch block.type {
        case .heading:
            let text = block.content.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if title == nil, !text.isEmpty { title = text }
        case .image:
            let source = block.attributes["source"]?.stringValue ?? ""
            let alt = block.attributes["alt"]?.stringValue ?? ""
            images.append((source: source, alt: alt))
        default:
            let text = block.content.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { bodyParagraphs.append(text) }
        }
        for child in block.children {
            collectSlideContent(blockID: child, ast: ast, title: &title, bodyParagraphs: &bodyParagraphs, images: &images)
        }
    }
}

// MARK: - ImportedFrameContent

/// One `draw:frame`'s classified content - see
/// `LOBridgeDeckIO.classify(frame:)`.
private enum ImportedFrameContent {
    case title(String)
    case body([String])
    case image(source: String?, alt: String)
}
