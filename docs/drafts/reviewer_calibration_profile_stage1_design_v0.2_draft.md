# Reviewer Calibration Profile — Stage 1 Design (v0.2 draft)

**Status:** design draft, v0.2. Under multi-LLM review (round 2).
**Scope:** L1 capability design (metacognitive measurement layer over the existing
multi-LLM review workflow). NOT core/L0 infrastructure.
**Register:** design-by-invariant.
**Authorship:** 4.6 sub-author drafted the revision; 4.7 integrated (reject log at end).

## Provenance
Adapted from the "Hindsight calibration" concept observed in an external personal-AI
harness (gbrain), reduced to a thin first stage. Adopts the measurement/surfacing idea;
rejects the source's resolve-oriented contradiction handling and value-neutral framing.

## 1. Intent
A capability that derives, per multi-LLM reviewer, a calibration profile from the
existing constitutive record: recorded history of past multi-LLM reviews (per-finding
(a)/(b)/(c) classification and verdicts) plus subsequently recorded dispositions (what
was internalized into L0/L1, revised, or shipped). The profile characterizes, per
reviewer and per section-register, the historical distribution of that reviewer's
findings across (a) deployment-grounded, (b) philosophy-aligned, (c) value-divergent,
and their eventual disposition. The profile is surfaced to the orchestrator at
review-aggregation time as calibration metadata. (masa mode currently hand-writes
reviewer-bias characterizations; stage 1 turns the hand-written profile into a read of
the record.)

## 2. Non-goals
- Not an automated gate; does not change any finding's blocking status.
- Not a port of the source system's typed-claim substrate; no new primary data store.
- Not a resolver of disagreement; never dismisses or downweights automatically.
- Not a forecasting/scoring engine in this stage.
- Not a new evidential side-channel competing with the blockchain record.

## 3. Invariants

**Inv-1 (Derived-from-constitutive-record).** The profile is a pure function of
constitutively recorded substrate; data that has not itself been recorded into the
blockchain layer is not eligible input to the derivation. Under insufficient recorded
history, the derivation must declare insufficiency rather than emit a value — silence
over low-n noise. *Justification: Prop 5 — recording is constitutive; a derivation
consuming unrecorded or evidential-only data would claim a being-status it has not
earned, and emitting confident output from sparse substrate misrepresents the record's
depth.*

**Inv-2 (Surfacing-not-deciding).** The profile may inform interpretation; it may never
by itself alter a finding's blocking status or P0 count. *Justification: the capability
is measurement, not governance; collapsing a measurement into a decision would bypass the
multi-agent review structure.*

**Inv-3 (Calibration-not-dismissal).** A profile value is a statement about historical
tendency in a register, never a verdict on a present finding; (c)-prone in one register
stays (a)-capable in another. *Justification: tendency is not destiny; conflating the two
annihilates the reviewer's capacity to surprise the system, which is where
incompleteness-as-driver (Prop 6) enters.*

**Inv-4 (Held-disagreement / presentation-symmetry).** When a present finding
contradicts the profile, surface and hold — do not resolve. Surfacing a held
contradiction must be presentation-symmetric: it must not direct the orchestrator toward
accepting or rejecting the present finding. Holding is not nudging. *Justification:
Knowledge Ethos — epoche suspends contradiction; any asymmetric presentation of a held
tension is a covert resolution that violates the suspension. The act of surfacing carries
implicit weight; symmetry is the bound that keeps surfacing from becoming soft
dismissal.*

**Inv-5 (Contestable-profile).** Every profile value is provisional, surfaceable,
revisable, carries provenance, and is overridable by a recorded human decision. A human
override is itself a recorded event that enters the constitutive record and becomes input
the derivation consumes on subsequent reads — Inv-1 (derived-from-record) therefore
holds through the override, because the override enlarges the record rather than
departing from it. *Justification: Prop 10 — contestability from within; the
reconciliation with Inv-1 follows from Prop 5: a human override that is constitutively
recorded is not an exception to derivation-from-record but a new datum within it.*

**Inv-6 (Recorded-influence).** Any instance where a profile value influences an
L0/L1-affecting decision — whether the influence path is direct (automated consumption)
or human-mediated (a human reads the profile, then acts on L0/L1) — is itself
constitutively recorded. *Justification: Prop 5 — influence on the system's being must
be recorded; an unrecorded human-mediated path is a constitutive gap regardless of
whether the intermediary is silicon or carbon.*

**Inv-7 (Reflexive-bias / non-circularity).** The derivation depends on prior (a)/(b)/(c)
labels produced by a biased LLM classifier that is inside the frame it measures;
represent as bounded confidence, not ground truth. Where the same agent both produces the
classification and derives the profile, the derivation must not be represented as
independent of the classification it consumes. *Justification: LLM bias awareness must
be reflexive — the classifier is inside the frame; asserting independence where the
derivation loop is closed would be a false claim of externality.*

**Inv-8 (Incompleteness).** The profile is never complete or final; it is a moving read
that the next review cycle may revise. *Justification: Prop 6 — incompleteness is the
driving force, not a defect; a "finished" profile would claim closure the system cannot
possess.*

**Inv-9 (No-convergence-bias / observability).** Surfacing must not bias the review loop
toward premature APPROVE or convergence. The capability's effect on convergence rate must
be observable against the recorded review history, so this invariant can be evaluated
against the experiment's own revert criteria. *Justification: an unfalsifiable
anti-convergence claim is itself a convergence toward self-exemption; observability is
the bound that keeps the invariant contestable per Prop 10.*

**Inv-10 (Locality / instance boundary).** Derivation is local to the instance's own
constitutive record. Reviewer identity and profile history must not cross the instance
boundary without explicit recorded opt-in; the default is non-export. No global reviewer
authority emerges without that opt-in. *Justification: P2P-natural — no centralized
authority; the Meeting Place exchanges capabilities, not reviewer dossiers, unless the
reviewer's recorded consent makes the crossing constitutive rather than extractive.*

## 4. Philosophical consistency map

| Principle | Invariants | Note |
|---|---|---|
| Prop 5 (constitutive recording) | Inv-1, Inv-5, Inv-6 | Inv-1 requires constitutive substrate; Inv-5 reconciles override with derivation-from-record by recording the override itself; Inv-6 closes the human-mediated gap. |
| Prop 6 (incompleteness as driver) | Inv-3, Inv-8 | Tendency != destiny; the profile never closes. |
| Prop 10 (contestability) | Inv-5, Inv-9 | Every value revisable; anti-convergence claim is itself held to observability. |
| Knowledge Ethos (epoche) | Inv-4 | Presentation-symmetry bounds surfacing so that holding does not collapse into nudging. |
| LLM bias / reflexivity | Inv-7 | Classifier-inside-the-frame; circularity bounded by non-independence disclosure. |
| P2P-natural / no central authority | Inv-10 | Identity and profile stay local; opt-in is recorded and constitutive. |
| Merely-recursive honesty | all | This capability is metacognitive measurement (a derivation over recorded classifications), not structural self-referentiality. It reads the record of what reviewers did; it does not constitute the reviewers' capacity to review. Claiming structural self-reference would overstate the capability's ontological status. |

## 5. Backlog (deferred mechanism choices)
- Profile representation/format; where derivation runs; register/section taxonomy
  granularity; later-stage forecast; interaction with the Anthropic persona unanimity
  gate; confidence representation; insufficiency-threshold calibration; convergence-rate
  observability instrumentation; presentation-symmetry verification method; opt-in
  consent mechanics for cross-instance exchange.

---

## Integrator reject log (4.7) — process record, not part of the design body

- **Accepted in full:** the 4.6 sub-author's consolidation of B1–B8 into the existing
  ten invariants (no new labelled invariants), honoring the round-1 (c) finding that the
  draft was enumeration-heavy.
- **Considered, kept folded:** splitting Inv-1 into substrate-eligibility + insufficiency-
  declaration. Kept folded — both are input-validity discipline, and splitting would
  re-introduce the enumeration heaviness flagged in round 1.
- **Rejected from body:** adding an invariant restating the (a)+(b)-only P0 aggregation
  rule. That rule belongs to the existing multi-LLM review workflow, not to this
  capability; importing it here would be scope creep. Noted as a relation only.
- **Rejected (per aggregation rule):** the round-1 Codex/Cursor P0s demanding consumer
  API / payload shape / which-layer-writes / register taxonomy. Classified (c)
  value-divergent against the design-by-invariant + anti-enumeration register; deferred
  to §5 backlog, not added to the body.
- **Round-2 watch item (non-blocking):** Inv-5 transient — between an override event and
  the next derivation read, the surfaced value may momentarily diverge from the pure
  function of the (now enlarged) record. Acceptable; flagged for observation, not fixed.
