import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraScrubRules.swift
// doc comment (usage dataset spec section 8) -- "versioned, reviewable
// pattern rules for secrets, keys, credentials, paths, addresses, phone
// numbers, account identifiers", the shared rule list behind both the
// scrub wall and the read-only probe, and `TesseraProbeClass`'s mapping
// from rule id to a human display class (never the matched content).
final class TesseraScrubRulesTests: DoctrineTestCase {

    // MARK: - scrub(): fixtures, one per documented rule (rule 9)

    func testScrubRedactsAPEMPrivateKeyBlock() {
        let text = "before\n-----BEGIN PRIVATE KEY-----\nMIIBVQ==\n-----END PRIVATE KEY-----\nafter"
        let scrubbed = TesseraScrubRules.scrub(text)
        XCTAssertTrue(scrubbed.contains("[REDACTED PRIVATE KEY]"))
        XCTAssertFalse(scrubbed.contains("MIIBVQ=="))
    }

    func testScrubRedactsABearerToken() {
        let scrubbed = TesseraScrubRules.scrub("Authorization: Bearer abc123XYZ.token-value")
        XCTAssertTrue(scrubbed.contains("Bearer [REDACTED]"))
        XCTAssertFalse(scrubbed.contains("abc123XYZ"))
    }

    func testScrubRedactsAnOpenAIStyleSecretKey() {
        let scrubbed = TesseraScrubRules.scrub("key: sk-abcdefghijklmnop")
        XCTAssertTrue(scrubbed.contains("sk-[REDACTED]"))
        XCTAssertFalse(scrubbed.contains("sk-abcdefghijklmnop"))
    }

    func testScrubRedactsACredentialAssignmentLine() {
        let scrubbed = TesseraScrubRules.scrub("API_KEY=supersecretvalue123")
        XCTAssertTrue(scrubbed.contains("[REDACTED]"))
        XCTAssertFalse(scrubbed.contains("supersecretvalue123"))
    }

    func testScrubRedactsAnEmailAddress() {
        let scrubbed = TesseraScrubRules.scrub("contact me at jane.doe@example.com please")
        XCTAssertEqual(scrubbed, "contact me at [REDACTED EMAIL] please")
    }

    func testScrubRedactsAPhoneNumber() {
        let scrubbed = TesseraScrubRules.scrub("call me at 415-555-0132 today")
        XCTAssertTrue(scrubbed.contains("[REDACTED PHONE]"))
        XCTAssertFalse(scrubbed.contains("415-555-0132"))
    }

    func testScrubRedactsAnAbsoluteUsersPath() {
        let scrubbed = TesseraScrubRules.scrub("see /Users/jdoe/Documents/secret.txt for details")
        XCTAssertTrue(scrubbed.contains("[REDACTED PATH]"))
        XCTAssertFalse(scrubbed.contains("jdoe"))
    }

    func testScrubOfPlainTextWithNoSensitiveContentIsUnchanged() {
        let text = "This is a perfectly ordinary sentence about quantization."
        XCTAssertEqual(TesseraScrubRules.scrub(text), text)
    }

    func testScrubAppliesAllRulesInOnePass() {
        let text = "email jane@example.com, key sk-abcdefghij, path /Users/jdoe/x"
        let scrubbed = TesseraScrubRules.scrub(text)
        XCTAssertTrue(scrubbed.contains("[REDACTED EMAIL]"))
        XCTAssertTrue(scrubbed.contains("sk-[REDACTED]"))
        XCTAssertTrue(scrubbed.contains("[REDACTED PATH]"))
    }

    // MARK: - probe(): ids only, never the matched content (rule 9)

    func testProbeReturnsTheMatchingRuleIDsInRuleOrder() {
        let text = "email jane@example.com and path /Users/jdoe/x"
        let ids = TesseraScrubRules.probe(text)
        XCTAssertEqual(ids, ["email", "fs-path"], "probe must return ids in TesseraScrubRules.all's declared order")
    }

    func testProbeOnCleanTextReturnsEmpty() {
        XCTAssertEqual(TesseraScrubRules.probe("nothing sensitive here at all"), [])
    }

    func testProbeNeverIncludesTheMatchedContentItself() {
        let text = "secret sk-abcdefghijklmno here"
        let ids = TesseraScrubRules.probe(text)
        for id in ids {
            XCTAssertFalse(id.contains("sk-abcdefghijklmno"), "the probe must report only rule ids, never matched content")
        }
    }

    // MARK: - version / requiredVersionStamp

    func testVersionStampFormat() {
        XCTAssertEqual(TesseraScrubRules.requiredVersionStamp, ">=\(TesseraScrubRules.version)")
    }

    // MARK: - TesseraProbeClass: independent oracle (rule 7) mapping
    // pinned against the doc comment's rule-id groupings, not against
    // TesseraScrubRules.all's own contents.

    func testLabelForRuleMapsSecretsRulesToSecretsClass() {
        for id in ["pem-key", "bearer-token", "secret-key", "credential-assignment"] {
            XCTAssertEqual(TesseraProbeClass.label(forRule: id), TesseraProbeClass.secrets, "\(id) must map to Secrets")
        }
    }

    func testLabelForRuleMapsContactRulesToContactInfoClass() {
        for id in ["email", "phone"] {
            XCTAssertEqual(TesseraProbeClass.label(forRule: id), TesseraProbeClass.contactInfo, "\(id) must map to Contact info")
        }
    }

    func testLabelForRuleMapsFsPathToPathsClass() {
        XCTAssertEqual(TesseraProbeClass.label(forRule: "fs-path"), TesseraProbeClass.paths)
    }

    func testLabelForUnknownRuleIDFallsBackToTheIDItself() {
        XCTAssertEqual(TesseraProbeClass.label(forRule: "some-future-rule"), "some-future-rule")
    }

    func testEveryRuleInAllHasAClassMapping() {
        // Every rule id declared in TesseraScrubRules.all must resolve to
        // one of the three named classes (not silently fall through to
        // the unknown-id passthrough), so the quarantine surface never
        // shows a raw rule id to the user for a currently-shipped rule.
        let knownClasses: Set<String> = [TesseraProbeClass.secrets, TesseraProbeClass.contactInfo, TesseraProbeClass.paths]
        for rule in TesseraScrubRules.all {
            XCTAssertTrue(knownClasses.contains(TesseraProbeClass.label(forRule: rule.id)), "\(rule.id) has no class mapping")
        }
    }

    // MARK: - classes(forLedgerReasons:)

    func testClassesForLedgerReasonsMapsProbePrefixedReasons() {
        let classes = TesseraProbeClass.classes(forLedgerReasons: ["probe:email", "probe:fs-path"])
        XCTAssertEqual(classes, [TesseraProbeClass.contactInfo, TesseraProbeClass.paths])
    }

    func testClassesForLedgerReasonsMapsModelMismatch() {
        let classes = TesseraProbeClass.classes(forLedgerReasons: ["model-mismatch"])
        XCTAssertEqual(classes, [TesseraProbeClass.modelMismatch])
    }

    func testClassesForLedgerReasonsSkipsProbeNone() {
        let classes = TesseraProbeClass.classes(forLedgerReasons: ["probe:none"])
        XCTAssertEqual(classes, [])
    }

    func testClassesForLedgerReasonsIgnoresUnrecognizedReasons() {
        let classes = TesseraProbeClass.classes(forLedgerReasons: ["some-other-reason"])
        XCTAssertEqual(classes, [])
    }

    func testClassesForLedgerReasonsDeduplicatesInFirstSeenOrder() {
        let classes = TesseraProbeClass.classes(forLedgerReasons: ["probe:email", "probe:phone", "probe:pem-key"])
        // email and phone both map to "Contact info"; pem-key maps to
        // "Secrets" -- dedup keeps first-seen order.
        XCTAssertEqual(classes, [TesseraProbeClass.contactInfo, TesseraProbeClass.secrets])
    }
}
