//===----------------------------------------------------------------------===//
//  GPUTransitionRenderer.swift
//  Tessera Studio
//
//  Item 2.19 (GPU transitions - the gpu engine tier of TransitionSpec,
//  design refinement doc section 5). TransitionSpec.swift's own doc
//  comment on TransitionEngine.gpu already settles the CoreImage-vs-
//  Metal split as "an implementation detail INSIDE this tier - one
//  vocabulary, no second store"; this file exercises that latitude by
//  realizing every one of the catalog's 10 `.gpu` presets through two
//  substrates, neither of which needs a live Metal device to construct
//  OR to unit-test:
//
//    - Transform3DTransitionMath: pure per-progress CATransform3D
//      parameters (rotation angle, translate, perspective m34) for the
//      3 presets that are fundamentally a rigid-layer 3D move (cube,
//      rochade, gallery) - consumed directly by a live CALayer/SwiftUI
//      `.rotation3DEffect` in the TesseraStudioMac playback view. No
//      pixel compositing happens in THIS file for these three.
//    - CoreImageTransitionMath + GPUTransitionRenderer: real CIFilter
//      pixel compositing for the 7 presets that are fundamentally a
//      2D image effect (newsflash, glitter, honeycomb, vortex, shred,
//      staticNoise, turningHelix) - the design contract's own "~5
//      custom Metal/SwiftUI-Shader presets" bucket is realized here via
//      CoreImage (CITwirlDistortion/CIHexagonalPixellate/procedural
//      compositing) rather than raw .metal shader source, a scope call
//      recorded in this wave's findings file (build-graph safety in a
//      4-way-parallel shared checkout with no Package.swift edit
//      available to any one track - see findings for the full
//      reasoning and the swap-in path if a real Metal kernel is wanted
//      later).
//
//  Every technique function is a PURE function of (progress, from, to):
//  no Date(), no real randomness (glitter's particle field is a fixed
//  seeded generator, not Swift's system RNG) - two independent calls at
//  the same progress produce byte-identical CIImage recipes (doctrine
//  rule 4). `GPUTransitionRenderer.renderFrame` ALWAYS returns the
//  spec's own presetID, even on its declared-fallback path (a `.gpu`
//  preset id this file has not implemented renders a plain crossfade
//  rather than a wrong visual, but never silently rewrites which preset
//  the caller asked for - the "wrong cube is worse than a declared
//  fade" rule from the design contract).
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import CoreImage
import QuartzCore

// MARK: - Transform3DTransitionMath

/// Pure CATransform3D-tier math for the 3 rigid-layer-move gpu presets
/// (cube, rochade, gallery). No CoreImage, no SceneKit, no GPU device -
/// every function here is arithmetic on `Double`, so it is testable
/// (and the "expected rotation angle at progress=0.5" content check the
/// design contract names explicitly) without ever creating a
/// `CATransform3D`, a layer, or a view.
public enum Transform3DTransitionMath {

    public struct CubeState: Sendable, Equatable {
        /// Degrees the OUTGOING face has rotated about its own vertical
        /// (Y) edge, 0 (facing the viewer) ... -90 (edge-on, rotated
        /// away).
        public let outgoingRotationDegrees: Double
        /// Degrees the INCOMING face has left to rotate, 90 (edge-on,
        /// about to swing in) ... 0 (facing the viewer).
        public let incomingRotationDegrees: Double
    }

    /// The classic PowerPoint/Keynote "Cube" transition: the outgoing
    /// slide is one face of a cube rotating away (0 -> -90 degrees)
    /// while the incoming slide is the adjacent face rotating into
    /// view (90 -> 0 degrees) - the two faces meet edge-on at the
    /// cube's shared vertical edge when `progress == 0.5`.
    public static func cube(progress: Double) -> CubeState {
        let p = clamp(progress)
        return CubeState(
            outgoingRotationDegrees: -90 * p,
            incomingRotationDegrees: 90 * (1 - p)
        )
    }

    public struct RochadeState: Sendable, Equatable {
        public let outgoingRotationDegrees: Double
        public let outgoingTranslateXFraction: Double
        public let incomingRotationDegrees: Double
        public let incomingTranslateXFraction: Double
    }

    /// "Rochade" (chess castling): the two slides swap places through a
    /// shared rotating-door pivot, rather than one simply sliding over
    /// the other (`push`, `.tween`) - same rotation shape as `cube` but
    /// paired with a lateral slide so the two faces visibly change
    /// places instead of meeting at a fixed edge.
    public static func rochade(progress: Double) -> RochadeState {
        let p = clamp(progress)
        return RochadeState(
            outgoingRotationDegrees: -90 * p,
            outgoingTranslateXFraction: -p,
            incomingRotationDegrees: 90 * (1 - p),
            incomingTranslateXFraction: 1 - p
        )
    }

    public struct GalleryState: Sendable, Equatable {
        public let outgoingScale: Double
        public let outgoingTranslateXFraction: Double
        public let incomingScale: Double
        public let incomingTranslateXFraction: Double
    }

    /// A cover-flow-style pass: the outgoing slide shrinks and slides
    /// left as it recedes, the incoming slide grows in from the right -
    /// the "gallery" name matches LibreOffice's own preset naming.
    public static func gallery(progress: Double) -> GalleryState {
        let p = clamp(progress)
        return GalleryState(
            outgoingScale: 1 - 0.3 * p,
            outgoingTranslateXFraction: -p,
            incomingScale: 0.7 + 0.3 * p,
            incomingTranslateXFraction: 1 - p
        )
    }

    /// Builds a real `CATransform3D` for a layer rotated `degrees`
    /// around the vertical (Y) axis with a perspective divide, so the
    /// rotation reads as a 3D turn rather than a flat horizontal
    /// squash - the standard `layer.transform` recipe (`m34 =
    /// -1/perspectiveDistance`) every CATransform3D card-flip / cube
    /// implementation uses. Exposed for the playback view; not itself
    /// used by the pure `cube`/`rochade`/`gallery` functions above so
    /// their own output stays a plain, directly-comparable value type.
    public static func perspectiveRotation(degrees: Double, perspectiveDistance: CGFloat = 1000) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspectiveDistance
        return CATransform3DRotate(transform, CGFloat(degrees) * .pi / 180, 0, 1, 0)
    }

    static func clamp(_ progress: Double) -> Double { min(max(progress, 0), 1) }
}

// MARK: - CoreImageTransitionMath

/// Pure per-preset parameter math for the 7 CoreImage-tier gpu presets.
/// Every function here is arithmetic (or, for `glitterParticles`, a
/// fixed-seed deterministic generator) - no `CIImage`/`CIFilter`
/// involved, so these are testable in isolation from CoreImage/GPU
/// availability entirely (doctrine rule 9: math gets fixtures AND
/// properties).
public enum CoreImageTransitionMath {

    /// 0 at `progress == 0` and `progress == 1`, 1 at `progress == 0.5`
    /// - the shared "peaks mid-transition, clean at both ends" shape
    /// several presets below use, so a gpu-tier preset is never
    /// visually indistinguishable from a plain crossfade at either
    /// endpoint (the one place a viewer would notice a wrong "declared
    /// fallback" substitution) while the DECLARED fallback path (an
    /// unimplemented preset id) still resolves to a plain crossfade -
    /// see `GPUTransitionRenderer.renderFrame`.
    public static func triangle(_ progress: Double) -> Double {
        1 - abs(clamp(progress) - 0.5) * 2
    }

    public static func clamp(_ progress: Double) -> Double { min(max(progress, 0), 1) }

    // MARK: newsflash

    public static func newsflashFlashOpacity(progress: Double) -> Double { triangle(progress) }
    public static func newsflashPunchScale(progress: Double) -> Double { 1 + 0.15 * triangle(progress) }

    // MARK: staticNoise

    public static func staticNoiseOpacity(progress: Double) -> Double { triangle(progress) }

    // MARK: vortex

    public static func vortexRadius(progress: Double, maxRadius: Double = 300) -> Double {
        maxRadius * triangle(progress)
    }
    public static func vortexAngleRadians(progress: Double) -> Double {
        6 * .pi * triangle(progress)
    }

    // MARK: honeycomb

    /// `CIHexagonalPixellate`'s own floor is a scale of ~1 (never
    /// fully off), so this never returns exactly 0 - `+ 1` keeps the
    /// filter meaningful at every progress value instead of asking for
    /// a degenerate zero scale at the endpoints.
    public static func honeycombScale(progress: Double, maxScale: Double = 40) -> Double {
        maxScale * triangle(progress) + 1
    }

    // MARK: glitter

    public struct GlitterParticle: Sendable, Equatable {
        public let xFraction: Double
        public let yFraction: Double
        public let peakOpacity: Double
    }

    /// Deterministic seeded positions (a fixed xorshift64* generator
    /// keyed by a constant, NOT wall-clock time or `Int.random`) - two
    /// independent calls with the same `count` return an IDENTICAL
    /// array, so the "glitter" preset's sparkle field is reproducible
    /// frame to frame and test to test (doctrine rule 4).
    public static func glitterParticles(count: Int = 24) -> [GlitterParticle] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextUnit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        return (0..<max(count, 0)).map { _ in
            GlitterParticle(xFraction: nextUnit(), yFraction: nextUnit(), peakOpacity: 0.5 + nextUnit() * 0.5)
        }
    }

    public static func glitterOpacity(progress: Double) -> Double { triangle(progress) }

    // MARK: shred

    /// Alternating strips tear at slightly different rates (odd-indexed
    /// strips lead, even-indexed strips lag) - the "torn apart unevenly"
    /// look that distinguishes `shred` from a plain synchronized wipe.
    public static func shredStripLocalProgress(progress: Double, stripCount: Int = 10) -> [Double] {
        let p = clamp(progress)
        return (0..<max(stripCount, 1)).map { i in min(p * (i.isMultiple(of: 2) ? 1.0 : 0.7), 1) }
    }

    // MARK: turningHelix

    /// Each strip's own local progress is phase-shifted by its index,
    /// so strips turn in a staggered wave rather than in lockstep - the
    /// "helix" (twisting) look.
    public static func helixStripRotationDegrees(progress: Double, stripCount: Int = 8) -> [Double] {
        let p = clamp(progress)
        let count = max(stripCount, 1)
        return (0..<count).map { i in
            let phase = Double(i) / Double(count) * 0.5
            let span = max(1 - phase, 0.0001)
            let local = clamp((p - phase) / span)
            return 180 * local
        }
    }
}

// MARK: - GPUTransitionFamily / GPUTransitionDispatch

/// Which rendering substrate realizes a given `.gpu` preset id. See the
/// file header for why the split lands the way it does; the exact
/// per-id assignment (which 3 are "rigid 3D move" vs which 7 are
/// "2D image effect") is a design call this wave's design contract left
/// open ("CATransform3D perspective (cube, fall, turn, rochade, 3D
/// venetian)" names Keynote-analogy presets, not literal catalog ids) -
/// recorded here and in the findings file for architect ratification.
public enum GPUTransitionFamily: Sendable, Equatable {
    case transform3D
    case coreImage
}

public enum GPUTransitionDispatch {
    /// Every real `TransitionCatalog` `.gpu` preset id this wave
    /// implements, and which family renders it. NOT derived from
    /// `TransitionCatalog.entries` itself (doctrine rule 7's
    /// independent-oracle law) - this table IS the independent oracle a
    /// totality test pins against.
    public static let family: [String: GPUTransitionFamily] = [
        "cube": .transform3D,
        "rochade": .transform3D,
        "gallery": .transform3D,
        "newsflash": .coreImage,
        "glitter": .coreImage,
        "honeycomb": .coreImage,
        "vortex": .coreImage,
        "shred": .coreImage,
        "staticNoise": .coreImage,
        "turningHelix": .coreImage,
    ]
}

// MARK: - GPUTransitionFrame

/// The result of rendering one `.gpu` preset at one progress value
/// through the CoreImage tier.
public struct GPUTransitionFrame: Sendable {
    /// Always the ORIGINAL spec's engine `presetID` (or the spec's own
    /// `id` for a non-`.gpu` spec) - identical whether or not
    /// `usedDeclaredFallback` is true. Round-tripping a `.gpu`
    /// assignment must keep the stored preset id even when playback
    /// only approximates it (design contract, item 2.19).
    public let presetID: String
    /// `true` when `presetID` has no implemented CoreImage technique
    /// (either it belongs to the Transform3D family, or - in the case
    /// of a hypothetical future catalog id this renderer has not been
    /// taught yet - it is genuinely unimplemented) and this frame is
    /// therefore a plain crossfade rather than the preset's real look.
    public let usedDeclaredFallback: Bool
    public let image: CIImage
}

// MARK: - GPUTransitionRenderer

/// Renders the 7 CoreImage-tier gpu presets (see `GPUTransitionDispatch
/// .family`) as real `CIImage` compositions. Stateless and side-effect-
/// free, matching `ShapeRenderer`/`ChartRenderer`'s own convention.
public struct GPUTransitionRenderer: Sendable {

    public init() {}

    /// Every preset id this renderer can draw for real (the
    /// `.coreImage`-family subset of `GPUTransitionDispatch.family`).
    /// Anything else - including a `.transform3D`-family id like
    /// "cube", which this renderer deliberately does not know how to
    /// draw - takes the declared-fallback crossfade path below.
    public static let implementedPresetIDs: Set<String> = Set(techniques.keys)

    /// Renders `spec` at `progress` (clamped to 0...1) compositing
    /// `from` -> `to`. A non-`.gpu` spec, or a `.gpu` spec whose preset
    /// id this renderer does not implement, renders an honest plain
    /// crossfade rather than a wrong visual - see `GPUTransitionFrame
    /// .usedDeclaredFallback`'s doc comment.
    public func renderFrame(for spec: TransitionSpec, progress: Double, from: CIImage, to: CIImage) -> GPUTransitionFrame {
        let p = CoreImageTransitionMath.clamp(progress)
        guard case let .gpu(presetID, _) = spec.engine else {
            return GPUTransitionFrame(presetID: spec.id, usedDeclaredFallback: false, image: Self.crossfade(from, to, p))
        }
        if let technique = Self.techniques[presetID] {
            return GPUTransitionFrame(presetID: presetID, usedDeclaredFallback: false, image: technique(p, from, to))
        }
        return GPUTransitionFrame(presetID: presetID, usedDeclaredFallback: true, image: Self.crossfade(from, to, p))
    }

    // MARK: - Technique table

    private static let techniques: [String: (Double, CIImage, CIImage) -> CIImage] = [
        "newsflash": newsflash,
        "glitter": glitter,
        "honeycomb": honeycomb,
        "vortex": vortex,
        "shred": shred,
        "staticNoise": staticNoise,
        "turningHelix": turningHelix,
    ]

    // MARK: - Shared primitives

    private static func commonExtent(_ a: CIImage, _ b: CIImage) -> CGRect {
        if !a.extent.isInfinite { return a.extent }
        if !b.extent.isInfinite { return b.extent }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// `CIDissolveTransition` (`inputImage`/`inputTargetImage`/
    /// `inputTime`) - a plain alpha crossfade. At `time == 0` the
    /// output is `from`; at `time == 1` the output is `to` (the
    /// filter's own defined behavior), so every technique below that
    /// composes ON TOP of a `dissolve(from, to, p)` base still reduces
    /// to the clean endpoints when its own extra effect parameter is
    /// itself 0 at `p == 0`/`p == 1` (every effect parameter in this
    /// file is built from `triangle`, which IS 0 at both endpoints).
    private static func dissolve(_ from: CIImage, _ to: CIImage, time: Double, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CIDissolveTransition") else { return from.cropped(to: extent) }
        filter.setValue(from, forKey: kCIInputImageKey)
        filter.setValue(to, forKey: "inputTargetImage")
        filter.setValue(CoreImageTransitionMath.clamp(time), forKey: "inputTime")
        return (filter.outputImage ?? from).cropped(to: extent)
    }

    private static func crossfade(_ from: CIImage, _ to: CIImage, _ progress: Double) -> CIImage {
        dissolve(from, to, time: progress, extent: commonExtent(from, to))
    }

    private static func radialGradient(center: CGPoint, radius0: Double, radius1: Double, color0: CIColor, color1: CIColor, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CIRadialGradient") else { return CIImage.empty() }
        filter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        filter.setValue(max(radius0, 0), forKey: "inputRadius0")
        filter.setValue(max(radius1, 0), forKey: "inputRadius1")
        filter.setValue(color0, forKey: "inputColor0")
        filter.setValue(color1, forKey: "inputColor1")
        return (filter.outputImage ?? CIImage.empty()).cropped(to: extent)
    }

    // MARK: - newsflash (zoom-punch + radial flash)

    private static func newsflash(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let punchScale = CGFloat(CoreImageTransitionMath.newsflashPunchScale(progress: p))
        let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .scaledBy(x: punchScale, y: punchScale)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        let punchedTo = to.transformed(by: transform).cropped(to: extent)
        let base = dissolve(from, punchedTo, time: p, extent: extent)

        let flashAlpha = CoreImageTransitionMath.newsflashFlashOpacity(progress: p)
        guard flashAlpha > 0.001 else { return base }
        let flash = radialGradient(
            center: CGPoint(x: extent.midX, y: extent.midY),
            radius0: 0,
            radius1: Double(max(extent.width, extent.height)) * 0.6,
            color0: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(flashAlpha)),
            color1: CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            extent: extent
        )
        return flash.composited(over: base)
    }

    // MARK: - staticNoise (deterministic noise field dissolved in at the midpoint)

    private static func staticNoise(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let base = dissolve(from, to, time: p, extent: extent)
        let opacity = CoreImageTransitionMath.staticNoiseOpacity(progress: p)
        guard opacity > 0.001 else { return base }
        let noise = deterministicNoiseImage(extent: extent)
        return dissolve(base, noise, time: opacity, extent: extent)
    }

    /// A fixed-seed procedural noise field rendered via CoreGraphics
    /// (NOT `CIRandomGenerator`) - deliberately: this file's determinism
    /// contract (doctrine rule 4) needs BYTE-IDENTICAL output across two
    /// independent calls, which this codebase can guarantee for its own
    /// pure-Swift seeded generator but cannot independently verify for
    /// `CIRandomGenerator`'s cross-call reproducibility without running
    /// the suite - see findings for the full reasoning.
    private static func deterministicNoiseImage(extent: CGRect) -> CIImage {
        let width = max(Int(extent.width.rounded(.up)), 1)
        let height = max(Int(extent.height.rounded(.up)), 1)
        let cols = 24
        let rows = 24
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        func nextByte() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
        let cellW = max(width / cols, 1)
        let cellH = max(height / rows, 1)
        for row in 0..<rows {
            for col in 0..<cols {
                let gray = CGFloat(nextByte()) / 255
                context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
                context.fill(CGRect(x: col * cellW, y: row * cellH, width: cellW + 1, height: cellH + 1))
            }
        }
        guard let cgImage = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    // MARK: - vortex (CITwirlDistortion over the crossfaded base)

    private static func vortex(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let base = dissolve(from, to, time: p, extent: extent)
        let radius = CoreImageTransitionMath.vortexRadius(progress: p)
        guard radius > 0.001 else { return base }
        guard let filter = CIFilter(name: "CITwirlDistortion") else { return base }
        filter.setValue(base, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CoreImageTransitionMath.vortexAngleRadians(progress: p), forKey: "inputAngle")
        return (filter.outputImage ?? base).cropped(to: extent)
    }

    // MARK: - honeycomb (CIHexagonalPixellate over the crossfaded base)

    private static func honeycomb(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let base = dissolve(from, to, time: p, extent: extent)
        // Effect magnitude (not just the filter's own `scale` floor of
        // ~1) gates whether the filter runs at all - `triangle` is 0 at
        // both endpoints, so p=0/p=1 stay an exact plain crossfade
        // (matching `vortex`'s identical `radius > 0.001` guard below)
        // instead of a barely-visible scale-1 pixellation lingering at
        // rest.
        guard CoreImageTransitionMath.triangle(p) > 0.02 else { return base }
        guard let filter = CIFilter(name: "CIHexagonalPixellate") else { return base }
        filter.setValue(base, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        filter.setValue(CoreImageTransitionMath.honeycombScale(progress: p), forKey: "inputScale")
        return (filter.outputImage ?? base).cropped(to: extent)
    }

    // MARK: - glitter (deterministic sparkle dots over the crossfaded base)

    private static func glitter(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        var image = dissolve(from, to, time: p, extent: extent)
        let overallAlpha = CoreImageTransitionMath.glitterOpacity(progress: p)
        guard overallAlpha > 0.001 else { return image }
        for particle in CoreImageTransitionMath.glitterParticles() {
            let center = CGPoint(
                x: extent.minX + CGFloat(particle.xFraction) * extent.width,
                y: extent.minY + CGFloat(particle.yFraction) * extent.height
            )
            let dot = radialGradient(
                center: center,
                radius0: 0,
                radius1: 6,
                color0: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(particle.peakOpacity * overallAlpha)),
                color1: CIColor(red: 1, green: 1, blue: 1, alpha: 0),
                extent: extent
            )
            image = dot.composited(over: image)
        }
        return image
    }

    // MARK: - shred (vertical strips torn apart at staggered rates)

    private static func shred(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let stripCount = 10
        let localProgress = CoreImageTransitionMath.shredStripLocalProgress(progress: p, stripCount: stripCount)
        let stripWidth = extent.width / CGFloat(stripCount)
        var result = CIImage.empty()
        for i in 0..<stripCount {
            let stripRect = CGRect(x: extent.minX + CGFloat(i) * stripWidth, y: extent.minY, width: stripWidth, height: extent.height)
            let stripImage = dissolve(from.cropped(to: stripRect), to.cropped(to: stripRect), time: localProgress[i], extent: stripRect)
            result = stripImage.composited(over: result)
        }
        return result.cropped(to: extent)
    }

    // MARK: - turningHelix (strips foreshortened by a per-strip staggered rotation)

    private static func turningHelix(_ p: Double, _ from: CIImage, _ to: CIImage) -> CIImage {
        let extent = commonExtent(from, to)
        let stripCount = 8
        let rotations = CoreImageTransitionMath.helixStripRotationDegrees(progress: p, stripCount: stripCount)
        let stripWidth = extent.width / CGFloat(stripCount)
        var result = CIImage.empty()
        for i in 0..<stripCount {
            let stripRect = CGRect(x: extent.minX + CGFloat(i) * stripWidth, y: extent.minY, width: stripWidth, height: extent.height)
            let angleDegrees = rotations[i]
            // abs(cos(angle)) is the cheap 2D stand-in for the strip's
            // own foreshortening as it "turns" about its vertical axis:
            // 1 = face-on (fully visible) at 0 degrees, ~0 = edge-on (a
            // sliver) at 90 degrees, back to 1 = face-on again at 180
            // degrees - the strip has "turned over" to show its other
            // side. Plain `cos` (no `abs`) would go NEGATIVE past 90
            // degrees and get floor-clamped to a permanent sliver
            // instead of widening back out, so a strip would still be a
            // thin line at progress=1 instead of settling on the full
            // `to` image - this was caught as a genuine bug while
            // writing this file's own tests (see findings).
            let squeeze = max(CGFloat(abs(cos(angleDegrees * .pi / 180))), 0.05)
            // Past 90 degrees the strip has notionally turned over, so
            // it shows `to` instead of `from`.
            let source = angleDegrees > 90 ? to : from
            let squeezed = source.cropped(to: stripRect).transformed(
                by: CGAffineTransform(translationX: stripRect.midX, y: 0)
                    .scaledBy(x: squeeze, y: 1)
                    .translatedBy(x: -stripRect.midX, y: 0)
            )
            result = squeezed.composited(over: result)
        }
        return result.cropped(to: extent)
    }
}
