import Foundation

// MARK: - PreservedParts

/// Byte-for-byte preservation of package parts a Tessera import/export
/// round trip cannot yet represent natively - VBA project binaries
/// (2.13 macros), custom XML parts (2.15 forms' data-binding source),
/// and similar opaque package members. Each part is kept EXACTLY as
/// read, keyed by its package-relative path (e.g.
/// `"word/vbaProject.bin"`, `"customXml/item1.xml"`), and re-emitted
/// verbatim on export - never re-serialized, re-interpreted, or
/// partially modified.
///
/// One shared mechanism for both 2.13 and 2.15 (per the design
/// contract's own "one `PreservedParts` mechanism, not two"
/// instruction), rather than two parallel byte-bag types: 2.13's
/// `MacroCompatLayer` reads/writes `"word/vbaProject.bin"` (and its
/// `xl:`/`ppt:` siblings) through this type without owning storage
/// itself; 2.15's `FormController`/`ContentControl` do the same for
/// `customXml/itemN.xml` data-binding sources. Both tracks build
/// against this exact API from the start of Wave P2-D - see
/// `docs/.scratch/p2-wave-d-report.md` (once written) for the
/// sequencing note this pre-landing resolves.
public struct PreservedParts: Codable, Sendable, Hashable {

    /// Package-relative path -> raw bytes, exactly as read. No
    /// normalization of the path string (case, leading slash, etc.) -
    /// callers use whatever path the source package itself used, so a
    /// round trip re-emits the identical key.
    public var parts: [String: Data]

    public init(parts: [String: Data] = [:]) {
        self.parts = parts
    }

    public var isEmpty: Bool { parts.isEmpty }

    public subscript(path: String) -> Data? {
        get { parts[path] }
        set { parts[path] = newValue }
    }
}
