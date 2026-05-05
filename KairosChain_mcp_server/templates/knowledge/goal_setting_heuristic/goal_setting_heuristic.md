---
name: goal_setting_heuristic
description: "自律 agent のゴール設定・改訂・分岐管理のための軽量ヒューリスティック。Telos 多元性、Boundary 監視、Contradiction 許容を goal-set タイミングと振り返りで適用する。Goal は動的に改訂可能で、大中小 milestone と risk branch を同時保持する。Knowledge Ethos v2.0 が塩漬け中の代替最小構成。"
version: "0.2"
layer: L1
tags: [goal_setting, autonomous_agent, guardrail, knowledge_ethos_lightweight, heuristic]
type: heuristic
status: draft (round 1 multi-LLM review 反映済み)
date: 2026-05-05
author: claude_opus4.7 (起草) + masaomi (着想)
related:
  - knowledge_ethos_philosophy_v1.1_approved_20260417
  - knowledge_ethos_v2.0_guardrail_claude_opus4.7_20260505 (paused)
applies_to:
  - autonomous_agent_goal_setting
  - autonomous_agent_goal_revision
  - autonomous_agent_completion_handler
  - autonomous_agent_weekly_review
---

# Goal-Setting Heuristic v0.2

## 0. Purpose

自律 agent が open-ended な mission を受けて自走するときに、偏狭化を防ぐための最小ヒューリスティック。Knowledge Ethos v2.0 のフル版は塩漬け中なので、その核心 3 機能（Telos 多元性 / Boundary 監視 / Contradiction 許容）だけを抜き出して動かす。本ファイルは agent の prompt context に常時 inject され、加えて以下の特定タイミングで明示的に参照される:

1. 新規ゴール設定時（大・中・小いずれか）
2. 既存ゴール改訂時（mid-flight 動的変更）
3. ゴール完了時 / 失敗時（次の提案を生成）
4. 振り返り時（rolling + 週次）

## 1. Goal 構造

Goal は単一ではなく **3 階層 + branch** で構成する。

### 1.1 階層

| 階層 | 例 | 期間 | 改訂頻度 |
|---|---|---|---|
| **大ゴール (Mission)** | 「GenomicsChain Swiss startup grant 取得」「KairosChain expert として自己成長」「Genomics × Blockchain × AI で KairosChain を市場投入」「HestiaChain 構築」 | 数ヶ月〜年 | ユーザー明示指示 / 大ゴール完了時のみ |
| **中ゴール (Milestone)** | 「Innosuisse 申請書 ver 1 完成」「自律成長 14 日 dry-run 完走」「marketing strategy v0 策定」 | 週〜月 | 大ゴール変更 / milestone 完了・失敗 / 状況変化検出時 |
| **小ゴール (Action)** | 「申請書セクション 3 草案」「dream_scan 1 回実行」「競合 3 社調査」 | 時間〜数日 | 上位 milestone 変更 / action 完了・失敗時 |

### 1.2 Branch (risk management)

各 **中ゴール (milestone)** に対して、最低 2 つの分岐を事前に書き出しておく:

- **Primary branch**: 想定通り進んだ場合の次 action
- **Fallback branch**: 失敗 / 阻害が発生した場合の代替 action
- **Pivot branch** (任意): 想定外の機会を発見した場合の転換先

事前に書き出していない branch は、失敗時に空白となり agent は halt するか低品質な即興判断に陥る。**事前に書き出しておくこと自体がガードレールである**。

加えて、**大ゴール (Mission) レベルでは pivot branch を「大ゴール候補の事前提示」として運用する**。agent は大ゴール自体を改訂できないが、環境変化（grant 締切変更、competitor 動向、ユーザー方針シフトなど）を検出したとき、新しい大ゴール候補を pivot branch として記録しておく。これは次回 user review 時の選択肢になる。これにより agent は user との日常 interaction が無くても halt せず、大ゴール再評価が必要な状況を蓄積できる。

## 2. Heuristic 1 — Goal-Set 時の 3 つの自問

新規に大 / 中 / 小ゴールを立てるとき、必ず次を確認する。違反する場合は代替案を生成するか、判断理由を記録する。

### 自問 1: Telos 多元性

> このゴールが目指す telos は単一か?

Telos 4 軸: **理解** (understanding) / **問題解決** (problem-solving) / **創造** (creation) / **領域づくり** (field-building)

- 単一しか含まないゴール → **最低 2 軸を含む代替案を生成して併記**。例: 「申請書を書く（問題解決のみ）」→ 「申請書を書きながら Swiss 助成エコシステムを理解する（問題解決 + 理解）」
- 大ゴールほど 3〜4 軸並立を推奨。小ゴールは 1 軸でも可だが、その小ゴールが属する中ゴールが多元性を持つこと。

### 自問 2: Boundary 多面性

> このゴールが要求する知識は単一領域に閉じているか?

- 単一領域 → 隣接領域の知識が本当に不要か明示的に check。不要と判断するなら **その判断理由を記録する**（後で振り返り時に bias 検出材料になる）
- 隣接領域知識が必要なのに「効率優先」で削っている場合、削らずに最低 1 つは含める
- 領域の例: Genomics（ドメイン）/ Blockchain（技術）/ AI（技術）/ Swiss innovation policy（制度）/ business / philosophy

### 自問 3: Contradiction 許容

> ゴール達成中に矛盾する情報・意見が出たとき、どう扱うつもりか?

- **デフォルト = coexistence**（両方を scope 条件付きで保持。例: 「small sample では ComBat overcorrects」と「reproducibility 確保には ComBat 必須」を両方残す）
- **exclusion**（片方を捨てる）を選ぶ場合、判断理由を記録する。**理由なき exclusion は禁止**
- multi-LLM review で reviewer 不一致が出たとき、デフォルトは coexistence (両意見を併記)、exclusion は明示的判断のみ

## 3. Heuristic 2 — Goal 改訂のトリガ

次のいずれかが発生したとき、現行ゴールを再検討する。

1. **ユーザーからの明示指示**: 大ゴールは原則これでのみ動かす
2. **完了**: 当該階層のゴールが達成 → success branch 発火
3. **失敗 / 詰まり**: 同一 action を **3 回試して進捗ゼロ** → fallback branch 発火
4. **環境変化検出**: 前提条件が変化（例: grant 締切変更、competitor 製品リリース、masaomi さんの方針変更）→ pivot branch 検討
5. **bias 検出**: 直近 N action（推奨 N=7）の rolling window で telos / boundary 分布が偏向 → 中ゴール再生成。加えて週次でも全集計実施（§5）。これにより website 自律更新のように毎日数 action 走るタスクで bias 検出が最大 6 日遅延することを防ぐ。
6. **introspection_check 連続失敗**: `introspection_check` ツールの `success` フィールドが false で 3 連続出力された場合 → 即時 halt + 大ゴールから再評価。本ヒューリスティック単独で運用条件として self-contained。

中ゴールと小ゴールは agent が自律改訂可能。**大ゴールは agent 単独では改訂しない**（ユーザー承認必須）。これは agent の暴走に対する最後の壁。

## 4. Heuristic 3 — 完了 / 失敗時の Next-Step 提案

ゴールが完了（success）または失敗（fail）したとき、agent は **必ず** 次の 3 種を生成してユーザーに提案する。提案を生成せずに halt することは禁止。

**完了 (success) 時**:

1. **同階層の次のゴール**: 同じ milestone レベルで次に来るもの
2. **上位への昇格提案**: 当該完了が上位 milestone の進捗にどう寄与したか。上位 milestone を update / 完了宣言すべきか
3. **下位への調整提案**: 学んだことを下位 action 設計にどう反映するか

**失敗 (fail) 時**: 上記 3 種に加えて、

4. **失敗 learning 抽出**: なぜ失敗したか。**ethos 的偏狭（telos 単一化 / boundary 縮退 / exclusion 偏重）が遠因でないか self-check**
5. **fallback branch 発火 or 新 fallback 生成**: 既存 fallback が適用可能か。不可なら新 fallback をその場で生成

これにより agent は **完了 / 失敗で halt しない**。常に次の候補を持ち続ける（運用要件「無限に次を考え続ける」の条件）。

### 4.1 halt 許可条件（halt 禁止の例外）

「halt 禁止」には次の例外がある。これらの状況では halt を許可し、token / chain_record の浪費を防ぐ:

1. **大ゴール (Mission) 完了時**: 全 milestone が完了し、次の Mission がユーザー指示待ちのとき → halt 等価。pivot branch に記録された候補があればそれを user review 時の提示材料とする
2. **大ゴール改訂のための user 承認待ち**: §3 トリガで Mission 改訂が必要と判定されたとき → halt 等価
3. **introspection_check 連続失敗 3 回**: §3 トリガ 6 → 即時 halt

### 4.2 提案の blocking / non-blocking 区分

agent が user に提案するとき、提案の種類で blocking 性が異なる:

- **Mission 関連の提案**: blocking（user 承認まで agent は halt 等価で待機）
- **Milestone / Action 関連の提案**: non-blocking（提案を chain_record + L2 に log し、agent は次 action に進む）

これにより、user の日常 interaction が無くても medium / action レベルでは autonomy が継続し、Mission レベルだけが user gate される。

## 5. Heuristic 4 — 振り返り (rolling + 週次)

二段階で実施する:

- **Rolling window**: 直近 7 action ごとに簡易集計。website 自律更新のように毎日数 action 走るタスクで早期検出。§3 トリガ 5 と連動。
- **週次集計**: 週 1 回（推奨: 日曜 22:00 などの固定スロット、launchd plist 1 entry 追加で実装可能）、過去 7 日の goal-set 履歴を全集計する。

| 集計軸 | 計測内容 | Alert 閾値 |
|---|---|---|
| Telos 分布 | 4 軸のうち何軸が active だったか | 1 軸が 80% 超 → 偏向 alert |
| Boundary 分布 | 設定されたゴール領域の数 | 単一領域 80% 超 → boundary collapse alert |
| Contradiction 履歴 | exclusion 採用回数 / 理由記録の有無 | 理由なき exclusion 1 件以上 → 違反 alert |
| Branch 利用 | fallback / pivot 発火回数 | fallback ゼロかつ進捗 100% → ヤラセ疑い alert |

Alert が出たら、来週の中ゴール設計に **強制 inject 項目** を追加する。例:

- telos 偏向 → 「来週は understanding 軸のゴールを最低 1 つ含む」
- boundary 縮退 → 「来週は隣接領域の小ゴールを最低 1 つ含む」
- 理由なき exclusion → 「次回 contradiction 発生時は coexistence デフォルトを徹底、exclusion 採用には理由 100 字以上記録」

集計結果と inject 項目は次の二系統に分けて記録する:

- **L2 へ**: `context_save` ツールで context として保存。ユーザーが朝レビューで参照可能にする
- **Blockchain へ**: `chain_record` ツールで簡易サマリ（alert 種別と件数のみ）を追記。改ざん不能な履歴とする

`context_save` と `chain_record` は別ツールであり、§8 接続表で個別に列挙する。

## 6. Self-Application

このヒューリスティック自身もここに書かれているルールに従って改訂可能:

- 軽量版が効かない病理が観察されたら、新項目を提案する（ユーザーの承認を経て次バージョンへ）
- 効かない項目が観察されたら削除する
- 改訂手続き: L2 → L1 promotion 経路（multi-LLM review 通過 → ユーザー承認）
- バージョン履歴は frontmatter に追記

これは Knowledge Ethos v2.0 で扱おうとした I-6（meta-revisability invariant）の軽量実装。

## 7. Out of Scope (Knowledge Ethos v2.0 復活時に統合する項目)

このヒューリスティックは意図的に最小。次は扱わない:

- Behavioral Ethos Fingerprint の計算（Fingerprint vs Profile 比較は本軽量版にはない）
- Epistemic Justice 違反検出（testimonial / hermeneutical）
- Goodhart 耐性（Fingerprint 最適化対象化の防止）
- HestiaChain merger 時の floor 伝播
- 5 dimensions の完全な記述的把握（Knowledge Ethos v1.1 が担当）

これらが必要になった時点で Knowledge Ethos v2.0 を復活させ、本軽量版を吸収統合する。

## 8. 運用接続

**重要前提**: 本ヒューリスティックの inject 経路は **agent prompt context への inject のみ**。tool 側に自動 filter / gate は実装されていない。下表の接続は agent / 運用者の規律に依存する soft 接続であり、ツール内蔵の hard 強制ではない。tool-level filter 化（dream_propose に Telos check hook を組み込む等）は将来 work。

| 接続先 | どう繋がるか | 強制度 |
|---|---|---|
| dream cycle (`dream_scan`, `dream_propose` 等) | agent が prompt context のヒューリスティックを参照しながら dream_propose を呼び出す。Telos / Boundary check は agent 判断で実施 | soft（agent 規律） |
| `multi_llm_review` | reviewer 不一致時、agent が Heuristic 1 自問 3 を参照して coexistence をデフォルトに判断 | soft（agent 規律） |
| `introspection_check` | Heuristic 2 トリガ 6 で連動。`success` フィールドが false で 3 連続なら agent loop を halt | soft（agent loop 側で counter 維持） |
| `skills_promote` | Heuristic 4 alert と整合する promotion のみ実行。alert 状態は L2 に保存され、agent が promotion 判断時に参照 | soft（agent 規律。tool 内蔵 gate なし） |
| `context_save` | 振り返り集計、alert 状態、bias 検出履歴を L2 に保存 | hard（tool 直接呼び出し） |
| `chain_record` | 振り返り集計の簡易サマリ（alert 種別と件数）を blockchain に追記 | hard（tool 直接呼び出し） |

## 9. Status

- **v0.1 draft (2026-05-05)**: 起草
- **v0.2 (2026-05-05)**: round 1 multi-LLM review (1 APPROVE / 3 REJECT / 1 REVISE) の critical P0 8 件を反映。具体的には: pivot branch 大ゴール候補化（§1.2）、rolling window alert 追加（§3 トリガ 5、§5）、introspection_check 自己完結化（§3 トリガ 6）、halt 許可条件と blocking 区分明示（§4.1, §4.2）、context_save と chain_record 分離（§5、§8）、§8 接続強制度区分追加（soft / hard）。L1 昇格。
- **次工程**: 別 KairosChain instance で masa mode 下に運用。2〜4 週の観察で alert 発火・代替案生成・next-step 提案の妥当性を判定。観察結果は L2 に蓄積し、Knowledge Ethos 更新の input にする。
- **塩漬け中の関連物**: Knowledge Ethos v2.0（フル版ガードレール）、L2 `knowledge_ethos_v2_review_round2_paused_20260505`
