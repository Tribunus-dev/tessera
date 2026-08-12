# Tessera Formula Engine: LangGraph Integration Design
## First-Class Integration with LangGraph State, Tools, Checkpoints, and Human-in-the-Loop

Date: 2026-08-11
Author: Mavis (for Julian Torres, sole architect)
Purpose: Design the integration between Tessera's Swift formula engine and LangGraph's
state graph model. The formula engine is not just "usable from" LangGraph — it is a
first-class citizen with dedicated state schema fields, MCP tool bindings, checkpoint
serialization, interrupt hooks, and knowledge graph edges.

---

## 1. Architecture Overview

### The bridging problem

LangGraph is Python. Tessera is Swift. The integration must cross that boundary.

```
Tessera Formula Engine (Swift, tessera-core)
    │
    ├── TesseraStudio Mac app
    │       SheetGridView ← SheetEngine ← EmbeddedPythonBridge ← tessera_lo_service.py
    │
    └── tessera-mcp-server (Python/FastMCP, sidecar process)
            │
            └── JSON-RPC over stdio or HTTP
                    │
                    └── LangGraph graph.nodes
                            │
                            ├── evaluate_formula(cell, sheet?)
                            ├── set_cell_value(addr, value, sheet?)
                            ├── get_range(range, sheet?)
                            ├── recalculate()
                            ├── run_scenario(name)
                            ├── compare_scenarios(a, b)
                            ├── get_named_ranges()
                            └── get_dependency_subgraph(cell)

LangGraph (Python, orchestration layer)
    │
    ├── StateGraph
    │       ├── State: TypedDict (formula_engine + workflow state)
    │       ├── Nodes: formula tool calls + LLM + approval + routing
    │       ├── Edges: conditional on formula outputs
    │       └── Checkpointer: PostgresSaver / MemorySaver
    │
    └── langgraph.mcp.MCPClient
            └── mcp_tool() bindings → MCP server tools
```

### Why MCP as the bridge layer

LangGraph has native first-class MCP support:
- `langgraph.mcp.MCPClient("http://...")` connects to any MCP server
- `mcp_tool(client, "tool_name")` wraps an MCP tool as a LangChain tool
- Tools appear in the LLM's action space with full schema metadata
- LangGraph checkpoints serialize the tool call history automatically

MCP is the right abstraction because:
1. LangGraph doesn't care that the engine is Swift — it only knows the tool contract
2. The same MCP server can serve both TesseraStudio (native) and the LangGraph agent
3. MCP resources can expose workbook metadata (sheets, named ranges, SheetPort manifests)
4. MCP prompts can define reusable formula evaluation workflows

---

## 2. LangGraph State Schema

The formula engine state lives in the LangGraph `TypedDict` alongside the workflow state.

```python
from typing import TypedDict, Annotated, Literal
from pydantic import BaseModel, Field

# ─────────────────────────────────────────────────────────────
# Formula engine state slice (lives in the LangGraph state)
# ─────────────────────────────────────────────────────────────

class FormulaEngineState(TypedDict, total=False):
    """The formula engine's contribution to the LangGraph state."""

    # Active workbook
    workbook_path: str | None
    workbook_loaded: bool
    workbook_sheets: list[str]
    active_sheet: str

    # Cell values — serialized Value enum
    # Represented as {"type": "number", "value": 42.0} etc.
    cell_values: dict[str, dict]  # "Sheet1!A1" -> Value serialized

    # Computed formula results (evaluated values, not formula text)
    formula_results: dict[str, dict]  # "Sheet1!B2" -> computed Value

    # Errors
    errors: dict[str, str]  # "Sheet1!C3" -> "#DIV/0!", "#REF!" etc.

    # Dirty cells awaiting recalculation
    dirty_cells: list[str]
    dirty_roots: list[str]  # cells that triggered the dirty propagation

    # Named ranges
    named_ranges: dict[str, str]  # "Revenue" -> "Sheet1!B2:B50"

    # Scenarios (SheetPort)
    scenarios: dict[str, dict]  # scenario name -> input bindings
    active_scenario: str | None
    scenario_results: dict[str, dict]  # name -> {output_cells: {...}}

    # Approval state (human-in-the-loop)
    pending_approvals: list["ApprovalRequest"]
    approved_cells: list[str]  # cells approved by human
    rejected_cells: list[str]

    # Receipt trace for AI agent operations
    eval_deterministic_config: dict | None
    eval_receipt_id: str | None

    # Knowledge graph edges from this workbook
    kg_references: list["KGReference"]  # cells linked to graph entities


class KGReference(TypedDict):
    """A cell linked to a knowledge graph entity."""
    cell: str           # "Sheet1!A1"
    entity_id: str      # UUID of the linked entity
    entity_label: str   # human-readable name
    relation: str       # "references", "owns", "depends_on"


class ApprovalRequest(TypedDict):
    """A human-in-the-loop approval gate on a formula result."""
    id: str
    triggered_by: str   # cell that triggered the approval check
    formula: str        # "=NPV(B2, C2:C12)"
    computed_value: dict  # Value serialized
    threshold: dict | None  # if threshold exceeded
    reason: str
    created_at: str      # ISO timestamp


# ─────────────────────────────────────────────────────────────
# Full LangGraph workflow state
# ─────────────────────────────────────────────────────────────

class WorkflowState(TypedDict):
    """Complete state for a Tessera-LangGraph workflow."""

    # Formula engine
    formula: FormulaEngineState

    # LLM conversation
    messages: Annotated[list, add_messages]

    # Workflow control
    current_node: str
    workflow_status: Literal["running", "paused", "approved", "rejected", "done"]
    retry_count: int
    interrupt_reason: str | None

    # Document operations
    document_path: str | None
    document_receipt_id: str | None

    # Audit trail
    operation_log: list["OperationEntry"]
```

### Why this schema design

1. **`cell_values` / `formula_results` split**: `cell_values` are the raw inputs (user-set). `formula_results` are computed outputs. Separating them means the graph can distinguish "what the user typed" from "what the engine computed."

2. **`dirty_roots`**: The cells that were explicitly set (not just recalculated). Used to show the user "you changed B2, which triggered these 8 downstream recalculations."

3. **`pending_approvals`**: Human-in-the-loop gates on formula results. The graph can interrupt on `#DIV/0!` or when a computed value exceeds a threshold, wait for human approval, and resume.

4. **`kg_references`**: Bidirectional edges between sheet cells and the knowledge graph. A cell `=Revenue - Expenses` in a financial model links to the `Revenue` and `Expenses` KG entities. The graph can traverse from a KG entity to the cells that reference it.

5. **`eval_deterministic_config`**: When an AI agent evaluates a model, the deterministic config (clock seed, RNG seed, timezone) is checkpointed. Any reviewer replays with the same seed and gets bit-identical results.

---

## 3. MCP Tool Bindings

The formula engine exposes these tools via the MCP server. Each tool maps to one
or more LangGraph node actions.

### Tool schemas

```python
# ─── Workbook operations ───────────────────────────────────────

load_workbook(path: str, sheet: str | None = None) -> {
    workbook_loaded: bool,
    sheets: list[str],
    active_sheet: str,
    cell_values: dict[str, dict],    # pre-loaded values
    named_ranges: dict[str, str],
    scenarios: dict[str, dict],
    error: str | None
}

save_workbook(path: str | None = None) -> {
    saved: bool,
    path: str,
    error: str | None
}

reload_workbook() -> { ...same as load_workbook... }


# ─── Cell operations ───────────────────────────────────────────

set_cell_value(addr: str, value: dict, sheet: str | None = None) -> {
    success: bool,
    dirty_cells: list[str],          # downstream cells now dirty
    errors: dict[str, str],          # new errors introduced
    error: str | None
}

# value schema: {"type": "number", "value": 42.0}
#              {"type": "string", "value": "hello"}
#              {"type": "bool", "value": true}
#              {"type": "null"}

set_formula(addr: str, source: str, sheet: str | None = None) -> {
    success: bool,
    dirty_cells: list[str],
    errors: dict[str, str],
    error: str | None
}

# source: "=SUM(A1:A10)", "=Revenue - Expenses", etc.


# ─── Evaluation ────────────────────────────────────────────────

evaluate_formula(addr: str, sheet: str | None = None) -> {
    value: dict,                     # computed Value
    formula: str | None,
    error: str | None
}

get_cell(addr: str, sheet: str | None = None) -> {
    value: dict,
    formula: str | None,
    cached_result: dict | None,
    is_dirty: bool,
    error: str | None
}

get_range(range_: str, sheet: str | None = None) -> {
    values: list[dict],             # row-major flat array
    width: int,
    height: int,
    error: str | None
}

recalculate(incremental: bool = True) -> {
    dirty_cells: list[str],
    computed_cells: list[str],
    errors: dict[str, str],
    error: str | None
}


# ─── Named ranges ──────────────────────────────────────────────

define_name(name: str, ref: str, scope: str | None = None) -> {
    success: bool,
    error: str | None
}

get_named_ranges() -> {
    named_ranges: dict[str, str],   # name -> "Sheet1!A1:B10"
    error: str | None
}


# ─── SheetPort / scenarios ─────────────────────────────────────

list_scenarios() -> {
    scenarios: list[str],
    error: str | None
}

run_scenario(name: str, deterministic: dict | None = None) -> {
    success: bool,
    input_cells: dict[str, dict],    # cells set by scenario
    output_cells: dict[str, dict],   # computed outputs
    errors: dict[str, str],
    deterministic_receipt_id: str | None,
    error: str | None
}

compare_scenarios(a: str, b: str) -> {
    a_outputs: dict[str, dict],
    b_outputs: dict[str, dict],
    diff: dict[str, {"a": dict, "b": dict}],
    error: str | None
}

validate_manifest(manifest_yaml: str) -> {
    valid: bool,
    errors: list[str],
    warnings: list[str]
}


# ─── Dependency graph introspection ─────────────────────────────

get_dependency_subgraph(addr: str, depth: int = 1) -> {
    graph: {
        "nodes": list[{"addr": str, "formula": str | None}],
        "edges": list[{"from": str, "to": str}]  # from -> to means "to depends on from"
    },
    error: str | None
}

get_evaluation_order(roots: list[str]) -> {
    order: list[str],               # evaluation order (topological sort)
    has_cycles: bool,
    cycle_members: list[str] | None,
    error: str | None
}


# ─── Approval / human-in-the-loop ──────────────────────────────

check_approval_required(addr: str, threshold: dict | None = None,
                       reason: str = "") -> {
    approval_required: bool,
    request_id: str | None,
    computed_value: dict,
    threshold: dict | None,
    error: str | None
}

approve_cell(addr: str, request_id: str) -> {
    success: bool,
    error: str | None
}

reject_cell(addr: str, request_id: str, reason: str) -> {
    success: bool,
    error: str | None
}


# ─── Receipt / deterministic ────────────────────────────────────

set_deterministic_mode(config: dict) -> {
    success: bool,
    receipt_id: str,
    error: str | None
}
# config: {"clock_seed": 1723400000, "timezone": "America/Los_Angeles",
#           "rng_seed": 42, "locale": "en_US"}

get_receipt(eval_receipt_id: str) -> {
    receipt: {
        "id": str,
        "workbook_path": str,
        "timestamp": str,
        "deterministic_config": dict,
        "operations": list[dict],    # cell changes
        "computed_results": dict,
        "validator": str             # "deterministic_replay"
    },
    error: str | None
}
```

---

## 4. MCP Server Implementation

### tessera-mcp-server (Python, FastMCP)

```python
# tessera-mcp-server/server.py
from mcp.server.fastmcp import FastMCP
from langgraph_mcp import MCPClient
import httpx

mcp = FastMCP("tessera-formula-engine")

# ─── Transport to Swift engine ──────────────────────────────────
# Two options:
#   A. HTTP: Swift engine runs an HTTP server on localhost:8420
#   B. Stdio: Swift engine runs as a subprocess, communicates via JSON-RPC over stdin/stdout
#
# Option B is preferred (no port management, works in all environments).
# The Swift side uses a simple JSON-RPC 2.0 protocol over stdio.

SWIFT_ENGINE_PATH = "/path/to/tessera-formula-engine-sidecar"
# or HTTP:
# ENGINE_URL = "http://localhost:8420"

def call_engine(method: str, params: dict = None) -> dict:
    """JSON-RPC 2.0 call to the Swift engine subprocess."""
    import subprocess, json
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": 1}
    result = subprocess.run(
        [SWIFT_ENGINE_PATH],
        input=json.dumps(payload).encode(),
        capture_output=True, timeout=30
    )
    response = json.loads(result.stdout.decode())
    if "error" in response:
        raise Exception(response["error"])
    return response["result"]


# ─── MCP Tools ──────────────────────────────────────────────────

@mcp.tool()
def load_workbook(path: str, sheet: str | None = None) -> dict:
    """Load an Excel workbook (.xlsx) or Tessera sheet into the engine."""
    return call_engine("load_workbook", {"path": path, "sheet": sheet})


@mcp.tool()
def set_cell_value(addr: str, value: dict, sheet: str | None = None) -> dict:
    """Set a cell's raw value. Marks dependent cells as dirty."""
    return call_engine("set_cell_value", {"addr": addr, "value": value, "sheet": sheet})


@mcp.tool()
def set_formula(addr: str, source: str, sheet: str | None = None) -> dict:
    """Set a cell's formula. Parses, registers in dep graph, queues recalc."""
    return call_engine("set_formula", {"addr": addr, "source": source, "sheet": sheet})


@mcp.tool()
def evaluate_formula(addr: str, sheet: str | None = None) -> dict:
    """Evaluate a single formula cell (incremental if already computed)."""
    return call_engine("evaluate_formula", {"addr": addr, "sheet": sheet})


@mcp.tool()
def get_range(range_: str, sheet: str | None = None) -> dict:
    """Get all values in a range as a row-major array."""
    return call_engine("get_range", {"range": range_, "sheet": sheet})


@mcp.tool()
def recalculate(incremental: bool = True) -> dict:
    """Recalculate dirty cells. Use incremental=True for single-cell edits."""
    return call_engine("recalculate", {"incremental": incremental})


@mcp.tool()
def run_scenario(name: str, deterministic: dict | None = None) -> dict:
    """Run a SheetPort scenario with optional deterministic config."""
    return call_engine("run_scenario", {"name": name, "deterministic": deterministic})


@mcp.tool()
def compare_scenarios(a: str, b: str) -> dict:
    """Compare outputs of two SheetPort scenarios side by side."""
    return call_engine("compare_scenarios", {"a": a, "b": b})


@mcp.tool()
def check_approval_required(addr: str, threshold: dict | None = None,
                           reason: str = "") -> dict:
    """Check if a cell value requires human approval before proceeding."""
    return call_engine("check_approval_required",
                       {"addr": addr, "threshold": threshold, "reason": reason})


@mcp.tool()
def approve_cell(addr: str, request_id: str) -> dict:
    """Approve a pending formula result (human-in-the-loop gate)."""
    return call_engine("approve_cell", {"addr": addr, "request_id": request_id})


@mcp.tool()
def get_dependency_subgraph(addr: str, depth: int = 1) -> dict:
    """Get the dependency subgraph rooted at a cell (for graph visualization)."""
    return call_engine("get_dependency_subgraph", {"addr": addr, "depth": depth})


@mcp.tool()
def set_deterministic_mode(config: dict) -> dict:
    """Enable deterministic evaluation mode (fixed clock/RNG seed)."""
    return call_engine("set_deterministic_mode", {"config": config})


@mcp.tool()
def get_receipt(eval_receipt_id: str) -> dict:
    """Get the evaluation receipt for a deterministic run (for verification)."""
    return call_engine("get_receipt", {"eval_receipt_id": eval_receipt_id})


# ─── MCP Resources ──────────────────────────────────────────────

@mcp.resource("workbook://sheets")
def workbook_sheets() -> str:
    """List all sheets in the active workbook."""
    result = call_engine("get_sheet_names", {})
    return json.dumps(result["sheets"])


@mcp.resource("workbook://named-ranges")
def workbook_named_ranges() -> str:
    """List all named ranges in the active workbook."""
    result = call_engine("get_named_ranges", {})
    return json.dumps(result["named_ranges"])


@mcp.resource("workbook://scenarios")
def workbook_scenarios() -> str:
    """List all SheetPort scenarios in the active workbook."""
    result = call_engine("list_scenarios", {})
    return json.dumps(result["scenarios"])


@mcp.resource("workbook://manifest")
def sheetport_manifest() -> str:
    """Get the SheetPort YAML manifest for the active workbook."""
    result = call_engine("get_sheetport_manifest", {})
    return result["manifest_yaml"]
```

### Swift sidecar (JSON-RPC over stdio)

The Swift engine runs as a sidecar subprocess. Communication is JSON-RPC 2.0 over stdin/stdout.
This is the simplest possible protocol — no HTTP server management, no port conflicts,
works in sandboxed environments.

```swift
// tessera-formula-sidecar/main.swift
// Entry point: reads JSON-RPC requests from stdin, writes responses to stdout.

struct JSONRPCRequest: Codable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: [String: AnyCodable]?
    let id: Int
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String = "2.0"
    let result: AnyCodable?
    let error: JSONRPCError?
    let id: Int
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    // Custom Codable implementation for dynamic JSON
}

// Dispatcher
func handle(_ req: JSONRPCRequest, engine: SheetEngine) -> JSONRPCResponse {
    do {
        let result: Any
        switch req.method {
        case "load_workbook":
            result = loadWorkbook(params: req.params, engine: engine)
        case "set_cell_value":
            result = setCellValue(params: req.params, engine: engine)
        case "set_formula":
            result = setFormula(params: req.params, engine: engine)
        case "evaluate_formula":
            result = evaluateFormula(params: req.params, engine: engine)
        case "get_range":
            result = getRange(params: req.params, engine: engine)
        case "recalculate":
            result = recalculate(params: req.params, engine: engine)
        case "run_scenario":
            result = runScenario(params: req.params, engine: engine)
        case "compare_scenarios":
            result = compareScenarios(params: req.params, engine: engine)
        case "check_approval_required":
            result = checkApprovalRequired(params: req.params, engine: engine)
        case "approve_cell":
            result = approveCell(params: req.params, engine: engine)
        case "get_dependency_subgraph":
            result = getDependencySubgraph(params: req.params, engine: engine)
        case "set_deterministic_mode":
            result = setDeterministicMode(params: req.params, engine: engine)
        case "get_receipt":
            result = getReceipt(params: req.params, engine: engine)
        default:
            return JSONRPCResponse(result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found", data: nil),
                id: req.id)
        }
        return JSONRPCResponse(result: AnyCodable(result), error: nil, id: req.id)
    } catch {
        return JSONRPCResponse(result: nil,
            error: JSONRPCError(code: -32000, message: error.localizedDescription, data: nil),
            id: req.id)
    }
}

// Main loop: read lines from stdin, write responses to stdout
// Uses LineBuffering on stdin so each JSON-RPC request is one line
```

---

## 5. LangGraph Node Patterns

### Pattern A: Financial model evaluation workflow

```
User: "Evaluate the Q3 revenue model with +15% growth and +25% margin"
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ node: load_model                                        │
│  tool: load_workbook("models/q3-revenue.xlsx")         │
│  writes: formula.workbook_loaded, formula.active_sheet  │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ node: run_scenario_hypothesis                           │
│  tool: set_cell_value("B2", {type:"number", value:0.15})  │
│  tool: set_cell_value("B3", {type:"number", value:0.25})  │
│  tool: run_scenario("Bull Case")                        │
│  writes: formula.scenario_results["Bull Case"]          │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ node: evaluate_outputs                                   │
│  tool: get_range("E10:E15")  ← Net Income, OCF, etc.  │
│  tool: check_approval_required("E10", threshold={...}) │
│  writes: formula.formula_results, formula.pending_approvals │
└─────────────────────────────────────────────────────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
     pending_approvals?          no approvals needed
              │                       │
              ▼                       ▼
┌─────────────────────────┐   ┌──────────────────────────┐
│ node: wait_for_approval │   │ node: commit_and_export │
│  INTERRUPT (LangGraph)  │   │  tool: save_workbook()  │
│  Human reviews E10:E15  │   │  tool: get_receipt(id)  │
│  approve/reject cells   │   │  writes: formula.eval_  │
│                         │   │    receipt_id           │
└─────────────────────────┘   └──────────────────────────┘
              │
    human approved
              │
              ▼
┌─────────────────────────┐
│ node: finalize          │
│  tool: save_workbook()  │
│  tool: export_receipt() │
└─────────────────────────┘
```

### Pattern B: Multi-agent spreadsheet review

```
Agent A (financial analyst): Loads model, sets base case inputs
Agent B (risk analyst):       Loads same workbook, runs stress scenarios
Agent C (CFO):               Reviews scenario comparison, approves
                              ──────────────────────────────────────
                              LangGraph orchestrates sequencing
                              Checkpointer = PostgresSaver
                              Each agent's edits are checkpointed
                              → Full audit trail of every cell change
                              → Any prior state can be replayed
```

### Pattern C: Agent-as-formula-node

The formula engine's dependency graph itself becomes a sub-graph:

```python
def financial_model_subgraph(state: WorkflowState) -> dict:
    """
    A sub-graph that evaluates a financial model.
    Each cell is a node; cell dependencies are edges.
    The graph traverses the dependency graph topologically.
    """
    outputs = {}

    # Topological evaluation order
    order_result = call_engine_tool("get_evaluation_order",
                                     roots=["E10", "E11", "E12"])
    if order_result["has_cycles"]:
        raise ValueError(f"Cycle detected: {order_result['cycle_members']}")

    for cell in order_result["order"]:
        result = call_engine_tool("get_cell", addr=cell)
        outputs[cell] = result["cached_result"]

        # Check threshold on every computed cell
        if result.get("threshold_exceeded"):
            state["formula"]["pending_approvals"].append({
                "id": str(uuid4()),
                "triggered_by": cell,
                "formula": result["formula"],
                "computed_value": result["cached_result"],
                "threshold": result.get("threshold"),
                "reason": "threshold exceeded",
                "created_at": datetime.utcnow().isoformat()
            })

    return {"formula": {"formula_results": outputs}}
```

### Pattern D: Knowledge graph → sheet cross-reference

```python
def link_sheet_to_graph(state: WorkflowState) -> dict:
    """
    Given a workbook with named ranges,
    traverse the knowledge graph to find which entities they reference.
    Creates KGReference edges for each named range → KG entity mapping.
    """
    named_ranges = call_engine_tool("get_named_ranges")

    kg_references = []
    for name, ref in named_ranges.items():
        # Query the knowledge graph: does this named range match any entity?
        kg_results = kg_graph.query(
            "MATCH (e) WHERE e.name CONTAINS $name RETURN e.id, e.label",
            {"name": name}
        )
        for entity in kg_results:
            kg_references.append({
                "cell": ref,  # "Sheet1!A1:B10"
                "entity_id": entity["id"],
                "entity_label": entity["label"],
                "relation": "references"
            })

    return {"formula": {"kg_references": kg_references}}
```

---

## 6. Human-in-the-Loop: Interrupt + Approval

LangGraph's interrupt mechanism is built for exactly this pattern:

```python
from langgraph.types import interrupt, Command

def evaluate_and_approve(state: WorkflowState) -> Command:
    """
    Node: evaluate a financial output and interrupt if threshold exceeded.
    The graph pauses here. Human reviews in TesseraStudio.
    LangGraph checkpointer persists the full state including the approval request.
    """
    cell = state["approval_target"]  # e.g. "Net Income"
    result = call_engine_tool("check_approval_required",
                               addr=cell,
                               threshold={"type": "number", "value": 1_000_000},
                               reason=f"Net Income exceeds $1M threshold")

    if result["approval_required"]:
        # Interrupt — persist state, wait for human
        interrupt(Command(
            resume={
                "formula": {
                    "pending_approvals": [{
                        "id": result["request_id"],
                        "triggered_by": cell,
                        "computed_value": result["computed_value"],
                        "threshold": result["threshold"]
                    }]
                }
            },
            goto="wait_for_approval_node"
        ))

    return {"formula": {"approved_cells": [cell]}}


def wait_for_approval_node(state: WorkflowState) -> dict:
    """
    LangGraph pauses here. TesseraStudio renders the approval UI.
    Human approves or rejects via approve_cell / reject_cell tool.
    When resumed, check the approval result.
    """
    # LangGraph has already persisted state["formula"]["pending_approvals"]
    # The human uses TesseraStudio to act on it
    # When the graph resumes, check if approval was granted
    if not state["formula"]["approved_cells"]:
        return Command(goto="evaluate_and_approve")
    return {}


def on_approval_resume(state: WorkflowState, resume_value: dict) -> dict:
    """
    Called when the graph resumes after interrupt.
    resume_value contains the approval result from TesseraStudio.
    """
    if resume_value.get("approved"):
        return {"formula": {"approved_cells": state["formula"]["pending_approvals"]}}
    else:
        return {
            "workflow_status": "rejected",
            "operation_log": [{
                "action": "approval_rejected",
                "cell": resume_value["cell"],
                "reason": resume_value["reason"]
            }]
        }
```

---

## 7. Checkpoint Serialization

When LangGraph checkpoints the state, the formula engine state must be serializable
to Python dict (JSON-compatible). The Swift side serializes `Value` as:

```swift
// Value serialization — Swift side
extension Value {
    func serialize() -> [String: Any] {
        switch self {
        case .null:       return ["type": "null"]
        case .number(let v):  return ["type": "number", "value": v]
        case .bool(let v):    return ["type": "bool", "value": v]
        case .string(let v):  return ["type": "string", "value": v]
        case .error(let e):   return ["type": "error", "error": e.displayString]
        case .date(let d):    return ["type": "date", "value": ISO8601Formatter.string(from: d)]
        case .array(let r, let c, let flat):
            return ["type": "array", "rows": r, "cols": c,
                    "flat": flat.map { $0.serialize() }]
        }
    }

    static func deserialize(_ dict: [String: Any]) -> Value? { ... }
}
```

LangGraph stores checkpoints as JSON in Postgres. The formula engine state slice
is serialized as nested dicts. On replay, the state is deserialized and the
Swift sidecar rehydrates the `SheetEngine` from the checkpointed `cell_values`.

**Key invariant**: The checkpoint captures the *cell values* (not the formula ASTs
or dependency graph structure — those are deterministic from the workbook file).
On replay, reload the workbook file and apply the checkpointed `cell_values`.

---

## 8. Named Ranges → Knowledge Graph Edges

Named ranges are the seam between the formula engine and the knowledge graph:

```python
# From the Tessera knowledge graph:
# (:Document {id: "q3-model"}) -[:DEFINES]-> (:NamedRange {name: "Revenue", ref: "Sheet1!B2:B50"})
# (:NamedRange {name: "Revenue"}) -[:AGGREGATES]-> (:Entity {type: "Revenue", label: "Q3 Revenue"})
# (:Entity) -[:BELONGS_TO]-> (:FiscalPeriod {period: "Q3 2026"})

def sync_named_ranges_to_graph(state: WorkflowState) -> dict:
    """
    After loading a workbook, sync its named ranges to the knowledge graph.
    Creates KG entities for named ranges that don't yet exist.
    """
    named_ranges = call_engine_tool("get_named_ranges")

    for name, ref in named_ranges.items():
        # Create or update KG entity for this named range
        kg_graph.upsert({
            "entity_type": "NamedRange",
            "name": name,
            "ref": ref,
            "workbook_path": state["formula"]["workbook_path"],
            "synced_at": datetime.utcnow().isoformat()
        })

        # Create edge from workbook document to named range entity
        kg_graph.link(
            from={"type": "Document", "path": state["formula"]["workbook_path"]},
            to={"type": "NamedRange", "name": name},
            relation="DEFINES"
        )

    return {}
```

---

## 9. SheetPort → Named Graph States

SheetPort scenarios are named graph states:

```python
class SheetPortScenarioState(TypedDict):
    """A SheetPort scenario is a named set of input bindings + computed outputs."""
    scenario_name: str
    input_bindings: dict[str, dict]   # cell -> value
    computed_outputs: dict[str, dict]  # cell -> computed value
    deterministic_config: dict | None
    eval_receipt_id: str | None
    approved: bool
    approved_by: str | None
    approved_at: str | None
```

LangGraph can:
- Fork a checkpoint at any scenario → explore multiple "what-if" branches
- Compare scenario outputs via `compare_scenarios`
- Commit the approved scenario back to the workbook
- Store each scenario as a separate checkpoint in Postgres

---

## 10. Complete Example: CFO Revenue Model Review

```python
from langgraph.graph import StateGraph, add_messages
from langgraph.types import Command, interrupt
from pydantic import BaseModel, Field
from typing import Annotated
import operator

# ─── State ─────────────────────────────────────────────────────

class RevenueModelState(TypedDict):
    messages: Annotated[list, add_messages]
    formula: FormulaEngineState
    approval_target: str | None
    final_output: dict | None


# ─── Graph ─────────────────────────────────────────────────────

builder = StateGraph(RevenueModelState)

# Node 1: LLM understands the user's request
def understand_request(state: RevenueModelState) -> dict:
    msg = state["messages"][-1]["content"]
    # Parse: which model? what assumptions? what outputs to review?
    # Returns: workbook_path, scenario_name, outputs_to_review
    return {"formula": {"workbook_path": "...", "approval_target": "E10"}}


# Node 2: Load workbook
def load_model(state: RevenueModelState) -> dict:
    result = load_workbook(state["formula"]["workbook_path"])
    return {"formula": {
        "workbook_loaded": result["workbook_loaded"],
        "sheets": result["sheets"],
        "cell_values": result["cell_values"],
        "named_ranges": result["named_ranges"]
    }}


# Node 3: Run the scenario
def run_scenario(state: RevenueModelState) -> dict:
    scenario_name = state.get("scenario_name", "Bull Case")
    result = run_scenario(scenario_name, deterministic={
        "clock_seed": 1723400000,
        "rng_seed": 42,
        "timezone": "America/Los_Angeles"
    })
    return {"formula": {
        "scenario_results": {scenario_name: result},
        "eval_deterministic_config": result.get("deterministic_receipt_id")
    }}


# Node 4: Check if approval is needed
def evaluate_outputs(state: RevenueModelState) -> Command:
    target = state.get("approval_target", "E10")
    result = check_approval_required(
        addr=target,
        threshold={"type": "number", "value": 500_000},
        reason="Net Income exceeds $500K — CFO approval required"
    )
    if result["approval_required"]:
        return Command(
            goto="interrupt_for_approval",
            resume={"formula": {"pending_approvals": [{
                "id": result["request_id"],
                "triggered_by": target,
                "computed_value": result["computed_value"],
                "threshold": result["threshold"],
                "reason": "threshold exceeded"
            }]}}
        )
    return {}


# Node 5: Human-in-the-loop interrupt
def interrupt_for_approval(state: RevenueModelState):
    """LangGraph pauses here. TesseraStudio shows the approval UI."""
    interrupt(Command(
        resume={"formula": {"pending_approvals": state["formula"]["pending_approvals"]}}
    ))


# Node 6: LLM summarizes the result for the user
def summarize(state: RevenueModelState) -> dict:
    scenario = state["formula"]["scenario_results"]
    receipt_id = state["formula"]["eval_receipt_id"]
    receipt = get_receipt(receipt_id) if receipt_id else None

    summary = format_scenario_summary(scenario)
    return {"messages": [AIMessage(content=summary)], "final_output": scenario}


# ─── Wire graph ─────────────────────────────────────────────────

builder.add_node("understand", understand_request)
builder.add_node("load", load_model)
builder.add_node("run_scenario", run_scenario)
builder.add_node("evaluate", evaluate_outputs)
builder.add_node("interrupt", interrupt_for_approval)
builder.add_node("summarize", summarize)

builder.set_entry_point("understand")
builder.add_edge("understand", "load")
builder.add_edge("load", "run_scenario")
builder.add_edge("run_scenario", "evaluate")

# Conditional: if approval needed → interrupt → summarize
#              if no approval → summarize
builder.add_conditional_edges(
    "evaluate",
    path=lambda state: "interrupt" if state["formula"]["pending_approvals"] else "summarize"
)
builder.add_edge("interrupt", "summarize")

graph = builder.compile(checkpointer=PostgresSaver(conn))
```

---

## 11. File Structure

```
TesseraStudio/
  FormulaEngine/                  # Swift formula engine (tessera-formula-engine-design.md)
    TypeSystem.swift
    CellAddr.swift
    Lexer.swift
    Parser.swift
    FormulaAST.swift
    DependencyGraph.swift
    Evaluator.swift
    ColumnSlice.swift
    UndoRedoStack.swift
    XLSXFormat.swift
    SheetPort.swift
    NamedRanges.swift
    Functions/
      FunctionRegistry.swift
      AggregateFunctions.swift
      ...
    FormulaEngineTests/
      ...

  tessera-formula-sidecar/        # Swift JSON-RPC sidecar (entry point)
    main.swift
    JSONRPC.swift
    EngineBridge.swift
    SidecarManifest.swift

  tessera-langgraph/              # Python package for LangGraph integration
    pyproject.toml
    tessera_langgraph/
      __init__.py
      state.py                    # FormulaEngineState, WorkflowState TypedDicts
      tools.py                   # MCP tool wrappers (call_engine_tool)
      nodes.py                   # Reusable graph nodes (load_model, run_scenario, etc.)
      interrupts.py              # Human-in-the-loop approval patterns
      kg_sync.py                 # Named range → KG sync
      examples/
        revenue_model_review.py
        financial_stress_test.py
        cfo_approval_flow.py
    tessera_mcp_server/
      server.py                  # FastMCP server (tessera-mcp-server)
      transport.py               # Stdio transport to Swift sidecar
```

---

## 12. Deterministic Receipt Integration

When an AI agent evaluates a financial model, the evaluation is deterministic-reproducible:

```
Agent invokes: run_scenario("Bull Case", deterministic={clock: 1723400000, rng: 42})
    │
    ├── Swift engine sets DeterministicConfig
    ├── TODAY() → fixed date from clock_seed
    ├── RAND()  → reproducible pseudo-random from rng_seed
    └── eval_receipt_id = UUID()
            │
            └── Receipt stored:
                {
                  "id": eval_receipt_id,
                  "workbook_path": "models/q3-revenue.xlsx",
                  "timestamp": "2026-08-11T18:30:00Z",
                  "deterministic_config": {clock: 1723400000, rng: 42, ...},
                  "operations": [{cell: "B2", value: 0.15, formula: "=0.15"}, ...],
                  "computed_results": {E10: {type:"number", value: 1_234_567.89}, ...},
                  "validator": "deterministic_replay"
                }
                    │
                    └── Stored in Tessera receipt chain (Postgres + C2PA)
                        Any reviewer: replay with same deterministic config
                        → bit-identical results
                        → no "but the date was different" dispute
```

The `get_receipt` MCP tool returns this for any AI agent evaluation.
The receipt is a first-class Tessera material receipt — it traces every formula
evaluation to the input cells that produced the output.
