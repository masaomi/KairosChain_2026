---
title: dream_digest — Narrative Synthesis as a Derived View (design-by-invariant)
component: dream SkillSet (L1)
version: design v0.3 draft
author: Masaomi Hatakeyama
status: DRAFT — revised after multi-LLM review Round 2 (full roster)
date: 2026-06-06
provenance: motivated by OpenAI ChatGPT "Dreaming" memory (2026), read against KairosChain Prop 5 + Knowledge Ethos
revises: dream_digest_design_v0.2_draft.md
---

# dream_digest — design v0.3 (design-by-invariant)

## Human-facing summary (in scope: verbose-but-readable)

派生ビューとしての narrative 合成。断片（L2/L1, version 単位で不変, append-only）は保存したまま、その上に再生成可能・削除可能・access 制約された俯瞰文章（digest）を per-topic で生成する。OpenAI Dreaming の「一貫した俯瞰」を取り込みつつ、上書き・矛盾平坦化・single source of truth・lock-in・access 集約漏れを invariant で封じる。

v0.2 → v0.3 の変更（Round 2 review 反映、genuine (a)/(b) のみ）:

- **I9 を生成・保存段階まで拡張、かつ「読んだ全ソース」で縛る**（cited だけでは不十分）。access は read/export 時に**現在 ACL で再評価**（content は snapshot 固定、access は live）。(a) security 3 件を解消。
- **I6 を実現可能に**: snapshot が引用集合を確定する（どのソースを引くかは入力で固定、LLM は phrasing のみ。選択しない）。これで provenance 集合の安定が LLM 非決定性に依存しなくなる。(b)。
- **I3 を partition 内に scope**。cross-topic の矛盾提示は I3 の対象外の既知限界と明記（§11）。I3×I10 の内部矛盾を解消。(b)。
- I8×I9 の export 整合（principal 節）、空 digest の扱い、I1/I5 の用語を明確化。
- Q4 解決: I9 は dream_digest の invariant として保持（principal 節付き）。core policy 委譲は §11 の将来検討。

実装機構に属する細部（ACL 再評価の実装方式、generation-directive の versioning 方式、I9 の enforcement hook）は §11 / 実装レビュー送り。design はこの round で締める方針。

---

## Context

`dream` SkillSet (L1) は現状 DETECTION 中心（dream_scan 検出 / dream_propose 梱包 / dream_archive 可逆退避 / dream_recall 復元）。合成内容は dream の外で LLM が生成。断片は保存・非上書き・blockchain 記録。

OpenAI Dreaming は断片を単一 narrative profile に背景再合成。KairosChain 原則下の hazard: 上書き（Prop 5）、矛盾平坦化（Knowledge Ethos）、single source of truth、lock-in（DEE fade-out）、access 集約漏れ（Round 1 発見）。

本設計は `dream_digest`（不変断片の傍らの DERIVED narrative view、置換しない）を追加する。

## Invariants

**I1 — Derivation, not authority.** A digest is a derived projection of L2/L1 source nodes only (L0 out of scope as a source). It is never a source of truth. Every assertion is traceable to ≥1 source node. A digest may be deleted and regenerated anytime without information loss. ("Source node" = a specific version of an L2/L1 entry; see I5 for version advance.)

**I2 — Source immutability and snapshot provenance.** Generation reads sources and writes only to digest storage; it never mutates/overwrites/merges/deletes L2/L1 content. At generation it captures a content-addressed snapshot: the exact set of source nodes consulted, each with its content hash. dream_archive remains the only path that relocates source content, reversibly; because generation only reads and pins hashes, it needs no lock and cannot be corrupted by concurrent archive/recall.

**I3 — Contradiction preservation within a partition (substrate-graded).** Within a topic partition (I10), a digest must not flatten disagreement to a single claim; it must surface the contradicting positions as coexisting. Representation is substrate-graded: with Knowledge Ethos present, a typed dimension-elevation edge (Aufhebung-pending = the dimension at which both hold is not yet found; both poles remain load-bearing); absent it, an inline flat annotation naming the disagreement. Supersession is forbidden in both grades. Contradictions that are visible only ACROSS partitions are an explicit, acknowledged non-obligation of I3 (see §11) — partitioning therefore does not violate I3, because I3's scope is the partition.

**I4 — Provenance completeness over a snapshot.** Every assertion carries references to its source nodes, content-addressed against the I2 snapshot, sufficient to audit it. An assertion whose provenance cannot be resolved at generation is dropped, not emitted. If all candidate assertions for a topic drop, no digest is emitted for that topic (empty is not an error). Soft-archived sources resolve against the archived full body, not the stub.

**I5 — Staleness is labelled, not corrected.** A source node is immutable per version; a source may ADVANCE to a new version (edit, archive, recall, or ACL change). Source age, confidence, and post-generation drift (a cited source whose current version/hash differs from the snapshot) are surfaced as annotations; the digest marks itself stale and is regenerated on demand. A digest never refreshes/rewrites/retires a source. Source correction remains separate, recorded, human-consented.

**I6 — Provenance-stable regeneration (citation set fixed by snapshot).** The I2 snapshot fixes the exact citation set as an INPUT: which source nodes a digest cites is determined by the snapshot, not chosen by the generating substrate. Given the same snapshot and the same generation directive, every regeneration cites that same provenance set, and every assertion remains backed by a resolvable source. The generating substrate may vary prose and claim phrasing but may not add, drop, or substitute citations — factual/prose identity across runs is explicitly NOT guaranteed (external nondeterministic substrate, per partial autopoiesis); provenance-set stability IS, because it is fixed by input rather than by generation.

**I7 — Recording.** Each generation event records the source snapshot (cited nodes + content hashes), the generation directive identity, and the output hash. The directive identity is part of the snapshot (so I6's antecedent "same directive" is well-defined). The digest artifact, being derived, need not be immutable; the generation event is.

**I8 — No authority, no lock-in.** No layer's correctness may depend on a digest; removing the digest subsystem entirely leaves L2/L1/L0 fully functional. A digest is read-/export-only with no write-back path into any layer. It must be exportable in a portable, human-readable form; "portable" means format-portability, not access-widening (export does not relax I9).

**I9 — Access bounded by all sources read, enforced at every stage.** A digest's access bound is the most restrictive access control among ALL source nodes READ during generation (not merely those cited). This bound applies at every stage — generation, storage, read, and export: the aggregated artifact at rest, and any read or export of it, may never widen access to, or enable exfiltration of, source content beyond what the source permits. Access is evaluated against the CURRENT access control of the sources at access time (content is snapshot-pinned; access is live — a source whose ACL tightens after generation immediately tightens the digest, and I5 surfaces the drift). Export is only to a principal authorized for the full source set. A digest is never a privilege-escalation surface.

**I10 — Per-topic partition.** Digests are partitioned per topic; there is no single global digest. (A global digest would concentrate authority and brush against I1/I8; partitioning bounds the de-facto-authority drift of Q1. A source node may appear in more than one topic partition.)

## Justification

Dreaming's value is a coherent overview surviving fragmentation; its hazards, under KairosChain's principles, are coherence-by-overwriting, contradiction-collapse, authority concentration, lock-in, and an access-aggregation leak. The invariants keep the value and remove the hazards by relocating synthesis to a derived, access-bounded, partitioned tier whose citations are fixed by input rather than by a nondeterministic substrate: I1/I8/I10 deny authority, lock-in, and concentration; I9 denies privilege escalation at every stage against live access controls; I2/I4/I5 bind it to an immutable content-addressed snapshot and forbid source mutation; I3 turns flattening into substrate-graded, partition-scoped contradiction-preservation; I6/I7 guarantee provenance-set stability and auditability by fixing the citation set in the snapshot, while honestly declining the prose determinism an LLM substrate cannot provide. The result is the Aufhebung the Knowledge Ethos describes: fragment tier and narrative tier coexist at different dimensions rather than one superseding the other.

## Relation to existing dream surface

- dream_scan: unchanged (detection). Its candidate clusters are a natural source for the I6 citation set (the snapshot input that fixes which nodes a digest cites).
- dream_propose: holds a synthesis-directive capability whose current directive merges sources into a SINGLE entry — which would flatten contradiction under I3. dream_digest OWNS its own generation directive and does NOT reuse dream_propose's verbatim. dream_propose is unchanged for its own promotion use.
- dream_archive / dream_recall: unchanged; remain the only source-relocating, reversible path (I2). Soft-archived sources resolve provenance against the archived full body (I4).
- New surface (dream_digest): generate / regenerate / read / export a per-topic derived digest under I1–I10.

## §11 Backlog — mechanism choices deferred (NOT part of the invariant body)

- Digest storage location/format (non-canonical derived/regenerable tier, distinct from L1 `knowledge/` and L2 context paths).
- Whether semantic clustering augments lexical detection as the I6 citation-set input.
- Scheduling: on-demand vs idle/nightly generation.
- Confidence/freshness decay representation for I5.
- Optional future strengthening of I6: a canonical claim representation (claim-set hashing) re-enabling factual-claim equivalence (not realizable without an undeclared intermediate today).
- Topic-boundary definition for I10; CROSS-PARTITION contradiction surfacing (acknowledged non-obligation of I3 — a source in multiple partitions may carry contradictions visible only across them; surfacing these is future work).
- Generation-directive identity/versioning scheme (mechanism for I7's "directive identity").
- Enforcement MECHANISM for I9 (access inheritance, live ACL re-evaluation, generation-principal binding) and I8 (read-/export-only): policy hook vs storage-tier permission. Whether I9 should later be promoted to a core access-control policy that any aggregating SkillSet inherits (Q4 placement) rather than re-stated per SkillSet.

## Open questions for review (Round 3)

- Q1 (carried, mitigated by I10, not eliminated): does per-topic partition sufficiently bound de-facto-authority drift? I10 is structural mitigation, not proof. Is an additional invariant warranted, or is honest acknowledgment sufficient at design stage?
- Q4 (resolved into I9 + §11): I9 stays a dream_digest invariant with the generation-principal clause; promotion to a shared core policy is deferred to §11. Confirm this placement.
- Q5 (new, meta): are the remaining open items (I9 enforcement mechanism, directive versioning, cross-partition contradictions) design-level integrity gaps, or implementation-level concerns that should move to implementation review rather than block design freeze?
