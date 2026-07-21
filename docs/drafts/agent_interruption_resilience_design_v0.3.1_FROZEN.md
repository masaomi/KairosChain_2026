# Agent SkillSet — Interruption Resilience, Slice A: Resumable Step Execution with At-Most-Once Advance

Status: **FROZEN v0.3.1** (design-by-invariant). Multi-LLM review R1 REVISE(2/6) → R2 4/6 → R3 5/6, persona unanimity 3/3 at R2 and R3. v0.3.1 applies R3's non-invariant clarifications only (no invariant or body change; no new subsection).
Track: interruption resilience (progress survivability). Separate document from the loop-quality track (self-verification / termination / progress read-back), by decision.
Origin: L2 `handoff_agent_skillset_interruption_resilience_20260721`
Layer: SkillSet (agent) change only. No L0/core change.
Section note: §§8–10 are intentionally reserved so the mechanism backlog keeps its established §11 heading across documents; the jump from §7 to §11 is a convention, not missing content.

## 1. Problem

During a real design session (2026-07-20/21), the orchestrating LLM's API stalled two to three times. The agent session's server-side state was intact throughout — observation, decision payload, and checkpoint records were all persisted — yet the loop fell into waiting for human input, because the only entity that could issue the next call had died. The failure is not loss of memory; it is loss of the driver, and nothing on the server side lets a fresh driver resume deterministically.

Three structural facts about the current step tool make a driver interruption costly rather than merely annoying:

1. A step executes its cognitive phases synchronously inside a single MCP call. When an internal LLM call runs long, the entire call is hostage to the caller's survival: past the harness threshold it becomes a background task whose retrieval again depends on the originator being alive.
2. A re-issued call is not a safe replay, and nothing serializes two callers. A stall is not a crash: the stalled driver may still be alive when a fresh driver is introduced, so two callers can act on the same session at once. The step tool dispatches on whatever state is currently persisted, with no anchor tying a call to the state it was issued against and no exclusion between concurrent callers — so a retry, or two live callers, can execute the same action twice. This is a live double-execution hazard independent of any API outage.
3. The status tool reports state but not the next move, so a resuming driver must reconstruct intent from raw state.

## 2. Goal and non-goals

Goal: after a **driver interruption** (the caller stalls, dies, or is replaced), a fresh caller can resume the loop deterministically from persisted state alone, with no completed work lost, no side-effecting action executed more than once, and no attempted-but-unconfirmed action silently dropped. Recovery reads the session's own next-move answer and re-issues from there; the cost of the interruption is bounded by waiting for any in-flight phase to finish, not by lost or duplicated work.

Non-goals for this slice (tracked separately, per handoff):

- Preventing the API outage itself (outside the SkillSet boundary).
- Harness-side watchdog hooks (track B; needs no design).
- Survivability of a **delegated executor's own crash** — heartbeat robustness and partial-result retention (track C). The single boundary statement for this is §6; §2 does not restate it.
- Autonomy-level switching during a session (track D; contingent on this slice).

## 3. Invariants

**INV-A1 (driver independence).** No server-side progress of a step depends on the initiating caller remaining alive after the call returns. A step whose execution has not completed when its call returns leaves behind a resumable handle under which execution continues under server-side ownership. Correctness does not depend on predicting in advance whether a step will be short or long: whether execution finished inline or continues under a handle, the remaining invariants hold identically — inline completion is an optimization, not a correctness boundary.

**INV-A2 (serialized atomic advance).** Every operation that advances a session's *persisted state* is serialized against all other such operations on that session and commits atomically: the recorded transition becomes visible in full or not at all, and no two operations advance the same session concurrently. This governs the store; it does not by itself make an external side effect atomic — that gap is the subject of INV-A3.

**INV-A3 (anchored at-most-once, with no silent drop).** Every state-advancing operation, whether or not it carries a human approval, carries an anchor identifying the state it was issued against; a re-issue whose anchor matches already-completed work returns the recorded outcome without re-executing, and an anchor that does not match the current state is rejected with the current state, never silently applied. For an operation carrying an **external side effect**, the effect is never executed more than once, and an effect whose outcome is unconfirmed after an interruption is never assumed to have happened and never assumed not to have happened: it is surfaced as an unresolved point in the derivable next move (INV-A4), where the human gate (INV-A5) adjudicates re-attempt. At-most-once for the effect; never a silent double-apply and never a silent drop. (Whether an unconfirmed effect can be resolved by the system or must reach the human gate depends on whether the effect is confirmable — a §11 mechanism concern; the invariant is that it is never silently resolved either way.)

**INV-A4 (monotone derivable recovery).** From persisted session state alone the system determines a single unique next move, and that state reflects exactly the transitions that have committed — never a partial or superseded one. When an unresolved side-effect point exists per INV-A3, its adjudication *is* that unique next move (it takes precedence over any other pending advance), so uniqueness is preserved rather than contested. A fresh driver therefore recovers by reading the next move and re-issuing it; no reconstruction of intent by the caller is required.

**INV-A5 (human-gate semantics preserved).** At-most-once resumption means the re-transmission of an identical judgment is safe; it never means a judgment is skipped. Every state that required an approval before this change still requires exactly one approval after it, and the adjudication of an unresolved side-effect (INV-A3) is itself such a gated judgment. Delegation changes when execution happens, not who decides.

## 4. Rationale

The invariants are one idea seen from several sides: the session's persisted state is the single source of truth for progress, and every party — the executing server, a retrying caller, a fresh caller after a stall, even two callers briefly co-existing — interacts with that truth through serialized, atomic, anchored transitions that cannot corrupt it, double-apply it, or silently drop a pending effect. A1 removes the caller from the liveness path; A2 makes every *store* advance indivisible and mutually exclusive, which closes the "stall is not a crash" concurrency case that motivated the slice; A3 makes every *effect* at-most-once and, where an interruption leaves its outcome unknowable, refuses to guess — it hands the unresolved point to the next move rather than dropping or repeating it; A4 makes recovery a read rather than a reconstruction; A5 states what the truth never absorbs — the human's judgment.

The realized shape reuses the delegation the review SkillSet already runs in production, whose resumable-handle state outlived exactly this outage class. That reuse is why this is expressible as a SkillSet change rather than new core infrastructure; the reliability guarantee, however, rests on the invariants above, not on the precedent.

## 5. Philosophy alignment

- Expressed entirely as an agent SkillSet change; core stays untouched (partial autopoiesis: the loop closes at the capability level, execution substrates remain external).
- Structural self-referentiality: the resilience mechanism for the loop is built from the same delegation structure a SkillSet already defines — the system heals its loop with its own vocabulary.
- Constitutive recording: the anchored, atomic transition record makes each advance — including each human judgment and each unresolved-effect adjudication — a first-class, replay-safe entry in the session's history, so recording remains constitutive of what happened rather than merely evidential of it.
- Orthogonal to the guard track: guard fixes what may be decided (mandate acceptance); this slice fixes how progress survives (plumbing). Neither weakens the other.

## 6. Boundary with track C

This is the single boundary statement for executor-crash survivability. This slice guarantees serialized, atomic, at-most-once, no-silent-drop advance at step/phase granularity (INV-A2/A3) for the driver-interruption scenario. Finer-grained survivability *inside* a delegated executor — bounding the latency of re-attempt after the executor's own crash, detecting a dead executor without a driver re-issue, per-phase partial results, heartbeat robustness — is track C, layered under the same handle without changing this slice's invariants. The two ship independently: A without C keeps every advance correct (never lost, never double-applied, never silently dropped) on executor crash, and defers to C only the *speed* at which such a crash is detected and recovered. Under A alone, a dead executor is discovered when a driver next reads the state and re-issues; who triggers that re-issue is the driver, until C adds server-side detection.

## 7. Compatibility

For sessions created under this change, correctness follows from the invariants without migration.

For sessions already in flight at the moment of upgrade, this slice makes a scoped guarantee and states its limit honestly. Their persisted state carries no anchor yet; the first post-upgrade advance establishes the anchor from the state it reads (the same first-advance semantics every new session has), after which the invariants hold, with no replay of pre-upgrade history required. An operation that was already mid-execution under the old synchronous model at the upgrade instant is not retroactively anchored — it completes or fails under the old model, and the anchor regime governs only advances issued after upgrade; this slice does not claim to protect a call that straddles the upgrade. That straddle window is inherent to changing an execution regime and cannot be closed by any invariant (a call already running cannot retroactively acquire a property the new version defines); it is instead closed operationally by quiescing in-flight operations before upgrade — an operational procedure noted in §11, not an invariant.

The change does alter one caller contract: a previously-always-inline long step may now return a handle instead of an inline result, so a caller that assumed inline completion must read the handle. This is a genuine surface change, not a pure superset; INV-A1 guarantees it introduces no *incorrectness* (state stays consistent either way), but the caller-facing surface decision — whether the inline path is preserved, auto-detected, or caller-selected — is a §11 item and is deliberately left open here rather than claimed resolved.

## 11. Mechanism backlog (not part of the reviewed body)

Deferred mechanism choices, to be settled at implementation time under the invariants above:

- Handle format and lifetime; whether the delegation handle and the INV-A3 anchor are the same identifier or distinct; reuse vs. adaptation of the review SkillSet's pending-token store.
- Anchor representation for INV-A3 (state fingerprint vs. monotonic step counter vs. both).
- Serialization mechanism for INV-A2 (per-session lock, compare-and-swap on a version, single-writer worker) and the atomic-commit mechanism (atomic rename / fsync ordering).
- The side-effect guard for INV-A3: how an outstanding intent's outcome is determined on resume (effect-level idempotency key, completion marker, external probe — an external probe populates persisted state, so INV-A4's "from persisted state alone" still holds: the probe feeds the state the next move is derived from, it does not bypass it) and how the unresolved point is represented in the next move.
- Wait-surface polling/timeout parameters; whether the agent wait tool shares the review wait tool's status enum; the exact call sequence a resumed caller issues when work is still in flight (status, then wait, then resume) vs. ready (status, then resume). The resume interaction count is a mechanism property, not a headline guarantee.
- Where the delegated executor lives (detached worker reuse vs. agent-specific worker) and its logging.
- next_move hint vocabulary and callable surface for the status tool (INV-A4).
- The caller-contract surface for previously-always-inline steps (§7): preserve inline, auto-detect the window, or caller-select.
- **Operational (not an invariant):** upgrade-drain procedure — quiescing in-flight operations before deploying this change removes the §7 straddle window, whose double-execution hazard the invariants cannot retroactively close for a call already running under the old model.
