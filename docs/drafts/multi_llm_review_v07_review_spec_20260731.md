# v0.7 レビュー仕様（事前宣言）— 記録 schema ミニ設計・設計ラウンド

- 日付: 2026-07-31
- 状態: DECLARED（R1 投函前に宣言。ラウンド中は変更しない。レビュー対象そのものが変わった場合のみ、L1 v3.8.0 Step -1 に従い再宣言する）
- 土台: R13〜R15 spec の形式（`docs/drafts/multi_llm_review_r{13,14,15}_review_spec_*.md`）。ただし本ラウンドは実装でなく新規設計文書を対象とする設計ラウンドであり、掃引・分類表は最初から存在しない
- 手順の規範: L1 `multi_llm_review_workflow` v3.8.0 Step -1／開始申し送り = L2 `handoff_mlr_v07_design_round_start_20260731` §3

## 1. レビュー対象（P0 適格はここだけ）

- 対象 = `docs/drafts/multi_llm_review_v07_record_schema_design_20260731.md`（本ラウンドで作成する設計文書 1 本）の本文と不変条件。
- 対象文書の backlog 節（実装時に選ぶ機構）への指摘は advisory。
- 凍結済み v0.6（`multi_llm_review_escalation_and_persona_model_design_v06_20260727.md`）は前提であり、それ自体は対象外。v0.6 への指摘は advisory。ただし「v0.7 が v0.6 の凍結不変条件（INV-E1〜E5・P1・P2）と未申告のまま矛盾する」という指摘は対象内（(a)）。
- 実装（lib / test）は本ラウンドの対象外。実装への指摘は queue へ。
- Unknowns Pass（Step 0.25）で宣言された Open Unknown の再指摘は (c) advisory（INV-U4。本ラウンドの宣言は attended pass による）。ただし「宣言された先送り自体が危険」という指摘は blocking のまま。

## 2. 合格条件（fail-closed）

APPROVE には以下のすべてが必要:

1. §1 の対象への (a) がゼロ — 実現不能な不変条件／不変条件同士の矛盾／v0.6 凍結不変条件との未申告の衝突／「その実行の記録だけから判別できる」を破る欠落。
2. (b) が消尽 — design-by-invariant からの逸脱（機構列挙の本文混入、invariant で足りる箇所の枝分かれ列挙、改訂中の新設節）。
3. (c) は advisory であり blocking ではない。

## 3. 閉じ方（投函前に宣言する消尽経路）

- 閾値: 3/5。ただし食い違い枠の APPROVE・空返答 APPROVE は到達の根拠にせず、薄い APPROVE は raw_text_length を併記して判断材料にする。
- 到達可能性: roster = persona 3（同一モデルの申告）＋ `claude_cli_opus4.6` ＋ `codex_gpt5.6-sol` ＋ `cursor_composer2.5`。codex は較正上 perpetual-REJECT 傾向のため、閾値到達は可能だが保証されない。
- 主経路: (a)+(b) の消尽 → masaomi の freeze 宣言（凍結設計 v0.6 §5 が既に認める閉じ方）。比率は参考値として記録する。
- 修正は 1 ラウンド 5 件まで。各修正に「この修正が新しく主張すること」を 1 行つける。

## 4. ラウンド運用（Step -1 の系＋環境注意）

- 投函前に反証専任 1 体: 設計文書中の数字と「〜が無い／〜は実装済み」型の主張を、コードと記録の実測で照合してから投函する。
- 配布は枠ごとに分ける: `claude_cli` 枠 = 本文込み（sandbox によりリポジトリを読めないため）／codex・cursor = パス＋sha256／persona = harness 内で原本参照。
- Step 0（reviewer 較正の読込）・Step 0.25（投函前に全 unknown が終端状態であること = INV-U1）・Step 0.5（Design Direction Block）＋ philosophy briefing を全 reviewer prompt に適用する。
- collect 期限は 5400 秒。ただし設定の既定は 1800 秒なので、呼び出しごとに `collect_deadline_seconds_override` で明示的に渡す（渡し忘れると 1800 秒で走る）。persona の stall（600 秒無進行）は同 prompt で再走。
- 判定表の報告には per-reviewer の判定・raw_text_length・(a)/(b)/(c) 内訳を併記する。
- `model_divergence` が発火したら本物として扱い調査する（adapter の `keys.first` 誤読は修正済のため、以後の発火は既知原因では説明できない）。
