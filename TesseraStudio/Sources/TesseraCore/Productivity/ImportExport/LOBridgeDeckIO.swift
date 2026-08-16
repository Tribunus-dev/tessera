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
/// **PDF export includes speaker notes.** `exportDeck(_:to:format:)`'s
/// `.pdf` case passes `impress_pdf_Export:{"ExportNotesPages":true}` as
/// `LibreOfficeConverter.convert(...)`'s `filterOptions` argument - that
/// parameter carries the filter suffix on the `--convert-to` value
/// soffice receives while `targetExtension` itself (used for the
/// produced file's path derivation) stays the bare `"pdf"`. Notes text
/// reaches the `.fodp` via `presentation:notes` elements (see
/// ``mapToFlatODFTree(_:)``); this is what makes it show up in the
/// rendered PDF too.
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

    /// Export `deck` to `url` as `format`. The `.pdf` case passes
    /// `impress_pdf_Export`'s `ExportNotesPages` filter option through
    /// `LibreOfficeConverter.convert(...)`'s `filterOptions` parameter
    /// so speaker notes are included in the rendered PDF (see this
    /// type's doc comment). `accessibility` (item 2.20's filter-options
    /// plumbing) extends that SAME `impress_pdf_Export:{...}` filter-data
    /// object with `UseTaggedPDF`/`PDFUACompliance` rather than building
    /// a second filter-options mechanism - see `PDFFilterOptions.build`
    /// and `PDFAccessibilityOptions`'s own doc comment for what the flag
    /// currently does and does not achieve on this LO install.
    public func exportDeck(
        _ deck: SlideDeck, to url: URL, format: DeckExportFormat, accessibility: PDFAccessibilityOptions = .off
    ) async throws {
        let root = Self.mapToFlatODFTree(deck)
        let fodpData = try await writer.write(root) { blobURL in
            try Data(contentsOf: blobURL)
        }
        var filterOptions: String?
        if format == .pdf {
            var fragments = ["\"ExportNotesPages\":true"]
            fragments.append(contentsOf: accessibility.filterDataFragments)
            filterOptions = PDFFilterOptions.build(filterName: "impress_pdf_Export", fragments: fragments)
        }
        let outputData = try await converter.convert(
            data: fodpData, sourceExtension: "fodp", targetExtension: format.rawValue, filterOptions: filterOptions
        )
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
    /// field it manages). `presentation:notes` -> `SlideMeta.notes`. A
    /// page's SMIL transition (or its referenced style's) ->
    /// `SlideMeta.transitionID` via ``resolveTransitionCatalogID(forPage:
    /// root:)`` - `nil` when nothing confidently maps, never a guess.
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
        var pageNameToID: [String: UUID] = [:]

        for (pageIndex, page) in presentation.elementChildren.filter({ $0.name == "draw:page" }).enumerated() {
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
            pageNameToID[page.attributes["draw:name"] ?? slideName(atIndex: pageIndex)] = rootBlock.id

            let notesText = page.firstElementChild(named: "presentation:notes")
                .map { paragraphTexts(in: $0).joined(separator: "\n") } ?? ""
            let masterID = page.attributes["draw:master-page-name"].flatMap { masterNameToID[$0] }
            let transitionID = resolveTransitionCatalogID(forPage: page, root: root)

            // SMIL animation tree (P2 item 2.1): resolved against a
            // throwaway single-slide AST built from THIS page's own
            // rootBlock/extraBlocks (the full deck-wide `blocks` map
            // isn't assembled until after this loop, but an
            // animation's targets never reach outside their own
            // slide, so this subtree is sufficient context).
            var slideBlocks = extraBlocks
            slideBlocks[rootBlock.id] = rootBlock
            let slideAST = DocumentAST(blocks: slideBlocks, rootChildren: [rootBlock.id])
            let frameIDToBlockID = frameIDsByPosition(rootID: rootBlock.id, ast: slideAST)
            let animationTree = mapAnimationTree(fromPage: page) { frameIDString in
                frameIDToBlockID[frameIDString].map { AnimationTarget(blockID: $0) }
            }

            slideMeta[rootBlock.id.uuidString] = SlideMeta(
                layout: layout, notes: notesText, masterPageID: masterID, transitionID: transitionID,
                animations: animationTree?.flattened(), animationTree: animationTree
            )
        }

        deck.body = DocumentAST(blocks: blocks, rootChildren: rootChildren)
        deck.slideMeta = slideMeta
        let shows = mapCustomShows(fromSettings: presentation.firstElementChild(named: "presentation:settings"), nameToID: pageNameToID)
        if !shows.isEmpty { deck.customShows = shows }
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
    /// Called from ``mapToSlideDeck(root:titleFallback:)`` for every
    /// `draw:page`, landing the result on that slide's
    /// `SlideMeta.transitionID`. Exposed `public static` (not folded
    /// directly into the walk) since it stays independently useful and
    /// is tested standalone in `LOBridgeDeckIOTests` against
    /// hand-built fixtures with no full deck needed.
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

            let meta = deck.slideMeta[rootID.uuidString] ?? .default
            // Only tag frames with animation-target ids when this
            // slide actually carries a SMIL tree (P2 item 2.1) - an
            // animation-free slide's fodp output stays exactly what
            // it was before this item landed.
            let animationTree = meta.effectiveAnimationTree
            func frameID(_ position: AnimationFramePosition) -> String? {
                animationTree == nil ? nil : animationFrameID(forRootSlideID: rootID, position: position)
            }

            var frames: [FlatODFElement] = []
            if let title, !title.isEmpty {
                var titleAttributes = ["presentation:class": "title"]
                if let id = frameID(.title) { titleAttributes["xml:id"] = id }
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: titleAttributes,
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
                var bodyAttributes = ["presentation:class": "outline"]
                if let id = frameID(.body) { bodyAttributes["xml:id"] = id }
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: bodyAttributes,
                    children: [.element(FlatODFElement(name: "draw:text-box", children: paragraphNodes))]
                ))
            }
            var imageIndex = 0
            for image in images where !image.source.isEmpty {
                var imageAttributes = ["draw:name": image.alt]
                if let id = frameID(.image(imageIndex)) { imageAttributes["xml:id"] = id }
                imageIndex += 1
                frames.append(FlatODFElement(
                    name: "draw:frame",
                    attributes: imageAttributes,
                    children: [.element(FlatODFElement(
                        name: "draw:image",
                        children: [.element(FlatODFElement(
                            name: "office:binary-data",
                            attributes: [FlatODFElement.externalizedBinaryDataKey: image.source]
                        ))]
                    ))]
                ))
            }

            var pageAttributes: [String: String] = [
                "draw:name": slideName(atIndex: index),
                "draw:master-page-name": meta.masterPageID.flatMap { masterIDToName[$0.uuidString] } ?? "Default",
            ]
            if let id = frameID(.wholeSlide) { pageAttributes["xml:id"] = id }

            var pageChildren: [FlatODFNode] = frames.map { .element($0) }
            if let animationTree {
                let classification = classifyAnimationTargets(rootID: rootID, ast: deck.body)
                let frameIDs = classification.mapValues { animationFrameID(forRootSlideID: rootID, position: $0) }
                pageChildren.append(.element(mapAnimationTree(animationTree, frameIDs: frameIDs)))
            }
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
        if let settingsElement = mapCustomShows(deck.effectiveCustomShows, deck: deck) {
            pageElements.append(settingsElement)
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

// MARK: - LOBridgeDeckIO + Custom shows <-> fodp (P2 item 2.10)

extension LOBridgeDeckIO {

    /// The `draw:page@draw:name` value `mapToFlatODFTree` writes for
    /// the page at `index` (0-based): `"Slide \(index + 1)"`. This is
    /// this bridge's ONE existing slide-identity mechanism - custom
    /// shows (below) reuse it rather than inventing a second one, per
    /// the design contract's own instruction.
    static func slideName(atIndex index: Int) -> String {
        "Slide \(index + 1)"
    }

    /// Builds `presentation:settings > presentation:show*` for
    /// `shows`, `presentation:pages` a comma list of slide NAMES via
    /// ``slideName(atIndex:)`` - the exact inverse of
    /// ``mapCustomShows(fromSettings:nameToID:)``. Returns `nil` for
    /// an empty show list so a deck with none gets no
    /// `presentation:settings` element at all (matching this file's
    /// existing style of omitting empty/default sections - see
    /// `automaticStyleElements` in ``mapToFlatODFTree(_:)``). A show
    /// whose `slideIDs` entry no longer names a live slide is already
    /// absent from `deck.effectiveCustomShows` before this function
    /// ever sees it - see that property's own doc comment.
    static func mapCustomShows(_ shows: [CustomShow], deck: SlideDeck) -> FlatODFElement? {
        guard !shows.isEmpty else { return nil }
        var nameByID: [UUID: String] = [:]
        for (index, rootID) in deck.body.rootChildren.enumerated() {
            nameByID[rootID] = slideName(atIndex: index)
        }
        let showElements: [FlatODFElement] = shows.map { show in
            let pages = show.slideIDs.compactMap { nameByID[$0] }.joined(separator: ",")
            return FlatODFElement(
                name: "presentation:show",
                attributes: ["presentation:name": show.name, "presentation:pages": pages]
            )
        }
        return FlatODFElement(name: "presentation:settings", children: showElements.map { .element($0) })
    }

    /// The inverse: `presentation:settings > presentation:show*` ->
    /// `[CustomShow]`, resolving each `presentation:pages` NAME back
    /// to a slide id via `nameToID` (the caller's own `draw:page@
    /// draw:name -> rootBlock.id` table, built the same walk that
    /// resolves every other page-identified reference in
    /// ``mapToSlideDeck(root:titleFallback:)``). A name with no
    /// matching slide is skipped, not synthesized as a dangling id -
    /// a name this deck never had is a different situation from "the
    /// slide existed and was later deleted", which
    /// `SlideDeck.effectiveCustomShows` is the one place that handles.
    static func mapCustomShows(fromSettings settings: FlatODFElement?, nameToID: [String: UUID]) -> [CustomShow] {
        guard let settings else { return [] }
        return settings.elementChildren
            .filter { $0.name == "presentation:show" }
            .map { element in
                let name = element.attributes["presentation:name"] ?? ""
                let pageNames = (element.attributes["presentation:pages"] ?? "")
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let slideIDs = pageNames.compactMap { nameToID[$0] }
                return CustomShow(name: name, slideIDs: slideIDs)
            }
    }
}

// MARK: - LOBridgeDeckIO + SMIL animation tree <-> fodp (P2 item 2.1)
//
// Greenfield: no prior wave parsed or emitted `p:timing`/`anim:*`.
// This bridge routes exclusively through fods (decision 12 - the
// xlsx/pptx/docx parts are never touched directly), so only the ODF
// `anim:*`/`presentation:node-type` vocabulary is implemented; OOXML
// `p:timing`'s own element names are the `LibreOfficeConverter`
// CLI step's concern, same as every other surface this bridge
// touches.
//
// **`smil:begin` encoding is this bridge's own, not verified against
// a live soffice round trip** (unlike e.g. ``resolveTransitionCatalogID
// (forPage:root:)``, which explicitly documents when it does and does
// not trust a real ODF value). It is informed by real SMIL/ODF begin
// syntax (`"indefinite"`, `"<id>.click"`, offset suffixes) but chooses
// its own unambiguous encoding for the 5 ``SMILCondition`` cases so
// this bridge's own reader is guaranteed to invert its own writer;
// this is exactly the kind of thing testing-doctrine.md rule 10 calls
// an empirical probe waiting to happen, recorded as such in this
// wave's findings file rather than silently assumed byte-correct
// against real LibreOffice output.
extension LOBridgeDeckIO {

    // MARK: Animation target <-> frame id resolution
    //
    // This bridge's existing per-slide content export
    // (`collectSlideContent`/the frame-building loop in
    // `mapToFlatODFTree`) aggregates ALL body paragraphs into ONE
    // `draw:frame`, discarding individual paragraph-block identity -
    // a pre-existing limitation of that path, not introduced here.
    // Animation targeting through this bridge is therefore addressed
    // at 4 granularities per slide, matching that existing structure
    // exactly: the whole slide, its title (if any), its aggregated
    // body content (if any - ALL paragraph blocks resolve to this ONE
    // shared target), and its Nth image (0-based, in document order).
    // A genuinely per-paragraph animation target (e.g. an `iterate`
    // "build by paragraph" driving distinct paragraphs) is only
    // addressable at "the whole body" granularity through fodp I/O
    // until the general content-export path itself carries per-block
    // ids - recorded as a P2 design-judgment call in this wave's
    // findings file, not silently narrowed.

    enum AnimationFramePosition: Hashable {
        case wholeSlide
        case title
        case body
        case image(Int)
    }

    /// The `xml:id` this bridge writes on (and reads back from) the
    /// frame/page representing `position` for the slide whose root
    /// block is `rootID`. Deterministic from `rootID` + `position`
    /// alone - export tags frames with this directly; import resolves
    /// `smil:targetElement` values against it via
    /// ``frameIDsByPosition(rootID:ast:)``.
    static func animationFrameID(forRootSlideID rootID: UUID, position: AnimationFramePosition) -> String {
        switch position {
        case .wholeSlide: return "tessera-anim-\(rootID.uuidString)"
        case .title: return "tessera-anim-\(rootID.uuidString)-title"
        case .body: return "tessera-anim-\(rootID.uuidString)-body"
        case .image(let n): return "tessera-anim-\(rootID.uuidString)-image-\(n)"
        }
    }

    /// Every block in the slide's subtree (`rootID`, walked via
    /// `ast`), classified to the ``AnimationFramePosition`` its
    /// content would export under. Used on EXPORT: a behavior's
    /// `AnimationTarget.blockID` looks itself up here (via
    /// `animationFrameID(forRootSlideID:position:)`) to find the
    /// `xml:id` to write as `smil:targetElement`.
    static func classifyAnimationTargets(rootID: UUID, ast: DocumentAST) -> [UUID: AnimationFramePosition] {
        var out: [UUID: AnimationFramePosition] = [rootID: .wholeSlide]
        var sawTitle = false
        var imageIndex = 0
        func walk(_ blockID: UUID) {
            guard let block = ast.blocks[blockID] else { return }
            switch block.type {
            case .heading where !sawTitle:
                out[blockID] = .title
                sawTitle = true
            case .image:
                out[blockID] = .image(imageIndex)
                imageIndex += 1
            default:
                if blockID != rootID, out[blockID] == nil { out[blockID] = .body }
            }
            for child in block.children { walk(child) }
        }
        walk(rootID)
        return out
    }

    /// The inverse direction's lookup table: every `xml:id` string
    /// this slide's subtree WOULD export under, mapped to the first
    /// block (in document order) that resolves to it - used on
    /// IMPORT as the `targetResolver` basis for
    /// ``mapAnimationTree(fromPage:targetResolver:)``. "First wins"
    /// for the shared `.body` id (see this extension's header) is a
    /// deliberate, deterministic choice, not an arbitrary Dictionary
    /// ordering artifact - it comes from the SAME ordered `walk` this
    /// type's export-direction classifier uses.
    static func frameIDsByPosition(rootID: UUID, ast: DocumentAST) -> [String: UUID] {
        var out: [String: UUID] = [:]
        func record(_ position: AnimationFramePosition, _ blockID: UUID) {
            let key = animationFrameID(forRootSlideID: rootID, position: position)
            if out[key] == nil { out[key] = blockID }
        }
        var sawTitle = false
        var imageIndex = 0
        func walk(_ blockID: UUID) {
            guard let block = ast.blocks[blockID] else { return }
            switch block.type {
            case .heading where !sawTitle:
                record(.title, blockID)
                sawTitle = true
            case .image:
                record(.image(imageIndex), blockID)
                imageIndex += 1
            default:
                if blockID != rootID { record(.body, blockID) }
            }
            for child in block.children { walk(child) }
        }
        record(.wholeSlide, rootID)
        walk(rootID)
        return out
    }

    // MARK: SMILAnimationTree -> fodp

    private static let containerNodeTypeToODF: [SMILNodeType: String] = [
        .tmRoot: "timing-root",
        .mainSeq: "main-sequence",
        .interactiveSeq: "interactive-sequence",
        .clickPar: "on-click",
        .withGroup: "with-previous",
        .afterGroup: "after-previous",
    ]
    private static let odfToContainerNodeType: [String: SMILNodeType] =
        Dictionary(uniqueKeysWithValues: containerNodeTypeToODF.map { ($0.value, $0.key) })

    private static let iterateTypeToODF: [IterateSpec.IterateType: String] = [
        .byParagraph: "by-paragraph",
        .byWord: "by-word",
        .byLetter: "by-letter",
    ]
    private static let odfToIterateType: [String: IterateSpec.IterateType] =
        Dictionary(uniqueKeysWithValues: iterateTypeToODF.map { ($0.value, $0.key) })

    /// Builds the `<anim:par>` (or, for a tree whose root was parsed
    /// from `anim:excl`, `<anim:excl>` - see
    /// `SMILTimingProps.exclMarkerPresetClass`) element for `tree`,
    /// suitable as a `draw:page` child. `frameIDs` resolves each
    /// behavior's `AnimationTarget.blockID` to the `xml:id` its frame
    /// was tagged with (``classifyAnimationTargets(rootID:ast:)``'s
    /// output, re-keyed through ``animationFrameID(forRootSlideID:
    /// position:)`` by the caller) - a target with no entry is
    /// dropped from the export (honest "cannot address it" rather
    /// than a dangling `smil:targetElement`).
    static func mapAnimationTree(_ tree: SMILAnimationTree, frameIDs: [UUID: String]) -> FlatODFElement {
        mapSMILNode(tree.root, frameIDs: frameIDs)
    }

    private static func mapSMILNode(_ node: SMILNode, frameIDs: [UUID: String]) -> FlatODFElement {
        switch node {
        case let .par(props, children):
            var attrs = timingAttributes(props, frameIDs: frameIDs)
            let elementName: String
            if props.presetClass == SMILTimingProps.exclMarkerPresetClass {
                attrs.removeValue(forKey: "presentation:preset-class")
                elementName = "anim:excl"
            } else {
                elementName = "anim:par"
            }
            return FlatODFElement(
                name: elementName, attributes: attrs,
                children: children.map { .element(mapSMILNode($0, frameIDs: frameIDs)) })
        case let .seq(props, children):
            let attrs = timingAttributes(props, frameIDs: frameIDs)
            return FlatODFElement(
                name: "anim:seq", attributes: attrs,
                children: children.map { .element(mapSMILNode($0, frameIDs: frameIDs)) })
        case let .iterate(props, spec, children):
            var attrs = timingAttributes(props, frameIDs: frameIDs)
            attrs["anim:iterate-type"] = iterateTypeToODF[spec.type]
            attrs["anim:iterate-interval"] = secondsString(fromMS: spec.intervalMS)
            return FlatODFElement(
                name: "anim:iterate", attributes: attrs,
                children: children.map { .element(mapSMILNode($0, frameIDs: frameIDs)) })
        case let .behavior(props, target, behavior):
            return mapBehavior(props: props, target: target, behavior: behavior, frameIDs: frameIDs)
        }
    }

    private static func mapBehavior(
        props: SMILTimingProps, target: AnimationTarget, behavior: SMILBehavior, frameIDs: [UUID: String]
    ) -> FlatODFElement {
        var attrs = timingAttributes(props, frameIDs: frameIDs)
        if let targetID = frameIDs[target.blockID] {
            attrs["smil:targetElement"] = targetID
        }
        if let paragraphIndex = target.paragraphIndex {
            attrs["tessera:targetParagraphIndex"] = String(paragraphIndex)
        }
        switch behavior {
        case let .animate(attributeName, values, from, to, by):
            attrs["smil:attributeName"] = attributeName
            if !values.isEmpty { attrs["smil:values"] = values.joined(separator: ";") }
            if let from { attrs["smil:from"] = from }
            if let to { attrs["smil:to"] = to }
            if let by { attrs["smil:by"] = by }
            return FlatODFElement(name: "anim:animate", attributes: attrs)
        case let .set(attributeName, to):
            attrs["smil:attributeName"] = attributeName
            attrs["smil:to"] = to
            return FlatODFElement(name: "anim:set", attributes: attrs)
        case let .animateMotion(svgPath):
            attrs["svg:path"] = svgPath
            return FlatODFElement(name: "anim:animateMotion", attributes: attrs)
        case let .animateColor(attributeName, from, to, colorInterpolation):
            attrs["smil:attributeName"] = attributeName
            if let from { attrs["smil:from"] = from }
            if let to { attrs["smil:to"] = to }
            if let colorInterpolation { attrs["anim:color-interpolation"] = colorInterpolation }
            return FlatODFElement(name: "anim:animateColor", attributes: attrs)
        case let .animateTransform(transformType, from, to, by):
            attrs["svg:type"] = transformType
            if let from { attrs["smil:from"] = from }
            if let to { attrs["smil:to"] = to }
            if let by { attrs["smil:by"] = by }
            return FlatODFElement(name: "anim:animateTransform", attributes: attrs)
        case let .animateEffect(transitionType, subtype, direction):
            attrs["smil:type"] = transitionType
            if let subtype { attrs["smil:subtype"] = subtype }
            if let direction { attrs["smil:direction"] = direction }
            return FlatODFElement(name: "anim:transitionFilter", attributes: attrs)
        case let .audio(source):
            if let source { attrs["xlink:href"] = source }
            return FlatODFElement(name: "anim:audio", attributes: attrs)
        case let .video(source):
            if let source { attrs["xlink:href"] = source }
            return FlatODFElement(name: "anim:video", attributes: attrs)
        case let .command(commandType, value):
            attrs["anim:command"] = commandType
            if let value { attrs["tessera:commandValue"] = value }
            return FlatODFElement(name: "anim:command", attributes: attrs)
        }
    }

    private static func timingAttributes(_ props: SMILTimingProps, frameIDs: [UUID: String]) -> [String: String] {
        var attrs: [String: String] = [:]
        if let nodeTypeString = containerNodeTypeToODF[props.nodeType] {
            attrs["presentation:node-type"] = nodeTypeString
        }
        if let begin = beginString(props.begin, frameIDs: frameIDs) {
            attrs["smil:begin"] = begin
        }
        if let durationMS = props.durationMS {
            attrs["smil:dur"] = secondsString(fromMS: durationMS)
        }
        if let repeatCount = repeatCountString(props.repeatCount) {
            attrs["smil:repeatCount"] = repeatCount
        }
        if props.autoReverse { attrs["smil:autoReverse"] = "true" }
        if props.accelerate != 0 { attrs["smil:accelerate"] = numberString(props.accelerate) }
        if props.decelerate != 0 { attrs["smil:decelerate"] = numberString(props.decelerate) }
        if props.fill != .auto { attrs["smil:fill"] = props.fill.rawValue }
        if props.restart != .always { attrs["smil:restart"] = props.restart.rawValue }
        if let presetClass = props.presetClass, presetClass != SMILTimingProps.exclMarkerPresetClass {
            attrs["presentation:preset-class"] = presetClass
        }
        if let presetID = props.presetID { attrs["presentation:preset-id"] = presetID }
        return attrs
    }

    private static func beginString(_ conditions: [SMILCondition], frameIDs: [UUID: String]) -> String? {
        guard !conditions.isEmpty else { return nil }
        let parts = conditions.map { condition -> String in
            switch condition {
            case .indefinite:
                return "indefinite"
            case let .time(ms):
                return secondsString(fromMS: ms)
            case let .afterPrevious(ms):
                return ms == 0 ? "after-previous" : "after-previous;\(secondsString(fromMS: ms))"
            case let .withPrevious(ms):
                return ms == 0 ? "with-previous" : "with-previous;\(secondsString(fromMS: ms))"
            case let .onClick(target, ms):
                let idPart = target.flatMap { frameIDs[$0.blockID] } ?? "next"
                return ms == 0 ? "\(idPart).click" : "\(idPart).click;\(secondsString(fromMS: ms))"
            }
        }
        return parts.joined(separator: ",")
    }

    private static func secondsString(fromMS ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        return numberString(seconds) + "s"
    }

    private static func numberString(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : "\(value)"
    }

    private static func repeatCountString(_ value: SMILRepeatCount?) -> String? {
        switch value {
        case .none: return nil
        case .indefinite: return "indefinite"
        case .count(let v): return numberString(v)
        }
    }

    // MARK: fodp -> SMILAnimationTree

    /// Parses `page`'s top-level `anim:par`/`anim:seq`/`anim:iterate`/
    /// `anim:excl` child (SMIL animations live as a direct
    /// `draw:page` child, alongside the content frames) into a
    /// ``SMILAnimationTree``. `nil` when the page has no such child
    /// (the common, animation-free case). `targetResolver` maps an
    /// `smil:targetElement` string back to an ``AnimationTarget`` -
    /// the caller builds it from ``frameIDsByPosition(rootID:ast:)``
    /// over the SAME slide's just-built block subtree.
    static func mapAnimationTree(
        fromPage page: FlatODFElement, targetResolver: (String) -> AnimationTarget?
    ) -> SMILAnimationTree? {
        guard let rootElement = page.elementChildren.first(where: {
            ["anim:par", "anim:seq", "anim:iterate", "anim:excl"].contains($0.name)
        }) else { return nil }
        guard let node = mapSMILElement(rootElement, leafRoleHint: .clickEffect, targetResolver: targetResolver) else {
            return nil
        }
        return SMILAnimationTree(root: node)
    }

    /// `leafRoleHint` is the ``SMILNodeType`` a bare behavior element
    /// reached at this position should be tagged with - real ODF
    /// never repeats a container's on-click/with-previous/after-
    /// previous role on its leaf children (only the enclosing
    /// `anim:par`'s own `presentation:node-type` carries it), so a
    /// leaf's role is inferred top-down from its nearest container
    /// ancestor instead - see this extension's header.
    private static func mapSMILElement(
        _ element: FlatODFElement, leafRoleHint: SMILNodeType, targetResolver: (String) -> AnimationTarget?
    ) -> SMILNode? {
        switch element.name {
        case "anim:par", "anim:excl":
            let nodeType = element.attributes["presentation:node-type"].flatMap { odfToContainerNodeType[$0] } ?? .tmRoot
            var props = parseTimingAttributes(element, nodeType: nodeType, targetResolver: targetResolver)
            if element.name == "anim:excl" { props.presetClass = SMILTimingProps.exclMarkerPresetClass }
            let childHint: SMILNodeType
            switch nodeType {
            case .clickPar: childHint = .clickEffect
            case .withGroup: childHint = .withEffect
            case .afterGroup: childHint = .afterEffect
            default: childHint = leafRoleHint
            }
            let children = element.elementChildren.compactMap {
                mapSMILElement($0, leafRoleHint: childHint, targetResolver: targetResolver)
            }
            return .par(props, children: children)
        case "anim:seq":
            let nodeType = element.attributes["presentation:node-type"].flatMap { odfToContainerNodeType[$0] } ?? .mainSeq
            let props = parseTimingAttributes(element, nodeType: nodeType, targetResolver: targetResolver)
            let children = element.elementChildren.compactMap {
                mapSMILElement($0, leafRoleHint: leafRoleHint, targetResolver: targetResolver)
            }
            return .seq(props, children: children)
        case "anim:iterate":
            let props = parseTimingAttributes(element, nodeType: leafRoleHint, targetResolver: targetResolver)
            let iterateType = element.attributes["anim:iterate-type"].flatMap { odfToIterateType[$0] } ?? .byParagraph
            let intervalMS = element.attributes["anim:iterate-interval"].flatMap(milliseconds(fromSecondsString:)) ?? 0
            let spec = IterateSpec(type: iterateType, intervalMS: intervalMS)
            let children = element.elementChildren.compactMap {
                mapSMILElement($0, leafRoleHint: .clickEffect, targetResolver: targetResolver)
            }
            return .iterate(props, spec, children: children)
        default:
            return mapBehaviorElement(element, nodeType: leafRoleHint, targetResolver: targetResolver)
        }
    }

    private static func mapBehaviorElement(
        _ element: FlatODFElement, nodeType: SMILNodeType, targetResolver: (String) -> AnimationTarget?
    ) -> SMILNode? {
        guard let targetIDString = element.attributes["smil:targetElement"],
              var target = targetResolver(targetIDString)
        else { return nil }
        if let paragraphString = element.attributes["tessera:targetParagraphIndex"], let idx = Int(paragraphString) {
            target.paragraphIndex = idx
        }
        let props = parseTimingAttributes(element, nodeType: nodeType, targetResolver: targetResolver)
        switch element.name {
        case "anim:animate":
            let values = element.attributes["smil:values"].map { $0.components(separatedBy: ";") } ?? []
            return .behavior(props, target: target, .animate(
                attributeName: element.attributes["smil:attributeName"] ?? "",
                values: values,
                from: element.attributes["smil:from"],
                to: element.attributes["smil:to"],
                by: element.attributes["smil:by"]))
        case "anim:set":
            return .behavior(props, target: target, .set(
                attributeName: element.attributes["smil:attributeName"] ?? "",
                to: element.attributes["smil:to"] ?? ""))
        case "anim:animateMotion":
            return .behavior(props, target: target, .animateMotion(svgPath: element.attributes["svg:path"] ?? ""))
        case "anim:animateColor":
            return .behavior(props, target: target, .animateColor(
                attributeName: element.attributes["smil:attributeName"] ?? "",
                from: element.attributes["smil:from"],
                to: element.attributes["smil:to"],
                colorInterpolation: element.attributes["anim:color-interpolation"]))
        case "anim:animateTransform":
            return .behavior(props, target: target, .animateTransform(
                transformType: element.attributes["svg:type"] ?? "",
                from: element.attributes["smil:from"],
                to: element.attributes["smil:to"],
                by: element.attributes["smil:by"]))
        case "anim:transitionFilter":
            return .behavior(props, target: target, .animateEffect(
                transitionType: element.attributes["smil:type"] ?? "",
                subtype: element.attributes["smil:subtype"],
                direction: element.attributes["smil:direction"]))
        case "anim:audio":
            return .behavior(props, target: target, .audio(source: element.attributes["xlink:href"]))
        case "anim:video":
            return .behavior(props, target: target, .video(source: element.attributes["xlink:href"]))
        case "anim:command":
            return .behavior(props, target: target, .command(
                commandType: element.attributes["anim:command"] ?? "",
                value: element.attributes["tessera:commandValue"]))
        default:
            return nil
        }
    }

    private static func parseTimingAttributes(
        _ element: FlatODFElement, nodeType: SMILNodeType, targetResolver: (String) -> AnimationTarget?
    ) -> SMILTimingProps {
        SMILTimingProps(
            nodeType: nodeType,
            begin: parseBegin(element.attributes["smil:begin"], targetResolver: targetResolver),
            durationMS: element.attributes["smil:dur"].flatMap(milliseconds(fromSecondsString:)),
            repeatCount: parseRepeatCount(element.attributes["smil:repeatCount"]),
            autoReverse: element.attributes["smil:autoReverse"] == "true",
            accelerate: element.attributes["smil:accelerate"].flatMap(Double.init) ?? 0,
            decelerate: element.attributes["smil:decelerate"].flatMap(Double.init) ?? 0,
            fill: element.attributes["smil:fill"].flatMap { SMILFill(rawValue: $0) } ?? .auto,
            restart: element.attributes["smil:restart"].flatMap { SMILRestart(rawValue: $0) } ?? .always,
            presetClass: element.attributes["presentation:preset-class"],
            presetID: element.attributes["presentation:preset-id"]
        )
    }

    private static func parseBegin(_ raw: String?, targetResolver: (String) -> AnimationTarget?) -> [SMILCondition] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { part -> SMILCondition? in
            let token = String(part)
            if token == "indefinite" { return .indefinite }
            if token.hasPrefix("after-previous") {
                return .afterPrevious(offsetMS: offsetSuffix(token, prefix: "after-previous"))
            }
            if token.hasPrefix("with-previous") {
                return .withPrevious(offsetMS: offsetSuffix(token, prefix: "with-previous"))
            }
            if let clickRange = token.range(of: ".click") {
                let idPart = String(token[token.startIndex..<clickRange.lowerBound])
                let offset = offsetSuffix(token, prefix: idPart + ".click")
                let target = idPart == "next" ? nil : targetResolver(idPart)
                return .onClick(target: target, offsetMS: offset)
            }
            if let ms = milliseconds(fromSecondsString: token) {
                return .time(offsetMS: ms)
            }
            return nil
        }
    }

    private static func offsetSuffix(_ token: String, prefix: String) -> Int {
        guard token.hasPrefix(prefix) else { return 0 }
        let rest = token.dropFirst(prefix.count)
        guard rest.hasPrefix(";") else { return 0 }
        return milliseconds(fromSecondsString: String(rest.dropFirst())) ?? 0
    }

    private static func parseRepeatCount(_ raw: String?) -> SMILRepeatCount? {
        guard let raw else { return nil }
        if raw == "indefinite" { return .indefinite }
        guard let value = Double(raw) else { return nil }
        return .count(value)
    }

    private static func milliseconds(fromSecondsString s: String) -> Int? {
        guard s.hasSuffix("s") else { return nil }
        guard let seconds = Double(s.dropLast()) else { return nil }
        return Int((seconds * 1000).rounded())
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
