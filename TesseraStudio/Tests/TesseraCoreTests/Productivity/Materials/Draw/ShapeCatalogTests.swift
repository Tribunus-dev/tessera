import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ShapeCatalogTests
//
// Contract source: ShapeCatalog.swift's own doc comment on
// `entry(for:)`: "entries covers ShapeKind.allCases EXCEPT .connector
// (created by dragging between two shapes, never inserted from a
// palette), enforced by ShapeCatalogTests, not by the compiler" - this
// file IS the enforcement the source comment names. Doctrine rule 7
// (independent oracle): the expected kind list is a literal hardcoded
// here (mirroring Shape.swift's ShapeKind declaration order), not
// derived by asking ShapeCatalog or ShapeKind.allCases for its own
// answer and comparing it to itself.

final class ShapeCatalogTests: DoctrineTestCase {

    /// Hardcoded from Shape.swift's `ShapeKind` declaration (rule 7,
    /// independent oracle) - every PALETTE-insertable kind except
    /// `.connector`.
    private static let palettableKinds: [ShapeKind] = [
        .rect, .ellipse, .line, .arrow, .polygon, .star, .freeform,
    ]

    func testCatalogHasExactlyOneEntryPerPalettableShapeKind() {
        let catalogKinds = Set(ShapeCatalog.entries.map(\.kind))
        XCTAssertEqual(catalogKinds, Set(Self.palettableKinds))
        XCTAssertEqual(ShapeCatalog.entries.count, Self.palettableKinds.count, "no duplicate catalog entries")
    }

    func testCatalogHasNoEntryForConnector() {
        XCTAssertFalse(ShapeCatalog.entries.contains { $0.kind == .connector }, ".connector is created by dragging between shapes, never inserted from a palette")
    }

    func testEntryForEveryPalettableKindReturnsMatchingEntry() {
        for kind in Self.palettableKinds {
            XCTAssertEqual(ShapeCatalog.entry(for: kind).kind, kind)
        }
    }

    func testMakeShapePositionsAtOriginWithCatalogDefaultSizeFillAndStroke() {
        let entry = ShapeCatalog.entry(for: .rect)
        let shape = ShapeCatalog.makeShape(kind: .rect, at: (x: 12, y: 34), zIndex: 5)

        XCTAssertEqual(shape.geometry.x, 12)
        XCTAssertEqual(shape.geometry.y, 34)
        XCTAssertEqual(shape.geometry.width, entry.defaultSize.width)
        XCTAssertEqual(shape.geometry.height, entry.defaultSize.height)
        XCTAssertEqual(shape.fill, entry.defaultFill)
        XCTAssertEqual(shape.stroke, entry.defaultStroke)
        XCTAssertEqual(shape.zIndex, 5)
        XCTAssertEqual(shape.kind, .rect)
    }

    func testMakeShapeAssignsAFreshIDPerCall() {
        let a = ShapeCatalog.makeShape(kind: .ellipse, at: (x: 0, y: 0), zIndex: 0)
        let b = ShapeCatalog.makeShape(kind: .ellipse, at: (x: 0, y: 0), zIndex: 0)
        XCTAssertNotEqual(a.id, b.id)
    }
}
