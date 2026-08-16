import Foundation

//===----------------------------------------------------------------------===//
//  ContentControl.swift
//  Tessera Studio
//
//  Forms (P2-D item 2.15, sota-enterprise-report.md's "2.15 Forms -
//  content controls as Block attributes, not a Forms material"). Adopts
//  DOCX's `w:sdt` content-control model: richText/plainText/comboBox/
//  dropDownList/datePicker/checkBox/picture, with `w:sdtPr` carrying
//  tag/title/lock and `w:dataBinding[@w:xpath]` binding control content
//  to a custom-XML package part. A form is a document with controls, so
//  a ``ContentControl`` is an ATTRIBUTE existing block cases can carry
//  (see `Block/contentControl` in `Block.swift`), never a new
//  `BlockType` case - keeps the 25-case budget intact (studio-expansion-
//  plan.md decision 3).
//
//  Peer of `Block` (own file, same convention as `Shape`/`ChartSpec`/
//  `MediaBlock`/`FrameProperties`): the value type's own `Codable`
//  conformance is the single source of truth for the wire shape;
//  `Block/contentControl` stores it as a nested JSON object under
//  `attributes["contentControl"]` and never re-derives it.
//
//  **The `value` field (judgment call, recorded here and in this wave's
//  findings file, p2-d-findings-2.md).** The design contract's own field
//  list for this type - "kind, tag, title, placeholder, listItems,
//  locks, binding" - does not literally name a value-storage field, but
//  its own `FormController` contract (see that file's header) requires
//  one: "checkBox/dropDownList writes a value into the ContentControl's
//  OWN state" - somewhere has to hold that state. `value: String?` is
//  that somewhere. It is read/written ONLY for kinds whose resolved
//  value is NOT the host block's own `content` (see
//  `FormController.resolvedValue(for:hostBlock:)` for the exact
//  kind-by-kind split): `.comboBox`/`.dropDownList`/`.datePicker`/
//  `.checkBox`/`.picture`. For `.plainText`/`.richText`, `value` stays
//  `nil` forever - the control's whole point is that the HOST BLOCK'S
//  `content` (ordinary `InlineRun`s, exactly like every other prose
//  block) carries the fill-in text, matching `FieldSpec`'s own "cached
//  resolved text lives in `content`, structural state lives in the
//  attribute" split. A single `String?` (not a typed enum keyed to
//  `kind`) keeps the wire shape uniform across all seven kinds and
//  matches how the `doc_form_fill` tool's own argument arrives (a plain
//  string - see `Tools/DocTools.swift`); kind-specific validation
//  (checkbox "true"/"false", drop-down membership in `listItems`) is
//  `FormController.fill`'s job, not this type's.
//
//  **Data binding.** `binding` is an XPath expression (e.g.
//  `/root/field[@id='x']`) resolved against a custom-XML package part
//  preserved verbatim in the owning `Doc`'s `preservedParts`
//  (`DocumentProcessing/PreservedParts.swift` - the SAME mechanism
//  2.13's `MacroCompatLayer` uses for `word/vbaProject.bin`, per that
//  type's own "one PreservedParts mechanism, not two" doc comment).
//  This type carries only the XPath string; the resolver
//  (`FormBindingResolver.resolve(_:in:)`) and the exact supported
//  XPath SUBSET (deliberately not full XPath 1.0) live in
//  `FormController.swift` - see that file's header for the full
//  documented grammar and the "why minimal" reasoning.
//===----------------------------------------------------------------------===//

// MARK: - ContentControlKind

/// The seven `w:sdt` content-control kinds this codebase models -
/// Word's own set (richText/plainText/comboBox/dropDownList/
/// datePicker/checkBox/picture; `repeatingSection` is explicitly out of
/// scope for P2-D per the design contract's own field list, which
/// enumerates exactly these seven).
public enum ContentControlKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Multi-paragraph formatted text. At this layer (no rich-text
    /// model exists below `InlineRun`), `FormController.fill` writes
    /// plain `InlineRun` text - see that file's header for the
    /// documented P2-D simplification.
    case richText
    /// Single-paragraph plain text.
    case plainText
    /// A list the user can also type a custom value into. Uses
    /// ``ContentControl/listItems`` for its suggestion set, but
    /// `FormController.fill` does not require membership (see that
    /// file's header) - the OOXML-documented distinction from
    /// ``dropDownList``.
    case comboBox
    /// A list restricted to exactly ``ContentControl/listItems`` -
    /// `FormController.fill` rejects (no-ops) a value outside the list.
    case dropDownList
    /// A calendar-picked date. Stored as the caller's own date-text
    /// convention (no parsing/formatting is imposed here - see
    /// `FormController.swift`'s header for the documented scope limit).
    case datePicker
    /// A boolean toggle. `FormController.fill` accepts exactly
    /// `"true"`/`"false"` (case-sensitive) and rejects anything else.
    case checkBox
    /// A single image reference. `value` holds an opaque
    /// path/URL/attachment-id string, the same string-reference
    /// convention `MediaBlock.sourceURL`/`.posterImageURL` already use
    /// (no `URL` stored directly anywhere in this codebase's persisted
    /// models).
    case picture
}

// MARK: - ContentControlLocks

/// `w:sdtPr/w:lock`'s two independent flags. Both default `false`
/// (unlocked) - the common case for a freshly-created control.
public struct ContentControlLocks: Codable, Sendable, Hashable {
    /// Content editing is disabled (`w:lock w:val="sdtContentLocked"` or
    /// `"contentLocked"`). `FormController.fill` treats this as a hard
    /// gate: a content-locked control's `fill` call is always a no-op,
    /// regardless of kind - see that file's header.
    public var contentLocked: Bool
    /// The control itself cannot be deleted (`w:lock w:val=
    /// "sdtLocked"` or `"unlocked"`/`"contentLocked"`'s sibling flag).
    /// Not enforced anywhere in this wave's scope (no control-deletion
    /// API exists yet); carried so a round-tripped document does not
    /// silently drop the flag on export.
    public var deletionLocked: Bool

    public init(contentLocked: Bool = false, deletionLocked: Bool = false) {
        self.contentLocked = contentLocked
        self.deletionLocked = deletionLocked
    }
}

// MARK: - ContentControl

/// One `w:sdt` content control's persistent state, stored via
/// `Block/contentControl` - see this file's header for the full design
/// and the `value` field's judgment-call rationale.
public struct ContentControl: Codable, Sendable, Hashable {
    public var kind: ContentControlKind
    /// The control's programmatic identifier (`w:tag/@w:val`) - what an
    /// agent or template refers to it by (`doc_form_fields_list`'s
    /// primary key, `FormController.formData(in:)`'s dictionary key).
    /// Not required to be unique by this type (a real DOCX does not
    /// enforce uniqueness either); callers that need uniqueness enforce
    /// it themselves.
    public var tag: String
    /// Human-readable label (`w:title/@w:val`), shown in a properties
    /// UI. Distinct from `placeholder` - `title` describes the control,
    /// `placeholder` is shown INSIDE an empty control.
    public var title: String?
    /// Placeholder text shown when the control is empty
    /// (`w:sdtContent`'s own placeholder run in real DOCX; modeled here
    /// as a plain string since this type carries no run-level styling).
    public var placeholder: String?
    /// The fixed choice set for ``ContentControlKind/comboBox`` and
    /// ``ContentControlKind/dropDownList`` (`w:listItem` entries).
    /// Empty for every other kind - not enforced by this type, but
    /// `FormController.fill` never reads it for a non-list kind.
    public var listItems: [String]
    public var locks: ContentControlLocks
    /// An XPath expression (`w:dataBinding/@w:xpath`) into a custom-XML
    /// package part, or `nil` when the control is not data-bound (the
    /// common case). See this file's header "Data binding" section.
    public var binding: String?
    /// The control's own resolved value for the kinds that do not write
    /// into the host block's `content` - see this file's header's
    /// `value` section for the exact kind split and the judgment-call
    /// rationale for this field's existence.
    public var value: String?

    public init(
        kind: ContentControlKind,
        tag: String,
        title: String? = nil,
        placeholder: String? = nil,
        listItems: [String] = [],
        locks: ContentControlLocks = ContentControlLocks(),
        binding: String? = nil,
        value: String? = nil
    ) {
        self.kind = kind
        self.tag = tag
        self.title = title
        self.placeholder = placeholder
        self.listItems = listItems
        self.locks = locks
        self.binding = binding
        self.value = value
    }
}
