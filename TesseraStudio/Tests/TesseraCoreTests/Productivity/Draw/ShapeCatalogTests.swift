import XCTest
@testable import TesseraCore

final class ShapeCatalogTests: XCTestCase {

    /// The catalog must cover every kind - `entry(for:)` force-unwraps
    /// its lookup, so a missing entry would crash at first use rather
    /// than degrade gracefully. This test is the thing that catches a
    /// forgotten entry BEFORE that happens.
    func testEveryShapeKindHasExactlyOneCatalogEntry() {
        let kinds = ShapeCatalog.entries.map(\.kind)
        XCTAssertEqual(Set(kinds).count, kinds.count, "duplicate catalog entries")
        // .connector (P1 1.19) is deliberately NOT a palette-insertable
        // kind: it's created by dragging between two existing shapes,
        // never "insert a connector at a point" the way every other
        // catalog entry works, so it has no entry here by design.
        for kind in ShapeKind.allCases where kind != .connector {
            XCTAssertTrue(kinds.contains(kind), "\(kind) has no catalog entry")
        }
    }

    func testEntryLookupMatchesKind() {
        // .connector has no catalog entry (see
        // testEveryShapeKindHasExactlyOneCatalogEntry) - entry(for:)
        // force-unwraps, so calling it for .connector would crash, not
        // just fail an assertion.
        for kind in ShapeKind.allCases where kind != .connector {
            XCTAssertEqual(ShapeCatalog.entry(for: kind).kind, kind)
        }
    }

    func testEveryEntryHasAPositiveSize() {
        for entry in ShapeCatalog.entries {
            XCTAssertGreaterThan(entry.defaultSize.width, 0, "\(entry.kind) has zero/negative default width")
            // Line/arrow are intentionally zero-height (a horizontal
            // stroke, not a filled area).
            if entry.kind != .line && entry.kind != .arrow {
                XCTAssertGreaterThan(entry.defaultSize.height, 0, "\(entry.kind) has zero/negative default height")
            }
        }
    }

    /// Line and arrow have no interior - a default fill on either
    /// would silently do nothing (ShapeRenderer skips fill for these
    /// kinds), so the catalog should not carry one.
    func testLineAndArrowHaveNoDefaultFill() {
        XCTAssertNil(ShapeCatalog.entry(for: .line).defaultFill)
        XCTAssertNil(ShapeCatalog.entry(for: .arrow).defaultFill)
    }

    func testMakeShapePositionsAtTheGivenOrigin() {
        let shape = ShapeCatalog.makeShape(kind: .rect, at: (x: 50, y: 60), zIndex: 2)
        XCTAssertEqual(shape.kind, .rect)
        XCTAssertEqual(shape.geometry.x, 50)
        XCTAssertEqual(shape.geometry.y, 60)
        XCTAssertEqual(shape.zIndex, 2)
        let entry = ShapeCatalog.entry(for: .rect)
        XCTAssertEqual(shape.geometry.width, entry.defaultSize.width)
        XCTAssertEqual(shape.fill, entry.defaultFill)
        XCTAssertEqual(shape.stroke, entry.defaultStroke)
    }
}
