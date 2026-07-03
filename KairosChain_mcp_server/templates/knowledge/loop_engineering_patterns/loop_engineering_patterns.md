---
name: loop_engineering_patterns
description: Use before designing or classifying an agent loop in KairosChain — to pick a loop type, apply loop-design craft, and place each loop at the right layer under the Prop 10 floor. Claude Code's four loop types + design principles, extended with the governance constraint Anthropic omits.
version: "0.3"
tags: [loops, agent, autonomy, taxonomy, layer-placement, provenance]
---

# Loop Engineering Patterns

Distilled from Claude Code's post [Getting Started with Loops](https://claude.com/blog/getting-started-with-loops) (Anthropic, 2026). Local provenance / facts index: `references/claude_code_loops_2026.md` (pointer; canonical text is the URL, not redistributed here). Sibling method: [[skill_authoring_patterns]] — same distill-an-Anthropic-post-through-KairosChain-layers move.

## When to reference this entry
Open *before* designing or classifying an agent loop — not a runtime tool:
- New agent loop / autonomous cycle → pick a §A type, apply §B craft, then place it via §C.
- "Which layer owns this loop?" (harness vs gem/SkillSet, plus the cross-cutting L0 governance floor) → §C table + the L0 note below it.
- Strengthening the `agent` OODA loop (self-verification, semantic stop) → §B + §C evaluator/verifier notes.
- Explaining why KairosChain's autonomous mode keeps human checkpoints → §C Prop 10 floor.
- Not for: skill lifecycle/maturation → [[agent_skill_evolution_guide]]; general layer rules → [[layer_placement_guide]].

## A. Four loop types (base-level classification)
Two axes generate the four types: **trigger** (user prompt / goal spec / schedule-or-event) and **human presence** (present / absent). The autonomous type is the no-human variant of the schedule/event trigger, not a fourth independent trigger — kept as a peer type here to mirror the source taxonomy.
1. **Turn-driven** — trigger: user prompt; stop: task done or needs context; for short exploratory work.
2. **Goal-driven** — trigger: goal spec (`/goal`); stop: goal met OR max turns; a separate evaluator checking exit criteria raises reliability; for tasks with verifiable exit.
3. **Time-driven** — trigger: schedule/interval (`/loop`, `/schedule`); stop: user cancels or work done; for recurring work / external monitoring.
4. **Autonomous** — trigger: events/schedule, no human present; stop: each task exits on goal, routine runs until disabled; for well-defined recurring streams (triage, migrations).

Micro (small) and macro (broad) loops compose; match loop complexity to problem abstraction.

## B. Design craft (universal — adopt as-is)
Output quality tracks the surrounding harness, not the model alone. Keep the codebase clean so the loop follows existing patterns. **Encode verification as a skill with quantitative checks** so the loop measures its own work. Keep docs accessible/current. **Use a second, independent agent for review** (fresh context, separate session/model). Set explicit success/stop criteria and max-turn caps to bound cost; script deterministic steps instead of re-reasoning them; monitor token spend.

## C. KairosChain reading (layer placement + the floor Anthropic omits)
The four types are harness-framed (`/goal`, `/loop`, `/schedule`, `/usage`, auto mode are Claude Code mechanisms). KairosChain already implements most of the substance across layers — so the work is mostly *placement*, not adoption; one item is still design-stage (flagged in the table):

| Type | KairosChain home | Existing mechanism (status) |
|---|---|---|
| Turn-driven | harness (Claude Code) | interactive session (shipped) |
| Goal-driven | gem / SkillSet | `agent` OODA loop with explicit goal + max-step cap; goal-satisfaction judged from reflect-phase confidence/remaining, human-mediated stop (shipped). The *wired* auto-exit on confidence is the Autonomous row's Gate 7, not this path. |
| Time-driven | harness / gem | harness: `/loop`, `/schedule`, ScheduleWakeup/Cron (shipped, harness-layer); gem: routines × autonomous-growth (design, not yet shipped) |
| Autonomous | gem | `autonomos_cycle`/`loop`, `autoexec`, and the `agent` autonomous path — whose Gate 7 confidence early-exit (`confidence_exit_threshold`, wired in `agent_step.rb`) terminates on goal satisfaction (shipped) |

**L0 (cross-cutting, not a per-type home):** the Prop 10 procedural floor binds every row — it is a governance constraint over all four types, not a home for any one. See the paragraph below.

The article's craft maps onto existing mechanisms (illustratively, not as strict 1:1 equivalences): its "separate evaluator" for goal-driven ≈ the agent's reflect-phase confidence evaluation (Observe/Reflect), not `multi_llm_review`; "verification as skill" ≈ `introspection_check` / `definition_verify`; "second agent for review" ≈ `multi_llm_review` (independent session). These pre-exist; they are not new imports.

**The governance floor Anthropic omits.** Every article loop optimizes for completion/throughput; none carries a consent/audit constraint. KairosChain adds a cross-cutting axis: **every loop, whatever its type, is bound by the Prop 10 procedural floor** — no loop may bypass consent, harm protection, or audit, and any autonomous norm must stay recordable and contestable. (Prop 10 is currently provisional/inline in masa mode, not yet promoted to L0; the floor it names is nonetheless the intended binding.) Concretely, the autonomous type's "run until disabled, no human present" cannot be adopted verbatim: KairosChain's autonomous loop carries human checkpoints and safety gates (the `agent` skill), and a stop is not a bare exit but a constitutively recorded Kairos moment (Prop 5). This floor is the KairosChain-specific delta — the article has no place for it because a weight-hosted assistant has no revisable governance surface. Consistent with (not proof of) masa mode's harness-as-cultivation-surface bet in [[skill_authoring_patterns]] §C.

## Related
[[skill_authoring_patterns]] · [[layer_placement_guide]] · [[agent_skill_evolution_guide]] (instance-local, not gem-bundled) · [[kairoschain_self_development]] · kairoschain_meta_philosophy (Prop 5 constitutive recording). Prop 10 procedural floor: current authoritative home is masa mode § Proposition 10 (inline, provisional); migration into L1/L0 is pending.
