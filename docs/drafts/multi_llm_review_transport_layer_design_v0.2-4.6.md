---
name: multi_llm_review_transport_layer_design_v0.2-4.6
type: design_draft_subauthor_output
version: 0.2-4.6
status: 4.6 sub-author raw output, preserved for audit
date: 2026-05-15
author: Claude Opus 4.6 (sub-author)
basis: v0.1 + round 1 multi-LLM review curated P0 findings (A/B/C/D)
preserved_for: integrator audit trail
---

# 4.6 Sub-author raw output (preserved verbatim)

The text below is the unmodified output of the 4.6 sub-author invocation. It contains the reject log and the revised v0.2 body inside a fenced markdown block. The 4.7 integrator's cleaned-up final v0.2 lives in `multi_llm_review_transport_layer_design_v0.2_draft.md`.

---

v0.1 を読みました。4 件の P0 修正を反映した v0.2 を出力します。

---

# REJECT LOG

## Rejected (c) findings (with reason)

1. **Codex の integrity boundary 提案** (tmux operator out-of-band input への新 invariant 要求) — Reason: 新 invariant 提案、hard constraint §1 違反 (scope constraint violation)
2. **Codex の human visibility 制約提案** — Reason: 同上、scope constraint violation。§5 で意図的に非制約としており v0.1 設計判断を維持
3. **Skeptic の §1 empirical 検証要求 (Inv-1 経験的検証手順)** — Reason: R-series advisory。§11 backlog 追加で吸収済み (P0-B 修正と統合)
4. **Skeptic の Inv-7 cost → 宣言的 policy 一般化提案** — Reason: selective survival。v0.1 文面で十分機能しており一般化は premature
5. **全 P2 advisory** — Reason: invariant 文面修正なし。§4 微修正のみ許容範囲
6. **Cursor の Inv-6 境界曖昧性指摘** — Reason: §2 scope + §3 表で読み取り可能、明示的修正不要
7. **Cursor の Prop 1/3/4/5/8 内部定義欠落指摘** — Reason: CLAUDE.md 参照で十分。§3 表脚注は不要（propositions は本設計の読者が既知の前提）

## Accepted (a)+(b) P0 fixes

**A. (P0-A, philosophy-aligned) Inv-1 命名 qualify + §4 register 差明示.** Inv-1 の「transport 独立性」を「transport に対する観測不変性」に改め、§1 問題文と §3 表の Inv-1 行を一致させる。§4 に「Inv-4/Inv-5 による transport 状態の constitutive recording は Inv-1 と別 register で作用する」旨を 1 文追加。Inv-1 の主張を finding tuple の observation invariance に限定し、blockchain 記録経路での transport 可視性との overclaim を解消。

**B. (P0-B, deployment-grounded) §7 Inv-1 違反基準に非決定性 qualifier 追加 + §11 backlog 追加.** §7 の Inv-1 違反記述に「LLM 非決定性要因（温度、サンプリング）を統制した条件下で」を qualifier として挿入。§11 に「Inv-1 観測不変性の経験的検証手順（温度固定、複数 sample 平均、非 transport 要因の分離）」を backlog 項目として追加。

**C. (P0-C, deployment-grounded) Inv-4 に transport identity 記録要求を追加.** Inv-4 の文面に「使用された transport identity」を blockchain 記録の必須フィールドとして追加。これにより Inv-5 (silent fallback 禁止) の post-hoc 検証が blockchain 記録から可能になる。§7 の Inv-4 違反基準にも transport identity 欠落を追加。

**D. (P0-D, deployment-grounded) §4 に lifetime/state 次元分離を明示 + Inv-3 qualify.** §4 justification の Inv-2/Inv-3 段落に「lifetime (Inv-2) と対話状態 (Inv-3) は別次元」を明示。Inv-3 文面を「記録されたリセット event 以降」で qualify し、リセット手段の具体的契約は §11 mechanism に委ねることを §4 で宣言。

[Body of revised v0.2 follows — see integrated file `multi_llm_review_transport_layer_design_v0.2_draft.md` for the canonical version.]
