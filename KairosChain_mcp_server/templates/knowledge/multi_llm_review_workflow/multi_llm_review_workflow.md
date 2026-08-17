---
name: multi_llm_review_workflow
description: "Multi-LLM review methodology and execution — workflow pattern, CLI tooling, consensus analysis, Persona Assembly. Applicable to design, implementation, documentation, or any artifact."
version: "3.10.2"
tags:
  - workflow
  - review
  - multi-llm
  - quality
  - process
  - orchestration
  - automation
related:
  - multi_llm_reviewer_evaluation
  - design_to_implementation_workflow
---

# Multi-LLM Review Workflow

## Overview

Multiple independent LLMs review the same artifact, and their findings are compared
and integrated. The user (or primary LLM) acts as orchestrator.

This skill covers:
- **WHAT/WHEN**: When to use multi-LLM review, review types, convergence criteria
- **HOW**: CLI commands, prompt generation, auto/manual execution, consensus analysis

For **WHO** (which LLM is good at what), see: `multi_llm_reviewer_evaluation`
For **development lifecycle** (design → implement → verify), see: `design_to_implementation_workflow`

## Step -1 — Pre-declared review spec (loop hygiene)

> Validation scope: these rules were derived from one non-converging loop
> (multi_llm_review R10–R15, 2026-07) where they took the P0 count from 10 to
> 2 in two rounds and closed the loop in three. They are instance practice
> until reproduced on a second, non-self-referential subject; treat the
> numbers below as one loop's evidence, not a law.

Before dispatching round 1 — and again whenever the review TARGET changes —
write a review spec and declare it frozen for the round:

1. **Pre-declare the pass condition** (per `loop_validation`: spec before
   judgement, fail-closed). State what APPROVE requires. A loop whose target
   drifted (e.g. from an implementation to the instrument that measures it)
   without a re-declared spec is structurally non-converging: a 300-claim
   artifact at any realistic per-claim error rate yields double-digit
   findings every round regardless of quality.
2. **Split target from appendix.** Only the shipping deliverable is
   P0-eligible. Instruments, sweep logs, classification tables are appendix:
   findings against them are advisory and go to the queue. This is what
   collapsed the claim surface from ~350 to ~30.
3. **Cap fixes per round (≤5)** and write one line per fix: *what this fix
   newly claims* (values pinned, ranges narrowed, failure visibility
   changed). A fix that cannot state its new claims is doing more than the
   finding asked.
4. **Pre-flight falsifier.** Before dispatch, one agent whose only job is to
   refute every factual claim in the spec and artifact — especially numbers
   and "X does not exist" claims. In this loop it caught real errors before
   every single dispatch (3 + 1 + 0 refuted across R13–R15); rounds without
   it had returned the same errors as P0s.
5. **Check threshold reachability before dispatching.** Compute the maximum
   achievable approve count from live slots; if the threshold is
   unreachable, declare the exhaustion path up front (the frozen design's
   own closing: findings exhausted → operator freeze declaration) instead of
   discovering it at collect.
6. **Reference originals by path + sha256; do not transcribe.** Reviewers
   read the repository; the artifact carries the manifest. Transcription
   errors are undetectable and 100KB+ pastes rot.

Corollaries observed in the same loop: fix the *class*, and fix every copy —
a corrected lib comment whose refuted twin survives in a test file costs a
full round. When an author writes history into comments, the falsifier must
check the cited records; two of the loop's P0s were numbers copied from the
wrong document.

## Step 0 — Load reviewer characteristics (mandatory)

**Before invoking any reviewer**, fetch `multi_llm_reviewer_evaluation` via
`knowledge_get`. That knowledge contains:

- per-reviewer strengths/weaknesses and verdict biases
- Codex value-system divergence (3 biases) and (a)/(b)/(c) finding classification
- convergence rule and reviewer-specific signal interpretation

Skipping Step 0 leads to misreading reviewer output — in particular, treating
Codex (c)-class value-divergent REJECTs as blocking, which causes review loops to
fail to converge. The cross-reference exists in `related:` frontmatter; this step
makes it an explicit pre-condition rather than an implicit hint.

## Step 0.25 — Unknowns Pass (pre-draft, qualifying reviews only)

> **Numbering vs timing**: Step 0 and Step 0.5 execute at review time,
> immediately before dispatch. Step 0.25 executes **pre-draft** — earlier in
> wall-clock time than both. The numeric order is document order, not
> execution order.

**Applies to** artifacts that this workflow's decision heuristic routes to
full multi-LLM review, in the design-phase and knowledge/documentation
review types (design review, knowledge/documentation-update review, document
review). Throughout this step, "qualifying review" means exactly this set.
Artifacts below that threshold (single-LLM review, self-review, skip) are
exempt — the pass inherits the existing tier heuristic rather than
introducing a second gate. Implementation-phase reviews are out of scope.

The problem this step solves: the workflow otherwise begins at "artifact
exists," so unknowns the author never considered enter drafts undetected and
are excavated by reviewers round by round, inflating round counts. The pass
moves unknown discovery from the expensive channel (review rounds) to the
cheap channel (pre-draft dialogue), and makes the residue explicit.
(Source: Thariq Shihipar, "A Field Guide to Fable: Finding Your Unknowns,"
2026-07-03 — techniques ① blindspot pass and ③ interview. Design record:
`docs/drafts/multi_llm_review_unknowns_pass_v0.3.1_FROZEN.md`.)

### Structure of the pass

Step 0.25 runs after the decision to produce a qualifying artifact and
before its first draft. Two moves, one triage:

1. **Blindspot enumeration.** The orchestrator, holding full project
   context, enumerates the questions most likely to change the design if
   answered differently — *without answering them itself*. This is a bounded
   search discipline, not a completeness guarantee: the pass is judged by
   whether it reliably surfaces the highest-impact questions available to
   the orchestrator's current context (nothing-missed is unachievable per
   Prop 6).
2. **Interview.** The orchestrator puts the enumerated questions to the
   human, one question at a time, ordered by decision impact. The interview
   ends when both parties judge that remaining questions will only be
   answerable once a draft exists. Ending the interview does not discharge
   the triage below: every enumerated unknown — including those the
   interview never reached — still exits through it.

**Triage.** Every surfaced unknown exits the pass in exactly one of two
**terminal** states, possibly via one **transient** state:

- **Resolved** (terminal) — answered by the human; the answer feeds the
  Design Direction Block (Step 0.5).
- **Declared** (terminal) — recorded in the artifact as an *Open Unknown*
  and registered in the artifact's backlog section. A human's explicit
  decision *not* to answer a question is itself a human judgment and routes
  the unknown here — a legitimate attended outcome.
- **Draft-deferred** (transient, non-terminal) — marked for mandatory
  re-triage after drafting. Re-triage collapses each draft-deferred unknown
  into Resolved or Declared **before review dispatch** (a precondition of
  dispatch under INV-U1). INV-U2 applies at re-triage exactly as at the
  interview: collapsing to Resolved requires the human's answer, so
  unattended re-triage can only collapse to Declared.

### Invariants

**INV-U1 (front-load gate).** Round 1 of a qualifying review is not
dispatched for an artifact that has not passed through the Unknowns Pass.
At dispatch time, every unknown the pass surfaced is in a terminal state:
resolved by the human, or declared in the artifact. A draft-deferred unknown
still in its transient state blocks dispatch until re-triaged.

**INV-U2 (human gate).** The answerer in the interview is the human. The
orchestrator posing a question and answering it itself does not constitute
resolution. (Same conceptual line as ACT-1 in L2 attestation — analogical,
not a shared implementation: judgment-shaped decisions belong to the human.)

**INV-U3 (constitutive recording).** The products of the pass — enumerated
questions, human answers, declared Open Unknowns — are recorded to L2. A
discovered unknown is an asset, not a consumable. The record is written
unconditionally: a pass that surfaces no unknowns writes an explicit
zero-result record, which is what makes a skipped pass distinguishable from
a pass that surfaced nothing. The record is instance-local; outbound sharing
is governed by the instance's existing outbound-sharing discipline — this
invariant authorizes no new disclosure surface.

**INV-U4 (declared unknowns are non-blocking — bounded).** A reviewer
finding that merely restates a declared Open Unknown is classified (c)
advisory by default, subject to two bounds:

- *Provenance bound*: the demotion applies only to unknowns whose specific
  declaration a human has seen — declared through an attended pass, or
  ratified by a human at a subsequent attended session. Declarations made by
  an orchestrator alone (including unattended declarations under a mandate's
  category-level pre-classification) carry no demotion power until so
  ratified.
- *Inverted default*: when the orchestrator is uncertain whether a finding
  merely restates a declared unknown or shows that the declared deferral is
  itself unsafe, the finding is treated as blocking. This deliberately
  inverts the usual "unsure between (b) and (c) → (c)" rule, because here
  the doubt concerns whether a gate is being laundered, and gates fail
  closed.

Findings about the *integrity* of the design — internal contradiction,
unrealizable invariant, an Open Unknown whose declared deferral is itself
unsafe — remain (a)/(b) and block as before.

**INV-U5 (classification authority).** The judgment-shaped /
non-judgment-shaped classification of an unknown is a human prerogative.
Attended, the human exercises it through the interview itself (answering,
declining, or judging a question draft-answerable). Unattended, every
surfaced unknown is judgment-shaped by default; only a human-authored
mandate may pre-classify named categories as non-judgment-shaped for a given
run. An orchestrator's self-classification has no force. (Fail-closed:
unclassified ⇒ judgment-shaped ⇒ stop.)

### Unattended execution (autonomous loops)

In an unattended context, the "resolved" exit is unavailable. INV-U2 is
preserved — the system does not self-answer — and INV-U5 governs
classification:

- **Judgment-shaped** (the unattended default for ALL unknowns): fail-closed
  stop; the question is recorded and queued for the next attended session.
- **Non-judgment-shaped** (only via human-authored mandate
  pre-classification): declared as Open Unknown; the run proceeds, but per
  INV-U4's provenance bound the declaration carries no demotion power until
  human-ratified — reviewer restatements remain blocking.

Consequence: an unattended run without a mandate cannot proceed past any
surfaced unknown. This is intended — it makes "unattended design review
without human pre-delegation" structurally inert rather than quietly
self-certifying, and liberal declaring yields no convergence advantage.

Stop semantics, as an invariant: repeated unattended encounters with the
same pending question produce no new side effects and no forward motion —
re-stopping is idempotent; forward motion requires a human answer. The
mandate's expressive power, the ratification protocol, and the
pending-question queue mechanism are owned by the Autonomous Growth Loop
guard track (see the frozen design's §11 backlog).

### Acceptance observation (selective survival)

This step is a discipline under observation, not settled infrastructure.
From adoption onward, during synthesis the orchestrator tags each blocking
finding — and each finding demoted under INV-U4 — as kind `open-question`
(unresolved design decision) or kind `defect` (flaw in a made decision),
recorded in the round's L2 review record. Survival judgment (human's, on
recorded counts): round-1 `open-question` counts should trend toward zero
across the first 2–3 qualifying loops; no INV-U4-demoted finding re-tagged
`defect` within its loop + next revision cycle; interviews staying within
~5 questions.

## Step 0.5 — Design Direction Block (design / docs reviews only)

For **design-phase** and **knowledge/documentation-update** reviews, prepend a
**Design Direction Block** to every reviewer prompt, in addition to the project
philosophy briefing (CLAUDE.md § "Multi-LLM Review Philosophy Briefing"). For
**implementation-phase** reviews this block is optional — implementation review
is correctness-vs-design, where philosophy divergence has limited impact.

### Why this exists

Phase 2 Case A (Context Graph review loop, 4 rounds, 2026-05-04) showed that
a philosophy briefing alone does not shift Codex/Cursor reviewers from REJECT.
What shifted Cursor to APPROVE in round 4 was **briefing + explicit design
direction for this artifact**. Codex remained resistant even with both, but the
(a)/(b)/(c) classification (see `multi_llm_reviewer_evaluation` § Reviewer
Value-System Divergence) makes its REJECTs digestible. The combination —
briefing + direction + classification — is the operational protocol that
prevents review loops from failing to converge over value-system divergence
mistaken for genuine defects.

### Block structure (prepend to every reviewer prompt)

> **Invariant**: the block declares the artifact's intentional scope so reviewers
> can distinguish in-scope critique from out-of-scope expectation. The fields below
> are illustrative facets of that single invariant, not an enumeration of independent
> requirements; omit fields that do not apply to the artifact rather than forcing
> content into every slot.

```
## Design Direction (this artifact)

**Problem this artifact solves**:
- <one or two sentences>

**Problems this artifact does NOT solve** (out of scope):
- <bullet: explicitly excluded scope>
- <bullet: deferred to future design — name the future design if known>

**Rejected alternatives and reasons**:
- Alt A: <one line> — rejected because <reason>
- Alt B: <one line> — rejected because <reason>

**Design tradeoffs adopted**:
- <axis>: chose X over Y because <reason>
  (e.g., "discipline > infrastructure: workflow-level Step 0 hard fetch
   over knowledge-graph auto-load, to avoid premature core change")
- <axis>: chose X over Y because <reason>
  (e.g., "invariant declaration > mechanism enumeration, per project
   design-by-invariant principle")

**Declared Open Unknowns** (carried in from Step 0.25, if any):
- <unknown>: declared open; findings that merely restate it are (c) advisory
  per INV-U4 (subject to its provenance bound and inverted default)

**Where to register additions/objections**:
- New mechanisms or scope expansions → §11 backlog of the artifact, not body
- Style/readability concerns not entailed by project principles → (c)
  value-divergent class, advisory only
```

### How to author each field

- **Problem solved / not solved**: Should match the artifact's actual scope
  declarations. If you can't fill these in cleanly, the artifact's scope is
  unclear — fix that first, then review.
- **Rejected alternatives**: List at least 2. If you have only 1, you have not
  considered the design space; design is not yet review-ready.
- **Tradeoffs**: Name the axis explicitly (X over Y). "We chose X" without an
  alternative axis is a position, not a tradeoff.

### Effect on reviewer instruction

After the block, instruct reviewers:

> Evaluate against the Design Direction above. Findings inconsistent with the
> declared scope, rejected alternatives, or tradeoffs are (c) value-divergent
> by default — record as advisory, not blocking. Findings about the *integrity*
> of the design (internal contradiction, unrealizable invariant, scope
> inconsistency) remain (a) deployment-grounded or (b) philosophy-aligned.

### Scope of this step

- Design-phase review: **mandatory**
- Knowledge / documentation update review: **mandatory** (treated as design)
- Implementation-phase review: optional — use only when implementation makes
  significant design choices not fixed by the design artifact

## Two Execution Paths (read this first)

There are **two distinct execution paths** with the same name "multi-LLM review".
They differ in subprocess lifecycle ownership and completion-detection mechanics.
Pick the right one for your environment:

### Path A — Host-tracked (Bash workflow)

- **Trigger**: orchestrator (LLM) calls Claude Code's `Bash` tool with
  `run_in_background: true` to spawn `claude -p`, `codex exec`, `agent -p` directly.
- **Process parent**: Claude Code (the host harness).
- **Completion detection**: **event-driven**. Claude Code's shell tracker monitors
  the spawned shells; when they exit, the LLM is notified through the standard
  tool-result mechanism. Statusbar shows `XX shells` while reviewers are running.
- **When to use**: interactive Claude Code sessions for one-off Tier 3 reviews.
- **Reference**: see "Orchestration Template" section below for the canonical
  `Bash(background)` pattern.

### Path B — MCP-managed (multi_llm_review SkillSet)

- **Trigger**: orchestrator calls the MCP tool `multi_llm_review`.
- **Process parent**: the kairos-chain Ruby gem (MCP server). The gem forks a
  detached worker (`bin/dispatch_worker.rb`) which calls `Process.setsid` and
  spawns CLI reviewers as a separate session leader.
- **Completion detection**: **polling required**. Claude Code is not the parent,
  so the spawned subprocesses do NOT appear in the `XX shells` statusbar count.
  The orchestrator must call `multi_llm_review_collect` (and optionally
  `multi_llm_review_wait` first) to observe completion.
- **When to use**: portable execution (other MCP hosts, autonomous Agent SkillSet),
  or any case where you want the consensus computation done server-side.
- **Recommended chain (3-step)**: `multi_llm_review` → `multi_llm_review_wait` →
  `multi_llm_review_collect`. Each Phase-1/1.5 response carries a `next_action`
  hint pointing at the next tool. wait is optional but recommended — without it,
  collect's internal polling still covers worker completion, but recovery hints
  for `still_pending`, `crashed`, and `past_collect_deadline` are less explicit.
- **Reference**: see "Orchestrator Delegation Protocol" + "Async/Parallel Collect
  Timing — Iron Rule" sections below.

### Quick selector

| Question | Answer |
|----------|--------|
| **Default**: Is the `multi_llm_review` MCP tool available? | **Path B** (roster from config, orchestrator exclusion automatic) |
| MCP tool unavailable or user explicitly requests manual execution? | **Path A** (fallback — roster construction is the orchestrator's responsibility) |
| Do you need this to work in Cursor / autonomous mode / other MCP host? | **Path B** |
| Do you want the consensus result inside the MCP tool response? | **Path B** |
| Did you observe `XX shells` in the statusbar last time it worked? | That was Path A |
| Did the run produce a `collect_token` and a `pending/<token>/` directory? | That was Path B |

**Why Path B is the default**: Path A delegates roster construction to the
orchestrating LLM, which must correctly extract reviewer count, model assignments,
orchestrator exclusion rules, and convergence thresholds from this skill and
`multi_llm_reviewer_evaluation`. Empirically, LLMs misread these parameters —
e.g., confusing "exclude orchestrator from subprocess" with "exclude orchestrator
model from all reviewers" (the Agent Team Personas are *designed* to use the
orchestrator's own model for persona diversity). Path B enforces the correct
configuration from `config/multi_llm_review.yml`, eliminating this error class.

### Pre-flight checklist (Path A only)

If Path B is unavailable and you must use Path A, extract these values **before
starting** and verify each against `config/multi_llm_review.yml`. The config is
canonical; the numbers written below are a cross-check, not a substitute — when
they disagree, the config is right and this section is stale.

```
- [ ] Your model (orchestrator): ___
- [ ] Agent Team Personas model: = orchestrator model (NOT a different model),
      unless you are running personas on a different model on purpose — then
      it is whatever you declare as persona_model (see § Persona execution model)
- [ ] Subprocess CLI model: Opus 4.6. The other Claude roster slot is Opus 5,
      which under the default "delegate" strategy is taken by your persona team
      rather than spawned — so when you are Opus 5, Opus 4.6 is the only Claude
      CLI subprocess
- [ ] Codex models: gpt-5.6-sol AND gpt-5.5 (both, not either/or), each with -m
- [ ] Cursor model: composer-2.5, passed explicitly as --model composer-2.5
- [ ] Total reviewer count: 5 (or 4 after orchestrator exclusion from subprocess)
- [ ] Closing condition: new (a)+(b) P0 = 0, with carryover P0s counted
      separately and a closure verdict on each. The APPROVE ratio the tool
      reports (3/5 full roster, 3/4 after exclusion) is a reference value,
      not the condition — see § Convergence Rules
```

**Every slot names its model on the command line (INV-E5).** A reviewer launched
without an explicit model flag inherits the external CLI's own default, which
lives outside this repository and is user-editable. This is not hypothetical:
on 2026-07-27 the cursor slot had no pinned model, `~/.cursor/cli-config.json`
had been changed to `claude-opus-4-8`, and the roster ran three Anthropic slots
out of five while still recording the answer as `cursor_composer2.5`. Provider
diversity was silently lost and the record named a model that had not answered.
Path B refuses such a slot outright; on Path A nothing refuses it but you.

### Common mistakes (Path A)

| Mistake | Correct behavior | Why it happens |
|---------|-----------------|----------------|
| Launch a reviewer without an explicit model flag | Always pass `--model` / `-m`. A slot with no flag takes the CLI's user-editable default | "The default is the one we want" — it was, until someone changed it outside this repo |
| Exclude orchestrator model from Agent Team Personas | Agent Team uses orchestrator model — they provide persona diversity, not epistemic diversity | LLM misreads "do not assign yourself as a reviewer" as applying to Agent Team; it applies only to subprocess CLI |
| Run only Codex GPT-5.6-sol, skip 5.5 | Run both — cross-generation entries catch different things (5.5 found §5 schema contradiction in Phase 2 Case A that no other reviewer caught) | Cost-saving heuristic; roster has both for a reason |
| Use a smaller/cheaper model as Agent Team substitute | Use the orchestrator's own model with different personas | Confusing "model diversity" with "persona diversity" — Agent Team is the latter |
| Run 3 reviewers instead of the configured roster | Use the full roster from config | Ad-hoc "3 is enough" reasoning; the roster size is empirical |
| Count a reply that carries only a verdict | Drop it from the denominator, and say why | A bare "APPROVE" looks like agreement and raises the bar for everyone else without contributing (see § Substance and the denominator) |

## Roles

| Role | Who | Responsibility |
|------|-----|---------------|
| **Designer/Implementer** | Primary LLM (single instance) | Design, implement, synthesize reviews, produce fix plans |
| **Reviewers** | N independent LLMs (N >= 2) | Independent multi-perspective review |
| **Orchestrator** | User or primary LLM | Route prompts, collect results, trigger next phase |

## When to Use

### Use multi-LLM review when:
- Security-critical: access control, authentication, billing, cryptography
- Cross-component: modifications touching 3+ SkillSets or core hooks
- Tier 3+ complexity: architectural redesign, new subsystem
- High seam risk: designs that depend on existing codebase APIs
- Important documents: grant applications, papers, specifications

### Use single-LLM review when:
- Tier 1-2: new feature within existing pattern, single SkillSet
- Self-contained: minimal cross-component dependencies
- Well-understood: implementation path is clear

### Skip review when:
- Typo fixes, comment updates, formatting changes
- Development-only changes (test fixtures, dev scripts)

### Decision heuristic:
```
Security, identity, or money involved?
  YES → full multi-LLM review
  NO  → Crosses SkillSet boundaries or modifies core hooks?
    YES → full multi-LLM review
    NO  → New domain logic (> 100 lines)?
      YES → single-LLM review (1 round)
      NO  → skip or self-review
```

The user always has the final say.

## Workflow Pattern

```
[0.25] Unknowns Pass (pre-draft; qualifying reviews only — see Step 0.25)
         |
         ├── blindspot enumeration + human interview
         └── L2 context:    pass record (unconditional, incl. zero-result)
         |
[1] Primary LLM creates artifact → outputs artifact + review prompt
         |
         ├── artifact:      log/{name}_{llm}_{date}.md
         ├── re-triage:     draft-deferred unknowns → Resolved or Declared
         ├── review prompt: log/{name}_review_prompt.md
         └── L2 context:    saved via context_save
         |
[2] Orchestrator sends prompt → N reviewer LLMs execute in parallel
    (for qualifying reviews, conditioned on INV-U1: pass record exists
     and every surfaced unknown is terminal)
         |
         ├── Reviewer 1:   independent review
         ├── Reviewer 2:   independent review
         └── Reviewer N:   independent review
         |
[3] Orchestrator collects → primary LLM reads + synthesizes
         |
         ├── reads:    log/{name}_review{R}_{reviewer}_{date}.md  (×N)
         ├── outputs:  revised artifact + new review prompt
         └── L2 save:  consensus + revised artifact
         |
[4] Classify findings as (a)/(b)/(c) per `multi_llm_reviewer_evaluation`
    Apply INV-U4: findings merely restating a declared Open Unknown → (c)
    advisory (provenance bound + inverted default apply — see Step 0.25)
    Tag each blocking finding and each INV-U4-demoted finding as kind
    `open-question` or `defect` in the round's L2 record
    If no (a)/(b) blocking findings → proceed to next phase
    If any (a)/(b) finding          → repeat from [2] with revised artifact
    (the revision obeys § Revision Discipline below)
    (c) findings are recorded as advisory; non-blocking
```

## Revision Discipline (between rounds)

> Evidence base: 35 recorded runs across 8 threads, 2026-08-03 → 08-06
> (tokens in `.kairos/multi_llm_review/pending/`), two of which ran to
> convergence. Same validation caveat as Step -1: a strong regularity in one
> instance's logs, not yet reproduced elsewhere. Analysis record: L2
> `mlr_p0_inflation_analysis_and_opus46_no_verdict_diagnosis_20260806`.

The strongest predictor of round N+1's raw P0 count in those logs is whether
the round-N revision **added mechanism** to the artifact — not the artifact's
size, not reviewer strictness:

- chain_history_erasure v0.5 added two invariants and a recount section
  (draft 9.3k → 19.1k chars): raw P0 went 13 → 38, and 17 of the 38 targeted
  the added or rewritten sections. v0.8, similar in size (18.6k) but authored
  under an explicit "no new mechanism" rule, closed at 13 with one external
  slot finding zero P0s.
- mlr_evidence_fix R1's fix added four unrequested defensive mechanisms; R2
  returned 41 findings, nearly all of them defects inside the additions. All
  four mechanisms were later removed, each for a measured reason.
- Deletions never generated findings: chain erasure v0.7 deleted three
  mechanisms — zero new P0s against the deletions, confirmed in writing by
  three slots.
- Each thread converged within 1–2 rounds of switching to subtractive
  revisions; neither converged while revisions were additive.

Rules:

1. **A revision closes findings by deletion, correction, or naming — never by
   default-adding.** New mechanisms, invariants, sections, or defensive
   layers do not enter a revision unprompted. If a finding appears to require
   new mechanism, put the question to the operator ("finding X seems to need
   mechanism Y — add, defer to backlog, or drop?") before drafting it in.
   Explanatory prose is a lighter form of the same risk: a sentence added
   only to justify a retreat became the sole blocking finding of the round
   that followed it (mlr_evidence R6 — "adding an explanation creates a new
   claim").
2. **Prefer a revision author that is not the model whose additions are under
   review.** This extends the existing separation principle — the deciding
   context never authors what judges it — from verification to revision.
   Opus 5 has a measured additive propensity (scope-broadening; the v0.5
   explosion above), but the model is the pressure, not the cause: Fable 5
   also added-and-broke (v0.6's fsync/realpath additions, v0.7's predicate 4
   — a fatal genesis-rejecting defect) until the subtractive rule was
   imposed, and Opus 5 converged mlr_evidence once its revisions became
   subtractive (retreat + removal). Combine both levers: the subtractive
   rule always, a different-model reviser when available.

## Review Types

| Type | Focus | Reviewers See | Typical Use |
|------|-------|--------------|-------------|
| Design review | Architecture, enforcement paths, threat model | Design document | Before implementation |
| Implementation review | Code correctness, security, wiring, test coverage | Full source code | After implementation |
| Fix plan review | Completeness, correctness, prioritization | Fix plan with proposed code | After review findings |
| Document review | Accuracy, completeness, consistency | Document text | Grant applications, papers |
| Final/convergence review | All prior findings resolved, no new issues | Resolution matrix + revised artifact | Before merge |

## LLM Role Differentiation

Without explicit instruction, different LLMs naturally focus on different verification layers:

| Layer | Description | Example Findings |
|-------|-------------|-----------------|
| **Structural/Architectural** | System-level integrity, component relationships | Thread safety, load-order dependency |
| **Design-Implementation Seam** | Whether designed APIs actually exist in the codebase | Missing hook API, non-existent method, wrong return type |
| **Safety Defaults** | Fail-closed behavior, input validation | Fail-open on nil, missing charset validation |

**Key insight**: The "design-implementation seam" is the most valuable layer and most
likely to be missed by a single LLM reviewing its own design. For per-model profiles, see `multi_llm_reviewer_evaluation`.

## Convergence Rules

The rule applies **after** orchestrator classifies each finding as (a)/(b)/(c) per
`multi_llm_reviewer_evaluation` § Reviewer Value-System Divergence. Only (a)+(b)
findings count toward the thresholds below; (c) findings are recorded as advisory
and never block.

- **3/5 APPROVE** full roster, or **3/4 APPROVE** after orchestrator exclusion ("exclude" strategy only — the default "delegate" strategy keeps 5 voters via collect) (no (a)/(b) REJECT) = proceed to next step
- **Any (a) or (b) REJECT or FAIL** = revise and re-review
- **(c)-only REJECT** = record as advisory, non-blocking
- **Unanimous APPROVE** (no (a)/(b)) = highest confidence, proceed
- Legacy 3-reviewer mode: 2/3 APPROVE (no (a)/(b)) = proceed
- Codex REJECT with (a)/(b) findings + others APPROVE = likely real issue, investigate before overriding
- Codex REJECT with only (c) findings = expected per Codex value-system divergence; non-blocking

**The ratio is not the only way a round closes, and it is not the primary one.**
Two roster entries (both Codex) are structurally unlikely to reach APPROVE — 24
consecutive REJECTs on one design loop — so a ratio threshold may never be met on
a document they are unhappy with. The intended close is the **exhaustion of (a)
and (b) findings, declared by the human**. A round where every deployment-grounded
and philosophy-aligned finding has been answered is converged whether or not the
numerator moved. Do not treat a reached ratio as sufficient on its own either:
check what the approving replies actually said before counting them.

**Count carryover and new (a)/(b) P0s separately; the machine-side signal of
convergence is "new P0 = 0", not the APPROVE ratio.** Require each persona to
state a closure verdict on its own prior-round P0s — closed / open /
half-closed, with grounds. This format is validated live (chain erasure
R6–R8) and is what makes the carryover/new split computable. A round whose
(a)+(b) findings are all carryover with closure verdicts, and whose revision
drew zero new P0s (observed without exception when the revision was
subtractive — see § Revision Discipline), is a freeze candidate for the
operator regardless of the numerator. Neither of the two 2026-08 threads
ever reached its APPROVE ratio; both closed by (a)+(b) exhaustion + operator
freeze declaration — the intended close described above, now with a
measurable trigger.

**Escalating raises the bar.** The rule is a ratio over the observers that
counted, so adding reserve observers with `escalate: true` raises the number of
agreements required. That is the intended cost of a wider panel, not a defect —
but do not escalate a round you are hoping to close.

For normative detail and the underlying classification, see
`multi_llm_reviewer_evaluation` § Convergence Rule (Updated).

### Consensus Patterns

| Agreement | Meaning | Action |
|-----------|---------|--------|
| **N/N** (unanimous) | Architectural-level gap | Must fix |
| **Majority** (e.g. 3/5, 3/4) | Implementation-level issue | Should fix |
| **1/N only** | Specialty-specific insight | Do NOT ignore — often the most novel finding |

1/N findings are not "minority opinions to discard." They represent unique expertise.

### Majority Rule — Reference Only

A single reviewer's FAIL may identify a critical vulnerability others missed.
**Never use majority rule to dismiss a finding without evaluating its substance.**

### Convergence Curve (typical for Tier 3)

```
Round 1: Architectural gaps     — "this is missing"     (existence)
Round 2: Fix correctness        — "the fix is wrong"    (accuracy)
Round 3: Refinement only        — "minor adjustments"   (polish)
```

Simpler artifacts (Tier 1-2, documents) may converge in 1-2 rounds.

### Severity Scale

Standard: FAIL / HIGH / MEDIUM / LOW for findings.
APPROVE / APPROVE WITH CHANGES / REJECT for verdicts.
Legacy mapping: CONCERN ≈ HIGH/MEDIUM, NOTE ≈ LOW, OK ≈ no finding.

## Persona Assembly Integration

When complexity warrants deeper analysis from the Claude reviewer:

| Complexity | Claude Mode | Rationale |
|-----------|------------|-----------|
| Tier 1-2 | Single perspective | Assembly overhead not justified |
| Tier 3+ | Persona Assembly (4+ personas) | Multiple viewpoints catch seam issues |
| Safety-critical | Assembly + Guardian persona | Adversarial thinking required |
| Final merge gate | Assembly (Kairos + Guardian + Pragmatist + Skeptic) | Comprehensive pre-merge check |
| Knowledge/methodology review | Single perspective | Content review benefits from LLM diversity, not persona diversity |

Assembly findings are weighted as a **single reviewer** (not 4 votes) to avoid
over-representing the Claude perspective in the consensus matrix.

## Synthesis Pattern

When the orchestrator integrates N reviews:

1. **Build concordance matrix** — which findings appear in 2+ reviews?
2. **Classify each finding** — N/N (must fix), majority (should fix), 1/N (evaluate substance)
3. **Evaluate minority findings on substance** — is it a real bug? Security issue?
4. **Create revised artifact** — apply all genuine bugs regardless of concordance count
5. **Create resolution matrix** — map each finding to its resolution with justification
6. **Output new review prompt** — include resolution matrix for verification

## L2 Save Points

Save to L2 context at these moments:
- **After the Unknowns Pass** (Step 0.25; unconditional, including
  zero-result passes, per INV-U3): enumerated questions, human answers,
  declared Open Unknowns
- After design/implementation complete (before review)
- After synthesis of reviews (revised version)
- After final convergence (implementation-ready / merge-ready)
- **Per-round finding tagging** (Step 0.25 acceptance observation): each
  blocking finding and each INV-U4-demoted finding tagged `open-question`
  or `defect` in the round's review record
- **After each review round**: capture per-reviewer observations — verdict,
  (a)/(b)/(c) classification breakdown, briefing-reaction shift (did the
  reviewer change verdict after Step 0.5 design direction?), anomalies
  (off-pattern findings, format failures, refusal). Tag context name with
  prefix `reviewer_evaluation_observation_<reviewer>_<date>` so future
  refinement of `multi_llm_reviewer_evaluation` can sample these records
  systematically. This closes the L2→L1 promotion loop for reviewer
  profiles themselves.

---

# Execution

## Auto Mode vs Manual Mode

### Mode Detection

```bash
which codex 2>/dev/null && echo "codex: available" || echo "codex: NOT FOUND"
which agent 2>/dev/null && echo "agent: available" || echo "agent: NOT FOUND"
which claude 2>/dev/null && echo "claude: available" || echo "claude: NOT FOUND"
```

- All three available → Auto mode (the configured roster, currently 5 reviewers)
- Codex + Agent only → Auto mode (legacy, reduced roster — apply "Legacy 3-reviewer mode: 2/3 APPROVE" from Convergence Rules)
- Any of codex/agent missing → Manual mode
- User override: `mode: manual` or `mode: auto`

### CLI Tool Matrix (tested 2026-03-28; model flags made mandatory 2026-07-27)

Every row names its model explicitly. There is no "default model" column any
more, because the defaults belong to the CLIs and the CLIs are configured
outside this repository — see the incident recorded in § Pre-flight checklist.

| Tool | Command | Prompt Input | Output Collection | Model |
|------|---------|-------------|-------------------|-------|
| **Codex** | `codex exec -m <model>` | stdin pipe: `cat prompt.md \| codex exec -m <model> -` | `-o /path/output.md` | gpt-5.6-sol + gpt-5.5 (both roster entries, `-m` per entry) |
| **Cursor Agent** | `agent -p --model composer-2.5` | File reference (stdin NOT supported) | stdout redirect: `> output.md` | composer-2.5, passed explicitly — never relying on the CLI default |
| **Claude Code** | Agent tool (internal) | Direct prompt string | Write to workspace file | Orchestrator model, or the declared `persona_model` when personas run elsewhere |
| **Claude CLI (4.6)** | `claude -p --model claude-opus-4-6` | stdin pipe: `cat prompt.md \| claude -p --model claude-opus-4-6` | stdout redirect: `> output.md` | Opus 4.6 — the calibrated anchor, deliberately not a frontier model |
| **Claude CLI (frontier)** | `claude -p --model claude-opus-5` | stdin pipe: `cat prompt.md \| claude -p --model claude-opus-5` | stdout redirect: `> output.md` | Runs only when Opus 5 is *not* the orchestrator; when it is, that slot is taken by the persona team |

`--bare` must NOT be passed (established 2026-07-23): it skips credential
loading and the subprocess fails with "Not logged in". The project-instruction
bias it was meant to suppress is handled by `review_context: independent`
instead.

Fable 5 appears in no row above. It was retired from the roster on 2026-07-26
after five consecutive non-substantive returns, and now sits in the reserve
container — see § Reserve observers (escalation).

### Thinking Effort Configuration (validated 2026-04-20)

Based on cross-evaluation experiment (7 models × 4 tasks + Nomic, 518 CLI calls):

| Role | Model | Effort Flag | Rationale |
|------|-------|-------------|-----------|
| **Primary (orchestrator)** | session default | (default) | Sufficient for integration, dialogue, judgment |
| **Reviewer: Agent Team** | = orchestrator, or the declared `persona_model` | (default) | Personas inherit whichever model actually runs them |
| **Reviewer: Claude CLI** | Opus 4.6, plus any frontier roster slot the orchestrator is not | (default; config `effort: medium`) | Evaluator quality is effort-independent (low≈high: 8.35 vs 8.16) — per 2026-04-29 policy reviewers stay at default |
| **Coding sub-agent** | Opus 5 | `--effort xhigh` | Published starting point for coding/agentic work; not measured here (see note) |
| **Design sub-agent** | Opus 5 | `--effort high` | Published starting point for intelligence-sensitive work; not measured here (see note) |
| **Codex** | GPT-5.6-sol / GPT-5.5 | (no flag) | Fixed effort |
| **Cursor Agent** | Composer-2.5 | (no flag) | Fixed effort |

Note (2026-07-25): the effort experiment data is from the Opus 4.6/4.7
generation. Opus 5 and Fable 5 effort sensitivity is not yet calibrated;
defaults apply until re-measured.

Note (2026-07-26): the coding / design sub-agent rows moved from Opus 4.7
(retired 2026-06-10) to Opus 5. Their effort values are Anthropic's published
starting points for Opus 5, not measurements from this project — treat them as
a starting point to sweep down from, not a validated setting. Separately, the
**sub-author** role for self-referential passages stays Opus 4.6: it is chosen
for its ambiguity-preserving bias, not for capability, so a frontier successor
does not replace it.

Key findings:
- **Opus 4.6** high effort improves Evaluator/Strategy (+0.43/+0.200 Nomic), not Response
- **Opus 4.7** high effort improves Response/Thinking (+0.81 code, +0.53 philosophy), not Evaluator
- **Opus 4.7 low > Opus 4.6 high** in combined score — model generation > effort setting

**Effort escalation** (coding/design sub-agents and the post-aggregation revision
phase only — NOT reviewers, who stay at default per the 2026-04-29 policy): For
particularly complex tasks (Tier 3+ architecture, security-critical code,
multi-component refactoring), the LLM accessing this skill SHOULD escalate to
`--effort high` at its own judgment. No human approval is needed for effort
escalation — it is a cost/quality tradeoff that the executing LLM is best
positioned to evaluate in context.

### Model Detection

Detection tells you what a CLI *would* pick if you did not say. Use it to notice
that a default has drifted — never to decide which model a reviewer runs. Every
slot names its own model (INV-E5), so a detected default that differs from the
roster is a warning about the environment, not an instruction to follow.

```bash
codex exec -C . -o /dev/null "What model are you? Reply with only the model name."
agent --list-models 2>&1 | grep "(current\|default)"
# Claude Code: known from session
```

Where a transport reports back which model actually answered, record it beside
the declared one. Path B does this automatically: `model_source` reads
`observed` or `declared`, and `model_divergence` is true when the two disagree.
Divergence is recorded rather than corrected — the run is not retried, but the
record no longer claims a model that did not answer.

### Orchestrator Self-Identification (Self-Referential Model Reporting)

**Rule**: When invoking `multi_llm_review` (or running this workflow manually), the
orchestrating LLM MUST pass its own model identifier as `orchestrator_model`.

**Rationale**: The reviewer roster contains more than one Claude entry (Opus 5
and Opus 4.6 as of 2026-07-26). A frontier slot sits in the roster on purpose:
when it is the current session model it matches `orchestrator_model` and becomes
the persona-team slot; when it is not, it is dispatched as a `claude -p`
subprocess. With the current two-entry Claude side, an Opus 5 orchestrator leaves
Opus 4.6 as the only Claude CLI subprocess. No per-orchestrator config branch is
needed either way.
To avoid the orchestrator reviewing its
own output (no independent signal), the dispatcher excludes or delegates the
roster entry whose `model` matches `orchestrator_model` (per
`orchestrator_strategy`). This keeps the same SkillSet useful
regardless of which Claude model the user has toggled to via `/model` — review
composition adapts automatically.

**Why "argument-passing" not "file-introspection"**:
- The orchestrator's model identity lives in *its own context* (system prompt
  declares e.g. "You are powered by Fable 5"). No external file or env var is
  authoritative — `/model` switches change context immediately.
- MCP protocol does not transmit caller-model info; only the orchestrator can
  truthfully report its own identity. This is genuine self-reference: the system
  reports its own state to itself.
- Reading `~/.claude/projects/<cwd>/<sessionId>.jsonl` works but depends on
  Claude Code internals (format may change between versions). Argument-passing
  has zero internal-format dependency.

**How orchestrator obtains its model ID**:
- Claude Code sessions: read the system prompt line "You are powered by the
  model named ... The exact model ID is ...". Use the exact ID as stated,
  whatever its form (e.g. `claude-opus-5`, `claude-fable-5`). Strip any context
  suffix — `claude-opus-5[1m]` is passed as `claude-opus-5`, since the roster
  matches on the bare model ID.
- Other hosts: use whatever introspection the host provides; if none, pass
  `null` and accept that no exclusion happens.

**Tool invocation example**:
```
multi_llm_review(
  artifact_path: "log/design.md",
  review_type: "design",
  orchestrator_model: "claude-opus-5"    # MUST be set by caller; bare ID, no [1m] suffix
)
```

**Dispatcher behavior** (config: `exclude_orchestrator_model: true`, default `true`):
- If `orchestrator_model` matches a roster entry's `model`, that entry is skipped.
- `min_quorum` and `convergence_rule` apply to the remaining reviewers.
- 5-reviewer roster → 4 reviewers; `convergence_rule_after_exclusion: "3/4 APPROVE"`
  (from config) replaces the full-roster rule. This reduced count applies to the
  "exclude" strategy only. The "subprocess" strategy keeps the full roster (the
  matching entry runs as a fresh CLI process instead of being skipped). Under the
  default "delegate" strategy, the matching entry is dropped at dispatch but
  re-added at collect as the persona-team entry, so the voter count returns to 5
  and the full-roster rule (3/5 APPROVE) applies.
- **At most one roster entry leaves for matching the caller.** This is only
  visible on a roster carrying three or more entries on the orchestrator's own
  model: the first is taken over by the persona team, the second leaves as the
  caller's own, and any beyond that run — as fresh external processes on that
  model, which is what the "subprocess" strategy buys deliberately. On the
  current roster (one Opus 5 entry) the question does not arise. Settled
  2026-07-27: the invariant fixes a count for the persona clause and states none
  for this one, and the shipped behaviour follows the text rather than widening
  it. A caller who wants a same-model slot to run anyway asks for it with
  `orchestrator_strategy: "subprocess"`.
- If `orchestrator_model` is `null` or unmatched, full roster runs (back-compat).

**Manual-mode equivalent**: When orchestrating by hand, do not assign yourself
as a subprocess reviewer. Run the Claude CLI subprocess reviewers (Opus 4.6, plus
any frontier roster slot you are not); if your own model matches one of them,
skip that entry and use the after-exclusion convergence rule.

**The roster cannot be replaced per call.** There was once a `reviewers_override`
argument; it is gone, and a call that still carries it is refused with an error
rather than silently ignored, so a stale runbook fails loudly instead of
reviewing against a roster nobody can see. To widen a panel for one hard
artifact, use `escalate: true` — see § Reserve observers below.

### Orchestrator Delegation Protocol (Two-Phase, default)

The `delegate` strategy lets the orchestrator perform persona-based "Agent Team"
review in its own context — preserving inherited project context that a fresh
`claude -p` subprocess loses. Subprocess reviewers (codex, cursor, Claude CLI
Opus 4.6 and the non-orchestrator frontier model) remain single-LLM.

**Why**: The orchestrator already holds the artifact in context with full project
awareness. Re-shipping it to a sandboxed subprocess discards that context. Same-
model persona switching gives stylistic / framing diversity (validated empirically);
cross-model subprocess reviewers give epistemic diversity. The two are complementary.

**Call 1**: `multi_llm_review(orchestrator_strategy: "delegate", orchestrator_model: "...")`
- SkillSet drops the orchestrator-matching reviewer from dispatch
- Subprocess reviewers run synchronously (no background threads)
- Subprocess results persisted to `.kairos/multi_llm_review/pending/<uuid>.json`
- Returns `status: "delegation_pending"`, `collect_token`, `persona_count_min/max`

**Orchestrator's obligation** (between calls):
- Recognize the `delegation_pending` status
- Spawn 2-4 parallel `Agent` tool calls with self-chosen personas appropriate to
  the artifact (e.g. design → architect/security/operability; code → correctness/
  performance/api-design; doc → ontologist/skeptic/integration)
- Collect persona results: each as `{persona, verdict (APPROVE|REVISE|REJECT),
  reasoning, findings: [{severity, issue}, ...]}`

**Call 2**: `multi_llm_review_collect(collect_token, orchestrator_reviews: [...])`
- Persona Assembly: any REJECT → REJECT; else any REVISE → REVISE; else APPROVE
- Assembled into one synthetic reviewer entry `claude_team_<orchestrator_model>`
- Combined with persisted subprocess results, run Consensus, return final verdict
- Idempotent: repeated calls with the same token return the cached result

**Failure modes**:
- `expired_or_unknown_token`: orchestrator missed `must_collect_by` deadline
  (default 1800s since v3.23.2; was 600s), or token never existed. The pending
  review is gone; call `multi_llm_review` again from scratch.
- `error: invalid orchestrator_reviews`: persona count outside 2-4 or missing
  required fields. Fix and retry collect with the same token.
- All-subprocess-failed at Call 1: returns error immediately; no token issued.

**Default**: `orchestrator_strategy` defaults to `"delegate"` (config key
`default_orchestrator_strategy`). `"exclude"` remains available as the legacy
strategy. (Historical note: delegate was opt-in until validated by use; it has
been the config default since v3.x.)

### Persona execution model (`persona_model`)

The persona team normally runs on the orchestrator's own model, and declaring
`orchestrator_model` is enough — that declaration stands in the persona position
and the matching roster slot is taken over by the persona result.

Pass `persona_model` when the personas will actually run on a **different** model
from the caller. The case this exists for: a cheaper session orchestrating a
review while spawning its persona sub-agents on a stronger model. Then the slot
that gets taken over is the one matching `persona_model`, not the one matching
the caller.

```
multi_llm_review(
  orchestrator_model: "claude-fable-5",   # who is calling
  persona_model:      "claude-opus-5",    # who the personas actually run on
  ...
)
```

| Declared | Persona convened? | Which roster slot it takes | Caller's own slot |
|---|---|---|---|
| `orchestrator_model` only | Yes, on the caller's model | The one matching the caller | Taken by the persona |
| Both, different models | Yes, on `persona_model` | The one matching `persona_model` | Leaves the set (not self-reviewed) |
| `persona_model` matches no roster slot | Yes | None — it joins as an independent observer, widening the denominator | Leaves the set |
| Neither | No persona; the run completes in one phase | — | — |

**This declaration is never verified.** The persona team runs outside this
system, in the caller's own harness, and nothing here can observe which model
answered. It is recorded as a declaration and kept apart from observed
provenance in the record (`model_source: declared`). A caller that declares
falsely produces a record that is wrong and internally consistent; the honesty of
this field is the caller's, not the tool's.

### Reserve observers (escalation)

The roster in config is the canonical set and cannot be replaced per call. What a
caller *can* do is add the reserve observers declared under
`escalation_reviewers`, for one call:

```
multi_llm_review(escalate: true, ...)
```

Points worth knowing before using it:

- **Difficulty is the caller's judgement.** The tool does not decide that an
  artifact is hard; it only takes the answer. There is deliberately no automatic
  escalation.
- **Escalating raises the bar.** The convergence rule is a ratio over the
  observers that counted, so a wider panel needs more agreements.
- **The container is provider-neutral.** It is a place to put a temporary
  observer, not a slot reserved for a particular model. Removing an occupant is
  a deletion in config and nothing else; a caller that still passes `escalate:
  true` afterwards simply adds nothing and the verdict is unaffected.
- Reserve entries obey INV-E5 exactly like roster entries: they name their
  provider and model, and inherit no CLI default.

As of 2026-07-26 the container holds Fable 5, which was retired from the roster
after five consecutive non-substantive returns.

### Substance and the denominator

A reply counts toward the denominator when it **carries a verdict** and **says
something beyond it**. Both conditions, separately checked; a reply failing
either leaves the denominator rather than being counted, because otherwise it
raises the agreement everyone else must reach while contributing none of its own.

The two failures look nothing alike, and conflating them is why this rule was
rebuilt four times:

| Reply | Carries a verdict? | Says something? | Outcome |
|---|---|---|---|
| `APPROVE` | yes | no | `insubstantial` |
| `APPROVE. P0` | yes | no (a severity names no defect) | `insubstantial` |
| `I'll review this and give my assessment.` | **no** | yes | `no_verdict` |
| `競合状態あり` | no (no verdict word) | yes | `no_verdict` |
| `REJECT: P0 key logged in plaintext` | yes | yes | counts |
| `NO-GO` + findings | yes (see the vocabulary below) | yes | counts as REJECT |

The second row is the shape that retired Fable 5 — long enough to pass any
substance rule, and stating no judgement. Three rebuilds of the substance rule
missed it because they were all looking at the wrong half. A reply that states
no verdict used to be counted as a conservative `REVISE`, which blocked
convergence on a judgement its author never gave.

- The test is mechanical and has no setting: **does anything remain once the
  verdict word is removed?** No model is asked to judge whether a review is good.
- It applies to every observer equally, the persona team included. A persona
  submission whose findings are blank leaves the denominator exactly as a
  subprocess reply would — and so does a structured reply from any other slot.
  A JSON reply is judged by **the words it carries, whatever keys they live
  under**, not by the text it renders to and not by keys named in advance.
  Judging it by rendered text counted its own key names as content: the residue
  of `{"overall_verdict": "APPROVE", "findings": [], "reasoning": ""}` is three
  words of schema and no review. Naming the keys instead threw away real
  reviews: a REJECT whose findings used `description` was recorded as an empty
  submission. **Answer in whatever shape you like** — nothing here requires a
  particular key.
- **Open your reply with your verdict.** A structured submission states its
  verdict as a field; a free-text reply states it in an `**Overall Verdict**`
  header **on the first line, before anything else**. A header anywhere else is
  not read as yours — it may be a sample you are discussing — so quoting verdict
  headers further down is safe and needs no escaping.

  Three rounds tried to tell a stated header from a displayed one by reading the
  text more cleverly, and each attempt opened a hole in the direction that
  passes: round 4 anchored the search to the start of a line, and a line inside
  a fence starts a line; round 6 excluded fenced and blockquoted regions, and a
  four-backtick fence closes on the inner three-backtick line, taking the rest
  of the reply — including the real verdict — with it. A quotation and a
  statement are the same characters, so no amount of reading decides between
  them. Position does, because a quotation cannot be first unless the reviewer
  chose to open with one.

  A reply that opens with a preamble falls to a last-resort word scan over the
  whole text. That is a guess, and it reads quotations along with everything
  else — but it checks REJECT first, so it cannot turn a stated rejection into
  a recorded approval.
- **The words that count as a verdict are one list, the same for every
  observer.** `APPROVE / PASS / ACCEPT / LGTM / SHIP IT`,
  `REJECT / FAIL / BLOCK / NO-GO / NACK / DENY / VETO`,
  `REVISE / CHANGES REQUIRED / NEEDS WORK / NEEDS REVISION / REWORK`. Where a
  reply carries more than one, the blocking reading wins (REJECT, then REVISE,
  then APPROVE) — a reply saying two of them has qualified one judgement, not
  stated two. Japanese verdict words are deliberately **not** in this list
  (author decision, 2026-07-28): a Japanese review counts on its findings, but
  its judgement must be stated in one of the words above.
- It is **not** a quality bar, and must not be tuned into one. `競合状態あり` is a
  review. So is `REJECT: P0 private key logged in plaintext`. Earlier versions of
  this rule measured length and, at one setting, discarded Japanese reviews
  entirely — reviewers answer in the artifact's language, and this project's
  artifacts are largely Japanese.
- What leaves the denominator is recorded with the reason, per reviewer and
  again in `denominator_composition`. A slot that answered emptily and a slot
  that never answered are both absent from the numerator and must never be
  confused in the record, so `skip_reason` distinguishes: `insubstantial` (a
  reply that said nothing beyond its verdict), `no_verdict` (a reply that stated
  no judgement), `transport` (a call that was attempted and failed),
  `not_dispatched` or the dispatcher's own wording such as `dispatch_timeout`
  (a slot this system declined to run), and `declined` (a submission that stated
  SKIP for itself — reachable only by a caller that declares it, which nothing
  in this repository currently does). Only a token-shaped reason is carried
  through; anything else becomes `not_dispatched`, so a traceback or a sentence
  cannot land in a field documented as a small vocabulary. Nothing is defaulted:
  a row with no reason omits the field, because a default here states a cause
  the record does not know.

- **The escalation record is filled in only where it is wholly absent.** Pending
  state written before escalation existed carries no such field, and that one
  case is answered truthfully — a version with no escalation to offer cannot
  have been asked for it. A record that exists is carried as recorded, gaps and
  all: completing a partial one wrote `requested: false` beside
  `escalated: true`, a pair the producing code cannot emit. Silence about a key
  is legible to a reader; a value asserted where none was recorded is not.
- The count beside these is `observers_reporting` — the observers that answered,
  which is not the number of slots the configuration named. That question is
  answered by `denominator_composition`, which lists every observer including
  the ones that never ran and why.

**What this rule cannot do.** It cannot tell a terse honest approval from a lazy
one. `**Overall Verdict**: APPROVE / No findings` is the exact form the reviewer
prompt asks for when a reviewer finds nothing, so it counts — the only way to
exclude it would be to exclude every honest terse approval with it. When a round
reaches its ratio, read what the approving replies actually said before treating
the ratio as convergence. That judgement is the human's and no rule replaces it.

#### A no_verdict streak is a seat-environment signal, not a dead reviewer

Before treating a slot as dead, read its `raw_text_excerpt` / `stated_text`
in the pending record. Diagnosed live (2026-08-06, `claude_cli_opus4.6`,
four consecutive no_verdict exclusions across one implementation-review
thread): the CLI itself was healthy throughout. The subprocess seat runs
sandboxed — no tools, empty working directory — so on **implementation**
artifacts that cite file paths, the model attempted to read code before
judging: two rounds opened with pseudo-tool-call markup, one opened with
"the repository is not accessible" and stated its verdict header only
further down, where the positional rule correctly refuses it. The same
seat, in the same period, complied on **design** artifacts (verdict on
line 1, counted every round). Remedies, in order: state in the subprocess
prompt that the seat has no file access and must review the artifact text
alone, marking unverifiable claims `[INFERRED]` (the grounding_rules block
already licenses this); keep prompt rule #6 (full artifact inline) honest
for implementation reviews; only then consider `--add-dir` with read-only
tools, accepting CLAUDE.md contamination. A streak that survives those
remedies is a real outage.

#### Async/Parallel Collect Timing — Iron Rule

When `delegation.parallel.default: true` (the v3.x default), Call 1 returns
`delegation_pending` **immediately** (~50ms) and a detached worker runs the
subprocess reviewers in parallel with the orchestrator's persona Agent
reviews. This is faster, but introduces a timing trap:

> **The orchestrator MUST call `multi_llm_review_collect` immediately after
> the persona Agent reviews complete — without intervening user dialogue,
> unrelated tool calls, or context switches.**

Why this matters:

- The LLM is **not event-driven**. When the worker finishes writing
  `subprocess_status: "done"` to `state.json`, nothing wakes the orchestrator.
  The orchestrator only notices when it next calls `multi_llm_review_collect`.
- `multi_llm_review_collect` already polls internally at
  `poll_interval_seconds: 0.5` for up to `collect_max_wait_seconds: 420` (7min)
  per call. Polling is not the bottleneck — the bottleneck is the orchestrator
  forgetting to call collect at all.
- The token expires at `collect_deadline` (default 30min since v3.23.2). If
  user dialogue or other work intervenes between persona Agent completion and
  the collect call, the token can expire while the subprocess results sit
  ready and unread on disk.

Recommended orchestrator flow (single LLM turn, no detours):

```
1. multi_llm_review(...) → receive delegation_pending + collect_token
2. Spawn persona Agent reviews (Agent tool, parallel, 2-4 personas)
3. As soon as ALL personas return → multi_llm_review_collect(collect_token, ...)
4. Return final consensus to user
```

Anti-pattern (do NOT do this):

```
1. multi_llm_review(...) → delegation_pending
2. Run persona Agent reviews
3. ❌ "By the way, while we wait, let me explain X to the user…"
4. ❌ User asks an unrelated question, conversation drifts
5. ❌ 30+ minutes later, finally try collect → expired_or_unknown_token
```

If the orchestrator is genuinely interrupted (user explicitly switches topic,
or persona Agent itself takes a long time and the orchestrator wants to
report progress), it should still **call collect first** — collect returns
quickly if the worker is already done, or blocks up to 7min if not. Either
way, the token stays alive and consensus is captured before resuming side
work.

Manual recovery if expiry happens: subprocess results are persisted at
`.kairos/multi_llm_review/pending/<token>/subprocess_results.json` and remain
readable until GC. Read them directly and synthesize manually, then re-run
`multi_llm_review` for fresh results if needed.

### Critical CLI Notes

- **Every launch names its model** (INV-E5): `--model` for `claude` and `agent`,
  `-m` for `codex`. A launch without it inherits a user-editable CLI default from
  outside this repository — see § Pre-flight checklist for what that cost once
- **Cursor Agent stdin**: `cat file | agent -p -` does NOT work. Use file-reference:
  `agent -p --trust --model composer-2.5 "Read log/prompt.md and follow the instructions."`
- **Cursor Agent trust**: `--trust` required for headless/non-interactive mode
- **Cursor Agent model**: `--model composer-2.5` is mandatory, not optional. The
  CLI default lives in `~/.cursor/cli-config.json` and has been changed there
  before, silently swapping the model behind an unchanged role label
- **Codex workspace**: `-C /path/to/workspace` to set working directory
- **Claude Agent paths**: Write within workspace (e.g., `log/`), not `/tmp`
- **Claude CLI (Opus 4.6 / any non-orchestrator frontier slot)**: `claude -p --model claude-opus-4-6` (likewise `claude-opus-5`) runs as external process. Uses stdin pipe (like Codex). Do NOT pass `--bare` — it skips credential loading and the subprocess dies with "Not logged in" (established 2026-07-23). Project-instruction bias is suppressed via `review_context: independent`, not via `--bare`
- **Claude CLI parallelism**: Agent tool (internal, orchestrator model) + Bash `claude -p` (external, Opus 4.6 and any other Claude roster slot the orchestrator is not) run truly in parallel as separate processes
- **Claude CLI file access**: a plain `claude -p` review subprocess should not need file access. Ensure the review prompt includes all artifact content inline (rule #6). Use `--add-dir` + `--allowedTools "Read,Glob,Grep"` if file access is genuinely needed, and accept that CLAUDE.md is loaded (the old `--bare` workaround is unusable — see above)

## Prompt Generation Rules

Every review prompt MUST include these 7 items:

1. **Output filename table** — so each reviewer knows where to save
2. **Auto-execution commands** — ready-to-run CLI per reviewer
3. **Review instructions** — what to focus on, what NOT to re-review
4. **Prior findings to verify** (R2+) — the findings the revision addresses,
   so the reviewer can judge each closed / open / half-closed. Findings only:
   no per-reviewer verdict history, no finding counts, no round tallies
   (see § Reviewer incentive rule)
5. **Context** — architecture summary for reviewers unfamiliar with codebase
6. **Full artifact content inline** — reviewers may not have file access
7. **Severity ratings + output format** — structured template for review output

All prompt content MUST be in **English** for consistent parsing across LLM tools.

### Reviewer incentive rule

**Never tell a reviewer — subprocess or persona — that its finding count is
compared across rounds, which round this is, or what verdicts were given
before.** A reviewer told its count is watched treats the count as the
deliverable, and that selects for finding-*production* over finding-*weight*
(observed 2026-08-06: an orchestrator wrote "your finding count is compared
across rounds" into persona prompts during the project_orientation_report
loop; of the round's 7 P0s, 3 were factually correct findings that cost
nobody anything). Convergence — carryover vs new, (a)+(b) exhaustion, the
ratio — is measured by the orchestrator from the record, after the replies
are in. The reviewer receives the artifact, the review criteria, and the
prior findings it must verify. Nothing else about the loop's state.

What this rule does NOT forbid: passing prior findings for closure
verification (rule #4 — that is content, not score-keeping), and the
carryover/new split in § Convergence Rules (that is orchestrator-side
bookkeeping the reviewer never sees).

### XML Block Structure for Review Prompts

Review prompts SHOULD use XML blocks to give LLMs explicit structural contracts.
This reduces hallucination, enforces grounded findings, and standardizes output.

```xml
<task>
Review the provided artifact for [review type: design correctness / implementation bugs / ...].
Target: [artifact name and version]
Scope: [what changed since last round, or "initial review"]
</task>

<structured_output_contract>
Output a Markdown file with this structure:
- **Reviewer**: [tool_name]
- **Model**: [model_id]
- **Date**: [ISO date]
- **Overall Verdict**: APPROVE / APPROVE WITH CHANGES / REJECT

For each finding:
- **Severity**: FAIL / HIGH / MEDIUM / LOW
- **Confidence**: 0.0-1.0 (how certain you are this is a real issue)
- **Location**: file:line or section reference
- **What can go wrong**: concrete failure scenario
- **Why this is vulnerable**: code path or design gap
- **Likely impact**: data loss, security breach, silent corruption, etc.
- **Recommended fix**: specific change (not "consider improving")
</structured_output_contract>

<grounding_rules>
Ground every finding in the provided artifact text or referenced source files.
If a claim is an inference (not directly visible in the artifact), label it:
  "[INFERRED] Based on X, this likely means Y."
Do not invent files, methods, or runtime behavior not shown in the artifact.
Keep confidence scores honest — 0.5 if uncertain, 0.9+ only if directly evidenced.
</grounding_rules>

<verification_loop>
Before finalizing your review:
1. Re-read each FAIL/HIGH finding. Is the failure scenario concrete and reproducible?
2. Check for second-order failures: empty-state, retry, stale state, rollback risk.
3. Verify file paths and line numbers are accurate.
4. If you found zero issues, state that explicitly — do not manufacture findings.
</verification_loop>

<default_follow_through_policy>
Complete the full review in one pass. Do not ask clarifying questions.
If context is missing, note it as a finding with severity LOW and confidence 0.3.
</default_follow_through_policy>
```

**Usage**: Include these XML blocks in the prompt body (rule #3 "Review instructions").
They replace or supplement free-form review instructions. The blocks are
LLM-agnostic and work with Claude, GPT, and Composer models.

**When to use full XML blocks vs. lightweight**:
- **Full** (all 5 blocks): Design review, implementation review, security-critical
- **Lightweight** (`<task>` + `<structured_output_contract>` only): Fix plan review, document review

### Output Directive in Prompt Body

The prompt body itself (what the LLM sees) must contain:
```markdown
## Output
Save your review to: `log/{artifact}_review{N}_{llm_id}_{date}.md`
```

### Review Output Header

Each review file MUST include:
```markdown
- **Reviewer**: [tool_name]
- **Model**: [model_id]
- **Date**: [ISO date]
- **Overall Verdict**: APPROVE / APPROVE WITH CHANGES / REJECT
```

## Orchestration Template

```
Step 1: Generate review prompt
  - Write to log/{artifact}_review_prompt.md
  - Include all 7 required items (see Prompt Generation Rules)
  - Append full artifact content

Step 2: Detect environment, and check the roster against config
  - Run: which codex && which agent && which claude
  - Read the roster from config/multi_llm_review.yml — do NOT read CLI defaults
    and treat them as the roster. Detection only tells you whether a default has
    drifted; the model each slot runs is named on the command line.
  - Report: "Auto mode: Codex (gpt-5.6-sol, gpt-5.5), Cursor (composer-2.5),
    Claude Team (orchestrator model), Claude CLI (opus-4.6)"

Step 3: Execute the configured roster in parallel (currently 5 slots, one of
        which is your own persona team)
  - Bash(background): cat prompt.md | codex exec -m gpt-5.5 -C workspace -o log/review_codex_gpt5.5.md -
  - Bash(background): cat prompt.md | codex exec -m gpt-5.6-sol -C workspace -o log/review_codex_gpt5.6-sol.md -
  - Bash(background): agent -p --trust --model composer-2.5 "Read prompt and review..." > log/review_cursor.md
  - Agent(background): Claude Team (orchestrator model, e.g. Opus 5) → write to log/review_claude_team_opus5.md
  - Bash(background): cat prompt.md | claude -p --model claude-opus-4-6 > log/review_claude_opus4.6.md 2>log/review_claude_opus4.6.stderr.log
    (add a line per further Claude roster slot you are not; with the 2026-07-26
     roster an Opus 5 orchestrator has none, so opus-4.6 is the only one)

Step 4: Collect and validate
  - Wait for all to complete (background task notifications)
  - Verify each output file exists and contains structured review
  - Failed tool → offer manual fallback

Step 5: Consensus analysis
  - Read all review files
  - Build concordance matrix
  - Apply consensus rules
  - Generate: log/{artifact}_consensus.md

Step 6: Report to user
  - Per-reviewer verdicts, concordance matrix, recommended actions
  - Save L2 context
```

## Error Handling

| Error | Detection | Recovery |
|-------|-----------|----------|
| CLI not found | `which` non-zero | Manual mode fallback |
| Auth expired | Non-zero exit, auth error | Prompt re-login |
| Timeout (>5 min) | Background task timeout | Kill, report partial, retry |
| Empty output | Missing verdict | Report failure, manual retry |
| Trust prompt | Agent hangs | `--trust` flag |
| Usage limit | "usage limit" in output | Alternate tool fallback |

## File Naming Conventions

```
log/{artifact}_review_prompt.md                    # Shared prompt
log/{artifact}_review{N}_{llm_id}_{date}.md       # Individual reviews
log/{artifact}_review{N}_consensus_{date}.md       # Consensus analysis
```

LLM identifiers: `claude_cli_opus5`, `claude_cli_opus4.6`,
`codex_gpt5.6-sol`, `codex_gpt5.5`, `cursor_composer2.5`, `cursor_gpt5.4`,
`cursor_premium`. The delegated slot is reported as `claude_team_<model>`
(e.g. `claude_team_claude-opus-5`), assembled at collect time — the roster's
own labels stay CLI-neutral because either frontier entry can take either path.
(legacy, pre-2026-06-10: `claude_opus4.6`, `claude_team_opus4.6`, `claude_team_opus4.7`,
`claude_cli_opus4.7`, `cursor_composer2`; retired 2026-07-23: `codex_gpt5.4`;
retired 2026-07-25: `claude_cli_opus4.8`, `claude_team_fable5`;
retired 2026-07-26: `claude_cli_fable5` — five consecutive non-substantive
returns, 85-128 characters in 5-7 seconds, no findings and no verdict text)

## Internal Agent Team Review

When the primary LLM reviews using its own agent team:

1. Launch 2-3 parallel agents with different perspectives
2. Each reviews independently
3. **Persona Assembly** synthesizes: deduplicate, resolve severity, compress
4. Output single consolidated review file

Compression ratio: parallel agent raw → Assembly ≈ 2:1

## Anti-Patterns

- Don't skip the review prompt — reviewers need inline content and context
- Don't merge design + implementation review — they find different bug classes
- Don't advance to Phase N+1 before Phase N review converges
- Don't re-review from scratch — each round checks only the delta
- Don't use only internal agent team — different providers catch different bugs
- Don't dismiss 1/N findings without evaluating substance
- Don't use Persona Assembly in every intermediate round (save for final gate)

---

## Experimental Data

### Service Grant (Tier 3, 2026-03-18)
- 3 review rounds, 3 LLMs → 8 P0/P1 design bugs found
- Implementation review: 6 FAIL + 5 CONCERN → 13 FIX
- Fix plan: 2 rounds → deadlock found → converged

### Attestation Nudge (Tier 2, 2026-03-28)
- Design: 2 rounds, 3 LLMs → v0.1(REJECT) → v0.3(converged)
- Implementation review: 1 round → 3/3 FAIL (missing call site)
- Final review + Persona Assembly: 3/3 APPROVE, 0 FAIL
- Codex convergence: REJECT → REJECT → REJECT → APPROVE (4 rounds)
- Self-referential review: v3.0 of this skill reviewed by its own process → v3.1
- Self-referential review: v3.2 (4-reviewer update, 2026-04-19) reviewed with new 4-reviewer default (Opus 4.6 + 4.7 + Codex + Composer-2). 4/4 APPROVE WITH CHANGES R1. Findings integrated → v3.3
- Roster update (v3.5, 2026-06-10): Fable 5 replaces Opus 4.7 as orchestrator/team slot; Opus 4.8 added as second subprocess CLI reviewer alongside Opus 4.6. 4.6 retained for its documented complementary bias (ambiguity-preserving, self-reference-friendly); 4.7 retired as its register is covered by 4.8 and Fable 5. 4.8/Fable 5 bias profiles uncalibrated — record (a)/(b)/(c) breakdowns per round until profiles accumulate in `multi_llm_reviewer_evaluation`
- Self-referential review of v3.5 (2 rounds, 2026-06-10/11, first run of the 6-reviewer roster): R1 REVISE (1 APPROVE / 4 REJECT — stale pre-v3.5 passages) → fixes → R2 3/6 APPROVE (4.6, 4.8, codex 5.4) with Cursor contributing a code-grounded correction (subprocess strategy keeps the full roster). 4.6/4.8 verdicts split along the predicted lenient/strict axis in R1 and converged to APPROVE in R2
- Step 0.25 Unknowns Pass added (v3.6, 2026-07-05): designed via its own
  3-round self-referential review (R1 REVISE 2/6 → R2 REVISE 2/6 → R3 4/6
  APPROVE; v0.3.1 FROZEN). The loop demonstrated the step's own thesis:
  R1's two biggest blockers (unattended classification authority, INV-U4
  demotion bounds) were exactly judgment-shaped unknowns a pre-draft
  interview would have caught. Also observed: fix-verification requires
  epistemic diversity — the personas that authored R1 findings all approved
  their own fixes in R2, while subprocess reviewers caught the seams.
  Design record: `docs/drafts/multi_llm_review_unknowns_pass_v0.3.1_FROZEN.md`
- Roster update (v3.6.1, 2026-07-23): Codex gpt-5.6-sol replaces gpt-5.4
  (retired — its "everyday coding" register is covered by the frontier
  entries). gpt-5.5 retained as the calibrated anchor for cross-generation
  comparison. 5.6-sol's reviewer bias profile is uncalibrated — record
  (a)/(b)/(c) breakdowns per round until a profile accumulates in
  `multi_llm_reviewer_evaluation`; watch for agentic-coding drift into
  implementation detail during design-phase reviews ((c) inflation)
- Roster update (v3.6.2, 2026-07-25): Opus 5 enters the roster and Opus 4.8
  retires — the same succession logic that retired 4.7 on 2026-06-10 (the
  strictness / systematizing register passes to the direct successor). The
  Claude side now holds BOTH frontier models (Opus 5, Fable 5) plus Opus 4.6.
  This is deliberate: whichever frontier model is the session orchestrator is
  matched by `orchestrator_model` and becomes the persona-team slot, and the
  other is dispatched as a `claude -p` subprocess — so the composition
  "orchestrator persona + other frontier via CLI + 4.6 via CLI" holds under
  either orchestrator with no config branching. Since Fable 5 was retired on
  2026-07-26 the roster is 5, so `convergence_rule` is `3/5` and
  `convergence_rule_after_exclusion` is `3/4`. With Opus 5 as orchestrator its
  own slot is delegated to the persona team, so the Claude CLI side is
  `claude_cli_opus4.6` alone; the delegated slot is relabelled
  `claude_team_<model>` at collect.
  Opus 5's reviewer bias profile is uncalibrated — record (a)/(b)/(c)
  breakdowns per round until a profile accumulates in
  `multi_llm_reviewer_evaluation`
- `--bare` correction (v3.6.2, 2026-07-25): all `claude -p` examples had
  carried `--bare` since v3.0. It skips credential loading, so the subprocess
  returns "Not logged in" (established 2026-07-23). Removed everywhere;
  project-instruction bias is suppressed by `review_context: independent`
- Sub-agent model correction (v3.6.3, 2026-07-26): the coding / design
  sub-agent rows in the effort table still named Opus 4.7, retired 2026-06-10
  — a stale row an instruction-following orchestrator would execute verbatim,
  launching a subprocess on a retired model. Moved to Opus 5, with the effort
  values marked as published starting points rather than measurements from this
  project. The sub-author role is explicitly excluded from the succession: it
  stays Opus 4.6 because the reason for choosing it is a bias profile
  (ambiguity-preserving, self-reference-friendly), not capability
- Model flags made mandatory, roster figures corrected, escalation and persona
  declaration documented (v3.7, 2026-07-27): the Path A procedure still taught
  launching cursor with no `--model`, which is precisely how the 2026-07-27
  incident happened — the CLI default had been changed to `claude-opus-4-8`
  outside this repository, so the roster ran three Anthropic slots out of five
  while still recording `cursor_composer2.5`. Path B now refuses a slot that
  does not name its model (INV-E5); Path A had no such guard and was still
  teaching the unguarded form, making this the one route where the incident
  could recur with no code in the way. Every CLI example now names its model.
  Separately, the roster figures were a generation stale throughout (6
  reviewers, `4/6`, Fable 5 in the roster) — corrected to 5 and `3/5`, with
  Fable 5 moved to the reserve container. Three capabilities that existed in
  the tool but appeared nowhere here are now documented: `escalate` (reserve
  observers), `persona_model` (personas running on a model other than the
  caller's), and the substance rule that keeps verdict-only replies out of the
  denominator. `reviewers_override` is recorded as removed and refused rather
  than silently ignored. Convergence guidance gained the point that had been
  carried only in operator memory: exhaustion of (a)+(b) findings, declared by
  the human, is the primary close — a reached ratio is neither necessary nor
  sufficient on its own

- Verdict determination hardened after a live failure (v3.7.1, 2026-07-27):
  round 4 of the escalation/persona implementation review recorded the persona
  team's REVISE as an APPROVE. The team's verdict was being re-derived by
  searching the assembled text, and a persona had quoted
  `{"overall_verdict": "APPROVE", ...}` inside a finding as an example of a
  defect; the search found the quotation before the `**Overall Verdict**:
  REVISE` on line 1. Three fixes: a structured submission now states its verdict
  as a field and nothing in its prose overrules it; the header is recognised
  only at the start of a line; and a JSON verdict is read by parsing a reply
  that *is* a JSON document rather than by scanning prose for an object. The
  residual limitation is recorded in § Substance and the denominator — the
  last-resort word heuristic still sees verdict words inside quotations, so
  state your verdict in the header when discussing reply shapes. Separately,
  INV-E2 was found to have been implemented by half: it asks that a counted
  reply *carry a verdict* and *have substance*, and only substance was checked,
  so an opening sentence with no judgement in it entered the denominator as a
  conservative REVISE — the exact shape that retired Fable 5, blocking
  convergence on nobody's verdict

- Three of round 4's own fixes reopened what they closed (v3.7.2, 2026-07-28):
  round 5 of the same implementation review found that each of the three
  verdict fixes recorded above had left a hole, and all three in the direction
  that passes. Start-of-line header matching does not exclude a quotation,
  because a line inside a fenced block starts a line — the header is now read
  from what the reviewer said, with fences and blockquotes excluded, and a
  reply that is entirely fenced is read whole because it is quoting nothing.
  Judging a structured reply by named keys (`reasoning`, `issue`) threw away a
  REJECT whose findings used `description` — the rule now asks whether anything
  was said in words, under any key. And the words that count as a verdict were
  two different lists, so `NO-GO` from a persona was a REJECT while `NO-GO`
  from an external slot was no judgement at all; there is now one list, with
  one precedence. Alongside these: `skip_reason` distinguishes five outcomes
  where it previously flattened three into `transport`; `total_configured` was
  renamed `observers_reporting` because it never counted what it claimed; the
  eased convergence rule after an exclusion now asks whether the denominator
  actually shrank rather than which reason fired; and a synchronous delegation
  writes the same storage layout as the parallel one, so the lock serialising
  two concurrent collects is no longer silently skipped

- Position replaces cleverness in verdict reading (v3.7.3, 2026-07-28): round 6
  was reviewed and rejected by five of six observers, all of them naming the
  same shape — the fixes of round 6 had reopened what they closed, in the
  direction that passes. Two were shipped defects: the header capture was
  written with `\s`, which includes the newline in Ruby, so it ran past the
  header into the following prose and recorded a stated APPROVE followed by
  "No blocking issues" as a REJECT; and the fence regex tracked neither fence
  length nor delimiter, so a four-backtick block quoting a three-backtick
  sample gave the quoted verdict the reviewer's vote. Rather than a fourth
  attempt at reading free text more carefully, the rule is now positional: the
  reviewer's verdict is the header the reply opens with, and the fence and
  blockquote machinery is deleted. The prompt asks for it there, and this test
  now pins that it does. Alongside: a partial escalation record is carried as
  recorded rather than completed with values the producing code cannot emit;
  only a token-shaped skip reason is carried into the record; and a row with no
  reason omits the field in the per-reviewer list as it already did in the
  composition.

  The round's other lesson was about testing, and it is recorded here because
  it generalises past this SkillSet: **a regex pinned by one literal example is
  free everywhere else**. Round 6's own mutation pass replaced whole functions
  and killed 21 of 21; the review's mutation pass went after regex internals —
  fence markers, character classes, digit ranges, word boundaries — and 18 of
  27 survived. Mutate the inside of a pattern, not only the pattern.

- Revision discipline, new-P0 convergence signal, and no_verdict seat
  diagnosis (v3.9.0, 2026-08-06): cross-thread analysis of 35 recorded runs
  (8 threads, 2026-08-03 → 08-06) established that raw P0 growth tracks
  additive revisions, not reviewer severity — every mechanism a revision
  added became the next round's battleground, deletions drew zero new P0s
  in every measured case, and both threads that converged did so within
  1–2 rounds of switching to subtractive revisions (one under a Fable 5
  reviser, one under the same Opus 5 orchestrator that had produced the
  additive explosion). New § Revision Discipline encodes the subtractive
  rule and the reviser-separation preference. § Convergence Rules gains the
  carryover/new P0 split, with "new (a)+(b) P0 = 0" as the machine-side
  freeze-candidate signal — neither thread ever reached its APPROVE ratio;
  both closed by (a)+(b) exhaustion + operator freeze. § Substance and the
  denominator gains the seat-environment diagnosis: `claude_cli_opus4.6`'s
  four-round no_verdict streak was the sandboxed seat colliding with
  implementation artifacts (pseudo-tool-calls, "repository not accessible"
  preamble), not a dead reviewer — the same seat counted every round on
  design artifacts in the same period. Analysis record: L2
  `mlr_p0_inflation_analysis_and_opus46_no_verdict_diagnosis_20260806`

- Reviewer incentive rule and the finding weight axis (v3.10.0, 2026-08-06):
  § Prompt Generation Rules gains the Reviewer incentive rule — reviewer
  prompts never mention finding counts, round numbers, or prior verdicts;
  convergence is measured orchestrator-side from the record, and prior
  findings are passed for closure verification only (rule #4 reworded
  accordingly, from "review history table" to "prior findings to verify").
  Motivating observation: an orchestrator told personas their counts were
  compared across rounds, and 3 of the round's 7 P0s were factually correct
  findings that cost nobody anything. In the same change the SkillSet
  (0.10.0) adds the weight axis mechanically: the prompt contract requires a
  `[consequence: who is harmed, and how]` clause on every P0, and
  aggregation records a P0 without one at P2, keeping the stated severity
  and the demotion reason beside it (`severity_stated` /
  `severity_demoted: consequence_missing`). Presence is checked
  mechanically; whether a stated consequence is real or trivial stays the
  orchestrator's call, per the (a)/(b)/(c) discipline. Handoff record: L2
  `handoff_mlr_finding_weight_axis_and_reviewer_incentive_20260806`

- The Path A pre-flight checklist states the closing condition, not the ratio
  (v3.10.1, 2026-08-17): the checklist line read "Convergence rule: 3/5 APPROVE
  (full) or 3/4 APPROVE (after exclusion)" while § Convergence Rules, 200 lines
  further down in a 1578-line file, states that the machine-side signal is
  "new (a)+(b) P0 = 0" and the ratio is auxiliary. The checklist is what is read
  before dispatch, so the ratio was the operative rule in practice regardless of
  what the prose said. The line now leads with the closing condition and keeps
  the two ratios beside it as reference values. No rule changed; the order in
  which a reader meets them did. Operator observation, 2026-08-17: attention
  failed to land on the P0 criterion round after round.

- The round dashboard ships with this entry, and its gate states the closing
  condition (v3.10.2, 2026-08-17): `scripts/render_dashboard.rb` reads a round
  summary as JSON on stdin, fills `assets/review_dashboard.html`, and writes a
  self-contained page — the worked example `resource_render` names in its own
  description and default output derivation (`render_dashboard.rb` →
  `dashboard.html`). Both files had existed only on one instance, so a fresh
  install had a tool whose documented example pointed at absent files, and an
  upgrade of this entry deleted them: the update decision hashes
  `multi_llm_review_workflow.md` alone, and the apply step replaces the whole
  entry directory, so anything under `assets/` or `scripts/` that the
  distribution does not carry is removed without appearing in the report. The
  input shape is assembled by hand and is not the review tool's payload:
  `{artifact, rounds:[{round, reviewers:[{id, label, pool: blocking|advisory,
  verdict, findings:[{class: a|b|c, text, severity}]}]}]}`. Findings may carry
  `carryover: true`, meaning raised in an earlier round and still open; an
  absent flag means new. The gate reports a **freeze candidate** when new
  (a)+(b) is zero, and shows the vote tally as a reference value beside it. It
  previously required every blocking-pool seat to APPROVE *and* the round's
  whole (a)+(b) count to be zero, which is unreachable in the state both
  2026-08 threads actually closed in — driven through the real renderer, a round
  with zero new and one carryover (a) at 1 of 2 seats approving reports
  "GATE NOT PASSED" under the old rule and "FREEZE CANDIDATE" under this one.

**Key insight**: Design reviews and implementation reviews find
**categorically different bugs**. Both phases are necessary.
