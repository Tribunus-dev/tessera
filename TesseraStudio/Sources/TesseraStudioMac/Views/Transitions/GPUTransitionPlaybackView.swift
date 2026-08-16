//===----------------------------------------------------------------------===//
//  GPUTransitionPlaybackView.swift
//  Tessera Studio
//
//  Item 2.19 (GPU transitions). The thin presentation-layer consumer of
//  `GPUTransitionRenderer`/`Transform3DTransitionMath`
//  (`TesseraCore/Views/Renderers/Transitions/GPUTransitionRenderer.swift`
//  - see that file's header for the full family split and rationale).
//  All the actual per-progress math lives there, pure and tested; this
//  view only turns that math into on-screen pixels: real
//  `.rotation3DEffect` for the Transform3D family (cube/rochade/
//  gallery), a rendered `CGImage` for the CoreImage family (everything
//  else).
//
//  Not wired into a presenter-mode host yet - there is no slide-
//  playback screen in the app today for this view to be pushed into
//  (verified before writing this file: no `Transitions`/`Presenter`
//  view existed anywhere under `TesseraStudioMac/Views/Slides/`). This
//  is a standalone, reusable view for whoever builds presenter mode
//  next; see this wave's findings file.
//===----------------------------------------------------------------------===//

import SwiftUI
import CoreImage
import TesseraCore

// MARK: - GPUTransitionPlaybackView

/// Renders one frame of a `.gpu`-tier `TransitionSpec` at a given
/// `progress` (0...1), compositing `fromImage` -> `toImage`. Non-`.gpu`
/// specs and unimplemented `.gpu` preset ids both fall through to
/// `GPUTransitionRenderer`'s own honest crossfade fallback - this view
/// never special-cases "unknown preset" itself, so its behavior stays
/// in lockstep with the engine's own declared-fallback contract.
public struct GPUTransitionPlaybackView: View {
    private let spec: TransitionSpec
    private let fromImage: CGImage
    private let toImage: CGImage
    private let progress: Double

    private let renderer = GPUTransitionRenderer()
    // `.useSoftwareRenderer` is NOT set here (unlike the test suite's
    // context) - on-screen playback wants the GPU-accelerated path;
    // determinism across renders only matters for the offscreen/test
    // path, not for what a human watches live.
    private static let ciContext = CIContext()

    public init(spec: TransitionSpec, fromImage: CGImage, toImage: CGImage, progress: Double) {
        self.spec = spec
        self.fromImage = fromImage
        self.toImage = toImage
        self.progress = progress
    }

    public var body: some View {
        if case let .gpu(presetID, _) = spec.engine,
           GPUTransitionDispatch.family[presetID] == .transform3D {
            transform3DBody(presetID: presetID)
        } else {
            coreImageBody
        }
    }

    // MARK: - Transform3D family

    @ViewBuilder
    private func transform3DBody(presetID: String) -> some View {
        switch presetID {
        case "cube":
            let state = Transform3DTransitionMath.cube(progress: progress)
            ZStack {
                faceImage(fromImage)
                    .rotation3DEffect(.degrees(state.outgoingRotationDegrees), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0.5)
                faceImage(toImage)
                    .rotation3DEffect(.degrees(state.incomingRotationDegrees), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
            }
        case "rochade":
            let state = Transform3DTransitionMath.rochade(progress: progress)
            ZStack {
                faceImage(fromImage)
                    .rotation3DEffect(.degrees(state.outgoingRotationDegrees), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                    .offset(x: CGFloat(state.outgoingTranslateXFraction) * CGFloat(fromImage.width))
                faceImage(toImage)
                    .rotation3DEffect(.degrees(state.incomingRotationDegrees), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                    .offset(x: CGFloat(state.incomingTranslateXFraction) * CGFloat(toImage.width))
            }
        case "gallery":
            let state = Transform3DTransitionMath.gallery(progress: progress)
            ZStack {
                faceImage(fromImage)
                    .scaleEffect(CGFloat(state.outgoingScale))
                    .offset(x: CGFloat(state.outgoingTranslateXFraction) * CGFloat(fromImage.width))
                faceImage(toImage)
                    .scaleEffect(CGFloat(state.incomingScale))
                    .offset(x: CGFloat(state.incomingTranslateXFraction) * CGFloat(toImage.width))
            }
        default:
            // GPUTransitionDispatch.family named this id `.transform3D`
            // but no case above draws it yet - an honest crossfade
            // beats a missing view, matching the CoreImage engine's own
            // declared-fallback contract.
            coreImageBody
        }
    }

    private func faceImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    // MARK: - CoreImage family

    private var coreImageBody: some View {
        let ciFrom = CIImage(cgImage: fromImage)
        let ciTo = CIImage(cgImage: toImage)
        let extent = CGRect(x: 0, y: 0, width: fromImage.width, height: fromImage.height)
        let frame = renderer.renderFrame(for: spec, progress: progress, from: ciFrom, to: ciTo)
        let rendered = Self.ciContext.createCGImage(frame.image, from: extent)
        return Group {
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
    }
}
