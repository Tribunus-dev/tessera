# SOTA evidence: P2 enterprise track (2.13-2.21 design positions)

Prepared 2026-08-14 by the refinement-pass research agent (enterprise track).
Evidence input to `../studio-expansion-design-refinement-2026-08-14.md`; the
companion doc carries the consolidated, architect-facing positions. Kept as
evidence per the house pattern (peer of `lo-{writer,calc,impress}-report.md`).

Covers 2.13, 2.14, 2.15, 2.16, 2.19, 2.20, 2.21. (2.17/2.18 Draw 3D/morph are
covered by the canvas/charts report.)

> Consolidation note (2026-08-14): the 2.20 position below was drafted against
> the plan's original in-process-UNO bridge premise ("storeToURL FilterData;
> the bridge is not shelling out"). That premise is stale - in-process UNO
> died at P0 (see the plan's 6a addendum). The filter OPTION names are
> identical across the UNO FilterData sequence and the CLI
> `--convert-to 'pdf:writer_pdf_Export:{...}'` JSON syntax (LO > 7.3;
> installed: 26.2.5.2), so the position survives under whichever Gate 1
> architecture is ratified. The consolidated doc states 2.20 as
> Gate-1-dependent.

## Local evidence

Source: `TesseraStudio/docs/studio-expansion-plan.md` (main).

- Section 6c: 21 P2 deliverables at time of research; 2.13-2.21 promoted from
  6d on 2026-08-14 for corporate-adoption reasons; the plan flags 2.13/2.15/
  2.16 as carrying "real open design questions, not just unscoped effort".
- 2.13: "most likely a read-and-flag-for-agent-tool-rewrite path rather than a
  real VBA interpreter"; embedding `basic/source/comp/*` "balloons the binary".
- 2.14: `BlockType.equation`'s `latex` string "already covers read/round-trip
  (shipped)"; this item adds authoring UI + engine.
- 2.15: "Tessera materials are document-shaped today, not form-shaped"; ties
  to LO's XForms/UNO control hierarchy; design TBD (material vs BlockType).
- 2.16: "the no-egress doctrine says no SDBC" is "a policy conflict, not a
  complexity one"; needs an explicit egress/credentials/audit decision first.
- 2.19: P1 `TransitionStore` (SwiftUI tween, 30+ preset catalog) already
  covers presets; this adds GPU-rendered transitions on top. The Impress
  scratch report (`lo-impress-report.md:63`) had punted `TransitionerImpl.cxx`
  as "1k+ LoC of GPU plumbing we do not need".
- 2.20: `EnhancedPDFExportHelper.cxx` parity; "a distinct code path from plain
  PDF export"; hard procurement-blocker framing. Writer scratch report line 93
  notes Tessera's current PDF rides textutil/webkit on some paths.
- 2.21: wizard UI layers on 2.4's `MailMergeCoordinator` "single-submit
  endpoint, which stays the underlying engine either way". 2.4 is driven by
  `Doc.linkedEntityIDs`.
- Section 8 binding constraint for 2.13: "any future Tessera scripting surface
  will be a Tessera-native agent tool surface, NOT a Basic dialect."
- No-egress doctrine evidence: `lo-calc-report.md:28,32,114` (no SDBC, no
  embedded Basic, "the agent tool surface IS the scripting model");
  `docs/tessera-productivity-ux-research.md:37,44` (on-device default,
  local-first receipts as signed JSON).

Tier mapping, from `TesseraStudio/docs/agent-tools-surface.md` (sections 2,
10, 11): `ApprovalLevel.auto` -> tier0 = all read tools, no receipts;
`.prompt` -> tier1 = single-entity mutations, exactly one receipt per call;
tier2 = import/export class (`ConfirmationPanel` label); tier3 = destructive
on non-empty material. Naming: snake_case verb_object, no `_v2`. Tools live
one-file-per-surface under `TesseraCore/Tools/`. Tier lowering only via
`TesseraTier.revoke()`. Note (section 11): the import/export->tier2 and
trash->tier3 rules are prose, not code yet.

## SOTA findings per item

### 2.13 Macros / VBA

- ONLYOFFICE: macros are JavaScript on their Office API; VBA is never
  executed. Since v9.0 the built-in AI plugin converts VBA source to a JS
  macro (parse -> map to API -> generate -> user validates; failed conversions
  emit commented explanations).
  https://api.onlyoffice.com/docs/macros/guides/converting-vba-macros/
  https://www.onlyoffice.com/blog/2023/07/transforming-a-microsoft-office-macro-into-an-onlyoffice-macro
- Google: Sheets "macros" ARE Apps Script (recorder generates it). The Macro
  Converter add-on (Enterprise Plus tiers) statically converts Excel VBA to
  Apps Script, emits a compatibility assessment plus README of
  unsupported-API workarounds. VBA is never executed.
  https://developers.google.com/apps-script/guides/macro-converter/convert-files
  https://workspaceupdates.googleblog.com/2020/12/macro-converter-excel-to-google-sheets.html
- Microsoft: web Excel cannot run VBA at all; Office Scripts (TypeScript) is
  the cross-platform successor for new automation.
  https://learn.microsoft.com/en-us/office/dev/scripts/resources/vba-differences
- Collabora is the only vendor executing Basic/VBA-compatible macros - by
  shipping the actual LO runtime, server-side in a per-document container,
  disabled by default, with DB/external-doc/external-program access blocked;
  macro editing is desktop-only. Exactly the embedding cost Tessera's
  one-binary rule rejects.
  https://www.collaboraonline.com/blog/how-to-use-and-manage-macros-in-collabora-online/
- Parse-only feasibility: mature ANTLR4 grammars exist - antlr/grammars-v4
  `vba/`, Rubberduck's production `VBAParser.g4`, ProLeap VB6. ANTLR4 has a
  Swift target.
  https://github.com/antlr/grammars-v4/tree/master/vba
  https://github.com/rubberduck-vba/Rubberduck/blob/next/Rubberduck.Parsing/Grammar/VBAParser.g4
- Storage: DOCM/XLSM/PPTM carry VBA as `word|xl|ppt/vbaProject.bin`, an OLE
  compound file with MS-OVBA run-length-compressed source; olevba is the
  reference extractor, and the decompressor is a few hundred lines
  (ms-ovba-compression).
  https://github.com/decalage2/oletools/wiki/olevba
  https://pypi.org/project/ms-ovba-compression

### 2.14 Equations

- SwiftMath (mgriebling): full-Swift port of iosMath (LaTeX math mode, TeX
  layout rules, CoreText), SPM-native, MIT, iOS 11+/macOS 12+, 39 releases,
  activity within months - maintained, and small enough to vendor.
  https://github.com/mgriebling/SwiftMath
  https://swiftpackageindex.com/mgriebling/SwiftMath
- MathLive: the web SOTA math editor (800+ TeX commands, virtual keyboards,
  exports LaTeX/MathML/Typst/MathJSON) - a web component, so UX reference
  only. https://mathlive.io/
- MathML Core: Baseline since Jan 2023 - relevant as an HTML-export target,
  not as an internal model.
  https://developer.mozilla.org/en-US/docs/Web/MathML
- Typst math: markedly more humane markup than LaTeX - the authoring-UX bar.
  https://typst.app/docs/guides/for-latex-users/
- ODF storage: `<semantics>` wraps presentation MathML plus
  `<annotation encoding="StarMath 5.0">{x}^{2}</annotation>` - LO re-reads
  from the annotation.
  https://lists.w3.org/Archives/Public/www-math/2007Dec/0003.html

### 2.15 Forms

- Modern Word forms = content controls (`w:sdt`): richText/plainText/
  comboBox/dropDownList/datePicker/checkBox (+picture, repeatingSection),
  with `<w:sdtPr>` carrying tag/title/lock and `<w:dataBinding w:xpath=...>`
  binding control content to a custom XML part in the package.
  https://learn.microsoft.com/en-us/visualstudio/vsto/walkthrough-binding-content-controls-to-custom-xml-parts
  https://www.telerik.com/document-processing-libraries/documentation/libraries/radwordsprocessing/model/content-controls/content-controls
- LO implements W3C XForms (legacy, near-zero corporate corpus); AcroForm is
  the PDF output-side model, a separate concern.

### 2.16 Database

- DuckDB: official Swift package `duckdb/duckdb-swift` (Apple/Linux/Windows,
  SPM), in-process analytical engine; native CSV/Parquet/JSON readers; xlsx
  via the excel core extension (`read_xlsx`). Fully local, no network
  required.
  https://duckdb.org/2023/04/21/swift
  https://github.com/duckdb/duckdb-swift
  https://duckdb.org/docs/lts/guides/file_formats/excel_import
- GRDB.swift (groue): SQLite toolkit, v7.11.x, actively maintained 2026.
  https://github.com/groue/GRDB.swift

### 2.20 Tagged PDF / PDF-UA

- LO filter options confirmed (official pdf_params help): `UseTaggedPDF`
  (bool, default false), `PDFUACompliance` (bool, default false; selecting UA
  forces tagged), `SelectPdfVersion` (long: 0=1.7, 1=PDF/A-1b, 2=A-2b,
  3=A-3b, 15/16/17). CLI JSON FilterOptions syntax requires LO > 7.3; PDF/UA
  export itself landed in LO 7.1 (with the accessibility checker). The same
  option names ride the UNO FilterData PropertyValue sequence on storeToURL.
  https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html
  https://help.libreoffice.org/7.1/en-US/text/shared/01/ref_pdf_export_universal_accessibility.html
- PDF/UA-1 conformance model: Matterhorn Protocol 1.1 - 31 checkpoints, 136
  failure conditions; 87 machine-decidable, 47 need human judgment. Headline
  requirements: full semantic tagging + logical reading order, alt text on
  non-text content, artifacting of decoration, document Title + Language
  metadata, table header structure.
  https://pdfa.org/wp-content/uploads/2021/04/Matterhorn-Protocol-1-1.pdf
- veraPDF: open-source validator implementing PDF/A and PDF/UA-1/UA-2; CLI
  `verapdf --flavour ua1 file.pdf`; the standard automatable harness
  (machine-checkable Matterhorn subset). Java-based.
  https://verapdf.org/  https://docs.verapdf.org/validation/
- Apple PDFKit/Quartz: no PDF/UA awareness - Preview/PDFKit ignore structure
  tags; no conformance tooling in the OS. Native export would mean
  hand-building the structure tree over low-level CGPDFContext tag
  primitives, nowhere near Matterhorn coverage.
  https://developer.apple.com/forums/thread/713855
  https://eclecticlight.co/2019/06/26/pdf-without-adobe-24-accessibility-with-pdf-ua/

### 2.19 GPU transitions

- OpenGL is deprecated on macOS (10.14+); Keynote-class transitions (Cube,
  Flip, Ripple, Magic Move) ride Core Animation / Metal compositing.
  https://support.apple.com/guide/keynote/add-transitions-tanff5ae749e/mac
- LO's GL transition set: Tiles, Cube, Circles, Helix, Fall, Turn Around,
  Iris, Turn Down, Rochade, 3D Venetian, Static, Fine Dissolve, Vortex,
  Ripple, Glitter, Honeycomb, Newsflash.
  https://en.wikipedia.org/wiki/LibreOffice_Impress
  https://caolanm.blogspot.com/2016/12/impress-libreoffice-opengl-slide.html
- Core Image ships GPU-backed two-image transition filters natively:
  CIDissolve, CIRipple, CIPageCurl(+WithShadow), CIFlash, CISwipe, CIMod,
  CIBarsSwipe, CICopyMachine, CIAccordionFold, CIDisintegrateWithMask -
  exactly the "two slide snapshots + progress" model.
  https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html

### 2.21 Mail merge

- Word: the classic 6-step wizard still leads on layout fidelity but couples
  sending to a configured Outlook; widely described as clunky.
  https://qualtir.com/blog/mail-merge-word-vs-gmail
- Google: Docs has no native merge (add-on ecosystem fills it); the modern
  native flow is Gmail mail merge (2022-2023): compose + link a Sheet (up to
  1,500 recipients) + tag chips + preview - one surface, no wizard.
  https://workspaceupdates.googleblog.com/2022/10/gmail-built-in-mail-merge-tags.html
  https://workspaceupdates.googleblog.com/2023/06/google-sheets-now-integrated-with-gmail.html

## Design positions

### 2.13 MacroCompatLayer - parse + preserve + agent-assisted rewrite; never execute

The working hypothesis is validated, and it is the industry consensus, not a
compromise: ONLYOFFICE, Google, and Microsoft-on-web all refuse to execute
VBA and offer conversion instead; the only executor (Collabora) does it by
shipping the LO runtime in a server container - unavailable to a local
one-binary app, and already ruled out by the architect ("NOT a Basic
dialect"). Design: on DOCM/XLSM/PPTM import, (1) preserve `vbaProject.bin`
byte-for-byte as an opaque preserved part keyed by its package path on the
material (round-trip = re-emit the untouched part; never re-serialize);
(2) decompress MS-OVBA source per module into read-only derived text;
(3) run a light outline parse (modules, Sub/Function signatures, doc
comments, called-API census a la Google's compatibility assessment) - not a
full grammar; Rubberduck/grammars-v4 remain the escape hatch if
statement-level fidelity is ever needed; (4) agent-assisted translation
renders a draft plan/script over the existing agent tools (the scripting
model), which the user applies through normal tiered calls.

- Files: `TesseraCore/DocumentProcessing/Macros/MacroCompatLayer.swift` +
  `VBAOutlineParser.swift` + `OVBADecompressor.swift`, peers of the bridge
  filters; tools in `TesseraCore/Tools/MacroTools.swift`. Preserved-part
  storage evolves the material import path shared with 2.15's custom XML
  parts (one `PreservedParts` mechanism, not two).
- Tools/tiers: `macro_list` tier0, `macro_read` tier0, `macro_translate`
  tier1 (writes a draft artifact + one receipt; executes nothing). There is
  NO `macro_run`.
- Effort: M. (A real interpreter would be XL and is rejected.)
- P3 punt trigger: if corporate demand is only "don't destroy my macros on
  round-trip", the preservation slice alone is S - ship it in the
  export-filter wave and let outline+translate slip.
- Open question for architect: what artifact does `macro_translate` produce -
  a stored playbook/workflow material (reusable, receipted) or a one-shot
  chat plan? Recommendation: stored playbook, since the tool surface is the
  scripting model.

### 2.14 StarMathEditor - LaTeX-first authoring over SwiftMath rendering

LaTeX-first, confirmed: `BlockType.equation.latex` stays the canonical model;
render natively with SwiftMath (vendored, MIT - TeX layout rules over
CoreText, SPM, alive). Authoring UI is source-editor-with-live-preview plus a
symbol palette (MathLive's keyboard UX and Typst's readable-markup bar are
the references; no WYSIWYG structure editor in v1). Import mapping: ODF
formula objects -> prefer the `StarMath 5.0` annotation when present and
translate StarMath -> LaTeX (small grammar, plain-text); else
presentation-MathML-subset -> LaTeX; DOCX OMML -> LaTeX via the bridge.
Write-back: if the equation was not edited, re-emit the preserved original
annotation/OMML (same preserve-source pattern as 2.13); if edited, emit from
LaTeX and accept LO/Word regenerating their native forms.

- Files: `TesseraCore/Productivity/Materials/Docs/EquationEngine.swift`
  (SwiftMath wrapper, peer of `BlockRenderer`), `StarMathTranslator.swift` +
  `MathMLTranslator.swift` beside the bridge filters; UI
  `EquationEditorView.swift`.
- Tools/tiers: none new - equations ride `doc_write`/`doc_insert_block`
  (tier1) with the `.equation` case; `doc_read` returns the latex string
  (tier0).
- Effort: M (rendering is off-the-shelf; the two translators are the real
  work).
- P3 punt trigger: if SwiftMath render quality fails review on macOS text
  sizes, punt the authoring UI and keep the shipped latex round-trip; do not
  start a native TeX layout engine.
- Open question: equation numbering + cross-references - do they join
  `FieldController` (recommended) or stay out of scope for v1?

### 2.15 Forms - content controls as Block attributes, not a Forms material

Adopt the `w:sdt` content-control model, not XForms and not a new material. A
form is a document with controls, so: add `contentControl: ContentControl?`
as an attribute on existing block cases (block-level SDT) plus an inline-run
annotation tag for inline SDTs - attribute-based, no new BlockType case
needed, which keeps the case budget intact. `ContentControl { kind:
richText|plainText|comboBox|dropDownList|datePicker|checkBox|picture, tag,
title, placeholder, listItems, locks, binding: XPath? }`. Data binding:
preserve imported custom XML parts (shared `PreservedParts` mechanism with
2.13), resolve `dataBinding` XPaths against them, and expose a derived
`FormData` (tag -> value) view. Calc scope v1 = data-validation-backed cells
(P1 `DataValidation` already covers dropdown/checkbox-style corporate
sheets); no worksheet ActiveX-style controls.

- Files: `TesseraCore/Productivity/ContentControl.swift` (peer of `Block`),
  `Materials/Docs/FormController.swift` (peer of `FieldController`); tools
  extend `Tools/DocTools.swift`.
- Tools/tiers: `doc_form_fields_list` tier0; `doc_form_fill` tier1 - it
  mutates content, but it is the canonical bounded, schema-validated write
  (one receipt per call, per-field before/after payload). Export of filled
  data rides `doc_read`/`doc_export` (tier0/tier2 as today).
- Effort: M (L if full native control chrome on iOS + macOS lands in the
  same wave).
- P3 punt trigger: if procurement only needs "open DOCX with content controls
  without breaking them", preservation via the bridge is nearly free;
  interactive fill UI and binding resolution can slip.
- Open question: protection semantics - on a "filling in forms only"
  protected doc, does `doc_form_fill` stay tier1 while other `doc_*` writes
  return `.denied`? Recommended yes; needs the architect to bless
  denial-by-protection as a tier interaction, since tier lowering is
  otherwise revoke-only.

### 2.16 DatabaseConnector - local-file-engines-only; the doctrine wins

Resolve the policy conflict by construction, not by consent UX: no network
DSNs, no ODBC/JDBC/SDBC, no credential storage, ever. A "database" in Tessera
is a local file the user picked: `.sqlite`/`.db` via GRDB, and
CSV/Parquet/JSON (plus optionally xlsx) via DuckDB (`duckdb-swift`), both
in-process and socket-free, opened strictly read-only at the engine level
(SQLITE_OPEN_READONLY / DuckDB read_only) - enforcement by connection mode,
not SQL parsing. Query provenance: `db_query` itself is a read (no receipt,
per the receipts rule); the moment results materialize into a sheet, the
receipt embeds source-file path + content hash + SQL text + row count,
giving the audit log full provenance for every value that entered a
material. Enterprise users needing live Postgres/Oracle export an extract to
Parquet/CSV upstream - that is the consent boundary, and it lives outside
the app by design.

- Files: `TesseraCore/DataAccess/DatabaseConnector.swift` (actor over GRDB +
  duckdb-swift), `Tools/DatabaseTools.swift`.
- Tools/tiers: `db_attach(path)` tier1 (registers a sandbox-scoped bookmark;
  one receipt); `db_schema` tier0; `db_query` (SELECT over attached sources)
  tier0; `db_import_range` (query result -> sheet range) tier1; `db_detach`
  tier1.
- Effort: M (engines are off-the-shelf; the work is bookmarks, read-only
  plumbing, receipts, and the sheet materialization surface).
- P3 punt trigger: if the embedded-Python pandas route (the plan's original
  workaround) is judged adequate - but note it bypasses tiers and receipts
  entirely, which is precisely the corporate-adoption argument for building
  this properly.
- Open questions: (a) xlsx boundary - files already imported as
  SheetWorkbook materials must be queried via `sheet_query`; DuckDB only
  touches non-material files; architect must bless that line to avoid two
  xlsx readers. (b) iOS: DuckDB core-extension loading (excel) may need
  static linking - if awkward, drop xlsx from the v1 db path (CSV/Parquet
  cover the analyst workflow).

### 2.19 GPU transitions - reframe as Metal/Core Image; OpenGL is dead here

Reframe the item: "OpenGL transitions" becomes "GPU transition tier for
TransitionStore". `TransitionSpec` gains a `renderTier`
(`tween | coreImage(name) | metalShader(name)`) - a serialization extension
of the P1 catalog, not a parallel store. Playback composites two slide
snapshots (SlideDeckRenderer already rasterizes slides) through a CI
transition filter or a small Metal pass, driven by progress. Coverage of
LO's GL catalog: Ripple/Fine Dissolve/Static -> CIRipple/CIDissolve(+noise);
Iris -> CIFlash/CIMod-class or a trivial shader; Cube/Fall/Turn Around/
Rochade/3D Venetian -> CoreAnimation CATransform3D perspective on the two
snapshot layers; genuinely-need-custom-Metal: Vortex, Glitter, Honeycomb,
Newsflash, Helix (SwiftUI Shader/layerEffect on macOS 14+/iOS 17+ is the
cheap vehicle). PPTX/ODP round-trip keeps the stored presetId untouched even
when playback approximates.

- Files: `Materials/Slides/TransitionStore.swift` evolves (spec field);
  `Materials/Slides/TransitionRenderer.swift` new, peer of
  `SlideDeckRenderer`; `Shaders/SlideTransitions.metal`.
- Tools/tiers: none new; `slide_set_transition` (tier1) accepts the extended
  spec.
- Effort: M (S if capped at the CA + Core Image set; the five custom shaders
  are the M delta).
- P3 punt trigger: the weakest promotion of the nine - if the wave is tight,
  ship the CA + CI tier with graceful fallback-to-dissolve for the five
  shader presets and punt the .metal file entirely.
- Open question: approximate vs fallback for unimplemented presets -
  recommend approximate, preserve presetId.

### 2.20 Tagged PDF / PDF-UA - LO filter options + native preflight + veraPDF harness

Filter-options path (Gate-1-dependent transport: CLI JSON filter options on
the shipped converter today, or FilterData on whatever structured bridge is
ratified): `UseTaggedPDF=true` + `PDFUACompliance=true` (LO >= 7.1;
installed 26.2.5.2 clears every version floor). The real engineering is
upstream of the flag: the AST -> LO mapping must emit what the tagger needs -
style-based headings, image alt text, table headers, document Title +
Language - so the wave pairs the flag with (a) `AccessibilityPreflight`
(native checks mirroring LO 7.1's checker: missing alt text, heading-order
jumps, missing title/lang) surfaced before export, and (b) an acceptance
harness: CI exports a fixture corpus and runs `verapdf --flavour ua1`,
asserting zero machine-checkable Matterhorn failures (87 of 136 conditions
are machine-decidable - that is the automatable contract; the 47
human-judgment conditions get a documented manual checklist). PDFKit/native
is a dead end for conformance and is not attempted.

- Files: extend the bridge-filter export paths (evolution, not a separate
  exporter - the "distinct code path" lives inside LO); new
  `TesseraCore/DocumentProcessing/AccessibilityPreflight.swift`; CI harness
  under the test tree with veraPDF as a dev-time-only Java dependency (never
  shipped).
- Tools/tiers: `doc_export`/`sheet_export`/`slide_export` gain an
  `accessibility: pdfua` argument (stays tier2, export class); new
  `doc_accessibility_check` tier0 (read, no receipt).
- Effort: S for flag plumbing; M for the full slice (preflight + fixtures +
  harness).
- P3 punt trigger: none for the export flag - highest procurement value per
  line of code in the whole batch. Only the preflight UI may slip.
- Open question: Writer-side PDF export currently bypasses LO on some paths
  (textutil/webkit per the Writer scratch report) - PDF/UA output must route
  through the LO filter; that routing is part of the wave.

### 2.21 Mail-merge wizard (+ 2.4 coordinator) - coordinator-first stands; merge to documents, never to SMTP

Confirmed: `MailMergeCoordinator` (2.4) stays the single-submit engine -
template Doc + data source linked via `Doc.linkedEntityIDs` (SheetWorkbook or
contacts) + field mapping -> N output documents/PDFs, one run-receipt
carrying a per-record manifest. Word's 6-step wizard is the legacy UX;
Gmail's native merge (link a Sheet, tag chips, preview, one send surface) is
the modern pattern - so 2.21 is not six steps but a single guided sheet over
the same endpoint: source picker -> field-chip mapping -> live preview of
record k -> run. The agent is the second client of the same endpoint (tools
compose; no wizard-only logic). Doctrine position: Tessera merges to
documents; it never sends email - output lands as materials/files and the
user's mail client owns delivery. That keeps no-egress intact and dodges the
Word/Outlook coupling failure mode entirely.

- Files: `TesseraCore/Productivity/Materials/Docs/MailMergeCoordinator.swift`
  (2.4); `MailMergeWizardView.swift` (2.21, thin UI); merge fields ride
  `FieldController` - a `mergeField` variant of the planned
  `BlockType.field`, not a parallel placeholder syntax. Tools in
  `Tools/DocTools.swift`.
- Tools/tiers: `merge_preview(record:)` tier0 (read, no receipt); `merge_run`
  tier2 - fan-out creation of N materials/files is export-class blast
  radius, above the single-entity tier1 default.
- Effort: 2.4 M; 2.21 S once the coordinator exists.
- P3 punt trigger: the wizard UI (2.21 only) if agent-driven merges cover
  real usage - the coordinator (2.4) is the load-bearing half and should not
  slip.
- Open question: confirm `BlockType.field` absorbs `mergeField` rather than
  adding a tenth case; and whether contacts-as-source lands in v1 or
  Sheet-only.

## What NOT to adopt

- An embedded Basic/VBA interpreter (2.13). Collabora's execution model
  requires the LO runtime in a sandboxed server container; every local-first
  competitor converts instead of executing. Violates the one-binary rule and
  the architect's "NOT a Basic dialect" decision. No `macro_run` tool at any
  tier.
- Full statement-level VBA grammar in v1 (2.13). The outline + census parse
  delivers the product value; grammars-v4/Rubberduck stay available if
  fidelity demands grow.
- ODBC/JDBC/SDBC, network DSNs, and credential storage (2.16). The conflict
  is resolved by not building the conflicting thing; a consent/tier
  architecture for egress would still make Tessera a credential custodian
  and a data-exfiltration surface, for a workflow Parquet/CSV extracts
  already serve.
- XForms (2.15). Dead standard with a negligible corporate corpus; the DOCX
  `w:sdt` model is what procurement documents actually contain. Also: no
  separate "Forms material" - attribute on Block, per the 3-foot rule.
- MathML as the internal equation model, or a WebView/MathLive editor
  (2.14). LaTeX string is shipped and canonical; MathML is an import/export
  mapping. WebView-based authoring breaks the native SwiftUI direction.
- OpenGL in any form, and SceneKit as a transition engine (2.19).
  Deprecated / wrong tool; CoreAnimation + Core Image + small Metal shaders
  cover the catalog.
- Native tagged-PDF generation over PDFKit/CoreGraphics (2.20). PDFKit has
  no PDF/UA awareness; hand-building Matterhorn-conformant structure trees
  over raw CG tag primitives is a multi-quarter accessibility project the LO
  filter makes unnecessary. veraPDF stays a CI-only dev dependency (Java),
  never in-app.
- Email sending in mail merge (2.21). No SMTP, no send-on-behalf; merge
  output is documents. Sending is the mail client's job and would breach
  no-egress.
- A six-step wizard clone (2.21). One guided sheet over the coordinator
  endpoint, with the agent as the equal-power client.
