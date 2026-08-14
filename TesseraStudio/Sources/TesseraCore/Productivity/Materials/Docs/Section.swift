import Foundation

// MARK: - SectionKind

/// The break/container semantics a section carries. Mirrors LO's
/// `SwSectionData` kinds (`sw/source/core/docnode/section.cxx`) closely
/// enough to round-trip ODT/DOCX section breaks without losing which
/// kind of break produced the section.
public enum SectionKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// No page break - the section starts inline in the flow (a
    /// multi-column region within the current page).
    case continuous
    /// Starts a new page, single column.
    case singleColumn
    /// Starts on the next page.
    case nextPage
    /// Starts on the next even-numbered page.
    case evenPage
    /// Starts on the next odd-numbered page.
    case oddPage
    /// A container for an index/TOC - not itself flowed content.
    case indexContainer
}

// MARK: - DocumentSection

/// Column layout and break semantics for one `.section` block. Kept
/// separate from `DocumentPageLayout` (which stays the page-wide
/// default) rather than folding into it: a document can have several
/// sections with different column counts, so the per-section override
/// has to live somewhere sections themselves can be looked up by ID.
///
/// Named `DocumentSection` rather than the shorter `Section` because
/// this module imports SwiftUI throughout, and `SwiftUI.Section` (the
/// `Form`/`List` view builder) is already in scope everywhere - a
/// bare `Section` here would shadow it and silently break every
/// `Section { ... }` call site in the app's views.
public struct DocumentSection: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var kind: SectionKind
    public var columns: Int
    public var columnGap: Double
    /// Points into a future style registry (P1's `StyleRegistry`, see
    /// studio-expansion-plan.md capability #9); `nil` until that lands.
    public var linkedStyleID: UUID?

    public init(
        id: UUID = UUID(),
        kind: SectionKind = .continuous,
        columns: Int = 1,
        columnGap: Double = 18,
        linkedStyleID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.columns = columns
        self.columnGap = columnGap
        self.linkedStyleID = linkedStyleID
    }
}

// MARK: - SectionStore

/// Pure helpers over a `DocumentAST`'s section map
/// (`DocumentAST.meta.sections`). Not a persisted CRUD store with its
/// own receipts/view model - `.section` blocks are ordinary tree nodes
/// that live and undo alongside the rest of the document, the same way
/// `.list`/`.toggle` don't get their own store either. What's
/// store-shaped here is only the indirection from a block to its
/// shared `DocumentSection` value.
public enum SectionStore {
    /// Looks up the `DocumentSection` a `.section` block refers to via
    /// `attributes["sectionRef"]`.
    public static func section(for block: Block, in ast: DocumentAST) -> DocumentSection? {
        guard block.type == .section,
              let ref = block.attributes["sectionRef"]?.stringValue,
              let id = UUID(uuidString: ref) else { return nil }
        return ast.meta.sections[id]
    }

    /// Builds a `.section` block wrapping `children`, registering a new
    /// `DocumentSection` (or reusing `existingSectionID` to link multiple
    /// blocks to the same section identity - e.g. a section that
    /// continues across a page break) in `ast.meta.sections`.
    @discardableResult
    public static func makeSection(
        kind: SectionKind = .continuous,
        columns: Int = 1,
        columnGap: Double = 18,
        linkedStyleID: UUID? = nil,
        children: [UUID],
        parentID: UUID? = nil,
        existingSectionID: UUID? = nil,
        in ast: inout DocumentAST
    ) -> Block {
        let sectionID = existingSectionID ?? UUID()
        if ast.meta.sections[sectionID] == nil || existingSectionID == nil {
            ast.meta.sections[sectionID] = DocumentSection(
                id: sectionID, kind: kind, columns: columns,
                columnGap: columnGap, linkedStyleID: linkedStyleID
            )
        }
        var block = Block(type: .section, attributes: ["sectionRef": .string(sectionID.uuidString)], parentID: parentID)
        block.children = children
        return block
    }
}
