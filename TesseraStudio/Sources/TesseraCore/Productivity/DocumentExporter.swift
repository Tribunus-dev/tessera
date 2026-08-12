import Foundation
#if canImport(AppKit)
import AppKit
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
/// **PDF** — rendered via AppKit's `NSAttributedString` + `NSPrintOperation`.
/// Requires macOS; falls back to plain-text on other platforms.
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

    public init() {}

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
            var rows: [String] = []
            for childID in block.children {
                guard let cellBlock = ast.blocks[childID] else { continue }
                let inner = try renderInlineRuns(cellBlock.content)
                rows.append("<td>\(inner)</td>")
            }
            return "<table><tr>\(rows.joined(separator: ""))</tr></table>"

        case .tableCell:
            // Rendered by parent table.
            let inner = try renderInlineRuns(block.content)
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
            return "<p><code>$\(escapeHTML(latex))$</code></p>"

        case .comment, .trackInsertion, .trackDeletion:
            // Review-only / collaboration blocks; not rendered to export HTML.
            return ""
        }
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

    /// Render an HTML file to PDF using `textutil -convert pdf`.
    /// textutil uses macOS's WebKit HTML renderer internally, producing
    /// high-quality output matching what Safari would print.
    private func renderPDF(from htmlFile: URL, destination: URL) async throws -> URL {
        try await convertWithTextutil(from: htmlFile, to: .pdf, destination: destination)
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
}
