import XCTest
import CoreGraphics
import CoreImage
@testable import TesseraCore

// MARK: - GPUTransitionRendererTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 5, item 2.19 ("CI transition filters ... CATransform3D
// perspective ... ~5 custom Metal/SwiftUI-Shader presets ... Round-trip
// keeps the stored presetId even when playback approximates") plus the
// task brief's own named tests: "GPU transition renderer determinism
// (two renders at the same progress value match)"; "at least one real
// content assertion per renderer FAMILY (not just did-not-crash - e.g.
// a dissolve filter's alpha-blend output at progress=0.5 differs
// measurably from progress=0/1; a CATransform3D cube's layer transform
// at progress=0.5 has the expected rotation angle)"; "a fallback-
// preserves-presetId round-trip test". Doctrine rule 4 (determinism
// first), rule 7 (independent oracles - the 10-id list below is copied
// from TransitionSpec.swift's own `buildEntries()`, never derived by
// iterating `TransitionCatalog.entries`), rule 8 (content + degenerate
// inputs), rule 9 (math gets fixtures AND properties).

final class GPUTransitionRendererTests: DoctrineTestCase {

    // Software renderer: determinism across two independent render
    // calls in the same process is this file's load-bearing contract
    // (rule 4) - a GPU-driver-accelerated context could in principle
    // introduce nondeterministic dithering/precision differences a
    // software rasterizer does not.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    // MARK: - Test image helpers

    /// A left/right split-color image, NOT a uniform solid color -
    /// several techniques below (vortex/honeycomb) are pure per-pixel
    /// geometric distortions, which are visually invisible on a flat
    /// field (distorting a uniform color still looks like that same
    /// uniform color). Every content test in this file uses images
    /// with real spatial variation so a distortion's effect is actually
    /// observable in the rendered bytes.
    private func halfSplitImage(colorLeft: (CGFloat, CGFloat, CGFloat), colorRight: (CGFloat, CGFloat, CGFloat), extent: CGRect) -> CIImage {
        let width = max(Int(extent.width), 1)
        let height = max(Int(extent.height), 1)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: colorLeft.0, green: colorLeft.1, blue: colorLeft.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: colorRight.0, green: colorRight.1, blue: colorRight.2, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let cgImage = context.makeImage()!
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private func renderBuffer(_ image: CIImage, extent: CGRect) -> [UInt8] {
        let width = Int(extent.width)
        let height = Int(extent.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        Self.ciContext.render(image, toBitmap: &buffer, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    private func approxEqual(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 5) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > tolerance { return false }
        return true
    }

    // MARK: - Determinism (rule 4) - FIRST, before any content assertion

    func testTwoIndependentCoreImageRendersAtTheSameProgressProduceByteIdenticalOutput() throws {
        // honeycomb: pure CIFilter geometry, no seeded/procedural noise
        // in the mix - the cleanest possible determinism witness.
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "honeycomb"))
        let extent = CGRect(x: 0, y: 0, width: 48, height: 48)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)
        let renderer = GPUTransitionRenderer()

        let frameA = renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to)
        let frameB = renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to)

        XCTAssertEqual(renderBuffer(frameA.image, extent: extent), renderBuffer(frameB.image, extent: extent))
    }

    func testDeterministicNoiseFieldIsByteIdenticalAcrossTwoIndependentStaticNoiseRenders() throws {
        // staticNoise specifically - the one technique with its own
        // procedural noise field (deliberately NOT CIRandomGenerator,
        // see GPUTransitionRenderer's own doc comment) - proves that
        // field is reproducible too, not just the filter-only presets.
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "staticNoise"))
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)
        let renderer = GPUTransitionRenderer()

        let frameA = renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to)
        let frameB = renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to)

        XCTAssertEqual(renderBuffer(frameA.image, extent: extent), renderBuffer(frameB.image, extent: extent))
    }

    func testTwoIndependentTransform3DComputationsAtTheSameProgressMatch() {
        XCTAssertEqual(Transform3DTransitionMath.cube(progress: 0.5), Transform3DTransitionMath.cube(progress: 0.5))
        XCTAssertEqual(Transform3DTransitionMath.rochade(progress: 0.37), Transform3DTransitionMath.rochade(progress: 0.37))
        XCTAssertEqual(Transform3DTransitionMath.gallery(progress: 0.8), Transform3DTransitionMath.gallery(progress: 0.8))
    }

    // MARK: - Content (rule 8) - Transform3D family: the brief's own named example

    func testCubeRotationAngleAtHalfProgressIsExactlyHalfway() {
        let state = Transform3DTransitionMath.cube(progress: 0.5)
        XCTAssertEqual(state.outgoingRotationDegrees, -45)
        XCTAssertEqual(state.incomingRotationDegrees, 45)
    }

    func testCubeRotationAngleAtProgress0And1IsAtRest() {
        let start = Transform3DTransitionMath.cube(progress: 0)
        XCTAssertEqual(start.outgoingRotationDegrees, 0)
        XCTAssertEqual(start.incomingRotationDegrees, 90)
        let end = Transform3DTransitionMath.cube(progress: 1)
        XCTAssertEqual(end.outgoingRotationDegrees, -90)
        XCTAssertEqual(end.incomingRotationDegrees, 0)
    }

    func testRochadeTranslationIsHalfwaySwappedAtHalfProgress() {
        let state = Transform3DTransitionMath.rochade(progress: 0.5)
        XCTAssertEqual(state.outgoingTranslateXFraction, -0.5)
        XCTAssertEqual(state.incomingTranslateXFraction, 0.5)
    }

    func testGalleryScalesConvergeFromTheirOwnStartToEndValues() {
        let start = Transform3DTransitionMath.gallery(progress: 0)
        XCTAssertEqual(start.outgoingScale, 1)
        XCTAssertEqual(start.incomingScale, 0.7)
        let end = Transform3DTransitionMath.gallery(progress: 1)
        XCTAssertEqual(end.outgoingScale, 0.7)
        XCTAssertEqual(end.incomingScale, 1)
    }

    // MARK: - Content (rule 8) - CoreImage family: the brief's own named example, generalized

    func testStaticNoiseOutputAtHalfProgressDiffersMeasurablyFromProgress0And1() throws {
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "staticNoise"))
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)
        let renderer = GPUTransitionRenderer()

        let atStart = renderBuffer(renderer.renderFrame(for: spec, progress: 0, from: from, to: to).image, extent: extent)
        let atMid = renderBuffer(renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to).image, extent: extent)
        let atEnd = renderBuffer(renderer.renderFrame(for: spec, progress: 1, from: from, to: to).image, extent: extent)

        XCTAssertNotEqual(atMid, atStart, "the noise field peaks at progress 0.5 (CoreImageTransitionMath.triangle) - it must not equal the clean start frame")
        XCTAssertNotEqual(atMid, atEnd, "the noise field peaks at progress 0.5 - it must not equal the clean end frame")
        // Noise opacity is 0 at BOTH endpoints (triangle(0) == triangle(1) == 0),
        // so the declared-honest endpoints are a plain crossfade result,
        // not a wrong/stuck visual.
        XCTAssertTrue(approxEqual(atStart, renderBuffer(from, extent: extent)), "progress 0 must approximate the clean `from` image")
        XCTAssertTrue(approxEqual(atEnd, renderBuffer(to, extent: extent)), "progress 1 must approximate the clean `to` image")
    }

    func testVortexOutputAtHalfProgressDiffersFromAPlainCrossfadeOfTheSamePatternedImages() throws {
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "vortex"))
        let extent = CGRect(x: 0, y: 0, width: 48, height: 48)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)

        let vortexMid = renderBuffer(GPUTransitionRenderer().renderFrame(for: spec, progress: 0.5, from: from, to: to).image, extent: extent)

        // Independent oracle built directly in this test (doctrine rule
        // 7), NOT calling into GPUTransitionRenderer's own private
        // crossfade helper - a plain dissolve, so this assertion is
        // actually about the twirl distortion doing something, not a
        // tautology against the renderer's own internals.
        let plainDissolve = CIFilter(name: "CIDissolveTransition")!
        plainDissolve.setValue(from, forKey: kCIInputImageKey)
        plainDissolve.setValue(to, forKey: "inputTargetImage")
        plainDissolve.setValue(0.5, forKey: "inputTime")
        let plainMid = renderBuffer(plainDissolve.outputImage!.cropped(to: extent), extent: extent)

        XCTAssertNotEqual(vortexMid, plainMid, "CITwirlDistortion must visibly rearrange the patterned image, not silently degrade to a plain dissolve")
    }

    func testEveryImplementedCoreImagePresetDiffersMeasurablyAtHalfProgressFromBothEndpoints() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)
        let renderer = GPUTransitionRenderer()

        for id in GPUTransitionRenderer.implementedPresetIDs.sorted() {
            let spec = try XCTUnwrap(TransitionCatalog.spec(forID: id), "catalog must still carry \(id)")
            let atStart = renderBuffer(renderer.renderFrame(for: spec, progress: 0, from: from, to: to).image, extent: extent)
            let atMid = renderBuffer(renderer.renderFrame(for: spec, progress: 0.5, from: from, to: to).image, extent: extent)
            let atEnd = renderBuffer(renderer.renderFrame(for: spec, progress: 1, from: from, to: to).image, extent: extent)
            XCTAssertNotEqual(atMid, atStart, "\(id) at progress 0.5 must differ from its own progress-0 frame")
            XCTAssertNotEqual(atMid, atEnd, "\(id) at progress 0.5 must differ from its own progress-1 frame")
        }
    }

    // MARK: - Fallback preserves presetId (design contract, item 2.19)

    func testTransform3DFamilyPresetTakesTheDeclaredFallbackButKeepsItsOwnPresetID() throws {
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "cube"))
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)

        let frame = GPUTransitionRenderer().renderFrame(for: spec, progress: 0.5, from: from, to: to)

        XCTAssertEqual(frame.presetID, "cube", "round-trip must keep the stored presetId even when this renderer only approximates it with a crossfade")
        XCTAssertTrue(frame.usedDeclaredFallback, "GPUTransitionRenderer deliberately does not implement the Transform3D family - see GPUTransitionDispatch")
    }

    func testAnImplementedCoreImagePresetNeverTakesTheFallbackPath() throws {
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "honeycomb"))
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)

        let frame = GPUTransitionRenderer().renderFrame(for: spec, progress: 0.5, from: from, to: to)

        XCTAssertEqual(frame.presetID, "honeycomb")
        XCTAssertFalse(frame.usedDeclaredFallback)
    }

    // MARK: - Totality (rule 7: independent oracle, not derived from TransitionCatalog itself)

    func testEveryRealCatalogGPUPresetHasAFamilyAssignment() {
        // Hardcoded from TransitionSpec.swift's own buildEntries() - the
        // complete `.gpu`-engine id list as of this wave. Deliberately
        // NOT computed by iterating TransitionCatalog.entries.
        let realGPUPresetIDs: Set<String> = [
            "newsflash", "glitter", "honeycomb", "vortex", "rochade",
            "cube", "gallery", "shred", "staticNoise", "turningHelix",
        ]
        XCTAssertEqual(Set(GPUTransitionDispatch.family.keys), realGPUPresetIDs)

        for id in realGPUPresetIDs {
            guard let spec = TransitionCatalog.spec(forID: id) else {
                XCTFail("\(id) must exist in TransitionCatalog"); continue
            }
            guard case .gpu = spec.engine else {
                XCTFail("\(id) must be a .gpu-engine spec"); continue
            }
        }
    }

    func testEveryCoreImageFamilyPresetIsActuallyImplemented() {
        let coreImageIDs = GPUTransitionDispatch.family.filter { $0.value == .coreImage }.map(\.key)
        XCTAssertEqual(coreImageIDs.count, 7, "the design contract's own ~5-plus-2 CoreImage-tier bucket - see GPUTransitionRenderer's file header")
        for id in coreImageIDs {
            XCTAssertTrue(GPUTransitionRenderer.implementedPresetIDs.contains(id), "\(id) is assigned to the CoreImage family but has no implemented technique")
        }
    }

    func testEveryTransform3DFamilyPresetDeliberatelyHasNoCoreImageTechnique() {
        let transform3DIDs = GPUTransitionDispatch.family.filter { $0.value == .transform3D }.map(\.key)
        XCTAssertEqual(transform3DIDs.count, 3)
        for id in transform3DIDs {
            XCTAssertFalse(GPUTransitionRenderer.implementedPresetIDs.contains(id), "\(id) belongs to the Transform3D family and must take the declared-fallback path, not a CoreImage technique")
        }
    }

    // MARK: - Pure math (rule 9: fixtures AND properties)

    func testTriangleIsZeroAtBothEndsAndOneAtTheMidpoint() {
        XCTAssertEqual(CoreImageTransitionMath.triangle(0), 0)
        XCTAssertEqual(CoreImageTransitionMath.triangle(1), 0)
        XCTAssertEqual(CoreImageTransitionMath.triangle(0.5), 1)
    }

    func testTriangleClampsProgressOutsideZeroToOne() {
        XCTAssertEqual(CoreImageTransitionMath.triangle(-1), 0)
        XCTAssertEqual(CoreImageTransitionMath.triangle(2), 0)
    }

    func testGlitterParticlesAreDeterministicAcrossCalls() {
        XCTAssertEqual(CoreImageTransitionMath.glitterParticles(count: 12), CoreImageTransitionMath.glitterParticles(count: 12))
    }

    func testGlitterParticlesStayWithinTheUnitSquareAndOpacityRange() {
        for particle in CoreImageTransitionMath.glitterParticles(count: 24) {
            XCTAssertGreaterThanOrEqual(particle.xFraction, 0)
            XCTAssertLessThanOrEqual(particle.xFraction, 1)
            XCTAssertGreaterThanOrEqual(particle.yFraction, 0)
            XCTAssertLessThanOrEqual(particle.yFraction, 1)
            XCTAssertGreaterThanOrEqual(particle.peakOpacity, 0.5)
            XCTAssertLessThanOrEqual(particle.peakOpacity, 1)
        }
    }

    func testShredStripLocalProgressAlternatesLeadAndLagAtFullProgress() {
        let localProgress = CoreImageTransitionMath.shredStripLocalProgress(progress: 1, stripCount: 4)
        XCTAssertEqual(localProgress, [1.0, 0.7, 1.0, 0.7])
    }

    func testHoneycombScaleNeverGoesBelowOne() {
        XCTAssertGreaterThanOrEqual(CoreImageTransitionMath.honeycombScale(progress: 0), 1)
        XCTAssertGreaterThanOrEqual(CoreImageTransitionMath.honeycombScale(progress: 1), 1)
        XCTAssertGreaterThan(CoreImageTransitionMath.honeycombScale(progress: 0.5), CoreImageTransitionMath.honeycombScale(progress: 0))
    }

    func testHelixStripRotationsStayWithin0And180Degrees() {
        for rotation in CoreImageTransitionMath.helixStripRotationDegrees(progress: 0.6, stripCount: 6) {
            XCTAssertGreaterThanOrEqual(rotation, 0)
            XCTAssertLessThanOrEqual(rotation, 180)
        }
    }

    // MARK: - Degenerate inputs (rule 8: empty, zero rect, single value)

    func testZeroSizeExtentDoesNotCrash() throws {
        let extent = CGRect(x: 0, y: 0, width: 0, height: 0)
        let from = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let to = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "staticNoise"))
        _ = GPUTransitionRenderer().renderFrame(for: spec, progress: 0.5, from: from, to: to)
    }

    func testIdenticalFromAndToImagesRenderAtEveryProgressWithoutCrashing() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let image = halfSplitImage(colorLeft: (0.2, 0.4, 0.6), colorRight: (0.8, 0.1, 0.3), extent: extent)
        let renderer = GPUTransitionRenderer()
        for id in GPUTransitionRenderer.implementedPresetIDs {
            let spec = try XCTUnwrap(TransitionCatalog.spec(forID: id))
            for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
                _ = renderer.renderFrame(for: spec, progress: p, from: image, to: image)
            }
        }
    }

    func testProgressOutsideZeroToOneIsClamped() throws {
        let spec = try XCTUnwrap(TransitionCatalog.spec(forID: "honeycomb"))
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let from = halfSplitImage(colorLeft: (1, 0, 0), colorRight: (0, 1, 0), extent: extent)
        let to = halfSplitImage(colorLeft: (0, 0, 1), colorRight: (1, 1, 0), extent: extent)
        let renderer = GPUTransitionRenderer()

        let belowZero = renderBuffer(renderer.renderFrame(for: spec, progress: -5, from: from, to: to).image, extent: extent)
        let atZero = renderBuffer(renderer.renderFrame(for: spec, progress: 0, from: from, to: to).image, extent: extent)
        XCTAssertEqual(belowZero, atZero, "progress below 0 must clamp to the same output as progress == 0")

        let aboveOne = renderBuffer(renderer.renderFrame(for: spec, progress: 5, from: from, to: to).image, extent: extent)
        let atOne = renderBuffer(renderer.renderFrame(for: spec, progress: 1, from: from, to: to).image, extent: extent)
        XCTAssertEqual(aboveOne, atOne, "progress above 1 must clamp to the same output as progress == 1")
    }
}
