import Foundation

// MARK: - AnimationTrigger

/// When a slide-show animation effect starts, relative to the click
/// stream and the effect immediately before it in play order. Mirrors
/// SMIL/OOXML's three `p:cond` timing shapes for a click-driven
/// sequence - see ``AnimationEffectList``'s header for the P2 tree
/// this vocabulary maps onto.
public enum AnimationTrigger: String, Codable, Sendable, Hashable, CaseIterable {
    /// Starts a new group: waits for the next click (or "advance")
    /// during slide show playback.
    case onClick
    /// Starts at the same instant as the effect immediately before it
    /// in array order. Never legal as the first effect in a list -
    /// there is nothing before it to start with.
    case withPrevious
    /// Starts when the effect immediately before it in array order
    /// finishes. Never legal as the first effect in a list, for the
    /// same reason as ``withPrevious``.
    case afterPrevious
}

// MARK: - AnimationEffect

/// One entrance/emphasis/exit effect applied to a slide block during
/// playback. `targetBlockID`, `presetID`, `trigger`, `durationMS`,
/// `delayMS` - the exact field set the P1 design contract names for
/// item 1.20 (studio-expansion-design-refinement-2026-08-14.md,
/// Slides cluster).
public struct AnimationEffect: Codable, Sendable, Hashable {
    public var targetBlockID: UUID
    /// Which catalog preset plays (fly-in, fade, wipe, ...). Not
    /// validated against a catalog here - presets are a P2 concern
    /// once ``SMILAnimationTree`` exists to carry the richer
    /// per-preset parameters SMIL supports; P1 stores the id as an
    /// opaque string, matching how `presetID`-shaped references are
    /// deferred elsewhere in this wave (e.g. transition ids).
    public var presetID: String
    public var trigger: AnimationTrigger
    public var durationMS: Int
    public var delayMS: Int

    public init(
        targetBlockID: UUID,
        presetID: String,
        trigger: AnimationTrigger,
        durationMS: Int,
        delayMS: Int
    ) {
        self.targetBlockID = targetBlockID
        self.presetID = presetID
        self.trigger = trigger
        self.durationMS = durationMS
        self.delayMS = delayMS
    }
}

// MARK: - AnimationEffectList

/// The play-order-flattened animation list for one slide
/// (studio-expansion-design-refinement-2026-08-14.md, Slides cluster,
/// item 1.20). Array position IS play order - there is no separate
/// order field on ``AnimationEffect``, and nothing about this type
/// may be reordered without changing what plays when.
///
/// **Why flat, and how a P2 tree recovers from it losslessly.**
/// LO Impress / OOXML model slide animation as a two-level SMIL tree:
/// `mainSeq` is a sequence of click-triggered groups, and each group
/// is one `.onClick` effect plus zero or more `.withPrevious` /
/// `.afterPrevious` followers that ride along with it (or immediately
/// after it) without waiting for another click. This flat list is
/// PROVABLY that tree's pre-order flattening, under one grouping
/// rule:
///
///   - every `.onClick` effect starts a new group
///   - every `.withPrevious` / `.afterPrevious` effect belongs to the
///     group opened by the nearest preceding `.onClick` effect (in
///     array order) - i.e. it is a follower of whatever group is
///     "currently open" when it is reached
///   - a non-empty list's first effect must be `.onClick` (a
///     follower with nothing preceding it has no group to join)
///
/// That rule is exactly what makes the P2 constructor
/// `SMILAnimationTree(flat: AnimationEffectList)` total - every value
/// this type can hold maps to exactly one tree - with
/// `tree.flattened()` as its left inverse
/// (`SMILAnimationTree(flat: tree.flattened())` reproduces `tree`).
/// Neither `SMILAnimationTree` nor the constructor exists yet - that
/// is P2's job - but this type's shape is fixed today so that
/// evolution is additive: the pinned fixture
/// `Fixtures/animation-effect-list-p1.json` and its byte-identical
/// re-encode test are the load-compat contract, and
/// `AnimationEffectListTests.testSMILAnimationTreeFlatInitializerWillExist`
/// pins the constructor's name ahead of its P2 implementation.
public typealias AnimationEffectList = [AnimationEffect]
