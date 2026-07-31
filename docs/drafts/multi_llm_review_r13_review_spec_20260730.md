# R13 レビュー仕様（事前宣言）— multi_llm_review 判定読み取りの修正

- 日付: 2026-07-30
- 状態: DECLARED（レビュー投函前に宣言。投函後は変更しない）
- 対象ループ: multi_llm_review 予備枠＋persona 実行モデル実装（設計正本 = `docs/drafts/multi_llm_review_escalation_and_persona_model_design_v06_20260727.md`、FROZEN）
- この文書の根拠: L1 `loop_validation` v0.4（事前宣言 spec → fail-closed 判定）。R10〜R12 が収束しなかった主因は、レビュー対象が凍結設計の外（自作計器）へ移ったのに合格条件を宣言し直さなかったことにある（分析 = L2 `review_surface_inflation_length_vs_model_verified_20260728` ほか）。R13 から対象と合格条件を宣言してから投函する。

## 1. レビュー対象（出荷物）— これだけが P0/P1 の的

| ファイル | 変更 |
|---|---|
| `lib/multi_llm_review/verdict_vocabulary.rb` | 語彙表の一本化（WORDS）。`classify` 削除 |
| `lib/multi_llm_review/persona_assembly.rb` | persona の宣言判定を `stated`（値全体・錨つき）で読む。死んだ `*_ALIASES` 定数を削除 |
| `lib/multi_llm_review/consensus.rb` | 宣言判定を正準形で運ぶ（`merge(verdict: declared)`）。死んだ `VERDICT_PATTERNS` を削除 |
| `test/test_mutation_survivors.rb` | 新テスト 2 クラス追加、語彙テスト 2 クラスを一本化後の形に書き換え |
| `test/test_multi_llm_review.rb` | 散文判定のテスト 1 件を新しい振る舞いに書き換え |

評価の枠は凍結設計 v0.6 の不変条件（INV-E1〜E5、INV-P1、INV-P2）。とくに INV-E2（母数に入るのは判定を伴う実質のあるレビューだけ）と INV-E4（母数の構成は記録から判別できる）。

## 2. 今回の修正 3 件と、各修正が新しく主張すること

R12 の P0 10 件のうち、出荷コードに関わる 3 件（P0-1, P0-2, P0-3）を閉じる。1 ラウンドの修正上限は 5 件（今回 3 件）。

### F-1a — persona の宣言判定を値として読む（P0-1 を類ごと閉じる）

`normalize_verdict` が `classify`（語の検索）でなく `stated`（値全体）で読む。判定の読み取り関数は全経路で `stated` 一つになり、`classify` は削除。

**新しく主張すること**:
- persona の判定欄が EXACT の形でない値（散文、不可視空白つき、`NOT APPROVED`）は、その中の語がどう読めても**判定として数えられず**、REVISE ＋ 警告に落ちる
- 経路間で異なるのは「判定でない値」の落ち先だけ（persona = REVISE ＋警告、外部 = `no_verdict` で母数外）。これは意図した差で、共有される不変条件は「判定でない値は判定として数えない」
- 副次効果: R12 外部 P1「persona 経路で `NOT APPROVED` が APPROVE」はこの修正で閉じる

### F-1b — 語彙表を WORDS 一本に（P0-2 を類ごと閉じる）

語のリストは `WORDS` 一箇所。検索用と値判定用の正規表現は、そこから区切り字クラスだけ替えて組み立てる。錨と padding（`\A…\z`、`\**`、`[ \t]`）は正規表現リテラル内に残す。

**新しく主張すること**:
- 組み立て後の正規表現 6 本は R12 時点のリテラルと**ソース文字列一致**（実測 6/6 IDENTICAL。挙動不変の作り替え）
- 語の文字列は変異掃引の対象外になる。その代償は per-alias の明示テスト（`TestEveryWordInTheVocabulary`、全別名語 × 主要区切り × 大小 × padding、52 形）で払う。錨と padding は引き続き掃引が見る。被覆は代表であって機械展開の全被覆ではない（文法が受理する形のうち約 30 形は一覧外。二写しの食い違いは WORDS 一本化で構造的に消えているため、一覧の役割は「語の脱落・誤記の検出」に縮む）。R12 が名指しした 4 形（`NEEDS\tWORK` `CHANGES\tREQUIRED` `NO\tGO` `NEEDS CHANGE`）は収載済み
- 退役したのは**二写しの等価テストのクラス**（`TestTheTwoVocabulariesAcceptTheSameWords`）。FORMS の一覧自体は 47 → 52 形に拡張して残る。「値である判定は実質を持たない」（`residue == ''`）を不変条件として保持

### F-2 — 宣言判定は正準形で運ぶ（P0-3 を閉じる）

`extract_verdict` は門を通した宣言を `merge(verdict: declared)` で正準形にして返す。`skip` 小文字宣言も `SKIP` に正準化され母数を出る。

**新しく主張すること**:
- 小文字・混在の宣言（`approve`、`Reject`、`skip`）は宣言どおりに数えられる（従来: 門は通るが `== 'APPROVE'` に届かず、母数だけ上げる行になっていた）

## 3. 付録（参照物）— 的にしない

変異掃引の結果・分類 TSV・ハーネス・分類 script は**レビュー対象でない**。これらへの指摘は歓迎するが、(c) 相当の助言として queue（L2）へ入り、判定を動かさない。理由: 分類表 325 行の理由文はそれ自体が反証可能な主張の山で、これを的に含めると期待指摘数が毎ラウンド二桁になり、構造的に収束しない（07-30 分析）。計器自体の審査は、計器を凍結する際に別ループとして行う。

R12 の P0 のうち計器側の 5 件（P0-4〜P0-8: nth 不使用、GROUP 並び順依存、fail-open の誤分類ほか）と数字の誤り 2 件（P0-9, P0-10）は queue 済み（L2 `handoff_multi_llm_review_r12_results_and_open_p0s_20260730`）。外部 P1 の JSON 重複鍵も queue。

## 4. 合格条件（fail-closed）

**APPROVE の条件**（すべて満たすこと）:
1. §1 の出荷物に対する (a) 指摘（仕様違反・実行時欠陥・データ破損・並行性）がゼロ
2. §2 の「新しく主張すること」がいずれも反証されない
3. 不変条件 INV-E2 / INV-E4 / INV-P1 / INV-P2 との矛盾が指摘されない

上のいずれかが破られれば REVISE/REJECT。付録への指摘は条件に入らない。

**閉じ方**(D-4、投函前に宣言): 閾値 3/5 への到達、**または** (a)+(b) の消尽を masaomi が確認して freeze 宣言。後者は凍結設計 v0.6 §5「収束判定への影響」が「比率の到達とは別の閉じ方として既に機能している」と定める経路。到達可能性の注記: `claude_cli_opus4.6` 枠は 3 セッション連続で `model_divergence`（haiku-4.5 が応答、原因未調査）であり、食い違い枠の APPROVE は数えないため、**閾値到達は算術的に困難な見込み**。これを見込んだ上で投函する。

## 5. 実施記録（判別実験を兼ねる）

- 改訂の著者: orchestrator を Opus 5 から **Fable 5**（自動で Opus 4.8 に切り替わる場合あり）へ変更して実施。07-28 検証の手当て #1（改訂を別モデルに書かせる）の初適用
- persona は R12 と同条件に保つため **`model: opus`（Opus 5）で明示起動**する。著者だけを替え、検査側を固定する — これで「Opus 5 は著者として甘いのか、検査側の配置が厳しいのか」が R12 との比較で判別できる
- 赤→緑の記録: 新テスト 8 件を修正前コードに当てて 7 件が赤（予測どおりの現行欠陥、反証専任が R12 の lib 復元で独立に再確認）、修正後に全緑。最終テスト数は 467 → **477 runs / 1630 assertions / 失敗ゼロ**（15 ファイル。的絞り走行後の追補と FORMS 拡張を含む）
- 正規表現の作り替えはソース一致で挙動不変を確認（6/6 IDENTICAL。反証専任が R12 成果物 Appendix D の旧リテラルとの比較で独立に再確認）
- 的絞り変異走行（触った 3 ファイル、ハーネス `--only`）:
  - `verdict_vocabulary.rb`: 36 変異、初回生存 11。うち本物の穴 **5 件**（検索側 `\b` 3 件 — 末尾 2・先頭 1 — と `/i` 2 件。`classify` 削除でテストも消えた副作用）に断言を追加して再走行、**生存 6**。残り = 等価 5（`gsub→sub` 2 件は各語に区切り placeholder が高々 1 個、未使用の区切り引数への変異 3 件）＋到達不能 1（`strip` の `.to_s`、出荷経路の呼び出し元は常に String）
  - `persona_assembly.rb` ＋ `consensus.rb`: 生成 215（構文 2、分母 213）、既存 suite が 116・新テストが 51 を殺し、生存 46。**変更領域（`normalize_verdict`、宣言判定の正準化ブロック）の生存はゼロ**。46 件はすべて今回触っていない既存領域で、R12 分類の queue と同種（未検査の上限定数、防御的 `.to_s`、旧抽出正規表現の量指定子）。記録 = `.tmp_mlr_r13_targeted{,2,3}.{log,json}`
- 投函前に反証専任 1 体がこの文書の事実主張（とくに数字と「〜が無い」型）を実測で照合する（07-28 手当て #2）

## 6. 投函の形

- 成果物はパス＋sha256 で原本を指す（R12 で実証済みの形式）。転記しない
- roster: persona 3 体（verdict_reading / classification_soundness / instrument_integrity 相当、ただし §1 の対象と §3 の区分を prompt に明記）＋外部 3 機（cli_opus4.6 / codex_gpt5.6-sol / cursor_composer2.5）
- prompt には CLAUDE.md の philosophy briefing と本仕様の §1〜§4 を前置する
- **実行系の注記**（反証専任の観察、2026-07-30）: レビューの実行系（MCP サーバが読む `.kairos/skillsets/multi_llm_review/`）は R7 相当のままで、本修正を含まない。これは R10〜R12 と同じ条件（instance 同期は収束後・masaomi の承認後）であり、レビュアーが読むのは template 側の原本なので判定対象に影響しない。同期のタイミングは収束後に裁定
