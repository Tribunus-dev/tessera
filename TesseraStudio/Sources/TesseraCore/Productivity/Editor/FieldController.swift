import Foundation

//===----------------------------------------------------------------------===//
//  FieldController.swift
//  Tessera Studio
//
//  Field refresh for Writer (P1 item 1.1,
//  studio-expansion-design-refinement-2026-08-14.md's Writer cluster).
//  A `.field` block's `attributes["field"]` holds the persistent
//  `FieldSpec` (kind + dirty flag - see `Block.field`); its `content`
//  holds the CACHED RESOLVED text as ordinary `InlineRun`s, exactly
//  like every other leaf block, so `plainText()`/`DocumentExporter`/
//  agent context see real text with no field-aware special-casing in
//  those files.
//
//  `FieldSpec`/`FieldKind` live in this file rather than a peer
//  "Field.swift" (the shape `Shape`/`FrameProperties`/`ChartSpec` each
//  get their own file next to `Block.swift`'s bridge) because this
//  item's file list does not include one - `RevisionController.swift`
//  is the precedent for a controller file owning its own small support
//  types (`RevisionDirection`/`RevisionBlockOutcome`/`RevisionResolution`
//  all live there, not in a separate file either).
//
//  Pure and stateless, matching RevisionController/TransformController/
//  QueryEngine in this same wave family: `refresh` takes a `Block` and
//  a `DocumentAST` and returns a new `Block`, never touching `DocStore`.
//  A future `DocStore` integration is the one place that both calls
//  this and appends the `doc_fields_refreshed` receipt - only when the
//  returned `Block` actually differs from the one passed in, which
//  `refresh`'s idempotence under a fixed clock (see below) is what
//  makes that a plain `!=` check rather than something this file needs
//  to compute itself.
//
//  **Layout-sensitive fields stay dirty.** `.page`/`.numPages`/`.ref`
//  need a paginator to resolve (which page a block LANDS on isn't
//  knowable from the AST alone) - no paginator context exists until
//  P2. `refresh` leaves these three kinds' `content` AND `dirty`
//  completely untouched: not "cleared", not "recomputed to the same
//  last-known text" - the returned `Block` IS the input `Block`. This
//  is the documented P1 limitation the design contract calls for
//  ("layout fields stay dirty with last-known text until a paginator
//  context exists"), not a bug to fix here.
//
//  **Everything else always resolves.** `.date`/`.time`/`.sequence`/
//  `.author`/`.title`/`.docProperty` need no page layout, so `refresh`
//  always recomputes their text and clears `dirty` - even when it was
//  already clear. `.date`/`.time` read the injected `clock`, which is
//  what makes "idempotent under a FIXED clock" the real test:
//  `refresh(refresh(b, clock: c), clock: c) == refresh(b, clock: c)`
//  holds exactly when `c` returns the same `Date` both times. Under a
//  REAL moving clock this is deliberately NOT idempotent - a date
//  field has to track today.
//
//  **`.sequence(name:)` numbers from the AST, not a stored counter.**
//  Its resolved text is this field's 1-based ordinal among every
//  `.sequence(name:)` block sharing `name`, counted in
//  `ast.depthFirstOrder()` - the LO/Word SEQ field's own rule. No
//  separate counter to keep in sync with the tree.
//
//  **`.author`/`.title`/`.docProperty(name:)` resolve to `""` at P1.**
//  `DocumentMeta` (this file's only document-level input, reached via
//  `ast`) carries page layout and section identities, not document
//  properties - wiring these to `Doc.title`/a real author/a custom
//  doc-property store needs a `Doc`, not just a `DocumentAST`, threaded
//  through, which is a later item's scope, not this one's. Empty is
//  the same rendering LO/Word give an unset property, so this is a
//  legitimate resolution, not a placeholder error value.
//===----------------------------------------------------------------------===//

// MARK: - FieldKind

/// What a `.field` block computes. Associated values carry the one
/// piece of data each kind needs to resolve (a target, a sequence
/// name, a property name); the plain cases need none.
///
/// NOTE: `mergeField` (P2 item 2.4) is a later case on this SAME enum,
/// not a new `BlockType`. Adding it needs no migration here: Swift's
/// Codable synthesis for an enum with associated values decodes each
/// case by name, so every `FieldSpec` already on disk (encoding one of
/// THESE cases) keeps decoding exactly as it does today once a new
/// case exists alongside them.
public enum FieldKind: Codable, Sendable, Hashable {
    /// Current page number. Layout-sensitive - see file header.
    case page
    /// Total page count. Layout-sensitive - see file header.
    case numPages
    /// The page number of `targetBlockID`'s enclosing page (a "see
    /// page N" cross-reference). Layout-sensitive - see file header.
    case ref(targetBlockID: UUID)
    /// Auto-numbered caption counter (Word's SEQ field), scoped by
    /// `name` (e.g. "Figure", "Table"). Resolved from document order,
    /// not a stored counter - see `FieldController.sequenceNumber`.
    case sequence(name: String)
    case date
    case time
    case author
    case title
    /// A named custom document property (Word's DOCPROPERTY field).
    case docProperty(name: String)
}

// MARK: - FieldSpec

/// A `.field` block's persistent state, stored via
/// `attributes["field"]` - see `Block.field`. The RESOLVED text is NOT
/// here; it lives in the block's own `content` (see file header).
public struct FieldSpec: Codable, Sendable, Hashable {
    public var kind: FieldKind
    /// `true` when `content` may not reflect `kind`'s true current
    /// value - set on creation (nothing resolved yet) and left `true`
    /// forever for a layout-sensitive `kind` at P1 (see file header).
    /// `FieldController.refresh` is the only place that clears it.
    public var dirty: Bool

    public init(kind: FieldKind, dirty: Bool = true) {
        self.kind = kind
        self.dirty = dirty
    }
}

// MARK: - FieldController

/// Pure field resolution over `Block`/`DocumentAST` - peer of
/// `RevisionController`/`TransformController`/`QueryEngine`: a plain
/// namespace of static functions, no state, no `DocStore` dependency.
/// See the file header for the full design.
public enum FieldController {

    /// Re-resolve `block`'s field. A no-op (returns `block` unchanged)
    /// when `block` isn't a `.field` block or carries no `FieldSpec`
    /// yet. See the file header for the layout-sensitive/insensitive
    /// split and the idempotence guarantee under a fixed `clock`.
    public static func refresh(_ block: Block, in ast: DocumentAST, clock: () -> Date = { Date() }) -> Block {
        guard block.type == .field, var spec = block.field else { return block }
        guard let text = resolvedText(for: spec.kind, blockID: block.id, in: ast, now: clock()) else {
            // Layout-sensitive: last-known content and dirty flag are
            // left exactly as they were - see file header.
            return block
        }
        var result = block
        result.content = [InlineRun(text: text)]
        spec.dirty = false
        result.field = spec
        return result
    }

    /// The freshly-resolved text for a layout-INSENSITIVE `kind`, or
    /// `nil` for a layout-SENSITIVE one (`.page`/`.numPages`/`.ref`) -
    /// `nil` is `refresh`'s signal to leave `content`/`dirty` untouched.
    private static func resolvedText(for kind: FieldKind, blockID: UUID, in ast: DocumentAST, now: Date) -> String? {
        switch kind {
        case .page, .numPages, .ref:
            return nil
        case .date:
            return format(now, pattern: "yyyy-MM-dd")
        case .time:
            return format(now, pattern: "HH:mm:ss")
        case .sequence(let name):
            return String(sequenceNumber(name: name, blockID: blockID, in: ast))
        case .author, .title, .docProperty:
            return ""
        }
    }

    /// `blockID`'s 1-based ordinal among every `.sequence(name:)`
    /// field sharing `name`, in document order - see file header.
    /// `blockID` absent from `ast` (a detached block being resolved
    /// before insertion) counts as the next one after every match found.
    private static func sequenceNumber(name: String, blockID: UUID, in ast: DocumentAST) -> Int {
        var count = 0
        for id in ast.depthFirstOrder() {
            guard let candidate = ast.blocks[id], candidate.type == .field,
                  let kind = candidate.field?.kind,
                  case .sequence(let candidateName) = kind,
                  candidateName == name
            else { continue }
            count += 1
            if id == blockID { return count }
        }
        return count + 1
    }

    /// A fresh, fixed-locale/fixed-timezone `DateFormatter` per call -
    /// matches `ChatProgressFeed.timestampLabel`'s own convention
    /// (this codebase doesn't cache `DateFormatter` instances as
    /// static state).
    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
