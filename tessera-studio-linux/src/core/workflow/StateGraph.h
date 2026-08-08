#pragma once
#include <string>
#include <vector>
#include <unordered_map>
#include <functional>
#include <set>
#include <optional>
#include "core/data/DataLayer.h"

namespace tessera {

// LangGraph-inspired state graph for Tessera — Fedora-native C++
// Concepts: State (typed map), Nodes (functions), Edges (normal/conditional), Entry/Finish, Checkpointer (Postgres), Interrupts (human approval), Reducers

using GraphState = std::unordered_map<std::string, std::string>; // JSONValue simplified to string for now; extensible to variant
struct StateUpdate {
    GraphState updates;
    // reducer per key: "replace" (default), "append", "add"
    std::unordered_map<std::string, std::string> reducers; // key -> reducer type
};

using NodeFunc = std::function<StateUpdate(const GraphState&)>;

struct GraphNode {
    std::string id;
    std::string displayName;
    NodeFunc fn;
    std::string description;
};

struct ConditionalEdge {
    std::string from;
    std::function<std::string(const GraphState&)> router; // returns next node id or "__end__"
    std::unordered_map<std::string, std::string> branches; // router result -> node id
};

enum class WorkflowEventType { Started, NodeStarted, NodeFinished, Log, Interrupted, Checkpoint, Finished };
struct WorkflowEvent {
    WorkflowEventType type;
    std::string nodeId;
    std::string typeId;
    std::string message;
    bool success = true;
    GraphState stateSnapshot;
};

struct Checkpoint {
    std::string id; // uuid/v4
    std::string threadId; // workflow run id
    int step = 0;
    std::string nodeId;
    GraphState state;
    std::string createdAt; // iso8601
};

// Reducer: merge current state with update
GraphState reduceState(const GraphState &current, const StateUpdate &update);

// Checkpointer — Postgres-backed via DataLayer (entity_type workflow_checkpoint, like receipt_chain)
class PostgresCheckpointer {
public:
    explicit PostgresCheckpointer(DataLayer *dl) : data_(dl) {}
    std::string save(const std::string &threadId, int step, const std::string &nodeId, const GraphState &state);
    std::optional<Checkpoint> load(const std::string &checkpointId) const;
    std::vector<Checkpoint> list(const std::string &threadId) const;
    std::optional<Checkpoint> latest(const std::string &threadId) const;
    bool purge(const std::string &threadId);
private:
    DataLayer *data_ = nullptr;
    static std::string toJson(const GraphState &s);
    static GraphState fromJson(const std::string &j);
};

// StateGraph — LangGraph-style
class StateGraph {
public:
    StateGraph() : StateGraph("workflow", nullptr) {}
    explicit StateGraph(const std::string &name, DataLayer *dl = nullptr);

    // Graph construction
    void addNode(const std::string &id, const std::string &displayName, NodeFunc fn, const std::string &desc="");
    void addEdge(const std::string &from, const std::string &to);
    void addConditionalEdge(const std::string &from, std::function<std::string(const GraphState&)> router, const std::unordered_map<std::string,std::string> &branches);
    void setEntryPoint(const std::string &id);
    void setFinishPoint(const std::string &id); // "__end__" sentinel for finish
    void interruptBefore(const std::vector<std::string> &nodeIds);
    void interruptAfter(const std::vector<std::string> &nodeIds);
    void setReducer(const std::string &key, const std::string &reducer); // "replace" | "append" | "add"

    // Validation (unknown node, type mismatch, cycle)
    bool validate(std::string &err) const;

    // Execution — off GTK thread, events via callbacks marshalled with g_idle_add
    using EventCb = std::function<void(const WorkflowEvent&)>;
    using StateCb = std::function<void(const Checkpoint&)>;

    // Run from initial state; returns threadId for resume
    std::string run(const GraphState &initial, EventCb onEvent, StateCb onCheckpoint);
    // Resume from a checkpoint (time travel)
    std::string resume(const std::string &checkpointId, EventCb onEvent, StateCb onCheckpoint);
    // Streaming run that respects interrupts — caller must approve via approveInterrupt()
    bool approveInterrupt(const std::string &threadId, bool approved, const std::string &message="");

    // Introspection
    std::vector<GraphNode> nodes() const;
    std::vector<std::pair<std::string,std::string>> edges() const;
    std::vector<ConditionalEdge> conditionalEdges() const;
    std::string name() const { return name_; }

private:
    std::string name_;
    DataLayer *data_ = nullptr;
    std::vector<GraphNode> nodes_;
    std::vector<std::pair<std::string,std::string>> edges_;
    std::vector<ConditionalEdge> condEdges_;
    std::string entryPoint_;
    std::string finishPoint_ = "__end__";
    std::set<std::string> interruptBefore_;
    std::set<std::string> interruptAfter_;
    std::unordered_map<std::string,std::string> reducers_;

    PostgresCheckpointer checkpointer_;
    // runtime
    struct RunContext {
        std::string threadId;
        GraphState state;
        int step = 0;
        EventCb onEvent;
        StateCb onCheckpoint;
    };
    void executeThread(RunContext ctx, std::optional<Checkpoint> resumeFrom);
    static std::string newThreadId();
    static std::string newCheckpointId();
};

} // namespace tessera
