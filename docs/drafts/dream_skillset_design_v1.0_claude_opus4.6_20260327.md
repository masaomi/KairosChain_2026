# Dream SkillSet Design Draft v1.0

**Date**: 2026-03-27
**Author**: Masaomi Hatakeyama (design intent) + Claude Opus 4.6 (primary designer)
**Status**: Draft — awaiting Multi-LLM review
**Scope**: New L1 SkillSet for memory consolidation and knowledge promotion

---

## 0. Design Intent & Philosophical Motivation

### Problem Statement

KairosChain's L2→L1 promotion logic currently lives **outside the system** — in Cursor Rules, Claude Tutorial Mode instructions, and human memory. This creates three problems:

1. **Tool fragmentation**: Promotion triggers differ per client (Cursor sees different rules than Claude Code)
2. **No constitutive recording**: The *decision to consolidate knowledge* is not recorded on the blockchain
3. **Passive accumulation**: L2 contexts accumulate without active review; L1 knowledge can become stale, duplicated, or contradictory

### Deeper Implications

The system that **defines how knowledge evolves** cannot currently **describe its own knowledge evolution rules** within its own framework. This is a gap in structural self-referentiality.

### Philosophical Justification

| Proposition | Relevance |
|-------------|-----------|
| **P1 (Self-referentiality)** | Knowledge consolidation rules should be expressible as a SkillSet, not hard-coded in external tools |
| **P2 (Partial autopoiesis)** | Closing the loop: the system produces its own knowledge organization |
| **P5 (Constitutive recording + Kairotic temporality)** | Consolidation is a constitutive act — it reconstitutes the knowledge structure. Timing is Kairotic (when patterns mature), not Chronos (every N hours) |
| **P6 (Incompleteness as driving force)** | The system can never fully consolidate its own knowledge (Godelian limit), but the attempt drives evolution |

### What This Design IS NOT

- **NOT Auto Dream (Claude Code)**: Auto Dream runs server-side during idle time. Dream SkillSet runs within MCP sessions, triggered by the LLM or autonomos cycle
- **NOT an autonomous agent**: Dream proposes, humans decide. No auto-promotion without consent
- **NOT a replacement for skills_promote**: Dream *discovers candidates* and *prepares proposals*. Actual promotion still goes through `skills_promote`
- **NOT a cron job**: No scheduled execution. Triggered at session start, session end, or during autonomos reflect phase

---

## 1. Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │         Dream SkillSet (L1)         │
                    │                                     │
                    │  dream_scan ──► dream_consolidate   │
                    │       │               │             │
                    │       ▼               ▼             │
                    │  dream_propose ──► skills_promote   │
                    │       │          (existing tool)    │
                    │       ▼                              │
                    │  chain_record                       │
                    │  (consolidation event)              │
                    └──────────┬──────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        Session Start    Autonomos         Manual
        (Orient)         Reflect Phase     Invocation
```

### Dependency Graph

```
dream (new)
├── depends_on: [] (no hard dependencies)
├── integrates_with: autonomos (optional, Orient/Reflect hook)
├── uses: skills_promote (for actual promotion)
├── uses: context_manager (L2 scanning)
├── uses: knowledge_provider (L1 scanning)
└── uses: chain_record (consolidation events)
```

---

## 2. Tool Specifications

### 2.1 dream_scan

**Purpose**: Scan L2 contexts and L1 knowledge, detect patterns and consolidation opportunities.

**When to use**: Session start, or when explicitly asked to review accumulated knowledge.

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `scope` | string | No | `"l2"` (default), `"l1"`, `"all"` — what to scan |
| `since` | string | No | ISO8601 date or session_id — scan from this point (default: all) |
| `min_recurrence` | integer | No | Minimum times a pattern must appear (default: 3) |

**Output**: Structured scan report containing:

```yaml
scan_result:
  scanned:
    l2_sessions: 12
    l2_contexts: 34
    l1_entries: 8

  promotion_candidates:    # L2 patterns ready for L1
    - name: "debug_workflow_pattern"
      evidence:
        - session: "session_20260315_..."
          context: "debugging_rails_api"
          tag_match: [debugging, rails, api]
        - session: "session_20260320_..."
          context: "fix_auth_endpoint"
          tag_match: [debugging, rails, auth]
        - session: "session_20260325_..."
          context: "resolve_pg_timeout"
          tag_match: [debugging, rails, postgres]
      recurrence: 3
      suggested_l1_name: "rails_debugging_patterns"
      confidence: "high"

  consolidation_candidates:  # L1 entries that overlap or conflict
    - type: "overlap"
      entries: ["skillset_quality_guide", "implementation_checklist"]
      overlap_tags: [implementation, quality]
      suggestion: "merge into single entry"

    - type: "stale"
      entry: "old_deployment_config"
      reason: "not referenced in last 10 sessions"
      suggestion: "archive or delete"

    - type: "contradiction"
      entries: ["convention_a", "convention_b"]
      field: "naming_style"
      values: ["camelCase", "snake_case"]
      suggestion: "resolve and unify"

  health_summary:
    total_l2: 34
    total_l1: 8
    promotion_ready: 2
    consolidation_needed: 3
    healthy: true
```

**Implementation approach**:

The scan itself is **structural, not semantic**. It detects patterns through:

1. **Tag frequency analysis**: Count tag co-occurrences across L2 contexts
2. **Name similarity**: Levenshtein distance between context/knowledge names
3. **Cross-session recurrence**: Same tags appearing in N+ distinct sessions
4. **Reference graph**: Which L2 contexts reference the same L1 knowledge
5. **Staleness detection**: L1 entries not referenced in recent L2 contexts

The LLM then interprets the scan results and decides what to propose. This separation keeps the SkillSet tool deterministic while leveraging LLM judgment for semantic analysis.

### 2.2 dream_consolidate

**Purpose**: Prepare a consolidation plan for L1 knowledge (merge, archive, update).

**When to use**: After `dream_scan` identifies consolidation candidates, or manually.

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string | Yes | `"merge"`, `"archive"`, `"update"`, `"preview"` |
| `entries` | array[string] | Yes (merge) | L1 entry names to merge |
| `target_name` | string | Yes (merge) | Name for merged entry |
| `entry` | string | Yes (archive/update) | L1 entry name |
| `reason` | string | No | Reason for consolidation |
| `dry_run` | boolean | No | Preview changes without executing (default: true) |

**Commands**:

- **`preview`**: Show current state of specified entries side-by-side (read-only)
- **`merge`**: Combine multiple L1 entries into one (dry_run default)
  - Creates new merged entry
  - Archives source entries (not deleted)
  - Records merge event on blockchain
- **`archive`**: Mark L1 entry as archived (soft delete)
  - Moves to `knowledge/_archived/`
  - Records archive event on blockchain
  - Archived entries excluded from future scans
- **`update`**: Update metadata of an L1 entry (tags, description)
  - Records update on blockchain

**Safety**: All destructive operations default to `dry_run: true`. The LLM must explicitly set `dry_run: false` after user confirmation.

### 2.3 dream_propose

**Purpose**: Generate a batch promotion proposal from scan results.

**When to use**: After reviewing `dream_scan` results, to create actionable promotion proposals.

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `candidates` | array[object] | Yes | Promotion candidates from dream_scan |
| `assembly` | boolean | No | Use Persona Assembly for evaluation (default: false) |
| `personas` | array[string] | No | Personas for assembly (default: ["kairos", "pragmatic"]) |

Each candidate object:

```json
{
  "source_sessions": ["session_20260315_...", "session_20260320_..."],
  "source_contexts": ["debugging_rails_api", "fix_auth_endpoint"],
  "target_name": "rails_debugging_patterns",
  "reason": "Recurring debugging pattern across 3+ sessions"
}
```

**Output**: For each candidate, generates:

1. A draft L1 knowledge entry (YAML frontmatter + Markdown skeleton)
2. A `skills_promote` command to execute (if user approves)
3. Optional Persona Assembly analysis

**Workflow**:

```
dream_scan → user reviews → dream_propose → user approves → skills_promote
                                                ↓
                                          chain_record
                                    (dream_proposal event)
```

---

## 3. Integration with Autonomos OODA Cycle

### Where Dream Fits

Dream naturally maps to two phases of the OODA cycle:

| OODA Phase | Dream Integration | Timing |
|------------|-------------------|--------|
| **Orient** | `dream_scan` — review accumulated L2, update knowledge landscape | Start of cycle |
| **Reflect** | `dream_propose` — after execution, check if new patterns emerged | End of cycle |

### Implementation

The autonomos reflector (`reflector.rb`) already checks for L1 promotion candidates when the same goal cycles 3+ times. Dream extends this:

```ruby
# In reflector.rb, after existing promotion check:
if dream_enabled? && cycle_count >= promotion_threshold
  # Instead of simple promotion check, invoke dream_scan
  # with scope limited to current goal's related sessions
end
```

This is **optional integration** — Dream works standalone without autonomos.

---

## 4. Blockchain Recording

### What Gets Recorded

| Event | Record Type | Data |
|-------|-------------|------|
| Scan executed | `dream_scan` | Scope, timestamp, result summary (not full content) |
| Consolidation executed | `dream_consolidate` | Command, entries affected, reason |
| Proposal created | `dream_proposal` | Candidate list, assembly result if used |
| Promotion via dream | Delegated to `skills_promote` | Standard promotion record |

### Why Record Scans?

The scan itself is a constitutive act (Proposition 5). Recording "the system examined its own knowledge at time T and found patterns X" is part of the system's self-referential history.

---

## 5. Kairotic Trigger Design

### Why NOT Chronos (Scheduled)

| Chronos (Auto Dream style) | Kairos (Dream SkillSet) |
|----------------------------|-------------------------|
| Triggers after N hours | Triggers when patterns mature |
| Server-side, always-on | Client-side, session-bound |
| Fixed consolidation window | Variable, context-dependent |
| Optimizes for freshness | Optimizes for readiness |

### Trigger Heuristics

The LLM (not the SkillSet) decides when to invoke `dream_scan`. Recommended heuristics (to be encoded in L1 knowledge, not hard-coded):

```yaml
# L1 knowledge: dream_trigger_policy
triggers:
  session_start:
    condition: "last_scan older than 5 sessions"
    action: "dream_scan(scope: 'all')"

  session_end:
    condition: "new L2 contexts created this session >= 2"
    action: "dream_scan(scope: 'l2', since: current_session)"

  autonomos_reflect:
    condition: "same goal cycled 3+ times"
    action: "dream_scan(scope: 'l2', since: first_cycle_session)"

  user_request:
    condition: "user says 'review knowledge' or similar"
    action: "dream_scan(scope: 'all')"
```

These heuristics are **L1 knowledge, not code**. They can be promoted to L0 if they prove stable, or modified without code changes.

---

## 6. Comparison: Dream SkillSet vs. Claude Auto Dream vs. Cursor Rules

| Aspect | Claude Auto Dream | Cursor Rules (current) | Dream SkillSet (proposed) |
|--------|-------------------|------------------------|--------------------------|
| **Scope** | Tool-side memory (.claude/) | Cursor-only rules | KairosChain L1/L2 layers |
| **Trigger** | Idle time (Chronos) | LLM session behavior | Kairos (pattern maturity) |
| **Recording** | None (internal optimization) | None | Blockchain-recorded |
| **Evolvability** | Anthropic controls | Manual rule editing | L2→L1→L0 self-evolution |
| **Pattern detection** | Server-side ML | LLM memory | Structural scan + LLM judgment |
| **Tool-agnostic** | Claude-only | Cursor-only | Any MCP client |
| **Coexistence** | Yes (different layer) | Superseded | Primary |
| **Consolidation** | Date normalization, dedup | None | Merge, archive, update |

### Coexistence with Auto Dream

When Claude Code's Auto Dream feature becomes available:

- Auto Dream handles `.claude/memory/` files (tool-side)
- Dream SkillSet handles `.kairos/` knowledge (system-side)
- No conflict — different layers, different concerns

---

## 7. Self-Referentiality Assessment

### Can Dream Be Expressed as a SkillSet?

**Yes.** Dream follows the standard SkillSet pattern:

```
.kairos/skillsets/dream/
├── skillset.json
├── lib/dream/
│   ├── scanner.rb       # L2/L1 pattern detection
│   ├── consolidator.rb  # Merge/archive/update operations
│   └── proposer.rb      # Batch proposal generation
├── tools/
│   ├── dream_scan.rb
│   ├── dream_consolidate.rb
│   └── dream_propose.rb
├── knowledge/
│   └── dream_trigger_policy/
│       └── dream_trigger_policy.md   # Trigger heuristics (L1)
└── config/
    └── dream.yml         # Defaults (min_recurrence, scan scope, etc.)
```

### Can Dream's Own Rules Be Promoted?

**Yes.** The trigger policy (`dream_trigger_policy`) is L1 knowledge. If it proves stable across many sessions, it can be promoted to L0 via `skills_promote`. The system's knowledge consolidation rules are themselves subject to knowledge consolidation — this is the self-referential closure.

### Meta-Level Classification

- `dream_scan`, `dream_consolidate`, `dream_propose` — **base-level operations** (they act on L2/L1 content)
- `dream_trigger_policy` — **meta-level knowledge** (it governs when base-level operations execute)
- The SkillSet itself — **meta-meta-level** (it defines the capability to have knowledge consolidation)

This three-level structure mirrors KairosChain's ML1/ML2/ML3 framework.

---

## 8. Safety Considerations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Accidental data loss (merge/archive) | High | `dry_run: true` default; blockchain record enables recovery |
| Over-consolidation (merging distinct knowledge) | Medium | LLM judgment + user confirmation; Persona Assembly for complex cases |
| Scan performance on large L2 history | Low | `since` parameter limits scope; structural scan is O(n) in contexts |
| Promotion spam (too many suggestions) | Medium | `min_recurrence` threshold; max proposals per scan configurable |
| Self-referential loop (Dream consolidating Dream's own policy) | Low | Standard L1 modification rules apply; no special-casing needed |

---

## 9. Open Questions

### Q1: Should dream_scan detect semantic similarity, or only structural patterns?

**Tentative answer**: Structural only (tag overlap, name similarity, reference graph). Semantic analysis is delegated to the LLM interpreting scan results. This keeps the tool deterministic and testable.

### Q2: Should archived L1 entries be permanently deleted after N sessions?

**Tentative answer**: No. Archive is soft-delete. Permanent deletion is a separate, manual action. The blockchain record ensures the system remembers that the knowledge existed.

### Q3: Should Dream integrate with Meeting Place (multi-agent knowledge sharing)?

**Tentative answer**: Future extension. Dream could publish consolidation insights to Meeting Place, but this is out of scope for v1.0.

### Q4: Should the trigger policy be L0 from the start?

**Tentative answer**: No. Start as L1 knowledge. It needs to be validated through use before L0 promotion. This follows the system's own graduation principle.

### Q5: How does Dream interact with the Tutorial Mode behavioral gradient?

**Tentative answer**: Tutorial Mode's "suggest L2 save at session end" and "note patterns across sessions" behaviors become concrete invocations of `dream_scan` and `dream_propose`. Tutorial Mode instructions can reference Dream tools instead of describing behavior inline.

---

## 10. Implementation Phases

| Phase | Deliverable | Dependencies | Test Criteria |
|-------|-------------|--------------|---------------|
| **Phase 1** | `dream_scan` (L2 structural scan only) | ContextManager, KnowledgeProvider | Scan 5+ sessions, detect tag recurrence |
| **Phase 2** | `dream_propose` (batch proposal generation) | Phase 1, skills_promote | Generate valid promotion commands from scan results |
| **Phase 3** | `dream_consolidate` (merge/archive/update) | KnowledgeProvider, chain_record | Merge 2 L1 entries with dry_run; verify blockchain record |
| **Phase 4** | `dream_trigger_policy` (L1 knowledge) | Phase 1-3 | Heuristics correctly trigger scan at session start |
| **Phase 5** | Autonomos integration (optional) | Phase 1-2, autonomos | Reflect phase invokes dream_scan when threshold met |

---

## 11. skillset.json (Draft)

```json
{
  "name": "dream",
  "version": "0.1.0",
  "description": "Memory consolidation and knowledge promotion through pattern detection. Scans L2 contexts for recurring patterns, consolidates L1 knowledge (merge/archive/update), and proposes promotions. Inspired by sleep-time memory consolidation but triggered Kairoticly (when patterns mature) rather than chronologically.",
  "author": "Masaomi Hatakeyama",
  "layer": "L1",
  "depends_on": [],
  "provides": [
    "memory_consolidation",
    "pattern_detection",
    "knowledge_hygiene",
    "promotion_discovery"
  ],
  "tool_classes": [
    "KairosMcp::SkillSets::Dream::Tools::DreamScan",
    "KairosMcp::SkillSets::Dream::Tools::DreamConsolidate",
    "KairosMcp::SkillSets::Dream::Tools::DreamPropose"
  ],
  "config_files": ["config/dream.yml"],
  "knowledge_dirs": ["knowledge/dream_trigger_policy"],
  "min_core_version": "2.8.0"
}
```

---

## 12. Relationship to Cursor Rules (Migration Path)

The user's existing Cursor Rules:

```
# L2 → L1 promotion trigger:
# - Same context referenced 3+ times across sessions
# - User says "keep this" / "this is useful"
# - Hypothesis validated through use

# L1 → L0 promotion trigger:
# - Knowledge governs KairosChain's own behavior
# - Mature stable pattern, infrequently changed
```

These rules become the initial content of `dream_trigger_policy` (L1 knowledge). After Dream SkillSet is deployed:

1. Cursor Rules can reference Dream tools: "Use `dream_scan` at session start"
2. Claude Tutorial Mode can invoke Dream tools instead of describing behavior inline
3. The trigger rules themselves live in KairosChain and are tool-agnostic
4. Eventually, Cursor Rules for promotion become unnecessary (Dream handles it)

---

*Generated: 2026-03-27 by Claude Opus 4.6*
*Review status: Awaiting Multi-LLM review (R1)*
