---
name: kairoschain_capability_boundary
description: KairosChain Phase 1.5 doctrine — how KairosChain articulates its own boundary against harness (Claude Code, Codex CLI, Cursor, raw API). Use this when reasoning about which features are KairosChain native vs harness-borrowed.
tags: [doctrine, capability, harness, boundary, phase1.5, acknowledgment, self-articulation, l0, l1]
version: "1.1.1"
date: 2026-05-03
---

# KairosChain Capability Boundary — Doctrine

## Why this exists

KairosChain runs inside a **harness** (Claude Code, Codex CLI, Cursor, or raw API). Many features that operationally appear to be "KairosChain capabilities" are actually delivered by the harness. Examples:

- CLAUDE.md auto-load (Claude Code) — delivers KairosChain doctrine to LLM context
- MEMORY.md auto-load (Claude Code) — delivers Active Resume Points UX
- Skill auto-trigger (Claude Code) — surfaces L1 knowledge as skills
- Subagent delegation (Claude Code Agent tool) — backs the persona unanimity gate of multi_llm_review
- Subprocess CLI invocation (claude/codex/cursor) — backs subprocess reviewers

If KairosChain (or its operating LLM) doesn't recognize the boundary, **two failure modes** follow:

1. **Self-overestimation**: assuming KairosChain capabilities that don't exist on a different harness
2. **Conflation in design**: improving "KairosChain" by piling features into harness-specific delivery (e.g., bigger CLAUDE.md), which doesn't translate when the harness changes

Phase 1.5 introduces the structural articulation needed to prevent both.

## The 8 Invariants

| # | Invariant | What it means |
|---|---|---|
| 1 | **Self-articulation** | KairosChain's boundary must be queryable at runtime. The interface is `capability_status` MCP tool + this L1 doctrine. |
| 2 | **Honest unknown** | When detection fails, return `:unknown`. Never guess. |
| 3 | **Declare-not-enforce** | Capability declarations articulate, they do not refuse tool calls. |
| 4 | **Structural congruence** | The DSL (`harness_requirement` method override) matches BaseTool's existing pattern (`name`, `category`, `usecase_tags`). No new mechanism. |
| 5 | **Composability** | SkillSet tools participate in the same mechanism. No SkillSet-vs-core split. |
| 6 | **Active vs external separation** | "What harness runs KairosChain" (active_harness) and "what CLIs KairosChain spawns" (used_externals) are concepts. Same-source CLI is excluded from used_externals (claude_cli excluded when active_harness=:claude_code). |
| 7 | **Forward-only metadata** | Tools opt in to declarations. Undeclared default = `:core` but flagged with `declared: false`. |
| 8 | **Acknowledgment** | When a tool uses external/harness assistance, the response articulates that explicitly via `harness_assistance_used:` field. Silent absorption is forbidden. Distinct from Honest unknown — that handles detection failure (epistemology), Acknowledgment handles successful-but-dependent execution (articulation duty). |

## The 3 Tiers

A tool's `harness_requirement` declares which tier:

- **`:core`** — MCP protocol + filesystem only. Subprocess never spawned. Harness-agnostic. Examples: context_save, chain_record, knowledge_get, capability_status itself (with `probe_externals: false`).
- **`:harness_assisted`** — Spawns subprocess CLIs OR uses harness-specific features that have graceful fallback. Examples: agent_* (uses llm_client SkillSet whose backend is subprocess CLI), multi_llm_review (subprocess reviewers + Claude Code Agent persona path).
- **`:harness_specific`** — Cannot work outside one specific harness. Examples: plugin_project (target_harness: claude_code; generates Claude Code plugin artifacts).

**Tier transitivity**: `:core` works in `:harness_assisted` and `:harness_specific` environments too. Reverse is not true.

## How to use `capability_status`

`capability_status` is the MCP tool that returns the 4-layer view:

| Layer | Content | When to consult |
|---|---|---|
| **declared** | Static manifest of all registered tools and their tiers | Always — answers "what tools exist and their declared tier" |
| **observed** | Runtime detection (active_harness, used_externals, optional external_availability) | When you need to know what's actually running |
| **delivery_channels** | Active harness-delivered content surfaces (CLAUDE.md/MEMORY.md auto-load etc.) | When you need to recognize "this content reached the LLM via harness, not via KairosChain" |
| **tension** | Mismatches between declared and observed | Pre-flight check before invoking a `:harness_assisted` tool |

### Pre-flight check pattern

Before invoking a tool you suspect may be harness-coupled:

```
1. Call capability_status (probe_externals: true if you need external_availability)
2. Find the tool in declared.tools
3. If tier == :core → safe to invoke anywhere
4. If tier == :harness_assisted → check observed.external_availability for required CLIs, OR consult fallback_chain
5. If tier == :harness_specific → check observed.active_harness == declared.target_harness
6. Read tension[] to see if any declared dependencies are missing
```

`capability_status` itself is `:core` by default. With `probe_externals: true` it adds an `external_availability` section honestly self-labeled with `tier_used: :harness_assisted` (the section's data was obtained via harness-touching probes, but the rest of the tool stays core).

## Acknowledgment in tool responses

`:harness_assisted` and `:harness_specific` tools that use the `with_acknowledgment` helper include a `harness_assistance_used:` field in their response:

```json
{
  "result": "...",
  "harness_assistance_used": {
    "path_taken": "claude_code_agent_personas",
    "tier_actually_used": "harness_specific",
    "target_harness": "claude_code",
    "acknowledgment": "this invocation used harness_specific path 'claude_code_agent_personas' (target_harness: claude_code) — articulated per Acknowledgment invariant"
  }
}
```

**Read this field**. It tells you whether the tool relied on harness-borrowed capability for this specific invocation. If you reason about KairosChain's "capabilities" without reading these fields, you will overestimate what's portable.

## Delivery channels (channels are NOT KairosChain native)

The `delivery_channels` section of `capability_status` enumerates harness-delivered content surfaces. Some content delivered via these channels IS KairosChain doctrine; the **delivery itself is a harness feature**:

| Channel | Content | Delivery |
|---|---|---|
| CLAUDE.md auto-load (Claude Code) | KairosChain doctrine (e.g., Multi-LLM Review Philosophy Briefing) | Claude Code feature |
| MEMORY.md auto-load (Claude Code) | KairosChain L2 handoff data (Active Resume Points) | Claude Code feature |
| Skill auto-trigger (Claude Code) | (depends on skill) | Claude Code feature |

When you read content that originated from these channels, **acknowledge that the delivery is harness-specific** even when the content is KairosChain doctrine. On a non-Claude-Code harness, the same content exists but is not auto-delivered — the LLM must explicitly fetch it (via `knowledge_get`, `resource_read`, etc.).

## The masaomi reframe (origin of Acknowledgment invariant)

> 「常に自分自身の能力で仕事をしているのか、誰かの協力で仕事が達成できているのかを認識していることは感謝の気持ちにもつながりますし、自己能力の過大評価を防げます」
>
> "Always knowing whether you are doing the work with your own capability or with someone else's cooperation leads to gratitude and prevents overestimation of one's self-capability."

This human analog drives the Acknowledgment invariant. Phase 1.5 is the machine translation: even redundant per-operation acknowledgment is valuable, because conflation prevention is structurally upstream of feature improvement.

## Consumer

This doctrine is for **the KairosChain orchestrator LLM**, regardless of which harness runs it. Whether you are an Opus 4.7 instance running under Claude Code, an Opus 4.6 subprocess under codex CLI, or a model invoked via raw Anthropic API, this doctrine applies: read `capability_status`, recognize delivery channels, and articulate harness assistance in your reasoning about KairosChain's capabilities.

## Update cadence

This doctrine updates on:
- **Invariant changes** (= going through a new design round, multi-LLM reviewed)
- **Tier classification changes** (each tool maintainer when modifying their tool's `harness_requirement`)
- **Delivery channel additions** (when a new harness or a new auto-load mechanism is recognized)

## Related references

- Design source: `docs/drafts/capability_boundary_design_v1.1.md`
- Phase 1 (Context Graph) precursor: `docs/drafts/context_graph_l2_mapping_design_v2.1.md`
- KairosChain 9 propositions: `CLAUDE.md` (Generative Principle + Nine Propositions)
