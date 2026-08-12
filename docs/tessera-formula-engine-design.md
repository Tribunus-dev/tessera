# Tessera Formula Engine
## Architecture Design — HyperFormula Patterns + Formularizer Patterns in Swift

Date: 2026-08-11
Author: Mavis (for Julian Torres, sole architect)
Purpose: Design a Swift-native spreadsheet formula engine that combines the UX patterns from
HyperFormula (headless spreadsheet, incremental recalc, dirty tracking) with the architectural
patterns from Formularizer (Arrow-backed storage, dependency graph, undo/redo, SheetPort,
deterministic mode, 400+ functions). Built in Swift. MIT/Apache-2.0 compatible.

---

## 1. Scope and Goals

### What we're building

A Swift-native headless spreadsheet engine — no UI, no rendering. The pixels are
Tessera's problem via `SheetGridView`. The engine parses Excel-compatible formulas,
maintains a dependency graph, incrementally recalculates on edit, supports undo/redo,
and persists to XLSX.

### What "HyperFormula patterns" means

The UX/integration patterns from HyperFormula (all TypeScript, GPLv3) adapted to Swift:

- Headless: engine is decoupled from any rendering layer
- Incremental recalculation: edit one cell → only dirty subgraph recomputes
- Shared ASTs: formula stored once, all cells referencing it point to the same node
- Lazy CRUD: row/column insert marks formulas dirty, doesn't rewrite them until read
- Dirty tracking: per-cell dirty flag + reverse dependency edges for BFS propagation
- 400+ Excel-compatible built-in functions
- Function autocomplete metadata (param names, types, descriptions)
- Named expressions

### What "Formularizer patterns" means

The architectural/enterprise patterns from Formularizer (MIT/Apache-2.0, Rust/PyO3) adapted to Swift:

- **Arrow-inspired columnar storage**: range operations (SUMIFS, VLOOKUP) receive typed
  slices directly rather than iterating cell-by-cell. Represent as `[Double]`, `[String]`
  slices rather than `[(Int, Int) -> Value]` closures.
- **Dependency graph with cycle detection**: topological schedule prevents circular references
- **Undo/redo transactional changelog**: action grouping, rollback, replay. Every edit is
  individually undoable. Grouped edits (paste range) = one undo step.
- **SheetPort**: treat any workbook as a typed API via YAML manifests. Schema validation
  + batch scenario evaluation. The corporate procurement killer: "upload this sheet,
  my AI agent evaluates your input against the model."
- **Deterministic mode**: injectable clock, timezone, and RNG seed. Every formula
  evaluation is reproducible. Critical for receipt-traceable AI agent operations.
- **Incremental propagation via reverse edges**: BFS from dirty cell through `dependents[cell]`,
  stop when values stabilize. Correct handling of volatile functions (NOW, RAND).
- **XLSX I/O**: load and write `.xlsx` files preserving formulas and formatting

### Non-goals (deferred)

- ODS format support
- VBA macros
- Excel add-ins (XLL)
- Real-time collaborative editing (multi-player)
- Dynamic array functions (FILTER, UNIQUE, SORT, SORTBY) — Phase 2

---

## 2. Type System

```swift
/// The value type system mirrors Excel's. Every cell holds exactly one Value.
public enum Value: Equatable, Sendable {
    case null                           // empty cell
    case number(Double)                 // all numeric types unify to Double
    case bool(Bool)                    // TRUE/FALSE
    case string(String)                // text
    case error(ValueError)             // #DIV/0!, #REF!, #NAME?, etc.
    case date(Date)                    // internal date representation
    case array(rows: Int, cols: Int, flat: [Value])  // array/matrix result
}

/// Excel error codes
public enum ValueError: Equatable, Sendable {
    case divisionByZero      // #DIV/0!
    case notAvailable       // #N/A
    case nullReference      // #NULL!
    case numberInvalid     // #NUM!
    case referenceInvalid   // #REF!
    case nameInvalid       // #NAME?
    case spill             // #SPILL! (Phase 2)
    case null              // #NULL!

    public var displayString: String { switch self {
        case .divisionByZero: return "#DIV/0!"
        case .notAvailable:   return "#N/A"
        case .nullReference:  return "#NULL!"
        case .numberInvalid:  return "#NUM!"
        case .referenceInvalid: return "#REF!"
        case .nameInvalid:    return "#NAME?"
        case .spill:         return "#SPILL!"
        case .null:          return "#NULL!"
    }}

    public var isCritical: Bool { switch self {
        // #DIV/0!, #NUM!, #REF!, #NAME? propagate
        case .divisionByZero, .numberInvalid, .referenceInvalid, .nameInvalid: return true
        // #N/A, #NULL! are "blankable" errors
        default: return false
    }}
}
```

### Type coercion rules

```
number + number → number
string + string → string (concatenation, unless numeric)
number * string → #VALUE!
bool + bool → number (TRUE=1, FALSE=0 in arithmetic contexts)
anything + error → error
```

---

## 3. Cell Addressing

```swift
/// A single cell reference, e.g. "A1", "AA100", "$B$5", "Sheet3!$D7"
public struct CellRef: Hashable, Sendable, CustomStringConvertible {
    public let sheet:  String?      // nil = same sheet
    public let column: Int         // 0-based (0 = A)
    public let row:    Int         // 0-based (0 = row 1)
    public let colAbsolute: Bool   // $ prefix
    public let rowAbsolute: Bool   // $ prefix

    public init(sheet: String? = nil, column: Int, row: Int,
                 colAbsolute: Bool = false, rowAbsolute: Bool = false)
    public static let a1 = CellRef(column: 0, row: 0)
}

/// A rectangular range, e.g. "A1:B10", "Sheet2!$C$5:$D$15"
public struct RangeRef: Hashable, Sendable {
    public let sheet:    String?
    public let topLeft:  CellRef
    public let bottomRight: CellRef

    public var width:  Int { bottomRight.column - topLeft.column + 1 }
    public var height: Int { bottomRight.row    - topLeft.row    + 1 }

    /// Iterate all cells in the range
    public func cells() -> [CellRef]
}
```

---

## 4. Formula AST

```swift
/// A formula AST node. Immutable once constructed.
public indirect enum FormulaAST: Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case cell(CellRef)                        // single cell reference
    case range(RangeRef)                      // range → evaluates to array
    case binary(op: BinaryOp, left: FormulaAST, right: FormulaAST)
    case unary(op: UnaryOp, operand: FormulaAST)
    case function(name: String, args: [FormulaAST])
    case arrayLiteral([[FormulaAST]])         // {1,2;3,4} matrix literal
    case error(ValueError)                    // literal error
}

/// Binary operators (Excel precedence order)
public enum BinaryOp: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/"
    case power = "^", concat = "&"
    case equal = "=", notEqual = "<>", less = "<", greater = ">"
    case lessOrEqual = "<=", greaterOrEqual = ">="
    case intersect = " "  // implicit intersection operator
    case rangeOp = ":"    // range operator
}

/// Unary operators
public enum UnaryOp: String, Sendable {
    case negate = "-", plus = "+", percent = "%"
}

/// Formula with source tracking and a unique ID for shared AST deduplication
public struct Formula: Sendable {
    public let id: UUID           // shared AST identity
    public let ast: FormulaAST
    public let source: String    // original "=SUM(A1:A10)" for display/error
    public let span: SourceSpan?  // byte offset for error reporting

    public init(source: String, ast: FormulaAST)
}
```

---

## 5. Lexer + Parser

### Lexer

Tokenizes `"=SUM(A1:B5, C1) & "total""` into:

```
TOKEN_FORMULA_MARKER (=)
TOKEN_FUNC (SUM, arity: 1..*)
TOKEN_LPAREN
TOKEN_RANGE (A1:B5)
TOKEN_COMMA
TOKEN_RANGE (C1)
TOKEN_RPAREN
TOKEN_CONCAT (&)
TOKEN_STRING ("total")
```

### Parser

Pratt parser (operator-precedence) handles Excel's 18-level precedence table.

Key Excel precedence rules:
```
1.  :  (range)
2.  ;  (union, implicit intersection)
3.  - (negate), + (positive), % (percent)
4.  ^  (power)
5.  *, /
6.  +, -
7.  &  (concatenation)
8.  =, <>, <, >, <=, >=
```

Handles:
- Named ranges (`=Revenue - Expenses`)
- Sheet-qualified refs (`=Sheet2!A1`)
- External refs (`='[Book1.xlsx]Sheet1'!$B$2`) — read-only
- Array literals (`={1,2,3;4,5,6}`)
- Implicit intersection (`A1` in a row context = that row's A1)

---

## 6. Dependency Graph

```swift
/// Bidirectional dependency graph for incremental recalculation.
/// Maintains both directions so we can:
///   - Resolve evaluation order (precedents)
///   - Propagate dirty state (dependents)
public final class DependencyGraph: Sendable {
    /// precedents[cell] = cells this cell depends on (forward edges)
    private var precedents: [CellAddr: Set<CellAddr>] = [:]
    /// dependents[cell] = cells that depend on this cell (reverse edges)
    private var dependents:  [CellAddr: Set<CellAddr>] = [:]
    /// formula[cell] = parsed formula AST for this cell
    private var formulaAST:   [CellAddr: FormulaAST] = [:]

    /// Topological sort with cycle detection
    public func evaluationOrder(from roots: [CellAddr]) throws -> [CellAddr]
    /// BFS propagation from dirty cell to all downstream dependents
    public func dirtySubgraph(from dirty: CellAddr) -> Set<CellAddr>
    /// Remove all edges for a cell (used before deleting)
    public func removeCell(_ addr: CellAddr)
    /// Add or update formula edges for a cell
    public mutating func setFormula(_ addr: CellAddr, ast: FormulaAST) throws
    /// Get all cells that depend (directly or transitively) on a cell
    public func allDependents(of addr: CellAddr) -> Set<CellAddr>
}
```

**Cycle detection**: topological sort throws on cycles. Excel's behavior is to show
`#REF!` for the cell that completes the cycle — we do the same.

**Volatile function handling**: cells with volatile functions (NOW, TODAY, RAND, OFFSET,
INDIRECT) are marked volatile. On any recalc, ALL volatile cells are marked dirty first
— their values can change without their inputs changing.

---

## 7. Evaluator

```swift
/// Recursive evaluator with call-stack depth limit (prevent infinite recursion)
public final class Evaluator {
    public struct Config {
        public var maxCallDepth: Int = 50
        public var maxArraySize: Int = 10_000
        public var deterministicMode: DeterministicConfig?
    }

    public func evaluate(_ ast: FormulaAST, at addr: CellAddr) throws -> Value

    /// Evaluate a range → materialize as flat array
    public func evaluateRange(_ range: RangeRef) throws -> [Value]

    /// Batch evaluate a list of cells in topological order (called by engine)
    public func evaluateAll(_ order: [CellAddr], engine: &SheetEngine) throws
}
```

### Evaluation mechanics

```
evaluate(cell) {
    1. If cached and not dirty → return cached
    2. Get topological order of this cell's precedents
    3. Recurse: evaluate each precedent first
    4. Apply formula AST → Value
    5. Cache result
    6. Return
}
```

**Array evaluation**: ranges evaluate to `[Value]` (flat row-major). Functions like
`SUM(A1:B10)` receive the materialized `flat: [Value]` slice directly — no cell-by-cell
iteration in the hot path.

---

## 8. Built-in Function Registry

### Phase 1 (~25 functions — lean core for knowledge workspace)

| Category | Functions |
|---|---|
| Arithmetic | `+`, `-`, `*`, `/`, `^`, `%` (in AST) |
| Aggregate | `SUM`, `AVERAGE`, `COUNT`, `COUNTA`, `MAX`, `MIN`, `PRODUCT`, `SUBTOTAL` |
| Logic | `IF`, `IFS`, `AND`, `OR`, `NOT`, `IFERROR`, `IFNA`, `TRUE`, `FALSE`, `SWITCH` |
| Lookup | `INDEX`, `MATCH`, `VLOOKUP`, `HLOOKUP`, `CHOOSE`, `ROW`, `COLUMN`, `ROWS`, `COLUMNS`, `ADDRESS` |
| Text | `CONCATENATE`, `LEN`, `LEFT`, `RIGHT`, `MID`, `TRIM`, `UPPER`, `LOWER`, `PROPER`, `SUBSTITUTE`, `FIND`, `SEARCH`, `TEXT`, `VALUE`, `REPT`, `REPLACE`, `TEXTBEFORE`, `TEXTAFTER` |
| Math | `ABS`, `ROUND`, `ROUNDUP`, `ROUNDDOWN`, `INT`, `MOD`, `SQRT`, `POWER`, `LOG`, `LOG10`, `LN`, `EXP`, `PI`, `SIGN`, `CEILING`, `FLOOR`, `SUMIF`, `COUNTIF`, `AVERAGEIF`, `SUMIFS`, `COUNTIFS`, `AVERAGEIFS` |
| Date/Time | `TODAY`, `NOW`, `DATE`, `YEAR`, `MONTH`, `DAY`, `HOUR`, `MINUTE`, `SECOND`, `WEEKDAY`, `WEEKNUM`, `EDATE`, `EOMONTH`, `TIME`, `DATEDIF`, `DAYS` |
| Type | `ISBLANK`, `ISNUMBER`, `ISTEXT`, `ISLOGICAL`, `ISERROR`, `ISNA`, `ISERR`, `N`, `NA`, `TYPE`, `ERROR.TYPE`, `CELL` |
| Array (Phase 2) | `TRANSPOSE`, `FREQUENCY`, `GROWTH`, `TREND` |

### Phase 2 (~50 functions — corporate/financial extension)

| Category | Functions |
|---|---|
| Financial | `NPV`, `PV`, `FV`, `PMT`, `RATE`, `NPER`, `IRR`, `MIRR`, `PPMT`, `IPMT`, `DB`, `DDB`, `SLN`, `SYD`, `COUPNCD`, `COUPPCD`, `COUPNUM`, `COUPDAYBS`, `COUPDAYSNC`, `ACCRINT`, `ACCRINTM`, `DISC`, `PRICE`, `YIELD`, `MDURATION`, `ODDFPRICE`, `ODDFYIELD`, `ODDLPRICE`, `ODDLYIELD`, `TBILLEQ`, `TBILLPRICE`, `TBILLYIELD`, `XNPV`, `XIRR`, `XLOOKUP` |
| Statistics | `STDEV`, `STDEVP`, `VAR`, `VARP`, `MEDIAN`, `MODE`, `PERCENTILE`, `QUARTILE`, `CORREL`, `COVAR`, `RSQ`, `SLOPE`, `INTERCEPT`, `FORECAST`, `LARGE`, `SMALL`, `RANK`, `PERCENTRANK`, `PERCENTILE.EXC`, `PERCENTILE.INC`, `MODE.SNGL`, `MODE.MULT` |
| Engineering | `BIN2DEC`, `DEC2BIN`, `HEX2DEC`, `DEC2HEX`, `CONVERT`, `DELTA`, `GESTEP`, `COMPLEX`, `IMREAL`, `IMAGINARY`, `IMSUM`, `IMPRODUCT` |
| Info | `INFO`, `ERROR.TYPE` |
| Dynamic arrays (Phase 2) | `FILTER`, `UNIQUE`, `SORT`, `SORTBY`, `SEQUENCE`, `LET`, `LAMBDA`, `BYROW`, `BYCOL`, `MAP`, `SCAN`, `REDUCE`, `MAKEARRAY`, `ISOMITTED` |

### Function signature metadata (for autocomplete)

```swift
public struct FunctionSignature: Sendable {
    public let name: String
    public let description: String
    public let parameters: [Parameter]
    public let returnType: ValueType
    public let volatility: FunctionVolatility
}

public struct Parameter: Sendable {
    public let name: String
    public let description: String
    public let type: ValueType        // what this param accepts
    public let optional: Bool
    public let repeatable: Bool       // ..., e.g. SUM(a, b, ...)
}

public enum FunctionVolatility: Sendable {
    case notVolatile    // pure function, cacheable
    case volatile       // NOW, TODAY, RAND, OFFSET, INDIRECT, INFO
}
```

---

## 9. Arrow-Inspired Columnar Storage

Formularizer's key architectural insight: range operations are the hot path, and they
should receive typed slices, not cell-by-cell callbacks.

```swift
/// A column slice — the unit of efficient range operations.
/// Instead of calling a closure for each cell, functions receive typed arrays.
public struct ColumnSlice: Sendable {
    public let values: ContiguousArray<Double?>    // null = empty cell
    public let strings: ContiguousArray<String?>
    public let bools:    ContiguousArray<Bool?>
    public let errors:  ContiguousArray<ValueError?>

    /// Build from a sheet region
    public init(from range: RangeRef, engine: &SheetEngine)

    /// SUM of numeric values (ignores non-numeric)
    public func sum() -> Double
    /// AVERAGE of numeric values
    public func average() -> Double
    /// COUNT of non-empty cells
    public func count() -> Int
    /// Numeric count only
    public func countNumbers() -> Int
    /// MIN/MAX
    public func min() -> Double?
    public func max() -> Double?
    /// Aggregate with condition (SUMIF pattern)
    public func sumWhere(condition: (Double) -> Bool) -> Double
}
```

**How it works in SUMIFS**:
```swift
// Traditional: for cell in range { if condition { sum += cell.value } }
// Arrow: let slice = ColumnSlice(from: range); return slice.sumWhere { $0 > 0 }
//
// slice.sum() iterates a ContiguousArray<Double?> in O(n) with no Swift overhead
// (the Array reps a column, not a row, so hot-range SUM over 1000 rows = one slice)
```

---

## 10. Undo/Redo Changelog

```swift
/// One undoable edit
public struct Edit: Sendable {
    public let id: UUID
    public let timestamp: Date
    public let groupID: UUID?       // nil = individual edit; same groupID = one undo step
    public enum Change: Sendable {
        case setValue(addr: CellAddr, old: Value, new: Value)
        case setFormula(addr: CellAddr, old: Formula?, new: Formula?)
        case insertRow(at: Int, count: Int, values: [[Value]])
        case insertCol(at: Int, count: Int, values: [[Value]])
        case deleteRow(at: Int, count: Int, values: [[Value]])
        case deleteCol(at: Int, count: Int, values: [[Value]])
        case moveRow(from: Int, to: Int)
        case moveCol(from: Int, to: Int)
        case setName(name: String, old: NamedRange?, new: NamedRange?)
        case clearSheet(name: String)
        case renameSheet(old: String, new: String)
        case insertSheet(name: String, at: Int)
        case deleteSheet(name: String)
    }
}

/// Transactional changelog with action grouping
public final class UndoRedoStack: Sendable {
    public var undoStack: [Edit] = []
    public var redoStack: [Edit] = []

    /// Group several edits into one undo step
    public func beginGroup()
    public func endGroup()

    /// Push an edit (or group of edits) onto the undo stack
    public mutating func push(_ edit: Edit)

    /// Undo — returns the compensating edit(s)
    public mutating func undo() -> [Edit]

    /// Redo — returns the original edit(s)
    public mutating func redo() -> [Edit]

    /// Clear redo stack when new edit is pushed (standard undo behavior)
    public mutating func commit(_ edit: Edit)
}
```

**Paste = one undo step**: `beginGroup()` before paste, `endGroup()` after. Ctrl+Z undoes the entire paste. Individual cell edits within the group share a `groupID`.

---

## 11. SheetPort: Typed Workbook API via YAML Manifests

Formularizer's SheetPort turns a spreadsheet into a typed function. We replicate this.

```swift
/// A SheetPort manifest — describes the contract for a typed workbook API
public struct SheetPortManifest: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public let cell: String          // "B2"
        public let label: String         // "Revenue Growth Rate"
        public let type: String          // "number", "percentage", "text"
        public let required: Bool
        public let range: String?         // "B2:D2" for array inputs
        public let validation: ValidationRule?
    }
    public struct Output: Codable, Sendable { /* similar to Input */ }
    public struct Scenario: Codable, Sendable {
        public let name: String
        public let description: String
        public let inputs: [String: String]  // label -> value
    }

    public let title: String
    public let description: String
    public let version: String
    public let inputs: [Input]
    public let outputs: [Output]
    public let scenarios: [Scenario]
}

/// SheetPort runtime
public final class SheetPort: Sendable {
    public func load(manifest: SheetPortManifest, workbook: &SheetEngine) throws
    public func validateInputs(_ values: [String: Value]) throws -> [String: Value]
    public func runScenario(_ name: String) throws -> [String: Value]
    public func evaluateAll() throws -> [String: Value]
    public func diff(scenario a: String, scenario b: String) throws -> [String: (Value, Value)]
}
```

**Manifest YAML example:**
```yaml
title: "Revenue Model v1.2"
version: "1.2.0"
inputs:
  - cell: B2
    label: "Revenue Growth Rate"
    type: percentage
    required: true
    validation: { min: -0.5, max: 2.0 }
  - cell: B3
    label: "Operating Margin"
    type: percentage
    required: true
outputs:
  - cell: E10
    label: "Net Income"
    type: currency
  - cell: E11
    label: "Operating Cash Flow"
    type: currency
scenarios:
  - name: "Bull Case"
    description: "15% growth, 25% margin"
    inputs:
      "Revenue Growth Rate": 0.15
      "Operating Margin": 0.25
  - name: "Bear Case"
    inputs:
      "Revenue Growth Rate": 0.02
      "Operating Margin": 0.10
```

**The killer corporate procurement feature**: a CFO uploads a revenue model workbook, annotates it with a SheetPort manifest, and sends it to counterparties. Counterparties fill in their inputs via a web form (backed by SheetPort). The model evaluates deterministically — every number traces to the input cell that produced it. No Excel license needed. No macros. No opaque cell formulas.

---

## 12. Deterministic Mode

For AI agent operations and receipt-traceable calculations:

```swift
public struct DeterministicConfig: Sendable {
    public var clockSeed: UInt64    // fixed "now" in seconds since epoch
    public var timezone: String     // e.g. "America/Los_Angeles"
    public var rngSeed: UInt64      // reproducible RAND(), RANDBETWEEN()
    public var locale: String       // for NUMBERFORMAT localization

    /// Evaluate NOW() → returns the fixed clock seed date
    /// Evaluate RAND() → deterministic pseudo-random
    /// Evaluate TODAY() → derived from clockSeed
}

public final class DeterministicEngine: Sendable {
    public init(config: DeterministicConfig, engine: SheetEngine)
    /// Same API as SheetEngine but with reproducible clock/RNG
    public func evaluate(_ formula: String, at addr: CellAddr) throws -> Value
}
```

**Receipt integration**: when an AI agent evaluates a financial model, the `DeterministicConfig`
is stored in the material receipt. Any reviewer can replay the exact same evaluation with
the same seed and verify the result. No "but the date was different" excuses.

---

## 13. XLSX Import/Export

```swift
/// XLSX I/O using CoreXLSX (Swift, BSD license) for reading
/// and a custom ZIP+XML writer for writing (no external dependency needed).
public struct XLSXFormat: Sendable {
    /// Read a .xlsx file into a SheetEngine
    public static func load(from data: Data) throws -> SheetEngine

    /// Write a SheetEngine to a .xlsx file
    public static func save(_ engine: SheetEngine, to url: URL) throws

    /// What gets preserved:
    /// - All formulas (parsed and re-serialized)
    /// - Cell values (including cached formula results)
    /// - Number formats (DATE, PERCENTAGE, CURRENCY, CUSTOM)
    /// - Column widths, row heights
    /// - Sheet names and order
    /// - Named ranges
    /// - Merged cells
    /// What gets dropped:
    /// - Macros (VBA)
    /// - Charts, drawings
    /// - Custom XML extensions
}
```

**Format round-trip**: formulas are stored as the original `source: String` and re-parsed
on load. Cells with only cached values (no formula) are preserved as computed values.
Styles are read and reapplied (Font, Fill, Border, Alignment, Protection).

---

## 14. SheetEngine: The Core Class

```swift
/// The main entry point — owns all sheets, the dependency graph, and the changelog.
public final class SheetEngine: Sendable {
    public let workbookName: String

    // Sheets
    public var sheets: [String: Sheet]    // name -> sheet
    public var sheetOrder: [String]        // ordered names

    // Engine internals
    private var depGraph: DependencyGraph
    private var evaluator: Evaluator
    private var undoStack: UndoRedoStack
    private var cache: [CellAddr: CachedValue]
    private var dirtyCells: Set<CellAddr>
    private var volatileCells: Set<CellAddr>
    private var namedRanges: [String: RangeRef]

    // Deterministic mode
    private var deterministicConfig: DeterministicConfig?

    // SheetPort
    private var sheetPort: SheetPort?

    public init(workbookName: String = "Workbook")

    // --- Cell operations ---

    /// Get the value of a cell (evaluates if dirty)
    public func getValue(_ addr: CellAddr, sheet: String? = nil) throws -> Value

    /// Set a raw value (clears any formula)
    public func setValue(_ addr: CellAddr, _ value: Value, sheet: String? = nil) throws

    /// Set a formula (parses, registers in dep graph, queues recalc)
    public func setFormula(_ addr: CellAddr, _ source: String, sheet: String? = nil) throws

    /// Get the formula source for a cell
    public func getFormula(_ addr: CellAddr, sheet: String? = nil) -> Formula?

    /// Batch set values/formulas (for paste, import)
    public func setBatch(_ changes: [CellAddr: CellChange], sheet: String? = nil) throws

    // --- Recalculation ---

    /// Full recalculation of all dirty cells
    public func recalculate() throws

    /// Incremental recalc — only dirty cells and their dependents
    public func recalculateIncremental() throws

    /// Force recalc of a specific cell and its precedents
    public func recalculate(_ addr: CellAddr) throws

    // --- Undo/Redo ---

    public func undo() throws
    public func redo() throws
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // --- Sheet operations ---

    public func addSheet(name: String, at index: Int? = nil) throws
    public func removeSheet(name: String) throws
    public func renameSheet(old: String, new: String) throws
    public func moveSheet(name: String, to index: Int) throws

    // --- Named ranges ---

    public func defineName(_ name: String, _ ref: RangeRef) throws
    public func removeName(_ name: String) throws
    public func resolveName(_ name: String) -> RangeRef?

    // --- Range operations ---

    /// Get all values in a range as a flat array
    public func getRange(_ range: RangeRef) throws -> [Value]

    /// Get all values in a range as a typed column slice (Arrow pattern)
    public func getColumnSlice(_ range: RangeRef) throws -> ColumnSlice

    // --- I/O ---

    public func loadXLSX(from data: Data) throws
    public func saveXLSX() throws -> Data

    // --- SheetPort ---

    public func loadSheetPortManifest(_ manifest: SheetPortManifest) throws
    public func runSheetPortScenario(_ name: String) throws -> [String: Value]

    // --- Deterministic mode ---

    public func setDeterministicMode(_ config: DeterministicConfig)
    public func clearDeterministicMode()
}
```

---

## 15. Named Ranges

```swift
/// Named ranges (defined names in Excel)
public struct NamedRange: Sendable {
    public let name: String
    public let ref: RangeRef
    public let scope: String?   // nil = workbook scope; sheet name = sheet scope
    public let comment: String?
}
```

Named ranges resolve during parsing — `=Revenue - Expenses` where "Revenue" is a
named range expands to the underlying `RangeRef` before the dep graph is updated.

---

## 16. Error Handling

```swift
public enum FormulaError: Error, LocalizedError {
    case parse(syntax: String, position: Int, message: String)
    case referenceInvalid(addr: CellAddr)       // #REF!
    case nameInvalid(name: String)               // #NAME!
    case cycleDetected(path: [CellAddr])         // circular reference
    case divisionByZero                          // #DIV/0!
    case notAvailable                            // #N/A
    case typeMismatch(expected: String, got: Value)  // #VALUE!
    case arrayDimensionMismatch                  // #NUM! in array context
    case sheetNotFound(name: String)
    case cellNotFound(addr: CellAddr)
    case maxRecursionDepthExceeded(addr: CellAddr)
    case maxArraySizeExceeded(size: Int)

    public var errorValue: ValueError { /* map to ValueError enum */ }
}
```

---

## 17. File Structure

```
TesseraCore/
  FormulaEngine/
    FormulaEngine.swift           // SheetEngine + Sheet + CellAddr + CellRef + RangeRef
    FormulaAST.swift              // AST nodes + Formula struct
    Lexer.swift                   // Tokenizer
    Parser.swift                  // Pratt parser
    Evaluator.swift               // Recursive evaluator
    DependencyGraph.swift          // Bidirectional graph + cycle detection
    TypeSystem.swift              // Value enum + coercion
    ColumnSlice.swift             // Arrow-inspired columnar storage
    UndoRedoStack.swift           // Changelog + grouping
    XLSXFormat.swift              // CoreXLSX read + custom ZIP/XML write
    SheetPort.swift               // Typed manifest + scenario runner
    NamedRanges.swift             // NamedRange + registry
    Functions/
      FunctionRegistry.swift      // Signature metadata + dispatcher
      AggregateFunctions.swift    // SUM, AVERAGE, COUNT, MAX, MIN, etc.
      MathFunctions.swift         // ABS, ROUND, SUMIF, SUMIFS, etc.
      LogicFunctions.swift        // IF, IFS, AND, OR, NOT, IFERROR, SWITCH
      LookupFunctions.swift       // INDEX, MATCH, VLOOKUP, HLOOKUP, XLOOKUP, CHOOSE
      TextFunctions.swift         // CONCATENATE, LEN, LEFT, RIGHT, MID, TEXT, etc.
      DateFunctions.swift         // TODAY, NOW, DATE, YEAR, MONTH, DAY, DATEDIF, etc.
      TypeFunctions.swift         // ISBLANK, ISERROR, ISNA, ISNUMBER, N, NA, TYPE
      FinancialFunctions.swift    // NPV, PV, FV, PMT, RATE, IRR, XIRR, XNPV, etc.
      StatisticalFunctions.swift   // STDEV, VAR, MEDIAN, CORREL, FORECAST, etc.
      ArrayFunctions.swift        // TRANSPOSE, FREQUENCY (Phase 2: FILTER, UNIQUE, SORT)
    FormulaEngineTests/
      LexerTests.swift
      ParserTests.swift
      EvaluatorTests.swift
      DependencyGraphTests.swift
      FunctionTests.swift
      XLSXRoundTripTests.swift
```

---

## 18. Dependencies

| Dependency | License | Purpose | Acceptable? |
|---|---|---|---|
| CoreXLSX | BSD | XLSX read | YES — BSD, read-only during load |
| None (custom ZIP writer) | — | XLSX write | YES — pure Swift |
| None | — | Everything else | YES — pure Swift |

**No external formula engine**. Everything is custom Swift. The function implementations
are handwritten for each category — this is where most of the LoC lives (~3000 lines across
function files). The lexer + parser is ~600 lines. The dependency graph is ~200 lines.
The evaluator is ~300 lines. The rest is supporting infrastructure.

---

## 19. Implementation Order

### Phase 1: Core (this session)
1. `TypeSystem.swift` — Value enum, coercion rules
2. `CellAddr.swift` — CellRef, RangeRef
3. `Lexer.swift` — tokenizer
4. `Parser.swift` — Pratt parser
5. `FormulaAST.swift` — AST + Formula struct
6. `DependencyGraph.swift` — bidirectional graph, cycle detection, dirty propagation
7. `Evaluator.swift` — recursive evaluator with cache
8. `AggregateFunctions.swift` — SUM, AVERAGE, COUNT, COUNTA, MAX, MIN
9. `SheetEngine.swift` — top-level class, wiring everything
10. `ColumnSlice.swift` — Arrow-inspired range materialization
11. `UndoRedoStack.swift` — changelog with grouping
12. Basic `SheetGridView` wiring — formula bar, cell editing, recalc on edit
13. Tests: 40+ cases covering lexer, parser, evaluator, dep graph, functions

### Phase 2: Functions + XLSX (follow-up)
14. Remaining Phase 1 functions (Logic, Lookup, Text, Math, Date, Type)
15. `XLSXFormat.swift` — CoreXLSX read + custom write
16. Named ranges
17. NamedRange integration in parser
18. Tests: full function suite + XLSX round-trip

### Phase 3: Financial + SheetPort (corporate)
19. Financial functions (NPV, IRR, XIRR, XNPV, PMT, etc.)
20. Statistical functions
21. `SheetPort.swift` — manifest YAML + scenario runner
22. `DeterministicConfig` + deterministic evaluation mode
23. Named ranges in SheetPort
24. Tests: financial scenarios, SheetPort manifest validation

### Phase 4: Advanced
25. Array functions (TRANSPOSE, FILTER, UNIQUE, SORT, SORTBY, SEQUENCE, LAMBDA)
26. Dynamic array spill semantics
27. Engineering functions
28. Named ranges with SheetPort integration
