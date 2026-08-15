//===----------------------------------------------------------------------===//
//  SlideDeckRenderer.swift
//  Tessera Studio
//
//  One slide -> one CGContext pass - peer of ChartRenderer/ShapeRenderer
//  the way a slide composes text, shapes, and charts onto one canvas.
//  Paint order: background (the slide's resolved SlideMasterPage/Theme,
//  P1 1.5), then every placeholder-bound content block (text via
//  BlockRenderer/CTFramesetter, `.chart` via ChartRenderer, both framed
//  through SlideLayoutSpec's placeholder `frameU`/`idx`, P1 1.7/1.9),
//  then every `.shape` in the slide in `zIndex` order via ShapeRenderer.
//
//  `BlockRenderer.render(_:in:)` already takes an `EditorMode` - every
//  one of its per-type renderers ignores the parameter today (no
//  branch reads `mode`), so there is no behavioral difference to hook a
//  canvas-render mode into yet. This file calls it with `.document`
//  (the closest semantic fit: full AST, all block types) rather than
//  adding a speculative new case with no observable effect - see this
//  item's own report for the finding.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import CoreText

// MARK: - SlideDeckRenderer

/// Stateless and side-effect-free, matching `ChartRenderer`/
/// `ShapeRenderer`: every slide renders independently of every other.
public struct SlideDeckRenderer: Sendable {

    public init() {}

    // MARK: - Entry point

    /// Renders `deck`'s slide at `slideIndex` into `context`, confined to
    /// `rect`. `rect` is also the frame `frameU` denormalizes against, so
    /// the SAME method reproduces the slide correctly at any destination
    /// size (a live canvas view's own bounds, a PNG/JPG pixel size, one
    /// PDF page's media box) - `DeckExportCoordinator` is what actually
    /// varies the destination.
    ///
    /// `context` is assumed to already be in this codebase's top-left-
    /// origin/y-down convention (`ShapeGeometry`'s documented convention -
    /// see `ChartRenderer.valueToY`'s doc comment for the same
    /// assumption). A live AppKit/UIKit-backed canvas view's draw context
    /// already is; an offscreen `CGBitmapContext` or a raw PDF
    /// `CGContext` is NOT (CoreGraphics' own native space is bottom-left/
    /// y-up) - `DeckExportCoordinator` flips those before calling in,
    /// the same explicit pattern `ReceiptPDFRenderer.pdfData` already
    /// uses for its own CoreText draw (`ExportView.swift`).
    public func render(deck: SlideDeck, slideIndex: Int, in context: CGContext, rect: CGRect) {
        guard let slide = deck.slide(at: slideIndex) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        guard rect.width > 1, rect.height > 1 else { return }

        let masterPage = deck.masterPage(forSlideAt: slideIndex)
        drawBackground(masterPage: masterPage, activeTheme: deck.activeTheme, context: context, rect: rect)

        let spec = SlideLayoutSpec.default(for: slide.layout)
        let blockRenderer = self.blockRenderer(for: masterPage)
        let targetSlots = Self.flattenedSlots(of: spec)

        for (position, block) in Self.contentBlocks(of: slide.body).enumerated() {
            let frame = Self.resolveFrame(for: block, at: position, targetSlots: targetSlots, rect: rect)
            drawContentBlock(block, blockRenderer: blockRenderer, in: frame, context: context)
        }

        // Free-floating vector shapes paint last (on top of placeholder
        // content), matching how every mainstream slide tool layers a
        // manually placed shape/annotation over the layout's own text
        // frames. `.shapeGroup` carries no geometry of its own (`Block`'s
        // own doc comment) - only its leaf `.shape` members draw.
        let shapeRenderer = ShapeRenderer()
        let shapes = Self.orderedShapes(in: slide.body)
        for shape in shapes {
            // allShapes: lets a .connector's .attached endpoint resolve
            // its sibling's glue point (ConnectorRouter) - without it,
            // an attached connector silently renders an empty path.
            shapeRenderer.render(shape, in: context, allShapes: shapes)
        }
    }

    // MARK: - Background

    /// `masterPage.backgroundColorHex` resolves through `activeTheme`
    /// (P1 1.5's `ColorRef`/`Theme.resolve(_:)`); a `.theme` slot with no
    /// active theme still resolves (against `Theme.builtinDefault(for:)`)
    /// via a throwaway empty `Theme` - `Theme.resolve` is an instance
    /// method but `.theme` case only ever reads `colors[slot] ??
    /// builtinDefault(for: slot)`, and an empty `colors` dict is exactly
    /// "no theme" (`SlideMasterPage.activeThemeID`'s own doc comment).
    /// No master page, or a master with no background set, paints plain
    /// white - the renderer's own default per this item's contract.
    private func drawBackground(masterPage: SlideMasterPage?, activeTheme: Theme?, context: CGContext, rect: CGRect) {
        let hex: String
        if let ref = masterPage?.backgroundColorHex {
            hex = (activeTheme ?? Theme(name: "")).resolve(ref)
        } else {
            hex = "#FFFFFF"
        }
        context.setFillColor(Self.parseHex(hex) ?? CGColor(gray: 1, alpha: 1))
        context.fill(rect)
    }

    /// A `BlockRenderer` tinted with the master's `textColorHex` when set
    /// - that field's own doc comment: "default text color for
    /// placeholder content painted on top of this master", i.e. exactly
    /// the text this method's caller is about to draw. Falls back to
    /// `EditorTheme.light` (`BlockRenderer.init`'s own default).
    private func blockRenderer(for masterPage: SlideMasterPage?) -> BlockRenderer {
        guard let hex = masterPage?.textColorHex else { return BlockRenderer(theme: .light) }
        return BlockRenderer(theme: EditorTheme(textColorHex: hex, headingColorHex: hex))
    }

    // MARK: - Content-block dispatch

    /// `.chart` delegates to `ChartRenderer`; `.shape`/`.shapeGroup` are
    /// painted separately (see `render(deck:slideIndex:in:rect:)`) so a
    /// content block of either type here is a no-op, not a fallback
    /// text render. Everything else (heading/paragraph/list/image/
    /// table/...) goes through `BlockRenderer` -> `NSAttributedString`
    /// -> `CTFramesetter`, the one substrate this item's contract asks
    /// for.
    private func drawContentBlock(_ block: Block, blockRenderer: BlockRenderer, in rect: CGRect, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        switch block.type {
        case .shape, .shapeGroup:
            return
        case .chart:
            guard let spec = block.chart else { return }
            ChartRenderer().render(spec, in: context, rect: rect)
        default:
            drawAttributedString(blockRenderer.render(block, in: .document), in: rect, context: context)
        }
    }

    /// Draws `text` inside `rect` via `CTFramesetter`. CoreText's glyph
    /// space is y-up; this file's `context` is y-down (see this type's
    /// doc comment) - the flip below is scoped to `rect` (reflection
    /// about its own vertical midpoint, not the whole context) so the
    /// SAME `path` still bounds the frame afterward, matching
    /// `ChartRenderer.drawText`'s own per-draw local-flip technique.
    private func drawAttributedString(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: - Content-block enumeration

    /// The slide's placeholder-eligible content blocks, in slot order -
    /// mirrors `SlideStore.applyingLayout`'s own `existingBlocks`
    /// definition exactly (the root's children when it's a pure wrapper,
    /// e.g. `.titleAndContent`'s toggle; else the root itself, e.g.
    /// `.title`/`.image`/`.blank`), so the SAME notion of "the slide's
    /// content blocks" is shared by layout application and rendering.
    static func contentBlocks(of ast: DocumentAST) -> [Block] {
        guard let rootID = ast.rootChildren.first, let root = ast.blocks[rootID] else { return [] }
        return root.children.isEmpty ? [root] : root.children.compactMap { ast.blocks[$0] }
    }

    // MARK: - Placeholder-slot flattening

    /// `spec`'s target slots, flattened the same way
    /// `SlideStore.applyingLayout` flattens them: every `builtins` entry
    /// has exactly one top-level placeholder (`SlideLayoutSpec`'s own
    /// header comment) - its children when it wraps any, else itself.
    static func flattenedSlots(of spec: SlideLayoutSpec) -> [SlideLayoutPlaceholder] {
        guard let top = spec.placeholders.first else { return [] }
        return top.children.isEmpty ? [top] : top.children
    }

    // MARK: - Frame resolution

    /// Resolves `block`'s draw frame: `idx` match first (`block
    /// .attributes["placeholderIdx"]` against a slot's `idx`, type-
    /// checked - the same identity-matching principle `SlideStore
    /// .applyingLayout` established for CONTENT, reused here for
    /// LAYOUT geometry, P1 1.7/1.9), else `position` match (a block
    /// `insertingSlide` created directly - never round-tripped through
    /// `setSlideLayout` - carries no `placeholderIdx` yet, but its
    /// array position already lines up with the spec's slot order 1:1,
    /// since both were built from the same 4 built-in shapes), else the
    /// slot's own `frameU` is absent/unmatched and
    /// `defaultFrameU(for:)` applies.
    static func resolveFrame(for block: Block, at position: Int, targetSlots: [SlideLayoutPlaceholder], rect: CGRect) -> CGRect {
        if let recorded = block.attributes["placeholderIdx"]?.numberValue.map({ Int($0) }),
           let slot = targetSlots.first(where: { $0.idx == recorded && $0.blockType == block.type }) {
            return denormalize(slot.frameU, defaultFor: block.type, rect: rect)
        }
        if position < targetSlots.count, targetSlots[position].blockType == block.type {
            return denormalize(targetSlots[position].frameU, defaultFor: block.type, rect: rect)
        }
        return denormalize(nil, defaultFor: block.type, rect: rect)
    }

    private static func denormalize(_ frameU: CGRect?, defaultFor type: BlockType, rect: CGRect) -> CGRect {
        let unit = frameU ?? defaultFrameU(for: type)
        return CGRect(
            x: rect.minX + unit.minX * rect.width,
            y: rect.minY + unit.minY * rect.height,
            width: unit.width * rect.width,
            height: unit.height * rect.height
        )
    }

    /// A reasonable default position/size for a placeholder-bound block
    /// with no explicit `frameU` set - `SlideLayoutPlaceholder/frameU`'s
    /// own doc comment. Two bands: a title strip along the top for
    /// `.heading`, a content box below it for everything else
    /// (paragraph/list/image/table/chart/...) - matches every built-in
    /// catalog entry's own "Title" + content-slot(s) shape.
    private static func defaultFrameU(for type: BlockType) -> CGRect {
        switch type {
        case .heading:
            return CGRect(x: 0.06, y: 0.05, width: 0.88, height: 0.16)
        default:
            return CGRect(x: 0.06, y: 0.24, width: 0.88, height: 0.70)
        }
    }

    // MARK: - Shape enumeration

    /// Every `.shape` in `ast` - including ones nested inside
    /// `.shapeGroup`/`.frame`/`.section` - in `zIndex` order, matching
    /// `ShapeZOrder`'s own "position in paint order" meaning for
    /// `zIndex`. `ast.depthFirstOrder()` walks the WHOLE subtree
    /// (`Slide.body` already includes every descendant of the slide's
    /// root - see `SlideDeck.collectBlocks`), so a shape need not be a
    /// direct content-block sibling to be found here.
    static func orderedShapes(in ast: DocumentAST) -> [Shape] {
        ast.depthFirstOrder()
            .compactMap { id -> Shape? in
                guard let block = ast.blocks[id], block.type == .shape else { return nil }
                return block.shape
            }
            .sorted { $0.zIndex < $1.zIndex }
    }

    // MARK: - Hex parsing

    /// `#RRGGBB` or `#RRGGBBAA`, matching `ChartRenderer`/`ShapeRenderer`'s
    /// own local parser convention (this codebase's established choice
    /// of duplicating the ~15 lines per CoreGraphics-only renderer rather
    /// than sharing a private helper across files).
    // Device RGB explicitly, not the CGColor(red:green:blue:alpha:)
    // convenience initializer: that initializer builds the color in a
    // different implicit color space, so filling a deviceRGB bitmap
    // context (what every caller - export, tests - actually renders
    // into) silently color-matches/distorts the hex value instead of
    // passing its bytes through untouched. Same colorSpace on both
    // ends is what makes a #RRGGBB hex land as those exact bytes.
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    private static func parseHex(_ hex: String) -> CGColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return CGColor(
                colorSpace: deviceRGB,
                components: [
                    CGFloat((value >> 16) & 0xFF) / 255,
                    CGFloat((value >> 8) & 0xFF) / 255,
                    CGFloat(value & 0xFF) / 255,
                    1,
                ]
            )
        }
        return CGColor(
            colorSpace: deviceRGB,
            components: [
                CGFloat((value >> 24) & 0xFF) / 255,
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255,
            ]
        )
    }
}
