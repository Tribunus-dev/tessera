//===----------------------------------------------------------------------===//
//  UndoRedoStack.swift
//  Tessera Formula Engine
//
//  Transactional changelog with action grouping for undo/redo.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Edit

/// A single, undoable edit to the spreadsheet.
public struct Edit: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let groupID: UUID?   // nil = individual edit; same groupID = one undo step

    public enum Change: Sendable {
        case setValue(addr: CellAddr, sheet: String?, old: Value, new: Value)
        case setFormula(addr: CellAddr, sheet: String?, old: Formula?, new: Formula?)
        case insertRow(at: Int, sheet: String?, count: Int)
        case insertCol(at: Int, sheet: String?, count: Int)
        case deleteRow(at: Int, sheet: String?, count: Int)
        case deleteCol(at: Int, sheet: String?, count: Int)
        case moveRow(from: Int, to: Int, sheet: String?)
        case moveCol(from: Int, to: Int, sheet: String?)
        case clearSheet(name: String)
        case renameSheet(old: String, new: String)
        case insertSheet(name: String, at: Int)
        case deleteSheet(name: String)
        case defineName(name: String, old: RangeRef?, new: RangeRef?)
    }

    public let change: Change

    public init(groupID: UUID? = nil, change: Change) {
        self.id = UUID()
        self.timestamp = Date()
        self.groupID = groupID
        self.change = change
    }

    /// The compensating edit that undoes this one.
    public var inverse: Edit {
        switch change {
        case .setValue(let addr, let sheet, let old, let new):
            return Edit(groupID: groupID, change: .setValue(addr: addr, sheet: sheet, old: new, new: old))
        case .setFormula(let addr, let sheet, let old, let new):
            return Edit(groupID: groupID, change: .setFormula(addr: addr, sheet: sheet, old: new, new: old))
        case .insertRow(let at, let sheet, let count):
            return Edit(groupID: groupID, change: .deleteRow(at: at, sheet: sheet, count: count))
        case .insertCol(let at, let sheet, let count):
            return Edit(groupID: groupID, change: .deleteCol(at: at, sheet: sheet, count: count))
        case .deleteRow(let at, let sheet, let count):
            return Edit(groupID: groupID, change: .insertRow(at: at, sheet: sheet, count: count))
        case .deleteCol(let at, let sheet, let count):
            return Edit(groupID: groupID, change: .insertCol(at: at, sheet: sheet, count: count))
        case .moveRow(let from, let to, let sheet):
            return Edit(groupID: groupID, change: .moveRow(from: to, to: from, sheet: sheet))
        case .moveCol(let from, let to, let sheet):
            return Edit(groupID: groupID, change: .moveCol(from: to, to: from, sheet: sheet))
        case .clearSheet(let name):
            return Edit(groupID: groupID, change: .clearSheet(name: name))
        case .renameSheet(let old, let new):
            return Edit(groupID: groupID, change: .renameSheet(old: new, new: old))
        case .insertSheet(let name, let at):
            return Edit(groupID: groupID, change: .deleteSheet(name: name))
        case .deleteSheet(let name):
            return Edit(groupID: groupID, change: .insertSheet(name: name, at: 0))
        case .defineName(let name, let old, let new):
            return Edit(groupID: groupID, change: .defineName(name: name, old: new, new: old))
        }
    }
}

// MARK: - UndoRedoStack

/// Thread-safe undo/redo stack with action grouping.
public final class UndoRedoStack: @unchecked Sendable {
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var pendingGroupID: UUID?
    private var pendingEdits: [Edit] = []
    private let lock = NSLock()

    public init() {}

    // MARK: - Grouping

    /// Begin a new edit group. All edits until `endGroup()` share one undo step.
    public func beginGroup() {
        lock.lock()
        defer { lock.unlock() }
        pendingGroupID = UUID()
    }

    /// End the current edit group. All pending edits are grouped into one undo step.
    public func endGroup() {
        lock.lock()
        defer { lock.unlock() }
        guard let groupID = pendingGroupID else { return }

        // Group pending edits under the same groupID
        for var edit in pendingEdits {
            // Create a new edit with the groupID
            let groupedEdit = Edit(groupID: groupID, change: edit.change)
            undoStack.append(groupedEdit)
        }
        pendingEdits.removeAll()
        // Clear redo stack (standard undo behavior)
        redoStack.removeAll()
        pendingGroupID = nil
    }

    /// Cancel the current group without committing.
    public func cancelGroup() {
        lock.lock()
        defer { lock.unlock() }
        pendingEdits.removeAll()
        pendingGroupID = nil
    }

    // MARK: - Push

    /// Push an individual edit (or append to the current group).
    public func push(_ edit: Edit) {
        lock.lock()
        defer { lock.unlock() }

        if pendingGroupID != nil {
            // Accumulate into pending group
            pendingEdits.append(edit)
            return
        }

        undoStack.append(edit)
        redoStack.removeAll() // Clear redo on new edit
    }

    // MARK: - Undo

    /// Pop the most recent undo item and return its inverse.
    public func undo() -> [Edit]? {
        lock.lock()
        defer { lock.unlock() }

        guard !undoStack.isEmpty else { return nil }

        // Collect the top group (all edits with the same groupID)
        var groupID = undoStack.last?.groupID
        var edits: [Edit] = []

        while let edit = undoStack.popLast() {
            edits.append(edit.inverse)
            if edit.groupID != groupID { break }
            if groupID == nil { break } // Individual edit
        }

        // Push to redo stack
        for edit in edits.reversed() {
            redoStack.append(edit.inverse)
        }

        return edits.isEmpty ? nil : edits
    }

    // MARK: - Redo

    /// Pop the most recent redo item and return it.
    public func redo() -> [Edit]? {
        lock.lock()
        defer { lock.unlock() }

        guard !redoStack.isEmpty else { return nil }

        var groupID = redoStack.last?.groupID
        var edits: [Edit] = []

        while let edit = redoStack.popLast() {
            edits.append(edit)
            if edit.groupID != groupID { break }
            if groupID == nil { break }
        }

        // Push to undo stack
        for edit in edits.reversed() {
            undoStack.append(edit)
        }

        return edits.isEmpty ? nil : edits
    }

    // MARK: - State

    public var canUndo: Bool {
        lock.lock(); defer { lock.unlock() }
        return !undoStack.isEmpty
    }

    public var canRedo: Bool {
        lock.lock(); defer { lock.unlock() }
        return !redoStack.isEmpty
    }

    public var undoCount: Int {
        lock.lock(); defer { lock.unlock() }
        return undoStack.count
    }

    public var redoCount: Int {
        lock.lock(); defer { lock.unlock() }
        return redoStack.count
    }

    /// Clear all history.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        undoStack.removeAll()
        redoStack.removeAll()
        pendingEdits.removeAll()
        pendingGroupID = nil
    }

    /// Last edit summary (for UI display).
    public var lastEditDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = undoStack.last else { return nil }
        return describe(last.change)
    }

    private func describe(_ change: Edit.Change) -> String {
        switch change {
        case .setValue(let addr, _, _, _): return "Edit \(addr)"
        case .setFormula(let addr, _, _, _): return "Formula in \(addr)"
        case .insertRow(let at, _, _): return "Insert row at \(at + 1)"
        case .insertCol(let at, _, _): return "Insert column at \(at + 1)"
        case .deleteRow(let at, _, _): return "Delete row \(at + 1)"
        case .deleteCol(let at, _, _): return "Delete column \(at + 1)"
        case .moveRow(let from, let to, _): return "Move row \(from + 1) to \(to + 1)"
        case .moveCol(let from, let to, _): return "Move column \(from + 1) to \(to + 1)"
        case .clearSheet(let name): return "Clear sheet '\(name)'"
        case .renameSheet(let old, _): return "Rename sheet '\(old)'"
        case .insertSheet(let name, _): return "Insert sheet '\(name)'"
        case .deleteSheet(let name): return "Delete sheet '\(name)'"
        case .defineName(let name, _, _): return "Define name '\(name)'"
        }
    }
}
