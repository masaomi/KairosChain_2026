# R14 レビュー仕様（事前宣言）— persona 判定欄の着地の作り直し

- 日付: 2026-07-31
- 状態: DECLARED（投函前に宣言。投函後は変更しない）
- 土台: `docs/drafts/multi_llm_review_r13_review_spec_20260730.md`（R13 仕様）。§A-3（付録の扱い）・§A-4（合格条件の形式）・投函の形はそのまま引き継ぐ。本書は差分のみ。
- R13 の結果: 道具の集計は APPROVE (3/3) だが食い違い枠（haiku 応答、実在の切替と 07-31 調査で確定）を除くと 2/3。persona team は REVISE、P0 実質 4 件 — すべて F-1a の fallback 着地（非判定値 → REVISE）一点に遡る。L2 `handoff_multi_llm_review_r13_results_20260730`。

## 1. レビュー対象（出荷物）

| ファイル | 変更 |
|---|---|
| `lib/multi_llm_review/persona_assembly.rb` | **F-R1**: 判定欄の着地を作り直し。`validate!` が `stated`（値全体）で欄を門にかけ、非判定値は **ArgumentError で提出ごと拒否**。`normalize_verdict` と `ALLOWED_VERDICTS`（死んだ定数）を削除。`assemble`・`build_raw_text` は検証済みの値を `stated` で読む |
| `lib/multi_llm_review/consensus.rb` | **F-R2a**: 注釈のみ。R13 が書いた誤った実測（「3 機で successful_count 3」）を R12 成果物 §7 の実測（手組みの 1 行・出荷経路では到達不能・正準化は防御）に訂正。normalize_verdict 削除の経緯注釈も現実に合わせ更新 |
| `lib/multi_llm_review/verdict_vocabulary.rb` | **F-R2b**: 注釈のみ。「refusal は必ず `no_verdict` で母数を出る」を二呼び出し元の現実（外部 = `no_verdict`、persona = 検証で拒否 → 言い直し）に訂正。モジュール冒頭に R13→R14 の経緯を追記 |
| `test/test_mutation_survivors.rb` | persona 着地のテストを拒否形に書き換え（生 U+00A0 の埋め込みも `\u` 表記へ解消）。R13 fallback を主張していた 2 テストを新挙動に更新 |
| `test/test_multi_llm_review.rb` | **collect 階層の継ぎ目テスト追加**: 拒否された提出は token を消費せず、言い直した提出が collect できる。alias テストを assemble 駆動に書き換え |
| `test/test_observer_set_seams.rb` | 「同じ語は誰が運んでも同じ判定」テストの persona 側を assemble 駆動に |

## 2. 裁定の実装形（明示）

masaomi の裁定は「(α) 非判定の persona は母数に入れない・事由を記録」。実装はその**境界形**を採った: 非判定値は提出の門（`validate!`）で拒否し、呼び出し元が言い直す。除外（当人だけ落として続行）にしなかった理由:

- 除外は票を失う。R13 P0 が実測した形 — `REJECT (2 blockers)` — は除外でも reject 票が消え、**回が通る方向に動く**。拒否なら呼び出し元が REJECT と言い直し、票が生きる
- persona 欄は外部応答と違い、**この会話の中で orchestrator が書く欄**。言い直しの費用はほぼゼロで、外部枠に言い直しを求められないという R9 の前提はここに当たらない。二経路の着地が違うことの根拠はこの非対称
- (α) の要件はどちらの形でも満たす: 判定を述べない値は母数に入らず（INV-E2）、事由は記録に届く（INV-E4 — 拒否の error が呼び出し元へ、token は無傷）

この形は R13 persona `verdict_reading` の修正方向の提案（「外部と同じ着地」= 除外）**とも異なる**。上記 1 点目がその提案自身の P0 と矛盾するため。レビュアーはこの判断ごと検証してよい。

## 3. 各修正が新しく主張すること

**F-R1**:
- (i) 出荷コードで `assemble` を呼ぶのは collect の `call_locked` 一箇所で、検証は token の消費・cache 書き込みより**前**に走る。拒否後の再 collect は成立する（collect 階層のテストで保持）
- (ii) 非判定値は、型（文字列・数値）・装飾・不可視空白を問わず提出ごと拒否され、**どの経路の母数にも入らない**。「判定でない値は判定として数えられない」が両経路で成立
- (iii) persona は SKIP を宣言できない（従来どおり・意図した非対称のまま。queue 済）
- (iv) 挙動変更: R12 まで散文判定は語検索で読まれ、R13 では REVISE に落ちた。R14 では拒否。**呼び出し元が新たに負う義務は「正確な判定語で書くこと」だけ**。collect の inputSchema は enum(APPROVE/REVISE/REJECT) を既に宣言しており、enum を守る呼び出し元は何も変わらない — 実際の受理集合は enum より広い（語彙 alias・装飾・小文字も受理、実測 5/5）ので、これは enum そのものの強制ではなく「enum を含む集合」の門である

**F-R2a/b**: 注釈は現行コードと記録に対して真である（R13 P0 の「注釈が保証を騙る」2 件の解消）。実測値の出典は R12 成果物 §7 と R12 L2 handoff。

## 4. 合格条件（fail-closed）

R13 仕様 §A-4 と同形: (1) §1 の出荷物への (a) ゼロ、(2) §3 の主張が反証されない、(3) INV-E2/E4/P1/P2 と矛盾しない。付録（掃引 log・分類・ハーネス）への指摘は advisory。閉じ方も同じ（閾値 or (a)+(b) 消尽 → freeze 宣言）。`claude_cli_opus4.6` 枠の APPROVE は `model_divergence` 時は数えない（07-31 調査で実在の切替と確定済み）。

## 5. 実施記録（投函前に確定させる）

- 著者: fable5/4.8（R13 と同じ）。persona: `model: opus`（Opus 5 固定、R12/R13 と同条件）
- 赤→緑: 拒否形の新テスト 5 件中 4 件が R13 コードで赤（`ArgumentError expected but nothing was raised`）→ 修正後 **476 runs / 1632 assertions / 失敗ゼロ**（15 ファイル）
- 的絞り掃引（`persona_assembly.rb`、二段構え、記録 = `.tmp_mlr_r14_targeted.{log,json}`）: 生成 92 / 既存 suite が殺した 42 / 新テストが殺した 27 / 生存 16 / 時間切れ 6 / 構文 1（分母 85）。生存 16 の内訳: 変更領域は L164 の 4 件のみで、いずれも拒否メッセージの切り詰め表示（80 字の境界・切り詰め枝の `.to_s`）— 仕様が文言を定めない S。残り 12 件は R13 掃引（targeted2）と同一の既存領域（上限定数 3・`IDENT_RE` 量指定子 1・防御的 `.to_s` 群・`empty?`）で queue 済みの類
- **掃引が門の強度を測っていないことの開示**（反証専任の指摘）: 門の判定行（`unless VerdictVocabulary.stated(verdict)`）に生成された変異は 1 件（`unless`→`if`）で既存 suite が殺したが、raise 本体は文字列リテラルのみでこの計器の射程外。**門の強度を担っているのは掃引ではなく、赤→緑のテストと実測（拒否 20/20・受理 5/5）である**
- 時間切れ 6 件の締切は「baseline×5（下限 8 秒）」であり、6 件中 3 件は約 59 秒級・1 件は約 28 秒級の締切を超えている（下限 8 秒の巻き添え候補は 2 件のみ）。生存にも kill にも数えない第三分類として記録
- 反証専任 1 体（Opus 5）による照合: 9 主張 CONFIRMED（うち追加実測 3 — 外部経路でも同値が母数を出ること、persona は SKIP を宣言できないこと、collect 継ぎ目テストが本物を駆動すること）、REFUTED 1（時間切れの締切の記述 — 本節に反映済み）、UNVERIFIABLE 2（R13 の注釈原文は未 commit のため復元不能、掃引の二段実行はハーネス設計からの推定）。「enum の強制」という語の強すぎも指摘され §3(iv) を修正済み
