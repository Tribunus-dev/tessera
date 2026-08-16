import Foundation

// MARK: - DocumentSearchIndex

/// Find/replace over a ``DocumentAST``, sharing ``Doc/plainText(of:)``'s
/// exact depth-first block-text coordinates so a match's offsets can be
/// sliced straight out of that function's output.
///
/// A pure, stateless namespace (mirrors ``TableLayout``'s shape) - no
/// store, no persisted state. `Doc.appendPlainText` is `private` to
/// `Doc.swift`, so `appendEntries` below mirrors its switch/traversal
/// by hand rather than calling into it; the two must stay in lockstep
/// for the shared-coordinates invariant to hold (proved in
/// `DocumentSearchIndexTests` by composing match offsets against
/// `Doc.plainText(of:)`'s own output).
public enum DocumentSearchIndex {

    // MARK: - SearchOptions

    public struct SearchOptions: Sendable, Equatable {
        public var caseSensitive: Bool
        /// Per-block matching is the default: a match cannot span two
        /// different blocks' text. Set `true` to search the fully
        /// flattened `Doc.plainText(of:)` string instead, allowing a
        /// match to cross a block boundary (the "\n" `appendPlainText`
        /// joins entries with).
        public var crossBlock: Bool

        public init(caseSensitive: Bool = false, crossBlock: Bool = false) {
            self.caseSensitive = caseSensitive
            self.crossBlock = crossBlock
        }
    }

    // MARK: - SearchMatch

    public struct SearchMatch: Sendable, Equatable, Hashable {
        /// The block whose own text entry the match was found in. For
        /// a `crossBlock` match spanning multiple blocks, this is the
        /// block containing the match's start.
        public let blockID: UUID
        /// UTF-16 offsets into `Doc.plainText(of:)`'s output for the
        /// SAME `DocumentAST` (the codebase's established offset
        /// convention - see `RangeOffset`): `plainText.utf16` sliced
        /// `[rangeStart, rangeEnd)` reproduces the matched text exactly.
        public let rangeStart: Int
        public let rangeEnd: Int

        public init(blockID: UUID, rangeStart: Int, rangeEnd: Int) {
            self.blockID = blockID
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
        }
    }

    // MARK: - Search

    public static func search(
        _ query: String,
        in ast: DocumentAST,
        options: SearchOptions = SearchOptions()
    ) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let located = locatedEntries(for: ast)
        guard !located.isEmpty else { return [] }

        if options.crossBlock {
            let fullText = located.map { $0.entry.text }.joined(separator: "\n")
            return findAllRanges(of: query, in: fullText, caseSensitive: options.caseSensitive).map { range in
                let start = utf16Offset(range.lowerBound, in: fullText)
                let end = utf16Offset(range.upperBound, in: fullText)
                // The block owning the START of the match. A match that
                // truly crosses a boundary has no single owning block;
                // `replacingAll` below refuses to mutate one it can't
                // resolve to a single block's own `content`.
                let owner = located.last(where: { $0.base <= start })?.entry ?? located[0].entry
                return SearchMatch(blockID: owner.blockID, rangeStart: start, rangeEnd: end)
            }
        }

        var matches: [SearchMatch] = []
        for (entry, base) in located {
            for range in findAllRanges(of: query, in: entry.text, caseSensitive: options.caseSensitive) {
                let localStart = utf16Offset(range.lowerBound, in: entry.text)
                let localEnd = utf16Offset(range.upperBound, in: entry.text)
                matches.append(SearchMatch(blockID: entry.blockID, rangeStart: base + localStart, rangeEnd: base + localEnd))
            }
        }
        return matches
    }

    // MARK: - Replace all

    /// Applies every match of `query` as ONE combined mutation:
    /// within each affected block, matches are spliced back-to-front
    /// (highest offset first) so replacing one match never shifts the
    /// still-pending offset of an earlier one in the same block.
    ///
    /// A match this can't trace back to exactly one block's own
    /// `content` array is silently excluded from the mutation (but was
    /// still returned by ``search(_:in:options:)`` for read-only
    /// callers) - see ``TextEntry/contentOffset``. `receiptPayload` is
    /// the shape a caller's Store attaches to ONE `doc_find_replace`
    /// receipt; this type has no Store dependency and does not append
    /// it itself.
    public static func replacingAll(
        _ query: String,
        with replacement: String,
        in ast: DocumentAST,
        options: SearchOptions = SearchOptions()
    ) -> (ast: DocumentAST, replacedCount: Int, receiptPayload: [String: JSONValue]) {
        let matches = search(query, in: ast, options: options)
        var result = ast
        var replacedCount = 0
        var affectedBlockIDs: Set<UUID> = []

        if !matches.isEmpty {
            let located = locatedEntries(for: ast)
            var entryByBlock: [UUID: (base: Int, entry: TextEntry)] = [:]
            for (entry, base) in located { entryByBlock[entry.blockID] = (base, entry) }

            for (blockID, blockMatches) in Dictionary(grouping: matches, by: { $0.blockID }) {
                guard let (base, entry) = entryByBlock[blockID],
                      let contentOffset = entry.contentOffset,
                      var block = result.blocks[blockID]
                else { continue }

                let entryLength = entry.text.utf16.count
                // Keep only matches fully inside this block's own
                // `content`-backed span, converted to content-local
                // offsets; sort back-to-front.
                let localRanges: [(start: Int, end: Int)] = blockMatches
                    .compactMap { match -> (start: Int, end: Int)? in
                        let localStart = match.rangeStart - base
                        let localEnd = match.rangeEnd - base
                        guard localStart >= contentOffset, localEnd <= entryLength, localStart < localEnd else { return nil }
                        return (start: localStart - contentOffset, end: localEnd - contentOffset)
                    }
                    .sorted { $0.start > $1.start }
                guard !localRanges.isEmpty else { continue }

                block.content = spliceContent(block.content, replacing: localRanges, with: replacement)
                result.blocks[blockID] = block
                replacedCount += localRanges.count
                affectedBlockIDs.insert(blockID)
            }
        }

        let payload: [String: JSONValue] = [
            // DocReceiptType has no `doc_find_replace` case yet (see
            // DocumentSearchIndexTests / task openQuestions) - the
            // literal string travels as a payload field until a Store
            // wires the real receipt type.
            "receiptType": .string("doc_find_replace"),
            "query": .string(query),
            "replacement": .string(replacement),
            "caseSensitive": .bool(options.caseSensitive),
            "crossBlock": .bool(options.crossBlock),
            "replacedCount": .number(Double(replacedCount)),
            "blockIDs": .array(affectedBlockIDs.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) }),
        ]
        return (result, replacedCount, payload)
    }

    // MARK: - TextEntry (mirrors Doc.appendPlainText)

    /// One block's own contributed line, in the same depth-first order
    /// `Doc.appendPlainText` walks and with the same inclusion rules.
    private struct TextEntry {
        let blockID: UUID
        let text: String
        /// UTF-16 offset within `text` where `content`'s own text
        /// begins. `nil` when `text` isn't derived from `content` at
        /// all (`.shape` reads `shape.text.plainText` instead), so no
        /// splice into `content` is well-defined for a match here.
        let contentOffset: Int?
    }

    private static func locatedEntries(for ast: DocumentAST) -> [(entry: TextEntry, base: Int)] {
        var flat: [TextEntry] = []
        for id in ast.rootChildren {
            appendEntries(blockID: id, ast: ast, into: &flat)
        }
        var located: [(entry: TextEntry, base: Int)] = []
        located.reserveCapacity(flat.count)
        var offset = 0
        for (index, entry) in flat.enumerated() {
            located.append((entry: entry, base: offset))
            offset += entry.text.utf16.count
            if index < flat.count - 1 { offset += 1 } // the "\n" appendPlainText joins entries with
        }
        return located
    }

    /// Mirrors `Doc.appendPlainText` exactly (switch cases, the
    /// double-recursion-guard child loop, everything) plus per-entry
    /// blockID/contentOffset tracking `Doc.plainText(of:)` has no need
    /// for. Keep in sync by hand - `Doc.appendPlainText` is private.
    private static func appendEntries(blockID: UUID, ast: DocumentAST, into out: inout [TextEntry]) {
        guard let block = ast.blocks[blockID] else { return }
        switch block.type {
        case .paragraph, .heading, .quote, .listItem, .tableCell, .field:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(TextEntry(blockID: blockID, text: text, contentOffset: 0)) }
        case .codeBlock:
            let text = block.content.map { $0.text }.joined()
            if !text.isEmpty { out.append(TextEntry(blockID: blockID, text: text, contentOffset: 0)) }
        case .callout:
            var line = ""
            var prefixLength = 0
            if let emoji = block.attributes["emoji"]?.stringValue, !emoji.isEmpty {
                let prefix = emoji + " "
                line += prefix
                prefixLength = prefix.utf16.count
            }
            line += block.content.map { $0.text }.joined()
            if !line.isEmpty { out.append(TextEntry(blockID: blockID, text: line, contentOffset: prefixLength)) }
        case .list:
            for child in block.children { appendEntries(blockID: child, ast: ast, into: &out) }
        case .table:
            for child in block.children { appendEntries(blockID: child, ast: ast, into: &out) }
        case .shapeGroup, .section, .frame:
            for child in block.children { appendEntries(blockID: child, ast: ast, into: &out) }
        case .shape:
            if let text = block.shape?.text?.plainText, !text.isEmpty {
                out.append(TextEntry(blockID: blockID, text: text, contentOffset: nil))
            }
        case .toggle, .image, .chart, .divider, .equation, .comment, .trackInsertion, .trackDeletion, .footnote, .endnote, .media:
            break
        case .toc:
            // Derived entry paragraphs (heading text + cached page
            // number), not original prose - excluded from the search
            // index the same way .comment/.trackInsertion are, so it
            // doesn't index duplicate content twice.
            break
        }
        for child in block.children where block.type != .list && block.type != .table
            && block.type != .shapeGroup && block.type != .section && block.type != .frame
            && block.type != .toc {
            appendEntries(blockID: child, ast: ast, into: &out)
        }
    }

    // MARK: - String matching (UTF-16 offsets, this codebase's convention - see CodeBlockHighlighter.utf16Offset)

    private static func findAllRanges(of query: String, in text: String, caseSensitive: Bool) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound // non-overlapping matches
        }
        return ranges
    }

    private static func utf16Offset(_ index: String.Index, in s: String) -> Int {
        s.utf16.distance(from: s.utf16.startIndex, to: index)
    }

    // MARK: - Content splicing

    private static func spliceContent(
        _ content: [InlineRun],
        replacing localRanges: [(start: Int, end: Int)],
        with replacement: String
    ) -> [InlineRun] {
        var runs = content
        for range in localRanges {
            runs = splice(runs, start: range.start, end: range.end, with: replacement)
        }
        return runs
    }

    /// Replaces the UTF-16 range `[start, end)` of `runs`' concatenated
    /// text with `replacement`. Only the run(s) the range actually
    /// touches are split; every other run (and the untouched head/tail
    /// of a touched run) keeps its original annotations verbatim. The
    /// replacement text inherits the annotations of the run the range
    /// starts in.
    private static func splice(_ runs: [InlineRun], start: Int, end: Int, with replacement: String) -> [InlineRun] {
        guard start < end else { return runs }
        var result: [InlineRun] = []
        var cursor = 0
        var insertedReplacement = false
        for run in runs {
            let runLength = run.text.utf16.count
            let runStart = cursor
            let runEnd = cursor + runLength
            cursor = runEnd

            guard runEnd > start && runStart < end else {
                result.append(run)
                continue
            }

            let localStart = max(0, start - runStart)
            let localEnd = min(runLength, end - runStart)

            if localStart > 0 {
                result.append(InlineRun(text: utf16Substring(run.text, from: 0, to: localStart), annotations: run.annotations))
            }
            if !insertedReplacement {
                if !replacement.isEmpty {
                    result.append(InlineRun(text: replacement, annotations: run.annotations))
                }
                insertedReplacement = true
            }
            if localEnd < runLength {
                result.append(InlineRun(text: utf16Substring(run.text, from: localEnd, to: runLength), annotations: run.annotations))
            }
        }
        return result
    }

    private static func utf16Substring(_ s: String, from utf16Start: Int, to utf16End: Int) -> String {
        let start = String.Index(utf16Offset: utf16Start, in: s)
        let end = String.Index(utf16Offset: utf16End, in: s)
        return String(s[start..<end])
    }
}
