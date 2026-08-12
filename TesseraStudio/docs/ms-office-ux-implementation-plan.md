# MS Office UX Pain Points — Tessera Implementation Plan

## Research Sources

- Reddit r/Office365 37-error open letter (writing a book with Word 365)
- Reddit r/FuckMicrosoft Word rant thread (tables, paste, font changes)
- Reddit r/microsoftsucks Excel rant (arrays, date/CSV export)
- Reddit r/technology Copilot rage (Quartz article on forced adoption)
- Microsoft Support forums, TechCommunity, Trustpilot reviews
- LibreOffice vs Ribbon debate (normalization effect, market dominance ≠ good UX)
- PowerPoint animation bugs, video embedding failures
- Trustpilot Office reviews (instability, crashes, cloud lock-in)
- Microsoft Q&A / answers.microsoft.com for specific bugs

---

## Pain Point Taxonomy

### Word (highest signal: 37-error open letter + Reddit threads)

| # | Pain Point | Severity | Source |
|---|---|---|---|
| W1 | Opens with Track Changes / markup visible by default | High | 37-error letter |
| W2 | Web version shows all markup, no hide option | High | 37-error letter |
| W3 | Auto-formatting converts text to tables, bullets, numbered lists without asking | High | 37-error + multiple threads |
| W4 | Paste from other apps (especially Outlook) silently re-formats or breaks | High | Multiple Reddit threads |
| W5 | Font changes on Enter in text boxes (new, blank) | Medium | Reddit r/microsoft |
| W6 | Copy-paste tables from external apps breaks | Medium | Reddit r/FuckMicrosoft |
| W7 | Table editing requires obscure multi-step menus | Medium | Reddit r/FuckMicrosoft |
| W8 | TOC generates for every sentence instead of actual headings | Medium | Freelance writers thread |
| W9 | Export/print layout doesn't match editing view | Medium | Freelance writers thread |
| W10 | No way to mass-format cells (e.g., barcode numbers → dates) | Medium | Microsoft Q&A answers |
| W11 | Comments displayed by default, no persistent hide preference | Medium | 37-error letter |
| W12 | Inconsistent behavior between desktop and web versions | Medium | Multiple |

### Excel (highest signal: Reddit r/microsoftsucks + TechCommunity)

| # | Pain Point | Severity | Source |
|---|---|---|---|
| E1 | No F2 to edit cell, no formula bar visible by default | P0 | Confirmed from audit |
| E2 | No Tab/Enter navigation between cells | P0 | Confirmed from audit |
| E3 | Barcode numbers auto-converted to dates on paste | High | Microsoft Q&A answers |
| E4 | Dynamic array functions (UNIQUE, SORT, VSTACK) can't be used in Data Validation dropdowns | High | TechCommunity + Microsoft Support |
| E5 | "You can't change part of an array" — no clear UX path to fix | High | TechCommunity |
| E6 | Dates/times corrupted on CSV export | High | Reddit r/microsoftsucks |
| E7 | Broken formulas proliferate silently (#SPILL!, #CALC!, #REF!) | High | Multiple threads |
| E8 | Conditional formatting and data validation work poorly together | Medium | Microsoft Support |
| E9 | Array formulas referencing other worksheets limited by format | Medium | Microsoft Support |
| E10 | Slow performance with large datasets / volatile functions | Medium | Multiple threads |

### PowerPoint (highest signal: Microsoft known issues + Reddit)

| # | Pain Point | Severity | Source |
|---|---|---|---|
| P1 | Animations break silently or don't play on certain slides | High | Microsoft Support known issues |
| P2 | Videos freeze/hang on playback (confirmed bug, unfixed as of Oct 2025) | High | Microsoft Support |
| P3 | Can't change default font for a presentation | High | Velocitypartners blog |
| P4 | Auto-reformatting when adding slides or changing layouts | High | Velocitypartners blog |
| P5 | Slow, jerky animations even for basic 2D effects | High | Reddit r/videoengineering |
| P6 | Large file sizes from embedded media | Medium | Microsoft Support |
| P7 | Fonts substitute unexpectedly | Medium | SlideGenius blog |
| P8 | No slide master default that persists across sessions | Medium | Multiple |

### All Apps (cross-cutting)

| # | Pain Point | Severity | Source |
|---|---|---|---|
| A1 | Copilot bundled, can't be removed, appears uninvited in UI | P0 | Quartz article, Reddit, Trustpilot |
| A2 | Instability: crashes, freezes, random freezes on basic ops | High | Multiple Reddit threads + Trustpilot |
| A3 | Forced Microsoft account / cloud for local files | High | Multiple threads |
| A4 | UI inconsistency between web and desktop versions | Medium | 37-error letter |
| A5 | Forced updates change behavior mid-project | Medium | Reddit r/Office365 |
| A6 | Pricing: $9.99–$99.99/yr with Copilot bundled and non-removable | High | BGR article |
| A7 | "Don't allow Copilot" enterprise setting silently broken | High | Quartz article |
| A8 | Teams Copilot generates embarrassing meeting summaries | High | Quartz article |
| A9 | Ribbon takes up too much vertical space without enough benefit | Low | LibreOffice vs Ribbon debate (minority view) |

---

## Implementation Plan

### Phase 1 — P0 Excel Muscle Memory (Sheets surface)

**E1 + E2: F2 cell edit + Tab/Enter navigation**

- F2: enter edit mode (cursor inside cell text, formula bar shows raw content)
- Enter: confirm edit, move down one row
- Shift+Enter: confirm, move up one row
- Tab: confirm, move right one column
- Shift+Tab: confirm, move left one column
- Escape: cancel edit, revert cell
- Formula bar above grid: always visible, shows `=A1+B2` format when cell has formula
- Single-click selects cell, double-click enters edit mode
- This is the single highest-impact UX fix — every Excel user has F2 burned in

**E10: Cell selection state is obvious**
- Selected cell: blue border (not subtle gray)
- Active cell address shown in formula bar left end
- Row/column headers highlighted when cell is selected

---

### Phase 2 — Proper Ribbon (Docs + Sheets surfaces)

**Same spatial layout as Word/Excel, but premium execution**

```
┌─────────────────────────────────────────────────────────────────────┐
│ [Tab: Home] [Insert] [Layout] [Review] [View]          [AI Badge] │
├─────────────────────────────────────────────────────────────────────┤
│ Group: Clipboard   │ Group: Font          │ Group: Paragraph         │
│ [Paste▾][Cut][Copy]│ [B][I][U][S][Aa▾]  │ [≡▾][1.▾][↩][↪][indent]│
├─────────────────────────────────────────────────────────────────────┤
```

**Home tab groups (Word-equivalent):**
- Clipboard: Paste (with format picker), Cut, Copy
- Font: Bold, Italic, Underline, Strikethrough, Font Color, Font Size, Font Face
- Paragraph: Bullet list, Numbered list, Outdent, Indent, Sort, Align Left/Center/Right/Justify
- Styles: Normal, Heading 1/2/3, Ctrl+Alt+1/2/3 wired to each

**Insert tab:**
- Tables, Images, Links, Header/Footer, Page Break

**Layout tab (Docs):**
- Margins, Orientation, Columns, Page Color, Line Numbers

**Review tab:**
- Comments (add/view), Track Changes toggle (off by default), Word Count

**View tab:**
- Ruler toggle, Gridlines toggle, Focus Mode

**Sheets ribbon (replaces flat gridControls):**
- Home: Cut/Copy/Paste, Font, Alignment, Number Format
- Insert: Chart, Function, Table, Image
- Formulas: Function Browser, Named Ranges, AutoSum
- Data: Sort, Filter, Data Validation, Conditional Formatting
- Review: Comments

**Ribbon execution standards:**
- Keyboard shortcut tooltips on hover (e.g., `B` tooltip shows "Bold (⌘B)")
- Group separators: thin 1px gray divider lines between groups
- Active tab: underline pill style (4px bottom border, rounded ends)
- Contextual tabs: "Table Tools" tab appears when cursor is inside a table
- Ribbon height: compact (40px), not bloated
- All shortcuts wired: ⌘B/I/U/S, ⌘Z/Y, ⌘[/], ⌘E (center), ⌘L/R/J

---

### Phase 3 — Auto-Format Control (Docs surface)

**Problem:** Word auto-converts `*text*` → bullets, `1.` → numbered lists, etc. Users can't find the off switch, or it requires 5 levels of dialog diving.

**Solution:**

1. **Auto-Format panel in Preferences** (Settings → Editing → Auto-Format)
   - Organized exactly like Word's AutoFormat As You Type tab
   - Each toggle clearly labeled with before/after description
   - Section header: "As You Type"
   - Toggle: "Automatic bulleted lists" — default **OFF**
   - Toggle: "Automatic numbered lists" — default **OFF**
   - Toggle: "Automatic lists" (catch-all) — default **OFF**
   - Toggle: "Auto-correct" — default **OFF**
   - Toggle: "Format beginning of list item like the one before it" — default **OFF**
   - Toggle: "Bold, italic, underline with math auto-correct" — default **OFF**

2. **Status bar indicator**
   - When any Auto-Format is ON: subtle pill in status bar: `AutoFormat: on`
   - Click pill → jumps to Auto-Format settings
   - When all OFF: no indicator shown

3. **Paste format preference** (Settings → Editing → Paste)
   - "Default paste from other apps": [Keep Source Formatting ▾] / Keep Text Only / Match Destination
   - Default: **Keep Text Only** (avoids W4 entirely)
   - Paste command shows format picker popover (plain/formatting/icons)

---

### Phase 4 — Word-Specific Fixes (from 37-error letter)

**W1 + W11: Track Changes / Comments off by default**
- Default state: Track Changes OFF
- Default state: Comments panel hidden
- "Open with markup" is a setting: OFF by default
- First-time experience: clean document, no floating sidebar

**W5: Font consistency in text boxes**
- New text box inherits document default font, not "some random font"
- Document default font configurable in Settings (not buried): Settings → Document → Default Font

**W8: Table of Contents**
- Generate TOC from actual heading styles only
- No auto-generation on paste
- Explicit "Insert TOC" command

**W9: Print/export matches view**
- WYSIWYG: what you see in editor is what prints
- No hidden reformatting on export

---

### Phase 5 — AI Layer (additive, not invasive)

**A1 + A7: AI opt-in, not bundled**

| Feature | Office behavior | Tessera behavior |
|---|---|---|
| AI in UI | Present by default, can't remove | Completely absent unless user enables |
| Route chip | Copilot always present | "Granite · Local" badge — on by default, shows privacy status |
| AI suggestions | Interrupt workflow | Ghost text (Tab to accept, Esc to dismiss) |
| AI formatting | Auto-apply changes | Inline diff review — Accept/Reject per hunk |
| AI summaries | Meeting-level surveillance | Receipt chain: model name, route, timestamp, prompt hash |
| AI training | Data sent to cloud | On-device only, no telemetry, no forced cloud |

**Implementation:**
1. Settings → AI: master toggle, defaults to OFF for cloud, ON for local Granite
2. Route chip in toolbar: "Granite · Local" (green dot) / "Cloud" (blue dot)
3. Every AI edit carries a receipt badge: click to see model, latency, timestamp
4. Ghost text: gray italic continuation, Tab to accept, Esc to dismiss
5. No AI popups, no AI tooltips, no AI animations unless user triggered

---

### Phase 6 — PowerPoint Surface (Slides)

**P3: Default font setting**
- Settings → Slides → Default Text Box Font
- Persists across sessions (stored in preferences, not per-file)

**P4: No auto-reformatting**
- Adding a new slide: inherits current theme, no auto-layout changes
- Changing theme: explicit action, never automatic
- Slide layout picker: always shown on new slide insert

**P1 + P5: Animation system**
- Tessera renders animations via SwiftUI/Metal (no web engine)
- Animations: Fade, Slide, Zoom, Fly — each with duration control
- Animation pane: ordered list, drag to reorder
- Preview on hover in editor, not just in presentation mode
- Videos: H.264 MP4 only (cross-platform safe), embedded in bundle

**Slide thumbnail panel**
- Left sidebar: slide thumbnails, drag to reorder
- Right-click: Duplicate, Delete, Change Layout

---

### Phase 7 — Stability / No-Cloud Defaults

**A2 + A3: Local-first operation**
- Files stored locally as `.tessera` (JSON-based document format)
- No Microsoft account required
- No forced OneDrive / cloud sync
- Optional: export to .docx, .xlsx, .pptx via LibreOffice pipeline
- App opens instantly (no splash, no auth check, no update check)

**No forced updates**
- Update check is opt-in only
- Feature behavior doesn't change between sessions without user action
- Settings are persistent and documented

---

## Priority Summary

| Phase | Work | Impact |
|---|---|---|
| 1 | F2 + Tab/Enter + formula bar | P0, immediate |
| 2 | Full ribbon + keyboard shortcuts | P0, daily use |
| 3 | Auto-format toggle + paste preference | P0, daily use |
| 4 | Track Changes default off, font defaults | High, friction removal |
| 5 | AI opt-in + route chip + receipts | Differentiation, trust |
| 6 | Slides formatting toolbar + default font | Medium |
| 7 | Local-first, no cloud required | Trust, reliability |
| 8 | Personal Context Engine (Calendar + Contacts + Email) | "Die rather than go without" tier |

---

### Phase 8 — Personal Context Engine (Email / Calendar / Contacts)

**The insight:** Most of a knowledge worker's personal context — relationships, deadlines, action items, project history, reminders — lives in their email and calendar. A productivity tool that doesn't have access to that context is flying blind. Outlook's stickiness isn't about being a good email client; it's about being a hook into all of it. Tessera can own this layer without shipping a full email client.

**This is what turns Tessera from "a document editor" into "the tool you die rather than go without."**

---

#### Current Architecture (what's already built)

```
TesseraDataLayer (actor facade: Postgres + Valkey)
         |
  ┌─────┼──────────────────────┐
  │     │                       │
EmailStore  CalendarStore    ContactStore
EmailMessage CalendarEvent     Contact
EmailImporter CalendarViewModel AppleContactsAdapter
EmailChatAdapter CalendarNLUParser CardDAVImporter
EmailComposer CalendarResolvers  VCardImporter
EmailSender  CalendarGraphConnector GoogleContactsAdapter
```

**Already done:**
- `CalendarStore` + `CalendarEvent` + `CalendarViewModel` + `CalendarSurfaceView` (three-column macOS view) — all built
- `EmailStore` + `EmailMessage` + `EmailImporter` (`.eml` / `.mbox` via Python subprocess) — all built
- `ContactStore` + `Contact` + `AppleContactsAdapter` (CNContactStore), `CardDAVImporter`, `VCardImporter`, `GoogleContactsAdapter` — all built
- Full constitutional receipt chains on every mutation for all three materials
- Graph model (`entity_links`, `hybrid_search`) already connects all three materials
- `ShareSheetCoordinator` and `EmailComposer` already exist for composition

**Persistence: Postgres via PostgresNIO. NOT SQLite.** All materials ride the universal `graph_entities` table. No SQLite anywhere in the stack.

---

#### What Is Actually Missing (three concrete gaps)

**Gap 1 — Live Calendar (EventKit adapter):**
`CalendarEvent` model and `CalendarStore` exist but no adapter reads from macOS Calendar.app. The `CalendarSurfaceView` renders but shows no events. Need an `EventKitAdapter` that mirrors `AppleContactsAdapter`'s pattern.

**Gap 2 — Live Email (IMAP adapter + SMTP sender):**
`EmailStore` + `EmailImporter` handle imported `.eml` / `.mbox` files only. No live inbox sync. Need `IMAPAdapter` for fetch and `SMTPClient` for delivery.

**Gap 3 — LLM Context Extraction:**
No pipeline yet that extracts action items, deadlines, and project references from email body text via Granite. The `EmailChatAdapter` provides raw context; the extraction layer is the missing piece.

---

#### Implementation: Gap 1 — EventKitAdapter

New file: `Sources/TesseraCore/Productivity/Materials/Calendar/EventKitAdapter.swift`

Pattern mirrors `AppleContactsAdapter`. The `CalendarStore.upsert()` already emits `event_created` / `event_updated` receipts — no new receipt type needed.

```
Source: macOS Calendar app (any account: iCloud, Google, Exchange)
Access: EventKit EKEventStore.requestAccess(to: .event)
Fields: title, startDate, endDate, location, notes, attendees, alarms, recurrence
Sync: initial full sync (last 30 days + next 90), then incremental via EKEventStore.refreshSourcesIfNecessary()
```

---

#### Implementation: Gap 2 — IMAPAdapter + SMTP Completion

New file: `Sources/TesseraCore/Productivity/Materials/Email/IMAPAdapter.swift`

```
Source: any IMAP server (Gmail, iCloud, Fastmail, ProtonMail, corporate Exchange)
Access: IMAP4 rev1 over port 993 with TLS
Credentials: stored in macOS Keychain via KeychainStorage (already exists)
Sync: initial 500 messages newest-first, then SEARCH SINCE <last-sync> + optional IDLE for real-time push
Write: IMAPAdapter produces EmailMessage, calls EmailStore.upsert() — already emits receipts
SMTP: EmailSender exists but needs SMTPClient completion for actual delivery
```

---

#### Implementation: Gap 3 — EmailContextExtractor

New file: `Sources/TesseraCore/Productivity/Materials/Email/EmailContextExtractor.swift`

The extracted context is stored as JSON in `EmailMessage.body` under a `context` key. `EmailStore` is unaware of the structure — it stores and retrieves the body JSON. Incremental re-extraction runs on changed emails only.

```
ExtractedContext: action_items (who/what/when), deadlines (explicit + relative),
                 projects (names + ticket IDs), sentiment, key_decisions
LLM: Granite runs locally, no external API calls
Storage: ~500 bytes per email. For 10k emails: ~5MB added to body JSONB.
```

---

#### UX Surfaces (what needs wiring, not rebuilding)

All three surfaces already exist. The work is wiring live-sync data and LLM extraction into them.

- **CalendarSurfaceView** — needs EventKitAdapter to populate
- **EmailView** — needs IMAPAdapter to populate  
- **ContactsView** — AppleContactsAdapter already works
- **Docs** — Smart Compose via Granite + contact/email context, deadline nudge cards
- **Sheets** — `=CONTACT()`, `=CALENDAR.NEXT()`, `=ACTIONS` formula functions; deadline row highlighting
- **Slides** — audience context card (contact history + email summary) before presenting

---

#### Privacy Architecture

Existing constitutional infrastructure handles this. The context engine just stays within it.

| Guarantee | Implementation |
|---|---|
| No email leaves the device | Granite runs locally. EmailContextExtractor is a local actor. |
| No telemetry | Zero analytics, zero crash reporting on email content |
| No cloud sync | Postgres stays local. Not in iCloud. |
| Granular permissions | Calendar, contacts, email each requested separately at setup |
| Revocable | Revoke EventKit access: re-denied prompt. Revoke IMAP: credentials removed from Keychain. |
| Audit trail | Every mutation already emits a receipt. Extraction writes back to same `EmailMessage.body`. |

**Setup wizard:** Calendar access → EventKit prompt. Contacts → already works. Email → IMAP credentials → Keychain → IMAPAdapter starts syncing → EmailContextExtractor runs in background.

---

## Anti-Patterns to Avoid (What Not to Do)

1. **Don't ship a ribbon with no groups** — flat button rows are what Pages/LibreOffice do wrong; groups with separators are non-negotiable
2. **Don't auto-enable AI features** — A1 is the #1 MS Office hate point; opt-in is the only correct answer
3. **Don't make the status bar crowded** — it shows context, not feature advertisements
4. **Don't change keyboard shortcuts** — ⌘B/I/U/S are sacred; Excel F2/Enter/Tab is sacred; deviating = broken muscle memory
5. **Don't add a "Copilot" button** — even if it has useful functionality, the name is now toxic; use "AI", "Assist", or the feature name itself
6. **Don't tie file format to a cloud account** — local .tessera files that export to .docx is the right model
7. **Don't ship email context without explicit consent** — calendar/contacts/email access must be a deliberate user choice with plain-language explanation; do not prompt at first launch, only at setup wizard when user is already in a consent frame
8. **Don't store email content in the context index** — only extracted structured data (action items, deadlines, names, project IDs). If the user revokes email access, only the structured index is deleted, not their email
9. **Don't make context opt-out instead of opt-in** — if the user skips context setup during onboarding, don't nag them with repeated prompts; leave a quiet "enable context" entry in Settings
10. **Don't surface context that wasn't requested** — the context engine answers questions (via the user typing, or via proactive nudges on detected deadlines), it doesn't announce itself unprompted. No "Sarah sent you an email" popups unless the user is actively working on something related to Sarah

