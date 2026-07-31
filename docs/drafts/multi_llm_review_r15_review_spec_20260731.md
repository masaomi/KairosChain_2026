# R15 レビュー仕様（事前宣言）— 注釈の訂正と断言の締め直し

- 日付: 2026-07-31
- 状態: DECLARED（投函前に宣言。投函後は変更しない）
- 土台: R14 仕様 `docs/drafts/multi_llm_review_r14_review_spec_20260731.md`（付録の扱い・合格条件の形式・閉じ方を引き継ぐ）。本書は差分のみ
- R14 の結果: 道具の集計 APPROVE（2/2 到達・reject 0・食い違い枠は機構が自動で `no_verdict` 退出）、事前宣言 spec では persona P0 2 件（いずれも (b)、(a) ゼロ）で REVISE。R13 の 6 件は 3 persona 全員が closed 判定。L2 `handoff_multi_llm_review_r14_results_20260731`

## 1. masaomi の裁定（2026-07-31）

R14 P0-2（拒否が実行の記録に痕跡を残さない）は **v0.7 記録 schema 改訂の queue へ**。同じ束: 食い違い票の母数扱い（C-3）・llm_client 診断欄の永続化。根拠: 記録に何を足すかの設計は一度にやる。R12/R13 の着地（語検索・REVISE fallback)も同様に無痕跡だったので退行ではない。**本ラウンドの的から外れる**（言及は歓迎、advisory 扱い）。

## 2. レビュー対象（出荷物）— lib の挙動変更ゼロの回

| ファイル | 変更 |
|---|---|
| `lib/multi_llm_review/persona_assembly.rb` | **注釈一段落のみ**（F-T1）: validate! の注釈の INV-E4 援用を訂正 — 充足根拠は「拒否は母数を動かさないので記録すべき事由が発生しない」であり「error が呼び出し元へ届く」ではない。旧版がその誤った主張をし R14 が反証した経緯と、記録の空白が queue 済みであることを本文に明記 |
| `test/test_multi_llm_review.rb` | F-T2: collect 継ぎ目テストに断言 5 行 — collected.json 不生成・pending state のバイト一致・言い直し後の構成（reviews 3 / persona_count 2 / llm_calls 2）。土台が legacy 単一ファイル形式なので実在する方のパスを読む |
| `test/test_mutation_survivors.rb` | F-T3: SKIP 拒否の pin（`SKIP`/`skip`/`Skip` × message 照合）。F-T4: 素の `assert_raises` 2 件に `/not a verdict/` の message 照合を追加（別の門の同型 error で緑になる穴）。F-T5: 削除の pin（`normalize_verdict`・`classify` の respond_to? 否定、`ALLOWED_VERDICTS`・`VERDICT_PATTERNS` の const_defined? 否定） |

R14 P2 のうち今回**やらない**もの（queue のまま）: 判定欄の 4 回読み（出荷経路で到達不能）／実質判定の計器の経路間不等（R14 変更外）／replay の短絡（冪等性としては正）／error_class（先行欠陥）／parallel 経路の言い直し検証／`test_mutation_survivors.rb` の git 追跡（commit 時に対応）。

## 3. 各修正が新しく主張すること

- F-T1: 注釈は INV-E4 の条文（記録だけから判別・母数を動かした事由は記録に残る）に対して正しい充足根拠を述べ、検証不能な主張を含まない。記録の空白は隠さず queue として名指しされている
- F-T2〜T5: 断言はいずれも**現行実装で緑**（実装は R14 で正しいと実測済み — 締め直したのは断言の側）。赤→緑の証拠は該当しない（挙動変更がないため）。それぞれが押さえる穴は R14 の P2 指摘の名指しどおり

## 4. 合格条件（fail-closed・R14 と同形）

(1) §2 の対象への (a) ゼロ、(2) §3 の主張が反証されない、(3) INV-E2/E4/P1/P2 と矛盾しない（**P0-2 の記録の空白は §1 の裁定により本ラウンドの条件 (3) の対象外** — v0.7 で扱う）。閉じ方 = 閾値 or (a)+(b) 消尽 → freeze 宣言。食い違い枠の APPROVE は数えない（今回は機構が自動処理する見込み）。

## 5. 実施記録

- 著者: fable5/4.8、persona: `model: opus`（Opus 5 固定）— R13/R14 と同条件
- テスト: 476 → **478 runs / 1668 assertions / 失敗ゼロ**（15 ファイル）
- 掃引: 実施しない。lib の実行可能な変更がゼロ（注釈のみ）のため、変異の分布は R14 の的絞り走行から変わらない。suite 緑が証拠
- 反証専任 1 体（Opus 5）: **6 項目全て CONFIRMED**。うち「lib の挙動変更ゼロ」は三重に裏取り — consensus/verdict_vocabulary の sha256 が R14 投函時と一致、R14 掃引記録の全 91 変異が「注釈ブロックへの 11 行挿入・他は offset そのまま」で 91/91 突き合わせ一致、挙動 battery 実測が R14 主張と同一。検証不能で残るのは「R14 版のどの 2 件が素の assert_raises だったか」（未 commit の上書きで復元不能）等の歴史記述のみ
