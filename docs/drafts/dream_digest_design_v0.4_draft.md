---
title: dream_digest — Narrative Synthesis as a Derived View (design-by-invariant)
component: dream SkillSet (L1)
version: design v0.4 — FROZEN (design phase)
author: Masaomi Hatakeyama
status: FROZEN for design phase after multi-LLM review R3 convergence. Remaining items are implementation-review / §11 concerns.
date: 2026-06-06
provenance: motivated by OpenAI ChatGPT "Dreaming" memory (2026), read against KairosChain Prop 5 + Knowledge Ethos
revises: dream_digest_design_v0.3_draft.md
---

# dream_digest — design v0.4 (design-by-invariant, FROZEN)

## Human-facing summary (in scope: verbose-but-readable)

派生ビューとしての narrative 合成。断片（L2/L1, version 単位で不変, append-only）を保存したまま、その上に再生成可能・削除可能・access 制約された俯瞰文章（digest）を per-topic で生成する。OpenAI Dreaming の「一貫した俯瞰」を取り込みつつ、上書き・矛盾平坦化・single source of truth・lock-in・access 集約漏れを invariant で封じる。

v0.3 → v0.4（Round 3 で収束した唯一の (b) を解消）:

- **I7 が「読んだ全ソース」を記録**（引用ノードのみ → 読んだ全ノード + ハッシュ）。これで I9（読んだ全ソースで access を縛る）が監査・enforce 可能になり、I7×I9 の不整合を解消。
- **用語を統一**: READ（読んだ集合）⊇ cited（引用＝主張根拠の部分集合）。snapshot は READ 集合を記録する、と一行定義。
- I9 に **generation principal 節**を昇格（生成は READ 集合全体に権限を持つ principal の下で走る）。"every stage" の主張を本文で閉じる。

design phase はこの版で FREEZE。残る項目（I9/I8 の enforcement 実装方式、directive versioning、cross-partition 矛盾、I3 の substrate 依存構造、Q1 残存リスク）は §11 / 実装レビュー送り。

---

## Context

`dream` SkillSet (L1) is DETECTION-centric (dream_scan detect / dream_propose package / dream_archive reversible-archive / dream_recall restore). Synthesis content is generated outside dream by an LLM. Fragments preserved, non-overwritten, blockchain-recorded.

OpenAI Dreaming re-synthesizes fragments into a single background narrative profile. Hazards under KairosChain principles: overwrite (Prop 5), contradiction-flattening (Knowledge Ethos), single source of truth, lock-in (DEE fade-out), access-aggregation leak (Round 1).

This design adds `dream_digest`: a DERIVED narrative view beside the immutable fragments, never replacing them.

## Definitions

- **Source node**: a specific VERSION of an L2/L1 entry; immutable per version (see I5 for version advance).
- **READ set**: every source node consulted during a generation.
- **Cited set**: the subset of the READ set that a given assertion is grounded in. `cited ⊆ READ`.
- The I2/I7 snapshot records the **READ set** (each node + its content hash); citations (I4) reference members of it.

## Invariants

**I1 — Derivation, not authority.** A digest is a derived projection of L2/L1 source nodes only (L0 out of scope as a source). It is never a source of truth. Every assertion is traceable to ≥1 source node. A digest may be deleted and regenerated anytime without information loss.

**I2 — Source immutability and snapshot provenance.** Generation reads sources and writes only to digest storage; it never mutates/overwrites/merges/deletes L2/L1 content. At generation it captures a content-addressed snapshot of the entire READ set (each node + content hash). dream_archive remains the only path that relocates source content, reversibly; because generation only reads and pins hashes, it needs no lock and cannot be corrupted by concurrent archive/recall.

**I3 — Contradiction preservation within a partition (substrate-graded).** Within a topic partition (I10), a digest must not flatten disagreement to a single claim; it must surface the contradicting positions as coexisting. Representation is substrate-graded: with Knowledge Ethos present, a typed dimension-elevation edge (Aufhebung-pending = the dimension at which both hold is not yet found; both poles remain load-bearing); absent it, an inline flat annotation naming the disagreement. Supersession is forbidden in both grades. Contradictions visible only ACROSS partitions are an explicit, acknowledged non-obligation of I3 (§11) — partitioning does not violate I3, because I3's scope is the partition.

**I4 — Provenance completeness over a snapshot.** Every assertion carries references to its cited nodes, content-addressed against the I2 snapshot, sufficient to audit it. An assertion whose provenance cannot be resolved at generation is dropped, not emitted. If all candidate assertions for a topic drop, no digest is emitted for that topic (empty is not an error). Soft-archived sources resolve against the archived full body, not the stub.

**I5 — Staleness is labelled, not corrected.** A source node is immutable per version; a source may ADVANCE to a new version (edit, archive, recall, or ACL change). Source age, confidence, and post-generation drift (any READ-set node whose current version/hash differs from the snapshot) are surfaced as annotations; the digest marks itself stale and is regenerated on demand. A digest never refreshes/rewrites/retires a source. Source correction remains separate, recorded, human-consented.

**I6 — Provenance-stable regeneration (citation set fixed by snapshot).** The I2 snapshot fixes the READ set, and thereby the citable universe, as an INPUT: which source nodes a digest may cite is determined by the snapshot, not chosen by the generating substrate. Given the same snapshot and the same generation directive, every regeneration cites the same provenance set, and every assertion remains backed by a resolvable source. The generating substrate may vary prose and claim phrasing but may not add, drop, or substitute citations beyond the snapshot — factual/prose identity across runs is explicitly NOT guaranteed (external nondeterministic substrate, per partial autopoiesis); provenance-set stability IS, because it is fixed by input rather than by generation.

**I7 — Recording.** Each generation event records the source snapshot (the entire READ set — every node consulted, cited or not — each with its content hash), the generation directive identity, and the output hash. Recording the full READ set (not only cited nodes) is what makes I9's access bound and audit decidable. The directive identity is part of the snapshot (so I6's antecedent "same directive" is well-defined). The digest artifact, being derived, need not be immutable; the generation event is.

**I8 — No authority, no lock-in.** No layer's correctness may depend on a digest; removing the digest subsystem entirely leaves L2/L1/L0 fully functional. A digest is read-/export-only with no write-back path into any layer. It must be exportable in a portable, human-readable form; "portable" means format-portability, not access-widening (export does not relax I9).

**I9 — Access bounded by the READ set, enforced at every stage.** A digest's access bound is the most restrictive access control among ALL nodes in the READ set (not merely the cited subset). This bound applies at every stage — generation, storage, read, export. Generation runs under a principal authorized for the entire READ set; the aggregated artifact at rest, and any read or export of it, may never widen access to, or enable exfiltration of, source content beyond what the source permits. Access is evaluated against the CURRENT access control of the sources at access time (content is snapshot-pinned; access is live — a source whose ACL tightens after generation immediately tightens the digest, and I5 surfaces the drift). Export is only to a principal authorized for the full READ set. A digest is never a privilege-escalation surface.

**I10 — Per-topic partition.** Digests are partitioned per topic; there is no single global digest. (A global digest would concentrate authority and brush against I1/I8; partitioning bounds the de-facto-authority drift of Q1. A source node may appear in more than one topic partition.)

## Justification

Dreaming's value is a coherent overview surviving fragmentation; its hazards, under KairosChain's principles, are coherence-by-overwriting, contradiction-collapse, authority concentration, lock-in, and an access-aggregation leak. The invariants keep the value and remove the hazards by relocating synthesis to a derived, access-bounded, partitioned tier whose READ set (and thereby citable universe) is fixed by input rather than by a nondeterministic substrate: I1/I8/I10 deny authority, lock-in, and concentration; I9 denies privilege escalation at every stage against live access controls over the full READ set; I2/I4/I5/I7 bind it to an immutable content-addressed snapshot of everything read and forbid source mutation; I3 turns flattening into substrate-graded, partition-scoped contradiction-preservation; I6 guarantees provenance-set stability by fixing the citable universe in the snapshot, while honestly declining the prose determinism an LLM substrate cannot provide. The result is the Aufhebung the Knowledge Ethos describes: fragment tier and narrative tier coexist at different dimensions rather than one superseding the other.

## Relation to existing dream surface

- dream_scan: unchanged (detection). Its candidate clusters are a natural source for the I6 READ-set snapshot (the input that fixes the citable universe).
- dream_propose: its current directive merges sources into a SINGLE entry — which would flatten contradiction under I3. dream_digest OWNS its own generation directive and does NOT reuse dream_propose's verbatim. dream_propose is unchanged for its own promotion use.
- dream_archive / dream_recall: unchanged; remain the only source-relocating, reversible path (I2). Soft-archived sources resolve provenance against the archived full body (I4).
- New surface (dream_digest): generate / regenerate / read / export a per-topic derived digest under I1–I10.

## §11 Backlog — mechanism & implementation-review items (NOT part of the invariant body)

- Digest storage location/format (non-canonical derived/regenerable tier, distinct from L1 `knowledge/` and L2 context paths).
- Whether semantic clustering augments lexical detection as the I6 READ-set input.
- Scheduling: on-demand vs idle/nightly generation.
- Confidence/freshness decay representation for I5.
- Optional future strengthening of I6: a canonical claim representation (claim-set hashing) re-enabling factual-claim equivalence (not realizable without an undeclared intermediate today).
- Topic-boundary definition for I10; CROSS-PARTITION contradiction surfacing (acknowledged non-obligation of I3).
- Generation-directive identity/versioning scheme (mechanism for I7's "directive identity").
- Enforcement MECHANISM for I9 (READ-set access inheritance, live ACL re-evaluation, generation/export-principal binding) and I8 (read-/export-only): policy hook vs storage-tier permission. Possible future promotion of I9 to a shared core access-control policy any aggregating SkillSet inherits.
- I3 substrate-dependent structure (R3 P3): a digest generated without Knowledge Ethos (flat annotation) vs with it (typed edge) differs structurally; reconciliation/migration when Ethos later appears is implementation-level.

## Convergence record (design phase)

- R1 (v0.1, full roster): REVISE 3A/2R — structural gaps (access surface, I6 unrealizable, I3 not layer-complete).
- R2 (v0.2): REVISE 2A/3R — fix-incompleteness (I9 scope, I6 citation determinism, I3×I10).
- R3 (v0.3): REVISE 3A/2R — single (b) (I7×I9 recording inconsistency); all else (c). Cursor → APPROVE.
- v0.4: I7×I9 resolved (record full READ set). Remaining findings are (c) terminology/advisory + P3 acknowledged design-intent. Per pre-committed freeze criterion (revise only on (a) or internal-contradiction (b); mechanism requests → §11/impl-review), design is FROZEN.

## Residual risks (acknowledged, non-blocking at design stage)

- Q1: per-topic partition (I10) mitigates de-facto-authority drift structurally but does not eliminate habituation risk. Accepted as a design-stage residual; revisit if observed in use.
- Codex (5.4/5.5) did not reach APPROVE across R1–R3. Per `multi_llm_reviewer_evaluation`, Codex APPROVE is not always reachable under value-system divergence; remaining Codex findings at R3 were the I7×I9 inconsistency (now fixed) and enforcement-mechanism requests classified (c). This is recorded, not overridden silently.
