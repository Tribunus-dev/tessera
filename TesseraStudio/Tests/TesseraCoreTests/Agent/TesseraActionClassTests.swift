import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraActionClass.swift doc
// comments -- the three pattern shapes (verb-prefix, path-glob, arg-shape),
// the tool-only fallback, and the irreversible guard (autonomy spec
// section 4): "RULES, not ML. No learned component may override this."
final class TesseraActionClassTests: DoctrineTestCase {

    // MARK: - Pattern shape 1: verb-prefix (shell-like tools)

    func testShellCommandClassifiesAsToolColonProgram() {
        let action = PendingAction(toolName: "bash", arguments: ["command": .string("git status")])
        XCTAssertEqual(TesseraActionClass.classify(action), "bash:git")
    }

    func testShellCommandStripsLeadingPath() {
        let action = PendingAction(toolName: "bash", arguments: ["command": .string("/usr/bin/git status")])
        XCTAssertEqual(TesseraActionClass.classify(action), "bash:git")
    }

    func testShellCommandIsCaseInsensitiveOnTheProgramToken() {
        let action = PendingAction(toolName: "bash", arguments: ["command": .string("GIT status")])
        XCTAssertEqual(TesseraActionClass.classify(action), "bash:git")
    }

    func testShellFragmentMatchOnTerminalToolName() {
        let action = PendingAction(toolName: "terminal_run", arguments: ["cmd": .string("npm install")])
        XCTAssertEqual(TesseraActionClass.classify(action), "terminal_run:npm")
    }

    func testShellCommandWithNoCommandArgumentFallsBackToToolName() {
        let action = PendingAction(toolName: "bash", arguments: [:])
        XCTAssertEqual(TesseraActionClass.classify(action), "bash")
    }

    // MARK: - Pattern shape 2: path-glob (file tools)

    func testFileWritePathCollapsesToOneSegmentGlobByDefault() {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("src/foo/bar.swift")])
        XCTAssertEqual(TesseraActionClass.classify(action), "file_write:src/**")
    }

    func testFileWritePathGlobDepthControlsSegmentCount() {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("src/foo/bar.swift")])
        XCTAssertEqual(TesseraActionClass.classify(action, pathGlobDepth: 2), "file_write:src/foo/**")
    }

    func testAbsolutePathCollapsesToExternal() {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("/etc/passwd")])
        XCTAssertEqual(TesseraActionClass.classify(action), "file_write:<external>")
    }

    func testHomeRelativePathCollapsesToExternal() {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("~/secrets.txt")])
        XCTAssertEqual(TesseraActionClass.classify(action), "file_write:<external>")
    }

    func testParentRelativePathCollapsesToExternal() {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("../outside/file.txt")])
        XCTAssertEqual(TesseraActionClass.classify(action), "file_write:<external>")
    }

    func testFileToolFragmentMatchOnReadToolName() {
        let action = PendingAction(toolName: "file_read", arguments: ["path": .string("docs/readme.md")])
        XCTAssertEqual(TesseraActionClass.classify(action), "file_read:docs/**")
    }

    // MARK: - Pattern shape 3: arg-shape (everything else with arguments)

    func testArgShapeClassIsToolNameHashOfSortedKeys() {
        let action = PendingAction(toolName: "quantize", arguments: [
            "model_path": .string("a"), "output_path": .string("b"), "policy_path": .string("c"),
        ])
        let classified = TesseraActionClass.classify(action)
        XCTAssertTrue(classified.hasPrefix("quantize#"))
    }

    func testArgShapeClassIsStableAcrossDifferentValuesForSameKeys() {
        let a = PendingAction(toolName: "quantize", arguments: ["model_path": .string("a"), "output_path": .string("b")])
        let b = PendingAction(toolName: "quantize", arguments: ["model_path": .string("x"), "output_path": .string("y")])
        XCTAssertEqual(TesseraActionClass.classify(a), TesseraActionClass.classify(b))
    }

    func testArgShapeClassDiffersForDifferentKeySets() {
        let a = PendingAction(toolName: "quantize", arguments: ["model_path": .string("a")])
        let b = PendingAction(toolName: "quantize", arguments: ["output_path": .string("a")])
        XCTAssertNotEqual(TesseraActionClass.classify(a), TesseraActionClass.classify(b))
    }

    // MARK: - Fallback: tool-only

    func testToolWithNoArgumentsAndNoFragmentMatchFallsBackToToolName() {
        let action = PendingAction(toolName: "list_models", arguments: [:])
        XCTAssertEqual(TesseraActionClass.classify(action), "list_models")
    }

    // MARK: - Classification is deterministic (doc comment: "Deterministic
    // and pure: same action -> same class, always")

    func testClassificationIsDeterministic() {
        let action = PendingAction(toolName: "bash", arguments: ["command": .string("git status")])
        let first = TesseraActionClass.classify(action)
        for _ in 0..<10 {
            XCTAssertEqual(TesseraActionClass.classify(action), first)
        }
    }

    // MARK: - Irreversible guard (autonomy spec section 4): RULES, not ML

    func testDestructiveVerbHeadIsIrreversible() {
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:rm", risk: .low))
    }

    func testNonDestructiveVerbHeadIsNotIrreversibleAtLowRisk() {
        XCTAssertFalse(TesseraActionClass.isIrreversible("bash:git", risk: .low))
    }

    func testHighRiskIsAlwaysIrreversibleRegardlessOfVerb() {
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:git", risk: .high))
    }

    func testForbiddenRiskIsAlwaysIrreversible() {
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:git", risk: .forbidden))
    }

    func testExternalPathFileWriteIsIrreversible() {
        XCTAssertTrue(TesseraActionClass.isIrreversible("file_write:<external>", risk: .low))
    }

    func testManualDenylistEntryIsIrreversible() {
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:git", risk: .low, denylist: ["bash:git"]))
    }

    func testMediumRiskReversibleActionIsNotIrreversible() {
        XCTAssertFalse(TesseraActionClass.isIrreversible("file_write:src/**", risk: .medium))
    }

    // MARK: - Every destructive verb in the denylist is irreversible at
    // low risk (rule 9: property test over the documented verb set).

    func testEveryDestructiveVerbIsIrreversibleAtLowRisk() {
        let verbs = ["rm", "rmdir", "del", "delete", "drop", "purge", "erase",
                     "format", "mkfs", "dd", "shred", "sudo", "chmod", "chown",
                     "kill", "shutdown", "reboot"]
        for verb in verbs {
            XCTAssertTrue(
                TesseraActionClass.isIrreversible("bash:\(verb)", risk: .low),
                "\(verb) must be irreversible"
            )
        }
    }
}
