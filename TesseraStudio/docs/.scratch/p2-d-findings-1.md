# P2-D findings - Track D1 (2.13 MacroCompatLayer)

Track ownership: `DocumentProcessing/Macros/{OVBADecompressor,
VBAOutlineParser, MacroCompatLayer}.swift`, `Tools/MacroTools.swift`,
`Productivity/ImportExport/TesseraFormatBridge.swift` (format-list
addition only), and the four new test files under
`Tests/TesseraCoreTests/{DocumentProcessing/Macros,Tools}/`.

One row per blocker, scope note, or design decision worth flagging -
not necessarily bugs.

---

## Design decision: CFBF module-stream boundary located by signature scan, not `dir`-stream `MODULEOFFSET`

A real module stream inside `vbaProject.bin` is `PerformanceCache`
(opaque compiled p-code) followed by the actual MS-OVBA
`CompressedContainer`, with the split point recorded only in the `dir`
stream's `MODULEOFFSET` record ([MS-OVBA] 2.3.4.2 - itself a second,
different compressed record format). This agent has high confidence in
the CFBF/[MS-CFB] container format (used far more broadly - every legacy
Office binary format, not just VBA - so recall is reliable) but only
moderate confidence in the exact `dir`-stream record TAG byte values
from memory, with no reference file or internet access to check them
against. Rather than risk silently-wrong `MODULEOFFSET`s from a
misremembered constant (a correctness bug that would look like
"working" until it slices a real module's source mid-token), the actual
choice: `MacroCompatLayer.decompressedSourceText(fromModuleStream:)`
scans a raw module stream for the `0x01` signature byte followed by a
structurally valid chunk header (correct `CompressedChunkSignature`
bits) AND confirms the remainder decompresses without error - two
independent checks - and returns `nil` (module skipped, not the whole
batch failed) if no offset qualifies.

This is real-format-correct for the common case (a `PerformanceCache`
prefix is compiled bytecode, essentially random-looking binary,
overwhelmingly unlikely to coincidentally look like a valid multi-chunk
OVBA container that also fully decompresses); it is NOT the
spec-authoritative method, and its accuracy against real-world
`vbaProject.bin` files from actual Office installations is unverified
(no reference sample). Recommend: before this ships to users editing
real `.docm` files, either (a) obtain a handful of real
`vbaProject.bin` samples and run them through `MacroCompatLayer.
moduleOutlines` as a corpus check (testing-doctrine.md rule 10's
"empirical probe, clearly marked" shape would fit), or (b) implement
real `dir`-stream `MODULEOFFSET` parsing once someone has reference
access to verify the exact tag values against the actual spec text or a
working implementation (oletools' `olevba`/`vba_context.py` would be the
reference). Recorded for architect ratification - this is exactly the
"real design judgment call... implement it, record it" case the wave
brief calls for.

## Design decision: `TranslatedMacroPlaybook` is a new minimal value type, not a fit for the existing "Playbook" precedent

Grepped `Playbook` in `Sources/TesseraCore` per the item's own
instruction. The only hit, `TesseraReasoningPlaybookStore` (`Learning/
TesseraReasoningPlaybookStore.swift`), is a GLOBAL, file-backed
`[problemClass: [strategy]]` store with no per-entity identity, no
receipt, and no Codable value-type artifact of its own - it is the
"self-improving learning loop" concept the item text names, but its
shape does not fit a per-Doc, per-module, RECEIPTED artifact (the
architect's own ratified decision, studio-expansion-plan.md section 8
row 16). Defined the minimal fallback the item's own text names instead:
`sourceModuleName: String`, `humanSummary: String`,
`suggestedToolCalls: [String]`, plus `calledAPIs: [String]` carried
through so the stored artifact is self-contained (a reader doesn't need
the original outline alongside it). No timestamp field on the type
itself - `translate(_:)` is pure/deterministic (round-trip identity,
testing-doctrine.md rule 2), so whatever wraps this for storage should
stamp `Doc.updatedAt` the way every other DocStore mutation already
does, not read the wall clock from inside this pure function.

## Design decision: preserved-part key = the real OOXML package-relative path

`PreservedParts`'s own doc comment already answers this ("word/
vbaProject.bin", case example) - used the literal real package paths for
all three hosts: `word/vbaProject.bin`, `xl/vbaProject.bin`,
`ppt/vbaProject.bin` (`MacroHostKind.preservedPartKey`). Not an invented
naming scheme - a round trip re-emits the SAME zip entry name it was
read from, matching `PreservedParts`'s own "re-emit verbatim, never
re-serialize" contract.

## Scope gap: Excel/.xlsm and PowerPoint/.pptm have no preserved-part storage this wave

This wave's pre-landed infrastructure (`Doc.preservedParts`,
`DocReceiptType.translateMacro`) only exists on `Doc` (the Writer
material). There is no `Sheet.preservedParts` or
`SlideDeck.preservedParts` field, and no `SheetReceiptType`/
`SlideReceiptType` case for a macro translation receipt. `MacroCompat
Layer`'s own pure pipeline (steps a-d) is fully host-agnostic - it works
identically given any `PreservedParts` bag and a `MacroHostKind` - but
`MacroTools.swift`'s three concrete tools can only reach documents
through `MacroToolContext.DocLoader`, which returns `Doc?`. Scoped
`macro_list`/`macro_read`/`macro_translate` to Word/`.docm` only this
wave (hardcoded `hostKind: .word` in `loadModuleOutlines`), documented
in each tool's own `description` string. If Excel/PowerPoint macro
support is wanted, a future wave needs: `Sheet.preservedParts: Preserved
Parts?` + a `.translateMacro`-equivalent `SheetReceiptType` case (same
for `SlideDeck`/`SlideReceiptType`), plus `MacroToolContext` gaining a
second loader keyed by host kind (or a discriminated union loader) - the
pure `MacroCompatLayer` layer needs zero changes to support this.

## WITHHELD-file gap: the vbaProject.bin -> PreservedParts import-time hook

Per the wave brief's own anticipation ("preservation itself... may need
to happen at import time in a bridge filter outside your file list;
document exactly where that hook needs to go if you can't reach it from
your own files") - confirmed this is real, not reachable from this
track's file list:

- **Exact location**: `DocStore.swift`'s
  `importFromFile(data:format:title:)` (`Sources/TesseraCore/
  Productivity/Materials/Docs/DocStore.swift`, currently lines ~967-
  1001), between step 1 ("Convert to Block AST via the Python bridge")
  and step 2 ("Create the doc"). `DocStore.swift` is explicitly withheld
  from this track this wave.
- **What it needs to do**: when `format` is `docm`/`xlsm`/`pptm` (or
  more generally, whenever the raw `data` the caller passed in is itself
  an OOXML zip package - `docx`/`xlsx`/`pptx` never carry a macro part,
  so this only matters for the three macro-enabled extensions), extract
  `word|xl|ppt/vbaProject.bin`'s raw bytes from that zip and set
  `doc.preservedParts = PreservedParts(parts: [key: bytes])` (merging
  with any 2.15 custom-XML parts already being written to the SAME
  `preservedParts` bag by that track's own import-side work) BEFORE
  `upsert(doc)`.
- **Two viable strategies, (A) recommended**:
  - **(A) Server-side (recommended)**: extend `scripts/tessera-
    format-bridge.py`'s docm/xlsm/pptm import handler to open the OOXML
    zip with Python's stdlib `zipfile` (trivial - a few lines), read the
    macro part's raw bytes if present, and add a `"preservedParts":
    {"word/vbaProject.bin": "<base64>"}`-shaped field to its existing
    JSON response (the same base64-blob channel `TesseraFormatBridge`
    already uses for the whole AST/file). `DocStore.importFromFile`
    decodes that field into `Doc.preservedParts`. Zero new Swift zip
    code; reuses Python's already-battle-tested `zipfile`.
  - **(B) Client-side**: a new Swift-side ZIP central-directory reader
    (OOXML zips are plain ZIP, a much simpler format than CFBF), called
    directly on `data` inside `DocStore.importFromFile` before/after the
    bridge call, independent of the Python bridge. More new code, no
    Python-side change.
- **Export side is symmetric and equally unreached**: re-emitting the
  preserved part verbatim into a `.docm`/`.xlsm`/`.pptm` on EXPORT needs
  the mirror-image change wherever `TesseraFormatBridge.exportFile`'s
  docm/xlsm/pptm path is implemented (also `scripts/tessera-format-
  bridge.py`, not reached this wave either).
- **Caveat on `TesseraFormatBridge.importFormats`/`exportFormats`
  themselves**: this track's OWN file-list item (`TesseraFormatBridge.
  swift`) only gates format RECOGNITION - what the app offers/accepts.
  Adding `"docm"`/`"xlsm"`/`"pptm"` to those two arrays does NOT by
  itself achieve macro preservation, and does not by itself even
  guarantee a docm imports/exports correctly at all: `python-docx`
  (which `_import_docx` in the bridge script presumably uses for
  `.docx`) treats `.docm` as structurally the same OOXML package it
  already reads, but whether it PRESERVES unknown parts like `vba
  Project.bin` on any write-back path, or silently drops them, is
  unverified (no reference access to confirm python-docx's actual
  behavior here). Flagging so this isn't overclaimed as "docm import/
  export now works end to end" - it doesn't, without the hook above.

## Design decision: `macro_translate` receipt is one-per-call (batch), not one-per-module

`DocReceiptType.translateMacro`'s own doc comment reads "A macro (VBA
project module) was translated..." (singular framing), which COULD be
read as one receipt per module. Chose one receipt per `macro_translate`
call instead (covering however many modules were actually translated -
all of them, or just `module_name` if the caller scoped it), matching
`DocStore.recordMailMerge`'s own established precedent in this exact
store ("Unlike every other mutation in this store, this method has no
'did anything change' guard... it always appends exactly one receipt for
a completed run" - same "one call, one receipt, regardless of fan-out
count" shape). `MacroTranslator`'s own doc comment in `MacroTools.swift`
documents this choice. If the architect wants one receipt per module
instead, `DocStore.translateMacro`'s eventual implementation is the only
place that needs to change - `MacroCompatLayer.translate(_:)` already
returns one `TranslatedMacroPlaybook` per outline either way, so nothing
in this track's own files needs to move.

## Design decision: called-API census matches BOTH VBA call styles, not just `Name(...)`

First draft required a trailing `(` (`\bShell\s*\(`), which is wrong for
VBA's very common bare-statement call form (`Shell "cmd.exe"`, no
parens - `Shell`'s return value is usually discarded). Caught by this
agent's own standalone validation run (see below), not by inspection.
Fixed to a plain word-boundary match (`\bShell\b`) - matches the
contract's own "a simple scan... not a security boundary" framing (a
variable literally named `Shell` is an acceptable false positive).

## Provenance note: no reference access to a real `vbaProject.bin` or MS-OVBA/MS-CFB sample

Per item 5's own instruction to document this honestly: every OVBA/CFBF
test fixture in this track (`MacroFixtures.swift`) is hand-written
against the public [MS-OVBA]/[MS-CFB] specifications from this agent's
own knowledge, NOT extracted from any real Microsoft-produced file. The
implementation (`OVBADecompressor.swift`, the `CFBFReader` type in
`MacroCompatLayer.swift`) and its fixture builders were developed and
round-trip-verified together via a standalone `swiftc`-compiled-and-run
script in the session scratchpad (explicitly NOT `swift build`/`swift
test` against the shared package - a throwaway multi-file compile
outside `.build/`, safe to run concurrently with the other 3 tracks).
That script exercised: literal-only + multi-chunk OVBA containers, one
fully hand-worked-by-hand copy-token example (bit-width/offset math
shown in the test's own comment), a raw/uncompressed chunk, every
documented malformed-input error case, 1/2/3-module CFBF fixtures
(crossing the 4-entries-per-directory-sector boundary), and a
>4096-byte module forcing CFBFReader's regular-FAT stream path rather
than the mini-stream path - it caught the API-census parens bug above
AND an unrelated bug in the fixture builder itself (routing a large
module through the mini-stream instead of a regular-sector chain; fixed
in the builder, not in `CFBFReader`, which correctly rejected the
resulting inconsistent input rather than reading garbage). The script
itself is not part of this PR; `MacroFixtures.swift` is its
production-bound output, and every one of the above scenarios has a
corresponding real XCTest in this track's four test files. This gives
real confidence the CFBF/OVBA code is internally consistent and spec-
faithful for the scenarios exercised - it is NOT the same as validation
against a real Office-produced file (see the signature-scan finding
above for the one gap that matters most).

## Scope note: `CFBFReader` supports only the common (<=109 FAT sector) case

No DIFAT sector chain support - `CFBFReaderError.tooManyFATSectors` if a
file needs one. Every real `vbaProject.bin` is small (typically tens of
KB; 109 FAT sectors covers roughly 7-13 MB depending on sector size), so
this is not expected to matter in practice, but it is a real, documented
limitation rather than silent mishandling.

## Scope note: `VBAOutlineParser` explicitly does not parse `Property` procedures or multi-line signatures

Per the design contract's own literal text ("Sub/Function signatures"),
`Property Get/Let/Set` is out of scope - tested
(`testParseIgnoresPropertyProcedures`). Signatures split across lines
via VBA's ` _` continuation are recognized (name/kind matched) but their
parameter list comes back empty rather than parsed - documented in
`VBAOutlineParser.subroutineSignatures`'s own doc comment as a known
"light parser" limitation, not silently dropped.

## Item status summary

1. OVBADecompressor.swift - DONE. Full MS-OVBA `CompressedContainer`
   decompression (compressed + raw chunk types), every malformed-input
   path throws a specific `OVBADecompressorError` case, round-trip-
   verified (see provenance note above).
2. VBAOutlineParser.swift - DONE. Module name, Sub/Function signatures
   (name/params/return type/visibility/static), leading doc comment,
   called-API census - all pure, all tested. Scope notes above (no
   Property, no multi-line signatures) are deliberate per the contract's
   own "light parser" framing.
3. MacroCompatLayer.swift - DONE for everything reachable from this
   track's files: step (a) `preservedVBAProjectBytes` (confirm/extract),
   step (b)/(c) `moduleOutlines` (CFBF extraction + OVBA decompress +
   outline parse per module), step (d) `translate(_:)` ->
   `TranslatedMacroPlaybook`. Step (a)'s OTHER half - actually populating
   `PreservedParts` from a real import - needs the withheld-file hook
   documented above (not implementable from this track's file list, as
   the wave brief itself anticipated).
4. MacroTools.swift - DONE. `macro_list`/`macro_read`/`macro_translate`
   via `MacroToolContext` (closure-seam shape, mirroring `DocToolContext`
   - a parallel track's own file, written against the identical
   "DocStore withheld" constraint this same wave). NOT registered into
   `TesseraToolRegistry.default` (withheld; see wiringNotes in the
   structured report).
5. Tests - DONE. 4 new test files, ~70 test methods total: OVBA hand-
   worked + generated round trips + every malformed-input case;
   VBAOutlineParser signature/doc-comment/API-census extraction incl.
   the parens-vs-bare-statement fix; MacroCompatLayer full pipeline over
   CFBF fixtures (1/2/3 modules, mini-stream AND regular-FAT paths) plus
   TWO explicit "never executes" canary-file assertions (one directly on
   `MacroCompatLayer.translate`, one through the full `macro_translate`
   tool); all three tools' schema round-trip + tier assertion + denial
   path (no context, malformed args, doc/module not found) mirroring
   `DocToolsTests.swift`'s own structure, plus the rule-5 trap test
   (`testExactlyThreeMacroToolsExistAndNoneIsMacroRun`, an independent
   hardcoded list per rule 7).
