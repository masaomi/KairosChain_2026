# Reviewer Calibration Profile — Stage 1 Design (v0.1 draft)

**Status:** design draft, v0.1. Under multi-LLM review.
**Scope:** L1 capability design (metacognitive measurement layer over the existing
multi-LLM review workflow). NOT core/L0 infrastructure.
**Register:** design-by-invariant. State invariants, not mechanisms. Mechanism
choices live in §5 backlog.

## Provenance

Adapted from the "Hindsight calibration" concept observed in an external personal-AI
harness (gbrain), deliberately reduced to a thin first stage. This design **adopts the
measurement/surfacing idea** and **rejects** the source system's two incompatible
framings: (i) resolve-oriented contradiction handling, and (ii) value-neutral tooling.
KairosChain-philosophy compatibility is the gating concern, expressed as Inv-1..Inv-10
below.

## 1. Intent

A capability that derives, per multi-LLM reviewer, a **calibration profile** from
KairosChain's *existing* constitutive record: the recorded history of past multi-LLM
reviews (per-finding (a)/(b)/(c) classification and verdicts) together with the
subsequently recorded dispositions (what was internalized into L0/L1, what was revised,
what shipped). The profile characterizes, per reviewer and per section-register, the
historical distribution of that reviewer's findings across:

- (a) deployment-grounded — spec violation, runtime bug, data corruption, concurrency hazard;
- (b) philosophy-aligned — deviation from the project's stated design principles;
- (c) value-divergent — reviewer style preference / generic best-practice not entailed by the principles;

and the eventual disposition of those findings. The profile is **surfaced** to the
orchestrator at review-aggregation time as calibration metadata.

masa mode currently hand-writes reviewer-bias characterizations (§ LLM Bias Awareness).
The constitutive record already contains the evidence to derive them. Stage 1 turns the
hand-written profile into a *read of the record* — nothing more.

## 2. Non-goals

- Not an automated gate. Does not change any finding's blocking status.
- Not a port of the source system's typed-claim ("facts/takes") substrate. No new
  primary data store.
- Not a resolver of disagreement. Never dismisses or downweights a finding automatically.
- Not a forecasting / scoring engine in this stage.
- Not a new evidential side-channel competing with the blockchain record.

## 3. Invariants

**Inv-1 (Derived-from-record).** The profile is a pure function of the existing
constitutive record; it introduces no new primary data store.
*Why:* a side-channel would create an evidential record competing with the constitutive
one (Prop 5). The profile must be a re-reading of recorded being, not a parallel ledger.

**Inv-2 (Surfacing-not-deciding).** The profile may inform interpretation of a finding's
classification; it may never, by itself, alter a finding's blocking status or P0 count.
*Why:* automated dismissal is the legalistic / thin-continuation failure masa mode guards
against. The human decision stays load-bearing.

**Inv-3 (Calibration-not-dismissal).** A profile value is a statement about a reviewer's
historical tendency in a register, never a verdict on a present finding. A reviewer
characterized as predominantly (c) in one register remains fully (a)-capable in another.
*Why:* masa mode states this explicitly; dismissal-by-profile would discard
deployment-grounded signal that is independent of reviewer bias.

**Inv-4 (Held-disagreement).** When a present finding contradicts the reviewer's profile,
the contradiction is surfaced and held, not resolved.
*Why:* Knowledge Ethos — suspend the demand for resolution (epoché); the dimension at
which both coexist may differ from the dimension the conflict is posed at.

**Inv-5 (Contestable-profile).** Every profile value is itself a provisional, surfaceable,
revisable claim carrying its derivation provenance, and is overridable by a recorded human
decision.
*Why:* Prop 10 contestability floor — a norm/claim that cannot be contested from within is
incompatible with the system.

**Inv-6 (Recorded-influence).** Any instance in which a profile value influences an
L0/L1-affecting decision is itself recorded in the constitutive record.
*Why:* Prop 5 — influence on the system's being must be recorded, closing the loop so the
profile cannot silently shape L0/L1.

**Inv-7 (Reflexive-bias).** The profile's derivation depends on prior (a)/(b)/(c)
classifications produced by an LLM with its own bias; the profile represents this as
bounded confidence, not as ground truth.
*Why:* masa mode requires reflexive bias awareness — the classifier is not outside the
frame it classifies.

**Inv-8 (Incompleteness).** The profile is never treated as complete or final; it is a
moving read that strengthens or weakens as the record grows.
*Why:* Prop 6 — incompleteness is the driving force of evolution, not a defect to eliminate.

**Inv-9 (No-convergence-bias).** Surfacing calibration must not bias the review loop toward
premature APPROVE / convergence.
*Why:* this is an explicit revert criterion of the multi-LLM review experiment; a profile
that manufactures convergence destroys signal rather than improving it.

**Inv-10 (Locality).** Profile derivation is local to the instance's own record; it
introduces no global reviewer authority shared across instances absent explicit recorded
opt-in.
*Why:* P2P-natural design, no central source of truth.

## 4. Philosophical consistency map

| Principle | Invariant(s) |
|---|---|
| Prop 5 — constitutive recording | Inv-1, Inv-6 |
| Prop 6 — incompleteness as driver | Inv-8 |
| Prop 10 — contestability floor | Inv-5 |
| Knowledge Ethos — suspend, not resolve | Inv-4 |
| LLM bias awareness (reflexive) | Inv-3, Inv-7 |
| Anti-premature-convergence (experiment revert criteria) | Inv-9 |
| No centralized control / P2P-natural | Inv-10 |
| Surfacing-not-deciding (human stays in loop) | Inv-2 |

**merely-recursive honesty.** This capability is metacognitive *measurement* (a cognitive
register), distinct from KairosChain's *structural* self-referentiality (Prop 1). It makes
no claim to the latter, and must not be presented as an instance of it.

## 5. Backlog (mechanism choices deferred — out of scope for this draft)

- Representation/format of the profile.
- Where derivation runs (a workflow step vs on-demand).
- Register / section-type taxonomy and its granularity.
- Whether a later stage adds a disposition-outcome forecast.
- Interaction with the Anthropic persona unanimity gate.
- Threshold/confidence representation for Inv-7 bounded confidence.
