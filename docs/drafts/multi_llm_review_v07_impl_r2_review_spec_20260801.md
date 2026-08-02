# v0.7 実装ラウンド R2 レビュー仕様（差分宣言）

- 日付: 2026-08-01
- 状態: DECLARED（R2 投函前に宣言。基底 = `multi_llm_review_v07_impl_review_spec_20260801.md`、ここに書かない項は基底のまま）
- 再宣言の理由: レビュー対象が裁定により変わったため（L1 `multi_llm_review_workflow` v3.8.0 Step -1 の再宣言条件）

## 1. 裁定の記録（masaomi、2026-08-01）

1. **(c) 群は advisory のまま維持**。R1 の (c)（重複鍵 JSON の全体拒否・stated_text 120 字上限・alias 全廃の旧 prompt 影響）は凍結設計の選択への異議であり、修正しない。記録には残る。
2. **agent_step の連動を本バンドルに入れる**。schema 版 1→2 が兄弟 SkillSet の review 門を恒常 INSUFFICIENT にする件は、範囲を宣言して本束で直す。

## 2. 対象の拡大（基底 §1 への差分）

- 追加対象: `KairosChain_mcp_server/templates/skillsets/agent/tools/agent_step.rb` の**連動 2 点のみ** — `SUPPORTED_VERDICT_SCHEMA_VERSION` の 2 対応と、payload の判定読み（`reference_verdict`、v1 記録は `verdict` 互換読み）。
- agent SkillSet のこれ以外への指摘は advisory（本束の対象外）。

## 3. 修正の申告（本ラウンドは 6 件 = 基底の 5 件上限＋裁定による範囲拡大分 1）

各修正の「新しく主張すること」:

1. **完結の事実で pin** — 同期 collect も collected.json を書き、掃除は state の完結印（collected/final_payload）でも pin する。→ 完結記録はどの経路・どの世代でも掃除に消されない。
2. **refusals.json の保全** — 縮約の keep に加え、reaped.json に refusal_count を載せる。→ 未完結 run の既知事由（差し戻し）は縮約後も読める。
3. **persona 行と招集の申告** — 座席 entry に persona_rows（体名＋判定の行）を持たせ record へ運ぶ。新入力 `persona_count_declared`（任意）を投函時に記録。→ 座席の中の行と、招集の申告 vs 提出の差が記録から読める（INV-R3/R4）。
4. **終端は必ず自分の事由を書く** — 一段経路の rescue に abandon_run、completed 書き込み失敗は payload に明示、spawn 失敗時は縮約まで行う、collect は reaped を先に見る。→ 偽の「期限切れ」事由は生成されない。（stale コメント 2 件の訂正を同梱: persona_assembly の「known gap」節・consensus の {}.merge 過大記述。挙動変更なし）
5. **記録面の列はテストが握る** — serializer 3 面の列固定・review_spec の delegation 往復・seat の excluded 枝・undelivered 行への artifact_delivery 欄追加。→ 記録に載る列は消すと赤くなる。
6. **agent_step 連動**（裁定 2）— 版 2 対応＋ reference_verdict 読み（v1 互換）。→ 兄弟門は v1/v2 どちらの記録も正しく読む。

## 4. 合格条件・閉じ方

基底 §3・§4 のまま（(a)+(b) 消尽 → masaomi 宣言）。R2 の焦点 = R1 の P0 クラスタ 8 が閉じたこと＋修正 6 件が宣言どおりであること。
