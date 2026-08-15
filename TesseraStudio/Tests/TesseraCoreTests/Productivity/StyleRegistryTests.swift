import XCTest
@testable import TesseraCore

// MARK: - StyleRegistryTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4,
// "Writer cluster" - StyleRegistry (row 9):
//   "UUID-keyed StyleDefinition (family, basedOn, next, props) in
//   DocumentMeta.styles ...; Block.attributes["styleRef"] supersedes the
//   string label; 4-layer resolution (docDefaults -> paragraph chain ->
//   character chain -> run annotations), LEAF WINS, cycle-guarded."
//   "Test: a 3-deep basedOn chain resolves matching OOXML leaf-override
//   semantics ...; style deletion REBINDS orphaned children to the deleted
//   style's own parent, never leaves a dangling basedOn reference ...;
//   a cycle (A based-on B based-on A) is guarded, not an infinite loop."
//
// Also sota-writer-slides-report.md #1 (styles): "Effective-format
// resolution order ... docDefaults -> ... -> paragraph style -> character
// style -> direct formatting; each later layer overrides the earlier."

final class StyleRegistryTests: DoctrineTestCase {

    // MARK: - Helpers

    private func style(
        id: UUID = UUID(),
        family: StyleFamily = .paragraph,
        basedOn: UUID? = nil,
        props: StyleProperties = StyleProperties()
    ) -> StyleDefinition {
        StyleDefinition(id: id, name: "s-\(id.uuidString.prefix(4))", family: family, basedOn: basedOn, props: props)
    }

    // MARK: - 4-layer resolution, 3-deep basedOn chain, leaf wins

    /// docDefaults sets alignment; a 3-deep paragraph basedOn chain (root ->
    /// mid -> leaf) each overrides ONE property; a run annotation overrides
    /// a property none of the styles touch. The leaf's own value for a
    /// property every ancestor also sets must win (OOXML leaf-override
    /// semantics, per the contract).
    func testResolveThreeDeepBasedOnChainLeafWinsOverEveryAncestor() {
        let rootID = UUID()
        let midID = UUID()
        let leafID = UUID()

        // Every layer sets fontSizePt to a DIFFERENT value; only the leaf's
        // value should survive.
        let root = style(id: rootID, props: StyleProperties(fontSizePt: 10, alignment: .leading))
        let mid = style(id: midID, basedOn: rootID, props: StyleProperties(fontSizePt: 14))
        let leaf = style(id: leafID, basedOn: midID, props: StyleProperties(fontSizePt: 18))
        let registry: [UUID: StyleDefinition] = [rootID: root, midID: mid, leafID: leaf]

        let resolved = StyleRegistry.resolve(paragraphStyleRef: leafID, registry: registry)

        XCTAssertEqual(resolved.fontSizePt, 18, "leaf's own fontSizePt must win over every ancestor's value")
        // A property only set at the root (alignment) must still resolve
        // through the whole chain - "a property only set at docDefaults
        // still resolves through all 4 layers" generalizes to "a property
        // only set at the chain's root still resolves through the chain".
        XCTAssertEqual(resolved.alignment, .leading, "a property set only at the chain's root must still resolve")
    }

    /// A property set ONLY at docDefaults (no style in the chain touches
    /// it) must still resolve through all 4 layers to the final result.
    func testResolvePropertySetOnlyAtDocDefaultsResolvesThroughAllFourLayers() {
        let paragraphID = UUID()
        let characterID = UUID()
        let docDefaults = style(props: StyleProperties(lineSpacing: 1.5))
        let paragraphStyle = style(id: paragraphID, props: StyleProperties(isBold: true))
        let characterStyle = style(id: characterID, family: .character, props: StyleProperties(isItalic: true))
        let registry: [UUID: StyleDefinition] = [paragraphID: paragraphStyle, characterID: characterStyle]

        let resolved = StyleRegistry.resolve(
            characterStyleRef: characterID,
            paragraphStyleRef: paragraphID,
            docDefaults: docDefaults,
            registry: registry
        )

        XCTAssertEqual(resolved.lineSpacing, 1.5, "docDefaults-only property must resolve through the full chain")
        XCTAssertEqual(resolved.isBold, true, "paragraph-layer property must resolve")
        XCTAssertEqual(resolved.isItalic, true, "character-layer property must resolve")
    }

    /// Full 4-layer order proof: docDefaults -> paragraph -> character ->
    /// run annotations, each layer overriding the same property so only
    /// the outermost (run annotation) value survives - "a literal run
    /// annotation always wins over anything style-derived" per the file's
    /// own doc comment.
    func testResolveFourLayerOrderRunAnnotationWinsOverEveryStyleLayer() {
        let paragraphID = UUID()
        let characterID = UUID()
        let docDefaults = style(props: StyleProperties(isBold: false))
        let paragraphStyle = style(id: paragraphID, props: StyleProperties(isBold: false))
        let characterStyle = style(id: characterID, family: .character, props: StyleProperties(isBold: false))
        let registry: [UUID: StyleDefinition] = [paragraphID: paragraphStyle, characterID: characterStyle]

        let resolved = StyleRegistry.resolve(
            runAnnotations: [.bold],
            characterStyleRef: characterID,
            paragraphStyleRef: paragraphID,
            docDefaults: docDefaults,
            registry: registry
        )

        XCTAssertEqual(resolved.isBold, true, "the run's own .bold annotation must win over every style layer setting isBold=false")
    }

    /// A dangling style ref (not present in the registry) resolves as an
    /// empty chain, not an error - "same fail-soft posture as a basedOn
    /// cycle" per the file's doc comment.
    func testResolveDanglingStyleRefResolvesAsEmptyChainNotError() {
        let resolved = StyleRegistry.resolve(paragraphStyleRef: UUID(), registry: [:])
        XCTAssertEqual(resolved, ResolvedStyle(), "a dangling ref must resolve to the empty style, not throw or crash")
    }

    // MARK: - Style deletion rebinds orphans to the deleted style's parent

    /// child -> parent -> grandparent; deleting `parent` must rebind
    /// `child.basedOn` to `grandparent.id` (never dangling), per the
    /// contract's exact construction.
    func testDeletingStyleRebindsChildToDeletedStylesOwnParent() {
        let grandparentID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let grandparent = style(id: grandparentID)
        let parent = style(id: parentID, basedOn: grandparentID)
        let child = style(id: childID, basedOn: parentID)
        let registry: [UUID: StyleDefinition] = [grandparentID: grandparent, parentID: parent, childID: child]

        let updated = StyleRegistry.deletingStyle(parentID, from: registry)

        XCTAssertNil(updated[parentID], "the deleted style must no longer be present")
        XCTAssertEqual(updated[childID]?.basedOn, grandparentID, "child.basedOn must rebind to the deleted style's own parent")
        XCTAssertNotNil(updated[grandparentID], "the grandparent must be untouched")
    }

    /// Deleting a ROOT style (basedOn == nil) makes its children new roots
    /// rather than dangling - per the doc comment's explicit case.
    func testDeletingRootStyleMakesChildrenNewRoots() {
        let rootID = UUID()
        let childID = UUID()
        let root = style(id: rootID, basedOn: nil)
        let child = style(id: childID, basedOn: rootID)
        let registry: [UUID: StyleDefinition] = [rootID: root, childID: child]

        let updated = StyleRegistry.deletingStyle(rootID, from: registry)

        XCTAssertNil(updated[rootID])
        XCTAssertNil(updated[childID]?.basedOn, "child of a deleted root becomes a new root (basedOn == nil), not dangling")
    }

    /// Deleting an id not present in the registry is a no-op - returns the
    /// registry unchanged.
    func testDeletingUnknownStyleIDIsNoOp() {
        let onlyID = UUID()
        let registry: [UUID: StyleDefinition] = [onlyID: style(id: onlyID)]
        let updated = StyleRegistry.deletingStyle(UUID(), from: registry)
        XCTAssertEqual(updated, registry)
    }

    // MARK: - Cycle guard

    /// A basedOn cycle (A based-on B based-on A) must not infinite-loop;
    /// resolution must terminate and return something sane. Backstopped
    /// by DoctrineTestCase's 30s watchdog (rule 12) in case the guard
    /// assertion itself is wrong and the walk truly hangs.
    func testResolveWithBasedOnCycleTerminatesInsteadOfLooping() {
        let aID = UUID()
        let bID = UUID()
        let a = style(id: aID, basedOn: bID, props: StyleProperties(fontSizePt: 10))
        let b = style(id: bID, basedOn: aID, props: StyleProperties(fontSizePt: 20))
        let registry: [UUID: StyleDefinition] = [aID: a, bID: b]

        // Termination IS the assertion: if `resolve` hung, the doctrine
        // watchdog fails this test by name rather than the suite hanging
        // forever.
        let resolved = StyleRegistry.resolve(paragraphStyleRef: aID, registry: registry)

        // "returns something sane": the resolved value must be one of the
        // properties actually present in the cycle, not garbage/crash.
        XCTAssertTrue(resolved.fontSizePt == 10 || resolved.fontSizePt == 20,
                       "a cycle must resolve to a value the cycle's own styles could produce, not garbage")
    }

    /// Deletion must also terminate on a cyclic registry (same guard
    /// concern, the other public entry point).
    func testDeletingStyleWithBasedOnCycleTerminates() {
        let aID = UUID()
        let bID = UUID()
        let a = style(id: aID, basedOn: bID)
        let b = style(id: bID, basedOn: aID)
        let registry: [UUID: StyleDefinition] = [aID: a, bID: b]

        let updated = StyleRegistry.deletingStyle(aID, from: registry)
        XCTAssertNil(updated[aID])
        XCTAssertNotNil(updated[bID])
    }

    // MARK: - StyleProperties.applied(over:) - leaf-wins primitive

    func testStylePropertiesAppliedOverPassesThroughNilFields() {
        let base = StyleProperties(isBold: true, fontSizePt: 12)
        let overlay = StyleProperties(isItalic: true) // isBold/fontSizePt left nil
        let result = overlay.applied(over: base)
        XCTAssertEqual(result.isBold, true, "nil overlay fields must pass the base value through unchanged")
        XCTAssertEqual(result.fontSizePt, 12)
        XCTAssertEqual(result.isItalic, true, "non-nil overlay fields must override")
    }

    func testStylePropertiesEmptyOverlayIsIdentity() {
        let base = StyleProperties(isBold: true, fontSizePt: 11, alignment: .center)
        XCTAssertTrue(StyleProperties().isEmpty)
        XCTAssertEqual(StyleProperties().applied(over: base), base)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testStyleDefinitionEncodeDecodeIdentity() throws {
        let original = StyleDefinition(
            id: UUID(),
            name: "Heading 1",
            family: .paragraph,
            basedOn: UUID(),
            next: UUID(),
            props: StyleProperties(isBold: true, fontSizePt: 24, alignment: .center)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(StyleDefinition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStyleDefinitionByteIdenticalReencode() throws {
        let original = StyleDefinition(
            id: UUID(),
            name: "Body Text",
            family: .character,
            basedOn: nil,
            next: nil,
            props: StyleProperties(textColorHex: "#112233")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let firstPass = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(StyleDefinition.self, from: firstPass)
        let secondPass = try encoder.encode(decoded)
        XCTAssertEqual(firstPass, secondPass, "decode -> re-encode must be byte-identical for a canonical-serialization type")
    }

    // MARK: - Block.styleRef bridge

    func testBlockStyleRefRoundTripsThroughAttributes() {
        var block = Block(type: .paragraph)
        XCTAssertNil(block.styleRef, "no styleRef attribute set yet")
        let styleID = UUID()
        block.styleRef = styleID
        XCTAssertEqual(block.attributes["styleRef"]?.stringValue, styleID.uuidString)
        XCTAssertEqual(block.styleRef, styleID)
        block.styleRef = nil
        XCTAssertNil(block.attributes["styleRef"], "setting nil must remove the attribute key entirely")
    }
}
