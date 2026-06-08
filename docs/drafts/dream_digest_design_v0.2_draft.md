---
title: dream_digest — Narrative Synthesis as a Derived View (design-by-invariant)
component: dream SkillSet (L1)
version: design v0.2 draft
author: Masaomi Hatakeyama
status: DRAFT — revised after multi-LLM review Round 1 (full roster)
date: 2026-06-06
provenance: motivated by OpenAI ChatGPT "Dreaming" memory (2026), read against KairosChain Prop 5 + Knowledge Ethos
revises: dream_digest_design_v0.1_draft.md
---

# dream_digest — design v0.2 (design-by-invariant)

## Human-facing summary (in scope: verbose-but-readable)

OpenAI の Dreaming は断片記憶を定期的に再合成して一貫プロフィールに上書きする。KairosChain はそれをそのまま採れない（上書きは命題5に反し、矛盾除去は Knowledge Ethos に反し、単一プロフィールは "no single source of truth" に反し、深い個人化は fade-out に反する）。本設計は合成を取り込みつつ、合成結果を「真実の所在」から「派生ビュー」へ格下げする。断片（L2/L1, 不変, append-only）は手を触れず残し、その上に再生成可能・削除可能な俯瞰文章（digest）を生成する。Aufhebung（両方を保持して次元を上げる）の実装。

v0.1 → v0.2 の主な変更（Round 1 review 反映）:

- **I9 新設（最重要）**: digest はソースを集約する新しい面なので、読取/export 権限を元ソースの access control 以下に縛る。集約が権限昇格・情報流出口にならないことを構造で保証。（Codex 単独の (a) 発見）
- **I6 弱化**: 「再生成しても factual claim が同一」は canonical claim 表現なしには実現不能（全 reviewer が指摘）。factual 同一を撤回し、**provenance 集合の同一**のみ保証。prose と claim の揺れ（LLM 非決定性）は受容し、部分的自己産出と整合させる。
- **I3 layer-complete 化**: dimension-elevation 辺を持つ Knowledge Ethos が未実装でも dream 単独で成立する floor（対立を共存ポジションとして inline 明示）を定義。型付き辺は Ethos があれば消費。
- **I2/I4 強化**: provenance は content-addressed（生成時にソース内容ハッシュ固定）。ソースが後で archive/mutate/recall されたら digest は **stale**（invalid でなく）。archive/recall 同時実行の一貫性もこれで解決。
- **per-topic を本文 invariant に昇格**: 単一 global digest を禁止（I1/I8/Q1 のため）。
- 用語の自己完結化、L0 を明示的に範囲外に。

以下は review にかける design-by-invariant 本体（簡潔さ優先、LLM-primary）。

---

## Context

`dream` SkillSet (L1) の現状は DETECTION 中心: dream_scan が字面+統計で promotion/consolidation/archive 候補を検出、dream_propose が LLM 向け synthesis directive を梱包、dream_archive が stale L2 を可逆 soft-archive（gzip+stub, SHA256）、dream_recall が復元。合成内容は dream の外で LLM が生成。断片は保存され上書きされない。すべて blockchain 記録。

OpenAI Dreaming は断片を単一 narrative profile に定期再合成（背景処理）。staleness / 類似事実取り違え / 断片による文脈弱化を解く。KairosChain 原則下の hazard: 上書き（命題5）、矛盾平坦化（Knowledge Ethos）、single source of truth、深い個人化 lock-in（DEE fade-out）。

本設計は `dream_digest` という DERIVED narrative view を追加する。不変断片の傍らに置き、決して置き換えない。

## Invariants

**I1 — Derivation, not authority.** A digest is a derived projection of L2/L1 source nodes only (L0 is out of scope as a source). It is never a source of truth. Every assertion in a digest is traceable to at least one immutable source node. A digest may be deleted and regenerated at any time without information loss.

**I2 — Source immutability and snapshot provenance.** Digest generation reads sources and writes only to digest storage; it never mutates, overwrites, merges, or deletes L2/L1 content. At generation time it captures a content-addressed snapshot (a content hash per cited source). dream_archive remains the only path that relocates source content, and it remains reversible; because generation only reads and pins hashes, it requires no lock and cannot be corrupted by concurrent archive/recall.

**I3 — Contradiction preservation (substrate-graded).** When sources disagree, a digest must not flatten the disagreement to a single claim; it must surface the contradicting positions as coexisting. The *representation* of that relation is graded by available substrate: when the Knowledge Ethos SkillSet is present, the relation is recorded as a typed dimension-elevation edge (Aufhebung-pending = the dimension at which both hold has not yet been found, both poles remain load-bearing); when it is absent, dream_digest satisfies I3 with an inline flat annotation that names the disagreement without a typed edge. Supersession (one source overwriting another) is forbidden in either grade.

**I4 — Provenance completeness over a snapshot.** Every assertion carries references to its source nodes, content-addressed against the I2 snapshot, sufficient to audit it. An assertion whose provenance cannot be resolved at generation time is dropped, not emitted. (Audit of soft-archived sources resolves against the archived full body, not the stub.)

**I5 — Staleness is labelled, not corrected.** Source age, confidence, and post-generation source drift (a cited source whose current content hash differs from the snapshot) are surfaced as annotations. A digest does not refresh, rewrite, or retire a source; it marks itself stale and is regenerated on demand. Correction of a source remains a separate, recorded, human-consented operation.

**I6 — Provenance-stable regeneration.** Given the same source snapshot and the same generation directive, two digests cite the same provenance set; every assertion remains backed by a resolvable source. Prose and the specific phrasing of claims may vary between regenerations — factual-claim identity across runs is explicitly NOT guaranteed, because generation depends on an external nondeterministic substrate (consistent with partial autopoiesis). What is guaranteed is provenance stability, not prose stability.

**I7 — Recording.** Each generation event is recorded: the source snapshot (cited sources + their content hashes), the generation directive identity, and the output hash. The digest artifact, being derived, need not be immutable; the generation *event* is.

**I8 — No authority, no lock-in.** No layer's correctness may depend on a digest; removing the digest subsystem entirely must leave L2/L1/L0 fully functional. A digest is read-/export-only and has no write-back path into any layer. It must be exportable in a portable, human-readable form.

**I9 — Access bounded by sources.** A digest's read and export access is bounded by the most restrictive access control among its cited sources; aggregation into a digest may never widen access to, or enable exfiltration of, any source content beyond what the source itself permits. A digest is never a privilege-escalation surface.

**I10 — Per-topic partition.** Digests are partitioned per topic; there is no single global digest. (A single global digest would concentrate authority and brush against I1/I8; partitioning bounds the de-facto-authority drift raised in Q1.)

## Justification

Dreaming's value is a coherent overview surviving fragmentation; its hazard, under KairosChain's principles, is achieving coherence by overwriting and by collapsing contradiction — producing the single source of truth and irreversible re-consolidation that Prop 5 and the Knowledge Ethos forbid, and (per Round 1) a new aggregation surface that could leak source content past its access controls. The invariants keep the value and remove the hazards by relocating synthesis to a derived, access-bounded, partitioned tier: I1/I8/I10 deny it authority, lock-in, and concentration; I9 denies it privilege escalation; I2/I4/I5 bind it to an immutable, content-addressed snapshot and forbid source mutation; I3 turns contradiction-flattening into substrate-graded contradiction-preservation; and I6/I7 guarantee provenance stability and auditability while honestly declining to guarantee prose determinism that an LLM substrate cannot provide. The result is the Aufhebung the Knowledge Ethos describes: the fragment tier and the narrative tier coexist at different dimensions rather than one superseding the other.

## Relation to existing dream surface

- dream_scan: unchanged (detection). May supply candidate clusters as digest inputs.
- dream_propose: holds a synthesis-directive capability whose current directive merges sources into a SINGLE entry — which would flatten contradiction under I3. dream_digest OWNS its own generation directive and does NOT reuse dream_propose's verbatim. dream_propose is unchanged for its own promotion use.
- dream_archive / dream_recall: unchanged; remain the only source-relocating, reversible path (I2). Soft-archived sources resolve provenance against the archived full body (I4).
- New surface (dream_digest): generate / regenerate / read / export a per-topic derived digest under I1–I10.

## §11 Backlog — mechanism choices deferred (NOT part of the invariant body)

- Digest storage location and format (must be a non-canonical, derived/regenerable tier — distinct from L1 `knowledge/` and L2 context paths).
- Whether semantic clustering (LLM / llm_call adapter) augments lexical detection as digest input, or detection stays as-is for v0.1.
- Scheduling: on-demand vs idle/nightly background generation (ties to routines × autonomous growth work).
- Confidence/freshness decay representation for I5 annotations.
- Optional future strengthening of I6: a canonical claim representation (claim-set hashing) that would re-enable factual-claim equivalence across regenerations. Deferred because it is not realizable without an undeclared intermediate structure today.
- Topic-boundary definition for I10, and handling of contradictions that span topic partitions (a source may appear in multiple topic digests; cross-topic contradiction surfacing is unsolved here — acknowledged limit).
- Generation-directive identity/versioning scheme for I7.
- Enforcement mechanism for I9 (access-control inheritance) and I8 (read-/export-only): policy hook vs storage-tier permission.

## Open questions for review (Round 2)

- Q1 (carried, partially mitigated by I10): does per-topic partition sufficiently bound de-facto-authority drift, or is any persistent digest still a habituation risk? I10 is a structural mitigation, not a proof.
- Q2 (resolved into I3): contradiction representation is now substrate-graded — flat annotation within dream alone, typed edge when Knowledge Ethos exists. Confirm this division is acceptable.
- Q3 (resolved into I6): I6 no longer claims factual determinism; it guarantees provenance stability only. Confirm that weakening (vs adding a canonical claim layer now) is the right call for v0.2.
- Q4 (new): is I9 (access bounded by sources) better expressed as an invariant here, or delegated entirely to a core access-control policy that dream_digest merely inherits? (Placement question, not a content question.)
