import Foundation
import SwiftMath
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

// MARK: - DocumentExporter

/// Exports a ``DocumentAST`` to standard formats: DOCX, PDF, ODT.
/// Uses a two-step pipeline: DocumentAST -> HTML -> native format.
///
/// **DOCX** — converted from HTML via `textutil -convert docx`.
/// Preserves headings (H1-H6), bold, italic, underline, strikethrough,
/// ordered/unordered/task lists, tables, block quotes, code blocks,
/// horizontal rules, and inline links.
///
/// **PDF** — converted from HTML via `soffice --convert-to pdf`
/// (`LibreOfficeConverter`), the same CLI conversion mechanism used
/// elsewhere in this pipeline (`PDFExportBridge`) — `textutil` has no
/// `pdf` conversion target, so it cannot serve this format.
///
/// **ODT** — converted from HTML via `textutil -convert odt`.
/// Less faithful than DOCX for complex formatting; a native ODF
/// writer is the Phase 2 target.
public final class DocumentExporter: Sendable {

    public enum ExportFormat: String, CaseIterable, Identifiable {
        case docx = "docx"
        case pdf  = "pdf"
        case odt  = "odt"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .docx: return "Word (.docx)"
            case .pdf:  return "PDF (.pdf)"
            case .odt:  return "OpenDocument (.odt)"
            }
        }

        public var fileExtension: String { rawValue }

        public var mimeType: String {
            switch self {
            case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case .pdf:  return "application/pdf"
            case .odt:  return "application/vnd.oasis.opendocument.text"
            }
        }

        public var utType: String {
            switch self {
            case .docx: return "org.openxmlformats.wordprocessingml.document"
            case .pdf:  return "com.adobe.pdf"
            case .odt:  return "org.oasis.opendocument.text"
            }
        }
    }

    public enum ExportError: Error, LocalizedError {
        case htmlGenerationFailed(String)
        case textutilFailed(exitCode: Int32, stderr: String)
        case noHTMLSupport
        case printOperationFailed
        case unsupportedFormat(ExportFormat)

        public var errorDescription: String? {
            switch self {
            case .htmlGenerationFailed(let reason):
                return "Failed to generate HTML: \(reason)"
            case .textutilFailed(let code, let stderr):
                return "textutil failed (exit \(code)): \(stderr)"
            case .noHTMLSupport:
                return "HTML export is not supported on this platform"
            case .printOperationFailed:
                return "Failed to render PDF via NSPrintOperation"
            case .unsupportedFormat(let format):
                return "Format '\(format.rawValue)' is not supported on this platform"
            }
        }
    }

    private let converter: LibreOfficeConverter

    public init(converter: LibreOfficeConverter = LibreOfficeConverter()) {
        self.converter = converter
    }

    // MARK: - Public API

    /// Export the document to the given format.
    /// Returns the file URL of the written file.
    public func export(
        _ doc: Doc,
        to format: ExportFormat,
        destination: URL
    ) async throws -> URL {
        let html = try htmlFromDocument(doc)
        let tempDir = FileManager.default.temporaryDirectory
        let htmlFile = tempDir.appendingPathComponent("tessera-export-\(doc.id.uuidString).html")
        try html.write(to: htmlFile, atomically: true, encoding: .utf8)

        switch format {
        case .docx, .odt:
            return try await convertWithTextutil(from: htmlFile, to: format, destination: destination)
        case .pdf:
            #if canImport(AppKit)
            return try await renderPDF(from: htmlFile, destination: destination)
            #else
            throw ExportError.unsupportedFormat(format)
            #endif
        }
    }

    /// Generate a preview of the document as HTML.
    public func htmlPreview(_ doc: Doc) throws -> String {
        try htmlFromDocument(doc)
    }

    // MARK: - HTML generation

    /// Convert a DocumentAST to a self-contained HTML document.
    /// Includes a minimal CSS stylesheet matching Word's defaults.
    private func htmlFromDocument(_ doc: Doc) throws -> String {
        let body = try renderAST(doc.body)
        let title = doc.displayTitle
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>\(escapeHTML(title))</title>
          <style>
            body {
              font-family: Calibri, 'Helvetica Neue', Arial, sans-serif;
              font-size: 11pt;
              line-height: 1.15;
              color: #1f1f1f;
              max-width: 6.5in;
              margin: 1in auto;
              padding: 0;
            }
            h1 { font-size: 24pt; font-weight: bold; margin: 24pt 0 12pt; }
            h2 { font-size: 18pt; font-weight: bold; margin: 20pt 0 10pt; }
            h3 { font-size: 14pt; font-weight: bold; margin: 16pt 0 8pt; }
            h4 { font-size: 12pt; font-weight: bold; margin: 14pt 0 6pt; }
            h5 { font-size: 11pt; font-weight: bold; margin: 12pt 0 4pt; }
            h6 { font-size: 11pt; font-weight: bold; font-style: italic; margin: 12pt 0 4pt; }
            p  { margin: 0 0 6pt; }
            ul, ol { margin: 0 0 6pt; padding-left: 24pt; }
            li { margin-bottom: 2pt; }
            blockquote {
              border-left: 3pt solid #888;
              margin: 6pt 0 6pt 12pt;
              padding-left: 12pt;
              color: #555;
            }
            pre, code {
              font-family: Consolas, 'SF Mono', monospace;
              font-size: 10pt;
              background: #f4f4f4;
              border-radius: 3pt;
            }
            pre { padding: 8pt; overflow: auto; }
            code { padding: 1pt 3pt; }
            table {
              border-collapse: collapse;
              margin: 6pt 0;
              width: 100%;
            }
            td, th {
              border: 1pt solid #ccc;
              padding: 4pt 6pt;
              text-align: left;
              vertical-align: top;
            }
            th { background: #f0f0f0; font-weight: bold; }
            hr { border: none; border-top: 1pt solid #ccc; margin: 12pt 0; }
            img { max-width: 100%; height: auto; }
            a { color: #0563c1; }
            .callout {
              background: #fffb8e;
              border-left: 4pt solid #f4b400;
              padding: 6pt 10pt;
              margin: 6pt 0;
            }
            .divider {
              color: #999;
              letter-spacing: 2pt;
            }
          </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Render a DocumentAST to HTML body content.
    private func renderAST(_ ast: DocumentAST) throws -> String {
        var out: [String] = []
        for blockID in ast.rootChildren {
            guard let block = ast.blocks[blockID] else { continue }
            out.append(try renderBlock(block, in: ast))
        }
        return out.joined(separator: "\n")
    }

    private func renderBlock(_ block: Block, in ast: DocumentAST) throws -> String {
        switch block.type {
        case .heading:
            let level = block.attributes["level"]?.intValue ?? 1
            let levelTag = "h\(min(max(level, 1), 6))"
            let inner = try renderInlineRuns(block.content)
            return "<\(levelTag)>\(inner)</\(levelTag)>"

        case .paragraph:
            let inner = try renderInlineRuns(block.content)
            return inner.isEmpty ? "<p><br></p>" : "<p>\(inner)</p>"

        case .list:
            let style = block.attributes["style"]?.stringValue ?? "unordered"
            let tag = style == "ordered" ? "ol" : "ul"
            var items: [String] = []
            for childID in block.children {
                guard let child = ast.blocks[childID] else { continue }
                let inner = try renderInlineRuns(child.content)
                items.append("<li>\(inner)</li>")
            }
            return "<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>"

        case .listItem:
            // List items are rendered by their parent list container.
            let inner = try renderInlineRuns(block.content)
            return "<li>\(inner)</li>"

        case .table:
            var rowsHTML: [String] = []
            for row in TableLayout.rows(for: block, in: ast) {
                var cellsHTML: [String] = []
                for placement in row {
                    guard let cellBlock = ast.blocks[placement.cellID] else { continue }
                    let inner = try renderTableCellContent(cellBlock, in: ast)
                    var spanAttrs = ""
                    if placement.rowSpan > 1 { spanAttrs += " rowspan=\"\(placement.rowSpan)\"" }
                    if placement.colSpan > 1 { spanAttrs += " colspan=\"\(placement.colSpan)\"" }
                    cellsHTML.append("<td\(spanAttrs)>\(inner)</td>")
                }
                rowsHTML.append("<tr>\(cellsHTML.joined(separator: ""))</tr>")
            }
            return "<table>\(rowsHTML.joined(separator: "\n"))</table>"

        case .tableCell:
            // Rendered by parent table when walked as part of one; this
            // path only runs if a cell is ever rendered standalone.
            let inner = try renderTableCellContent(block, in: ast)
            return "<td>\(inner)</td>"

        case .image:
            let src = block.attributes["source"]?.stringValue ?? ""
            let alt = block.attributes["alt"]?.stringValue ?? "image"
            return "<img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\">"

        case .codeBlock:
            let lang = block.attributes["language"]?.stringValue ?? ""
            let code = block.content.first?.text ?? ""
            let escaped = escapeHTML(code)
            return "<pre><code class=\"language-\(escapeHTML(lang))\">\(escaped)</code></pre>"

        case .callout:
            let emoji = block.attributes["emoji"]?.stringValue ?? "💡"
            let inner = try renderInlineRuns(block.content)
            return "<div class=\"callout\"><strong>\(emoji)</strong> \(inner)</div>"

        case .divider:
            return "<hr>"

        case .quote:
            let inner = try renderInlineRuns(block.content)
            return "<blockquote>\(inner)</blockquote>"

        case .toggle:
            let expanded = block.attributes["expanded"]?.boolValue ?? true
            let marker = expanded ? "▾" : "▸"
            let inner = try renderInlineRuns(block.content)
            return "<p>\(marker)  \(inner)</p>"

        case .equation:
            let latex = block.attributes["latex"]?.stringValue ?? ""
            return renderEquationHTML(latex)

        case .comment, .trackInsertion, .trackDeletion:
            // Review-only / collaboration blocks; not rendered to export HTML.
            return ""

        case .shape:
            // A bounding-box div, not a faithful silhouette: porting
            // ShapeRenderer's per-kind CGPath math (polygon/star point
            // generation) into a second, HTML-string renderer would
            // duplicate that logic and let the two drift. Position,
            // size, and fill/stroke color are still accurate.
            return renderShapeDiv(block.shape)

        case .chart:
            // Same rationale as .shape above: a labeled placeholder div,
            // not a ported copy of ChartRenderer's CoreGraphics drawing.
            let title = block.chart?.title ?? "Chart"
            return "<div class=\"chart\">\(escapeHTML(title))</div>"

        case .shapeGroup:
            var items: [String] = []
            for childID in block.children {
                guard let child = ast.blocks[childID] else { continue }
                items.append(try renderBlock(child, in: ast))
            }
            return "<div class=\"shape-group\">\n\(items.joined(separator: "\n"))\n</div>"

        case .section:
            var items: [String] = []
            for childID in block.children {
                guard let child = ast.blocks[childID] else { continue }
                items.append(try renderBlock(child, in: ast))
            }
            let columns = SectionStore.section(for: block, in: ast)?.columns ?? 1
            let style = columns > 1 ? " style=\"column-count:\(columns)\"" : ""
            return "<div class=\"section\"\(style)>\n\(items.joined(separator: "\n"))\n</div>"

        case .frame:
            var items: [String] = []
            for childID in block.children {
                guard let child = ast.blocks[childID] else { continue }
                items.append(try renderBlock(child, in: ast))
            }
            let f = block.frame
            let style = "position:absolute;left:\(f?.x ?? 0)px;top:\(f?.y ?? 0)px;width:\(f?.width ?? 0)px;height:\(f?.height ?? 0)px;"
            return "<div class=\"frame\" style=\"\(style)\">\n\(items.joined(separator: "\n"))\n</div>"

        case .field:
            // Cached resolved text, same as any other run-bearing block.
            let inner = try renderInlineRuns(block.content)
            return "<span class=\"field\">\(inner)</span>"

        case .footnote, .endnote:
            // Out-of-flow note bodies (DocumentMeta.notes) - rendered
            // only if walked directly, matching .shape's own "not the
            // real UI, just an exhaustive-switch placeholder" rationale.
            let inner = try renderInlineRuns(block.content)
            return "<div class=\"note\">\(inner)</div>"

        case .media:
            let media = block.media
            let src = media?.sourceURL ?? ""
            let tag = media?.kind == .video ? "video" : "audio"
            return "<\(tag) src=\"\(escapeHTML(src))\" controls></\(tag)>"

        case .toc:
            // Same recurse-and-wrap shape as .section/.shapeGroup above:
            // a TOC's children are real generated entry paragraphs, so
            // (unlike plainText's derived-content exclusion) an exported
            // document should show them - a reader opening the HTML
            // export needs to see the table of contents, not just know
            // one exists.
            var items: [String] = []
            for childID in block.children {
                guard let child = ast.blocks[childID] else { continue }
                items.append(try renderBlock(child, in: ast))
            }
            return "<nav class=\"toc\">\n\(items.joined(separator: "\n"))\n</nav>"
        }
    }

    /// A table cell's content: nested block children (paragraphs,
    /// lists, even a nested table) when it has any, walked through the
    /// same recursive dispatch every other container block uses -
    /// otherwise its flat inline runs, exactly as before. Every table
    /// cell created today has empty `children`, so this is a strict
    /// addition: no existing table's export output changes.
    private func renderTableCellContent(_ cell: Block, in ast: DocumentAST) throws -> String {
        guard !cell.children.isEmpty else {
            return try renderInlineRuns(cell.content)
        }
        var items: [String] = []
        for childID in cell.children {
            guard let child = ast.blocks[childID] else { continue }
            items.append(try renderBlock(child, in: ast))
        }
        return items.joined(separator: "\n")
    }

    private func renderInlineRuns(_ runs: [InlineRun]) throws -> String {
        var out = ""
        for run in runs {
            var part = escapeHTML(run.text)
            var hasAnnotations = false
            for annotation in run.annotations {
                switch annotation {
                case .bold:
                    part = "<strong>\(part)</strong>"
                    hasAnnotations = true
                case .italic:
                    part = "<em>\(part)</em>"
                    hasAnnotations = true
                case .underline:
                    part = "<u>\(part)</u>"
                    hasAnnotations = true
                case .strikethrough:
                    part = "<s>\(part)</s>"
                    hasAnnotations = true
                case .code:
                    part = "<code>\(part)</code>"
                    hasAnnotations = true
                case .subscript:
                    part = "<sub>\(part)</sub>"
                    hasAnnotations = true
                case .superscript:
                    part = "<sup>\(part)</sup>"
                    hasAnnotations = true
                case .link(let url):
                    part = "<a href=\"\(escapeHTML(url.absoluteString))\">\(part)</a>"
                    hasAnnotations = true
                case .color:
                    // HTML color annotations are inline styles; omit for compatibility.
                    hasAnnotations = true
                case .noteRef:
                    // The marker's number is derived (DocumentAST.
                    // deriveNoteNumbering()), not available per-run here;
                    // <sup> matches the superscript convention every
                    // word processor uses for a note reference.
                    part = "<sup>\(part)</sup>"
                    hasAnnotations = true
                }
            }
            out += part
        }
        return out
    }

    // MARK: - textutil conversion

    /// Convert an HTML file to DOCX/ODT using `textutil`.
    private func convertWithTextutil(
        from htmlFile: URL,
        to format: ExportFormat,
        destination: URL
    ) async throws -> URL {
        let formatArg = format.rawValue
        let outputDir = destination.deletingLastPathComponent()

        // Ensure output directory exists.
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Remove existing file so textutil doesn't append.
        try? FileManager.default.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = [
            "-convert", formatArg,
            "-outputdir", outputDir.path,
            htmlFile.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    // textutil strips the .html extension; the output is
                    // <basename>.<format> in the same directory.
                    let baseName = htmlFile.deletingPathExtension().lastPathComponent
                    let expected = outputDir.appendingPathComponent("\(baseName).\(formatArg)")
                    if FileManager.default.fileExists(atPath: expected.path) {
                        // Move to the requested destination.
                        try? FileManager.default.moveItem(at: expected, to: destination)
                        continuation.resume(returning: destination)
                    } else if FileManager.default.fileExists(atPath: destination.path) {
                        // Already at destination.
                        continuation.resume(returning: destination)
                    } else {
                        continuation.resume(throwing: ExportError.textutilFailed(
                            exitCode: proc.terminationStatus,
                            stderr: "output file not found at \(expected.path)"
                        ))
                    }
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ExportError.textutilFailed(
                        exitCode: proc.terminationStatus,
                        stderr: stderr
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - PDF rendering

    /// Render an HTML file to PDF via `soffice --convert-to pdf`
    /// (`LibreOfficeConverter`, the same CLI-conversion mechanism
    /// `PDFExportBridge`/`LibreOfficeConverter`'s other callers already
    /// use elsewhere in this pipeline). `textutil`'s own `-convert`
    /// target list has no `pdf` entry (verified against `textutil
    /// -help` - it converts between txt/rtf/rtfd/doc/docx/odt/webarchive,
    /// never pdf), so `convertWithTextutil` above cannot serve this
    /// format - `soffice` is the one already-proven-working converter
    /// in this codebase that actually supports HTML -> PDF.
    private func renderPDF(from htmlFile: URL, destination: URL) async throws -> URL {
        let htmlData = try Data(contentsOf: htmlFile)
        let pdfData = try await converter.convert(data: htmlData, sourceExtension: "html", targetExtension: "pdf")
        let outputDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try pdfData.write(to: destination)
        return destination
    }

    // MARK: - Helpers

    private func escapeHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Renders a `.equation` block's LaTeX to a self-contained
    /// `<img>` (a base64-embedded PNG), via the SAME SwiftMath path
    /// `BlockRenderer.renderLaTeX` uses (`MTMathImage.asImage()` - see
    /// that file for the shared rendering contract). Item 2.14's own
    /// design contract: `textutil`'s HTML->DOCX/ODT conversion (this
    /// file's own pipeline - see the header) has no MathML support, so
    /// an embedded raster image is the actual export target that
    /// survives that pipeline - not MathML, which `textutil` would
    /// just strip. This mirrors `.image` blocks above (`<img
    /// src="...">`), the one existing block type this file already
    /// exports as a raster image.
    ///
    /// Empty/whitespace-only LaTeX and any SwiftMath parse failure
    /// both degrade to the OLD literal `$latex$` placeholder text
    /// (never throws) - a visible, honest "this didn't render" marker,
    /// matching `BlockRenderer.renderLaTeX`'s own malformed-data
    /// contract for the same input.
    private func renderEquationHTML(_ latex: String) -> String {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<p><code>[Empty equation]</code></p>" }
        #if canImport(AppKit) || canImport(UIKit)
        let mathImage = MTMathImage(latex: latex, fontSize: 20, textColor: .black, labelMode: .display, textAlignment: .center)
        let (error, image) = mathImage.asImage()
        if error == nil, let image, image.size.width > 0, image.size.height > 0,
           let png = pngData(from: image) {
            let base64 = png.base64EncodedString()
            return "<p><img src=\"data:image/png;base64,\(base64)\" alt=\"\(escapeHTML(latex))\" width=\"\(Int(image.size.width))\" height=\"\(Int(image.size.height))\"></p>"
        }
        #endif
        return "<p><code>$\(escapeHTML(latex))$</code></p>"
    }

    #if canImport(AppKit)
    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #elseif canImport(UIKit)
    private func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }
    #endif

    /// No `Theme` is reachable in this exporter's scope (it works from
    /// a plain `Shape`, not a themed deck) - a `.theme` ref falls back
    /// to `Theme.builtinDefault(for:)`, the same neutral default
    /// `SlideDeckRenderer.drawBackground` uses with no active theme.
    private func hex(for ref: ColorRef) -> String {
        switch ref {
        case .literal(let hex): return hex
        case .theme(let slot, _): return Theme.builtinDefault(for: slot)
        }
    }

    private func renderShapeDiv(_ shape: Shape?) -> String {
        guard let shape else { return "<div class=\"shape\"></div>" }
        let g = shape.geometry
        var style = "position:absolute;left:\(g.x)px;top:\(g.y)px;width:\(g.width)px;height:\(g.height)px;"
        if g.rotation != 0 {
            style += "transform:rotate(\(g.rotation)deg);"
        }
        if let fill = shape.fill {
            style += "background-color:\(escapeHTML(hex(for: fill.colorHex)));opacity:\(fill.opacity);"
        }
        if let stroke = shape.stroke {
            style += "border:\(stroke.width)px solid \(escapeHTML(stroke.colorHex));"
        }
        let kindClass = "shape-\(escapeHTML(shape.kind.rawValue))"
        let label = shape.text?.plainText ?? ""
        return "<div class=\"shape \(kindClass)\" style=\"\(style)\">\(escapeHTML(label))</div>"
    }
}
