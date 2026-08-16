//===----------------------------------------------------------------------===//
//  ShapeExtrusionRenderer.swift
//  Tessera Studio
//
//  Item 2.17 (Draw 3D, extrude-only-via-SceneKit minimal design).
//  Builds an `SCNGeometry` (an `SCNShape`) for a `Shape` carrying a
//  non-nil `extrusion`, reusing `ShapeRenderer.path(for:allShapes:)`
//  for the 2D outline - the SAME construction the flat 2D renderer uses
//  for this shape's `ShapeKind` - instead of a second, divergent path
//  builder. Pure and side-effect-free, matching `ShapeRenderer`/
//  `ChartRenderer`'s own convention, and living in `TesseraCore` (not
//  `TesseraStudioMac`) for the identical reason those two do: it is the
//  part of this feature `TesseraCoreTests` can actually reach - see the
//  P2-B findings file for the file-placement rationale. The SwiftUI/
//  SceneKit VIEW that presents this geometry lives in
//  `TesseraStudioMac/Views/Draw/ShapeExtrusionSceneView.swift`, per the
//  wave brief's file list.
//===----------------------------------------------------------------------===//

import Foundation
import CoreGraphics
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform typealiases
//
// `SCNShape`'s designated initializer takes the platform's own bezier
// path type (`NSBezierPath` on macOS, `UIBezierPath` on iOS) - TesseraCore
// is a shared macOS+iOS target (`Package.swift`'s own header comment:
// "the shared SwiftUI views, guarded with #if os() where needed"), so
// this file follows that same established convention rather than being
// macOS-only despite today's only consumer (TesseraStudioMac) being
// macOS-only. `PlatformColor` itself is NOT redeclared here - it's
// already a public typealias in `Editor/BlockRenderer.swift`, module-
// wide visible; a second file-scoped declaration of the same name
// collides with it (Swift sees both in this file's lookup scope).

#if os(macOS)
private typealias PlatformBezierPath = NSBezierPath
#else
private typealias PlatformBezierPath = UIBezierPath
#endif

// MARK: - ShapeExtrusionRenderer

public struct ShapeExtrusionRenderer: Sendable {

    private let shapeRenderer = ShapeRenderer()

    public init() {}

    /// The extruded solid's geometry for `shape`, or `nil` when
    /// `shape.extrusion` is nil (nothing to extrude - not an error, the
    /// overwhelming majority of shapes never carry an extrusion).
    /// `allShapes` is forwarded to `ShapeRenderer.path(for:allShapes:)`
    /// unchanged (only consulted for a `.connector` shape's attached
    /// endpoints - see that method's own doc comment).
    public func makeGeometry(for shape: Shape, allShapes: [Shape] = []) -> SCNGeometry? {
        guard let extrusion = shape.extrusion else { return nil }
        let cgPath = shapeRenderer.path(for: shape, allShapes: allShapes)
        guard !cgPath.isEmpty else { return nil }

        let scnShape = SCNShape(path: Self.platformPath(from: cgPath), extrusionDepth: CGFloat(extrusion.depth))
        // SceneKit documents `extrusionDepth <= 0` as producing a flat,
        // two-dimensional shape lying in the z=0 plane - exactly the
        // "a zero-depth extrusion is visually flat" degenerate case
        // doctrine rule 8 asks for, and it falls out of SCNShape's own
        // semantics here rather than needing a special-cased branch.
        //
        // `chamferRadius` cannot legally exceed half the extruded
        // solid's own smaller dimension (SceneKit clamps internally,
        // but silently) - clamping explicitly here keeps
        // `makeGeometry`'s output bounding box a function this file
        // documents and tests, rather than one that depends on
        // SceneKit's own undocumented internal clamp.
        let bounds = cgPath.boundingBoxOfPath
        let maxChamfer = max(min(bounds.width, bounds.height, CGFloat(extrusion.depth)) / 2, 0)
        scnShape.chamferRadius = min(CGFloat(extrusion.bevelDepth), maxChamfer)

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = Self.resolveMaterialColor(shape.fill)
        material.metalness.contents = NSNumber(value: extrusion.metalness)
        material.roughness.contents = NSNumber(value: extrusion.roughness)
        material.isDoubleSided = true
        scnShape.materials = [material]

        return scnShape
    }

    // MARK: - Path bridging

    private static func platformPath(from cgPath: CGPath) -> PlatformBezierPath {
        #if os(macOS)
        return NSBezierPath(cgPath: cgPath)
        #else
        return UIBezierPath(cgPath: cgPath)
        #endif
    }

    // MARK: - Material color
    //
    // Reuses `Shape.fill`'s existing `ColorRef` rather than a second,
    // extrusion-only color field - see `ShapeExtrusion.swift`'s
    // implementation-note comment. `.theme` resolves via the same
    // neutral `Theme.builtinDefault(for:)` fallback `ShapeRenderer`
    // itself uses when no `Theme` is threaded through: no `Theme`
    // reaches this renderer either, for the identical reason
    // (`ShapeRenderer.hex(for:)`'s own doc comment).

    private static func resolveMaterialColor(_ fill: ShapeFill?) -> PlatformColor {
        let hex: String
        switch fill?.colorHex {
        case .none:
            hex = "#CCCCCC" // no fill set - a neutral solid default, not an invisible one
        case .literal(let value):
            hex = value
        case .theme(let slot, _):
            hex = Theme.builtinDefault(for: slot)
        }
        return color(fromHex: hex, opacity: fill?.opacity ?? 1)
    }

    private static func color(fromHex hex: String, opacity: Double) -> PlatformColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return PlatformColor(red: 0.8, green: 0.8, blue: 0.8, alpha: CGFloat(opacity))
        }
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if s.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        }
        return PlatformColor(red: r, green: g, blue: b, alpha: a * CGFloat(opacity))
    }
}
