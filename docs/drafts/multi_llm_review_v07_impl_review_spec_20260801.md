# v0.7 実装ラウンド レビュー仕様（事前宣言）

- 日付: 2026-08-01
- 状態: DECLARED（実装開始前に宣言。ラウンド中は変更しない。レビュー対象そのものが変わった場合のみ、L1 `multi_llm_review_workflow` v3.8.0 Step -1 に従い再宣言する）
- 土台: 設計ラウンド spec（`multi_llm_review_v07_review_spec_20260731.md`）の形式。本ラウンドは実装フェーズであり、凍結設計 v0.7.5 を実装する
- 凍結設計（正本・前提）: `docs/drafts/multi_llm_review_v07_record_schema_design_20260731.md`（FROZEN、sha256 `ec58724081fecaf3b1031fea669cd1db77a2d6ceec927db24fdc16e033cb556a`）
- 手順の規範: L1 `multi_llm_review_workflow` v3.8.0 Step -1／開始申し送り = L2 `handoff_mlr_v07_implementation_round_start_20260801`

## 1. レビュー対象（P0 適格はここだけ）

- 対象 = `KairosChain_mcp_server/templates/skillsets/multi_llm_review/` 配下の実装差分（`lib/` `tools/` `bin/` `config/` `skillset.json`）とそのテスト（`test/`）。
- 凍結設計 v0.7.5・v0.6 への指摘は advisory。「実装が凍結不変条件（INV-R1〜R7）または §2 の宣言済み機構選択と食い違う」という指摘は対象内（(a)）。
- `llm_client` SkillSet は本ラウンドで変更しない前提。変更が必要になった場合は本 spec を再宣言する。
- §2 で「変更しない」と宣言した現行挙動（padding 規則、`stated()` の全値一致、差し戻しの粒度、legacy 単一ファイル層の掃除規則）への指摘は advisory。

## 2. 機構の選択（宣言）— 設計 §6 backlog 15 項

実装は以下の選択に対して評価される。選択そのものへの異議は (c) advisory（機構の選択は設計が実装に委ねた裁量）。ただし「選択が INV-R1〜R7 を破る」は (a)。

| # | backlog 項 | 選択 |
|---|---|---|
| 1 | WORDS 縮小 | `WORDS` を 3 語幹＋時制活用のみに縮小: `APPROV(E\|ED\|ES\|ING)` / `REVIS(E\|ED\|ES\|ING)` / `REJECT(∅\|ED\|S\|ING)`。全 alias（LGTM, PASS, FAIL, BLOCK, NO-GO, NACK, DENY, VETO, ACCEPT, SHIP IT, CHANGES REQUIRED, NEEDS WORK, REWORK）廃止。padding 規則と `stated()` の全値一致は現行維持。参考値化（#2/#9）と同一 commit（INV-R1×R2 相互条件）。語彙の場 3 つの同期: prompt は正準 3 行（現行どおり）、collect input_schema enum は正準 3 語、`stated()` は 3 語＋活用（enum ⊂ stated なので予告と読みは食い違わない） |
| 2 | 結論欄の改名か注記か | 改名を選ぶ: 最終 payload 最上位の `verdict` を `reference_verdict` へ。値域（APPROVE/REVISE/INSUFFICIENT）と計算は現行のまま、意味だけが門から参考値へ降りる（INV-R2）。`Consensus.aggregate` の返り鍵も `:reference_verdict` へ |
| 3 | 受理の門の体数下限 | `MIN_PERSONAS` 2→0。collect `input_schema` の `minItems` は定数参照で自動連動（連動 2 箇所は構造上 1 箇所）。`validate!` の下限検査を削除 |
| 4 | 空の受理集合の既定 | `assemble([])` は `status: :skip`・事由 token `empty_persona_submission` の座席行を返す。`else 'APPROVE'` には到達しない（製造票の形を残さない）。座席は INV-R2 の実質測定で母数を出て、事由が記録に残る |
| 5 | 拒否の追記の機構 | collect の `rescue ArgumentError`（flock 保持中）で token dir の sidecar `refusals.json` に `{refused_at, stage, reason(≤200字), submission_count}` を追記。**拒否された本文は保存しない**（Open Unknown「載せる中身の範囲」は事実と事由だけの側に倒す）。成立した collect が sidecar を読み `refused_submissions` として最終 payload に載せる（INV-R4） |
| 6 | 除外集計の欄名と置き場 | `convergence.excluding_divergent` = `{approve_count, reject_count, successful_count, threshold}`。常に併記（INV-R5）。母数は動かさない |
| 7 | 診断欄の通し方と格 | dispatcher `build_success` が llm_call 応答の `api_error_status` / `fast_mode_state` を row へ（1 行）、`ReviewSerializer` の serialize / payload_row / deserialize が運ぶ（各 1 行、nil は `.compact` で落ちる）。**状態の札のみ**。資格情報・本文は運ばない（INV-R6＋設計ラウンド advisory） |
| 8 | spec 参照の置き場と同一性 | 新入力 `review_spec: {path, sha256}`（任意）。pending state と最終 payload に `review_spec` としてそのまま記録。系は検証しない — パス＋sha256 が読み手の確かめ方（INV-R6） |
| 9 | 到達可能性の計算時点 | dispatch 構築時（ObserverSet 解決後・投函前）。配布されない座席はその時点で excluded に載る |
| 10 | JSON `overall_verdict` 重複鍵の門 | `parse_structured` が重複鍵を検出（挿入時に重複を拒む object_class）→ 文書でないとして nil（判定なし側へ、fail-closed） |
| 11 | `artifact_delivery` の表現と解決 | roster 枠ごとの config key `artifact_delivery: inline \| by_reference`、既定は正本の枠に置き、無指定は `inline`。新入力 `artifact_path`（任意）。sha256 は渡された `artifact_content`（sanitizer 通過前の原文）から系が計算。`by_reference` 枠には本文の代わりに参照 manifest（path＋sha256＋検証指示）を配る。到達不能（`claude_code`×`independent` の実測 2026-07-31、または `artifact_path` 不在）→ 配布されず、事由つきで excluded に載り母数に入らない — それが唯一の帰趨（INV-R7）。row に `artifact_delivery` を記録。persona 座席には配布の行為が存在せず、本欄もない |
| 12 | persona 座席の導出規則 | 現行の優先順位規則を既定のまま、persona 座席 row に `verdict_derivation: 'precedence:REJECT>REVISE>APPROVE'` を明記（INV-R3「どの規則が走ったかを記録に」） |
| 13 | 痕跡の形・保持期間・書き込み点 | 全経路（非同期・同期・一段）で token dir＋`marker.json` を**投函の時点**で書く（一段経路も token を持つ）。完結の記録（collected.json／一段は completed.json）がそれを置き換える。掃除: collected/completed を持つ dir は reap しない（保持は無期限 — `retain_collected_seconds` の切除を廃止）。期限切れ pending dir は `rm_rf` でなく最小痕跡へ縮約 — `marker.json`＋`reaped.json {reaped_at, 判明事由}` を残し他を削除。legacy 単一ファイル層（v0.2.x、旧記録）は遡及しない（§4 非目標）ため現行掃除のまま |
| 14 | 差し戻しの粒度 | 現行のまま呼び出し全体（変更しない）。差し戻しの事実と事由は #5 の sidecar が担う |
| 15 | schema 版の印 | `BuildReviewBundle::VERDICT_SCHEMA_VERSION` 1→2。読み手は payload の `verdict_schema_version` で新旧を読み分ける（遡及なし・読み手の問題、設計 §5） |

backlog 外だが設計本文・advisory が要求する付随実装:

- **事由の札＋語形別欄**: `skip_reason` は閉じた token のまま（`DECLARED_REASON_RE` 維持）。語彙外の語で判定を試みた終局の提出は、書かれた語を `stated_text`（≤120 字）として row・composition に別欄で残す（INV-R1「書かれた語が事由として記録に残る」） |
- **座席印**: denominator_composition の各行に `seat: true`（真偽 1 欄。将来行レベルの記録が混ざっても座席の列を復元可能に） |
- **`PARSED_VERDICTS` から `SKIP` を除去**: INV-R1「SKIP を含め特例となる語は存在しない」。出荷済み書き手経由で到達不能なことは R12 で測定済み |
- **worker 経路の配布対応**: request.json に配布形式別 messages を持たせ、`Dispatcher.dispatch` は Array（従来・全 inline）と Hash（形式別）の両方を受ける |
- **version**: skillset.json 0.7.0 → 0.8.0 |

## 3. 合格条件（fail-closed）

APPROVE には以下のすべてが必要:

1. §1 の対象への (a) がゼロ — 実行時バグ／データ破壊／並行性ハザード／INV-R1〜R7 または §2 宣言との食い違い／「その実行の記録だけから判別できる」を破る欠落／テストが偽の緑を返す構造。
2. (b) が消尽 — 設計規律からの逸脱（凍結設計にない新機構の本文追加、宣言済み選択の黙った変更）。
3. (c) は advisory であり blocking ではない。機構選択そのものへの異議・一般的な工学的好みはここ。

## 4. 閉じ方（投函前に宣言する消尽経路）

- 閾値: 3/5（参考値）。食い違い枠の APPROVE・空返答型 APPROVE は到達の根拠にしない。薄い APPROVE は raw_text_length を併記。
- roster: persona 3 体（`model: opus` = Opus 5、チーム申告）＋ `claude_cli_opus4.6` ＋ `codex_gpt5.6-sol` ＋ `cursor_composer2.5`。codex は較正上 6 ラウンド中 4 回空返答型 APPROVE（実質 1 回のみ REVISE）— 到達は可能だが保証されない。
- 主経路: (a)+(b) の消尽 → masaomi の freeze（実装ラウンドでは merge/commit 承認）宣言。
- 修正は 1 ラウンド 5 件まで。各修正に「この修正が新しく主張すること」を 1 行つける。

## 5. ラウンド運用

- 投函前に反証専任 1 体: 本 spec と実装中の数字・「〜が無い/〜は実装済み」型主張をコードと記録の実測で照合してから投函。
- 配布: `claude_cli` 枠 = 本文込み（sandbox 実測によりリポジトリ不可読）／codex・cursor = パス＋sha256／persona = harness 内で原本参照。
- 実装フェーズにつき philosophy briefing は付けない（CLAUDE.md の scope 規則）。Design Direction Block は任意。
- collect 期限は 5400 秒を呼び出しごとに `collect_deadline_seconds_override` で明示。persona の stall（600 秒無進行）は同 prompt 再走。
- 判定表の報告は per-reviewer 判定・raw_text_length・(a)/(b)/(c) 内訳を併記。
- `model_divergence` の発火は本物として調査（adapter `keys.first` 誤読は修正済み）。
