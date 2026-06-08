---
title: dream_digest — Narrative Synthesis as a Derived View (design-by-invariant)
component: dream SkillSet (L1)
version: design v0.1 draft
author: Masaomi Hatakeyama
status: DRAFT — pre multi-LLM review
date: 2026-06-06
provenance: motivated by OpenAI ChatGPT "Dreaming" memory (2026), read against KairosChain Prop 5 + Knowledge Ethos
---

# dream_digest — design v0.1 (design-by-invariant)

## Human-facing summary (in scope: verbose-but-readable)

OpenAI の Dreaming は、断片的な記憶を定期的に再合成して一貫した文章プロフィールに上書きする。KairosChain はこれをそのまま採れない——上書きは命題5（構成的記録・不可逆）に反し、一貫化のための矛盾除去は Knowledge Ethos に反し、単一プロフィールへの集約は "no single source of truth" に反するため。

そこで本設計は、合成そのものは取り込むが、**合成結果を「真実の所在」ではなく「派生ビュー」に格下げする**。断片（L2/L1, append-only, 不変）は手を触れずに残し、その上に再生成可能な俯瞰文章（digest）を生成する。digest はいつでも捨てて作り直せる。これが Dreaming の良さ（一貫した俯瞰）と KairosChain の原則（保存・分散・可逆）の両立点であり、Aufhebung（両方を保持したまま次元を上げる）の実装である。

矛盾は消さない。digest 生成時に「未解決の対立として両立している」と明記する。これが Dreaming との決定的な差別化点になる。

以下は review にかけるための design-by-invariant 本体。簡潔さ優先（LLM-primary consumption）。

---

## Invariants

**I1 — Derivation, not authority.** A digest is a derived projection of L2/L1 sources. It is never a source of truth. Any fact in a digest must be traceable to at least one immutable source node. A digest may be deleted and regenerated at any time without information loss.

**I2 — Source immutability.** Digest generation reads sources and writes only to digest storage. It never mutates, overwrites, merges, or deletes L2 or L1 content. dream_archive remains the only path that relocates source content, and it remains reversible.

**I3 — Contradiction preservation.** When sources disagree, the digest surfaces the disagreement as coexisting positions; it does not select a winner or flatten to one claim. The relation between contradicting sources is recorded as dimension-elevation (Aufhebung-pending), never as supersession.

**I4 — Provenance completeness.** Every assertion in a digest carries references to its source nodes sufficient to regenerate or audit it. A digest with an unresolvable source reference is invalid.

**I5 — Staleness is labelled, not corrected.** Source age and confidence are surfaced in the digest as annotations. The digest does not refresh, rewrite, or retire a source to resolve staleness. Correction of a source remains a separate, recorded, human-consented operation.

**I6 — Regeneration determinism boundary.** Given the same source set and the same generation directive, two digests are required to be equivalent in their factual claims and provenance, even if prose differs. Prose variation is permitted; claim/provenance variation is not.

**I7 — Recording.** Each digest generation event is recorded (sources consulted, generation directive identity, output hash). The digest artifact itself, being derived, is not required to be immutable; the generation *event* is.

**I8 — No lock-in surface.** A digest must be exportable and human-readable in a portable form, and must not become a dependency that other layers read as authoritative. Removing the digest subsystem entirely must leave L2/L1/L0 fully functional.

## Justification (one prose paragraph)

Dreaming's value is a single coherent overview that survives fragmentation; its hazard, under KairosChain's principles, is that it achieves coherence by overwriting and by collapsing contradiction into one narrative — producing exactly the single source of truth and the irreversible re-consolidation that Prop 5 and the Knowledge Ethos forbid. The invariants above keep the value and remove the hazard by relocating the synthesis to a derived tier: I1/I8 deny it authority and lock-in, I2/I5 deny it the power to mutate or retire sources, I3 turns contradiction-flattening into contradiction-preservation, and I4/I6/I7 make the derivation auditable and reproducible so that the projection can always be trusted to be a faithful (not a creative) view of the immutable substrate. The result is the Aufhebung the masa-mode Knowledge Ethos describes: the fragment tier and the narrative tier coexist at different dimensions rather than one superseding the other.

## Relation to existing dream surface

- dream_scan: unchanged in role (detection). May supply candidate clusters as digest inputs.
- dream_propose: its existing synthesis-directive capability is the natural seed for digest generation directives (extension, not replacement).
- dream_archive / dream_recall: unchanged. Remain the only source-relocating, reversible path. I2 explicitly preserves their monopoly on source movement.
- New surface (dream_digest): generate / regenerate / read a derived digest under I1–I8.

## §11 Backlog — mechanism choices deferred (NOT part of the invariant body)

These are realization details to be decided after invariant approval. Listed here so the body stays mechanism-free (anti-enumeration).

- Digest storage location and format (derived/regenerable tier).
- Whether semantic clustering (LLM / llm_call adapter) augments lexical detection as digest input, or detection stays as-is for v0.1.
- Scheduling: on-demand vs idle/nightly background generation (ties to routines × autonomous growth work).
- Confidence/freshness decay representation for I5 annotations.
- Granularity: one global digest vs per-topic digests (note: a single global digest risks brushing against I8 / no-single-source — per-topic likely safer).
- How I6 equivalence is checked in practice (claim-set hashing vs review).

## Open questions for review

- Q1: Is a per-topic digest set sufficient to honour I8, or does any persistent digest risk becoming a de-facto authority over time through habitual reading? (This is the central philosophical risk.)
- Q2: Does I3 (contradiction preservation) belong in dream, or should it be delegated to the future Knowledge Ethos L1 SkillSet, with dream_digest merely consuming its dimension-elevation edges?
- Q3: Is I6's "factual equivalence under same inputs" testable without itself requiring an LLM judge (which reintroduces nondeterminism)?
