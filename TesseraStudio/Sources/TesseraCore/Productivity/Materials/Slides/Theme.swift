import Foundation

// MARK: - ThemeColorSlot

/// The OOXML 12-slot color scheme vocabulary, verbatim -
/// `dk1`/`lt1`/`dk2`/`lt2`/`accent1`-`accent6`/`hlink`/`folHlink`. LO
/// 7.6 ships exactly this subset (no `fmtScheme`) and round-trips;
/// see the design doc's Slides cluster, item 1.5.
public enum ThemeColorSlot: String, Codable, Sendable, Hashable, CaseIterable {
    case dk1, lt1, dk2, lt2
    case accent1, accent2, accent3, accent4, accent5, accent6
    case hlink, folHlink
}

// MARK: - ColorRef

/// A color that either paints literally or resolves against a
/// ``Theme``. Adopted by ``SlideMasterPage/backgroundColorHex`` (P1
/// 1.5) - `InlineRun` colors stay `.literal`-only (a bare hex string,
/// unchanged) at P1, so a theme swap never needs to rewrite a block
/// body.
public enum ColorRef: Codable, Sendable, Hashable {
    /// `#RRGGBB` or `#RRGGBBAA`, same convention as `ShapeFill.colorHex`
    /// / `SlideMasterPage.backgroundColorHex` before this evolution.
    case literal(String)
    /// A theme slot, tinted `-1` (full shade/darken) ... `0` (no
    /// adjustment) ... `1` (full tint/lighten) - matches OOXML's
    /// `lumMod`/`lumOff` convention IN SPIRIT ONLY: the exact OOXML
    /// tint math is out of scope for P1. `Theme.resolve(_:)` applies
    /// a simple linear blend toward black/white by `abs(tint)`
    /// instead.
    case theme(slot: ThemeColorSlot, tint: Double)
}

extension ColorRef: ExpressibleByStringLiteral {
    /// Lets a call site write `"#RRGGBB"` directly where a `ColorRef`
    /// is expected (`== .literal("#RRGGBB")`) - keeps every
    /// pre-existing literal-hex call site (and test) that assigns a
    /// bare string into what is now a `ColorRef` field
    /// source-compatible with this evolution.
    public init(stringLiteral value: String) {
        self = .literal(value)
    }
}

// MARK: - Theme

/// A named OOXML-vocabulary color + font scheme a deck's master pages
/// can resolve `ColorRef.theme` slots against (P1 1.5). Major/minor
/// fonts + the 12-slot palette only - `fmtScheme` (fill/line/effect
/// styles) is skipped per the design doc, matching what LO 7.6
/// itself round-trips.
public struct Theme: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// Hex per slot. Partial and complete themes both resolve every
    /// slot: a missing entry falls back to `Theme.builtinDefault(for:)`
    /// rather than failing to resolve.
    ///
    /// Keyed by `ThemeColorSlot` directly rather than `.rawValue`,
    /// unlike this codebase's usual convention of avoiding non-
    /// `String`/`Int` dictionary keys for JSON-shape reasons
    /// (`SlideMasterPage.swift`'s `effectiveMasterPages` doc comment
    /// explains why UUID keys use `.uuidString`): the on-disk shape
    /// here is a flat array, not a keyed object, but the vocabulary
    /// is a closed 12-name set internal to this file, not an external
    /// interop surface, so that tradeoff doesn't bite here.
    public var colors: [ThemeColorSlot: String]
    public var majorFont: String
    public var minorFont: String

    public init(
        id: UUID = UUID(),
        name: String,
        colors: [ThemeColorSlot: String] = [:],
        majorFont: String = "Calibri Light",
        minorFont: String = "Calibri"
    ) {
        self.id = id
        self.name = name
        self.colors = colors
        self.majorFont = majorFont
        self.minorFont = minorFont
    }

    /// Resolve `ref` to a `#RRGGBB`/`#RRGGBBAA` hex string. `.literal`
    /// returns its string as-is; `.theme` looks up `colors[slot]` (or
    /// `builtinDefault(for:)` if absent) and blends it toward
    /// black/white by `tint` - see `ColorRef.theme`'s doc comment for
    /// why this is a simplification of OOXML's real tint math.
    public func resolve(_ ref: ColorRef) -> String {
        switch ref {
        case .literal(let hex):
            return hex
        case .theme(let slot, let tint):
            let base = colors[slot] ?? Self.builtinDefault(for: slot)
            return Self.blend(base, tint: tint)
        }
    }

    /// The palette an unset slot resolves to - the stock "Office"
    /// default theme colors (Office 2013+), a well-known public
    /// palette and the closest thing to a neutral P1 default.
    public static func builtinDefault(for slot: ThemeColorSlot) -> String {
        switch slot {
        case .dk1: return "#000000"
        case .lt1: return "#FFFFFF"
        case .dk2: return "#44546A"
        case .lt2: return "#E7E6E6"
        case .accent1: return "#4472C4"
        case .accent2: return "#ED7D31"
        case .accent3: return "#A5A5A5"
        case .accent4: return "#FFC000"
        case .accent5: return "#5B9BD5"
        case .accent6: return "#70AD47"
        case .hlink: return "#0563C1"
        case .folHlink: return "#954F72"
        }
    }

    // MARK: - Tint blend

    /// `tint == 0` returns `hex` untouched (not round-tripped through
    /// parse/format) so an unadjusted resolve preserves the exact
    /// case/form the theme author wrote, matching `.literal`'s own
    /// as-is behavior.
    private static func blend(_ hex: String, tint: Double) -> String {
        let clamped = max(-1, min(1, tint))
        guard clamped != 0, let rgba = parseHex(hex) else { return hex }
        let target = clamped > 0 ? 1.0 : 0.0
        let amount = abs(clamped)
        return formatHex(
            r: rgba.r + (target - rgba.r) * amount,
            g: rgba.g + (target - rgba.g) * amount,
            b: rgba.b + (target - rgba.b) * amount,
            a: rgba.a
        )
    }

    private static func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return (
                Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255,
                1
            )
        }
        return (
            Double((value >> 24) & 0xFF) / 255,
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private static func formatHex(r: Double, g: Double, b: Double, a: Double) -> String {
        let ri = byte(r), gi = byte(g), bi = byte(b)
        guard a < 1 else {
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        }
        return String(format: "#%02X%02X%02X%02X", ri, gi, bi, byte(a))
    }

    private static func byte(_ v: Double) -> Int {
        Int((max(0, min(1, v)) * 255).rounded())
    }
}
