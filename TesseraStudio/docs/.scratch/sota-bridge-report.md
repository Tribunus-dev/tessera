# SOTA evidence: LO bridge architecture decision (CLI+FlatODF vs LibreOfficeKit vs URP socket)

Prepared 2026-08-14 by the refinement-pass research agent (bridge architecture),
against LibreOffice 26.2.5.2 (brew cask) on this machine. Evidence input to
`../studio-expansion-design-refinement-2026-08-14.md` Gate 1. Peer of
`lo-{writer,calc,impress}-report.md`. Scope: P1 1.8 (LOBridgeDeckIO), 1.18
(Draw I/O), P2 2.6 (Solver), P2 2.20 (tagged PDF).

Experiment artifacts lived in the session scratchpad (probe C source, test
fods/fodp/fodg outputs); the observations below are what they proved.

## Local evidence

### Installed LO and what ships in the cask

- Binary: /Applications/LibreOffice.app/Contents/MacOS/soffice, reports
  "LibreOffice 26.2.5.2".
- Contents/Frameworks/ (136 entries) contains libmergedlo.dylib (the merged
  monolith), libbinaryurplo.dylib (URP server side), libpyuno.dylib +
  pyuno.so (dead per plan 6a addendum), LibreOfficePython.framework.
- NO libsofficeapp.dylib anywhere in the app (find across the bundle: zero
  hits). LOK's stock init helper looks for that name first; on this build
  the LOK entry points live in the merged lib instead.
- `nm -gU libmergedlo.dylib` exports: _libreofficekit_hook,
  _libreofficekit_hook_2, _lok_preinit, _lok_preinit_2. LOK is compiled in
  and exported.
- NO LibreOfficeKit headers ship anywhere in the app. Headers would come
  from the LO source tree or SDK.
- Only ONE VCL backend ships: libvclplug_osxlo.dylib (Aqua/AppKit). There is
  no libvclplug_svplo (headless) plugin.
- Java UNO client stack ships complete (ridl.jar, jurt.jar, juh.jar,
  unoil.jar, unoloader.jar, libreoffice.jar under Resources/java/).
- `soffice --help` documents `--accept={connect-string}` / `--unaccept`.

### Option B probe: LOK init crashes on the stock cask

A minimal C probe (mirrors the leading LibreOfficeKitClass members, dlopens
libmergedlo.dylib, resolves libreofficekit_hook_2, calls it) produced,
reproduced with and without SAL_USE_VCLPLUGIN=svp:

- DLOPEN_OK, HOOK2_FOUND, then hard crash before init returns:
  NSInternalInconsistencyException "NSWindow should only be instantiated on
  the main thread!". Stack: soffice_main -> ImplSVMain -> InitVCL ->
  CreateSalInstance -> AquaSalInstance ctor -> AppKit NSComboBoxCell popup
  window creation. LOK init spins soffice_main on a secondary thread; the
  only available VCL backend is Aqua, which instantiates AppKit windows,
  which macOS forbids off the main thread.
- SAL_USE_VCLPLUGIN=svp changes nothing because the svp plugin does not
  exist in this build.

Conclusion: LOK on the stock brew cask is not "fragile", it is nonfunctional
at init. Matches upstream (web findings below).

### Option C probe: the URP acceptor works headless, no Python involved

- `soffice --headless --invisible -env:UserInstallation=<fresh>
  "--accept=socket,host=127.0.0.1,port=20026;urp;StarOffice.ServiceManager"`
  came up listening in 4s (nc -z connect succeeded). The acceptor is C++
  (libbinaryurplo.dylib); the broken bundled python3.12 is never touched.
  What is missing is only the CLIENT side in Swift.

### Option A probes: what flat ODF actually carries (verified by grep on real output)

Calc (fods):
- test.csv containing `=B2*C2` cells -> `--convert-to fods` produced LIVE
  formulas: `table:formula="of:=[.B2]*[.C2]" office:value-type="float"
  office:value="7"` (formula + cached value; CSV import evaluated and
  recalculated). number:number-style elements present. Cold first run with
  a fresh profile: 6.0s; warm runs: 2.1-2.5s.
- A hand-written rich .fods (2 sheets, SUM formula, cross-sheet formula,
  date + currency number styles, bold + background cell style, named range)
  -> xlsx -> back to fods. Survived: both sheets, `of:=SUM([.A1:.B1])`,
  cross-sheet `of:=[$Alpha.C1]*2`, number:date-style +
  number:currency-style, fo:background-color, fo:font-weight="bold",
  table:named-range, office:date-value.
- Writer gotcha found empirically: the source must declare
  xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" or LO treats the
  formula prefix as literal text and writes `of:=of:=SUM(...)` on next save.

Impress (fodp):
- The cask's Candy.otp template -> fodp (2.7MB): 6+ style:master-page
  elements by name; placeholder semantics as presentation:class attributes
  (title 20, subtitle 29, outline 37, notes 24, page-number 18, footer 19,
  header 12, date-time 18); presentation:placeholder elements with
  svg:x/y/width/height geometry (incl. handout layouts); draw:page
  elements; 24 presentation:notes elements; style:drawing-page-properties.
- Transition round-trip: injected smil:type="fade" smil:subtype="crossfade"
  presentation:duration="PT00H00M02S" into the page-1 drawing-page style,
  converted fodp -> pptx -> fodp. PPTX carried `<p:transition spd="slow"
  advTm="2000"><p:fade/>` and the return fodp carried smil:type="fade",
  smil:subtype="crossfade", smil:dur="2s". Transitions are fully represented
  in flat ODP.

Draw (fodg):
- A hand-written .fodg with draw:rect, draw:ellipse, draw:connector
  (draw:start-shape/end-shape + glue points), draw:path with bezier svg:d,
  draw:custom-shape (star5 enhanced-geometry), custom layer -> odg -> fodg:
  ALL shape types survived; the connector kept its glue-point bindings and
  gained a computed svg:d; the bezier svg:d and star5 enhanced-geometry
  survived.
- Layer placement rule found empirically: draw:layer-set must live in
  office:master-styles, not in the body. Misplaced, LO silently drops
  custom layers and reassigns shapes to "layout"; correctly placed, the
  custom "annotations" layer survives and the ellipse keeps
  draw:layer="annotations". The 5 standard layers (layout, background,
  backgroundobjects, controls, measurelines) are always emitted.
- SVG IMPORT limitation (matters for 1.18): an SVG with rect + ellipse +
  bezier path + text -> `--convert-to fodg` produced ONE draw:frame
  containing draw:image with office:binary-data (base64) - an embedded
  picture, NOT decomposed shapes. Structured SVG->Shape import is not what
  the CLI gives you. SVG EXPORT is fine: odg -> draw_svg_Export produced
  real `<path d="...">` elements.

PDF filter options (2.20 and deck export), all on 26.2.5.2:
- `--convert-to 'pdf:writer_pdf_Export:{"UseTaggedPDF":{"type":"boolean",
  "value":"true"},"PDFUACompliance":{"type":"boolean","value":"true"}}'`
  accepted; output contains /MarkInfo, /Marked true, /StructTreeRoot, and
  pdfuaid XMP markers (x3). Default export is tagged but has NO pdfuaid;
  forcing UseTaggedPDF=false removes /StructTreeRoot entirely - the JSON
  options demonstrably take effect.
- Impress notes: a 13-slide deck exported 13 pages default, 26 with
  ExportNotesPages=true, 13 with ExportOnlyNotesPages=true. Notes layouts
  work via CLI. Handout layout: no filter option exists (web-confirmed).
- Concurrency: 4 parallel soffice conversions with 4 distinct fresh
  -env:UserInstallation profiles all succeeded, 8.0s wall total (307% CPU)
  vs 2.1s for one warm run.

### The shipped and stranded code (worktree paths)

- Shipped: Productivity/ImportExport/LibreOfficeConverter.swift (177 lines;
  actor; bare-extension --convert-to; per-call throwaway profile; 60s
  timeout), plus WriterBridgeFilter.swift / CalcBridgeFilter.swift
  (CalcBridgeFilter currently round-trips via CSV, flattening inbound
  formulas - the fods evidence above removes that limitation).
- Stranded: DocumentProcessing/LibreOffice/tessera_lo_service.py (745),
  EmbeddedPythonBridge.swift (673; contains LOEnvironment with the
  `case processPool` stub), LibreOfficeBootstrap.swift (174), and
  Package.swift's CPythonBridge target pinned to pythonVersion = "3.14".

## Web findings

- LOK on macOS is upstream-acknowledged nonfunctional: bug 145127
  ("LibreOfficeKit macOS?") - "Unlike Windows and Linux, there is no
  'headless' vcl implementation on macOS"; fixing it means writing a new
  VCL plugin modeled on the iOS one, currently unfunded.
  https://www.mail-archive.com/libreoffice-bugs@lists.freedesktop.org/msg1037075.html
- LOK API surface: https://docs.libreoffice.org/libreofficekit.html and
  https://github.com/LibreOffice/core/blob/master/include/LibreOfficeKit/LibreOfficeKit.hxx
  TDF's "LibreOfficeKit for document conversion" (2024-07-25) shows the
  conversion triple and needs an LO SDK for headers:
  https://dev.blog.documentfoundation.org/2024/07/25/libreofficekit-for-document-conversion/
- URP protocol is fully specified and stable:
  http://www.openoffice.org/udk/common/man/spec/urp.html
  https://wiki.openoffice.org/wiki/Uno/Remote/Specifications/Uno_Remote_Protocol
  https://docs.libreoffice.org/binaryurp.html
  Binary protocol: type-annotated marshaling, protocol-property negotiation,
  thread IDs, oneway calls. No maintained Swift/Go/Rust client exists; a
  hand-rolled Swift client is realistically thousands of lines.
- unoserver runs INSIDE LibreOffice's own Python - dead on this machine for
  the same reason tessera_lo_service.py is. Its README quantifies the
  listener-vs-oneshot trade: a persistent listener cuts CPU 50-75% (2-4x
  throughput). https://github.com/unoconv/unoserver/blob/master/README.rst
- JSON filter-options syntax for --convert-to landed in LO 7.4:
  https://vmiklos.hu/blog/pdf-convert-to.html . Official parameter reference
  (UseTaggedPDF, PDFUACompliance, SelectPdfVersion, ExportNotesPages,
  ExportOnlyNotesPages; no handout option documented):
  https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html
- PDF/UA option exists since LO 7.1:
  https://help.libreoffice.org/7.1/en-US/text/shared/01/ref_pdf_export_universal_accessibility.html
- Impress handouts cannot be exported to PDF by the export filter at all -
  only File > Print reaches the handout view (long-standing enhancement
  request Issue 17387).
  https://ask.libreoffice.org/t/how-to-print-pdf-handouts-in-impress-as-a-script/19251
- Parallel soffice: one process per distinct UserInstallation is the
  universal guidance; failure modes at scale are memory growth and zombie
  processes. No documented hard limit; RAM/CPU bound.
  https://github.com/thecodingmachine/gotenberg/issues/94
- Security note for Option C: an exposed --accept UNO socket is remote code
  execution by design. Localhost-only binding is mandatory; the socket is a
  local code-execution boundary any same-user process can reach.
  https://hackdefense.com/publications/security-advisory-rce-in-apache-uno-api/

## Option comparison

Legend: 1.8 = ODP/PPTX I/O + PDF deck export; 1.18 = ODG/SVG I/O + PDF for
Draw; 2.6 = Solver; 2.20 = tagged PDF.

| | A: CLI + flat-ODF | B: LibreOfficeKit | C: URP socket client |
|---|---|---|---|
| 1.8 | YES, verified both directions; masters, placeholders, notes, transitions in the XML; PDF deck export incl. notes layouts. Handout PDF: no (filter limitation, all options). | Would cover but does not run on macOS stock builds. | YES once a client exists. |
| 1.18 | YES, verified: layers, connectors + glue points, bezier svg:d, custom-shape geometry; SVG + PDF export verified. Caveat: SVG IMPORT arrives as one embedded image, not shapes. | Same coverage in principle; same macOS blocker. | YES; can also drive .uno:Break to decompose SVG imports - the one 1.18 gap A has. |
| 2.6 | NO direct coverage. (Unverified hybrid: pre-seeded profile + macro:/// Basic script invoking the Solver service headless.) | Covers via UNO, but blocked on macOS. | YES - precisely what UNO-over-socket is for. |
| 2.20 | YES, verified end to end on 26.2.5.2. | n/a on macOS. | Same filter via storeToURL; no advantage over A. |
| Effort | Small-medium: Swift FlatODF reader/writer over XML; converter shipped; ~0 new process machinery. The XML IS the structured read. | Very large: build LO from source + write a new macOS headless VCL plugin (upstream: unfunded, nonexistent). | Large: hand-rolled binary URP client in Swift (thousands of lines) OR embedding a JVM (unacceptable). Server side already works. |
| Fragility | Low: CLI flags + ODF schema are decades-stable public contracts; testable with golden files. | Extreme: a self-maintained LO fork forever. | Medium: URP frozen-stable; fragility is process lifecycle + a bespoke protocol stack nobody else exercises. |
| Local-first + receipts | Best: one-shot subprocess, no daemon, no socket; conversions are discrete receipt-able events with input/output hashes. | Moot on macOS. | Daemon + localhost socket = standing code-execution endpoint; needs lifecycle supervision. |
| Perf | 2.1-2.5s warm per call, ~6s cold; 4-way parallel verified; ~2-4x CPU penalty vs a persistent listener at high volume. | (n/a) | Best at volume; needed only if 2s/call hurts. |

## Recommendation

Primary: **Option A** - keep LibreOfficeConverter and build Swift FlatODF
readers/writers (fodt/fods/fodp/fodg) on top of it. The only option fully
working on this machine today, and flat ODF verifiably carries everything
1.8, 1.18, and 2.20 need. Concretely:

- 1.8: LOBridgeDeckIO = soffice odp/pptx -> fodp -> SlideDeck AST parse;
  export = AST -> fodp -> soffice -> odp/pptx; PDF via impress_pdf_Export
  JSON options (notes supported; document handouts as not exportable in any
  architecture).
- 1.18: same shape over fodg; ship SVG import as embedded-image fidelity
  (AST marks it as such); SVG/PDF export via draw_svg_Export /
  draw_pdf_Export.
- 2.20: a thin options layer on LibreOfficeConverter (JSON filter-options
  parameter), not a new code path.
- CalcBridgeFilter migrates from CSV round-trip to fods and stops
  flattening inbound formulas (fixes the fidelity boundary its doc comment
  apologizes for).
- FlatODF writer rules the experiments surfaced: declare xmlns:of; put
  draw:layer-set in office:master-styles.

Fallback: **Option C, scoped, at P2** - adopt only when a deliverable
genuinely needs a live UNO session: today that is 2.6 (Solver) and
optionally SVG shape decomposition (.uno:Break) for 1.18. Before committing
to a hand-rolled Swift URP client for one feature, P2 weighs (a) a native
Swift simplex/LP solver, (b) the unverified macro:///-seeded-profile Basic
hybrid inside Option A's process model, against (c) the URP client. The
verified 4s acceptor startup means C is a pure client-side engineering
cost, not a platform risk.

Option B is **rejected**: empirically crashes at init on the stock cask
(AppKit main-thread exception; no headless VCL plugin shipped), upstream
confirms macOS LOK requires a VCL plugin that does not exist, no headers
ship, and the fix is a self-maintained LO fork.

Stranded code under this recommendation: DELETE EmbeddedPythonBridge.swift
(673), tessera_lo_service.py (745), LibreOfficeBootstrap.swift (174), and
Package.swift's CPythonBridge target + Python 3.14 framework link. Their
entire premise is dead twice over; nothing calls them; the
LOEnvironment.Mode.processPool stub should NOT be resurrected - if C is
built later it should be a fresh URPClient peer of LibreOfficeConverter,
not a revival of the Python stack. PythonSubprocessRunner.swift and
TesseraFormatBridge's python-docx path are unrelated (Homebrew Python
subprocess, no LO linkage) and stay.

## Risks and unknowns

1. Flat-file size/memory: a template fodp is 2.7MB; image-heavy decks embed
   media as base64 in one XML blob. The fodp parser must stream (XMLParser,
   not DOM) and the AST should externalize office:binary-data blobs.
2. SVG import fidelity (verified limitation): CLI import embeds SVG as an
   image; shape-level SVG import is either a native Swift SVG->Shape parser
   (plan 4b calls pure-Swift SVG a P3 stretch) or Option C's .uno:Break.
   Decide at 1.18 scoping, not implicitly.
3. Filter drift across LO majors: only golden-file round-trip tests in CI
   (skippable when soffice is absent) will catch a cask update changing
   behavior. This machine has already had one Gatekeeper regression +
   reinstall cycle.
4. CSV formula evaluation on import is default-on today; the fods migration
   of CalcBridgeFilter removes csv from the loop entirely.
5. Concurrency at scale: 4-way verified; keep a small semaphore (2-4) in
   LibreOfficeConverter and reuse warmed profile dirs to skip the ~4s
   cold-start tax.
6. 2.6 unknowns: the macro:/// Basic headless Solver hybrid is untested;
   the true cost of a minimal Swift URP client is unmeasured; a native
   Swift LP solver diverges from LO results by construction.
7. PDF/UA compliance is document-dependent: the flag sets structure +
   pdfuaid metadata (verified), but real ISO 14289 conformance needs alt
   text, language, contrast etc. in the source AST - 2.20 needs an
   authoring-side checklist, not just the flag.
8. Handout PDF is impossible in every architecture short of driving the
   print subsystem; the plan should record it as out of scope rather than
   leave it implied by "PDF deck export".
