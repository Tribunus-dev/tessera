# SOTA evidence: Calc engine (P1 1.10-1.13, 1.21, 1.22; Gate 2)

Prepared 2026-08-14. Provenance: the calc research agent verified the local
findings and dispatched three child studies (OSS engines + Excel semantics;
number formats + query/filter models; CF/validation/comments models), all
three of which delivered; the parent stalled in a relay loop before
composing, so this file was composed by the refinement pass directly from
the delivered evidence, with the key local claims independently re-verified
against main. Evidence input to
`../studio-expansion-design-refinement-2026-08-14.md` (§2 Gate 2 + §4 Calc
cluster). Peer of `lo-calc-report.md`.

## Local evidence (re-verified on main)

- **NumberFormatEngine has ZERO consumers.** grep for `NumberFormatEngine`
  across `Sources/` outside its own file: no hits. The landed P0 engine
  (594 lines, commit `2140af305`) is not on any render path;
  `SheetValueRenderer` still renders through the 8-case categorical
  `SheetNumberFormat` enum in `SheetCellFormat.swift`. A number-format
  parity claim is unverifiable until 1.11 wires it (claim-vs-evidence item).
- **Volatility is a hardcoded name list, not registry metadata.**
  `FormulaEngine/FormulaAST.swift:160-164`: `containsVolatile` checks the
  literal list ["NOW", "TODAY", "RAND", "RANDBETWEEN", "OFFSET",
  "INDIRECT", "INFO"]. There is no per-function volatility axis in the
  function registry; the engine-level dirty/recalc machinery consumes the
  AST flag. (The child study confirms no surveyed engine has an
  "array-volatile" axis either - see below.)
- **SheetCellFormat is already per-CELL.**
  `Materials/Sheets/Sheet.swift:242-259`: `cellFormat(row:col:)` /
  `settingCellFormat(row:col:_:)` read/write a per-cell block attribute
  (`SheetCellFormat.attributeKey`). The plan's earlier "per-column" note
  was wrong in the OTHER direction; 1.11 is a completion + wiring item,
  not a storage-model change.
- **Spill landed; implicit intersection did not.** `SheetEngine.swift`
  (top of file): `spillOrigin: CellAddr?`, `SpillSize`, spilled cells
  refuse edits. `Parser.swift:6` header CLAIMS "implicit intersection" -
  behavior at the evaluator level (@ operator, legacy-import prefixing,
  #SPILL! surfacing) is what 1.21 must verify and complete; do not trust
  the header comment as evidence.
- **CF/validation registries landed unwired** (P0 0.1c/0.1d): the rule
  types exist (`SheetConditionalFormat.swift`, `SheetValidationRule.swift`)
  but carry no priority/stopIfTrue and no evaluation hook into recalc or
  paint (parent's verified interim finding).
- **Comments anchor by block UUID** and survive row splices (parent's
  verified interim finding on `Productivity/Comments.swift`).

## Child study 1: OSS engines + Excel calc semantics (key findings)

- **Ironcalc** (Rust, v0.8 2026-08): dynamic arrays + spill, LAMBDA/LET,
  CF, ~"90% of Excel functions"; demand-driven recursive evaluation with
  an Evaluating/Evaluated state map for cycle detection; NO incremental
  dirty tracking - whole-workbook evaluate() per edit. COPY: the honest
  error taxonomy, esp. a dedicated #N/IMPL! error so unimplemented
  functions degrade loudly. DO NOT COPY: full recalc per edit.
  https://blog.ironcalc.com/ https://docs.ironcalc.com/features/error-types.html
- **HyperFormula**: dependency graph with range-node decomposition
  (SUM(A1:A100) reuses the one-row-shorter range node: O(n) not O(n^2));
  per-structural-op AST transformers (AddRows/RemoveColumns/... rewrite
  each affected AST; deleted targets become literal #REF! nodes -
  deletions are total and serializable). GPLv3: ideas only, never code.
  COPY: range decomposition + transformer pattern (pure AST -> AST per
  op, a clean fit for Swift value semantics). DO NOT COPY: cut-state that
  any subsequent operation silently aborts.
  https://hyperformula.handsontable.com/guide/dependency-graph.html
- **Univer**: COMMAND / MUTATION / OPERATION tiers - MUTATION = smallest
  synchronous serializable model change, the conflict-resolution unit;
  undo = inverse mutations. Strikingly parallel to Tessera's receipts.
  Formula engine runs async + interruptible in a worker. COPY: the
  mutation-tier discipline (already Tessera's shape). DO NOT COPY: the
  DI/plugin microkernel + whole-app-in-worker RPC.
  https://docs.univer.ai/guides/recipes/architecture/univer
- **Excel dynamic arrays**: spill anchor owns the formula; spilled cells
  are ghosted/read-only (matches the landed SheetEngine behavior);
  #SPILL! causes enumerated (obstruction, volatile-resize, edge, table,
  memory, merged cells); implicit intersection `@` is auto-prefixed onto
  legacy formulas on load; `=A2#` spill-range references; `_xlfn.SINGLE`
  / `_xlfn.ANCHORARRAY` are the legacy-file encodings. LAMBDA: first-
  class value, 253-param cap, #CALC! when uncalled, thunks as the
  community array-of-arrays workaround.
  https://support.microsoft.com/en-us/office/dynamic-array-formulas-and-spilled-array-behavior-205c6b06-03ba-4151-89a1-87a7eb36e531
  https://support.microsoft.com/en-us/office/implicit-intersection-operator-ce3be07b-0101-4450-a24e-c1c999be2b34
- **Shared formulas (OOXML t="shared")**: master formula + si index;
  followers reconstruct by R1C1-relative displacement; follower f text is
  ignored in favor of the master.
  https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.cellformula
- **Volatility taxonomy**: Excel = per-function volatile list (+
  argument-dependent INFO/CELL/SUMIF) + per-formula `ca` (calculate cell)
  and `aca` (always calculate array) persistence bits; calcChain.xml is
  an optimization hint, rebuildable, NOT the dependency tree; LO = per-
  token-array `ScRecalcMode` bits {ALWAYS, ONLOAD_MUST, ONLOAD_ONCE,
  ONLOAD_LENIENT, NORMAL, FORCED, ONREFMOVE}. **An "array-volatile"
  FUNCTION class appears in no engine surveyed** - the closest thing is
  Excel's per-formula aca bit. Iterative calc: calcPr iterate/
  iterateCount=100/iterateDelta=0.001; circular set iterated sheet-order
  then row-major, dependency tree ignored inside the loop. MTR: chain
  partitioned into thread-safe sections; INDIRECT/GETPIVOTDATA/CELL(fmt)
  etc. force the main thread.
  https://learn.microsoft.com/en-us/office/client-developer/excel/excel-recalculation
  https://raw.githubusercontent.com/LibreOffice/core/master/include/formula/tokenarray.hxx

## Child study 2: number formats + query/filter models (key findings)

Number formats:
- **ssf pipeline** (SheetJS, the reference JS implementation): section
  split (pos;neg;zero;text, conditional sections via bracketed
  comparisons), char-by-char tokenizer, second pass disambiguating m
  (month vs minute). Documented Excel deviations (3-condition formats
  buggy in Excel itself). https://github.com/SheetJS/ssf
- **Why ICU/CLDR patterns cannot express Excel codes**: TR35 has exactly
  2 subpatterns (no zero/text sections, no conditionals), no fractions,
  no elapsed [h], no fill `*` / pad `_` semantics, no locale bracket
  tags. Grammar-level mismatch, both directions - supports the Gate 2
  position (grammar in Swift, locale DATA from Foundation).
  https://unicode.org/reports/tr35/tr35-numbers.html
- **Corner-case mechanics** (for the gap-closure schedule): fractions =
  denominator-bounded continued-fraction approximation (D = 10^digits-1;
  fixed `#/8` = round(v*8)); elapsed time accumulates past wrap ([h] =
  D*24+H; negative durations: 1900 system shows #####); fill `*` =
  repeat-to-cell-width, pad `_x` = one char's advance width (width-less
  renderers: drop `*`, emit one space); locale tags `[$<currency>-<hex>]`
  with LCID low 16 bits, `[$-F800]` system long date, `[$-x-sysdate]`;
  conditional sections practical limit 2 + fallback, pound-fill on no
  match.
  https://webapp.docx4java.org/OnlineDemo/ecma376/SpreadsheetML/numFmts.html
  https://support.microsoft.com/en-us/office/number-format-codes-5026bbd6-04bc-48cd-bf33-80f18b4eae68
- **Frequency ranking** (best-effort; no corpus study exists): 1. locale
  tags (every UI Long Date / currency-picker cell), 2. fill/pad (stock
  Accounting built-ins 41-44 contain both), 3. elapsed time (built-in 46;
  timedelta round-trips), 4. fractions (built-ins 12/13, niche), 5.
  conditional sections (custom-only, rarest). This ordering drives the
  Gate 2 P1/P2 split.

Query/filter:
- **OOXML autoFilter**: per-column filterColumn with EXACTLY ONE criteria
  child of {filters (literal OR-set + dateGroupItem buckets), top10 (val
  = N-or-percent, filterVal = materialized cutoff), customFilters (max
  two predicates, and/or), dynamicFilter (today/thisWeek/M1-M12/
  aboveAverage... with snapshot vals), colorFilter (dxfId, cellColor
  flag), iconFilter}. Applied state = plain `row@hidden="1"` - criteria
  are stored declaratively and NOT re-evaluated on load; hidden rows are
  truth, criteria are UI state (they can disagree). Wildcards ride
  equal/notEqual with `*`/`?`.
  https://webapp.docx4java.org/OnlineDemo/ecma376/SpreadsheetML/autoFilter.html
- **sortState**: ordered sortCondition list (0..64), applied in document
  order; sortBy value|cellColor|fontColor|icon; customList;
  caseSensitive; stroke/PinYin methods exist for CJK.
- **Tables (ListObject)** are the better home for filter state: named,
  auto-resizing region with headerRowCount + per-column identity
  (id+name) + structured references ([#Data], [@Col]) - versus the bare
  worksheet-level ref rectangle with positional colIds. Direction note
  for a future SheetTable evolution; P1 QueryEngine targets the
  worksheet-level model first.
- **LO internals**: ScQueryParam (MAXQUERY=8 survives only as inline
  small-vector capacity; grows arbitrarily), ScQueryEntry items as
  by-value/by-string/by-date/by-color with multi-item value-in-list;
  operator set includes TOPVAL/BOTPERC/CONTAINS/BEGINS_WITH...;
  ScSortParam keys unbounded; QuickSort Compare() chains keys then
  tie-breaks on original row index - stability by explicit tie-break.
- **Mixed-type sort order** (Excel ascending): numbers < text < logical
  (FALSE<TRUE) < errors < blanks; descending reverses everything EXCEPT
  blanks, which sort last in both directions. LO: numbers before strings,
  empty always after non-empty.
  https://bettersolutions.com/excel/cells-ranges/sorting.htm

## Child study 3: CF / validation / comments models (key findings)

Conditional formatting:
- **cfRule**: 18 rule types (cellIs, expression, colorScale, dataBar,
  iconSet, top10, unique/duplicateValues, 4 text ops, blanks/errors x2,
  timePeriod, aboveAverage); integer `priority` REQUIRED, 1 = highest
  (sheet-global in practice); `stopIfTrue` cuts lower-priority rules for
  a matching cell; per-property winner = highest-priority matching rule.
  dxf payload legally carries font/numFmt/fill/alignment/border/
  protection. Formula rules anchor to the applied range's top-left cell
  with relative-shift semantics (implementation consensus).
  https://c-rex.net/samples/ooxml/e1/Part4/OOXML_P4_DOCX_cfRule_topic_ID0EFKO4.html
- **cfvo math** (the rendering contract): dataBar length = minLength +
  (v-min)/(max-min)*(maxLength-minLength) (defaults 10/90); colorScale =
  per-channel linear interpolation between adjacent stops (LO
  colorscale.cxx confirms; percentile linearly interpolates sorted
  cached values); iconSet default 3TrafficLights1, ascending percent
  steps 0/33/67, `gte` flag per threshold; x14 adds negative-value bar
  colors, axis position, custom icon sets, GUID pairing with legacy
  rules.
  https://webapp.docx4java.org/OnlineDemo/ecma376/SpreadsheetML/dataBar.html
- **Evaluation cost, the consensus**: CF stays OUT of the calc chain.
  Excel evaluates CF at REPAINT time for visible cells only
  ("super-volatile", re-evaluated on scroll; measured 2.8s vs 0.2s F9
  delta with a CF sheet visible; duplicate-detection over 132K cells =
  40s pathological). LO is lazy per-cell (IsCellValid -> Interpret on
  query) with per-entry cached range aggregates bracketed by
  startRendering/endRendering. Adopt: viewport-lazy paint-time
  evaluation + cached per-rule aggregates (min/max/percentile/duplicate
  sets) with explicit edit invalidation.
  https://fastexcel.wordpress.com/2013/10/09/exploring-conditional-format-performance-part-1-whats-slow-whats-buggy-and-whats-faster/

Data validation:
- **dataValidation**: type {whole, decimal, list, date, time, textLength,
  custom}, operator (8, default between), errorStyle {stop, warning,
  information}, allowBlank, prompts/errors, formula1/formula2.
  **showDropDown is INVERTED in practice** (true = SUPPRESS the arrow) -
  model internally as hideDropDown. List sources: inline quoted literals
  or range refs; cross-sheet sources need the x14 extension (2010+).
  https://webapp.docx4java.org/OnlineDemo/ecma376/SpreadsheetML/dataValidation.html
- **Enforcement reality**: Excel validates ONLY direct keyboard entry -
  paste, fill, formulas, and macros bypass by design; audit-after =
  "Circle Invalid Data". Google Sheets: per-rule reject vs warn (orange
  triangle); API exposes `strict`. Consensus: validate-at-interactive-
  entry + audit-after; engine/agent writes are RECORDED invalid, never
  blocked.
  https://support.microsoft.com/en-us/excel/more-on-data-validation

Comments:
- **Threaded model** (adopt): xl/threadedComments part + persons.xml
  (GUID person registry with providerId/userId); flat comment list, GUID
  ids, parentId-to-root replies, UTC dT, `done` resolve flag, plain text
  + mention offsets. Legacy notes (rich-text runs + VML anchors) and the
  legacy-placeholder dual-write ("tc={uid}" author marker) are an XLSX
  export shim only, never internal storage.
  https://learn.microsoft.com/en-us/openspecs/office_standards/ms-xlsx/42f9b03d-9662-4204-9783-dbeb324a691c

## Design recommendations (consolidated in the refinement doc §4)

1. **1.10 QueryEngine**: OOXML criteria model (value-set OR / custom pair
   / top10 / dynamic / color per column) + ordered stable multi-key sort
   with the mixed-type order table and explicit original-index tie-break;
   criteria = UI state, hidden rows = truth; one receipt per user action.
2. **1.12 CF evaluation**: evolve the landed registry with priority +
   stopIfTrue + the documented cfvo math; staged rule types (timePeriod
   P2); viewport-lazy paint-time evaluation with cached range aggregates;
   never a dependency-graph node.
3. **1.13 DataValidation**: validate-at-entry + audit-after; hideDropDown
   inversion handled at the bridge; engine/agent writes recorded, not
   blocked (agent tools rely on this - a blocking model would make
   `sheet_write` nondeterministic).
4. **1.11 per-cell styles**: WIRE NumberFormatEngine into
   SheetValueRenderer (zero consumers today); evolve SheetNumberFormat
   cases into format-code presets; complete borders/alignment + the dxf
   subset 1.12 needs. Storage model is already per-cell - no change.
5. **Gate 2 sizing** (the five documented engine gaps): locale-ID tags =
   M (LCID table + system-date passthrough; highest frequency); fill/pad
   = S in the width-aware cell renderer, trivial degradation elsewhere;
   elapsed time = S-M (accumulation math is specified); fractions = M
   (continued-fraction approximation); conditional sections = M and
   rarest. Recommendation: ratify landed scope; close locale tags +
   fill/pad at P1 (with the wiring); elapsed + fractions P2; conditional
   sections last.
6. **1.21 dynamic arrays**: implicit intersection @ + legacy-import
   prefixing (SINGLE/ANCHORARRAY encodings at the bridge), #SPILL!
   surfacing, volatile-resize protection; adopt LO-style ONLOAD recalc
   bits for import correctness; register OFFSET/INDIRECT/INFO volatility
   through one mechanism (today it is a hardcoded list in
   FormulaAST.containsVolatile - fine, but 1.21's tests must pin it).
7. **Volatile-array verdict**: DROP FunctionVolatility.array (plan row
   20). No surveyed engine has the axis; Excel's aca is a per-formula
   persistence bit. If a per-formula "always recalc array" bit is ever
   needed, it rides the TokenArray (the ScRecalcMode/aca precedent),
   not the function registry.
8. **1.22 comments**: threaded shape via the shared CommentAnchor design
   (see sota-writer-slides-report.md §10); person registry deferred to
   the bridge boundary until multi-author lands.

## What NOT to adopt

- Whole-workbook recalc per edit (Ironcalc's evaluate()) - the landed
  dirty-cone machinery is already ahead; keep it.
- HyperFormula code (GPLv3) - patterns only (range decomposition,
  structural-op AST transformers, #REF! materialization).
- A calcChain.xml-style persisted calculation order - it is an
  optimization hint upstream, and Tessera's DependencyGraph rebuilds
  order; persisting it would create a second source of truth.
- FunctionVolatility.array - phantom axis (see verdict 7).
- Blocking data validation on engine/agent writes - contradicts every
  surveyed implementation and would break agent-tool determinism.
- CF inside the dependency graph, or eager whole-sheet CF evaluation -
  the measured Excel pathologies are the cautionary tale.
- Excel's dual-part legacy comment storage internally - export shim only.
- The 255-char list-literal cap and similar Excel UI limits as engine
  invariants - bridge-boundary validations, not model constraints.
