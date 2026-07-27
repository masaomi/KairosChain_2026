---
title: Instance Session Protocol
description: Procedural runbook for an instance's session lifecycle — mandatory session-start tool calls, layer-state surfacing, continuity check, knowledge-gap baseline, during-work tool discipline, and session-end handoff. Retrieved on demand by an instruction mode; contains no normative content.
version: "0.1.0"
tags:
  - session
  - runbook
  - layer_awareness
  - tool_usage
  - continuity
---

# Instance Session Protocol

## What this is

The procedural half of an instance's operating discipline: *what to call, in what
order, and what to report*. It was extracted from the `masa` instruction mode so
that the mode carries only norms and this runbook loads on demand.

**This entry contains no norms.** Why an instance should establish ground state,
what it owes the operator in disclosure, and how it weighs speed against
deliberation all remain in the active instruction mode. If the two ever conflict,
the mode wins and this runbook is the thing that gets revised.

An instruction mode adopts this protocol by referring to it. A mode that wants a
different lifecycle should write its own runbook rather than edit this one.

---

## 1. Session start

Execute proactively, before responding to the operator's first task. The goal is
shared ground state, not a diagnostic dump: **report in 4–6 lines total, naming
issues only if found.**

### 1.1 Required tool calls

1. `chain_status()` — verify system health: blockchain integrity, layer counts,
   last known good state.
2. `resource_read(uri: "l0://kairos.md")` — load the propositions into working
   context. They ground every other decision in the session.
3. `knowledge_get(name: "kairoschain_self_development")` — load the development
   workflow, when the session works on KairosChain itself.
4. `skills_audit(command: "check", layer: "L1")` — verify knowledge-layer health
   and surface drift.

**Why step 4 is scoped to L1 deliberately**: L2 contexts are a growing record, so
age is their normal condition rather than a defect. An unscoped audit reports
every context older than 14 days as an issue, and the response outgrows the tool's
own output limit. When L2 needs attention, ask a *state* question — which handoffs
are still `pending`? — not an age question.

### 1.2 Layer state surface

After the calls, surface the operational layer state in 3–5 lines:

- Which host features are active this session (hooks, permissions, plugin
  projection, Skill tool, MCP transport).
- Which MCP server is connected, and its version.
- How plugin projection has mapped SkillSets to host artefacts — digest from
  `projection_manifest.json`.
- Any layer-specific constraint in effect: read-only mode, dry-run mode,
  suspended skills.

Supplying this is the harness's job, not something the model can obtain by
introspection. An agent cannot reliably determine which layer it is operating in
from the inside; the surface exists so that boundary crossings become reasoned
rather than accidental.

### 1.3 Continuity

If recent L2 contexts indicate work this session might continue — handoffs tagged
`pending`, unresolved revision candidates, paused review cycles — name them
briefly and offer to resume. **Do not auto-resume.**

### 1.4 Knowledge-gap baseline

Check the baseline entries in § 3 against what the instance actually has. Report
gaps only when they bear on the current task.

### 1.5 Failure mode

If any required call fails, surface the failure immediately and pause
non-essential work. A session whose ground state cannot be confirmed must not
proceed to autonomous tasks. (Autonomous behaviour lives in dedicated SkillSets
and is out of scope here.)

---

## 2. During work and at session end

Treat KairosChain tools as primary working memory: retrieve before generating.

### 2.1 During work

- **Before answering**: check L1 for a relevant convention. When one applies, say
  so — "applying your saved convention X here" — rather than applying it silently.
- **Multi-LLM review**: follow `multi_llm_review_workflow`.
- **Design work**: prototype while designing; checkpoint the evolution of the
  design, not only its conclusion.
- **Steady state**: when system health is good, say so. Do not report only
  problems.

### 2.2 Session end (with operator consent)

- Offer `context_save()`.
- Extract reusable patterns; propose L1 promotion for recurring ones.
- When the session included design or philosophical work, save the reasoning
  process, not only the conclusion.

### 2.3 Transparency

When invoking tools proactively, briefly state what was done and why. Never use a
tool silently and leave its result unsurfaced.

---

## 3. Knowledge baseline

Entries an instance is expected to have available:

| Entry | Status |
|---|---|
| `multi_llm_review_workflow` | available |
| `multi_llm_reviewer_evaluation` | available |
| `design_to_implementation_workflow` | available |
| `hestiachain_meeting_place` | available |
| `kairoschain_development_pitfalls` | available |
| `skillset_implementation_quality_guide` | **not retrievable** — ships only under the dev-repo `knowledge/`, which is absent from the gem |
| `kairoschain_meta_philosophy` | **not retrievable** — same cause |

The two unreachable entries are a known packaging consequence documented in
`kairoschain_development_pitfalls` § 1. Do not report them as instance-local gaps
to be authored: the content exists, its distribution path does not. Report them as
gaps only if a session needs their content, in which case read the file directly
from the dev repo.

`multi_llm_design_review` appears in older mode text as a baseline entry. No such
entry exists; the correct name is `multi_llm_review_workflow`.

### Behaviour on a genuine gap

- Propose creating the missing entry, with a draft outline.
- Cross-instance, opt-in only: publish knowledge needs via
  `meeting_publish_needs(opt_in: true)`.

---

## Maintenance

When a step here stops matching what an instance actually does, change this file
rather than adding a local exception in the instruction mode. The mode's job is to
say what the instance owes; this file's job is to say how the instance discharges
it, and it is expected to churn faster than the mode.
