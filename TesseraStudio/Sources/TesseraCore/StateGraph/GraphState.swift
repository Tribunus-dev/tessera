import Foundation

// LangGraph-inspired state graph for Tessera — Swift port of
// tessera-studio-linux/src/core/workflow/StateGraph.{h,cpp}.
//
// Concepts: State (typed map), Nodes (async functions), Edges
// (normal/conditional), Entry/Finish, Checkpointer, Interrupts
// (human approval), Reducers. See StateGraph.swift for the graph
// itself and StateGraphExecutor.swift for the run loop.

/// Typed graph state. The Linux port uses `unordered_map<string,string>`
/// (stringly-typed); Swift upgrades this to `JSONValue` so state keys can
/// hold real numbers, arrays, and objects without parsing.
public typealias GraphState = [String: JSONValue]

/// Per-key reducer semantics. Mirrors the Linux `reducers` map keyed by
/// "replace" | "append" | "add". `reduceState` applies them when merging an
/// update into the current state.
public enum StateGraphReducer: String, Sendable, Codable {
    /// Overwrite the existing value (default).
    case replace
    /// Join strings with a newline; concatenate arrays; no-op otherwise.
    case append
    /// Sum numbers; no-op for non-numeric values.
    case add
}

/// A partial state update returned by a node function. The `reducers` map
/// overrides the graph-level reducer per key; any key not present falls back
/// to the graph default (replace).
public struct StateUpdate: Sendable {
    public var updates: GraphState
    public var reducers: [String: StateGraphReducer]

    public init(updates: GraphState, reducers: [String: StateGraphReducer] = [:]) {
        self.updates = updates
        self.reducers = reducers
    }
}

/// Merge an update into the current state, applying per-key reducers.
/// Port of `reduceState` in StateGraph.cpp:11-31.
public func reduceState(current: GraphState, _ update: StateUpdate, defaultReducer: StateGraphReducer = .replace) -> GraphState {
    var out = current
    for (key, value) in update.updates {
        let reducer = update.reducers[key] ?? defaultReducer
        switch reducer {
        case .replace:
            out[key] = value
        case .append:
            out[key] = appendValues(existing: out[key], new: value)
        case .add:
            out[key] = addValues(existing: out[key], new: value)
        }
    }
    return out
}

private func appendValues(existing: JSONValue?, new: JSONValue) -> JSONValue {
    switch (existing, new) {
    // Append to a string with a newline separator, matching the Linux
    // `f->second += "\n" + kv.second` behaviour. An empty/nil existing
    // value just becomes the new value.
    case (.string(let old)?, .string(let next)) where !old.isEmpty:
        return .string(old + "\n" + next)
    case (.some, .string(let next)), (nil, .string(let next)):
        return .string(next)
    // Array concatenation (extension over the string-only Linux port, since
    // JSONValue can carry arrays).
    case (.array(let old)?, .array(let next)):
        return .array(old + next)
    case (nil, .array(let next)):
        return .array(next)
    // Anything else: overwrite (append has no meaningful semantics for
    // non-string/non-array values).
    default:
        return new
    }
}

private func addValues(existing: JSONValue?, new: JSONValue) -> JSONValue {
    let a = existing?.numberValue ?? 0
    guard let b = new.numberValue else { return new }
    return .number(a + b)
}
