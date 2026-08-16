# Dual-agent egress design: grants, postures, and the Tessy/Sky boundary

**Status:** proposal for architect ratification (decision 18 candidate).
Written 2026-08-15 after a code review of the shipped dual-agent surface.
Companion: `procurement-readiness-2026-08-15.md` (in progress - the
government/corporate evidence for the managed posture requirements).
**One immediate integrity item rides ahead of ratification:** section 2.

## 1. Verified current state (the gap this design closes)

Read at tip on `scratch/studio-p1/agent-a`:

- `Agent/TesseraDualAgentRouter.swift:26-39` - routing is a keyword
  heuristic (8 sensitive words, 12 complex words, length > 120), ported
  from the Linux demo. Rule at :54-61: `useSky = complex`, INDEPENDENT of
  sensitive.
- `Agent/TesseraDualAgentController.swift:149-151` - when Sky fires it
  receives the VERBATIM prompt; :162-163 builds ONE shared history for
  both agents, so Sky also receives the full transcript, including
  Tessy's prior replies (which may quote personal context Tessy read
  locally).
- `:78-88` - BOTH loops get `TesseraToolRegistry.default`: cloud-Sky
  carries the same local read tools as Tessy (notes/mail/graph), and tool
  RESULTS flow back through Sky's cloud conversation.
- `:135-144` + `:275-289` - the collab trace prints canned strings
  claiming "the raw personal context stays on device" while the raw
  prompt is being sent; `seedCollabTraceIfNeeded` fabricates a demo
  exchange. `CollabTraceEntry` (:33-38) is ephemeral in-memory state
  (bare `Date()`, unsigned, unpersisted).
- No tier gates the Sky path; no receipt records egress. A tier-2
  confirmation guards a file export while a keyword miss sends content to
  a cloud provider silently.

Verdict the design inherits: the boundary is persona-deep (system-prompt
sentences, `AgentPersona.swift:39-56`), not structural. The five doctrine
test files pin the heuristic's behavior faithfully; the boundary promise
has no mechanism to pin.

## 2. Immediate integrity fix (ships with the next commit, no ratification needed)

Remove the canned collab-trace claims (`:135-144`) and the demo seeding
(`:275-289`). Until the grant mechanism exists, the UI must not assert
"the raw personal context stays on device" - same law as no-receipt-
without-a-mutation: no claim without a mechanism. The trace surface
stays; it renders real grant data once section 3 lands.

## 3. The egress-grant mechanism (design contract)

Principle inversion: today Sky is kept out by classification; after this,
**Sky starts structurally blind and every crossing is an explicit,
tiered, receipted grant.**

### 3a. EgressGrant + SkyBriefing

- Files: `TesseraCore/Agent/EgressGrant.swift` (new, peer of
  `AgentPersona`), `TesseraCore/Agent/SkyBriefingBuilder.swift` (new,
  peer of `ChatGraphBuilder`).
- Types:

```swift
public struct SkyBriefing: Codable, Sendable, Hashable {
    public var taskText: String                 // abstracted or user-approved verbatim
    public var attachments: [BriefingAttachment] // each: excerpt + sourceEntityID + contentHash
    public var briefingHash: String              // sha256 of canonical encoding
}
public struct EgressGrant: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var briefing: SkyBriefing
    public var provider: String                  // model endpoint identity
    public var approvedAt: Date
    public var tier: TesseraTier                 // always >= tier2 (egress class)
    public var posture: AppPosture               // .personal | .managed(orgPolicyID)
}
```

- Flow: Tessy (local model) drafts the briefing - extractive redaction
  in v1, user-editable ALWAYS - the grant preview shows EXACTLY the
  bytes that will leave (diffable against source), approval is a tier-2
  action through the existing `TesseraApprovalEngine`, and the approval
  emits `agent_egress_granted` (payload: grant id, briefing hash,
  attachment content hashes, provider, persona) through the receipts
  pipeline. Team-up becomes: Tessy drafts -> user approves -> Sky
  reasons over the briefing ONLY -> Tessy synthesizes locally.
- Denial/expiry: grants are single-conversation scoped; a new Sky thread
  needs a new grant. No standing grants in v1 (managed mode may add
  org-scoped standing grants later; not now).

### 3b. Scoped tool registries

- `TesseraToolRegistry.default` splits into `.tessy` (unchanged roster)
  and `.sky` (constructed by SUBTRACTION: no personal-context read
  tools; every remaining read is grant-mediated). The registry
  difference IS the boundary. `TesseraDualAgentController.init` wires
  `.sky` into the Sky loop.
- Doctrine trap guard: `testSkyRegistryContainsNoPersonalReadTools`
  pins the subtraction against an independent hardcoded list of the
  personal-read tool names.

### 3c. Partitioned histories

- Sky's conversation store contains only: Sky's own bubbles + briefings
  received via grants. The shared-transcript build at
  `TesseraDualAgentController.swift:162` is replaced by per-persona
  history assembly; the only crossing is `append(briefing:)` guarded by
  a grant id.

### 3d. Receipts stamp the persona

- Every receipt payload gains `agent: "human" | "tessy" | "sky"` (and
  for sky, the provider). Three-way provenance - who edited this
  document - becomes queryable and exportable.

### 3e. Router demoted to suggestion

- `DualAgentRouter` keeps its API but its output becomes a UI HINT
  ("looks complex - bring in Sky?"). The only egress paths are explicit
  @-mentions and the grant flow. Keyword misclassification becomes a UX
  nit, not a privacy event. Later: Tessy's local model generates the
  suggestion instead of keywords (cheap with the engine; not v1).

### 3f. The boundary tests (the named doctrine contracts)

1. `testSkyProviderNeverReceivesContentAbsentFromAnApprovedGrant` - spy
   provider at the `stream(...)` seam captures every byte sent; assert
   set-inclusion against the union of approved briefings. THE product
   promise in executable form.
2. `testTeamUpSendsBriefingOnlyToSkyWhileTessySeesFullContext`.
3. `testEgressGrantApprovalEmitsExactlyOneReceiptWithBriefingHash`.
4. `testSkyHistoryContainsOnlyOwnThreadAndGrantedBriefings`.
5. Registry trap guard (3b) + `testDeniedGrantSendsNothingAndReceiptsNothing`.

Effort: M (one wave unit). The briefing/grant types, registry split,
history partition, and receipts are mechanical against existing
infrastructure; extractive redaction quality is the only novel part and
v1 is user-edited.

## 4. Posture scoping: personal vs managed

One binary, two postures, one rule: **org policy can only TIGHTEN, never
loosen** (the revoke-only tier precedent, applied org-wide). `AppPosture`
is a runtime value, not a build flavor.

| Surface | Personal (default) | Managed (org-enrolled) |
|---|---|---|
| Identity | none required | WorkOS AuthKit SSO; SCIM-provisioned |
| Sky availability | on by default, grant-gated | org policy: disabled / allowlisted providers / grant-gated with org tier floor |
| Grant approval | user approves at tier2 | user approves AND org policy evaluates (FGA): doc classes, roles, provider allowlist; denials show "blocked by <org> policy" with the policy name |
| Grant preview | full preview, editable | full preview, editable; org may require justification text on the grant |
| Receipts | local only; user-exportable | streamed to WorkOS Audit Logs (signed, persona-stamped); local copy retained |
| Purge / secure overwrite / Plead-the-Fifth | fully available | DISABLED or retention-policy-governed (records-law requirement; see procurement doc); deletion attestations become the defensible-disposal record |
| Router suggestion | on | org-configurable (off for air-gapped postures) |
| Posture visibility | none | persistent badge (org name) on the chat surface + settings; Sky's avatar carries a policy chip |
| Model management | user-chosen local models | org may pin/allowlist local model builds |

Plumbing:

- **Policy transport:** MDM managed app configuration (the AppConfig
  standard - Jamf/Kandji push a plist) carries the ENROLLMENT (org id,
  WorkOS environment, posture=managed); live policy (Sky rules, tier
  floors, provider allowlists) is fetched from the org control plane and
  cached signed, so an offline Mac keeps enforcing the last-known
  policy. Two layers deliberately: MDM proves device management; the
  control plane carries fast-moving policy.
- **Where policy evaluates:** the same choke points the personal flow
  uses - `TesseraApprovalEngine` (grant approval) and the registry
  constructor (Sky roster). Managed mode adds an evaluator, never a
  second path. One mechanism, both worlds.
- **Failure posture:** policy fetch failure = most-restrictive cached
  state; never fail-open to personal.
- Files: `TesseraCore/Agent/AppPosture.swift`,
  `TesseraCore/Settings/ManagedPolicy.swift` (+ AppConfig keys doc),
  evaluator hook in `TesseraApprovalEngine`. Effort: S-M on top of 3.
- Posture tests: `testManagedPolicyOnlyTightensNeverLoosens` (property
  test over random policy/user-setting pairs),
  `testPolicyFetchFailureFallsBackToMostRestrictiveCachedState`,
  `testPurgeSurfacesAreAbsentInManagedPostureWithRetentionPolicy`.

## 5. Sequencing

- Section 2 (canned-claim removal): immediate, rides the next commit.
- Section 3 (grant mechanism): one wave unit; slots as the opener of
  Wave P2-D (it is that wave's soul: macros/forms/database/tagged-PDF
  all assume the trust story is real) or as a standalone wave E before
  it. Recommendation: P2-D opener.
- Section 4 (postures): S-M; P2-D alongside D3/D4, since the WorkOS
  conversation needs a demo of exactly this.
- The procurement-readiness doc (in progress) feeds section 4's managed
  requirements; its findings may add rows to the posture matrix but do
  not change the mechanism.

## 6. Procurement-driven amendments (2026-08-15, from procurement-readiness-2026-08-15.md)

The research landed three BINDING corrections on this design:

1. **The control plane gets a seam.** Section 4's managed plumbing must
   not hard-wire WorkOS: government segments cannot use it (no
   FedRAMP/GovRAMP; DFARS 7012 excludes it from CUI paths outright).
   New: `OrgControlPlane` protocol with two providers - `.workOS`
   (commercial) and `.directFederation` (customer IdP via SAML/OIDC +
   optional direct SCIM + receipts to customer SIEM + policy via MDM
   only). Core types never reference WorkOS directly. The posture
   matrix's "Managed" column splits into managed-commercial and
   managed-government where they differ (receipts destination, IdP,
   purge policy source).
2. **Receipt signing becomes a pluggable suite.** Managed-mode default:
   ECDSA P-256 via Secure Enclave (inside Apple's FIPS 140-3 validated
   corecrypto scope); Ed25519 permitted for personal mode (its
   in-validated-scope status is unverified). All crypto in these paths
   routes through CryptoKit/Security.framework - no bundled third-party
   crypto. EgressGrant/receipt hashing stays SHA-256 (approved).
3. **Managed retention overrides the privacy features - by removal
   plus transplant, not rename.** In managed government postures the
   shipped Plead-the-Fifth feature (PleadTheFifthExecutor's
   no-confirmation hotkey, CovertTriggerMonitor's text-input phrase,
   user-discretionary invocation, WipeReportStore's unsigned deletable
   JSON) is provably absent: no invocable path, enforced by the
   posture guard tests. "Certified Disposition" is a SEPARATE managed
   feature reusing only the crypto-shred implementation and step-report
   structure: schedule-triggered, org-authorized, legal-hold-frozen,
   reported as a signed receipt in the chain. (Personal mode keeps
   Plead-the-Fifth unchanged; consider upgrading its wipe report to a
   signed receipt regardless - the current deletable-JSON report
   undersells even the personal audit-trail story.) Sky in government
   postures is BYO-endpoint only (customer-supplied authorized
   endpoint; per-grant provider/model/ZDR flag already in the receipt
   payload covers the disclosure need).

Test additions: `testDirectFederationPostureNeverContactsWorkOSEndpoints`
(spy transport), `testManagedModeReceiptSignaturesUseTheFIPSSuite`,
`testLegalHoldFreezesPurgeAndDisposition`.
