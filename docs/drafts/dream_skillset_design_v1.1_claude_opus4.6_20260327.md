# Dream SkillSet Design Draft v1.1

**Date**: 2026-03-27
**Author**: Masaomi Hatakeyama (design intent) + Claude Opus 4.6 (primary designer)
**Status**: Draft v1.1 — revised after R1 Multi-LLM review
**Scope**: New L1 SkillSet for memory consolidation and knowledge promotion

---

## Changes from v1.0

| Change | Reason | Reviewer |
|--------|--------|----------|
| **3 tools → 2 tools**: Removed `dream_consolidate` | Overlaps with `skills_audit` archive and `KnowledgeProvider` update. Dream should discover, not duplicate write operations | codex_gpt5.4 (P0), claude_team_opus4.6 (P1 #3) |
| **`dream_propose` output**: Emits `knowledge_update` commands, not `skills_promote` | `skills_promote` is one-source-one-target; Dream synthesizes many-to-one. Use `knowledge_update(action: "create")` for new L1 entries | codex_gpt5.4 (P0) |
| **Scan recording**: Only record scans with non-empty results | Empty scans are non-constitutive; recording them degrades signal quality | codex_gpt5.4 (P1) |
| **`since` parameter**: session_id-based only | Mixed ISO8601/session_id was underspecified | codex_gpt5.4 (P1) |
| **Archive path**: `.archived/` (not `knowledge/_archived/`) | Match existing `KnowledgeProvider` semantics | codex_gpt5.4 (P1) |
| **Reference graph**: Removed from v1 scan signals | No first-class citation graph exists; add in future version | codex_gpt5.4 (P1) |
| **Added `dream_status` tool concept** | Lightweight check before triggering full scan | claude_team_opus4.6 (Additional) |
| **Tag query strategy**: Specified explicitly | `ContextManager` has no tag index; scanner walks frontmatter | claude_team_opus4.6 (P1 #1) |
| **Merge content strategy**: LLM provides `content` param | Tool handles file ops + chain recording; LLM handles synthesis | claude_team_opus4.6 (P1 #2) |
| **Name similarity**: Jaccard on tokenized names, not Levenshtein | Levenshtein is fragile for reordered tokens | claude_team_opus4.6 (Q1) |
| **Autonomos integration**: Runtime detection, no code patch | Dream hooks via SkillSet detection, not `reflector.rb` patch | codex_gpt5.4 (P2), claude_team_opus4.6 (P2 #4) |

---

## 0. Design Intent & Philosophical Motivation

*(Unchanged from v1.0 — see Section 0 of v1.0 for full text)*

The system that **defines how knowledge evolves** cannot currently **describe its own knowledge evolution rules** within its own framework. Dream closes this self-referential gap by making promotion discovery a SkillSet capability.

**v1.1 scope refinement**: Dream v1 focuses exclusively on **discovery and proposal**. All write operations (promotion, archive, merge) are delegated to existing tools (`knowledge_update`, `skills_promote`, `skills_audit`). This avoids creating a second knowledge-maintenance surface.

---

## 1. Architecture Overview (v1.1)

```
                    ┌───────────────────────────────────┐
                    │       Dream SkillSet (L1)         │
                    │                                   │
                    │  dream_scan ──► dream_propose     │
                    │       │              │            │
                    │       │              ▼            │
                    │       │     knowledge_update      │
                    │       │     skills_promote        │
                    │       │     skills_audit          │
                    │       │     (existing tools)      │
                    │       │                           │
                    │       ▼                           │
                    │  chain_record                     │
                    │  (findings-only)                  │
                    └──────────┬────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        Session Start    Autonomos         Manual
        (LLM decision)  Reflect Phase     Invocation
```

### Dependency Graph

```
dream (new)
├── depends_on: [] (no hard dependencies)
├── integrates_with: autonomos (optional, runtime-detected)
├── delegates_to:
│   ├── knowledge_update (L1 entry creation/update)
│   ├── skills_promote (L2→L1 single-source promotion)
│   └── skills_audit (archive, health check)
├── reads: context_manager (L2 scanning)
├── reads: knowledge_provider (L1 scanning)
└── writes: chain_record (scan findings only)
```

### Key Design Decision: Read-Heavy, Write-Light

Dream is primarily a **read tool** that produces **actionable recommendations**. It does not own any write semantics. This avoids:

- Duplicating `KnowledgeProvider.archive` / `skills_audit` archive logic
- Creating a second policy surface for L1 modifications
- Conflating discovery (Dream's job) with execution (existing tools' job)

---

## 2. Tool Specifications

### 2.1 dream_scan

**Purpose**: Scan L2 contexts and L1 knowledge, detect patterns and consolidation opportunities.

**When to use**: Session start, or when explicitly asked to review accumulated knowledge.

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `scope` | string | No | `"l2"` (default), `"l1"`, `"all"` — what to scan |
| `since_session` | string | No | Session ID — scan from this session onward (default: all) |
| `min_recurrence` | integer | No | Minimum times a pattern must appear across distinct sessions (default: 3) |
| `max_candidates` | integer | No | Maximum candidates to return per category (default: 5) |

**Scan Signals** (v1 — structural only):

| Signal | Method | Strength |
|--------|--------|----------|
| Tag co-occurrence | Count tag sets appearing in N+ distinct sessions | **Primary** (authoritative) |
| Name token overlap | Jaccard similarity on `_`-tokenized names | Advisory (hint only) |
| Cross-session recurrence | Same context name/pattern in N+ sessions | **Primary** |
| Staleness | L1 entries not referenced in recent L2 contexts | **Primary** |

**Dropped from v1** (no first-class support yet):
- Reference graph (no citation/link graph in parser)
- Semantic similarity (delegated to LLM interpretation)

**Tag Query Implementation**:

`ContextManager` does not expose a tag index. The scanner:
1. Calls `ContextManager#list_sessions` to enumerate sessions
2. For each session, calls `list_contexts_in_session` to get context entries
3. Parses YAML frontmatter to extract `tags` field
4. Builds an in-memory tag frequency index per scan invocation
5. **No persistent cache** in v1 — full scan is O(sessions × contexts), acceptable for < 1000 contexts

If performance becomes an issue, a tag index cache in `.kairos/dream/tag_index.json` can be added in v2.

**Output**: Structured scan report:

```yaml
scan_result:
  scanned:
    l2_sessions: 12
    l2_contexts: 34
    l1_entries: 8
    scan_duration_ms: 450

  promotion_candidates:    # L2 patterns ready for L1
    - name: "debug_workflow_pattern"
      evidence:
        - session: "session_20260315_..."
          context: "debugging_rails_api"
          tags: [debugging, rails, api]
        - session: "session_20260320_..."
          context: "fix_auth_endpoint"
          tags: [debugging, rails, auth]
        - session: "session_20260325_..."
          context: "resolve_pg_timeout"
          tags: [debugging, rails, postgres]
      distinct_sessions: 3
      common_tags: [debugging, rails]
      signal_type: "tag_cooccurrence"
      confidence: "high"

  consolidation_candidates:  # L1 entries that may need attention
    - type: "overlap"
      entries: ["skillset_quality_guide", "implementation_checklist"]
      common_tags: [implementation, quality]
      jaccard_similarity: 0.67
      signal_type: "name_token_overlap"
      recommended_action: "skills_audit(command: 'check')"

    - type: "stale"
      entry: "old_deployment_config"
      last_referenced_session: "session_20260201_..."
      sessions_since_reference: 15
      recommended_action: "skills_audit(command: 'archive', ...)"

  health_summary:
    total_l2: 34
    total_l1: 8
    promotion_ready: 2
    consolidation_needed: 1
    stale: 1
```

**Blockchain recording**: Only when `promotion_candidates` or `consolidation_candidates` is non-empty. Record type: `dream_scan_findings`. Empty scans are not recorded.

### 2.2 dream_propose

**Purpose**: Generate actionable promotion proposals from scan results. Package many-to-one L2→L1 synthesis for user review.

**When to use**: After reviewing `dream_scan` results, to create concrete next-step commands.

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `candidates` | array[object] | Yes | Promotion candidates (from dream_scan or manual) |
| `content` | string | No | LLM-generated merged content for the new L1 entry |
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

1. **If `content` is provided** (LLM already synthesized): A ready-to-execute `knowledge_update` command:
   ```
   knowledge_update(
     action: "create",
     name: "rails_debugging_patterns",
     content: "...(LLM-provided)...",
     reason: "Dream promotion: Recurring debugging pattern across 3 sessions"
   )
   ```

2. **If `content` is NOT provided**: A synthesis prompt for the LLM to generate content from the source contexts, plus a template `knowledge_update` command to fill in.

3. **Optional Persona Assembly**: If `assembly: true`, generates a `skills_promote(command: "analyze")` template for deeper evaluation.

**Blockchain recording**: Records `dream_proposal` event with candidate list and recommended actions.

**Workflow** (two-pass):

```
Pass 1: dream_scan → LLM reviews findings → selects candidates
Pass 2: dream_propose(candidates, content: LLM_synthesis) → user approves → knowledge_update
```

The two-pass design ensures:
- The LLM sees raw scan data before committing to synthesis
- The user approves both the candidate selection and the synthesized content
- No write operations occur without explicit user consent

---

## 3. Integration with Autonomos OODA Cycle

### Where Dream Fits

| OODA Phase | Dream Integration | Timing |
|------------|-------------------|--------|
| **Orient** | `dream_scan` — review accumulated L2 before planning | Start of cycle |
| **Reflect** | LLM checks scan results against execution outcome | End of cycle |

### Implementation: Runtime Detection (No Code Patch)

Dream does **not** modify `reflector.rb`. Instead:

```ruby
# In Dream's scanner.rb:
def autonomos_available?
  # Runtime detection: check if autonomos SkillSet is loaded
  defined?(KairosMcp::SkillSets::Autonomos)
end

def scan_with_autonomos_context(cycle_id)
  return unless autonomos_available?
  # Load cycle history to inform scan scope
  store = Autonomos::CycleStore.new
  cycle = store.load(cycle_id)
  # Limit scan to sessions related to this goal
  scan(scope: 'l2', since_session: cycle[:first_session_id])
end
```

When autonomos is not installed, Dream works standalone. The existing `Reflector#check_l1_promotion` continues to work independently — Dream supersedes it gradually, not by code removal.

---

## 4. Blockchain Recording (v1.1)

| Event | Record Type | When | Data |
|-------|-------------|------|------|
| Scan with findings | `dream_scan_findings` | Non-empty results only | Scope, candidate count, health summary |
| Scan without findings | *(not recorded)* | — | — |
| Proposal created | `dream_proposal` | Always | Candidate list, recommended actions |
| Promotion executed | *(delegated)* | Via `knowledge_update` | Standard knowledge record |

### Rationale for Selective Recording

A scan that finds nothing confirms the current state but does not reconstitute it (Proposition 5). Only scans that reveal transformation opportunities are constitutive acts worth recording.

---

## 5. Kairotic Trigger Design

*(Unchanged from v1.0)*

### Trigger Heuristics (L1 Knowledge: `dream_trigger_policy`)

```yaml
triggers:
  session_start:
    condition: "last_scan_findings older than 5 sessions"
    action: "dream_scan(scope: 'all')"

  session_end:
    condition: "new L2 contexts created this session >= 2"
    action: "dream_scan(scope: 'l2', since_session: current_session)"

  autonomos_reflect:
    condition: "same goal cycled 3+ times"
    action: "dream_scan(scope: 'l2', since_session: first_cycle_session)"

  user_request:
    condition: "user says 'review knowledge' or similar"
    action: "dream_scan(scope: 'all')"
```

**Note on session start/end**: These triggers remain **LLM-side behavior** (client instructions). Dream does not add hooks for session lifecycle. The trigger policy is guidance for the LLM, not executable automation. Only the `autonomos_reflect` trigger is fully internalized.

---

## 6. Comparison: Dream SkillSet vs. Claude Auto Dream vs. Cursor Rules

*(Unchanged from v1.0)*

| Aspect | Claude Auto Dream | Cursor Rules (current) | Dream SkillSet (proposed) |
|--------|-------------------|------------------------|--------------------------|
| **Scope** | Tool-side memory (.claude/) | Cursor-only rules | KairosChain L1/L2 layers |
| **Trigger** | Idle time (Chronos) | LLM session behavior | Kairos (pattern maturity) |
| **Recording** | None (internal) | None | Blockchain (findings-only) |
| **Evolvability** | Anthropic controls | Manual rule editing | L2→L1→L0 self-evolution |
| **Tool-agnostic** | Claude-only | Cursor-only | Any MCP client |
| **Write operations** | Internal optimization | None | Delegated to existing tools |

---

## 7. Self-Referentiality Assessment

### Can Dream Be Expressed as a SkillSet?

**Yes.** Dream v1.1 is simpler and cleaner:

```
.kairos/skillsets/dream/
├── skillset.json
├── lib/dream/
│   ├── scanner.rb       # L2/L1 structural pattern detection
│   └── proposer.rb      # Proposal packaging
├── tools/
│   ├── dream_scan.rb
│   └── dream_propose.rb
├── knowledge/
│   └── dream_trigger_policy/
│       └── dream_trigger_policy.md
└── config/
    └── dream.yml
```

### Meta-Level Classification

- `dream_scan`, `dream_propose` — **base-level operations** (act on L2/L1 content)
- `dream_trigger_policy` — **meta-level knowledge** (governs when operations execute)
- The SkillSet itself — **meta-meta-level** (defines the capability)

### Relationship to Existing Tools

| Responsibility | Owner | Dream's Role |
|---------------|-------|-------------|
| L2→L1 promotion execution | `skills_promote` | Discovers candidates |
| L1 creation/update | `knowledge_update` | Generates ready-to-execute commands |
| L1 archive/health | `skills_audit` | Recommends actions |
| Blockchain recording | `chain_record` | Records own findings |
| Pattern detection | **Dream (new)** | Primary owner |
| Promotion proposal packaging | **Dream (new)** | Primary owner |

---

## 8. Safety Considerations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Over-promotion (too many suggestions) | Medium | `min_recurrence` threshold; `max_candidates` cap |
| Scan performance on large L2 history | Low | `since_session` limits scope; O(n) acceptable for < 1000 contexts |
| Self-referential loop (Dream scanning Dream's own policy) | Low | Standard L1 rules apply; no special-casing |
| Stale scan data leading to wrong proposals | Low | Two-pass workflow: LLM verifies before proposing |
| Noise in blockchain from frequent scans | Low | Only record non-empty findings (v1.1 change) |

**Note**: Data loss risks from v1.0 are eliminated — Dream v1.1 has no write operations.

---

## 9. Open Questions (Updated)

### Q1: Semantic vs. structural scan — RESOLVED

Structural only for v1. Define structural signals as primary (authoritative) or advisory. Semantic analysis is the LLM's responsibility when interpreting scan results.

### Q2: Permanent deletion — RESOLVED

No. Archive only. Permanent deletion is a separate concern handled by `skills_audit`.

### Q3: Meeting Place integration — DEFERRED

Out of scope for v1. Consider adding `shareable` field to scan output in v2.

### Q4: Trigger policy as L0 — RESOLVED

No. Start as L1. Follow the system's own graduation principle.

### Q5: Tutorial Mode interaction — RESOLVED

Tutorial Mode references Dream as an upgrade path, not a dependency. Migration sequence:
1. Deploy Dream SkillSet
2. Add `dream_trigger_policy` L1 knowledge
3. Update Tutorial Mode to reference Dream tools
4. Remove inline promotion behavior from Tutorial Mode
5. Update Cursor Rules similarly

### Q6 (NEW): Should Dream add a `dream_status` tool?

**Tentative answer**: Not in v1. The LLM can track last scan time in L2 context. If needed, add in v2 as a lightweight check (last scan time, pending candidates, trigger conditions).

### Q7 (NEW): How does `dream_trigger_policy` visibility work?

**Tentative answer**: The policy is bundled in the SkillSet's `knowledge/` directory and auto-registered as L1 knowledge. It is globally visible to the LLM via `knowledge_list`/`knowledge_get`. No special visibility mechanism needed.

---

## 10. Implementation Phases (Revised)

| Phase | Deliverable | Dependencies | Test Criteria |
|-------|-------------|--------------|---------------|
| **Phase 1** | `dream_scan` (L2 tag co-occurrence + staleness) | ContextManager, KnowledgeProvider | Scan 5+ sessions with tagged contexts; detect recurrence of 3+ |
| **Phase 2** | `dream_propose` (proposal packaging) | Phase 1, knowledge_update | Generate valid `knowledge_update` commands from scan results |
| **Phase 3** | `dream_trigger_policy` (L1 knowledge) | Phase 1-2 | Policy loaded by LLM; scan triggered at correct moments |
| **Phase 4** | Autonomos integration (optional) | Phase 1, autonomos | Runtime detection; scope-limited scan during reflect phase |

**Removed**: Phase 3 (dream_consolidate) and Phase 5 (autonomos code patch) from v1.0.

---

## 11. skillset.json (Draft v1.1)

```json
{
  "name": "dream",
  "version": "0.1.0",
  "description": "Memory consolidation discovery through structural pattern detection. Scans L2 contexts for recurring patterns across sessions, identifies stale or overlapping L1 knowledge, and packages promotion proposals for user review. Read-heavy, write-light: all modifications delegated to existing tools (knowledge_update, skills_promote, skills_audit).",
  "author": "Masaomi Hatakeyama",
  "layer": "L1",
  "depends_on": [],
  "provides": [
    "pattern_detection",
    "promotion_discovery",
    "knowledge_health_scan"
  ],
  "tool_classes": [
    "KairosMcp::SkillSets::Dream::Tools::DreamScan",
    "KairosMcp::SkillSets::Dream::Tools::DreamPropose"
  ],
  "config_files": ["config/dream.yml"],
  "knowledge_dirs": ["knowledge/dream_trigger_policy"],
  "min_core_version": "2.8.0"
}
```

---

## 12. Relationship to Cursor Rules (Migration Path)

*(Unchanged from v1.0)*

---

## 13. R1 Review Responses

### claude_team_opus4.6 — APPROVE_WITH_CONCERNS

| Issue | Response |
|-------|----------|
| P1 #1: No L2 tag query API | Scanner walks frontmatter directly. No persistent cache in v1 (Section 2.1) |
| P1 #2: Merge content generation | LLM provides `content` param to `dream_propose` (Section 2.2) |
| P1 #3: propose/consolidate routing | Eliminated by removing `dream_consolidate` |
| P1 #4: Archive reference integrity | Delegated to `skills_audit` which already handles this |
| P2 #4: autonomos code patch | Changed to runtime detection (Section 3) |
| Additional: dream_status | Deferred to v2 (Q6) |
| Additional: scan recording noise | Only record non-empty findings (Section 4) |
| Additional: merge atomicity | N/A — Dream no longer does merges |

### codex_gpt5.4 — REQUEST_CHANGES

| Issue | Response |
|-------|----------|
| P0 #1: propose/promote interface mismatch | `dream_propose` now emits `knowledge_update` commands (Section 2.2) |
| P0 #2: consolidate overlaps with existing tools | `dream_consolidate` removed entirely |
| P1: archive path wrong | Fixed to `.archived/` |
| P1: reference graph nonexistent | Removed from v1 signals |
| P1: session triggers external | Explicitly noted as LLM-side behavior (Section 5) |
| P1: scan recording noisy | Findings-only recording (Section 4) |
| P1: `since` underspecified | Changed to `since_session` (session_id only) |
| P1: `update` command too broad | Removed with `dream_consolidate` |
| P1: trigger policy visibility | Bundled knowledge auto-registered as L1 (Q7) |

---

*Generated: 2026-03-27 by Claude Opus 4.6*
*Review status: v1.1 — R1 issues addressed. Ready for R2 review or implementation.*
