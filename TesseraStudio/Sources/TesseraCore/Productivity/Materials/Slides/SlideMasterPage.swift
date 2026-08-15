import Foundation

// MARK: - SlideMasterPage

/// A deck-level presentation master: background + text color, shared
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
///
/// `backgroundColorHex` resolves through ``ColorRef`` as of P1 1.5: a
/// `.literal` value paints as-is; a `.theme` value resolves against
/// this master's theme catalog / active theme (`themeCatalog` /
/// `activeThemeID` below) via ``Theme/resolve(_:)``. See
/// ``ThemeStore``'s doc comment for why deck-level theme state is
/// mirrored per-master here rather than living on `SlideDeck` itself.
public struct SlideMasterPage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// `.literal("#RRGGBB")` or a `.theme` slot reference (P1 1.5).
    /// `nil` = the renderer's own default background. The `.literal`
    /// case keeps `SheetCellFormat.fillHex`'s hex-string convention.
    public var backgroundColorHex: ColorRef?
    /// `#RRGGBB` default text color for placeholder content painted
    /// on top of this master. `nil` = the renderer's own default.
    /// Stays a plain literal hex string at P1 - only master
    /// backgrounds and Shape fills adopt `ColorRef` per the design
    /// doc's Slides cluster, item 1.5.
    public var textColorHex: String?
    /// The deck's theme catalog (P1 1.5), keyed by `Theme.id.uuidString`
    /// - mirrored identically onto every master page in the owning
    /// deck by `ThemeStore` (see its doc comment). `nil`/empty = no
    /// theme defined yet, matching `masterPages ?? [:]`'s convention.
    public var themeCatalog: [String: Theme]?
    /// The catalog entry (by id) active for the deck, mirrored the
    /// same way `themeCatalog` is. `nil` = no active theme; `.theme`
    /// slots then resolve against `Theme.builtinDefault(for:)`.
    public var activeThemeID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        backgroundColorHex: ColorRef? = nil,
        textColorHex: String? = nil,
        themeCatalog: [String: Theme]? = nil,
        activeThemeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.backgroundColorHex = backgroundColorHex
        self.textColorHex = textColorHex
        self.themeCatalog = themeCatalog
        self.activeThemeID = activeThemeID
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

    // MARK: - Theme (P1 1.5)

    /// The deck's theme catalog. Reads from (any) one master page
    /// rather than a `SlideDeck` field of its own - see
    /// ``SlideMasterPage/themeCatalog``'s doc comment and
    /// ``ThemeStore``'s for why. Empty when the deck has no master
    /// pages yet, or none has defined a theme.
    public var effectiveThemes: [String: Theme] {
        effectiveMasterPages.values.first?.themeCatalog ?? [:]
    }

    /// A copy with `theme` defined (or replaced, by matching `id`) in
    /// the catalog, mirroring `settingMasterPage(_:)`'s shape. The
    /// updated catalog is written onto every existing master page
    /// (see `ThemeStore`'s doc comment for why); a deck with no
    /// master pages is returned unchanged - `ThemeStore` is expected
    /// to have already rejected that case before calling this.
    public func settingTheme(_ theme: Theme) -> SlideDeck {
        var updated = self
        var catalog = effectiveThemes
        catalog[theme.id.uuidString] = theme
        var pages = effectiveMasterPages
        for key in pages.keys { pages[key]?.themeCatalog = catalog }
        updated.masterPages = pages
        return updated
    }

    /// The deck's active theme id, read the same way `effectiveThemes` is.
    public var activeThemeID: UUID? {
        effectiveMasterPages.values.first?.activeThemeID
    }

    /// The resolved active theme, or `nil` when unset or the id no
    /// longer resolves in the catalog (a removed/never-defined theme
    /// leaves the deck with no active theme rather than a broken
    /// reference, matching `removingMasterPage(_:)`'s "clear on
    /// removal" precedent).
    public var activeTheme: Theme? {
        activeThemeID.flatMap { effectiveThemes[$0.uuidString] }
    }

    /// A copy with the deck's active theme set (or cleared, with
    /// `themeID: nil`), mirrored onto every master page the same way
    /// `settingTheme(_:)` mirrors the catalog.
    public func settingActiveThemeID(_ themeID: UUID?) -> SlideDeck {
        var updated = self
        var pages = effectiveMasterPages
        for key in pages.keys { pages[key]?.activeThemeID = themeID }
        updated.masterPages = pages
        return updated
    }
}
