import XCTest
@testable import TesseraCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - IntTextLocationTests
//
// Contract: IntTextLocation.swift's own doc comments - "The class
// implements isEqual: so two locations with the same integer compare
// equal. This is what NSTextRange and NSTextContentManager rely on for
// ordering and containment checks"; `compare(_:)` orders by the wrapped
// integer; `makeIntTextRange(start:end:) - Returns nil only when the
// start exceeds the end."

final class IntTextLocationTests: DoctrineTestCase {

    // MARK: - compare(_:)

    func testCompareOrdersByWrappedInteger() {
        let low = IntTextLocation(intValue: 3)
        let high = IntTextLocation(intValue: 7)
        XCTAssertEqual(low.compare(high), .orderedAscending)
        XCTAssertEqual(high.compare(low), .orderedDescending)
        XCTAssertEqual(low.compare(IntTextLocation(intValue: 3)), .orderedSame)
    }

    // MARK: - isEqual: (what NSTextRange relies on)

    func testIsEqualTrueForTwoDistinctInstancesWithTheSameIntValue() {
        let a = IntTextLocation(intValue: 42)
        let b = IntTextLocation(intValue: 42)
        XCTAssertTrue(a.isEqual(b))
        XCTAssertFalse(a === b, "must be two distinct instances, not the same object")
    }

    func testIsEqualFalseForDifferentIntValues() {
        XCTAssertFalse(IntTextLocation(intValue: 1).isEqual(IntTextLocation(intValue: 2)))
    }

    func testIsEqualComparesAgainstAnNSNumberByItsIntValue() {
        let location = IntTextLocation(intValue: 9)
        XCTAssertTrue(location.isEqual(NSNumber(value: 9)))
        XCTAssertFalse(location.isEqual(NSNumber(value: 10)))
    }

    func testIsEqualFalseForAnUnrelatedType() {
        XCTAssertFalse(IntTextLocation(intValue: 1).isEqual("not a location"))
    }

    // MARK: - hash / description

    func testHashMatchesForEqualIntValues() {
        XCTAssertEqual(IntTextLocation(intValue: 5).hash, IntTextLocation(intValue: 5).hash)
    }

    func testDescriptionIsTheIntegerAsAString() {
        XCTAssertEqual(IntTextLocation(intValue: 123).description, "123")
    }

    // MARK: - makeIntTextRange

    func testMakeIntTextRangeBuildsARangeSpanningStartToEnd() {
        let range = makeIntTextRange(start: 2, end: 8)
        XCTAssertNotNil(range)
        XCTAssertEqual((range?.location as? IntTextLocation)?.intValue, 2)
        XCTAssertEqual((range?.endLocation as? IntTextLocation)?.intValue, 8)
    }

    func testMakeIntTextRangeWithStartEqualToEndProducesAnEmptyRange() {
        let range = makeIntTextRange(start: 5, end: 5)
        XCTAssertNotNil(range, "a zero-length range (start == end) is legal, per NSTextRange")
        XCTAssertTrue(range?.isEmpty ?? false)
    }
}
