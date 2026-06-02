---
name: kairos_hook_projector_stage1_design_v0.1_draft
type: design_draft
version: 0.1
status: initial_draft_2026-05-25
date: 2026-05-25
author: Claude Opus 4.7 (1M context), interactive session with masaomi
prior_version: kairos_hook_projector_design_v0.2_draft (frozen, stage scaffolding source)
predecessor_stage: stage 0 commits 1-2 (skeleton + schema)
related:
  - kairos_hook_projector_design_v0.2_draft
  - kairos_hook_projector_v0.2_freeze_and_loop_observation_20260512
  - kairos_hook_projector_vs_plugin_projector_explanation_20260525
---

# `kairos_hook_projector` Stage 1 — Design Draft v0.1

## §1. Problem statement (invariant form)

Stage 0 established the skeleton, the mode_hooks envelope schema, and the
read-only status surface. The system is now able to *receive and validate*
mode_hooks declarations, but cannot yet *act on them*. The receptive side is
in place; the productive side is absent.

Stage 1 introduces the **compile path** — a deterministic mapping from a
schema-valid mode_hooks document to the SkillSet's own `plugin/hooks.json`
artifact. Composition (`extends` resolution, `conflict_policy` semantics)
remains deferred to Stage 4. Activation of the projection pipeline (the
actual write to `.claude/settings.json`) remains deferred to Stage 2.

**Inv-1.** Stage 1 closes the receptive/productive asymmetry within the
boundary of this SkillSet alone. No invariant established in Stage 0 is
weakened, and no surface owned by Stage 2+ is touched.

## §2. Design invariants

| # | Invariant | Rationale |
|---|---|---|
| Inv-1 | Stage 1 side effects are confined to artifacts internal to this SkillSet. Surfaces owned by Stage 0 (status tool, schema) and Stage 2+ (projection target) are not modified. | §1 + Inv-S0-6 carried forward |
| Inv-2 | Compilation is a pure function of (mode identity, schema-valid mode_hooks document). Same input pair yields byte-identical output. | Prop 1 (structural self-referentiality at compile layer) |
| Inv-3 | Compilation refuses any input declaring composition fields with semantic content. Primitive-only enforcement is structural, not conventional. | Stage scope discipline; composition is Stage 4 |
| Inv-4 | The absence of a mode_hooks document for a given mode is a well-formed input, not an error. Its compiled output is the well-formed empty artifact. | Fail-safe default; protects modes that opt out of hooks |
| Inv-5 | Every compilation produces a structured compile record describing the input identity, the output identity, the resolution path taken, and the time of compilation. | Prop 5 (constitutive recording) prerequisite |
| Inv-6 | The compile record is itself schema-validated against a Stage 1 record schema. Drift between record producer and record consumer is a compile-time error. | DoD-0-2 pattern carried forward |
| Inv-7 | When Stage 2 activates a recorded projection path, the compile record is the artifact that gets chain-recorded. Stage 1 does not itself record to chain; it produces a record-ready artifact. | Layer separation: Stage 1 owns semantics, Stage 2 owns activation |

## §3. Compile semantics (invariant form)

**Inv-C1.** Compilation consumes a pair (mode identity, mode_hooks document
state) and produces one of two outcomes: a compiled artifact accompanied by
a compile record, or a structured refusal accompanied by a refusal record.
There is no third outcome (no partial write, no silent skip).

**Inv-C2.** The structure of the compiled artifact is constrained to be
directly consumable by the existing `plugin_projector` pipeline without
further transformation. The Claude Code hooks format is treated as an
external substrate; the compiler maps mode_hooks semantics to that
substrate, and does not negotiate with consumers of the substrate.

**Inv-C3.** Refusal taxonomy is exhaustive over the input space: every
schema-valid input that the compiler cannot produce output for falls into a
named refusal category (schema-valid-but-composition, schema-valid-but-
target-substrate-impossible, etc.). The specific category set is §10 backlog.

**Inv-C4.** Refusal produces a refusal record of the same schema family as
the compile record. The distinction between success and refusal is encoded
in the record, not in its absence.

## §4. Ordering specification (Inv-O1 concretization)

**Inv-O1.** When multiple hooks attach to the same event within a single
schema-valid mode_hooks document, the execution order in the compiled
artifact is the **declaration order** as preserved by a structure-preserving
parser.

### Rationale

Stage 1 is primitive-variant-only by Inv-3. All hooks for a given mode
therefore originate from a single source document. Declaration order is the
simplest deterministic rule that does not require the operator to learn an
additional concept beyond the order they already wrote. Explicit priority
fields would be premature here: they earn their cost only when multiple
sources contribute hooks to the same event, which is a Stage 4
(composition) concern.

Declaration order has two cost paths the operator must accept:

1. Reordering hook entries in the source document changes execution
   semantics. This is observable in the compile record's resolution path.
2. The choice of parser matters. Implementations must use parsers that
   preserve array order through the parse-then-emit cycle.

Both costs are paid in plain sight: (1) is visible in the source document;
(2) is enforced by Inv-O2 below.

**Inv-O2.** The parser used for mode_hooks ingestion must preserve array
order through any intermediate representation. This is verified by a
test fixture that round-trips an array-ordered input through the parser and
the compiler.

**Inv-O3.** The compile record enumerates each compiled hook as a
positional tuple within its event. This makes the realized ordering
auditable from the record alone, without re-reading the source document.

## §5. Default behavior for modes without mode_hooks

**Inv-D1.** A mode for which no mode_hooks document is provided compiles to
the well-formed empty artifact (an artifact carrying zero hooks). This is
distinct from a refusal: it is a successful compilation whose output
happens to be empty.

**Inv-D2.** The well-formed empty artifact is byte-identical regardless of
which mode is being compiled. This is a structural property that simplifies
the projection pipeline's idempotency reasoning.

**Inv-D3.** The presence of an empty mode_hooks document (one that exists
but declares zero hooks) is observationally indistinguishable at the
artifact layer from the absence case (Inv-D1). It is distinguished only at
the compile record layer, where the resolution path records which case
applied.

## §6. Stage 1 DoD invariants

| # | DoD |
|---|---|
| DoD-S1-1 | A compile entrypoint exists. Its accepted inputs are exhaustively (mode identity, schema-valid mode_hooks document) and (mode identity, absence). |
| DoD-S1-2 | Tests assert refusal on each refusal category named in Inv-C3 (at minimum: composition-content present, schema-invalid input). |
| DoD-S1-3 | Tests assert declaration-order preservation across a multi-hook same-event input that includes at least three hooks. |
| DoD-S1-4 | An integration test confirms that the compiled artifact, when fed to the existing `plugin_projector` test harness, is accepted without modification. (This test exists in Stage 1; it does not yet trigger real projection — that is Stage 2.) |
| DoD-S1-5 | Stage 0 boot-time assertion (DoD-0-4 of v0.2 design) continues to pass after Stage 1 implementation. No surface owned by Stage 0 or Stage 2 is touched. |
| DoD-S1-6 | A compile record schema exists and is self-validating, mirroring the DoD-0-2/-0-3 pattern established in Stage 0. |
| DoD-S1-7 | The compile record schema and the compile record producer share a single source of truth (the producer reads the schema, or both are generated from a shared specification). Drift between them is a compile-time error. |

## §7. Failure modes and invariant-form mitigations

| Failure mode | Mitigating invariant |
|---|---|
| Compilation produces non-deterministic output | Inv-2 (pure function) + Inv-O2 (parser order preservation) |
| Operator writes `extends` expecting composition to work | Inv-3 + Inv-C3 (structural refusal with named category) |
| Compile record drifts from chain-record consumer expectations | Inv-6 + DoD-S1-7 (shared source of truth) |
| Mode without mode_hooks errors at projection time | Inv-D1 + Inv-D2 (well-formed empty artifact) |
| Stage 1 inadvertently writes to .claude/settings.json | Inv-1 + Stage 0 boot-time assertion (DoD-0-4) carried forward |
| Refusal silently produces partial output | Inv-C1 (no third outcome) + Inv-C4 (refusal is encoded, not absent) |
| Stage 1 compiler invoked with an input the schema accepts but Stage 1 cannot handle | Inv-C3 (exhaustive refusal taxonomy) |
| Ordering changes silently across implementations | Inv-O2 + Inv-O3 (parser invariant + auditable record) |

## §8. Open questions (Stage 2+)

| # | Content | Resolved at |
|---|---|---|
| OQ-1 | When does Stage 1 compilation actually fire? (operator-explicit invocation vs MCP server boot-time vs both) | Stage 2 |
| OQ-2 | Persistence policy for compile records (in-memory only, on-disk, or chain-recorded directly by Stage 1) | Stage 2 |
| OQ-3 | Whether a single invocation compiles one mode or many | Stage 2 |
| OQ-4 | Recompilation skip policy when input is unchanged (digest-based skip vs always-recompile vs force-flag) | Stage 2 |
| OQ-5 | Refusal taxonomy concrete category set (Inv-C3) | Stage 1 implementation phase |
| OQ-6 | Compile record schema concrete field set | Stage 1 implementation phase |

OQ-5 and OQ-6 are intentionally pushed to implementation phase rather than
resolved in this design draft, in keeping with the v0.2 freeze decision that
deferred residual mechanism questions to implementation learning.

## §9. Non-goals

- Composition (`extends` resolution, `conflict_policy` semantics) — Stage 4
- Activation of projection to `.claude/settings.json` — Stage 2
- Multi-source ordering across variants — Stage 4
- Auto-resolution policy semantics and operator consent capture — Stage 4
- Reverse projection (Claude Code hook firing → KairosChain) — Stage 7
- CLI subcommand surface (`kairos-chain hooks ...`) — Stage 2

## §10. Mechanism backlog (intentionally deferred)

The following are mechanism choices that any implementation satisfying
§2-§7 is free to make, and are not part of this design's contract:

- Concrete YAML field names for hook entries within events
- The function-call shape of the compile entrypoint (positional vs keyword
  parameters, error class hierarchy)
- File paths and naming for compile record persistence
- The specific field set of the compile record schema (beyond Inv-5's
  enumeration of categories that must be captured)
- The concrete category names within the refusal taxonomy (Inv-C3)
- Hook entry validation rules beyond the schema-level envelope checks (e.g.,
  event name enumeration, hook command shape)
- The choice of YAML parser library, provided Inv-O2 is satisfied

## §11. Relationship to v0.2 frozen design

This Stage 1 draft is the concretization of §6 row "stage 1" of the v0.2
frozen design. The invariants in §2-§5 above are net additions over v0.2;
they refine but do not contradict any v0.2 invariant. Specifically:

- v0.2 Inv-1 (deterministic invocation path existence): Stage 1 produces
  the artifact that Stage 2 will use to realize the deterministic path.
- v0.2 Inv-2 (no new projection path): preserved by Inv-1 (this draft) +
  the projection-pipeline-reuse constraint of Inv-C2.
- v0.2 Inv-O1 (ordering decided at composition output time): refined by
  §4 above to "declaration order at single-source compile time" — this is
  the primitive-variant specialization of v0.2 Inv-O1, not a replacement.
- v0.2 Inv-7 (hook composition change is chain-recorded across all paths):
  this draft's Inv-7 narrows the layer responsibility (Stage 1 produces
  the recordable artifact; Stage 2 owns the activation that triggers
  recording), without changing the v0.2 invariant's coverage.

If any reviewer identifies a conflict between this draft and the v0.2
frozen design that is not explicitly reconciled above, this draft is the
draft that must be revised. The v0.2 freeze is the load-bearing baseline.
