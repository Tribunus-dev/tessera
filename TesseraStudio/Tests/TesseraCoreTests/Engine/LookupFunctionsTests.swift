import XCTest
@testable import TesseraCore

// Contract source: no refinement-doc/sota-report spec table exists for
// per-function lookup semantics (see the findings file's "contract
// gaps" section - this is a real, noted gap). What IS a legitimate
// contract here is each function's own PUBLISHED `FunctionSignature`/
// `FunctionParameter` `description` text, registered in
// `LookupFunctions.swift` - that text is the product's declared,
// shipped behavioral commitment (surfaced to the agent tool layer and
// any generated docs), so asserting the implementation honors its own
// declared signature is spec-conformance, not implementation-
// reverse-engineering. Quoted inline per test below. Calls go straight
// through `FunctionRegistry.shared.lookup(name)!.call(args)` - these
// four functions take no live-engine context (unlike OFFSET/INDIRECT),
// so no `SheetEngineCore` is needed at all.
final class LookupFunctionsTests: DoctrineTestCase {

    private func fn(_ name: String) throws -> BuiltInFunction {
        try XCTUnwrap(FunctionRegistry.shared.lookup(name), "\(name) must be registered")
    }

    // MARK: - VLOOKUP
    // Declared description: "Looks up a value in the first column of a
    // table and returns a value from another column." Declared
    // range_lookup: "TRUE = approximate (default), FALSE = exact."

    private func numberTable() -> Value {
        // key | label
        //   1 | one
        //   2 | two
        //   3 | three
        .array(rows: 3, cols: 2, flat: [
            .number(1), .string("one"),
            .number(2), .string("two"),
            .number(3), .string("three"),
        ])
    }

    func testVLOOKUPExactMatchReturnsMatchingRowsOtherColumn() throws {
        let vlookup = try fn("VLOOKUP")
        let result = try vlookup.call([.number(2), numberTable(), .number(2), .bool(false)])
        XCTAssertEqual(result, .string("two"))
    }

    func testVLOOKUPExactMatchWithNoHitReturnsNotAvailable() throws {
        let vlookup = try fn("VLOOKUP")
        let result = try vlookup.call([.number(99), numberTable(), .number(2), .bool(false)])
        XCTAssertEqual(result, .error(.notAvailable))
    }

    /// "range_lookup ... TRUE = approximate (default)" - omitting the
    /// 4th argument must behave as though TRUE were passed.
    func testVLOOKUPOmittedRangeLookupDefaultsToApproximate() throws {
        let vlookup = try fn("VLOOKUP")
        // 2.5 has no exact key; approximate must find the largest key
        // that does not exceed it (2 -> "two"), matching the same
        // 3-argument call with range_lookup explicitly TRUE.
        let omitted = try vlookup.call([.number(2.5), numberTable(), .number(2)])
        let explicitTrue = try vlookup.call([.number(2.5), numberTable(), .number(2), .bool(true)])
        XCTAssertEqual(omitted, .string("two"))
        XCTAssertEqual(omitted, explicitTrue)
    }

    // MARK: - HLOOKUP
    // Declared description: "Looks up a value in the first row of a
    // table and returns a value from another row."

    func testHLOOKUPExactMatchReturnsMatchingColumnsOtherRow() throws {
        let hlookup = try fn("HLOOKUP")
        // Transposed shape of numberTable(): row 0 = keys, row 1 = labels.
        let table = Value.array(rows: 2, cols: 3, flat: [
            .number(1), .number(2), .number(3),
            .string("one"), .string("two"), .string("three"),
        ])
        let result = try hlookup.call([.number(3), table, .number(2), .bool(false)])
        XCTAssertEqual(result, .string("three"))
    }

    // MARK: - MATCH
    // Declared match_type description: "1 = largest <=, 0 = exact,
    // -1 = smallest >=."

    private func ascendingVector() -> Value {
        .array(rows: 1, cols: 5, flat: [.number(1), .number(3), .number(5), .number(7), .number(9)])
    }

    private func descendingVector() -> Value {
        .array(rows: 1, cols: 5, flat: [.number(9), .number(7), .number(5), .number(3), .number(1)])
    }

    func testMATCHExactTypeZeroFindsExactPosition() throws {
        let match = try fn("MATCH")
        let result = try match.call([.number(5), ascendingVector(), .number(0)])
        XCTAssertEqual(result, .number(3)) // 1-based position of 5
    }

    func testMATCHExactTypeZeroWithNoHitReturnsNotAvailable() throws {
        let match = try fn("MATCH")
        let result = try match.call([.number(4), ascendingVector(), .number(0)])
        XCTAssertEqual(result, .error(.notAvailable))
    }

    func testMATCHTypeOneOnAscendingDataFindsLargestValueLessThanOrEqual() throws {
        let match = try fn("MATCH")
        // 6 is not present; largest <= 6 in [1,3,5,7,9] is 5 (position 3).
        let result = try match.call([.number(6), ascendingVector(), .number(1)])
        XCTAssertEqual(result, .number(3))
    }

    func testMATCHTypeNegativeOneOnDescendingDataFindsSmallestValueGreaterThanOrEqual() throws {
        let match = try fn("MATCH")
        // 6 is not present; smallest >= 6 in [9,7,5,3,1] is 7 (position 2).
        let result = try match.call([.number(6), descendingVector(), .number(-1)])
        XCTAssertEqual(result, .number(2))
    }

    // MARK: - XLOOKUP
    // Declared match_mode: "0 exact, -1 next smaller, 1 next larger,
    // 2 wildcard." Declared search_mode: "1 first-to-last, -1
    // last-to-first." Declared if_not_found: falls back when no match.

    func testXLOOKUPExactModeReturnsCorrespondingResultEntry() throws {
        let xlookup = try fn("XLOOKUP")
        let lookup = Value.array(rows: 1, cols: 3, flat: [.string("a"), .string("b"), .string("c")])
        let result = Value.array(rows: 1, cols: 3, flat: [.number(10), .number(20), .number(30)])
        let hit = try xlookup.call([.string("b"), lookup, result])
        XCTAssertEqual(hit, .number(20))
    }

    func testXLOOKUPIfNotFoundIsReturnedWhenThereIsNoMatch() throws {
        let xlookup = try fn("XLOOKUP")
        let lookup = Value.array(rows: 1, cols: 3, flat: [.string("a"), .string("b"), .string("c")])
        let result = Value.array(rows: 1, cols: 3, flat: [.number(10), .number(20), .number(30)])
        let miss = try xlookup.call([.string("z"), lookup, result, .string("missing")])
        XCTAssertEqual(miss, .string("missing"))
    }

    func testXLOOKUPMatchModeWildcardHonorsGlobPattern() throws {
        let xlookup = try fn("XLOOKUP")
        let lookup = Value.array(rows: 1, cols: 3, flat: [.string("apple"), .string("banana"), .string("cherry")])
        let result = Value.array(rows: 1, cols: 3, flat: [.number(1), .number(2), .number(3)])
        let hit = try xlookup.call([.string("ba*"), lookup, result, .null, .number(2)])
        XCTAssertEqual(hit, .number(2))
    }

    func testXLOOKUPSearchModeLastToFirstFindsTheLastMatch() throws {
        let xlookup = try fn("XLOOKUP")
        let lookup = Value.array(rows: 1, cols: 4, flat: [.string("x"), .string("y"), .string("x"), .string("z")])
        let result = Value.array(rows: 1, cols: 4, flat: [.number(1), .number(2), .number(3), .number(4)])
        // search_mode -1: last-to-first - the LAST "x" (position 3, value 3).
        let hit = try xlookup.call([.string("x"), lookup, result, .null, .number(0), .number(-1)])
        XCTAssertEqual(hit, .number(3))
    }

    // MARK: - INDEX
    // Declared description: "Returns a value from a table or array."
    // row_num/col_num are declared as positions (1-based, matching every
    // other 1-based row/col argument in this file - MATCH's own result
    // is asserted 1-based above).

    func testINDEXReturnsValueAtOneBasedRowAndColumn() throws {
        let index = try fn("INDEX")
        let result = try index.call([numberTable(), .number(2), .number(2)])
        XCTAssertEqual(result, .string("two"))
    }

    func testINDEXWithOnlyRowNumberOnASingleColumnDefaultsToFirstColumn() throws {
        let index = try fn("INDEX")
        let singleColumn = Value.array(rows: 3, cols: 1, flat: [.number(10), .number(20), .number(30)])
        let result = try index.call([singleColumn, .number(2)])
        XCTAssertEqual(result, .number(20))
    }

    // MARK: - CHOOSE
    // Declared description: "Selects a value from a list by position."

    func testCHOOSESelectsTheOneBasedPositionalValue() throws {
        let choose = try fn("CHOOSE")
        let result = try choose.call([.number(2), .string("x"), .string("y"), .string("z")])
        XCTAssertEqual(result, .string("y"))
    }
}
