//===----------------------------------------------------------------------===//
//  TokenArray.swift
//  Tessera Formula Engine
//
//  A flat, RPN (postfix) token stream compiled from a FormulaAST, with
//  cell/range references encoded RELATIVE TO THE FORMULA'S OWN ANCHOR
//  CELL rather than as absolute addresses. That's the property that
//  makes two formulas "the same shape": `=A1+B1` at B2 and `=A2+B2` at
//  B3 both compile to the identical token stream (each says "the cell
//  one column left of me" and "the cell directly above me"), so ONE
//  compiled TokenArray can be shared across every cell a fill-down (or
//  paste, or AutoFill) produced from the same original formula -
//  matching the capability matrix's "Formula engine: TokenArray IR +
//  shared formula groups... covered (RPN)" framing (studio-expansion-
//  plan.md capability #17): LibreOffice's own internal representation
//  is RPN too.
//
//  Scope note (0.2b, deliberately re-scoped smaller than the plan's
//  original single "RecalcScheduler + TokenArray IR + shared formula
//  groups" bundle - see the 0.2a RecalcState commit's message for why
//  that got split): this file is a genuinely working, tested PEER of
//  FormulaAST - compiler, RPN evaluator, and a shared-formula interning
//  registry - verified to produce identical results to the existing
//  AST-walking Evaluator across a battery of real formulas. It is NOT
//  wired into SheetEngine's live cell-evaluation path in this pass:
//  swapping the production evaluation path is separate, additional
//  risk (correctness-critical, hot-path code) beyond what "add a new,
//  optional capability" warrants in one step. FormulaAST stays the
//  authoring/evaluation surface SheetEngine actually uses; TokenArray
//  is ready infrastructure for a later increment to adopt.
//
//  Not every formula compiles. TokenArrayCompiler.compile(_:anchor:)
//  returns nil for constructs with no flat-RPN-friendly representation
//  in this pass - LET/LAMBDA (name binding introduces a lexical scope
//  a flat stack machine doesn't have without real extra work) and
//  array literals (rare in practice; supporting them cleanly needs a
//  richer token shape than a single scalar-producing RPN stream). A
//  formula that doesn't compile simply has no TokenArray and isn't
//  eligible for shared-group interning - it keeps working exactly as
//  before via the AST path, which every formula already goes through
//  regardless.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - RelativeAxis

/// One axis (column or row) of a compiled reference: either an offset
/// from the formula's own anchor cell, or a fixed absolute position
/// (`$`-marked in the original formula) that doesn't move regardless
/// of which cell the compiled token stream is evaluated against.
public enum RelativeAxis: Sendable, Hashable {
    case relative(offset: Int)
    case absolute(Int)

    /// Resolve against an anchor's own coordinate on this axis.
    /// Returns nil if the resolved position would be negative (a
    /// relative offset pointing off the top/left edge of the sheet -
    /// `CellAddr` itself refuses to represent that).
    func resolve(anchor: Int) -> Int? {
        switch self {
        case .relative(let offset):
            let resolved = anchor + offset
            return resolved >= 0 ? resolved : nil
        case .absolute(let value):
            return value >= 0 ? value : nil
        }
    }
}

// MARK: - RelativeCellRef

/// A cell reference compiled relative to the formula's anchor. `sheet`
/// is carried verbatim from the source `CellRef` (nil means "the
/// formula's own sheet, whatever that is when evaluated" - already
/// anchor-relative in spirit, so it needs no offset of its own).
public struct RelativeCellRef: Sendable, Hashable {
    public let sheet: String?
    public let col: RelativeAxis
    public let row: RelativeAxis
}

// MARK: - RelativeRangeRef

/// A range reference compiled relative to the formula's anchor. Both
/// corners are always `.relative` - `RangeRef` (the AST's own range
/// type) carries no per-corner absolute flag to compile from, matching
/// its existing, pre-existing limitation (not something introduced
/// here).
public struct RelativeRangeRef: Sendable, Hashable {
    public let sheet: String?
    public let topLeftColOffset: Int
    public let topLeftRowOffset: Int
    public let bottomRightColOffset: Int
    public let bottomRightRowOffset: Int
}

// MARK: - RPNToken

/// One element of a compiled, postfix (RPN) token stream. Operands
/// (literals, refs) push a value; operators/functions pop their
/// operands and push a result - `TokenArrayEvaluator` is a plain stack
/// machine over this stream.
public enum RPNToken: Sendable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(ValueError)
    case null
    case cellRef(RelativeCellRef)
    case rangeRef(RelativeRangeRef)
    case namedRange(String)
    case binaryOp(BinaryOp)
    case unaryOp(UnaryOp)
    /// Pops `argCount` values (in argument order) and pushes the
    /// function's result.
    case function(name: String, argCount: Int)
}

/// A compiled formula: its token stream plus a stable, content-based
/// identity used for interning (see `SharedFormulaGroups`). Two
/// `TokenArray`s with the same `tokens` are the same shape by
/// definition - `groupKey` is exactly `tokens` today; kept as its own
/// property so a future richer key (e.g. folding in a normalized
/// number-format hint) doesn't require touching every call site.
public struct TokenArray: Sendable, Hashable {
    public let tokens: [RPNToken]
    public var groupKey: [RPNToken] { tokens }
}

// MARK: - TokenArrayCompiler

public enum TokenArrayCompiler {
    /// Compile `ast` into a flat RPN token stream relative to `anchor`.
    /// Returns nil for a construct this compiler doesn't support (see
    /// the file header) - the caller falls back to AST-only evaluation
    /// for that formula, exactly as it already does today.
    public static func compile(_ ast: FormulaAST, anchor: CellAddr) -> TokenArray? {
        var tokens: [RPNToken] = []
        guard emit(ast, anchor: anchor, into: &tokens) else { return nil }
        return TokenArray(tokens: tokens)
    }

    private static func emit(_ ast: FormulaAST, anchor: CellAddr, into tokens: inout [RPNToken]) -> Bool {
        switch ast {
        case .number(let n):
            tokens.append(.number(n))
            return true
        case .string(let s):
            tokens.append(.string(s))
            return true
        case .bool(let b):
            tokens.append(.bool(b))
            return true
        case .error(let e):
            tokens.append(.error(e))
            return true
        case .null:
            tokens.append(.null)
            return true
        case .cell(let ref):
            // The named-range marker (see Evaluator.recursiveEvaluate's
            // .cell case): a negative-address CellRef whose `sheet`
            // carries "$name". Not a real cell - emit a named-range
            // token instead of relative-offsetting a sentinel address.
            if ref.addr.col < 0 && ref.addr.row < 0, let marker = ref.sheet {
                tokens.append(.namedRange(String(marker.dropFirst())))
                return true
            }
            tokens.append(.cellRef(relativize(ref, anchor: anchor)))
            return true
        case .range(let ref):
            tokens.append(.rangeRef(relativize(ref, anchor: anchor)))
            return true
        case .binary(let op, let left, let right):
            guard emit(left, anchor: anchor, into: &tokens) else { return false }
            guard emit(right, anchor: anchor, into: &tokens) else { return false }
            tokens.append(.binaryOp(op))
            return true
        case .unary(let op, let operand):
            guard emit(operand, anchor: anchor, into: &tokens) else { return false }
            tokens.append(.unaryOp(op))
            return true
        case .function(let name, let args):
            let upper = name.uppercased()
            // LET/LAMBDA bind names into a lexical scope a flat stack
            // machine doesn't model in this pass - see the file header.
            guard upper != "LET", upper != "LAMBDA" else { return false }
            for arg in args {
                guard emit(arg, anchor: anchor, into: &tokens) else { return false }
            }
            tokens.append(.function(name: name, argCount: args.count))
            return true
        case .arrayLiteral:
            // See the file header: not supported in this pass.
            return false
        }
    }

    private static func relativize(_ ref: CellRef, anchor: CellAddr) -> RelativeCellRef {
        RelativeCellRef(
            sheet: ref.sheet,
            col: ref.colAbsolute ? .absolute(ref.addr.col) : .relative(offset: ref.addr.col - anchor.col),
            row: ref.rowAbsolute ? .absolute(ref.addr.row) : .relative(offset: ref.addr.row - anchor.row)
        )
    }

    private static func relativize(_ ref: RangeRef, anchor: CellAddr) -> RelativeRangeRef {
        RelativeRangeRef(
            sheet: ref.sheet,
            topLeftColOffset: ref.topLeft.col - anchor.col,
            topLeftRowOffset: ref.topLeft.row - anchor.row,
            bottomRightColOffset: ref.bottomRight.col - anchor.col,
            bottomRightRowOffset: ref.bottomRight.row - anchor.row
        )
    }
}

// MARK: - TokenArrayEvaluator

/// Evaluates a compiled `TokenArray` against a specific anchor cell -
/// a plain stack machine, the RPN counterpart of `Evaluator`'s
/// recursive AST walk. Given the same anchor/sheet/engine, produces
/// the same `Value` `Evaluator.evaluate` would for the AST this
/// TokenArray was compiled from (verified in TokenArrayTests.swift
/// against a battery of real formulas, not just asserted).
public enum TokenArrayEvaluator {
    public enum EvalError: Error {
        /// A relative or absolute reference resolved to a negative
        /// column/row - off the top/left edge of the sheet for this
        /// particular anchor. Not a malformed TokenArray; the same
        /// compiled stream is valid for other anchors.
        case referenceOutOfBounds
        case malformedStream
    }

    public static func evaluate(
        _ array: TokenArray,
        anchor: CellAddr,
        sheet: String,
        functions: FunctionRegistry,
        engine: SheetEngineCore
    ) throws -> Value {
        var stack: [Value] = []
        stack.reserveCapacity(array.tokens.count)

        for token in array.tokens {
            switch token {
            case .number(let n): stack.append(.number(n))
            case .string(let s): stack.append(.string(s))
            case .bool(let b): stack.append(.bool(b))
            case .error(let e): stack.append(.error(e))
            case .null: stack.append(.null)

            case .cellRef(let ref):
                guard let col = ref.col.resolve(anchor: anchor.col),
                      let row = ref.row.resolve(anchor: anchor.row) else {
                    stack.append(.error(.referenceInvalid))
                    continue
                }
                let addr = CellAddr(col: col, row: row)
                stack.append(try engine.getCellValue(addr, sheet: ref.sheet ?? sheet))

            case .rangeRef(let ref):
                guard let topLeftCol = RelativeAxis.relative(offset: ref.topLeftColOffset).resolve(anchor: anchor.col),
                      let topLeftRow = RelativeAxis.relative(offset: ref.topLeftRowOffset).resolve(anchor: anchor.row),
                      let bottomRightCol = RelativeAxis.relative(offset: ref.bottomRightColOffset).resolve(anchor: anchor.col),
                      let bottomRightRow = RelativeAxis.relative(offset: ref.bottomRightRowOffset).resolve(anchor: anchor.row) else {
                    stack.append(.error(.referenceInvalid))
                    continue
                }
                let range = RangeRef(
                    sheet: ref.sheet,
                    topLeft: CellAddr(col: topLeftCol, row: topLeftRow),
                    bottomRight: CellAddr(col: bottomRightCol, row: bottomRightRow)
                )
                let values = try engine.getRangeValues(range, fallbackSheet: sheet)
                stack.append(.array(rows: range.height, cols: range.width, flat: values))

            case .namedRange(let name):
                stack.append(try engine.resolveNamedRange(name, at: anchor, fallbackSheet: sheet))

            case .binaryOp(let op):
                guard let right = stack.popLast(), let left = stack.popLast() else {
                    throw EvalError.malformedStream
                }
                stack.append(BinaryEvaluator.apply(op, left, right))

            case .unaryOp(let op):
                guard let operand = stack.popLast() else { throw EvalError.malformedStream }
                stack.append(UnaryEvaluator.apply(op, operand))

            case .function(let name, let argCount):
                guard stack.count >= argCount else { throw EvalError.malformedStream }
                let args = Array(stack.suffix(argCount))
                stack.removeLast(argCount)
                guard let fn = functions.lookup(name) else {
                    stack.append(.error(.nameInvalid))
                    continue
                }
                if let arity = fn.arity, !arity.contains(args.count) {
                    stack.append(.error(.notAvailable))
                    continue
                }
                stack.append(try fn.call(args))
            }
        }

        guard stack.count == 1, let result = stack.last else {
            throw EvalError.malformedStream
        }
        return result
    }
}

// MARK: - SharedFormulaGroups

/// Interns compiled `TokenArray`s by shape, so every cell a fill-down
/// (or paste, or AutoFill) produced from one original formula can point
/// at ONE shared compiled representation instead of each allocating its
/// own - the actual memory/perf win "shared formula groups" names.
/// `TokenArray.groupKey` (== `tokens`) is the identity: two arrays with
/// equal tokens ARE the same group, by construction (relative offsets
/// make `=A1+B1` at B2 and `=A2+B2` at B3 compile to the identical
/// stream - see the file header).
///
/// Not wired into `DependencyGraph`/`SheetEngine` in this pass - see
/// the file header's scope note. A cell that wants to participate
/// looks up or creates its group ID here; nothing calls this yet.
public final class SharedFormulaGroups: @unchecked Sendable {
    private var idByKey: [[RPNToken]: UUID] = [:]
    private var arrayByID: [UUID: TokenArray] = [:]
    /// How many cells currently reference each group - lets a caller
    /// evict a group once its last member is deleted/edited away,
    /// without keeping every historical shape alive forever.
    private var refCountByID: [UUID: Int] = [:]
    private let lock = NSLock()

    public init() {}

    /// Look up or create the group for `array`, incrementing its
    /// reference count. Returns the SAME id for any `array` with an
    /// equal `groupKey`, regardless of which anchor compiled it.
    @discardableResult
    public func intern(_ array: TokenArray) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let key = array.groupKey
        if let existing = idByKey[key] {
            refCountByID[existing, default: 0] += 1
            return existing
        }
        let id = UUID()
        idByKey[key] = id
        arrayByID[id] = array
        refCountByID[id] = 1
        return id
    }

    /// The compiled array for a group, or nil if the id is unknown
    /// (never interned, or already fully released).
    public func tokenArray(for id: UUID) -> TokenArray? {
        lock.lock()
        defer { lock.unlock() }
        return arrayByID[id]
    }

    /// How many cells currently reference this group.
    public func referenceCount(for id: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return refCountByID[id] ?? 0
    }

    /// Release one reference to `id` (a member cell was deleted or its
    /// formula changed to something else). The group is forgotten once
    /// its count reaches zero, so an edited-away shape doesn't pin
    /// memory forever.
    public func release(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = refCountByID[id] else { return }
        if count <= 1 {
            refCountByID.removeValue(forKey: id)
            if let array = arrayByID.removeValue(forKey: id) {
                idByKey.removeValue(forKey: array.groupKey)
            }
        } else {
            refCountByID[id] = count - 1
        }
    }

    /// How many distinct shapes are currently interned.
    public var groupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrayByID.count
    }
}
