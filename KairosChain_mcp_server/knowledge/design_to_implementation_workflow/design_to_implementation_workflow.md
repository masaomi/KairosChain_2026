---
name: design_to_implementation_workflow
description: "Full-lifecycle workflow for complex features: design review, self-review, implementation review, and final merge gate. Derived from Service Grant + Attestation Nudge experiments."
version: "1.1"
tags:
  - workflow
  - implementation
  - multi-llm
  - design-review
  - methodology
  - self-review
---

# Design-to-Implementation Workflow

## Overview

A structured workflow for implementing complex features (Tier 2+) that maximizes
quality through multiple review checkpoints. Each checkpoint finds categorically
different bugs.

## Full Lifecycle Model (v1.1)

```
┌─────────────────────────────────────────────────────────────┐
│ DESIGN PHASE                                                │
│                                                             │
│  Draft v0.1 ──→ Multi-LLM Review R1 ──→ Fix ──→ v0.2      │
│                 (structural gaps)                           │
│                                                             │
│  v0.2 ──→ Multi-LLM Review R2 ──→ Fix ──→ v0.3            │
│            (fix correctness)                                │
│                                                             │
│  Convergence: 0 FAIL, 2/3+ APPROVE                         │
├─────────────────────────────────────────────────────────────┤
│ IMPLEMENTATION PHASE                                        │
│                                                             │
│  Implement from v0.3 ──→ Tests pass                        │
│                                                             │
│  Self-Review (Agent subagent) ──→ Fix P0/P1                │
│  (race conditions, edge cases, code quality)                │
│                                                             │
│  Tests pass again                                           │
├─────────────────────────────────────────────────────────────┤
│ VERIFICATION PHASE                                          │
│                                                             │
│  Multi-LLM Implementation Review ──→ Fix                   │
│  (missing wiring, fail-open, integration gaps)              │
│                                                             │
│  Final Multi-LLM Review + Persona Assembly                  │
│  (merge gate: 3/3 APPROVE = merge-ready)                   │
└─────────────────────────────────────────────────────────────┘
```

## When to Use This Workflow

| Tier | Scope | Design Review | Self-Review | Impl Review | Final Review |
|------|-------|--------------|-------------|-------------|--------------|
| 1 | Single file, known pattern | Skip | Optional | Skip | Skip |
| 2 | Multi-file, SkillSet feature | 1-2 rounds | Recommended | 1 round | Optional |
| 3 | Cross-component, new subsystem | 2-3 rounds | Required | 1 round | Required |
| 3+ | Security-critical | 2-3 rounds | Required | 1 round | Required + Persona Assembly |

## Phase Details

### Design Phase

#### Solo Design (v0.1)
- Single LLM (Opus-class) produces initial design
- Include: architecture, component design, schema, error handling, phase boundaries
- Output: Complete design document with pseudocode

#### Multi-LLM Review Rounds
- **3 reviewers**: Claude Opus 4.6 + Codex GPT-5.4 + Composer-2
- **Convergence criteria**: 0 FAIL, 2/3+ APPROVE
- **Typical rounds**: 2-3 for Tier 3 complexity
- **Convergence curve**:
  - R1: Structural gaps — "this is missing" (existence)
  - R2: Fix correctness — "the fix is wrong" (accuracy)
  - R3: Refinement — "minor adjustments" (polish)

### Implementation Phase

#### Implementation
- Single Opus-class LLM for context preservation
- Follow design document's phase ordering
- Implement → test within each component before moving to next

#### Self-Review (NEW in v1.1)

Before requesting external multi-LLM review, run a self-review using an Agent subagent:

```
Agent(subagent_type: "general-purpose"):
  "Review [file] for bugs, race conditions, edge cases, 
   test coverage gaps. Categorize as P0/P1/P2."
```

**Why self-review matters**:
- Finds P0 bugs cheaply (no external LLM cost)
- Catches implementation-level issues design review can't see
- Example: P0 race condition in `rebuild_indexes` (unlocked file read) — found by self-review, invisible to design review

**What self-review finds** (confirmed in Attestation Nudge session):
- Race conditions in file I/O patterns
- Index staleness after state transitions
- Missing error recovery paths (corrupted JSON)
- Test coverage gaps for edge cases

### Verification Phase

#### Implementation Review (NEW in v1.1)

After self-review fixes, run full multi-LLM review of the **implemented code** (not design doc):

**Key difference from design review**: Implementation review finds **categorically different bugs**:

| Design Review Finds | Implementation Review Finds |
|--------------------|-----------------------------|
| "This API doesn't exist" | "This method has no call site" |
| "The key model is inconsistent" | "The fail-open path is exploitable" |
| "Session concept is undefined" | "The return type doesn't match the guard" |

**Attestation Nudge data point**:
- Design review: 8 findings across 2 rounds (structural + correctness)
- Implementation review: 5 findings in 1 round (wiring + integration)
- **Zero overlap** between design and implementation findings

#### Final Review + Persona Assembly

For Tier 3+ or pre-merge gates:

```
Claude Persona Assembly (4 personas):
  Kairos    — Philosophical alignment, layer boundaries
  Guardian  — Security, fail-safe behavior, flock correctness
  Pragmatist — Code quality, test coverage, performance
  Skeptic   — What breaks first? Scale? Silent failures?
```

**When to use Persona Assembly**:
- Final merge gate for Tier 3+ features
- Safety-critical components
- NOT for intermediate rounds (diminishing returns)

**Merge criteria**: 3/3 APPROVE with 0 FAIL. Codex APPROVE is the strongest signal (see `multi_llm_reviewer_evaluation`).

## Effort Level Selection

| Phase | Effort | Rationale |
|-------|--------|-----------|
| Design review | High | Maximize gap detection |
| Implementation | Medium | Design is detailed; faithful translation |
| Self-review | Low | Quick Agent pass, fix obvious issues |
| Implementation review | High | Find wiring/integration bugs |
| Final review | High | Merge gate with Persona Assembly |

## Tool Usage During Implementation

| Tool | Purpose | Timing |
|------|---------|--------|
| knowledge_get (L1) | Load domain context | Session start |
| context_save (L2) | Save session progress | Session end / milestone |
| Agent (subagent) | Self-review | After implementation, before external review |

### What NOT to Use During Implementation
- **Autonomos**: Overhead of observe/orient/decide is wasteful when design document
  already serves as roadmap. Save for exploratory phases.
- **autoexec**: Designed for structured JSON step plans, not free-form coding
- **Agent team**: Context fragmentation across agents. Single LLM preserves
  cross-component coherence for tightly-coupled implementations.

## Convergence Data

### Service Grant (Tier 3, 2026-03-18)
- Design: v1.0 → v1.4, 3 review rounds, 3 LLMs
- Design review findings: R1: 8 P0/P1, R2: 2 FAIL + 28 CONCERN, R3: 0 FAIL
- Implementation: Phase 0-3, 2 rounds implementation review
- Total bugs found: 8 (design) + 13 (implementation review) + 2 (during coding)

### Attestation Nudge (Tier 2, 2026-03-28)
- Design: v0.1 → v0.3, 2 review rounds, 3 LLMs
- Self-review: 4 fixes (P0-1 race, P1-4 staleness, P1-6 test gap, P2-2 recovery)
- Implementation review: 3 fixes (missing call site, fail-open attest, escaping)
- Final review (Persona Assembly): 0 FAIL, 3/3 APPROVE
- **Codex convergence**: REJECT → REJECT → REJECT → APPROVE (4 rounds)

## Anti-Patterns

- Implementing Phase 2+ when Phase 1 prerequisites aren't met
- Using agent team for implementation (context fragmentation)
- Skipping self-review (misses cheap P0 fixes)
- Skipping implementation review (design review can't find wiring bugs)
- Treating Codex REJECT as "too strict" without investigating (usually substantive)
- Using Persona Assembly in every round (diminishing returns; save for final gate)
- Implementing without design review for Tier 3 complexity ("just implement it")
