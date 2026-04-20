# ADR-001: Runtime Topology — Interactive vs Daemon Mode

**Status**: Accepted
**Date**: 2026-04-20
**Context**: KairosChain 24/7 Autonomous Operation Design v0.2, Gap 1 §1.1
**Decision makers**: Masaomi Hatakeyama + 4-LLM review panel (R2 converged)

---

## Context

KairosChain must support two fundamentally different operational contexts:

1. **Interactive**: Human developer using Claude Code, MCP protocol over stdio, tool calls dispatched via JSON-RPC. Human-in-the-loop for all decisions.
2. **Autonomous (Daemon)**: 24/7 background operation, no MCP client connected, scheduled mandates via Chronos, self-directed OODA loops with safety gates.

The question: how does daemon mode invoke tools without an MCP client?

## Decision

**KairosChain operates in two modes sharing the same codebase and tool implementations.**

| Aspect | Interactive Mode | Daemon Mode |
|--------|-----------------|-------------|
| MCP Transport | stdio (JSON-RPC) | None |
| Tool Dispatch | `Protocol#handle_tool_call` → MCP | Direct: `ToolRegistry#invoke` |
| Process Model | Child of Claude Code | Standalone (launchd/Docker) |
| Session Lifecycle | Tied to Claude Code session | Persistent, survives restarts |
| Human Interaction | Synchronous (approve/revise/skip) | Asynchronous (attach to observe) |
| State Recovery | N/A (short-lived) | WAL + idempotency keys |

### Key Insight

The existing `ToolRegistry` already resolves tool classes by name and can invoke them directly via Ruby method calls:

```ruby
# Daemon mode — no MCP transport needed:
tool_class = ToolRegistry.resolve("safe_file_write")
tool = tool_class.new(safety: @safety, invocation_context: @ctx)
result = tool.call(params)

# Interactive mode — same tool, MCP transport:
# Client → JSON-RPC → Protocol#handle_tool_call → ToolRegistry → tool.call(params)
```

Both modes execute the same `BaseTool#call` implementations. The difference is only in how the call is routed.

### Interactive Session Attachment

When a Claude Code session connects to a running daemon:
- Daemon exposes an MCP endpoint (HTTP/SSE on localhost)
- Session can observe state, issue mandates, override checkpoints
- Daemon continues autonomously if session disconnects
- Multiple sessions can attach read-only; one session at a time has write control

### Process Supervision

| Platform | Mechanism | Auto-restart | Health Check |
|----------|-----------|--------------|--------------|
| macOS (dev) | launchd plist | `KeepAlive: true` | Process exit code |
| Docker (prod) | `restart: always` | Container policy | HTTP `/health` endpoint |

Environment requirements:
- `RBENV_VERSION=3.3.7` pinned in launchd env (macOS)
- Working directory: project root (`.kairos/` must be accessible)

## Consequences

### Positive
- **No daemon-specific tool rewrites**: All tools work identically in both modes
- **Testability**: Daemon mode can be tested by directly invoking ToolRegistry in tests
- **Gradual migration**: Phase 1 (current) runs in interactive mode only; daemon infrastructure is Phase 2
- **Session attachment**: Human can inspect and intervene at any time

### Negative / Risks
- **Safety divergence risk**: Daemon mode has no human confirmation UI → must enforce safety gates programmatically (mandate risk budgets, complexity review, L0 checkpoint)
- **State recovery complexity**: Daemon must handle crashes mid-ACT → requires WAL (Phase 2)
- **Permission model**: Interactive mode has Claude Code's permission system; daemon mode must implement its own (InvocationContext blacklist + Safety policies)

### Neutral
- `CognitiveLoop` and `AgentStep` work unchanged in both modes (they invoke tools via `@caller.invoke_tool` which abstracts the dispatch mechanism)
- Logging (P1.2) works in both modes (writes to `.kairos/logs/`)
- Blockchain recording works in both modes (direct Ruby calls)

## Phase 1 Implications (Current)

Phase 1 does NOT implement daemon mode. This ADR documents the architectural decision so that:
1. Phase 1 code does not accidentally introduce daemon-incompatible patterns
2. Phase 2 implementation has a clear target architecture
3. Design reviews can verify daemon-readiness of new code

### Daemon-readiness checklist for Phase 1 code:
- [ ] Tools must not assume MCP stdio transport
- [ ] State must be persisted to disk (not held in MCP session memory)
- [ ] Side effects must be idempotent or WAL-protectable
- [ ] No interactive prompts or blocking user input
- [ ] InvocationContext must be serializable (already implemented)

## Related Decisions
- **State Recovery (Gap 1 §1.2)**: WAL + idempotency keys for ACT phase (Phase 2)
- **Chronos Scheduler (Gap 2)**: Cron-like mandate issuer for daemon mode (Phase 2)
- **Session Attachment Protocol (Gap 1 §1.1)**: HTTP/SSE attach mechanism (Phase 2, A2 addendum)

## References
- Design: `log/kairoschain_24x7_autonomous_v0.2_design_20260420.md` §Gap 1
- R2 consensus: `log/kairoschain_24x7_autonomous_v0.2_review2_consensus_20260420.md` (A2: attach protocol)
- Philosophy: CLAUDE.md — "Prefer P2P-natural, locally-autonomous designs"
