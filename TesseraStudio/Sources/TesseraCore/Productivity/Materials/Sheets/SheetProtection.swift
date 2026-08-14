//===----------------------------------------------------------------------===//
//  SheetProtection.swift
//  Tessera Studio
//
//  Sheet-level "lock against accidental edits" - the spreadsheet-world
//  convention, not a real security boundary. The file on disk is not
//  encrypted by this; a locked sheet is a guard against a stray
//  keystroke or an over-eager agent, not against a determined reader.
//===----------------------------------------------------------------------===//

import Foundation

/// Whether a sheet accepts cell/format mutations right now.
///
/// `nil` on `Sheet.protection` (the default for every sheet written
/// before this existed, and for every unprotected sheet since) means
/// unprotected - callers should treat a missing value the same as
/// `SheetProtection(isLocked: false)`, not as "unknown."
public struct SheetProtection: Codable, Sendable, Hashable {
    public var isLocked: Bool
    /// Shown to the user (and to the agent, in the tool-call error) when
    /// a locked edit is refused. Optional: "why" is often obvious from
    /// context ("this is the published version").
    public var reason: String?

    public static let unprotected = SheetProtection(isLocked: false)

    public init(isLocked: Bool = false, reason: String? = nil) {
        self.isLocked = isLocked
        self.reason = reason
    }
}

extension Sheet {
    /// `protection ?? .unprotected`, so every call site can treat the
    /// optional field as a non-optional value instead of re-deriving
    /// the "nil means unprotected" rule at each use.
    public var effectiveProtection: SheetProtection {
        protection ?? .unprotected
    }
}
