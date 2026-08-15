import XCTest
@testable import TesseraCore

/// Tests for ``StyleRegistry``: `DocumentMeta.styles` round-tripping,
/// 4-layer resolution (docDefaults -> paragraph chain -> character
/// chain -> run annotations) with leaf-wins semantics, cycle guarding,
/// and deletion's "rebinds to parent, never dangles" contract.
final class StyleRegistryTests: XCTestCase {

    // MARK: - DocumentMeta.styles round-trip

    func testStyleRegistryRoundTripsThroughDocumentMeta() throws {
        let style = StyleDefinition(
            name: "Heading 1",
            family: .paragraph,
            props: StyleProperties(isBold: true, fontSizePt: 24)
        )
        var ast = DocumentAST(blocks: [:], rootChildren: [])
        ast.meta.styles[style.id] = style

        let decoded = try DocumentAST.from(jsonData: try ast.jsonData())
        XCTAssertEqual(decoded.meta.styles[style.id]?.name, "Heading 1")
        XCTAssertEqual(decoded.meta.styles[style.id]?.family, .paragraph)
        XCTAssertEqual(decoded.meta.styles[style.id]?.props.isBold, true)
        XCTAssertEqual(decoded.meta.styles[style.id]?.props.fontSizePt, 24)
    }

    func testDocumentMetaWithoutStylesKeyDecodesAsEmpty() throws {
        // A document written after `sections`/`notes` shipped but before
        // `styles` existed has both those keys but no "styles" key at
        // all - the decoder must default to empty, not throw. Same
        // shape as BlockTests' testDocumentMetaWithoutSectionsKeyDecodesAsEmpty
        // / testDocumentMetaWithoutNotesKeyDecodesAsEmpty, one field
        // later in the timeline.
        let json = """
        {"blocks": {}, "rootChildren": [], "meta": {"pageLayout": {
            "pageWidth": 595, "pageHeight": 842,
            "marginTop": 72, "marginBottom": 72, "marginLeft": 72, "marginRight": 72,
            "columnCount": 1, "columnGap": 18, "pageColor": "#FFFFFF"
        }, "sections": {}, "notes": {}}}
        """
        let decoded = try DocumentAST.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.meta.styles.isEmpty)
        XCTAssertEqual(decoded.meta.pageLayout.pageWidth, 595)
    }

    func testStyleDefinitionRoundTripsBasedOnAndNext() throws {
        let parentID = UUID()
        let nextID = UUID()
        let style = StyleDefinition(name: "Body Text", family: .paragraph, basedOn: parentID, next: nextID)
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(StyleDefinition.self, from: data)
        XCTAssertEqual(decoded.basedOn, parentID)
        XCTAssertEqual(decoded.next, nextID)
        XCTAssertEqual(decoded.family, .paragraph)
    }

    // MARK: - Block.styleRef

    func testStyleRefRoundTripsThroughAttributesOnAnyBlockType() {
        let styleID = UUID()
        var block = Block(type: .paragraph)
        XCTAssertNil(block.styleRef)

        block.styleRef = styleID
        XCTAssertEqual(block.styleRef, styleID)
        XCTAssertEqual(block.attributes["styleRef"]?.stringValue, styleID.uuidString)

        // Not type-gated like .shape/.frame/.chart/.field/.media: a
        // heading can carry a style ref just as well as a paragraph.
        var heading = Block(type: .heading)
        heading.styleRef = styleID
        XCTAssertEqual(heading.styleRef, styleID)

        block.styleRef = nil
        XCTAssertNil(block.styleRef)
        XCTAssertNil(block.attributes["styleRef"])
    }

    // MARK: - StyleProperties.applied(over:)

    func testAppliedOverSubstitutesOnlyNonNilFields() {
        let base = StyleProperties(isBold: false, textColorHex: "#000000", alignment: .leading)
        let overlay = StyleProperties(textColorHex: "#0000FF")
        let result = overlay.applied(over: base)
        XCTAssertEqual(result.isBold, false, "untouched field passes through from base")
        XCTAssertEqual(result.textColorHex, "#0000FF", "overlay's non-nil field wins")
        XCTAssertEqual(result.alignment, .leading, "untouched field passes through from base")
    }

    // MARK: - 4-layer resolution: 3-deep basedOn chain, leaf-wins (OOXML semantics)

    func testThreeDeepBasedOnChainResolvesWithLeafWinsSemantics() {
        // A (root) -> B (basedOn A) -> C (basedOn B), matching the
        // contract's exact fixture: a property set at C wins over the
        // same property set at B or A; a property NOT set at C but set
        // at B wins over A; a property set only at A applies when
        // neither B nor C override it.
        let styleA = StyleDefinition(
            name: "A",
            family: .paragraph,
            props: StyleProperties(isBold: false, textColorHex: "#000000", alignment: .leading)
        )
        let styleB = StyleDefinition(
            name: "B",
            family: .paragraph,
            basedOn: styleA.id,
            props: StyleProperties(textColorHex: "#0000FF")
        )
        let styleC = StyleDefinition(
            name: "C",
            family: .paragraph,
            basedOn: styleB.id,
            props: StyleProperties(isBold: true)
        )
        let registry: [UUID: StyleDefinition] = [styleA.id: styleA, styleB.id: styleB, styleC.id: styleC]

        let resolved = StyleRegistry.resolve(paragraphStyleRef: styleC.id, registry: registry)

        // Set at C: C wins over B and A.
        XCTAssertEqual(resolved.isBold, true)
        // Set at B, not at C: B wins over A.
        XCTAssertEqual(resolved.textColorHex, "#0000FF")
        // Set only at A: applies since neither B nor C override it.
        XCTAssertEqual(resolved.alignment, .leading)
    }

    func testRunAnnotationsWinOverTheEntireStyleChain() {
        let styleA = StyleDefinition(name: "A", family: .paragraph, props: StyleProperties(textColorHex: "#000000"))
        let styleB = StyleDefinition(
            name: "B", family: .paragraph, basedOn: styleA.id,
            props: StyleProperties(textColorHex: "#0000FF")
        )
        let registry: [UUID: StyleDefinition] = [styleA.id: styleA, styleB.id: styleB]

        let resolved = StyleRegistry.resolve(
            runAnnotations: [.color(hex: "#FF0000"), .bold],
            paragraphStyleRef: styleB.id,
            registry: registry
        )

        // The literal run annotation wins over B (which already won over A).
        XCTAssertEqual(resolved.textColorHex, "#FF0000")
        XCTAssertEqual(resolved.isBold, true)
    }

    func testDocDefaultsApplyWhenNoStyleOverrides() {
        let docDefaults = StyleDefinition(
            name: "Normal",
            family: .paragraph,
            props: StyleProperties(fontFamily: "Calibri", fontSizePt: 11)
        )
        let resolved = StyleRegistry.resolve(docDefaults: docDefaults, registry: [:])
        XCTAssertEqual(resolved.fontFamily, "Calibri")
        XCTAssertEqual(resolved.fontSizePt, 11)
    }

    func testParagraphAndCharacterChainsBothContributeWithCharacterWinningTies() {
        // Character styles resolve strictly after paragraph styles, so
        // an overlapping property set on both is won by the character
        // style - it's the more specific (closer to the run) layer.
        let paragraphStyle = StyleDefinition(
            name: "Body", family: .paragraph,
            props: StyleProperties(textColorHex: "#111111", alignment: .justify)
        )
        let characterStyle = StyleDefinition(
            name: "Emphasis", family: .character,
            props: StyleProperties(isItalic: true, textColorHex: "#EE0000")
        )
        let registry: [UUID: StyleDefinition] = [paragraphStyle.id: paragraphStyle, characterStyle.id: characterStyle]

        let resolved = StyleRegistry.resolve(
            characterStyleRef: characterStyle.id,
            paragraphStyleRef: paragraphStyle.id,
            registry: registry
        )
        XCTAssertEqual(resolved.textColorHex, "#EE0000", "character chain resolves after paragraph, so it wins")
        XCTAssertEqual(resolved.alignment, .justify, "only the paragraph style set this; it survives")
        XCTAssertEqual(resolved.isItalic, true)
    }

    func testDanglingStyleRefResolvesAsEmptyChainRatherThanCrashing() {
        let docDefaults = StyleDefinition(name: "Normal", family: .paragraph, props: StyleProperties(isBold: false))
        let dangling = UUID()
        let resolved = StyleRegistry.resolve(paragraphStyleRef: dangling, docDefaults: docDefaults, registry: [:])
        XCTAssertEqual(resolved.isBold, false, "falls through to docDefaults; the dangling ref contributes nothing")
    }

    // MARK: - Cycle guard

    func testMutualBasedOnCycleResolvesWithoutInfiniteLoopingOrCrashing() {
        // X basedOn Y, Y basedOn X: a malformed/imported 2-cycle.
        let xID = UUID()
        let yID = UUID()
        let styleX = StyleDefinition(id: xID, name: "X", family: .paragraph, basedOn: yID, props: StyleProperties(isBold: true))
        let styleY = StyleDefinition(id: yID, name: "Y", family: .paragraph, basedOn: xID, props: StyleProperties(isItalic: true))
        let registry: [UUID: StyleDefinition] = [xID: styleX, yID: styleY]

        // Must return promptly (no infinite loop) regardless of which
        // style in the cycle resolution starts from.
        let resolved = StyleRegistry.resolve(paragraphStyleRef: xID, registry: registry)
        XCTAssertEqual(resolved.isBold, true)
        XCTAssertEqual(resolved.isItalic, true)
    }

    func testSelfReferentialBasedOnResolvesAsItsOwnPropsOnly() {
        let selfID = UUID()
        var style = StyleDefinition(id: selfID, name: "Self", family: .paragraph, props: StyleProperties(isBold: true))
        style.basedOn = selfID
        let resolved = StyleRegistry.resolve(paragraphStyleRef: selfID, registry: [selfID: style])
        XCTAssertEqual(resolved.isBold, true)
    }

    // MARK: - Deletion: rebinds to parent, never dangles

    func testDeletingMiddleStyleOfThreeDeepChainRebindsLeafToRoot() {
        let styleA = StyleDefinition(name: "A", family: .paragraph)
        let styleB = StyleDefinition(name: "B", family: .paragraph, basedOn: styleA.id)
        let styleC = StyleDefinition(name: "C", family: .paragraph, basedOn: styleB.id)
        let registry: [UUID: StyleDefinition] = [styleA.id: styleA, styleB.id: styleB, styleC.id: styleC]

        let result = StyleRegistry.deletingStyle(styleB.id, from: registry)

        XCTAssertNil(result[styleB.id], "the deleted style is gone")
        XCTAssertNotNil(result[styleA.id], "the root is untouched")
        XCTAssertEqual(result[styleC.id]?.basedOn, styleA.id, "the leaf now points directly at the root - no dangling basedOn")
    }

    func testDeletingARootStyleRebindsItsChildrenToNilInsteadOfDangling() {
        let root = StyleDefinition(name: "Root", family: .paragraph, basedOn: nil)
        let child = StyleDefinition(name: "Child", family: .paragraph, basedOn: root.id)
        let registry: [UUID: StyleDefinition] = [root.id: root, child.id: child]

        let result = StyleRegistry.deletingStyle(root.id, from: registry)

        XCTAssertNil(result[root.id])
        XCTAssertNil(result[child.id]?.basedOn, "the child becomes a new root, not a dangling reference")
    }

    func testDeletingAnAbsentStyleIsANoOp() {
        let styleA = StyleDefinition(name: "A", family: .paragraph)
        let registry: [UUID: StyleDefinition] = [styleA.id: styleA]
        let result = StyleRegistry.deletingStyle(UUID(), from: registry)
        XCTAssertEqual(result, registry)
    }

    func testDeletingStyleDoesNotDisturbUnrelatedStyles() {
        let styleA = StyleDefinition(name: "A", family: .paragraph)
        let unrelated = StyleDefinition(name: "Unrelated", family: .character)
        let registry: [UUID: StyleDefinition] = [styleA.id: styleA, unrelated.id: unrelated]

        let result = StyleRegistry.deletingStyle(styleA.id, from: registry)

        XCTAssertNil(result[styleA.id])
        XCTAssertEqual(result[unrelated.id], unrelated)
    }
}
