import Foundation

// MARK: - TransitionEngine

/// How a ``TransitionSpec`` actually renders (refinement doc section 4,
/// Slides cluster, item 1.6). Three tiers:
///
///   - `.tween`: a plain 2D animation (crossfade, directional wipe,
///     push/cover) - cheap, no stencil, no GPU shader.
///   - `.mask`: a shape-reveal transition (circle, diamond, wheel,
///     checkerboard, blinds, wedge, ...) driven by a stencil, still
///     CPU-cheap.
///   - `.gpu`: 3D / particle / shader-class effects. 2.19's split
///     between a CoreImage path and a Metal path is an implementation
///     detail INSIDE this tier - one vocabulary, no second store - so
///     the case carries no CoreImage-vs-Metal choice today. Until 2.19
///     lands, every `.gpu` preset renders its declared `fallbackID`
///     honestly: a wrong "cube" is worse than a declared fade.
public enum TransitionEngine: Codable, Sendable, Hashable {
    case tween
    case mask
    /// `presetID` names the GPU-side technique 2.19 will dispatch on
    /// (kept distinct from the owning `TransitionSpec.id` so the
    /// CoreImage/Metal split can pick an implementation without
    /// touching the catalog's id vocabulary; today it is set equal to
    /// the spec's own id since no such split exists yet).
    ///
    /// `fallbackID` is REQUIRED, not optional, so a `.gpu` case with no
    /// declared fallback is unrepresentable at the type level rather
    /// than a runtime check someone could forget. It MUST resolve to
    /// another entry's `id` in the SAME catalog - enforced by
    /// ``TransitionCatalog/validate(_:)`` at first access, not just
    /// documented here.
    case gpu(presetID: String, fallbackID: String)
}

// MARK: - TransitionSpec

/// One entry in the transition catalog (refinement doc section 4,
/// Slides cluster, item 1.6): a named preset an Impress-parity deck can
/// assign to a slide via ``TransitionStore``.
public struct TransitionSpec: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let engine: TransitionEngine
    public let durationDefaultMS: Int
    /// The OOXML `p:transition` child element name (`CT_SlideTransition`
    /// / `EG_SlideTransition`, e.g. "fade", "cut", "wipe") this preset
    /// maps from/to on import/export. `nil` for LibreOffice-only
    /// presets with no direct OOXML equivalent.
    public let ooxmlTag: String?

    public init(
        id: String,
        name: String,
        engine: TransitionEngine,
        durationDefaultMS: Int,
        ooxmlTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.durationDefaultMS = durationDefaultMS
        self.ooxmlTag = ooxmlTag
    }
}

// MARK: - TransitionCatalogError

public enum TransitionCatalogError: Error, Sendable, Equatable {
    /// A `.gpu` entry's `fallbackID` does not name any entry's `id` in
    /// the same catalog.
    case danglingFallback(gpuID: String, fallbackID: String)
    /// Two entries share the same `id`.
    case duplicateID(String)
    /// Two entries share the same non-nil `ooxmlTag`.
    case duplicateOOXMLTag(String)
}

// MARK: - TransitionCatalog

/// The static transition catalog (refinement doc section 4, Slides
/// cluster, item 1.6): OOXML's 20 canonical `p:transition` children
/// plus LibreOffice-only extras, ~34 entries total.
///
/// Embedded as a Swift literal rather than a bundled JSON resource:
/// `TesseraCore`'s `Package.swift` target ships only `Skills/README.md`
/// as a resource today, and this deliverable's file list does not
/// include `Package.swift` (shared checkout, parallel batch agents) -
/// adding a second `resources:` entry is out of scope here. See
/// ``entries`` for the data; the shape (id/name/engine/duration/
/// ooxmlTag) is exactly what a JSON-backed catalog would decode into,
/// so swapping to a bundled resource later is a mechanical change.
public enum TransitionCatalog {

    /// Every catalog entry. Validated once at first access -
    /// ``validate(_:)`` runs as a precondition here so a dangling
    /// `.gpu` fallback or a duplicate id/ooxmlTag fails loudly at
    /// catalog-construction time rather than shipping silently and
    /// only being caught by whichever test happens to exercise it.
    public static let entries: [TransitionSpec] = {
        let specs = Self.buildEntries()
        do {
            try Self.validate(specs)
        } catch {
            preconditionFailure("TransitionCatalog is malformed: \(error)")
        }
        return specs
    }()

    private static let byID: [String: TransitionSpec] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) }
    )

    private static let byOOXMLTag: [String: String] = {
        var out: [String: String] = [:]
        for spec in entries {
            guard let tag = spec.ooxmlTag else { continue }
            out[tag] = spec.id
        }
        return out
    }()

    /// The entry with this catalog id, or `nil` if `id` is not in the
    /// catalog.
    public static func spec(forID id: String) -> TransitionSpec? {
        byID[id]
    }

    /// The catalog id whose `ooxmlTag` is `tag`, or `nil` if no entry
    /// maps to it. ``TransitionCatalogError/duplicateOOXMLTag(_:)`` at
    /// construction time is what makes "exactly one" true here - this
    /// lookup would silently pick one of several otherwise.
    public static func id(forOOXMLTag tag: String) -> String? {
        byOOXMLTag[tag]
    }

    /// Every `.gpu` entry's `fallbackID` resolves to a real entry's
    /// `id` in `specs`, no two entries share an `id`, and no two
    /// entries share a non-nil `ooxmlTag`. Exposed as a free function
    /// over an arbitrary `[TransitionSpec]` (not just run internally
    /// against ``entries``) so tests can assert it directly against a
    /// catalog built for the test.
    public static func validate(_ specs: [TransitionSpec]) throws {
        var seenIDs: Set<String> = []
        var seenTags: Set<String> = []
        for spec in specs {
            guard seenIDs.insert(spec.id).inserted else {
                throw TransitionCatalogError.duplicateID(spec.id)
            }
            if let tag = spec.ooxmlTag {
                guard seenTags.insert(tag).inserted else {
                    throw TransitionCatalogError.duplicateOOXMLTag(tag)
                }
            }
        }
        let ids = Set(specs.map { $0.id })
        for spec in specs {
            guard case let .gpu(_, fallbackID) = spec.engine else { continue }
            guard ids.contains(fallbackID) else {
                throw TransitionCatalogError.danglingFallback(gpuID: spec.id, fallbackID: fallbackID)
            }
        }
    }

    // MARK: - Data

    /// OOXML tag names below are `EG_SlideTransition`'s child element
    /// names (ECMA-376 `CT_SlideTransition`) as best-verified from
    /// memory; genuinely uncertain ones are called out in the P1 1.6
    /// task report's openQuestions rather than guessed silently here.
    /// "checkerboard" is this catalog's (display-friendly) id; the
    /// wire-format tag itself is "checker".
    private static func buildEntries() -> [TransitionSpec] {
        [
            // MARK: OOXML canonical (20)
            TransitionSpec(id: "fade", name: "Fade", engine: .tween, durationDefaultMS: 700, ooxmlTag: "fade"),
            TransitionSpec(id: "cut", name: "Cut", engine: .tween, durationDefaultMS: 0, ooxmlTag: "cut"),
            TransitionSpec(id: "wipe", name: "Wipe", engine: .tween, durationDefaultMS: 700, ooxmlTag: "wipe"),
            TransitionSpec(id: "push", name: "Push", engine: .tween, durationDefaultMS: 700, ooxmlTag: "push"),
            TransitionSpec(id: "cover", name: "Cover", engine: .tween, durationDefaultMS: 700, ooxmlTag: "cover"),
            TransitionSpec(id: "pull", name: "Uncover", engine: .tween, durationDefaultMS: 700, ooxmlTag: "pull"),
            TransitionSpec(id: "dissolve", name: "Dissolve", engine: .tween, durationDefaultMS: 900, ooxmlTag: "dissolve"),
            TransitionSpec(id: "random", name: "Random", engine: .tween, durationDefaultMS: 700, ooxmlTag: "random"),
            TransitionSpec(id: "strips", name: "Strips", engine: .tween, durationDefaultMS: 800, ooxmlTag: "strips"),
            TransitionSpec(id: "split", name: "Split", engine: .tween, durationDefaultMS: 800, ooxmlTag: "split"),
            TransitionSpec(id: "circle", name: "Circle", engine: .mask, durationDefaultMS: 800, ooxmlTag: "circle"),
            TransitionSpec(id: "diamond", name: "Diamond", engine: .mask, durationDefaultMS: 800, ooxmlTag: "diamond"),
            TransitionSpec(id: "wheel", name: "Wheel", engine: .mask, durationDefaultMS: 900, ooxmlTag: "wheel"),
            TransitionSpec(id: "checkerboard", name: "Checkerboard", engine: .mask, durationDefaultMS: 900, ooxmlTag: "checker"),
            TransitionSpec(id: "blinds", name: "Blinds", engine: .mask, durationDefaultMS: 800, ooxmlTag: "blinds"),
            TransitionSpec(id: "wedge", name: "Wedge", engine: .mask, durationDefaultMS: 800, ooxmlTag: "wedge"),
            TransitionSpec(id: "plus", name: "Plus", engine: .mask, durationDefaultMS: 800, ooxmlTag: "plus"),
            TransitionSpec(id: "randomBar", name: "Random Bars", engine: .mask, durationDefaultMS: 800, ooxmlTag: "randomBar"),
            TransitionSpec(id: "comb", name: "Comb", engine: .mask, durationDefaultMS: 800, ooxmlTag: "comb"),
            TransitionSpec(
                id: "newsflash", name: "Newsflash",
                engine: .gpu(presetID: "newsflash", fallbackID: "fade"),
                durationDefaultMS: 1000, ooxmlTag: "newsflash"
            ),

            // MARK: LibreOffice extras (14) - no direct OOXML equivalent.
            TransitionSpec(id: "barWipeHorizontal", name: "Bar Wipe (Horizontal)", engine: .tween, durationDefaultMS: 700),
            TransitionSpec(id: "barWipeVertical", name: "Bar Wipe (Vertical)", engine: .tween, durationDefaultMS: 700),
            TransitionSpec(id: "revolvingCircles", name: "Revolving Circles", engine: .mask, durationDefaultMS: 900),
            TransitionSpec(id: "barnDoor", name: "Barn Door", engine: .tween, durationDefaultMS: 700),
            TransitionSpec(id: "blindsDiagonal", name: "Diagonal Blinds", engine: .mask, durationDefaultMS: 800),
            TransitionSpec(
                id: "glitter", name: "Glitter",
                engine: .gpu(presetID: "glitter", fallbackID: "fade"),
                durationDefaultMS: 1200
            ),
            TransitionSpec(
                id: "honeycomb", name: "Honeycomb",
                engine: .gpu(presetID: "honeycomb", fallbackID: "checkerboard"),
                durationDefaultMS: 1200
            ),
            TransitionSpec(
                id: "vortex", name: "Vortex",
                engine: .gpu(presetID: "vortex", fallbackID: "wheel"),
                durationDefaultMS: 1200
            ),
            TransitionSpec(
                id: "rochade", name: "Rochade",
                engine: .gpu(presetID: "rochade", fallbackID: "push"),
                durationDefaultMS: 1200
            ),
            TransitionSpec(
                id: "cube", name: "Cube",
                engine: .gpu(presetID: "cube", fallbackID: "wipe"),
                durationDefaultMS: 1000
            ),
            TransitionSpec(
                id: "gallery", name: "Gallery",
                engine: .gpu(presetID: "gallery", fallbackID: "fade"),
                durationDefaultMS: 1000
            ),
            TransitionSpec(
                id: "shred", name: "Shred",
                engine: .gpu(presetID: "shred", fallbackID: "strips"),
                durationDefaultMS: 1200
            ),
            TransitionSpec(
                id: "staticNoise", name: "Static",
                engine: .gpu(presetID: "staticNoise", fallbackID: "dissolve"),
                durationDefaultMS: 1000
            ),
            TransitionSpec(
                id: "turningHelix", name: "Turning Helix",
                engine: .gpu(presetID: "turningHelix", fallbackID: "wheel"),
                durationDefaultMS: 1200
            ),
        ]
    }
}
