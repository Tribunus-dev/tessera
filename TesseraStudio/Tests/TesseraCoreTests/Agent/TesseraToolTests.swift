import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraTool.swift doc
// comments -- JSONValue is "a type-erased JSON value for tool arguments
// and results"; JSONSchema/SchemaProperty mirror the JSON Schema wire
// shape; ToolResult.payload projects onto ToolResultPayload.
final class TesseraToolTests: DoctrineTestCase {

    // MARK: - JSONValue: round-trip identity (rule 2) across every case

    func testJSONValueStringRoundTrip() throws {
        try assertRoundTrip(.string("hello"))
    }

    func testJSONValueNumberRoundTrip() throws {
        try assertRoundTrip(.number(3.5))
    }

    func testJSONValueBoolRoundTrip() throws {
        try assertRoundTrip(.bool(true))
        try assertRoundTrip(.bool(false))
    }

    func testJSONValueNullRoundTrip() throws {
        try assertRoundTrip(.null)
    }

    func testJSONValueArrayRoundTrip() throws {
        try assertRoundTrip(.array([.string("a"), .number(1), .bool(true), .null]))
    }

    func testJSONValueObjectRoundTrip() throws {
        try assertRoundTrip(.object(["k1": .string("v"), "k2": .number(2)]))
    }

    func testJSONValueNestedRoundTrip() throws {
        try assertRoundTrip(.object(["arr": .array([.object(["x": .number(1)])])]))
    }

    private func assertRoundTrip(_ value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - JSONValue: legacy-JSON decode (pin a fixture, rule 2)

    func testJSONValueDecodesFromRawStringLiteral() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("\"hello\"".utf8))
        XCTAssertEqual(decoded, .string("hello"))
    }

    func testJSONValueDecodesFromRawNumberLiteral() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("42".utf8))
        XCTAssertEqual(decoded, .number(42))
    }

    func testJSONValueDecodesFromRawObjectLiteral() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        XCTAssertEqual(decoded, .object(["a": .number(1), "b": .string("x")]))
    }

    func testJSONValueDecodesFromRawNullLiteral() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("null".utf8))
        XCTAssertEqual(decoded, .null)
    }

    // MARK: - JSONValue accessors

    func testStringValueAccessorOnlyReturnsForStringCase() {
        XCTAssertEqual(JSONValue.string("x").stringValue, "x")
        XCTAssertNil(JSONValue.number(1).stringValue)
    }

    func testNumberValueAccessorOnlyReturnsForNumberCase() {
        XCTAssertEqual(JSONValue.number(3.5).numberValue, 3.5)
        XCTAssertNil(JSONValue.string("3.5").numberValue)
    }

    func testBoolValueAccessorOnlyReturnsForBoolCase() {
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertNil(JSONValue.number(1).boolValue)
    }

    // MARK: - shortDescription

    func testShortDescriptionForEachCase() {
        XCTAssertEqual(JSONValue.string("hi").shortDescription, "hi")
        XCTAssertEqual(JSONValue.bool(true).shortDescription, "true")
        XCTAssertEqual(JSONValue.bool(false).shortDescription, "false")
        XCTAssertEqual(JSONValue.null.shortDescription, "null")
        XCTAssertEqual(JSONValue.array([.null, .null]).shortDescription, "[2 items]")
        XCTAssertEqual(JSONValue.object(["a": .null]).shortDescription, "{1 keys}")
    }

    // MARK: - toAny() Foundation bridging

    func testToAnyBridgesStringAndNumberAndBool() {
        XCTAssertEqual(JSONValue.string("x").toAny() as? String, "x")
        XCTAssertEqual(JSONValue.number(2).toAny() as? Double, 2)
        XCTAssertEqual(JSONValue.bool(true).toAny() as? Bool, true)
    }

    func testToAnyBridgesNullToNSNull() {
        XCTAssertTrue(JSONValue.null.toAny() is NSNull)
    }

    func testToAnyBridgesArrayRecursively() {
        let any = JSONValue.array([.number(1), .number(2)]).toAny()
        XCTAssertEqual(any as? [Double], [1, 2])
    }

    // MARK: - JSONSchema.toJSON()

    func testJSONSchemaToJSONProducesParsableJSON() throws {
        let schema = JSONSchema(
            type: "object",
            properties: ["path": SchemaProperty(type: "string", description: "a path")],
            required: ["path"]
        )
        let json = schema.toJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "object")
        XCTAssertEqual(obj?["required"] as? [String], ["path"])
    }

    func testSchemaPropertyEnumCodingKeyIsEnumNotEnumValues() throws {
        // The custom CodingKeys map `enumValues` -> "enum" on the wire.
        let prop = SchemaProperty(type: "string", enumValues: ["a", "b"])
        let data = try JSONEncoder().encode(prop)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["enum"] as? [String], ["a", "b"])
        XCTAssertNil(obj?["enumValues"])
    }

    func testSchemaPropertyDefaultCodingKeyIsDefaultNotDefaultValue() throws {
        let prop = SchemaProperty(type: "string", defaultValue: "x")
        let data = try JSONEncoder().encode(prop)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["default"] as? String, "x")
    }

    // MARK: - ToolResult.ok / .fail factories

    func testToolResultOkFactoryIsSuccessWithNoError() {
        let result = ToolResult.ok("done", data: ["k": .string("v")])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "done")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.data?["k"], .string("v"))
    }

    func testToolResultFailFactoryIsFailureWithEmptyOutput() {
        let result = ToolResult.fail("bad path")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "bad path")
    }

    // MARK: - ToolResult.payload projection

    func testToolResultPayloadProjectsSuccessOutputErrorConfidenceBand() {
        let result = ToolResult(success: true, output: "out", data: nil, error: nil, confidenceBand: .high)
        let payload = result.payload
        XCTAssertEqual(payload.success, true)
        XCTAssertEqual(payload.output, "out")
        XCTAssertNil(payload.error)
        XCTAssertEqual(payload.confidenceBand, .high)
    }

    func testToolResultPayloadDefaultsToEmptySources() {
        // ToolResult carries no `sources` field of its own; the payload
        // projection always starts from an empty citation list. Citations
        // are lifted separately by UnifiedChatController.extractCitations
        // (see ChatMessageCitationTests).
        let result = ToolResult.ok("x")
        XCTAssertEqual(result.payload.sources, [])
    }
}
