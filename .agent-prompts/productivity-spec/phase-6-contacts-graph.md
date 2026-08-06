# Phase 6 — Contacts + Graph visualization for the Tessera productivity surface

## Context

Tessera Studio is a privacy-first macOS + iOS app. Phase 1 of the productivity surface is on `feat/prod-foundations` (committed, tests pass). It shipped the Block AST, Mutation API, Receipt infrastructure, ReceiptUndoManager, two-cursor data model, chat queue data model, and `DocumentStore`.

The full productivity spec is at `docs/tessera-productivity-design.md` (1115 lines, on branch `feat/productivity-spec`). Sections §12.7 (Contacts) and §12.8 (Graph visualization) are the canonical source. **Read them first.**

Your job is Phase 6: the Contacts material type (a first-class `graph_entity` with importer for Apple Contacts, VCard, Google, CardDAV) AND the Graph visualization surface (a force-directed view of all materials + relationships, using `Grape` from SwiftGraphs).

## Working environment

- Main checkout: `/Users/user/Developer/GitHub/tessera`
- Branch off `feat/prod-foundations`: `git fetch . && git worktree add worktrees/prod-contacts-graph -b feat/prod-contacts-graph feat/prod-foundations`
- New code under `TesseraStudio/Sources/TesseraCore/Productivity/Contacts/` and `TesseraStudio/Sources/TesseraCore/Productivity/Graph/`, plus `TesseraStudio/Sources/TesseraStudioMac/Views/Contacts/` and `TesseraStudio/Sources/TesseraStudioMac/Views/Graph/`
- Tests under `TesseraStudio/Tests/TesseraCoreTests/Productivity/Contacts/` and `TesseraStudio/Tests/TesseraCoreTests/Productivity/Graph/`
- Per AGENTS.md: no push, no PR. `Assisted-by: MiniMax`.

## Phase 6 deliverables

### 1. Contact entity model

```swift
public struct Contact: Codable, Sendable, Identifiable {
    public let id: UUID
    public var subtype: Subtype          // .person | .organization | .group
    public var name: NameComponents
    public var emails: [LabeledEmail]
    public var phones: [LabeledPhone]
    public var addresses: [LabeledAddress]
    public var organization: String?
    public var title: String?
    public var birthday: Date?
    public var photo: Data?
    public var notes: String?
    public var sourceURL: String?
    public var linkedEntityIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date
    public enum Subtype: String, Codable, Sendable { case person, organization, group }
}

public struct LabeledEmail: Codable, Sendable { /* label, value, isPrimary */ }
public struct LabeledPhone: Codable, Sendable { /* same shape */ }
public struct LabeledAddress: Codable, Sendable { /* same shape */ }
public struct NameComponents: Codable, Sendable { /* prefix, first, middle, last, suffix, nickname */ }
```

Storage: `graph_entity` row with `entity_type = 'contact'`, `subtype`, `body` = JSONB with the contact fields.

Migration `0003_contacts.sql`:
```sql
CREATE INDEX idx_entities_contact_name ON graph_entities (entity_type, label) WHERE entity_type = 'contact';
```

**Tests:** Contact round-trips JSON; each subtype serializes; linked entity IDs stored/retrieved; name queries are fast for 10k+ contacts.

### 2. Apple Contacts importer (CNContactStore, macOS)

```swift
public actor AppleContactsAdapter {
    public init() throws
    public func requestAccess() async throws -> Bool
    public func fetchAllContacts() async throws -> [Contact]
    public func fetchContact(identifier: String) async throws -> Contact?
    public func startObservingChanges() -> AsyncStream<ContactChange>
}
```

Uses Apple's `Contacts` framework. Entitlement: production needs `com.apple.developer.contacts` (granted on request). Dev-preview uses entitlement-free VCard path via `NSWorkspace.shared.open(_:)`.

**Tests:** CNContact → Contact translation; VCard round-trip; permission denied graceful; empty address book = empty array.

### 3. VCard importer (no entitlement)

```swift
public actor VCardImporter {
    public init()
    public func parse(data: Data) throws -> [Contact]
    public func parse(fileURL: URL) throws -> [Contact]
    public func serialize(contacts: [Contact]) throws -> Data
    public func write(contacts: [Contact], to fileURL: URL) throws
}
```

`CNContactVCardSerialization` for parse + serialize.

**Tests:** known `.vcf` parses; round-trip; multiple contacts; empty file; malformed → typed error.

### 4. Google Contacts importer (opt-in, OAuth)

```swift
public actor GoogleContactsAdapter {
    public struct Configuration { var clientID, clientSecret, redirectURI: String }
    public init(configuration: Configuration) throws
    public func authenticate() async throws -> GoogleOAuthToken
    public func fetchAllContacts() async throws -> [Contact]
    public func refreshTokenIfNeeded() async throws
}
```

Google People API (`https://people.googleapis.com/v1/people/me/connections`). OAuth via `ASWebAuthenticationSession`. Client ID + secret in Settings. Token in Keychain (via existing `TesseraKeychainVolume`).

**Tests:** mock API response, verify translation; token refresh; OAuth flow skip in tests (test token-usage path).

### 5. CardDAV importer (opt-in, XML-over-HTTP)

```swift
public actor CardDAVCImporter {
    public struct Configuration { var serverURL, username, password: String }
    public init(configuration: Configuration) throws
    public func discoverPrincipal() async throws -> URL
    public func discoverAddressBookURL() async throws -> URL
    public func fetchAllContacts() async throws -> [Contact]
    public func fetchChanges(since syncToken: String) async throws -> ContactDelta
}
```

CardDAV is XML over HTTP (RFC 6352). Implement directly using Apple's `XMLParser`. Supports iCloud, Fastmail, Nextcloud, etc.

**Tests:** mock server responses, verify PROPFIND/REPORT parsing; sync token handling; Basic auth with app-specific password.

### 6. Contacts surface (SwiftUI)

```swift
public struct ContactsView: View {
    public init(adapter: ContactsAdapterProvider)
    public var body: some View
}
```

macOS: `NavigationSplitView` (sidebar search/filter, list, detail). iOS: `NavigationStack`. Uses data layer's `hybrid_search` filtered to `entity_type = 'contact'`.

**Tests:** loads contacts; search filters; detail shows correct info; "Link to..." creates entity_link + receipt.

### 7. Graph visualization (Grape)

```swift
public struct GraphView: View {
    public init(dataLayer: TesseraDataLayer)
    public var body: some View
}
```

Add `https://github.com/SwiftGraphs/Grape` (v1.1.0+, Jan 2025) to `TesseraStudio/Package.swift`. SwiftUI-native, 2D simd, KDTree for spatial partitioning.

```swift
// In Package.swift
dependencies: [
    .package(url: "https://github.com/SwiftGraphs/Grape", from: "1.1.0"),
]
```

Layout: sidebar (filter chips + search) + canvas (force-directed) + detail (selected entity).

Node styling:
- **Size**: by importance (degree centrality, or pinned, or recency)
- **Color**: by entity_type (document = blue, task = green, contact = orange, etc.)
- **Label**: truncated to 30 chars
- **Icon**: small SF Symbol

Edge styling:
- **Color**: by link_type
- **Thickness**: by weight
- **Style**: solid (normal) / dashed (superseded) / dotted (voided)

**Tests:** viewmodel loads nodes/edges; filter chips filter; click selects; double-click opens; performance: 1000+ nodes < 100ms initial layout, 60fps interaction.

### 8. Progressive disclosure

For 1000s of `graph_entities`:
- Initial view: top 50 by importance (pinned + recent)
- Slider: 1 hop / 2 hops / 3 hops / all
- Force simulation: incremental updates, KDTree for many-body force

**Tests:** initial view shows pinned + recent; slider to 2 hops expands correctly; 5000-node layout < 1s.

### 9. Graph interactions

- Pan/zoom (pinch iOS, trackpad + Cmd-+/- macOS)
- Click to select (pulse, detail updates)
- Double-click to open (in native surface)
- Drag to select multiple
- Cmd-F to find (highlights + pans to first match)
- Right-click / long-press for context menu (Open, Link to..., Show related, Delete)

**Tests:** pan/zoom moves camera; click selects; double-click invokes open; right-click shows menu; "Link to..." creates entity_link + receipt.

### 10. Contact ↔ Agent integration

Agent's contact view is `hybrid_search` with `entity_type = 'contact'` filter. No special-case API.

Agent can answer:
- "What's John's email?" — hybrid_search with name filter
- "Who works at Acme?" — filter by organization
- "Find everyone I've emailed in the last month" — join with email surface

**Tests:** hybrid_search with contact filter returns only contacts; name lookup is fast; queries logged as receipts.

### 11. Privacy

- Every contact mutation is a constitutional receipt
- Contact data in Postgres, encrypted-volume (Plea the Fifth) covers it
- Contact export gated by `TesseraEgressGuard`, logged as `receipt_type = 'contact_export'`

**Tests:** every mutation produces a receipt; contact export through EgressGuard is logged; receipts reference correct entity_id.

### 12. Library survey

| Need | Library | Decision |
|---|---|---|
| Apple Contacts | `Contacts` framework | Adopt |
| Google People API HTTP | `URLSession` | Adopt |
| Google OAuth | `ASWebAuthenticationSession` | Adopt |
| CardDAV XML | `XMLParser` (Foundation) | Adopt |
| Graph visualization | `Grape` (SwiftGraphs) | Adopt |
| OAuth token storage | Keychain (existing infra) | Adopt |

### 13. Design doc

Write `docs/tessera-productivity-contacts-graph-design.md` (matching format). Sections: 1) Problem, 2) Why this design, 3) Contact model, 4) Apple Contacts importer, 5) VCard importer, 6) Google Contacts, 7) CardDAV, 8) Contacts surface, 9) Graph visualization (Grape), 10) Progressive disclosure, 11) Graph interactions, 12) Contact ↔ Agent, 13) Privacy, 14) Library survey, 15) Test strategy, 16) Out of scope.

## Hard constraints

- No SaaS, no API keys for the core (only opt-in Google + CardDAV)
- Apple Silicon native, macOS + Linux compatible
- 619 existing tests stay green
- `Assisted-by: MiniMax`, no push, no PR

## Out of scope

- Phase 2: editor
- Phase 3: chat panel + receipt drawer
- Phase 4: importer/exporter
- Phase 5: per-Materials-surface wrappers
- LinkedIn (v2), Google write-back (v2), real-time sync (v2), 3D graph (v2)

## Worker report

Files touched (with line counts); new tests (with pass/fail); performance (1000-node layout, 5000-node); library survey decisions; punts; "how to use"; screenshot/ASCII sketch of graph view.

Branch: `feat/prod-contacts-graph`. Worktree: `worktrees/prod-contacts-graph/`. No push, no PR.
