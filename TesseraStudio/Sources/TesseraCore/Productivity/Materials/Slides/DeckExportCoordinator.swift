//===----------------------------------------------------------------------===//
//  DeckExportCoordinator.swift
//  Tessera Studio
//
//  Wraps SlideDeckRenderer for PNG/JPG/PDF export - the ONE per-slide
//  CGContext-drawing method (`SlideDeckRenderer.render(deck:slideIndex:
//  in:rect:)`) reused unmodified against two destination kinds: an
//  offscreen bitmap `CGContext` (PNG/JPG, encoded via ImageIO's
//  `CGImageDestination`) and a multi-page PDF `CGContext`
//  (`CGContext(consumer:mediaBox:)`, one page per slide) - no separate
//  drawing implementation exists for either (this item's own contract,
//  "one substrate serves canvas, PNG/JPG, PDF").
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - DeckExportCoordinator

/// Stateless and side-effect-free, matching `SlideDeckRenderer` itself:
/// every export call is independent, no shared mutable state.
public struct DeckExportCoordinator: Sendable {

    public init() {}

    // MARK: - Bitmap (PNG / JPG)

    /// Renders `deck`'s slide at `slideIndex` into an offscreen RGBA8
    /// bitmap at `pixelSize` and encodes it as PNG. `pixelSize` doubles
    /// as `SlideDeckRenderer`'s destination `rect`, so every placeholder
    /// `frameU` denormalizes directly to the requested resolution - no
    /// separate scale step.
    public func renderPNG(deck: SlideDeck, slideIndex: Int, pixelSize: CGSize) -> Data? {
        renderBitmap(deck: deck, slideIndex: slideIndex, pixelSize: pixelSize, type: .png, quality: nil)
    }

    /// Same render path as `renderPNG`, encoded lossy at `quality`
    /// (0...1, ImageIO's `kCGImageDestinationLossyCompressionQuality`).
    public func renderJPEG(deck: SlideDeck, slideIndex: Int, pixelSize: CGSize, quality: CGFloat = 0.85) -> Data? {
        renderBitmap(deck: deck, slideIndex: slideIndex, pixelSize: pixelSize, type: .jpeg, quality: quality)
    }

    private func renderBitmap(deck: SlideDeck, slideIndex: Int, pixelSize: CGSize, type: UTType, quality: CGFloat?) -> Data? {
        guard let context = Self.makeBitmapContext(pixelSize: pixelSize) else { return nil }
        SlideDeckRenderer().render(
            deck: deck, slideIndex: slideIndex, in: context,
            rect: CGRect(origin: .zero, size: pixelSize)
        )
        guard let image = context.makeImage() else { return nil }
        return Self.encode(image, type: type, quality: quality)
    }

    /// A top-left-origin/y-down RGBA8 bitmap context. `CGBitmapContext`'s
    /// native space is bottom-left/y-up (standard CoreGraphics), but
    /// `SlideDeckRenderer` assumes the top-left/y-down convention
    /// `ShapeRenderer`/`ChartRenderer` already do (see
    /// `SlideDeckRenderer`'s own doc comment) - the flip happens once
    /// here, before the render call, the same explicit pattern
    /// `ReceiptPDFRenderer.pdfData` uses for its own raw PDF `CGContext`
    /// (`ExportView.swift`).
    private static func makeBitmapContext(pixelSize: CGSize) -> CGContext? {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: CFDictionary? = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - PDF (one page per slide)

    /// One PDF page per slide, `pageSize` points each - the SAME
    /// `SlideDeckRenderer.render` call as the bitmap paths above, against
    /// a PDF `CGContext` instead of a `CGBitmapContext`. `SlideDeck` has
    /// no canvas-size field of its own yet (a gap this item does not
    /// close - see its report's openQuestions), so `pageSize` defaults
    /// to a standard 16:9 slide size in points; a caller that knows its
    /// deck's real size should pass it explicitly. Returns `nil` for an
    /// empty deck rather than a zero-page PDF.
    public func renderPDF(deck: SlideDeck, pageSize: CGSize = CGSize(width: 960, height: 540)) -> Data? {
        guard deck.slideCount > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let renderer = SlideDeckRenderer()
        let rect = CGRect(origin: .zero, size: pageSize)
        for index in 0..<deck.slideCount {
            context.beginPDFPage(nil)
            // Same bottom-left/y-up native space as the bitmap path -
            // flip once per page, before the shared render call, and
            // restore before the page closes so the flip never
            // compounds across pages.
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            renderer.render(deck: deck, slideIndex: index, in: context, rect: rect)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
