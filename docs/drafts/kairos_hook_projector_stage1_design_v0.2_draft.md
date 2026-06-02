---
name: kairos_hook_projector_stage1_design_v0.2_draft
type: design_draft
version: 0.2
status: revised_2026-05-26
date: 2026-05-26
author: Claude Opus 4.6 (sub-author), merged by Claude Opus 4.7 (integrator)
prior_version: kairos_hook_projector_stage1_design_v0.1_draft
revision_basis: round 1 multi-LLM review (9 deduplicated P0 (a)+(b) findings)
related:
  - kairos_hook_projector_design_v0.2_draft (frozen baseline)
  - kairos_hook_projector_stage1_design_v0.1_draft
  - goal_hook_projector_stage1_design_revision
---

# `kairos_hook_projector` Stage 1 — Design Draft v0.2

## §1. Problem statement (invariant form)

Stage 0 established the skeleton, the mode_hooks envelope schema, and the
read-only status surface. The system is now able to *receive and validate*
mode_hooks declarations, but cannot yet *act on them*. The receptive side is
in place; the productive side is absent.

Stage 1 introduces the **compile path** — a deterministic mapping from a
schema-valid mode_hooks document to the SkillSet's own compiled hook
artifact. Composition (`extends` resolution, `conflict_policy` semantics)
remains deferred to Stage 4. Activation of the projection pipeline (the
actual write to the harness configuration surface) remains deferred to
Stage 2.

**Inv-1.** Stage 1 closes the receptive/productive asymmetry within the
boundary of this SkillSet alone. No invariant established in Stage 0 is
weakened, and no surface owned by Stage 2+ is touched.

## §2. Design invariants

| # | Invariant | Rationale |
|---|---|---|
| Inv-1 | Stage 1 side effects are confined to artifacts internal to this SkillSet. Surfaces owned by Stage 0 (status tool, schema) and Stage 2+ (projection target) are not modified. | §1 + Inv-S0-6 carried forward |
| Inv-2 | Compilation is a pure function of (mode identity, schema-valid mode_hooks document) in the following sense: for a given input pair, the **domain-semantic content** of the compiled artifact is identical. Metadata attached to the compile record (wall-clock timestamp, environment identifiers) is excluded from the purity projection. | Prop 1 (structural self-referentiality at compile layer). Scoping purity to domain-semantic content avoids contradiction with Inv-5's recording requirement. |
| Inv-3 | Compilation refuses any input declaring composition fields with semantic content. Primitive-only enforcement is structural, not conventional. | Stage scope discipline; composition is Stage 4 |
| Inv-4 | The absence of a mode_hooks document for a given mode is a well-formed input, not an error. Its compiled output is the well-formed empty artifact. | Fail-safe default; protects modes that opt out of hooks |
| Inv-5 | Every compilation produces a structured compile record describing the input identity, the output identity, the resolution path taken, and the time of compilation. | Prop 5 (constitutive recording) prerequisite |
| Inv-6 | The compile record is itself schema-validated against a Stage 1 record schema. Drift between record producer and record consumer is a compile-time error. | DoD-0-2 pattern carried forward |
| Inv-7 | When Stage 2 activates a recorded projection path, the compile record is the artifact that gets chain-recorded. Stage 1 does not itself record to chain; it produces a record-ready artifact. | Layer separation: Stage 1 owns semantics, Stage 2 owns activation |
| Inv-7nr | Inv-7 carries forward v0.2 Inv-7's "across all paths" guarantee. Stage 1's layer narrowing (producing the record-ready artifact rather than chain-recording directly) does not reduce the coverage of v0.2 Inv-7: every change path that v0.2 Inv-7 covers (compile, project, unproject, evolve) remains covered when Stage 2 takes ownership of activation. No path that was chain-recorded under v0.2 Inv-7 may become unrecorded under this narrowing. | Non-regression clause for v0.2 Inv-7 |
| Inv-8 | The compile path produces its compile record and compiled artifact as return values to its caller. Stage 1 does not persist compile records to any storage medium. Persistence decisions (filesystem, chain, in-memory cache) belong to the caller (Stage 2 or an operator invocation surface). | Record lifecycle clarity; avoids orphaned records when Stage 2 has not yet activated |
| Inv-9 | The mode identity supplied to compilation is bound to the `mode_name` field within the mode_hooks document. If the external mode identity and the document's declared `mode_name` diverge, compilation refuses with a binding-mismatch refusal. | Identity integrity; prevents a document authored for mode A from being silently compiled as mode B |

## §3. Compile semantics (invariant form)

**Inv-C1.** Compilation consumes a pair (mode identity, mode_hooks document
state) and produces one of two **domain outcomes**: a compiled artifact
accompanied by a compile record, or a structured refusal accompanied by a
refusal record. There is no third domain outcome (no partial write, no
silent skip).

Substrate faults (resource exhaustion, I/O failure, unexpected runtime
exceptions) are not domain outcomes. They propagate as infrastructure
errors through the host runtime's normal exception path. The compile path
makes no attempt to convert substrate faults into domain refusals, and
makes no guarantee about record production when a substrate fault occurs.

**Inv-C2.** The structure of the compiled artifact is constrained to be
directly consumable by the projection pipeline that already exists for
SkillSet artifacts, without further transformation. The harness hook format
is treated as an external substrate; the compiler maps mode_hooks semantics
to that substrate, and does not negotiate with consumers of the substrate.

**Inv-C3.** The refusal taxonomy partitions the input space exhaustively:
every schema-valid input that the compiler cannot produce output for falls
into exactly one refusal category. The partition property (every non-
compilable input is classified; no input falls into two categories) is
verified by tests that exercise the partition boundaries. The concrete
category set is §10 backlog; the exhaustiveness property is the invariant.

**Inv-C4.** Refusal produces a refusal record of the same schema family as
the compile record. The distinction between success and refusal is encoded
in the record, not in its absence.

## §4. Ordering specification

**Inv-O1.** When multiple hooks attach to the same event within a single
schema-valid mode_hooks document, the execution order in the compiled
artifact is deterministic: the same input always produces the same ordering.
The specific ordering rule is §10 backlog.

### Rationale

Stage 1 is primitive-variant-only by Inv-3. All hooks for a given mode
therefore originate from a single source document. The ordering rule need
only be deterministic and comprehensible to the operator. The concrete
choice of rule (declaration order, explicit priority, lexicographic, or
other) carries implementation trade-offs that belong to the mechanism layer.
Explicit cross-source priority fields earn their cost only when multiple
sources contribute hooks to the same event, which is a Stage 4
(composition) concern.

**Inv-O2.** The ordering determinism of Inv-O1 is verified by a test
fixture that compiles the same multi-hook same-event input twice (or
round-trips through parse-compile) and asserts identical ordering in the
compiled artifact.

**Inv-O3.** The compile record enumerates each compiled hook as a
positional tuple within its event. This makes the realized ordering
auditable from the record alone, without re-reading the source document.

## §5. Default behavior for modes without mode_hooks

**Inv-D1.** A mode for which no mode_hooks document is provided compiles to
the well-formed empty artifact (an artifact carrying zero hooks). This is
distinct from a refusal: it is a successful compilation whose output
happens to be empty.

**Inv-D2.** The well-formed empty artifact is produced through a
canonicalization step that guarantees structural identity regardless of
which mode is being compiled. The canonicalization step determines key
ordering, whitespace, encoding normalization, and any other
serialization-variant concerns. The specific canonicalization rules are §10
backlog; the invariant is that the canonicalizer exists and that its output
for the empty case is mode-independent.

**Inv-D3.** The presence of an empty mode_hooks document (one that exists
but declares zero hooks) is observationally indistinguishable at the
artifact layer from the absence case (Inv-D1). It is distinguished only at
the compile record layer, where the resolution path records which case
applied.

## §6. Stage 1 DoD invariants

| # | DoD |
|---|---|
| DoD-S1-1 | A compile entrypoint exists. Its accepted inputs are exhaustively (mode identity, schema-valid mode_hooks document) and (mode identity, absence). |
| DoD-S1-2 | Tests assert refusal on each refusal category named in Inv-C3. At minimum, refusal categories include: composition-content present, schema-invalid input, binding mismatch (Inv-9). Partition boundary tests verify that every refusal category is reachable and that no input triggers two categories simultaneously. |
| DoD-S1-3 | Tests assert ordering determinism (Inv-O1 + Inv-O2) across a multi-hook same-event input that includes at least three hooks. |
| DoD-S1-4 | An integration test confirms that the compiled artifact, when fed to the existing projection pipeline's test harness, is accepted without modification. (This test exists in Stage 1; it does not yet trigger real projection — that is Stage 2.) |
| DoD-S1-5 | Stage 0 boot-time assertion (DoD-0-4 of v0.2 design) continues to pass after Stage 1 implementation. No surface owned by Stage 0 or Stage 2 is touched. |
| DoD-S1-6 | A compile record schema exists and is self-validating, mirroring the DoD-0-2/-0-3 pattern established in Stage 0. |
| DoD-S1-7 | The compile record schema and the compile record producer share a single source of truth (the producer reads the schema, or both are generated from a shared specification). Drift between them is a compile-time error. |
| DoD-S1-8 | The compile entrypoint returns (artifact, record) to the caller and does not write to any persistent storage. Verified by test that asserts no filesystem side effects from a compile invocation. |

## §7. Failure modes and invariant-form mitigations

| Failure mode | Mitigating invariant |
|---|---|
| Compilation produces non-deterministic output | Inv-2 (pure function on domain-semantic content) + Inv-O2 (ordering determinism verification) |
| Operator writes `extends` expecting composition to work | Inv-3 + Inv-C3 (structural refusal with named category, exhaustive partition) |
| Compile record drifts from chain-record consumer expectations | Inv-6 + DoD-S1-7 (shared source of truth) |
| Mode without mode_hooks errors at projection time | Inv-D1 + Inv-D2 (well-formed empty artifact via canonicalization) |
| Stage 1 inadvertently writes to .claude/settings.json | Inv-1 + Stage 0 boot-time assertion (DoD-0-4) carried forward |
| Refusal silently produces partial output | Inv-C1 (no third domain outcome) + Inv-C4 (refusal is encoded, not absent) |
| Stage 1 compiler invoked with an input the schema accepts but Stage 1 cannot handle | Inv-C3 (exhaustive refusal partition, structurally verified) |
| Ordering changes silently across implementations | Inv-O1 (deterministic) + Inv-O2 (round-trip verification) + Inv-O3 (auditable record) |
| Compile records orphaned when Stage 2 not yet active | Inv-8 (records returned to caller, not persisted by Stage 1) |
| Document authored for mode A silently compiled as mode B | Inv-9 (binding-mismatch refusal) |
| Substrate fault (OOM, I/O error) mistaken for domain refusal | Inv-C1 domain/substrate distinction (substrate faults propagate as infrastructure errors, not domain outcomes) |
| Empty artifact differs across modes due to serialization variance | Inv-D2 (canonicalization step guarantees structural identity) |
| v0.2 Inv-7 "across all paths" coverage silently reduced by Stage 1 layer narrowing | Inv-7nr (non-regression clause: no path that was chain-recorded under v0.2 Inv-7 may become unrecorded) |

## §8. Open questions (Stage 2+)

| # | Content | Resolved at |
|---|---|---|
| OQ-1 | When does Stage 1 compilation actually fire? (operator-explicit invocation vs MCP server boot-time vs both) | Stage 2 |
| OQ-2 | Persistence policy for compile records (the caller's responsibility per Inv-8; the question is which callers persist where) | Stage 2 |
| OQ-3 | Whether a single invocation compiles one mode or many | Stage 2 |
| OQ-4 | Recompilation skip policy when input is unchanged (digest-based skip vs always-recompile vs force-flag) | Stage 2 |
| OQ-5 | Refusal taxonomy concrete category set (Inv-C3); the partition property and its verification are Stage 1 invariants, but category membership is §10 backlog | Stage 1 implementation phase |
| OQ-6 | Compile record schema concrete field set | Stage 1 implementation phase |
| OQ-7 | Canonicalization rules for Inv-D2 (key ordering, whitespace, encoding) | Stage 1 implementation phase |

OQ-5, OQ-6, and OQ-7 are intentionally pushed to implementation phase rather than
resolved in this design draft, in keeping with the v0.2 freeze decision that
deferred residual mechanism questions to implementation learning.

## §9. Non-goals

- Composition (`extends` resolution, `conflict_policy` semantics) — Stage 4
- Activation of projection to harness configuration surface — Stage 2
- Multi-source ordering across variants — Stage 4
- Auto-resolution policy semantics and operator consent capture — Stage 4
- Reverse projection (harness hook firing → KairosChain) — Stage 7
- CLI subcommand surface — Stage 2

## §10. Mechanism backlog (intentionally deferred)

The following are mechanism choices that any implementation satisfying
§2-§7 is free to make, and are not part of this design's contract:

- Concrete YAML field names for hook entries within events
- The function-call shape of the compile entrypoint (positional vs keyword
  parameters, error class hierarchy)
- File paths and naming for compile record persistence (noting that Stage 1
  itself does not persist, per Inv-8; this concerns the caller's choices)
- The specific field set of the compile record schema (beyond Inv-5's
  enumeration of categories that must be captured)
- The concrete category names within the refusal taxonomy (Inv-C3)
- Hook entry validation rules beyond the schema-level envelope checks (e.g.,
  event name enumeration, hook command shape)
- The choice of parser library, provided Inv-O1 determinism is satisfied
- The concrete ordering rule for Inv-O1 (declaration order, explicit
  priority, lexicographic, or other) — the invariant requires determinism,
  not a specific rule
- The canonicalization rules for Inv-D2 (key ordering, whitespace,
  encoding normalization)

## §11. Relationship to v0.2 frozen design

This Stage 1 draft is the concretization of §6 row "stage 1" of the v0.2
frozen design. The invariants in §2-§5 above are net additions over v0.2;
they refine but do not contradict any v0.2 invariant. Specifically:

- v0.2 Inv-1 (deterministic invocation path existence): Stage 1 produces
  the artifact that Stage 2 will use to realize the deterministic path.
- v0.2 Inv-2 (no new projection path): preserved by Inv-1 (this draft) +
  the projection-pipeline-reuse constraint of Inv-C2.
- v0.2 Inv-O1 (ordering decided at composition output time): refined by
  §4 above to "deterministic ordering at single-source compile time" — this
  is the primitive-variant specialization of v0.2 Inv-O1, not a
  replacement.
- v0.2 Inv-7 (hook composition change is chain-recorded across all paths):
  this draft's Inv-7 narrows the layer responsibility (Stage 1 produces
  the recordable artifact; Stage 2 owns the activation that triggers
  recording), and Inv-7nr explicitly guarantees non-regression: no path
  covered by v0.2 Inv-7 loses its chain-recording obligation.

If any reviewer identifies a conflict between this draft and the v0.2
frozen design that is not explicitly reconciled above, this draft is the
draft that must be revised. The v0.2 freeze is the load-bearing baseline.

## §12. Round 1 review P0 resolution mapping (appendix, non-invariant)

| # | P0 finding | Resolution in v0.2 |
|---|---|---|
| 1 | Inv-C2 substrate-as-invariant (specific SkillSet named) | Inv-C2 restated in capability terms: "projection pipeline that already exists for SkillSet artifacts." No proper name appears in any invariant. |
| 2 | Inv-2 vs Inv-5 timestamp contradiction | Inv-2 scoped: purity applies to domain-semantic content of compiled artifact; wall-clock metadata in compile record is excluded from purity projection. Rationale added. |
| 3 | Inv-O1 declaration-order is mechanism dressed as invariant | Inv-O1 restated as "deterministic ordering." Concrete ordering rule (including declaration order) moved to §10 backlog. Inv-O2 updated to verify determinism, not a specific rule. |
| 4 | Inv-C3 exhaustiveness unverifiable | Inv-C3 restated as partition property: every non-compilable input falls into exactly one refusal category. Verification method stated (partition boundary tests). Concrete categories remain §10 backlog. |
| 5 | Inv-C1 no-third-outcome doesn't cover infra faults | Inv-C1 now distinguishes domain outcomes (success / structured refusal) from substrate faults (propagated as infrastructure errors). No record guarantee under substrate fault. |
| 6 | Orphaned compile record lifecycle | Inv-8 added: Stage 1 returns records to caller, does not persist. DoD-S1-8 verifies no filesystem side effects. OQ-2 updated to note persistence is caller's decision. |
| 7 | Inv-D2 byte-identity under-specified | Inv-D2 restated: canonicalization step guarantees structural identity. Specific canonicalization rules are §10 backlog (OQ-7 added). |
| 8 | mode_name binding integrity | Inv-9 added: external mode identity must match document's declared `mode_name`; divergence triggers binding-mismatch refusal. Refusal category added to DoD-S1-2 minimum set. |
| 9 | v0.2 Inv-7 narrowing without non-regression clause | Inv-7nr added: explicit guarantee that no path covered by v0.2 Inv-7 loses chain-recording obligation under Stage 1's layer narrowing. §11 reconciliation updated. |
