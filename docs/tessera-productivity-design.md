# Tessera Productivity Surface — Design Spec

**Status:** Draft v0.1 (architect review pending)
**Author:** Mavis (for the architect)
**Date:** 2026-08-05
**Companion:** `docs/tessera-productivity-ux-research.md` (the deep rationale; this spec is the source of truth, the UX research doc is the evidence)
**Sister specs:** `docs/tessera-plead-the-fifth-design.md`, `docs/tessera-data-layer-design.md`

---

## 1. Problem

Tessera is a privacy-first macOS + iOS app with a constitutional-receipts backbone and a `Plea the Fifth` crypto-shred escape hatch. The data layer (`docs/tessera-data-layer-design.md`) is now on `main`: Postgres + Valkey, a knowledge graph of `graph_entities` / `entity_links` / `graph_receipts`, and a Swift `TesseraDataLayer` facade that the productivity surface builds on.

What we have not yet built is the user-facing productivity surface — the part of the app that competes with Notion / Coda / Craft / Bear for the user's daily work. This spec defines it.

The spec is intentionally narrower than a Notion-clone. We are NOT building a full office / email editor. We are building an **importer + AI-driven WYSIWYG editor + exporter** that handles documents, spreadsheets, slides, and email, with the constitutional-receipts model giving the user a full audit trail of every agent action.

---

## 2. Why this design

The architect has locked in the architecture over the course of this session. The locked-in choices, with one-line rationale:

| Choice | Rationale |
|---|---|
| **Semantic block AST** (not raw attributed string) | The agent reasons about headings/paragraphs/lists/tables, not characters. AST is the right granularity for agent edits. |
| **User + agent share one mutation API + one undo stack** | The agent IS the editor, not a co-pilot. The user can take over at any time. No "Insert" button. |
| **Streaming with smooth animation** (not raw keystrokes, not a loading screen) | The user sees the agent working — block slide-ins, deliberate text cadence, visible cursor — but not raw text streaming (rejected as "hella lame") and not "thinking… then result" (rejected as a loading screen). |
| **Chat panel is a command queue, not a chat history** | User-typed text is injected into the agent context as a "hard suggestion", shown in the UI as "pending" until the agent picks it up. Three states: pending → in-progress → applied (or failed). |
| **Per-document queue** (architect decision) | Each doc has its own queue; switching docs switches the queue. |
| **Agent continues in background when user switches docs** (architect decision) | The agent's work is decoupled from the user's view. A "Working in background" chip shows in the chat panel. The receipt chain serializes the work. |
| **On-device LLM default, remote opt-in** | Privacy story: on-device by default; Anthropic / OpenAI opt-in with per-receipt model + prompt logging. |
| **Constitutional receipts are first-class** (v1: signed JSON + Markdown + **C2PA**) | Every mutation is a receipt. Receipts are inspectable in a drawer, exportable as a signed bundle. C2PA was deferred to v2 in the research, but the architect wants C2PA in v1 — this spec treats C2PA as a v1 deliverable. |
| **NSTextView (macOS) + UITextView (iOS) via RichTextKit** | The most mature rich-text engines are the ones Apple itself uses. RichTextKit gives us SwiftUI niceties on top. |
| **Python + Pandoc for the format bridge** | Mature libraries: `python-docx`, `openpyxl`, `python-pptx`, `weasyprint`, `beautifulsoup4`, `mailbox` stdlib, plus Pandoc as the swiss-army format bridge. |

The deep UX rationale — the Apple HIG citations, the academic literature, the market pattern survey, the animation primitives, the accessibility decisions — lives in `docs/tessera-productivity-ux-research.md` (22-28 pages, 15 papers, 15 products surveyed, 68 specific decisions). This spec is the source of truth; the UX doc is the evidence.

---

## 3. Architecture overview

```
                            ┌─────────────────────────────────┐
                            │   TesseraStudioMac / iOS app    │
                            │                                 │
                            │  ┌──────────────┐ ┌──────────┐  │
                            │  │ WYSIWYG      │ │  Chat    │  │
                            │  │ Editor       │ │  Panel   │  │
                            │  │ (NSTextView/ │ │  (queue) │  │
                            │  │  UITextView) │ │          │  │
                            │  └──────┬───────┘ └────┬─────┘  │
                            │         │              │        │
                            │  ┌──────▼──────────────▼─────┐  │
                            │  │  Mutation API (typed ops) │  │
                            │  └────────────┬──────────────┘  │
                            │               │                 │
                            │  ┌────────────▼──────────────┐  │
                            │  │  Block AST + UndoManager  │  │
                            │  └────────────┬──────────────┘  │
                            └───────────────┼─────────────────┘
                                            │
                       ┌────────────────────┼────────────────────┐
                       │                    │                    │
              ┌────────▼────────┐  ┌─────────▼─────────┐  ┌──────▼──────┐
              │ TesseraDataStore│  │  TesseraCache     │  │  SwiftData  │
              │  (Postgres)     │  │  (Valkey)         │  │  (local)    │
              └─────────────────┘  └───────────────────┘  └─────────────┘
                                            │
                                  ┌─────────▼─────────┐
                                  │  Receipt infra    │
                                  │  (C2PA + JSON +   │
                                  │   Markdown)       │
                                  └───────────────────┘
                                            │
                                  ┌─────────▼─────────┐
                                  │  Import / Export  │
                                  │  (Python + Pandoc)│
                                  └───────────────────┘
```

**Load-bearing invariants:**

1. **No raw SQL / Redis commands leak past the data layer facade.** The productivity surface depends on `TesseraDataLayer`, never on Postgres or Valkey types.
2. **No raw text mutations leak past the Mutation API.** The WYSIWYG editor and the agent both go through the same typed operations.
3. **No agent edit lands without a receipt.** Every commit is signed (v1: ed25519, future: C2PA-signed), and the receipt is the source of truth for the audit trail.
4. **The chat panel never blocks the editor.** A pending message is injected into the agent's context but doesn't gate the user's ability to edit.
5. **The agent and the user have separate cursors.** The agent cursor (where the agent is currently editing) and the user cursor (where the user is currently focused) are independent. The user can click anywhere and edit freely; their edits become queue items that go to the front of the queue, pushing pre-existing items back. The agent isn't paused — it just sees a new higher-priority item and steers.
6. **The C2PA receipt signing key and the Plea the Fifth crypto-shred key are the SAME key.** Both live in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The Plea the Fifth 9-step wipe destroys this Keychain entry in step 3 (`destroy_volume_password`), which makes all prior signed receipts unverifiable (correct behavior: when the data dies, the receipts die with it). This is the constitutional property that makes C2PA in the foundation a procurement signal.

---

## 4. Document model (block AST)

A document is a tree of typed blocks. Each block has a stable `id` (UUID v7 for sortability), a `type`, optional `attributes`, and `content`. The block tree is stored in the data layer as a `graph_entity` with `entity_type = 'document'` and `body = <JSONB AST>`.

### 4.1 Block types

```swift
public enum BlockType: String, Codable, Sendable {
    case heading        // attributes: { level: 1|2|3|4|5|6 }
    case paragraph      // content: inline runs
    case list           // attributes: { style: "unordered" | "ordered" | "task", items: [BlockID] }
    case listItem       // content: inline runs
    case table          // attributes: { rows: Int, cols: Int, cells: [[BlockID]] }
    case tableCell      // content: inline runs
    case image          // attributes: { source: URL, alt: String, width: Int?, height: Int? }
    case codeBlock      // attributes: { language: String? }, content: source text
    case callout        // attributes: { emoji: String?, color: String? }
    case divider        // empty content
    case quote          // content: inline runs, attributes: { cite: String? }
    case toggle         // attributes: { expanded: Bool }, children: [Block]
    case equation       // attributes: { latex: String }
}
```

Inline content is modeled as a sequence of runs:

```swift
public struct InlineRun: Codable, Sendable {
    public enum Annotation: String, Codable, Sendable {
        case bold, italic, underline, strikethrough
        case code, subscript, superscript
        case link   // associated value: URL
        case color  // associated value: hex
    }
    public var text: String
    public var annotations: [Annotation]
}
```

### 4.2 The block tree

```swift
public struct Block: Codable, Sendable, Identifiable {
    public let id: UUID
    public var type: BlockType
    public var attributes: [String: AnyCodable]
    public var content: [InlineRun]              // for leaf blocks
    public var children: [UUID]                  // for container blocks (list, toggle, table, callout)
    public var parentID: UUID?
}
```

The document is stored as a flat `[UUID: Block]` map (for O(1) lookup) plus a `rootChildren: [UUID]` ordered list. This is the format Notion uses internally; it gives fast random-access updates and avoids the cost of walking a deep tree for every render.

### 4.3 Storage

The AST is serialized to JSON and stored as the `body` of a `graph_entity`:

```sql
INSERT INTO graph_entities (id, entity_type, subtype, label, body, source_url, embedding)
VALUES (
    $1,                                   -- uuid v7
    'document',
    $2,                                   -- 'doc' | 'sheet' | 'slide' | 'email'
    $3,                                   -- document title
    $4,                                   -- JSONB AST
    $5,                                   -- source URL (if imported)
    $6                                    -- embedding (computed async after save)
);
```

A separate `document_versions` table tracks every save as a new immutable version, with the AST + the receipt that produced it. This is the version history the user sees when they open "Version history" in the editor.

### 4.4 Rendering

The AST renders to a `NSAttributedString` (macOS) or `NSAttributedString`-equivalent for `UITextView` (iOS). The renderer is a pure function `Block → NSAttributedString` (with `NSTextAttachment`s for images, `NSTextList`s for lists, `NSTextTable`s for tables). The renderer is a separate module so it can be unit-tested in isolation.

---

## 5. Mutation API

The mutation API is the single interface for both the user (via the WYSIWYG editor) and the agent (via the chat panel). Every operation is typed, returns a receipt, and is undoable as a unit.

### 5.1 Operation taxonomy

```swift
public enum Mutation: Codable, Sendable {
    // Block-level operations
    case insertBlockAfter(parentID: UUID?, anchorID: UUID?, block: Block)
    case insertBlocksAfter(parentID: UUID?, anchorID: UUID?, blocks: [Block])
    case replaceBlock(blockID: UUID, block: Block)
    case deleteBlock(blockID: UUID)
    case moveBlock(blockID: UUID, newParent: UUID?, newIndex: Int)

    // Attribute / content operations (finer-grained, cheaper to undo)
    case setBlockAttribute(blockID: UUID, key: String, value: AnyCodable)
    case setBlockContent(blockID: UUID, content: [InlineRun])
    case appendInlineRun(blockID: UUID, run: InlineRun)
    case replaceInlineRun(blockID: UUID, index: Int, run: InlineRun)
    case deleteInlineRun(blockID: UUID, index: Int)
    case setInlineAnnotation(blockID: UUID, range: Range<Int>, annotation: InlineRun.Annotation, enabled: Bool)

    // Document-level operations
    case setDocumentTitle(title: String)
    case setDocumentMeta(key: String, value: AnyCodable)
}
```

### 5.2 Receipt contract

Every mutation returns a `Receipt`:

```swift
public struct Receipt: Codable, Sendable, Identifiable {
    public let id: UUID
    public let documentID: UUID
    public let actor: Actor          // .user(UserID) | .agent(AgentRunID)
    public let mutations: [Mutation]
    public let timestamp: Date
    public let priorReceiptID: UUID? // forms the chain
    public let signature: Data       // ed25519 (v1); C2PA manifest in v1 per architect
    public let c2paManifest: Data?   // optional C2PA manifest (v1)
    public let summary: String       // human-readable, "3 paragraphs replaced, 1 list added"
}
```

The `priorReceiptID` forms a chain — every receipt references the receipt that came before it for the same document. The chain is what makes the audit trail verifiable.

### 5.3 C2PA in v1 (architect decision)

The research doc recommended deferring C2PA to v2 (it requires a signing key in Keychain). The architect wants C2PA in v1. This spec commits to that:

- Each receipt includes a C2PA manifest signed with the user's Tessera signing key (stored in Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- The C2PA manifest references the document's content hash + the agent's model + prompt (if any).
- The manifest is verifiable by any C2PA-aware tool (e.g., the `c2patool` CLI, Adobe's Content Authenticity Tool, or any future Tessera user opening the same document).
- The signing key is created on first receipt generation, stored in Keychain, and never leaves the device.
- The C2PA manifest format follows the C2PA Technical Specification 2.x; we use the `c2pa-rs` Rust library via a Swift C-ABI shim (justified for performance + spec coverage; the alternative is a pure-Swift C2PA implementation, but no production-grade one exists yet).

**Open implementation question (deferrable):** the exact C2PA library choice. The spec assumes `c2pa-rs` via FFI; the implementation worker can downgrade to a pure-Swift library if one matures by the time the worker runs.

### 5.4 Undo / redo

A single `UndoManager` per document window. Each `Receipt` is one undo unit (one Cmd-Z = undo the whole agent instruction, not the last character). The undo manager is receipt-aware: it pops receipts off the chain, reverses their mutations, and creates a new "inverse" receipt.

### 5.5 User edits are queue items, not bypass operations (per architect direction)

Per the steering model in §6.6, the user's edits to the document are NOT bypass operations. They go through the same `Mutation` API as agent edits, they produce a `Receipt`, AND they create a queue item that goes to the front of the per-document chat queue.

Concretely:

- The `TesseraTextContentManager` (the AST-backed text content manager, see §9) detects the user's typing / formatting / paste and emits a stream of `Mutation` operations
- The mutation handler wraps them in a `Receipt` and a queue item
- The queue item is inserted at position 0 in the per-document queue
- The agent's `hybrid_search` context is updated to include the new front item
- The agent re-plans (if mid-edit) or picks up the new front item (if idle)

The natural-language description for the user's queue item comes from the agent's summarizer at the time of insertion ("You edited paragraph 3", "You added a new section after the heading", etc.). This is the same code path the agent uses to summarize its own actions.

This means: every keystroke (or every formatting change, or every paste) becomes a queue item. To prevent chat-panel spam, **coalescing** applies: a burst of user edits within a short window (default 1.5s of inactivity) is summarized as one queue item ("You edited section 'Introduction' — added 2 paragraphs and formatted a heading"). The coalescing window is a user setting, default 1.5s, range 0.5-5.0s.

---

## 6. Chat panel (command queue)

The chat panel is the control surface for the agent. It is NOT a chat history — it is a command queue where each message is a state machine from `pending` to `applied` (or `failed`).

### 6.1 Layout (per architect decision)

- **macOS**: always-visible sidebar on the right side of the window (HIG-compliant, matches Mail and Notes). Cmd-2 focuses the chat panel but does not toggle its visibility. Cmd-Option-2 toggles the inspector pane (the receipt drawer).
- **iOS**: bottom tab. The chat panel is one tab; the editor is the other. Tabs are persistent.

The chat panel has three regions (top to bottom):
1. **Header** — document title, "Working in background" chip (if any), undo/redo buttons, the receipt count
2. **Queue** — pending + in-progress + applied messages, in order
3. **Input** — text field for new pending messages, with the "Take over" button on the right

### 6.2 State machine

```
                 ┌──────────┐
                 │ pending  │  (user just typed, agent has seen it in context)
                 └─────┬────┘
                       │ agent picks up
                       ▼
                 ┌──────────┐
                 │ in-      │  (agent is actively working)
                 │ progress │
                 └─────┬────┘
                       │ agent commits
                       ▼
            ┌─────────────────────┐
            │ applied             │  (or → failed)
            │ (with receipt chip) │
            └─────────────────────┘
```

### 6.3 Visual treatment per state

- **Pending** — italic text, 60% opacity, clock icon. Editable (click to edit text, drag to reorder, X to delete). The agent has it in its context but hasn't started.
- **In-progress** — normal text, subtle highlight background, pulse animation (0.6 Hz scale + opacity oscillation on a small status dot). Live "applying to document…" caption with progress ("Streaming block 2 of 4"). "Take over" button appears.
- **Applied** — normal text, checkmark, inline receipt summary ("3 paragraphs updated, 1 list added, 1 receipt logged"). Tap the chip to open the receipt in the drawer.
- **Failed** — red flash, error message, retry button.

### 6.4 The "hard suggestion" semantics

When the user types a message and hits return, it becomes a pending message. The agent's context window is updated to include:

```
<pending>
  <message id="uuid" created_at="...">summarize section 2 and add a comparison table</message>
  <message id="uuid" created_at="...">use the latest data from materials/finance/q3.csv</message>
</pending>
<applied>
  <receipt id="..." timestamp="...">3 paragraphs updated</receipt>
  <receipt id="..." timestamp="...">1 list added</receipt>
  ...
</applied>
```

The agent sees pending FIRST. The agent can choose to:
- Pick up the next pending item when idle
- **Pre-plan for the next 1-2 pending items** to reduce latency (this is the "hard suggestion" benefit — the agent knows what's coming and can pre-warm its model)
- Re-plan mid-execution if the user adds a higher-priority pending redirect

### 6.5 The two-cursor model (per architect direction)

The user and the agent have **separate cursors** in the same document. They can be in the same paragraph or different paragraphs, and they don't conflict with each other. The two cursors are visually distinct:

- **Agent cursor** — small robot icon at the agent's edit location, with a subtle blue background. The cursor blinks at the standard 530ms rate when the agent is active.
- **User cursor** — the standard system text caret (no special treatment). Standard macOS / iOS behavior.

When the user clicks anywhere in the document, their cursor jumps to the click position. When the agent is mid-edit, the agent cursor moves through the affected blocks in real time. The two cursors can coexist in different paragraphs without any contention.

**No more "agent paused" banner.** The agent is never paused by a user click. The user has full, uninterrupted control of their cursor.

### 6.6 User edits as queue items (the steering model)

The user's edits are **queue items, not bypass operations**. When the user edits the document:

1. The user's edit is detected by the editor's mutation API (it's a real mutation, going through the same path as agent edits)
2. The edit is wrapped in a `Mutation` and a `Receipt`, just like agent edits
3. A new queue item is created from the user's edit: "You edited paragraph 3" (or similar; the natural-language description comes from the agent's summarizer at the time of insertion)
4. The new queue item is **inserted at the front of the queue**, pushing all pre-existing items back by one
5. The agent sees the new front item in its context window
6. The agent's current in-flight work (if any) is re-prioritized — it's not paused, but the agent re-plans given the user's edit

The user perceives this as the agent being "interrupted". In practice, the agent is just steered — it sees a new higher-priority item and responds to it. The agent's in-flight mutation, if any, is either completed (if the user's edit doesn't affect the affected blocks) or rolled back and re-planned (if it does).

The user can also use the chat panel to add pending items manually (text instructions to the agent). Those also go to the front of the queue and trigger the same re-planning.

### 6.7 Queue re-assessment on every front-of-queue add

Whenever a new item is added to the front of the queue (whether from a user edit or a manual pending message), the agent **re-assesses the entire queue**. Specifically:

1. The new front item is summarized by the agent (LLM call: "what is this user trying to do?")
2. The remaining queue items are summarized similarly
3. The agent does a **match-and-supersede check**: if the new front item is a refinement or replacement of an existing queue item, the existing item is marked `superseded` and visually dimmed in the queue UI
4. The new ordering is shown to the user; the user can re-reorder via drag if they disagree
5. The agent then picks up the new front item

The match-and-supersede check is an LLM call — it's cheap (a single prompt) and the result is cached. The check is:
- "Given the new instruction X and the existing queue items [Y, Z, W], does X supersede any of Y, Z, W? If so, which?"

A superseded item stays in the queue (visible but dimmed) so the user can see the history of intent. Tapping a superseded item shows the original and the supersession note.

### 6.8 "Hold your horses" — the explicit pause

The "Take over" button has been renamed to **"Hold your horses"** and its semantics changed. When the user clicks it:

1. The queue is **paused** — no new items are picked up by the agent
2. The agent is redirected to the user (not to the next item)
3. The agent opens a dialog: **"Is something wrong? Would you like me to reframe and approach things differently?"**
4. The user can describe what's working and what's not
5. The user and agent co-edit the queue — the user can drag items to reorder, the agent suggests reorderings based on the conversation
6. The goal is to **arrive at the user's actual desired end state**, not the literal sequence of items in the queue
7. When the user clicks "Resume", the agent picks up the new front item

The "Hold your horses" button is in the chat panel footer, always present. Its color is the system "pause" orange. While paused, the button label changes to "Resume" and the chat panel gets a subtle paused-indicator stripe.

This is a richer UX than the "agent paused banner" because it's conversational — the user and agent can negotiate the goal, not just pause/resume.

### 6.9 Cross-document behavior (per architect decision)

- Each document has its own chat queue (per-document queue model, architect-confirmed)
- When the user switches from doc A to doc B, the agent's in-flight edit on doc A **continues in the background** (architect-confirmed)
- A "Working in background" chip appears in the chat panel of doc A: "Agent is editing 'Doc B' — [Switch to Doc B] [Pause all]"
- The user can switch back to A to see the agent's progress
- The receipt chain serializes the work — even if two agent runs are happening on two docs, their receipts land in order, no conflicts
- "Pause all" (from the cross-doc chip) pauses every agent run across every document, not just the current one

### 6.10 Drag-to-reorder (macOS + iOS)

Pending items are draggable. On macOS, click-and-drag. On iOS, long-press to lift, then drag. VoiceOver rotor on both platforms. The reorder updates the agent's context window (re-ordering the pending list). Reordering during a "Hold your horses" pause is the primary way the user and agent co-edit the queue.

### 6.11 Deletion of pending items

- Pending: delete without confirmation (never executed)
- In-progress: "Stop and discard" confirmation (the in-flight receipt is voided, a new `cancelled` receipt is appended)
- Applied: not deletable (it's in the audit trail). Tapping it opens the receipt in the drawer.
- Superseded: a small "superseded" badge; the user can dismiss it to remove it from the visible queue, but the underlying receipt remains in the chain

---

## 7. Receipt infrastructure

The constitutional receipt is the load-bearing primitive. Every mutation produces a receipt; every receipt is signed; every receipt is inspectable; every receipt is exportable.

### 7.1 Storage

Receipts are stored in two places:

1. **In the Postgres `graph_receipts` table** (the data layer; see `docs/tessera-data-layer-design.md` §3). The `payload` is the JSONB-serialized receipt; the `signature` is the ed25519 signature.
2. **In an append-only `receipt_chain` table** keyed by `(document_id, chain_index)` — this is what gives us the linear order. The `prior_receipt_id` in the receipt forms the chain; the `chain_index` is just the monotonic position.

```sql
CREATE TABLE receipt_chain (
    document_id   uuid NOT NULL REFERENCES graph_entities(id) ON DELETE CASCADE,
    chain_index   bigint NOT NULL,
    receipt_id    uuid NOT NULL REFERENCES graph_receipts(id) ON DELETE RESTRICT,
    PRIMARY KEY (document_id, chain_index)
);
```

### 7.2 Receipt content (v1 includes C2PA per architect)

```json
{
  "id": "uuid",
  "document_id": "uuid",
  "actor": {
    "type": "agent",
    "agent_run_id": "uuid",
    "model": "claude-opus-4-7",
    "prompt_hash": "sha256:..."
  },
  "mutations": [ ... ],
  "timestamp": "2026-08-05T10:00:00Z",
  "prior_receipt_id": "uuid",
  "summary": "3 paragraphs updated, 1 list added",
  "signature": "ed25519:...",
  "c2pa_manifest": {
    "format": "c2pa.v2",
    "claim_generator": "tessera/1.0",
    "assertions": [
      { "label": "c2pa.hash.data", "data": { "hash": "sha256:..." } },
      { "label": "c2pa.actions", "data": { "actions": [ { "action": "c2pa.edited" } ] } }
    ],
    "signature": "es256:..."
  }
}

```

### 7.2.1 The signing key is the same key Plea the Fifth destroys (per architect direction)

The C2PA / ed25519 signing key is stored in macOS Keychain under a dedicated `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` entry, with the `kSecAttrService` set to `com.tessera.receipts.signing`. **This is the same Keychain entry that the `PleadTheFifthExecutor`'s step 3 (`destroy_volume_password`) destroys.** This is not a coincidence — it's a load-bearing architectural decision.

The implications:

1. **C2PA in the foundation is a procurement signal.** "All edits are signed with a C2PA manifest" is a corporate / government procurement checkmark. The signing key being held in Keychain (Apple's hardware-backed secure storage) makes the signature non-repudiable: the signature was made by the user's device, and the device's key is the only one that could have made it.

2. **Plea the Fifth's crypto-shred is the constitutional property.** When the user triggers Plea the Fifth, the 9-step wipe destroys the Keychain entry in step 3. The next time anyone tries to verify a signed receipt, the signature check fails — because the key is gone. The receipt data is also wiped (it's in Postgres, the Postgres data is in the encrypted volume, the volume's password is also in the Keychain and was destroyed). So the receipts are gone AND unverifiable — the constitutional property holds.

3. **Receipts do not "survive" a wipe.** A wiped device has no receipts, and any receipts that somehow leaked (e.g., a previous export) cannot be verified against a new device's receipts because the signing keys are per-device. This is the privacy story: the receipts are local, signed, and gone with the data.

4. **The implementation depends on `TesseraKeychainVolume`.** The receipt infrastructure reads/writes the signing key via the existing `TesseraKeychainVolume` actor (Phase 1 of Plea the Fifth, on main). The receipt worker does NOT introduce a new Keychain dependency; it uses the existing actor. This means the receipt infra and Plea the Fifth share a single key-lifecycle implementation, which is what makes the architecture consistent.

5. **The receipt signing key is per-device, not per-user.** A user with two devices has two signing keys, and receipts from one device cannot be verified on the other. v2 may add a multi-device key-sync story (with the user's explicit consent), but v1 is per-device.

### 7.3 Receipts drawer (per architect decision)

- **macOS**: right-side inspector pane in `NavigationSplitView`. The drawer is always available; Cmd-Option-2 toggles its visibility; tapping a receipt chip in the chat panel opens that receipt in the drawer.
- **iOS**: modal sheet with `.large` detent. Tap a chip to present the sheet.

The drawer has three tabs:
- **This document** — the receipt chain for the open document, newest first, with the ability to navigate to any point in history (the document opens at that version, read-only or restored as a new branch)
- **All documents** — the same chain view but across all documents, filterable by date, agent vs user, etc.
- **Export** — the export UI (see §7.5)

### 7.4 Receipt details

When the user taps a receipt in the drawer, they see:
- Header: actor, timestamp, model (if agent), prompt hash (if agent)
- Mutations: a list of the typed operations, expandable
- Diff: a before/after of the affected blocks (rendered as text, with red strikethrough for deletions and green underline for additions)
- Signature: the ed25519 signature as a hex string, with a "Verify" button that re-runs the signature check
- C2PA: the manifest summary, with a "View C2PA manifest" button that opens it in a sheet

### 7.5 Export (v1: signed JSON + Markdown + C2PA per architect)

The user can export the receipt chain as:

- **Signed JSON bundle** — the full chain as a single JSON file, with the ed25519 signatures and C2PA manifests inline. Filename: `<document-name>-audit-<date>.json`. Default export.
- **Markdown summary** — a human-readable Markdown file with one section per receipt, suitable for sharing with non-technical reviewers (lawyers, doctors, journalists). Filename: `<document-name>-audit-<date>.md`. Opt-in via a toggle.
- **C2PA-signed document** — the document itself, signed with the C2PA manifest embedded. The document is then verifiable by any C2PA-aware tool. Filename: `<document-name>-c2pa.<ext>` where `<ext>` is the document's export format.

The export happens via `TesseraEgressGuard` (the existing egress filter on main) — exports are gated, the user must approve, the export is logged as a receipt (`receipt_type = 'export'`).

---

## 8. Animation primitives

The seven animation primitives used by the editor and the chat panel. Drawn from the research doc §5, with the durations, easings, and Reduce Motion fallbacks.

| Primitive | Trigger | Duration | Easing | Reduce Motion fallback |
|---|---|---|---|---|
| **Block slide-in** | New block created | 250ms | `.easeOut` | Crossfade only, no slide |
| **Block replace** | Block replaced | 300ms | `.easeInOut` | Crossfade only |
| **Block delete collapse** | Block deleted | 200ms | `.easeIn` | Instant removal (no animation) |
| **Text appear** | Agent's text inside a block | 60ms per char (default; user setting 30-100ms) | `.linear` | Whole text appears at once |
| **Cursor blink** | Text view focus | 530ms cycle | N/A | Static caret, no blink |
| **Thinking pulse** | Agent is in tool-call / retrieval phase | 1000ms cycle (0.6 Hz) | spring (response 0.5, damping 0.7) | Static dot, no animation |
| **Agent paused banner slide-in** | Agent paused | 200ms | `.easeOut` | Instant appearance, no slide |

All animations are interruptible. The agent can cancel a slide-in if the user undoes before the animation completes.

Implementation: SwiftUI `withAnimation` and `Animation` primitives. For the text view, the streaming cadence is driven by a `Timer.publish` (or `Task.sleep` in async) that emits each character with the chosen delay.

---

## 9. Editor wrapping (NSTextContentManager + RichTextKit)

The WYSIWYG editor is a SwiftUI view that wraps the platform-native rich text engine. The architecture is:

```
RichTextEditor (SwiftUI)
  └─ RichTextKit.RichTextEditor (SwiftUI binding)
      └─ NSTextView (macOS) or UITextView (iOS)        — TextKit 2
          └─ TesseraTextContentManager : NSTextContentManager
              └─ Produces TesseraTextElement : NSTextElement per block
                  └─ Each TesseraTextElement wraps one Block from the AST
                      └─ The AST is the source of truth; the text view observes it
```

The `TesseraTextContentManager` is the key — it's a custom `NSTextContentManager` (the TextKit 2 abstract class Apple introduced in macOS 12 / iOS 15) that produces `TesseraTextElement: NSTextElement` instances, one per block. The `NSTextView` / `UITextView` consumes these elements via TextKit 2's standard layout pipeline.

This means:
- The text view's text comes from the AST, not from a flat string
- Edits in the text view (typing, formatting, paste) produce mutations on the AST, not on an `NSAttributedString`
- The agent's mutations update the AST, which the text content manager observes and re-renders
- The two-cursor model (see §6.5) is implemented at the `NSTextContentManager` level: the manager tracks both the user cursor and the agent cursor as separate `NSTextLocation` pointers

This is the trick that makes "user edits and agent edits are the same thing" work — both paths converge on the AST, and the AST is the only source of truth.

### 9.1 Why NSTextContentManager (not NSTextStorage)

- `NSTextStorage` is the legacy TextKit 1 API. It inherits from `NSMutableAttributedString`, which assumes the text is a flat attributed string. For an AST-backed editor, that's the wrong abstraction.
- `NSTextContentManager` is the TextKit 2 API. It works with `NSTextElement` instances, which can wrap any backing store — including our Block AST. This is what Apple recommends for non-trivial custom text backends (per WWDC 2026 Session 370 "Elevate your text experience with TextKit").
- TextKit 2 also gives us better performance (incremental layout, viewport-aware rendering) and better international language support.

### 9.2 Why STTextView (krzyzanowskim) as the base, not raw NSTextView / UITextView

- SwiftUI's `TextEditor` is not a true rich text editor. It's a multi-line plain text editor.
- `TextEditor` does not support tables, images, code blocks, or attributed runs.
- Raw `NSTextView` (macOS) and `UITextView` (iOS) are the engines Apple Notes, Mail, TextEdit, and Pages use. They are 30 / 15 years mature respectively — but they have legacy TextKit 1 code paths mixed with TextKit 2, and they don't ship with line numbers, syntax highlighting, or code-folding primitives.
- `STTextView` (krzyzanowskim, https://github.com/krzyzanowskim/STTextView) is a **TextKit 2 native** NSTextView / UITextView reimplementation designed for source code editing. It gives us line numbers, syntax highlighting, code folding, and a clean TextKit 2 architecture for free.
- **Crucially**: STTextView is not just a "source code editor" — it's the modern TextKit 2 text view, with source code editing as a killer use case. We use it as the base text view for ALL our editor surfaces (rich text documents, code files, inline code blocks within documents, the Notes surface). One engine, one set of code paths, one team to maintain it.

The architecture is:

```
RichTextEditor (SwiftUI, from RichTextKit)
  └─ STTextView (krzyzanowskim) — TextKit 2, line numbers, code-friendly
      └─ TesseraTextContentManager : NSTextContentManager (our custom subclass)
          └─ Produces TesseraTextElement : NSTextElement per block
              └─ Each TesseraTextElement wraps one Block from the AST
                  └─ The AST is the source of truth
```

The STTextView provides the view layer (line numbers, gutter, syntax highlighting for code blocks, find/replace, multi-cursor, accessibility primitives). The `TesseraTextContentManager` provides the AST-backed text source. The two compose: STTextView renders whatever the content manager produces, and the content manager produces TesseraTextElements for each Block in the AST.

For code blocks inside rich text documents, the rendering switches modes: a `Block` of type `.codeBlock` produces a `TesseraTextElement` with `language = "swift"`, and STTextView applies syntax highlighting for that language. Same engine, same code path, different rendering rule.

### 9.3 Library survey (per architect direction)

We surveyed Swift packages and Python libraries that could complement the editor without us building everything from scratch. The findings:

| Need | Surveyed | Decision |
|---|---|---|
| Modern TextKit 2 text view (line numbers, code-friendly, performant) | `STTextView` (krzyzanowskim) | **Adopt** — TextKit 2 native, source-code editor, used as the base for ALL editor surfaces. One engine for rich text + code. |
| SwiftUI niceties on top of the text view (toolbar, attribute pickers) | `RichTextKit` (Daniel Saidi) | **Adopt** — mature, Swift-native, 30+ releases, the de facto choice. Composes with STTextView (we wrap STTextView in a RichTextKit-style SwiftUI view). |
| AST-backed `NSTextContentManager` | none found | **Build** — no third-party library does this. Apple's abstract API is the right layer to subclass. |
| Markdown rendering (Python, for the importer's intermediate JSON) | `markdown-it-py` (Python) | **Adopt** — already in the importer stack. CommonMark compliant, AST output. |
| Markdown rendering (Swift, for the Notes surface) | `MarkdownUI` (gonzalezreal) | **Adopt** — Swift-native, good rendering quality, SwiftPM. |
| Markdown parsing (Swift) | none found that match the Block AST | **Build** — our Block AST is richer than CommonMark. |
| Syntax highlighting (Swift) | `Highlightr` (raspu/Highlightr) or `Splash` (JohnSundell/Splash) | **Adopt** — for code blocks inside documents. Splash is Swift-native; Highlightr wraps highlight.js. Pick Splash (smaller, Swift-only). |
| Text range / selection manipulation (Swift) | none needed | Use Apple's `NSTextRange` / `UITextRange` directly |

The conclusion: the parts that are "not a true rich text editor" we CAN offload (modern TextKit 2 view, toolbar, attribute pickers, markdown rendering, syntax highlighting) we do. The part that can't be offloaded (AST-backed `NSTextContentManager`) we build, but we build on Apple's modern API + a mature TextKit 2 view rather than rolling our own.

### 9.4 Cross-platform parity

- **macOS**: `NSTextView` + TextKit 2 (`NSTextContentManager`) + `NSToolbar` for the format bar
- **iOS**: `UITextView` + TextKit 2 + `inputAccessoryView` for the format bar above the keyboard
- Both use the same `TesseraTextContentManager` so the AST is the source of truth
- Both use the same animation primitives (with the platform's native animation system under the hood)
- Keyboard shortcuts: standard macOS text-editing shortcuts (Cmd-B, Cmd-I, Cmd-Z, Cmd-Shift-Z, Cmd-A, etc.) on macOS; iOS uses the standard text-editing gestures

---

## 10. Importers (Python + Pandoc)

The importer converts external document formats into the Block AST. It runs as a Python process (the `tessera` CLI on main) and emits a `graph_entity` with the AST as JSONB.

### 10.1 Format support (v1)

| Format | Library | Notes |
|---|---|---|
| `.docx` | `python-docx` | Full support: paragraphs, headings, lists, tables, images, footnotes |
| `.xlsx` | `openpyxl` | Cell values, formulas (as text), basic formatting, sheets as separate ASTs |
| `.pptx` | `python-pptx` | Slides as separate ASTs, text frames, basic shapes; master layouts are not preserved |
| `.pdf` | `weasyprint` (render) + `pdftotext` (extract) | Two-pass: render to HTML for visual reference, extract text for AST |
| `.eml`, `.msg` | `mailbox` stdlib + `email` stdlib | Headers + body + attachments |
| `.mbox` | `mailbox` stdlib | Apple Mail export, multiple messages per file |
| `.html`, `.mhtml` | `beautifulsoup4` | Cleaned HTML, then converted to AST blocks |
| `.md` | `markdown-it-py` | Standard CommonMark + GFM extensions |
| Any other format | **Pandoc** | Pandoc is the swiss-army knife. If `python-docx` doesn't cut it, Pandoc does. |

### 10.2 Pandoc as the bridge

Pandoc is the gold standard for format conversion. We use it for:

- **Round-tripping**: AST → Pandoc JSON → external format (DOCX, PDF, HTML, LaTeX, etc.)
- **Format conversion** between exotic formats (`.odt`, `.epub`, `.rst`, etc.)
- **Re-importing** documents that were edited externally (e.g., the user opens a DOCX in Word, saves it, re-imports)

The architecture: the AST is the canonical form. Pandoc converts in and out.

### 10.3 The import pipeline

```
external file
  └─ detect format (by extension + magic bytes)
      └─ choose importer
          ├─ python-docx / openpyxl / python-pptx / weasyprint / beautifulsoup4 / mailbox
          │   └─ parse to an intermediate JSON
          │       └─ convert to Block AST
          └─ Pandoc (for any other format)
              └─ parse to Pandoc JSON
                  └─ convert to Block AST
                      └─ emit graph_entity with AST as JSONB
                          └─ generate embedding (async)
                              └─ emit import receipt
```

The import is one Python process invocation per file. The result is one `graph_entity` + one import receipt.

### 10.4 Punted on (v1)

- **Real-time spreadsheet formulas** (xlsx): formulas are stored as text but not re-evaluated
- **Slide master layouts** (pptx): not preserved; only text frames and basic shapes
- **Email threading**: messages are imported as separate `email` entities; threading is a v2 feature
- **OCR for scanned PDFs**: requires a model; punted to v2
- **Password-protected files**: not handled in v1; the importer will return an error

---

## 11. Exporters

Exporters convert the Block AST back to external formats. Same architecture as the importer (Python + Pandoc), but the direction is reversed.

### 11.1 Format support (v1)

| Format | Method | Notes |
|---|---|---|
| `.pdf` | **PDFKit** (macOS) or `weasyprint` (cross-platform) | Native rendering on macOS; weasyprint on iOS / Linux |
| `.docx` | **Pandoc** | AST → Pandoc → DOCX |
| `.xlsx` | `openpyxl` | AST → openpyxl Workbook |
| `.pptx` | `python-pptx` | AST → python-pptl Presentation |
| `.html`, `.pdf` (alt) | **Pandoc** | For users who want HTML output |
| `.md` | `markdown-it-py` | For users who want plain Markdown |
| `.eml` | `mailbox` stdlib | For exporting an email draft |
| **Apple Mail** | `NSSharingServicePicker` (macOS) / `UIActivityViewController` (iOS) | The system share sheet; routes to the user's default mail client |
| **Slack** | Webhook URL configured in Settings | POST to the webhook with the formatted message |
| **Discord / Teams / custom** | Generic webhook target | The user adds their webhook URL + a label |

### 11.2 The share sheet

The primary export UX is the system share sheet. On macOS, `NSSharingServicePicker` presents a panel with all installed share targets (Mail, Messages, AirDrop, Slack, etc.). On iOS, `UIActivityViewController` is the equivalent. The user picks a target; Tessera hands the formatted document to the target.

This is better than building per-target integrations because:
- It works with whatever the user has installed (Gmail in browser, Outlook, Fastmail, etc.)
- It uses the OS's native handoff (rich previews, attachments, etc.)
- It requires no per-target API keys

For Slack (which doesn't show up in the share sheet reliably), we have a direct webhook path.

### 11.3 Punted on (v1)

- **Real-time collaboration** (Google Docs-style multi-user editing): not in v1. Single-user editing with the agent as the only "other" user.
- **Version-controlled export** (git-style): the user gets version history via the receipt chain, but not a git-style branch/merge model. Punted to v2.
- **Email replies that import back as receipts**: the user can export to email, but replies don't auto-import. Punted to v2.

---

## 12. Surfaces (Materials slice)

The productivity surface covers six material types: Tasks, Reminders, Calendar, Notes, Email, and the productivity documents (Doc, Sheet, Slide). Each surface is a separate view in the app, backed by the `graph_entities` table.

### 12.1 The Materials slice

The Materials slice is a horizontal navigation in the macOS app and a tab in the iOS app. It shows:

- **Tasks** (Things 3-style Inbox / Today / Upcoming / Anytime / Someday)
- **Reminders** (calendar-event-relative)
- **Calendar** (Fantastical-style natural language input)
- **Notes** (Bear-style Markdown focus)
- **Email** (MailMate-style keyboard-first)
- **Documents** (the productivity doc/sheet/slide types)
- **Code** (source code files, see §12.10 — uses the same `STTextView` engine as Documents, with line numbers, syntax highlighting, and code folding)
- **Contacts** (see §12.7)
- **Graph** (force-directed view of all materials + links, see §12.8)

All surfaces share:
- The chat panel (per-document queue, but with a "global inbox" view for tasks/reminders/email)
- The receipt drawer (the inspector pane on macOS, modal sheet on iOS)
- The constitutional receipt model (every action is a receipt)
- The same `STTextView`-based editor engine (Documents, Notes, and Code all use it; the engine is configured per-surface)

### 12.2 Tasks

- An Inbox for new tasks
- Today (auto-populated from due date)
- Upcoming (next 7 days)
- Anytime (no due date)
- Someday (deferred)
- Each task is a `graph_entity` with `entity_type = 'task'`
- Natural language input ("tomorrow at 3pm, call John about the contract") is parsed by the agent and emitted as a task + a receipt

### 12.3 Reminders

- Calendar-event-relative (15 min before the meeting, etc.)
- Each reminder is a `graph_entity` with `entity_type = 'reminder'`
- Linked to its calendar event via `entity_links`

### 12.4 Calendar

- Fantastical-style natural language input
- Events are `graph_entity` with `entity_type = 'calendar_event'`
- Linked to attendees (people entities), documents (doc entities that contain the event), tasks (task entities that are prep for the event)

### 12.5 Notes

- Bear-style Markdown focus
- Notes are `graph_entity` with `entity_type = 'note'`, `subtype = 'markdown'`
- The chat panel is a powerful note-taking tool: "summarize this article" creates a new note with the summary

### 12.6 Email

- MailMate-style keyboard-first
- Email messages are `graph_entity` with `entity_type = 'email'`
- The email surface is the most complex — v1 ships a thin IMAP client (read + reply), v2 adds send, search, threading

### 12.7 Contacts (per architect direction)

Contacts are first-class materials so the user and agent have full access to personal context. The agent must be able to look up "John" and find John's contact info + all linked entities (recent emails, calendar events, tasks involving John, documents that mention him).

**Entity model:**

```swift
public struct Contact: Codable, Sendable {
    public let id: UUID
    public var subtype: Subtype          // .person | .organization | .group
    public var name: NameComponents      // first, last, prefix, suffix, nickname
    public var emails: [LabeledEmail]    // home, work, other + primary
    public var phones: [LabeledPhone]    // mobile, work, home, other
    public var addresses: [LabeledAddress] // home, work, billing
    public var organization: String?     // for .person: employer; for .organization: parent org
    public var title: String?            // for .person: job title
    public var birthday: Date?
    public var photo: Data?              // headshot or logo
    public var notes: String?            // free-form
    public var sourceURL: String?        // where this contact came from
    public var linkedEntityIDs: [UUID]   // other graph entities this contact is linked to
    public var createdAt: Date
    public var updatedAt: Date
}
```

Contacts are stored as `graph_entity` rows with `entity_type = 'contact'`, `subtype = 'person' | 'organization' | 'group'`. The agent's contact lookup is a `hybrid_search` against the `graph_entities` table (which is what the data layer already does for everything else) — no special-case API.

**Importers (v1):**

- **Apple Contacts (Address Book)** — read via `CNContactStore` on macOS (with the `com.apple.developer.contacts` entitlement on the production build, dev-preview can use the entitlement-free path via VCard export). One-shot import on user request; ongoing sync is v2.
- **VCard files** (`.vcf`) — drag-and-drop or "Open with Tessera". `CNContactVCardSerialization` parses them, no entitlement required.
- **Google Contacts** — opt-in, via Google People API with OAuth. The user connects their Google account in Settings; the importer pulls contacts on a schedule. v2 adds write-back.
- **CardDAV** — opt-in, for iCloud, Fastmail, Nextcloud, etc. CardDAV is XML over HTTP; there's no mature Swift library, so we implement the protocol directly (it's a few hundred lines of XML parsing).
- **LinkedIn** — punted to v2 (LinkedIn's contact export requires a separate OAuth flow and the data is less structured).

**Agent context:**

The agent's view of contacts is the same `hybrid_search` query that powers everything else, with a typed filter for `entity_type = 'contact'`. The user can ask:

- "What's John's email?" — agent looks up the contact, returns the primary email
- "Who works at Acme?" — agent filters contacts by `organization`
- "Find everyone I've emailed in the last month" — agent joins contacts with the email surface

The contact lookup is fast (HNSW index on the embedding + trigram on the name) and goes through the same data layer facade — no special-case API for contacts.

**Privacy:**

Contact data is among the most sensitive personal data we handle. All contact mutations are constitutional receipts. The data is stored in Postgres (not on-device) but the encrypted-volume architecture (Plea the Fifth) covers the Postgres data path. A contact export is gated by `TesseraEgressGuard` and logged as a `receipt_type = 'contact_export'` receipt.

### 12.8 Graph visualization (per architect direction)

The graph view is a Material surface that shows the user their materials and how they all relate. It's the "big picture" view that complements the per-entity list views.

**What it shows:**

- Every `graph_entity` is a node, sized by importance (number of `entity_links` incoming + outgoing, or recency of access, or user-pinned importance)
- Every `entity_link` is an edge, colored by `link_type` (e.g., `authored`, `mentioned_in`, `attendee_of`, `assigned_to`, `part_of`)
- Node color by `entity_type` (document = blue, task = green, contact = orange, etc.)
- The view is interactive: pan, zoom, click to select, double-click to open the entity

**Library choice — Grape:**

`Grape` (li3zhen1 / SwiftGraphs, https://github.com/SwiftGraphs/Grape) is a Swift-native SwiftUI library for graph visualization and force-directed simulation. Latest release Jan 17 2025, 325+ stars, 2D simd, KD-tree for spatial partitioning. It renders directly in SwiftUI — no JavaScript bridge, no `WKWebView`. The 2D simd and KD-tree make it performant for the thousands-of-nodes case.

Alternatives considered:

- **D3.js force-directed in WKWebView** — most flexible, but adds a JS↔Swift bridge. The bridge complexity is not worth the gain for our use case.
- **ForceDirectedGraph by rayfix** — simpler, demo-quality. Not a production library.
- **Custom SwiftUI Canvas + force sim** — would work, but Grape already has this. Use Grape.

**Layout:**

The Materials slice gets a new "Graph" tab. The graph view is the main content of the tab. The sidebar shows filters (entity type, date range, link type, search box). The selected entity's detail panel is a SwiftUI sheet (or the existing inspector pane on macOS).

**Interactions:**

- **Pan / zoom** — pinch on iOS, trackpad + Cmd-+/- on macOS
- **Click to select** — node pulses, the detail panel updates
- **Double-click to open** — opens the entity in its native surface (document opens in the editor, task opens in the Tasks surface, contact opens in the Contacts surface)
- **Drag to select multiple** — for batch operations ("delete these 5 notes")
- **Cmd-F to find** — highlights matching nodes; the camera pans to the first match
- **Right-click (macOS) / long-press (iOS) for context menu** — "open", "link to...", "show related", "delete"

**Performance:**

For documents with thousands of `graph_entities`, the graph is rendered with progressive disclosure: the initial view shows only "pinned" + "recently accessed" nodes, with a slider to expand the visibility radius. The force simulation is updated incrementally (no full re-layout on every frame) using Grape's `ForceSimulation` with a `KDTree` for the many-body force.

**Privacy:**

The graph view respects the receipt chain — when the user opens an entity, the receipt drawer shows the recent receipts. When the user creates or deletes a link via the graph view (drag-to-link gesture), it's a `linkCreated` / `linkDeleted` mutation with a receipt.

### 12.9 Punted on (v1)

- **Full IMAP client** (send, search, threading): v1 is read + reply only
- **Full office editors** (Google Docs-style real-time collaboration): v2
- **Cross-surface AI workflows** ("if I get an email from John about X, create a task to review Y"): v2
- **LinkedIn contact import**: v2
- **Google Contacts write-back**: v2
- **Real-time contact sync (CardDAV / Google)**: v2 (v1 is one-shot import)
- **Graph view 3D mode**: v1 is 2D only

### 12.10 Code (per architect direction)

Code files are first-class materials. The user (and the agent) can open, edit, and reason about source code as a Material — same model as Documents, Notes, and Email.

**Why this matters:**

The agent's primary value-add in v1 is "AI-assisted writing". The most powerful form of that assistance is when the user is doing real engineering work — writing Swift code, debugging a script, drafting a SQL migration, etc. The agent should be a first-class collaborator on code, not just on prose. A user working on a Swift file should be able to type into the chat panel "add an async version of this function" and have the agent propose a diff, just like it does for prose.

**Storage:**

Code files are `graph_entity` rows with `entity_type = 'code'`, `subtype = 'swift' | 'python' | 'sql' | 'typescript' | 'json' | 'yaml' | 'markdown' | 'shell' | 'rust' | 'go' | ...`. The body is the source text. The agent's `hybrid_search` treats code as first-class text — embeddings are computed on the source, the knowledge graph links code to documents (e.g., a doc that references the function), tasks (a task to refactor the function), and contacts (the author).

**Editor:**

The Code surface uses the same `STTextView` + `TesseraTextContentManager` engine as the Documents surface (see §9.2). The only differences are rendering rules:

- **Line numbers**: shown in the gutter (STTextView's built-in feature)
- **Syntax highlighting**: per-language (via `Splash` for Swift, or the appropriate library per language)
- **Code folding**: regions (functions, classes, blocks) are foldable (STTextView feature)
- **Find-in-file**: Cmd-F opens an inline find bar with regex support
- **Multi-cursor**: Cmd-click to add cursors, edit multiple lines at once
- **No rich text rendering**: code files don't have headings, lists, or tables. They have a single "code" block which is the whole file.

A `Block` in the Code surface is a single `codeBlock` with the source as content. The agent edits it via the same `Mutation` API as prose blocks (replace the whole codeBlock, or do find-and-replace style mutations).

**Inline code within Documents:**

When a `codeBlock` block appears inside a Document, the same engine renders it with syntax highlighting (no line numbers, no folding, since it's inline). The user can double-click the code block to "expand" it into a full Code surface (jumps to the code as a standalone Material, with line numbers and folding). This is a navigation gesture, not a copy.

**Agent's code awareness:**

- The agent can read any code material (via `hybrid_search` with `entity_type = 'code'`)
- The agent can propose code changes as mutations (replace the `codeBlock` content, or insert/delete specific ranges)
- The agent's C2PA receipt for a code change includes the model, the prompt, and a diff summary
- The agent can chain code materials: "look at the implementation in `users.rs`, then update the doc in `users.md` to reflect the new behavior" — this is the cross-surface AI workflow

**Importers (v1):**

- **File system watch** — the user can point Tessera at a directory (e.g., `~/Developer/MyProject`) and Tessera tracks changes. New / modified / deleted code files become Materials.
- **Git integration** (light) — `git log` + `git diff` to surface the recent commit history in the receipt drawer. v2 adds branch / PR workflows.
- **Direct file open** — Cmd-O opens a file from disk, parses the language, creates a Material.
- **Drag-and-drop** — drop a file or folder into the Code surface, get a Material.

**Versioning:**

Code materials use the same `graph_receipts` chain as Documents. Every save is a new version with a receipt. The receipt summary includes the diff stats ("3 files changed, 47 insertions, 12 deletions"). The user can roll back via the receipt drawer.

**Punted on (v1):**

- **LSP integration** (Language Server Protocol) — no autocomplete, no go-to-definition, no inline errors from a real compiler. v2.
- **Git push / PR** — read-only git in v1. v2 adds write operations.
- **Multi-file refactor** as a single agent action — v1 is one-file-at-a-time. v2 chains.
- **Terminal integration** — running shell commands from the Code surface. v2.

---

## 13. Cross-platform (macOS / iOS)

The productivity surface runs on both macOS and iOS. The architecture is the same; the platform-specific differences are in the SwiftUI layout and the text view wrapping.

### 13.1 macOS

- `NavigationSplitView` three-column: sidebar (surfaces) | editor | chat panel + receipt drawer
- `NSTextView` for the editor
- `NSToolbar` for the format bar
- `NSSharingServicePicker` for export
- `NSStatusItem` integration (already on main for Plea the Fifth — the menu bar item gets a "Plea the Fifth" submenu AND a "Productivity" submenu with quick-add to Tasks / Notes)

### 13.2 iOS

- `TabView` for the surfaces
- `NavigationStack` for the editor
- `UITextView` for the editor
- `inputAccessoryView` for the format bar
- `UIActivityViewController` for export
- The chat panel is a tab in the bottom bar, not a sidebar

### 13.3 Handoff

- The user can start editing on macOS, switch to iOS, and continue (the document is in the data layer; both apps read/write through `TesseraDataLayer`)
- The agent's in-flight work is on the server (the data layer's Postgres), so it continues regardless of which app the user is on
- The chat panel on iOS shows the same queue as the chat panel on macOS (per-document queue model)

---

## 14. Accessibility

Accessibility is a first-class requirement, not a follow-up.

### 14.1 VoiceOver

- All chat panel states (pending, in-progress, applied, failed) have explicit VoiceOver labels
- The receipt drawer is fully VoiceOver-navigable
- The animation primitives are suppressed for VoiceOver users (Reduce Motion + a separate "prefers crossfades" setting)

### 14.2 Reduce Motion

- All seven animation primitives have Reduce Motion fallbacks (see §8)
- The user setting `prefersReducedMotion` (per-app) overrides the fallbacks globally
- The Reduce Motion setting is exposed in the Settings → Accessibility panel

### 14.3 Keyboard navigation

- macOS: full keyboard navigation for the chat panel (Tab, arrow keys, Enter, Cmd-1/2/3/4/5 for quick state transitions)
- iOS: external keyboard support; VoiceOver rotor for drag-to-reorder

### 14.4 Dynamic Type

- All text in the chat panel + receipt drawer + editor toolbar scales with Dynamic Type
- The text view's font respects Dynamic Type (the user can set the default editor font in Settings)

### 14.5 High contrast

- All UI respects the system "Increase Contrast" setting
- The receipt chip's color treatment has a high-contrast variant

---

## 15. Implementation order

The research doc §13 maps out the implementation order in detail. This spec condenses it.

### Phase 1 — Foundations (serial, single worker or tight pair)

1. **Block AST schema** — the data model (`[UUID: Block]` + `rootChildren: [UUID]`)
2. **Receipt infrastructure** — the chain, the storage, the ed25519 + C2PA signing
3. **Mutation API** — the typed operations, the `UndoManager` integration
4. **Undo wiring** — receipt-aware undo, batched for multi-block edits

Worktree: `worktrees/prod-foundations/` on branch `feat/prod-foundations`. Owner: one or two workers.

### Phase 2 — Editor (depends on Phase 1, one worker)

5. `NSTextView` (macOS) + `UITextView` (iOS) wrapping via `RichTextKit`
6. `TesseraTextStorage` — the AST-backed text storage
7. Block handles (drag, hover, click)
8. Block-level animations
9. Receipt-aware undo

Worktree: `worktrees/prod-editor/` on branch `feat/prod-editor`. Owner: editor worker.

### Phase 3 — Chat panel + Receipt drawer (depends on Phase 2, one or two workers)

10. Chat panel layout
11. State machine (pending / in-progress / applied / failed)
12. Drag-to-reorder
13. Interrupt UX
14. Receipts drawer (inspector pane macOS / modal sheet iOS)
15. Audit trail view
16. Export (signed JSON + Markdown + C2PA)

Worktree: `worktrees/prod-chat-receipts/` on branch `feat/prod-chat-receipts`. Owner: chat panel worker + receipt drawer worker.

### Phase 4 — Importers / Exporters (depends on Phase 1, parallel with Phase 3)

17. DOCX importer (`python-docx`)
18. XLSX importer (`openpyxl`)
19. PPTX importer (`python-pptx`)
20. PDF importer (`weasyprint` + `pdftotext`)
21. EML/MSG/MBOX importer (`mailbox` stdlib)
22. HTML importer (`beautifulsoup4`)
23. Pandoc bridge
24. PDF exporter (PDFKit macOS / weasyprint)
25. DOCX/HTML exporter (Pandoc)
26. Slack webhook exporter
27. NSSharingServicePicker / UIActivityViewController integration

Worktree: `worktrees/prod-import-export/` on branch `feat/prod-import-export`. Owner: import/export worker.

### Phase 5 — Materials surfaces (depends on Phase 3, multiple workers)

28. Tasks surface
29. Reminders surface
30. Calendar surface
31. Notes surface
32. Email surface
33. **Code surface** (per architect direction) — uses the same `STTextView` engine as the Documents surface but with line numbers, syntax highlighting (`Splash`), code folding, find-in-file, and multi-cursor. Per-language syntax detection from file extension. The agent's `hybrid_search` treats code as first-class text.
34. **Code importers** — file-system watch (point Tessera at a directory), git log/diff read-only integration, direct file open, drag-and-drop
35. **Code navigation gesture** — double-click an inline code block in a Document to expand it into the standalone Code surface (jump, not copy)
36. Materials slice integration

Worktree: `worktrees/prod-materials/` on branch `feat/prod-materials`. Owner: multiple workers, one per surface. Code is its own worker (shares the editor engine but the rendering rules + file-system integration are distinct).

### Phase 6 — Contacts + Graph visualization (depends on Phase 1, parallel with Phases 2-5)

34. **Contacts entity model** in `TesseraDataLayer` — `Contact` struct, `LabeledEmail` / `LabeledPhone` / `LabeledAddress` types, contact-specific schema migrations (an indexed view over `graph_entities` for the common queries)
35. **Apple Contacts importer** (macOS) — `CNContactStore` with the dev-preview entitlement path
36. **VCard importer** — `CNContactVCardSerialization`, no entitlement required, drag-and-drop + "Open with Tessera"
37. **Google Contacts importer** (opt-in) — Google People API with OAuth
38. **CardDAV importer** (opt-in) — direct XML-over-HTTP implementation
39. **Contacts surface** in the Materials slice — list view, search, detail view, "link to..." action
40. **Graph visualization surface** — Grape-based force-directed view, sidebar filters, detail panel
41. **Graph interactions** — pan/zoom, click to select, double-click to open, drag to select multiple, right-click for context menu
42. **Graph performance** — progressive disclosure for thousands-of-nodes cases, KDTree-accelerated force simulation
43. **Contact integration with the agent** — agent's `hybrid_search` queries with `entity_type = 'contact'` filter, contact lookup as part of the agent's context

Worktree: `worktrees/prod-contacts-graph/` on branch `feat/prod-contacts-graph`. Owner: contacts + graph worker (or two workers in sub-worktrees if the scope splits cleanly).

### Worktree timing

- Phase 1 → Phase 2 → Phase 3: serial (each depends on the prior)
- Phase 4: parallel with Phase 3 (depends only on Phase 1)
- Phase 5: parallel with Phase 4 (depends on Phase 3)
- Phase 6: parallel with Phases 2-5 (depends only on Phase 1, can start as soon as the data layer's `hybrid_search` is up)

The architect reviews the spec, then we dispatch Phase 1 first (the dependency root). Once Phase 1 lands, Phases 2, 4, and 6 can all dispatch in parallel. Phase 3 dispatches after Phase 2. Phase 5 dispatches after Phase 3.

---

## 16. Open questions (deferrable to implementation)

These are the 10 implementation-deferrable questions from the UX research doc §12.2. The architect can override any of these during implementation, but the spec's defaults are:

- **Q9.** Specific animation curves — use Apple's standard curves, tune per-primitive
- **Q10.** Character cadence default — 60ms default, user setting for 30-100ms
- **Q11.** Command palette (Cmd-K) contents — search nodes, actions, chat items, settings, recent documents
- **Q12.** Applied notification interruption level — Active (default), user opts into Time Sensitive
- **Q13.** Receipt drawer default filter — this document, last 7 days, all agents, all types, all statuses
- **Q14.** Audit trail export filename — `<document-name>-audit-<date>.json`
- **Q15.** "Working in background" indicator location — small chip in chat panel header
- **Q16.** "Urgent" pending message visual treatment — "Urgent" chip in system orange
- **Q17.** Cancel receipt status — `cancelled` (separate from `voided`)
- **Q18.** "Agent paused" banner exact placement — top of chat panel, above the queue

These can be decided during implementation. The spec's defaults are reasonable; the architect can override.

---

## 17. Out of scope (v2+)

- **Real-time collaboration** (Google Docs-style multi-user editing)
- **Full IMAP client** (send, search, threading) — v1 is read + reply
- **OCR for scanned PDFs**
- **Password-protected file import**
- **Email replies that import back as receipts**
- **Cross-surface AI workflows** ("if I get an email from John about X, create a task to review Y")
- **Real-time spreadsheet formula evaluation**
- **Slide master layout preservation**
- **Receipt signing key rotation** (v1 uses a single key; v2 adds key rotation)
- **Federated receipt verification** (a v2 feature — third parties can verify a receipt's signature without holding the user's signing key)

---

## Appendix A: References

- `docs/tessera-plead-the-fifth-design.md` — the constitutional-receipts design, the Plea the Fifth crypto-shred feature
- `docs/tessera-data-layer-design.md` — the Postgres + Valkey data layer, the `TesseraDataLayer` facade
- `docs/tessera-productivity-ux-research.md` — the UX research: 15 papers, 15 products, 68 specific decisions, 18 open questions
- `tools/tessera/db/README.md` — how to run the dev stack
- C2PA Technical Specification 2.x — the C2PA manifest format
- Apple HIG (macOS + iOS) — the design rules referenced throughout

---

## Appendix B: Glossary

- **AST** — Abstract Syntax Tree. The block tree that represents a document.
- **Block** — A typed unit in the AST (heading, paragraph, list, etc.)
- **Chat panel** — The per-document command queue for the agent
- **Constitutional receipt** — The signed record of every mutation in the system
- **C2PA** — Coalition for Content Provenance and Authenticity; a standard for signed content metadata
- **Inspector pane** — The right-side panel in a `NavigationSplitView` (macOS HIG)
- **Mutation** — A typed operation on the AST
- **Receipt** — Same as Constitutional receipt
- **Receipt chain** — The linear order of receipts for a document, linked via `prior_receipt_id`
- **RichTextKit** — A Swift package by Daniel Saidi providing SwiftUI niceties on top of `NSTextView` / `UITextView`
- **Streaming** — The agent's tokens are rendered to the AST incrementally, with animation
