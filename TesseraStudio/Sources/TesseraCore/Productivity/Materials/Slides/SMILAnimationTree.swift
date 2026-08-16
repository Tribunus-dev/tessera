import Foundation

// MARK: - SMILAnimationTree
//
// P2 item 2.1 (studio-p2-implementation-plan-2026-08-15.md; design
// contract in .scratch/sota-p2-core-report.md section "2.1
// SMILAnimationTree"). Full evolution of the P1 flat
// ``AnimationEffectList`` interim (AnimationEffectList.swift, item
// 1.20) to the two-level-and-beyond SMIL/OOXML timing tree
// (`sd/source/core/CustomAnimationEffect.cxx`'s `XAnimationNode`
// model). Per decision 7 (no versioned implementations): the flat
// list is NOT replaced, it becomes the tree's serialization/
// projection (``flattened()``); ``SlideMeta`` stores both fields and
// prefers the tree on decode (see that type's own doc comment in
// SlideDeck.swift).
//
// Every associated-value case below relies on SE-0295's automatic
// `Codable` synthesis for enums with associated values (the design
// contract's own words: "SE-0295 Codable synthesis") - no custom
// `init(from:)`/`encode(to:)` is written for ``SMILNode`` or
// ``SMILBehavior``/``SMILCondition``, the compiler-generated
// per-case keyed containers ARE the wire format.

// MARK: - SMILNodeType

/// The 9 legal values of a SMIL/OOXML timing node's `nodeType`
/// (OOXML `p:cTn@nodeType` / ST_TLTimeNodeType; ODF
/// `presentation:node-type`), exactly as named in the 2.1 design
/// contract's type sketch. Fixed at exactly 9 cases - a totality/
/// coverage test pins this count against an INDEPENDENT hardcoded
/// list (testing-doctrine.md rule 7: "the 9 SMIL node types" is that
/// rule's own named example), never by iterating this enum's own
/// `allCases` to validate itself.
public enum SMILNodeType: String, Codable, Sendable, Hashable, CaseIterable {
    /// The tree's single root: a `.par` with no useful timing of its
    /// own, wrapping ``mainSeq`` (and, when present, top-level
    /// ``interactiveSeq`` nodes triggered by their own click targets).
    case tmRoot
    /// The click-driven backbone: a `.seq` whose children are
    /// ``clickPar`` groups, one per user-visible "advance".
    case mainSeq
    /// A `.seq` triggered by clicking a specific on-slide object
    /// rather than by the mainSeq's ordinary "next click" advance -
    /// the P2 subset beyond flat reconstruction (`AnimationEffectList`
    /// has no interactive-trigger concept at all).
    case interactiveSeq
    /// One click group inside ``mainSeq``: a `.par` whose first child
    /// is the effect that fires ON that click (``clickEffect``) and
    /// whose later children are ``withGroup``/``afterGroup`` wrappers
    /// for followers riding along with or after it.
    case clickPar
    /// Wraps one `.withPrevious`-triggered follower effect
    /// (``withEffect``) inside a ``clickPar`` group.
    case withGroup
    /// Wraps one `.afterPrevious`-triggered follower effect
    /// (``afterEffect``) inside a ``clickPar`` group.
    case afterGroup
    /// The behavior node that plays when its enclosing ``clickPar``
    /// group's click fires.
    case clickEffect
    /// The behavior node inside a ``withGroup`` wrapper.
    case withEffect
    /// The behavior node inside an ``afterGroup`` wrapper.
    case afterEffect
}

// MARK: - SMILCondition

/// One `smil:begin`/`p:cond`-shaped start condition. A ``SMILNode``'s
/// timing props carry a LIST of these (`SMILTimingProps.begin`)
/// because SMIL legally allows multiple sync-arcs on one node (e.g.
/// "on click OR after 5s, whichever first") even though every tree
/// this file's own constructors produce uses exactly zero or one.
public enum SMILCondition: Codable, Sendable, Hashable {
    /// No computable start time - the node waits to be triggered
    /// (an ``SMILNodeType/interactiveSeq``'s own begin, or a node
    /// whose start rides entirely on its parent's timing).
    case indefinite
    /// Starts `offsetMS` after the immediately preceding sibling
    /// (in the enclosing container's child order) ENDS.
    case afterPrevious(offsetMS: Int)
    /// Starts `offsetMS` after the immediately preceding sibling
    /// STARTS (or, with no preceding sibling, after the parent
    /// container starts).
    case withPrevious(offsetMS: Int)
    /// Starts `offsetMS` after a click - on `target` when given (an
    /// interactive trigger naming the object that must be clicked),
    /// or on the next ordinary "advance" click when `target` is nil
    /// (the ordinary ``SMILNodeType/clickPar`` group opener).
    case onClick(target: AnimationTarget?, offsetMS: Int)
    /// Starts exactly `offsetMS` after the enclosing parent
    /// container's own start - the plain numeric-offset case SMIL
    /// calls an "offset-value" begin, used here to carry
    /// ``AnimationEffect/delayMS`` once a node's group-opening
    /// condition (indefinite/afterPrevious/withPrevious/onClick) has
    /// already been chosen.
    case time(offsetMS: Int)
}

// MARK: - SMILRepeatCount

/// `smil:repeatCount`'s two legal shapes: a finite (possibly
/// fractional, per SMIL) repeat count, or the literal `"indefinite"`
/// keyword.
public enum SMILRepeatCount: Codable, Sendable, Hashable {
    case count(Double)
    case indefinite
}

// MARK: - SMILFill

/// `smil:fill` - what a node's target looks like once its active
/// duration ends. The 6 values ODF/SMIL3 both recognize.
public enum SMILFill: String, Codable, Sendable, Hashable, CaseIterable {
    case remove
    case freeze
    case hold
    case transition
    case auto
    case `default`
}

// MARK: - SMILRestart

/// `smil:restart` - whether a node can be restarted while already
/// active. The 4 values ODF/SMIL3 both recognize.
public enum SMILRestart: String, Codable, Sendable, Hashable, CaseIterable {
    case always
    case whenNotActive
    case never
    case `default`
}

// MARK: - AnimationTarget

/// What a behavior node animates: a block, optionally narrowed to one
/// of its paragraphs (the ``IterateSpec`` "by paragraph" case's
/// per-iteration target, or a plain per-paragraph text-build effect).
/// Exactly the two fields the design contract names.
public struct AnimationTarget: Codable, Sendable, Hashable {
    public var blockID: UUID
    public var paragraphIndex: Int?

    public init(blockID: UUID, paragraphIndex: Int? = nil) {
        self.blockID = blockID
        self.paragraphIndex = paragraphIndex
    }
}

// MARK: - IterateSpec

/// `anim:iterate`'s own shape: what unit of the target's content gets
/// its own staggered copy of the wrapped behaviors, and how far apart
/// (`anim:iterate-interval`) each copy starts from the last.
public struct IterateSpec: Codable, Sendable, Hashable {
    public enum IterateType: String, Codable, Sendable, Hashable, CaseIterable {
        case byParagraph
        case byWord
        case byLetter
    }

    public var type: IterateType
    public var intervalMS: Int

    public init(type: IterateType = .byParagraph, intervalMS: Int = 0) {
        self.type = type
        self.intervalMS = intervalMS
    }
}

// MARK: - SMILBehavior

/// The 9 leaf behaviors a ``SMILNode/behavior(_:target:_:)`` node can
/// carry, exactly as named in the design contract's type sketch.
/// `.animateEffect` is Tessera's name for ODF's `anim:transitionFilter`
/// / OOXML's `p:animEffect` (the entrance/exit/emphasis preset-driven
/// behavior, as opposed to `.animate`'s raw attribute tweening) -
/// named to match the contract's own case list rather than either
/// format's element name.
public enum SMILBehavior: Codable, Sendable, Hashable {
    case animate(attributeName: String, values: [String], from: String?, to: String?, by: String?)
    case set(attributeName: String, to: String)
    case animateMotion(svgPath: String)
    case animateColor(attributeName: String, from: String?, to: String?, colorInterpolation: String?)
    case animateTransform(transformType: String, from: String?, to: String?, by: String?)
    case animateEffect(transitionType: String, subtype: String?, direction: String?)
    case audio(source: String?)
    case video(source: String?)
    case command(commandType: String, value: String?)
}

// MARK: - SMILTimingProps

/// The timing/behavior metadata every ``SMILNode`` case carries,
/// exactly the field list the design contract names.
public struct SMILTimingProps: Codable, Sendable, Hashable {
    public var nodeType: SMILNodeType
    public var begin: [SMILCondition]
    public var durationMS: Int?
    public var repeatCount: SMILRepeatCount?
    public var autoReverse: Bool
    public var accelerate: Double
    public var decelerate: Double
    public var fill: SMILFill
    public var restart: SMILRestart
    public var presetClass: String?
    public var presetID: String?

    public init(
        nodeType: SMILNodeType,
        begin: [SMILCondition] = [],
        durationMS: Int? = nil,
        repeatCount: SMILRepeatCount? = nil,
        autoReverse: Bool = false,
        accelerate: Double = 0,
        decelerate: Double = 0,
        fill: SMILFill = .auto,
        restart: SMILRestart = .always,
        presetClass: String? = nil,
        presetID: String? = nil
    ) {
        self.nodeType = nodeType
        self.begin = begin
        self.durationMS = durationMS
        self.repeatCount = repeatCount
        self.autoReverse = autoReverse
        self.accelerate = accelerate
        self.decelerate = decelerate
        self.fill = fill
        self.restart = restart
        self.presetClass = presetClass
        self.presetID = presetID
    }

    /// `presetClass` sentinel a fodp importer stamps on a `.par` node
    /// that was actually parsed from `anim:excl` (SMIL's "exclusive"
    /// time container - the design contract's "excl: parse-and-
    /// preserve as flagged par"). `SMILNode` deliberately has no 10th
    /// case for it (the 9-value ``SMILNodeType`` totality guard, rule
    /// 7, would then have to grow to 10 everywhere it's pinned) - a
    /// flagged `.par` round-trips the container back to `anim:excl`
    /// on export (see `LOBridgeDeckIO.mapAnimationTree(fromPage:...)`)
    /// without corrupting a real preset-class value, since no genuine
    /// ODF `presentation:preset-class` is ever spelled this way.
    /// Recorded as a P2 design-judgment call in this wave's findings
    /// file (excl is rare - PowerPoint's own UI barely exposes it -
    /// and no test-list item required more than parse-and-preserve).
    public static let exclMarkerPresetClass = "tessera:excl-container"
}

// MARK: - SMILNode

/// One node of the SMIL timing tree. `indirect` because `.par`/`.seq`/
/// `.iterate` recurse into `[SMILNode]`.
public indirect enum SMILNode: Codable, Sendable, Hashable {
    case par(SMILTimingProps, children: [SMILNode])
    case seq(SMILTimingProps, children: [SMILNode])
    case iterate(SMILTimingProps, IterateSpec, children: [SMILNode])
    case behavior(SMILTimingProps, target: AnimationTarget, SMILBehavior)
}

extension SMILNode {
    /// This node's ``SMILTimingProps``, regardless of case - every
    /// case carries exactly one.
    public var timingProps: SMILTimingProps {
        switch self {
        case .par(let props, _): return props
        case .seq(let props, _): return props
        case .iterate(let props, _, _): return props
        case .behavior(let props, _, _): return props
        }
    }

    /// This node's children, or `[]` for a leaf ``behavior`` node.
    public var childNodes: [SMILNode] {
        switch self {
        case .par(_, let children): return children
        case .seq(_, let children): return children
        case .iterate(_, _, let children): return children
        case .behavior: return []
        }
    }
}

// MARK: - SMILAnimationTree

/// The P2 evolution of the P1 flat ``AnimationEffectList`` (item
/// 1.20). See this file's header for the decision-7 relationship
/// between the two.
public struct SMILAnimationTree: Codable, Sendable, Hashable {
    /// Always a `.par` with `nodeType == .tmRoot`.
    public var root: SMILNode

    public init(root: SMILNode) {
        self.root = root
    }

    // MARK: flat -> tree (TOTAL)

    /// Builds the tree that reproduces `flat` when re-flattened via
    /// ``flattened()``, for every LEGAL flat list (the grouping rule
    /// `AnimationEffectList.swift`'s header states: every `.onClick`
    /// effect opens a new group; every `.withPrevious`/`.afterPrevious`
    /// effect joins the group most recently opened; a legal non-empty
    /// list's first effect is `.onClick`).
    ///
    /// TOTAL: an illegal leading `.withPrevious`/`.afterPrevious` (no
    /// group open yet to join) does not throw or trap - it opens an
    /// implicit group instead, exactly as though it were `.onClick`
    /// (its OWN `trigger` value is not consulted for group-boundary
    /// purposes when no group is open; only `groups.isEmpty` decides
    /// the boundary in that case). `flattened()` then reports that
    /// synthesized group's head effect back as `.onClick` regardless
    /// of what the illegal input's first element's `trigger` actually
    /// was - a correct outcome for illegal input (which by
    /// definition cannot round-trip byte-for-byte through a type
    /// whose invariant it violates), not a bug in the identity
    /// property, which is stated only for LEGAL lists.
    public init(flat: AnimationEffectList) {
        var groups: [[AnimationEffect]] = []
        for effect in flat {
            if effect.trigger == .onClick || groups.isEmpty {
                groups.append([effect])
            } else {
                groups[groups.count - 1].append(effect)
            }
        }
        let groupNodes = groups.map { Self.buildGroup($0) }
        let mainSeq = SMILNode.seq(SMILTimingProps(nodeType: .mainSeq), children: groupNodes)
        self.root = .par(SMILTimingProps(nodeType: .tmRoot), children: [mainSeq])
    }

    private static func buildGroup(_ effects: [AnimationEffect]) -> SMILNode {
        var children: [SMILNode] = []
        for (i, effect) in effects.enumerated() {
            let begin: [SMILCondition] = effect.delayMS != 0 ? [.time(offsetMS: effect.delayMS)] : []
            if i == 0 {
                // The group's head ALWAYS becomes .clickEffect - see
                // the totality note above for why this holds even for
                // an illegal leading follower.
                let props = SMILTimingProps(
                    nodeType: .clickEffect, begin: begin,
                    durationMS: effect.durationMS, presetID: effect.presetID)
                children.append(Self.behaviorNode(props: props, effect: effect))
            } else if effect.trigger == .afterPrevious {
                let innerProps = SMILTimingProps(
                    nodeType: .afterEffect, begin: begin,
                    durationMS: effect.durationMS, presetID: effect.presetID)
                let wrapperProps = SMILTimingProps(nodeType: .afterGroup, begin: [.afterPrevious(offsetMS: 0)])
                children.append(.par(wrapperProps, children: [Self.behaviorNode(props: innerProps, effect: effect)]))
            } else {
                let innerProps = SMILTimingProps(
                    nodeType: .withEffect, begin: begin,
                    durationMS: effect.durationMS, presetID: effect.presetID)
                let wrapperProps = SMILTimingProps(nodeType: .withGroup, begin: [.withPrevious(offsetMS: 0)])
                children.append(.par(wrapperProps, children: [Self.behaviorNode(props: innerProps, effect: effect)]))
            }
        }
        let groupProps = SMILTimingProps(nodeType: .clickPar, begin: [.onClick(target: nil, offsetMS: 0)])
        return .par(groupProps, children: children)
    }

    private static func behaviorNode(props: SMILTimingProps, effect: AnimationEffect) -> SMILNode {
        .behavior(
            props,
            target: AnimationTarget(blockID: effect.targetBlockID),
            .animateEffect(transitionType: effect.presetID, subtype: nil, direction: nil)
        )
    }

    // MARK: tree -> flat (left inverse on legal lists)

    /// Re-derives the play-order-flattened effect list from this
    /// tree. Walks `root -> mainSeq -> [clickPar groups] -> [behavior
    /// | (with/after)Group-wrapped behavior]`, the exact shape
    /// ``init(flat:)`` builds - so for any tree built that way,
    /// `tree.flattened() == flat` (the design contract's "left
    /// inverse" property). A tree with a different shape (e.g. one
    /// imported from a real fodp document with richer content -
    /// `interactiveSeq` siblings, `iterate` nodes, non-`.animateEffect`
    /// behaviors) degrades gracefully: anything ``flattened()``
    /// cannot map onto the flat vocabulary is simply omitted rather
    /// than mis-mapped, since `AnimationEffectList` itself has no
    /// slot to hold it.
    public func flattened() -> AnimationEffectList {
        guard case let .par(rootProps, rootChildren) = root, rootProps.nodeType == .tmRoot else { return [] }
        guard let mainSeqNode = rootChildren.first(where: { $0.timingProps.nodeType == .mainSeq }),
              case .seq = mainSeqNode else { return [] }
        var out: AnimationEffectList = []
        for group in mainSeqNode.childNodes {
            guard case let .par(groupProps, groupChildren) = group, groupProps.nodeType == .clickPar else { continue }
            for (i, child) in groupChildren.enumerated() {
                if i == 0 {
                    guard case let .behavior(props, target, _) = child else { continue }
                    out.append(AnimationEffect(
                        targetBlockID: target.blockID,
                        presetID: props.presetID ?? "",
                        trigger: .onClick,
                        durationMS: props.durationMS ?? 0,
                        delayMS: Self.delay(from: props.begin)
                    ))
                } else {
                    guard case let .par(wrapperProps, wrapperChildren) = child,
                          let inner = wrapperChildren.first,
                          case let .behavior(props, target, _) = inner
                    else { continue }
                    let trigger: AnimationTrigger = wrapperProps.nodeType == .afterGroup ? .afterPrevious : .withPrevious
                    out.append(AnimationEffect(
                        targetBlockID: target.blockID,
                        presetID: props.presetID ?? "",
                        trigger: trigger,
                        durationMS: props.durationMS ?? 0,
                        delayMS: Self.delay(from: props.begin)
                    ))
                }
            }
        }
        return out
    }

    private static func delay(from begin: [SMILCondition]) -> Int {
        for condition in begin {
            if case let .time(offsetMS) = condition { return offsetMS }
        }
        return 0
    }
}
