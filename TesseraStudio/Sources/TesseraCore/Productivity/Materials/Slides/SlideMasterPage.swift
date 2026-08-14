import Foundation

// MARK: - SlideMasterPage

/// A deck-level presentation theme: background + text color, shared
/// across every slide that references it via
/// ``SlideMeta/masterPageID``.
///
/// This is deliberately narrow. LibreOffice Impress's master-page
/// concept (`SdrPage`, see the slides design doc / gap-analysis row
/// 201) also carries shared placeholder shapes, page-number/footer
/// fields, and per-master transitions - those, plus the full
/// LO-catalog layout picker UI, are explicitly P1
/// (studio-expansion-plan.md's decision log, item 5). This ships the
/// piece a slide can already reference today: what to paint behind
/// it. `SlideDeckRenderer` (P1, not built yet) is what will actually
/// consult this - see `SlideDeck.masterPage(forSlideAt:)`'s doc
/// comment for the same "model ships before its live wiring" note
/// used throughout this phase's other P0 items.
public struct SlideMasterPage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// `#RRGGBB`, matching `SheetCellFormat.fillHex`'s convention.
    /// `nil` = the renderer's own default background.
    public var backgroundColorHex: String?
    /// `#RRGGBB` default text color for placeholder content painted
    /// on top of this master. `nil` = the renderer's own default.
    public var textColorHex: String?

    public init(
        id: UUID = UUID(),
        name: String,
        backgroundColorHex: String? = nil,
        textColorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.backgroundColorHex = backgroundColorHex
        self.textColorHex = textColorHex
    }
}

extension SlideDeck {
    /// `masterPages ?? [:]`, matching `effectiveNamedRanges`
    /// (`SheetNamedRange.swift`) and every other optional-dict
    /// field's "nil means none" convention in this codebase. Keyed by
    /// `id.uuidString` rather than `UUID` directly - `Dictionary`
    /// with a non-`String`/`Int` key encodes as a flat key/value array
    /// rather than a JSON object (see `DocumentAST`'s custom `Codable`
    /// for the same issue); every other UUID-identified dictionary in
    /// this codebase (`SlideDeck.slideMeta` included) sidesteps it the
    /// same way instead of adding a second custom `Codable`.
    public var effectiveMasterPages: [String: SlideMasterPage] {
        masterPages ?? [:]
    }

    /// A copy with `master` defined (or replaced, by matching `id`).
    public func settingMasterPage(_ master: SlideMasterPage) -> SlideDeck {
        var updated = self
        var pages = effectiveMasterPages
        pages[master.id.uuidString] = master
        updated.masterPages = pages
        return updated
    }

    /// A copy with the master page matching `id` removed, and every
    /// slide that referenced it falling back to no master (rather than
    /// a dangling id) - the same "clear on removal" invariant
    /// `SheetWorkbook.unload(_:)` keeps for named ranges.
    public func removingMasterPage(_ id: UUID) -> SlideDeck {
        var updated = self
        var pages = effectiveMasterPages
        pages.removeValue(forKey: id.uuidString)
        updated.masterPages = pages
        for key in updated.slideMeta.keys where updated.slideMeta[key]?.masterPageID == id {
            updated.slideMeta[key]?.masterPageID = nil
        }
        return updated
    }

    /// The master page assigned to the slide at `index`, or `nil` if
    /// that slide has none (or `index` is out of range, or the
    /// referenced id no longer resolves - a removed master leaves a
    /// slide with no master rather than a broken reference, per
    /// `removingMasterPage(_:)`).
    public func masterPage(forSlideAt index: Int) -> SlideMasterPage? {
        guard index >= 0, index < body.rootChildren.count else { return nil }
        let key = body.rootChildren[index].uuidString
        guard let masterID = slideMeta[key]?.masterPageID else { return nil }
        return effectiveMasterPages[masterID.uuidString]
    }
}
