---
name: kairoschain_faq_jp
description: よくある質問とサブツリー統合ガイド
version: 1.0
layer: L1
tags: [documentation, readme, faq, subtree, integration]
readme_order: 6
readme_lang: jp
---

## FAQ

### Q: LLMはL1/L2を自動的に改変しますか？

**A:** はい、LLMはMCPツールを使って自発的に（またはユーザーの依頼で）L1/L2を改変できます。

| レイヤー | LLMによる改変 | 条件 |
|---------|---------------|------|
| **L0** (kairos.rb) | 可能だが厳格 | `evolution_enabled: true` + `approved: true`（人間承認）+ ブロックチェーン記録 |
| **L1** (knowledge/) | 可能 | ハッシュのみブロックチェーン記録、人間承認不要 |
| **L2** (context/) | 自由 | 操作単位の記録なし、承認不要 |

※ `kairos.md` は読み取り専用で、LLMは改変できません。

**StateCommit補足**: 操作単位の記録とは別に、[StateCommit](#q-statecommitとは何ですか監査可能性をどう向上させますか)はコミットポイントで全レイヤー（L2含む）をキャプチャできます。スナップショットはオフチェーン保存され、オンチェーンにはハッシュ参照のみが記録されます。

**使用例:**
- L2: 調査中の仮説を `context_save` で一時保存
- L1: プロジェクトのコーディング規約を `knowledge_update` で永続化
- L0: メタスキルの変更を `skills_evolve` で提案（人間承認必須）

---

### Q: どのレイヤーに知識を保存すべきか、どう判断すればよいですか？

**A:** 組み込みの`layer_placement_guide`知識（L1）を参考にしてください。簡易判断ツリーは以下の通りです：

```
1. Kairos自体のルールや制約を変更するものですか？
   → はい: L0（人間承認必須）
   → いいえ: 次へ

2. 一時的、またはセッション限定のものですか？
   → はい: L2（自由に変更可能、操作単位の記録なし；StateCommitでキャプチャ可能）
   → いいえ: 次へ

3. 複数のセッションで再利用しますか？
   → はい: L1（ハッシュ参照記録）
   → いいえ: L2
```

**基本原則:** 迷ったらL2から始めて、後で昇格させる。

| レイヤー | 目的 | 典型的な内容 |
|----------|------|-------------|
| L0 | Kairosメタルール | 安全性制約、進化ルール |
| L1 | プロジェクト知識 | コーディング規約、アーキテクチャドキュメント |
| L2 | 一時的な作業 | 仮説、セッションノート、実験 |

**昇格パターン:** 知識は成熟するにつれて上位に移動できます: L2 → L1 → L0

詳細なガイダンスは: `knowledge_get name="layer_placement_guide"` を使用してください。

---

### Q: L1知識の健全性をどう維持しますか？L1の肥大化をどう防ぎますか？

**A:** `l1_health_guide`知識（L1）と`skills_audit`ツールを使って定期的なメンテナンスを行います。

**主要な閾値：**

| 条件 | 閾値 | アクション |
|------|------|----------|
| レビュー推奨 | 更新から180日経過 | `skills_audit`チェックを実行 |
| アーカイブ候補 | 更新から270日経過 | アーカイブを検討 |
| 危険なパターン | 検出時 | 即座に更新またはアーカイブ |

**推奨監査スケジュール：**

| 頻度 | コマンド |
|------|---------|
| 月次 | `skills_audit command="check" layer="L1"` |
| 月次 | `skills_audit command="recommend" layer="L1"` |
| 四半期 | `skills_audit command="conflicts" layer="L1"` |
| 問題発生時 | `skills_audit command="dangerous" layer="L1"` |

**セルフチェックリスト（l1_health_guideより）：**

- [ ] **関連性**: この知識はまだ適用可能か？
- [ ] **一意性**: 類似の知識が既に存在しないか？
- [ ] **品質**: 情報は正確で最新か？
- [ ] **安全性**: L0の安全制約に適合しているか？

**アーカイブプロセス：**

```bash
# 知識をレビュー
knowledge_get name="candidate_knowledge"

# 承認付きでアーカイブ
skills_audit command="archive" target="candidate_knowledge" reason="プロジェクト完了" approved=true
```

詳細なガイドラインは: `knowledge_get name="l1_health_guide"` を使用してください。

---

### Q: Persona Assemblyとは何ですか？いつ使うべきですか？

**A:** Persona Assemblyは、レイヤー間で知識を昇格させる際や、知識の健全性を監査する際に、複数の視点から評価を行うオプション機能です。人間の意思決定前に異なる観点を浮き彫りにするのに役立ちます。

**アセンブリモード:**

| モード | 説明 | トークンコスト | ユースケース |
|--------|------|---------------|-------------|
| `oneshot` (デフォルト) | 全ペルソナによる1回評価 | ~500 + 300×N | 日常的な判断、迅速なフィードバック |
| `discussion` | ファシリテーター付きマルチラウンド議論 | ~500 + 300×N×R + 200×R | 重要な決定、深い分析 |

*N = ペルソナ数、R = ラウンド数（デフォルト最大: 3）*

**モード選択の指針:**

| シナリオ | 推奨モード |
|----------|-----------|
| L2 → L1 昇格 | oneshot |
| L1 → L0 昇格 | **discussion** |
| アーカイブ判断 | oneshot |
| 矛盾解消 | **discussion** |
| クイック検証 | oneshot (kairosのみ) |
| 高リスク決定 | discussion (全ペルソナ) |

**利用可能なペルソナ:**

| ペルソナ | 役割 | バイアス |
|---------|------|----------|
| `kairos` | 哲学擁護者 / デフォルトファシリテーター | 監査可能性、制約保持 |
| `conservative` | 安定性の守護者 | より低コミットメントのレイヤーを好む |
| `radical` | イノベーション推進者 | 行動を好み、高リスクも許容 |
| `pragmatic` | コスト対効果分析者 | 実装複雑性 vs 価値 |
| `optimistic` | 機会探索者 | 潜在的利益に焦点 |
| `skeptic` | リスク特定者 | 問題やエッジケースを探す |
| `archivist` | 知識キュレーター | 知識の鮮度、冗長性 |
| `guardian` | 安全性番人 | L0整合性、セキュリティリスク |
| `promoter` | 昇格スカウト | 昇格候補の発見 |

**使用方法:**

```bash
# oneshotモード（デフォルト）- 1回評価
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" personas=["kairos", "conservative", "skeptic"]

# discussionモード - ファシリテーター付きマルチラウンド
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" \
  assembly_mode="discussion" facilitator="kairos" max_rounds=3 consensus_threshold=0.6 \
  personas=["kairos", "conservative", "radical", "skeptic"]

# skills_auditでの使用
skills_audit command="check" with_assembly=true assembly_mode="oneshot"
skills_audit command="check" with_assembly=true assembly_mode="discussion" facilitator="kairos"

# アセンブリなしで直接昇格
skills_promote command="promote" source_name="my_context" from_layer="L2" to_layer="L1" session_id="xxx"
```

**discussionモードのワークフロー:**

```
Round 1: 各ペルソナが立場を表明（SUPPORT/OPPOSE/NEUTRAL）
         ↓
ファシリテーター: 合意/不合意を整理、懸念点を特定
         ↓
Round 2-N: ペルソナが懸念に対応（合意 < 閾値の場合）
         ↓
最終サマリー: 合意状況、推奨、主要解決事項
```

**設定デフォルト（`audit_rules` L0スキルより）:**

```yaml
assembly_defaults:
  mode: "oneshot"           # デフォルトモード
  facilitator: "kairos"     # 議論のまとめ役
  max_rounds: 3             # discussionの最大ラウンド数
  consensus_threshold: 0.6  # 60% = 早期終了
```

**重要:** アセンブリの出力は助言のみです。人間の判断が最終的な権限を持ち続けます（特にL0昇格の場合）。

ペルソナ定義はカスタマイズ可能です: `knowledge/persona_definitions/`

---

### Q: チーム利用の場合、APIへの拡張が必要ですか？

**A:** KairosChainはリモート/チームアクセスのための**Streamable HTTPトランスポート**をサポートしています。チーム利用には以下の選択肢があります：

| 方式 | 追加実装 | 適合規模 |
|------|----------|----------|
| **Git共有** | 不要 | 小規模チーム（2-5人） |
| **SSHトンネリング** | 不要 | LANチーム（2-10人） |
| **Streamable HTTP** | ✅ 利用可能（`--http`フラグ） | 中規模チーム（5-20人） |
| **MCP over SSE** | 不要（Streamable HTTPで代替） | リモート接続が必要な場合 |

**Git共有（最もシンプル）:**
```
# knowledge/, skills/, data/blockchain.json をGitで管理
# 各メンバーがローカルでMCPサーバーを起動
# 変更はGit経由で同期
```

**SSHトンネリング（LANチーム、コード変更不要）:**

同一LAN内のチームでは、SSH経由でリモートMCPサーバーに接続できます。追加実装は不要で、サーバーマシンへのSSHアクセスがあれば利用可能です。

**セットアップ:**

1. 共有マシン（例：`server.local`）でMCPサーバーを準備：
   ```bash
   # サーバーマシン上で
   cd /path/to/KairosChain_mcp_server
   # サーバー準備完了（stdioベース、デーモン不要）
   ```

2. MCPクライアントをSSH経由で接続するよう設定：

   **Cursorの場合（`~/.cursor/mcp.json`）:**
   ```json
   {
     "mcpServers": {
       "kairos-chain": {
         "command": "ssh",
         "args": [
           "-o", "StrictHostKeyChecking=accept-new",
           "user@server.local",
           "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
         ]
       }
     }
   }
   ```

   **Claude Codeの場合:**
   ```bash
   claude mcp add kairos-chain ssh -- -o StrictHostKeyChecking=accept-new user@server.local "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
   ```

3. （オプション）パスワードなしアクセスのためSSH鍵認証を設定：
   ```bash
   # 鍵がなければ生成
   ssh-keygen -t ed25519
   
   # サーバーにコピー
   ssh-copy-id user@server.local
   ```

**SSHトンネリングの利点:**
- コード変更やHTTPサーバー実装が不要
- 既存のSSHインフラと認証を活用
- デフォルトで暗号化通信
- stdioベースのMCPプロトコルをそのまま利用可能

**SSHトンネリングの制限:**
- サーバーマシンへのSSHアクセスが必要
- 各クライアントが新しいサーバープロセスを起動（接続間で状態共有なし）
- 同時書き込みの場合、Gitで`storage/blockchain.json`と`knowledge/`を同期

**Streamable HTTPが適している場合:**
- SSHの到達範囲を超えたリモートアクセス（インターネット向き）
- Bearerトークン認証が必要
- CI/CDや外部システムとの統合
- セットアップの詳細は[オプション：Streamable HTTPトランスポート](#オプションstreamable-httpトランスポートリモートチームアクセス)を参照

---

### Q: チーム運用でkairos.rbやkairos.mdの変更に投票システムは必要ですか？

**A:** チーム規模と要件によります。

**現在の実装（単一承認者モデル）:**
```yaml
require_human_approval: true  # 1人が承認すればOK
```

**チーム運用で必要になる可能性がある機能:**

| 機能 | L0 | L1 | L2 |
|------|----|----|----| 
| 投票システム | 推奨 | オプション | 不要 |
| 定足数（Quorum） | 推奨 | - | - |
| 提案期間 | 推奨 | - | - |
| 拒否権（Veto） | 場合による | - | - |

**将来的に必要なツール（未実装）:**
```
governance_propose    - 変更提案を作成
governance_vote       - 提案に投票（賛成/反対/棄権）
governance_status     - 提案の投票状況を確認
governance_execute    - 閾値を超えた提案を実行
```

**kairos.mdの特殊性:**

`kairos.md`は「憲法」に相当するため、システム外での合意形成（GitHub Discussion等）を推奨します：

1. GitHub Issue / Discussionで提案
2. チーム全員でオフライン議論
3. 全員一致（またはスーパーマジョリティ）で合意
4. 手動でファイルを編集してコミット

---

### Q: ローカルテストの実行方法は？

**A:** 以下のコマンドでテストを実行できます：

```bash
cd KairosChain_mcp_server
ruby test_local.rb
```

テスト内容：
- Layer Registry の動作確認
- 18個のコアMCPツール一覧
- リソースツール（resource_list, resource_read）
- L1 Knowledge の読み書き
- L2 Context の読み書き
- L0 Skills DSL（6スキル）の読み込み

テスト後にアーティファクト（`context/test_session`）が作成されるので、不要なら削除してください：
```bash
rm -rf context/test_session
```

---

### Q: kairos.rbに含まれるメタスキルは何ですか？

**A:** 現在8つのメタスキルが定義されています：

| スキル | 説明 | 改変可能性 |
|--------|------|------------|
| `l0_governance` | L0自己統治ルール | contentのみ可 |
| `core_safety` | 安全性の基盤 | 不可（`deny :all`） |
| `evolution_rules` | 進化ルールの定義 | contentのみ可 |
| `layer_awareness` | レイヤー構造の認識 | contentのみ可 |
| `approval_workflow` | 承認ワークフロー（チェックリスト付き） | contentのみ可 |
| `self_inspection` | 自己検査能力 | contentのみ可 |
| `chain_awareness` | ブロックチェーン認識 | contentのみ可 |
| `audit_rules` | 知識ライフサイクル監査ルール | contentのみ可 |

`l0_governance`スキルは特別な存在です：どのスキルがL0に存在できるかを定義し、自己参照的統治というPure Agent Skillの原則を実装しています。

詳細は `skills/kairos.rb` を参照してください。

---

### Q: L0スキルを変更するにはどうすればいいですか？手順は？

**A:** L0の変更には、人間の監視を伴う厳格な複数ステップの手順が必要です。これは意図的な設計です — L0はKairosChainの「憲法」です。

**前提条件：**
- `skills/config.yml`で`evolution_enabled: true`（手動で設定が必要）
- セッション内の進化回数 < `max_evolutions_per_session`（デフォルト: 3）
- 対象スキルが`immutable_skills`に含まれていない（`core_safety`は変更不可）
- 変更がスキルの`evolve`ブロックで許可されている

**ステップバイステップの手順：**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. 人間: config.ymlでevolution_enabled: trueを手動設定          │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. AI: skills_evolve command="propose" skill_id="..." def="..." │
│    - 構文検証                                                    │
│    - l0_governanceのallowed_skillsチェック                      │
│    - evolveルールチェック                                        │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. 人間: 15項目チェックリストでレビュー（approval_workflow）     │
│    - Traceability（追跡可能性）: 3項目                          │
│    - Consistency（整合性）: 3項目                               │
│    - Scope（範囲）: 3項目                                       │
│    - Authority（権限）: 3項目                                   │
│    - Pure Agent Compliance（Pure準拠）: 3項目                   │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. AI: skills_evolve command="apply" ... approved=true          │
│    - バージョンスナップショット作成                               │
│    - kairos.rb更新                                              │
│    - ブロックチェーンに記録                                       │
│    - Kairos.reload!                                             │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. 検証: skills_dsl_get, chain_history, chain_verify            │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. 人間: evolution_enabled: falseに戻す（推奨）                  │
└─────────────────────────────────────────────────────────────────┘
```

**重要なポイント：**

| 観点 | 説明 |
|------|------|
| **進化の有効化** | 手動で設定が必要（AIはconfig.ymlを変更できない） |
| **承認** | 人間が15項目チェックリストを確認 |
| **記録** | すべての変更がブロックチェーンに記録 |
| **ロールバック** | `skills_rollback`でスナップショットから復元可能 |
| **不変** | `core_safety`は変更不可（`evolve deny :all`） |

**新しいL0スキルタイプを追加する場合：**

完全に新しいメタスキルタイプ（例：`my_new_meta_skill`）を追加するには：

1. まず`l0_governance`を進化させて`allowed_skills`リストに追加
2. 次に`skills_evolve command="add"`で新しいスキルを作成

両方のステップで人間承認とチェックリスト確認が必要です。

**L1/L2は影響を受けません：**

| レイヤー | ツール | 人間承認 | 進化有効化 |
|---------|--------|----------|-----------|
| **L0** | `skills_evolve` | 必要 | 必要 |
| **L1** | `knowledge_update` | 不要 | 不要 |
| **L2** | `context_save` | 不要 | 不要 |

L1とL2は従来通りAIが自由に変更できます。

---

### Q: L0 Auto-Checkとは何ですか？15項目チェックリストをどう助けますか？

**A:** L0 Auto-Checkは、L0変更前に**機械的なチェックを自動検証**する機能で、人間のレビュー負担を軽減します。

**仕組み：**

`skills_evolve command="propose"`を実行すると、システムは`approval_workflow`スキル（L0の一部）で定義されたチェックを自動実行します。これによりチェック基準が自己参照的に保たれます（Pure Agent Skill準拠）。

**チェックカテゴリ：**

| カテゴリ | タイプ | 項目数 | 説明 |
|---------|-------|-------|------|
| **Consistency** | 機械的 | 4 | allowed_skills内、非不変、構文有効、evolveルール |
| **Authority** | 機械的 | 2 | evolution_enabled、セッション制限内 |
| **Scope** | 機械的 | 1 | ロールバック可能 |
| **Traceability** | 人間 | 2 | 理由記載、L0ルールへの追跡可能 |
| **Pure Compliance** | 人間 | 2 | 外部依存なし、LLM非依存 |

**出力例：**

```
📋 L0 AUTO-CHECK REPORT
============================================================

✅ All 7 mechanical checks PASSED. 3 items require human verification.

### Consistency
✅ Skill in allowed_skills
   evolution_rules is in allowed_skills
✅ Skill not immutable
   evolution_rules is not immutable
✅ Ruby syntax valid
   Syntax is valid
✅ Evolve rules permit change
   Skill's evolve rules allow modification

### Authority
✅ Evolution enabled
   evolution_enabled: true in config
✅ Within session limit
   1/3 evolutions used

### Scope
✅ Rollback possible
   Version snapshots directory exists

### Traceability
✅ Reason documented
   Reason: Updating for clarity
⚠️ Traceable to L0 rule
   ⚠️ HUMAN CHECK: Verify this change can be traced to an explicit L0 rule.

### Pure Compliance
⚠️ No external dependencies
   ⚠️ HUMAN CHECK: Verify the change doesn't introduce external dependencies.
⚠️ LLM-independent semantics
   ⚠️ HUMAN CHECK: Would different LLMs interpret this change the same way?

------------------------------------------------------------
⚠️  3 item(s) require HUMAN verification.
    Review the ⚠️ items above before approving.
------------------------------------------------------------
```

**メリット：**

| Auto-Checkなし | Auto-Checkあり |
|---------------|---------------|
| 人間が15項目すべてを確認 | AIが7項目の機械的チェックを実施 |
| 構文エラーを見落としやすい | 構文が自動検証される |
| l0_governanceを手動チェック | allowed_skillsを自動チェック |
| 構造化されたレポートなし | 明確なパス/フェイルレポート |

**使用方法：**

```bash
# 追跡可能性のために理由を含める
skills_evolve command="propose" skill_id="evolution_rules" definition="..." reason="進化ワークフローを明確化"
```

**Pure Agent Skill準拠：**

チェックロジックは**L0内**（`approval_workflow`スキルのbehaviorブロック内）に定義されており、外部コードではありません。これはL0変更をチェックする基準自体がL0の一部であることを意味し、自己参照的整合性を維持しています。

---

### Q: KairosChainはどのような判断で自分のスキルを進化させようとしますか？そのためのメタスキルはありますか？

**A:** **KairosChainは意図的に「いつ進化すべきか」を判断するロジックを含んでいません。** この判断は人間側（または人間と対話するAIクライアント）に委ねられています。

**現在の設計における責任分担：**

| 責任 | 担当者 | 詳細 |
|------|--------|------|
| **進化の判断（いつ・何を）** | 人間 / AIクライアント | KairosChainの外側 |
| **進化の制約（許可/拒否）** | KairosChain | 内部ルールで検証 |
| **進化の承認** | 人間 | 明示的な `approved: true` |
| **進化の記録** | KairosChain | ブロックチェーンに自動記録 |

**既に実装されているもの：**
- ✅ 進化の制約（`SafeEvolver`）
- ✅ ワークフロー（propose → review → apply）
- ✅ レイヤー構造（L0/L1/L2）
- ✅ 8つのメタスキル定義

**実装されていないもの（設計上意図的）：**
- ❌ 「いつ進化すべきか」の判断ロジック
- ❌ 能力不足の自己検知
- ❌ 学習機会の認識
- ❌ 進化トリガー条件

**設計の根拠：**

これは意図的なものです。`kairos.md`（PHILOSOPHY-020 Minimum-Nomic）より：

| アプローチ | 問題 |
|-----------|------|
| 完全固定ルール | 適応不可、システムが陳腐化 |
| **無制限の自己改変** | **カオス、説明責任なし** |

「無制限の自己改変」を避けるため、KairosChainは進化のトリガーを意図的に外部アクターに委ねています。KairosChainは**ゲートキーパー**と**記録係**として機能し、自律的な自己改変者ではありません。

**将来の拡張可能性：**

「いつ進化すべきか」のメタスキルを追加したい場合は、以下のように定義できます：

```ruby
skill :evolution_trigger do
  version "1.0"
  title "Evolution Trigger Logic"
  
  evolve do
    allow :content      # トリガー条件は変更可能
    deny :behavior      # 判断ロジック自体は固定
  end
  
  content <<~MD
    ## 進化トリガー条件
    
    1. 同じエラーパターンが3回以上発生した場合
    2. ユーザーが明示的に「これを覚えて」と言った場合
    3. 新しいドメイン知識が提供された場合
    → L1への保存を提案
  MD
end
```

ただし、そのようなメタスキルを追加しても、**最終的な承認は人間が行うべきです**。これはKairosChainの安全設計の核心部分です。

---

### Q: スキル-ツール統一とは何ですか？Rubyファイルを編集せずにMCPツールを追加できますか？

**A:** はい！`kairos.rb`のスキルは`tool`ブロックでMCPツールを定義できるようになりました。これによりL0-Bでスキルとツールが統一されます。

**仕組み：**

```ruby
# kairos.rb内
skill :my_custom_tool do
  version "1.0"
  title "My Custom Tool"
  
  # 従来のbehavior（スキル内省用）
  behavior do
    { capability: "..." }
  end
  
  # ツール定義（MCPツールとして公開）
  tool do
    name "my_custom_tool"
    description "便利な処理を行う"
    
    input do
      property :arg, type: "string", description: "引数"
      required :arg
    end
    
    execute do |args|
      # ツール実装
      { result: process(args["arg"]) }
    end
  end
end
```

**設定で有効化：**

```yaml
# skills/config.yml
skill_tools_enabled: true   # デフォルト: false
```

**重要なポイント：**
- デフォルトは**無効**（保守的）
- ツールの追加・変更には`kairos.rb`の編集が必要（L0制約が適用）
- 変更には人間の承認が必要（`approved: true`）
- すべての変更はブロックチェーンに記録
- Minimum-Nomicに合致：「変更できるが、記録される」

**なぜこれほど厳格なのか？**

L0（`kairos.rb`）は意図的に**三重の保護**でロックされています：

| 保護 | 設定 | 効果 |
|------|------|------|
| 1 | `evolution_enabled: false` | kairos.rbの変更をブロック |
| 2 | `require_human_approval: true` | 明示的な人間の承認が必要 |
| 3 | `skill_tools_enabled: false` | スキルがツールとして登録されない |

**重要：** `config.yml`を変更するMCPツールは存在しません。LLMに「この設定を変更して」と頼んでも、LLMには変更する手段がありません。人間が手動で`config.yml`を編集する必要があります。

これは設計上の意図です：L0は法的類推における「憲法・法律」に相当し、頻繁に変更されるべきではありません。頻繁なツール追加が必要な場合は、以下を検討してください：

- **現在の制限**：`tool`ブロックはL0のみでサポート
- **将来の可能性**：L1でのツール定義サポート（軽量な制約、人間承認不要、ハッシュのみ記録）

ほとんどのユースケースでは、**L0ツールを頻繁に変更する必要はありません**。厳格なロックはシステムの整合性を確保します。

---

### Q: kairos.rb経由でツールを追加する場合と、tools/ディレクトリに直接追加する場合の違いは？

**A:** KairosChainにMCPツールを追加する方法は2つあります：

1. **`kairos.rb`経由（L0）**: スキル定義内で`tool`ブロックを使用
2. **`tools/`ディレクトリ経由**: `lib/kairos_mcp/tools/`にRubyファイルを直接追加

**機能的な同等性:** どちらの方法もLLMから呼び出し可能なMCPツールとして登録されます。

**主な違い:**

| 観点 | `kairos.rb` (L0) | `tools/`ディレクトリ |
|------|------------------|---------------------|
| 追加方法 | `skills_evolve`ツール経由 | 手動でファイル追加 |
| 人間承認 | **必須** | 不要 |
| ブロックチェーン記録 | **あり**（完全記録） | なし |
| 有効化条件 | `skill_tools_enabled: true` | 常に有効 |
| KairosChain管理下 | **はい** | いいえ |

**重要:** `tools/`ディレクトリへの直接追加は**KairosChain経由ではありません**。通常のコード変更（gitで追跡されるが、KairosChainのブロックチェーンでは監査されない）です。

**設計上の意図:**

- **コアインフラ**（`tools/`）: KairosChain自体が動作するために必要なツール。頻繁に変更されるべきではない
- **拡張ツール**（`kairos.rb`）: ユーザーが追加するカスタムツール。変更履歴を監査したい場合に使用

つまり：
- `kairos.rb`経由: 「厳格だが監査可能」
- `tools/`経由: 「自由だが監査対象外」

**将来の検討事項:** L1でのツール定義サポート（軽量な制約、ハッシュのみ記録）が追加される可能性があります。L0の厳格な制御は不要だが便利なツールの追加に適しています。

---

### Q: KairosChainはLLMに対してスキル作成を自発的に推奨すべきですか？

**A:** **いいえ。KairosChainは「記録と制約」に専念すべきであり、「いつ学ぶべきか」を推奨すべきではありません。** スキル作成を推奨するロジックは、LLM/AIエージェント側（Cursor Rules、system_promptなど）に委ねるべきです。

**なぜこの分離が重要か？**

| 観点 | KairosChain側で実装 | LLM/エージェント側に委譲 |
|------|---------------------|------------------------|
| **Minimum-Nomic原則** | 「変更は稀で高コストであるべき」 | エージェントが学習の価値を判断 |
| **責任の分離** | KairosChain = ゲートキーパー＆記録係 | LLM = 学習トリガーの決定者 |
| **カスタマイズ性** | 全ユーザーに同じ制約 | ユーザーごとに異なるエージェント設定が可能 |
| **プロンプト注入リスク** | 推奨ロジック自体が攻撃対象に | エージェント側で防御可能 |

**KairosChainの役割：**
- ✅ スキル変更を不変的に記録
- ✅ 進化の制約を強制（承認、レイヤールール）
- ✅ スキル管理のためのツールを提供
- ❌ 「いつ」「何を」学ぶかを決定

**自発的なスキル推奨の推奨アプローチ：**

AIエージェント（Cursor Rules、Claude system_promptなど）に以下を設定してください：

```markdown
# エージェント学習ルール

## スキル作成を推奨するタイミング
- 複数回の試行を必要とした問題を解決した後
- ユーザーが「いつも忘れる...」や「これはよくあるパターン」と言った場合
- 似たようなコードパターンが繰り返し生成された場合

## 推奨フォーマット
「[パターン]に気づきました。これをKairosChainスキルとして保存しますか？」

## KairosChainツールの使用：
- L2: 一時的な仮説には `context_save`
- L1: プロジェクト知識には `knowledge_update`（ハッシュのみ記録）
- L0: メタスキルには `skills_evolve`（人間承認が必要）
```

これにより、KairosChainは**中立的なインフラストラクチャ**として維持され、各チーム/ユーザーはエージェントレベルで独自の学習ポリシーを定義できます。

**スキル昇格トリガー（同じ原則が適用）：**

KairosChainはスキル昇格（L2→L1→L0）も自発的に提案しません。AIエージェントに昇格を提案させるよう設定してください：

```markdown
# スキル昇格ルール（上記に追加）

## L2 → L1 昇格を提案するタイミング
- 同じコンテキストが3回以上セッションをまたいで参照された
- ユーザーが「これは便利」「これを残したい」と言った
- 仮説が実際の使用で検証された

## L1 → L0 昇格を提案するタイミング
- 知識がKairosChain自体の動作を規定する
- 成熟した安定パターンで、頻繁に変更すべきでない
- チーム合意が得られた（共有インスタンスの場合）

## 昇格提案フォーマット
「この知識は複数のセッションで有用でした。
L2からL1に昇格して永続化しますか？」

## KairosChainツールの使用：
- `skills_promote command="analyze"` - Persona Assemblyで議論
- `skills_promote command="promote"` - 直接昇格
```

---

### Q: スキルやナレッジ同士で矛盾が生じたらどうなりますか？

**A:** 現状、KairosChainはスキル/ナレッジ間の**矛盾を自動検出する機能を持っていません**。これは設計ペーパーでも認識されている制限事項です。

**なぜ自動検出しないのか？**

KairosChainは意図的に「判断」を外部（LLM/人間）に委ねています：

| KairosChainの責務 | 外部に委ねる |
|------------------|-------------|
| 変更を記録する | 何を保存すべきか判断する |
| 制約を強制する | 内容の妥当性を判断する |
| 履歴を保持する | 矛盾を解決する |

**矛盾が生じた場合の現在のアプローチ：**

1. **暗黙のレイヤー優先順位**: `L0（メタルール）> L1（プロジェクト知識）> L2（一時コンテキスト）` — より低いレイヤーが優先
2. **LLMの解釈**: 複数のスキルが参照された場合、LLMが文脈に応じて解釈・調停
3. **人間による解決**: 重要な矛盾は、人間が関連スキルを更新して解決

**将来の可能性：**

矛盾検出をL1ナレッジまたはL0スキルとして追加することは可能です：

```markdown
# 矛盾検出スキル（例）

## 検出ルール
- 同じトピックで異なる推奨事項
- 相反するconstraint定義
- 循環依存

## 解決フロー
1. 検出時にユーザーに警告
2. Persona Assemblyで議論を生成
3. 人間が最終判断
```

ただし、「何を矛盾とみなすか」自体が哲学的な問題であり、KairosChainの現設計は意図的にそこに踏み込んでいません。

---

### Q: StateCommitとは何ですか？監査可能性をどう向上させますか？

**A:** StateCommitは、特定の「コミットポイント」で全レイヤー（L0/L1/L2）のスナップショットを作成し、監査可能性を向上させる機能です。個別のスキル変更記録とは異なり、StateCommitはある時点での**システム全体の状態**をキャプチャします。

**なぜStateCommitか？**

| 既存の記録 | StateCommit |
|----------|-------------|
| L0: 完全なブロックチェーントランザクション | 全レイヤーをまとめてキャプチャ |
| L1: ハッシュ参照のみ | レイヤー間の関係を含む |
| L2: 記録なし | コミット理由で「なぜ」を示す |

**ストレージ戦略:**
- **オフチェーン**: 完全なスナップショットJSONファイルを`storage/snapshots/`に保存
- **オンチェーン**: ハッシュ参照とサマリーのみ（ブロックチェーン肥大化防止）

**コミットタイプ:**

| タイプ | トリガー | 理由 |
|--------|---------|------|
| `explicit` | ユーザーが`state_commit`を呼び出し | 必須（ユーザー提供） |
| `auto` | システムがトリガー条件を検出 | 自動生成 |

**自動コミットトリガー（OR条件）:**
- L0変更を検出
- 昇格（L2→L1またはL1→L0）が発生
- 降格/アーカイブが発生
- セッション終了（MCPサーバー停止時）
- L1変更の閾値（デフォルト: 5）
- 合計変更の閾値（デフォルト: 10）

**AND条件（空コミット防止）:**
マニフェストハッシュが前回のコミットと異なる場合のみ自動コミットが実行されます。

**設定（`skills/config.yml`）:**

```yaml
state_commit:
  enabled: true
  snapshot_dir: "storage/snapshots"
  max_snapshots: 100

  auto_commit:
    enabled: true
    skip_if_no_changes: true  # AND条件

    on_events:
      l0_change: true
      promotion: true
      demotion: true
      session_end: true

    change_threshold:
      enabled: true
      l1_changes: 5
      total_changes: 10
```

**使用方法:**

```bash
# 明示的コミットを作成
state_commit reason="機能実装完了"

# 現在の状態を確認
state_status

# コミット履歴を表示
state_history

# 特定のコミットの詳細を表示
state_history hash="abc123"
```

---

### Q: スキルが溜まりすぎたらどうなりますか？クリーンアップの仕組みはありますか？

**A:** KairosChainは `skills_audit` ツールで全レイヤーの知識ライフサイクル管理を提供しています。

**`skills_audit` ツールの機能：**

| コマンド | 説明 |
|---------|------|
| `check` | L0/L1/L2レイヤー全体の健全性チェック |
| `stale` | 古くなった項目を検出（レイヤー別閾値） |
| `conflicts` | 知識間の潜在的な矛盾を検出 |
| `dangerous` | L0安全性と矛盾するパターンを検出 |
| `recommend` | 昇格/アーカイブの推奨を取得 |
| `archive` | L1知識をアーカイブ（人間の承認が必要） |
| `unarchive` | アーカイブから復元（人間の承認が必要） |

**レイヤー別の古さ閾値：**

| レイヤー | 閾値 | 理由 |
|---------|------|------|
| L0 | 日付チェックなし | 安定性は機能であり古さではない |
| L1 | 180日 | プロジェクト知識は定期的にレビューすべき |
| L2 | 14日 | 一時コンテキストはクリーンアップすべき |

**使用例：**

```bash
# 全レイヤーの健全性チェック
skills_audit command="check" layer="all"

# 古いL1知識を検出
skills_audit command="stale" layer="L1"

# アーカイブと昇格の推奨を取得
skills_audit command="recommend"

# Persona Assemblyで詳細分析
skills_audit command="check" with_assembly=true assembly_mode="discussion"

# 古い知識をアーカイブ（人間の承認が必要）
skills_audit command="archive" target="old_knowledge" reason="1年以上未使用" approved=true
```

**アーカイブの仕組み：**

- アーカイブされた知識は `knowledge/.archived/` ディレクトリに移動
- アーカイブメタデータ（理由、日付、後継）は `.archive_meta.yml` に保存
- アーカイブされた項目は通常の検索から除外されるが復元可能
- すべてのアーカイブ/復元操作はブロックチェーンに記録

**人間の監視：**

アーカイブと復元操作には明示的な人間の承認（`approved: true`）が必要です。このルールはL0の `audit_rules` スキルで定義されており、それ自体も変更可能（L0-B）です。

---

### Q: スキルが間違っていたり古くなっていたりした場合、どうやって修正しますか？

**A:** KairosChainは問題のある知識を特定・修正するための複数のツールを提供しています。

**ステップ1: `skills_audit`で問題を特定**

```bash
# 危険なパターンをチェック（安全性の矛盾）
skills_audit command="dangerous" layer="L1"

# 古い知識をチェック
skills_audit command="stale" layer="L1"

# Persona Assemblyで詳細な健全性チェック
skills_audit command="check" with_assembly=true
```

**ステップ2: 知識ツールでレビュー・修正**

| ツール | 用途 |
|--------|------|
| `knowledge_get` | スキル内容を取得してレビュー |
| `knowledge_update command="update"` | スキルを修正（ブロックチェーンに記録） |
| `skills_audit command="archive"` | 廃止されたものをアーカイブ（人間の承認が必要） |

**修正ワークフロー：**

```
1. ユーザー：「その回答おかしい。参照したスキルを見せて」
2. LLM：knowledge_get name="skill_name" を呼び出し
3. ユーザー：「Xについての部分が古い。直して」
4. LLM：修正内容を提案
5. ユーザー：変更を承認
6. LLM：knowledge_update command="update" content="..." reason="ユーザーフィードバック: 古い情報"
```

**廃止された知識の場合（削除ではなくアーカイブ）：**

```bash
# 廃止された知識をアーカイブ（履歴を保持、アクティブ検索から除外）
skills_audit command="archive" target="outdated_skill" reason="new_skillに置き換え" approved=true

# 後で必要になった場合、アーカイブから復元
skills_audit command="unarchive" target="outdated_skill" reason="まだ関連性あり" approved=true
```

**危険パターンの検出：**

`skills_audit command="dangerous"` は以下をチェックします：
- 安全チェックのバイパスを示唆する言葉
- ハードコードされた認証情報やAPIキー
- L0の `core_safety` と矛盾するパターン

**積極的なメンテナンス：**

AIエージェント（Cursor Rules / system_prompt）に定期的な監査を推奨するよう設定してください：

```markdown
# スキル品質ルール

## 定期監査
- 月次または問題発生時に `skills_audit command="check"` を実行
- `skills_audit command="recommend"` の推奨をレビュー

## ユーザーが問題を報告した場合
1. `skills_audit command="dangerous"` で安全性の問題をチェック
2. `knowledge_get` で特定のスキルをレビュー
3. `knowledge_update` で修正、または廃止されていればアーカイブ
```

---

### Q: ファイルベースストレージとSQLiteの違いは何ですか？

**A:** KairosChainは2種類のストレージバックエンドをサポートしています：

| 観点 | ファイルベース（デフォルト） | SQLite |
|------|----------------------------|--------|
| 設定 | 不要 | gemインストール + config変更 |
| 同時アクセス | 限定的 | WALモードで改善 |
| 人間可読性 | 直接JSONを確認可能 | エクスポートが必要 |
| バックアップ | ファイルコピー | .dbファイルコピー |
| 適合規模 | 個人 | 小規模チーム（2-10人） |

**移行は簡単：**

1. `gem install sqlite3`
2. config.ymlで`backend: sqlite`に変更
3. `Importer.rebuild_from_files`で移行
4. サーバー再起動

詳細は「オプション：SQLiteストレージバックエンド」セクションを参照してください。

---

### Q: Pure Agent Skillとは何ですか？なぜ重要ですか？

**A:** Pure Agent Skillは、L0の意味論的自己完結性を保証する設計原則です。根本的な問いに答えます：**AIシステムは外部依存なしに自身の進化をどう統治できるか？**

**核心原則：**

> L0を変更するためのすべてのルール、基準、正当化は、L0自身の中に明示的に記述されていなければならない。

**この文脈での「Pure」の意味：**

Pureは以下を意味**しません**：
- 副作用の完全な不在
- バイトレベルで同一の出力

Pureは以下を**意味します**：
- スキルの意味がどのLLMが解釈するかで変わらない
- 意味が承認者によって変わらない
- 意味が実行履歴や時間に依存しない

**KairosChainでの実装：**

| 以前 | 現在 |
|------|------|
| `config.yml`が許可されるL0スキルを定義（外部） | `l0_governance`スキルがこれを定義（自己参照的） |
| 承認基準が暗黙的 | `approval_workflow`に明示的チェックリスト |
| L0の認識なしに変更が可能 | L0が自身のルールを通じて自己統治 |

**`l0_governance`スキル：**

```ruby
skill :l0_governance do
  behavior do
    {
      allowed_skills: [:core_safety, :l0_governance, ...],
      immutable_skills: [:core_safety],
      purity_requirements: { all_criteria_in_l0: true, ... }
    }
  end
end
```

これにより「何がL0に入れるか」がL0自身の一部となり、外部設定ではなくなります。

**理論的限界（ゲーデル的）：**

完全な自己完結は理論的に不可能です。以下の理由により：

1. **停止問題**：変更がすべての基準を満たすかを機械的に常に検証できない
2. **メタレベル依存**：L0ルールの解釈者（コード/LLM）はL0の外部に存在
3. **ブートストラップ**：最初のL0は外部から作成されなければならない

KairosChainはこれらの限界を認識しつつ、**十分なPurity**を目指します：

> 独立したレビューアがL0の文書化されたルールのみを使用して、任意のL0変更の正当化を再構築できるなら、L0は十分にPureである。

**実践的なメリット：**

- **監査可能性**：すべての統治基準が一箇所に
- **ドリフト耐性**：統治を誤って壊しにくい
- **明示的な承認基準**：人間のレビューアにチェックリスト
- **自己文書化**：L0が自身を説明する

完全な仕様は `skills/kairos.md` のセクション [SPEC-010] と [SPEC-020] を参照してください。

---

### Q: なぜKairosChainはRuby、特にDSLとASTを使うのですか？

**A:** KairosChainがRuby DSL/ASTを選択したのは偶然ではなく、自己改変AIシステムにとって本質的な選択です。自己言及的なスキルシステムは、以下の3つの制約を同時に満たす必要があります：

| 要件 | 説明 | Rubyでの実現 |
|------|------|-------------|
| **静的解析可能性** | 実行前のセキュリティ検証 | `RubyVM::AbstractSyntaxTree`（標準ライブラリ） |
| **実行時修正可能性** | 運用中にスキルを追加・修正 | `define_method`、`class_eval`、オープンクラス |
| **人間可読性** | ドメインエキスパートが読める仕様 | 自然言語に近いDSL構文 |

**なぜこの3つが自己参照に重要か：**

KairosChainは**スキルがスキル自体によって制約される**という独自の自己言及構造を実装しています。例えば、`evolution_rules`スキルには以下が含まれます：

```ruby
evolve do
  allow :content
  deny :guarantees, :evolve, :behavior
end
```

これは「進化に関するルールは、それ自体を進化させることができない」という意味です。このブートストラップ制約を実現するには：
1. ルール定義を**パース**（AST経由の静的解析）
2. 制約を実行時に**評価**（メタプログラミング）
3. ルールの意味を**理解**（人間可読なDSL）

が必要です。

**他の言語との比較：**

| 観点 | Lisp/Clojure | Ruby | Python | JavaScript |
|------|-------------|------|--------|------------|
| **ホモイコニシティ（コード=データ）** | ○ 完全 | × なし | × なし | × なし |
| **人間可読性** | △ S式は読みにくい | ○ 自然 | △ 括弧必須 | △ 構文制約 |
| **標準ライブラリのASTツール** | × 不要だが監査困難 | ○ 完備 | △ 限定的 | △ 外部依存 |
| **DSL表現力** | ○ | ○ | △ | △ |
| **本番エコシステム** | △ | ○ 実績あり（Rails, RSpec） | ○ | ○ |

**理論的に最適:** Lisp/Clojure（ホモイコニシティにより自己改変が自然）  
**実用的に最適:** **Ruby**（可読性 + 解析可能性 + 進化可能性のバランス）

**決定的な強み — 分離可能性：**

KairosChainの自己言及システムでは、**定義**、**解析**、**実行**の分離が重要です：

```ruby
# 1. 定義：人間が読める
skill :evolution_rules do
  evolve { deny :evolve }  # 自己制約
end

# 2. 解析：実行前に検証
RubyVM::AbstractSyntaxTree.parse(definition)  # 静的解析

# 3. 実行：制約を評価
skill.evolution_rules.can_evolve?(:evolve)  # => false
```

Lispではコード=データなので、「解析」と「実行」の境界が曖昧になります。これは自由度は高いですが、**監査可能性**を実現するには追加の仕組みが必要です。

**結論:** KairosChainの目的が「AIスキルの監査可能な進化」である以上、Rubyは**実用的な最適解**です。唯一の正解ではありませんが、3つの制約を同時に満たす現実的な選択です。

---

### Q: ローカルスキルとKairosChainの違いは何ですか？

**A:** AIエージェントエディタ（Cursor、Claude Code、Antigravityなど）は通常、ローカルのスキル/ルール機構を提供しています。KairosChainとの比較は以下の通りです：

**ローカルスキル（例：`.cursor/skills/`、`CLAUDE.md`、エージェントルール）**

| 利点 | 欠点 |
|------|------|
| シンプル — ファイルを配置するだけで即利用可能 | 変更履歴なし — 誰が/いつ/なぜ変更したか追跡不可 |
| 高速 — ファイル直接読み込み、MCPオーバーヘッドなし | 自由すぎる — 意図しない改変が発生しうる |
| IDE標準統合 | レイヤー概念なし — 一時的な仮説と永続的な知識が混在 |
| 標準フォーマット（SKILL.md等） | 自己参照不可 — AIが自身のスキルを検査・説明できない |

**KairosChain（MCPサーバー）**

| 利点 | 欠点 |
|------|------|
| **監査可能性** — すべての変更がブロックチェーンに記録 | MCPオーバーヘッド — 若干のレイテンシ |
| **レイヤー構造** — L0（メタルール）/ L1（プロジェクト知識）/ L2（一時コンテキスト） | 学習コスト — レイヤーとツールの理解が必要 |
| **承認ワークフロー** — L0変更には人間の承認が必要 | セットアップ — MCPサーバーの設定が必要 |
| **自己参照** — AIがスキルを検査・説明・進化させられる | 複雑性 — シンプルな用途には過剰な場合がある |
| **セマンティック検索** — RAG対応で意味ベースの検索が可能 | |
| **StateCommit** — 任意の時点でシステム全体のスナップショット取得可能 | |
| **ライフサイクル管理** — `skills_audit`で古い知識の検出・アーカイブ | |

**使い分けの指針：**

| シナリオ | 推奨 |
|----------|------|
| 個人の小規模プロジェクト | ローカルスキル |
| 監査・説明責任が必要 | KairosChain |
| AIの能力進化を記録したい | KairosChain |
| チームでの知識共有 | KairosChain（特にSQLiteバックエンド） |
| 素早いプロトタイピング | ローカルスキル → 成熟したらKairosChainに移行 |

**本質的な違い：**

- **ローカルスキル**: 「便利なドキュメント」として機能
- **KairosChain**: 「監査可能なAI能力進化の台帳」として機能

KairosChainの哲学：

> *「KairosChainは『この結果は正しいか？』ではなく『この知性はどのように形成されたか？』に答えます」*

単にスキルを使うだけならローカルスキルで十分ですが、**AIがどのように学び、進化してきたかを説明できる必要がある**場合はKairosChainが適しています。

**ハイブリッドアプローチ：**

両方を同時に使用することも可能です：
- ローカルスキル：素早い、非公式な知識用
- KairosChain：監査証跡が必要な知識用

KairosChainはローカルスキルを置き換えるものではありません。必要な場合に監査可能性とガバナンスの追加レイヤーを提供するものです。

**読み取り互換性：L1知識をClaude Code Skillsとして使用**

KairosChainのL1知識ファイルはYAML frontmatter + Markdown形式を使用しており、Claude Code Skills形式と互換性があります。Claude Codeは未知のfrontmatterフィールド（`version`、`layer`、`tags`）を無視するため、L1ファイルはそのまま読み取れます。

L1知識をClaude Code Skillsとして使用するには、シンボリックリンクを作成します：

```bash
# 単一の知識項目
mkdir -p ~/.claude/skills/layer-placement-guide
ln -s /path/to/.kairos/knowledge/layer_placement_guide/layer_placement_guide.md \
      ~/.claude/skills/layer-placement-guide/SKILL.md

# またはプロジェクトの知識ディレクトリ全体をリンク
ln -s /path/to/.kairos/knowledge ~/.claude/skills/kairos-knowledge
```

これは**読み取り専用の互換性**を提供します。Claude CodeがL1知識を参照できますが、すべての変更はKairosChainの`knowledge_update`ツール経由で行い、ブロックチェーンの監査証跡を維持する必要があります。直接のファイル編集は監査メカニズムをバイパスします。

KairosChainをインストールしていないユーザーとGitHub経由で成熟したL1知識を共有する場合に特に有用です。

---

## サブツリー統合ガイド

KairosChain_2026は`git subtree`を使用して他のプロジェクトに組み込むことができるよう設計されています。これにより各プロジェクトで以下が可能になります：

- 上流のKairosChain_2026リポジトリからフレームワーク更新を受信
- プロジェクト固有の知識（L1）をローカルに蓄積
- 追加のクローン手順なしで、すべてを単一リポジトリに保持

> **Gem方式 vs Subtree方式:** KairosChainをgem（`gem install kairos-chain`）でインストールした場合、サブツリーの設定は**不要**です。gem方式とサブツリー方式は独立したインストール方法です。サブツリー方式は、プロジェクトリポジトリにソースコード全体を組み込みたいユーザー向けです。gem方式については[インストール](#インストールgemまたはリポジトリ)セクションを参照してください。

### なぜサブツリー（サブモジュールではなく）

| 観点 | subtree | submodule |
|------|---------|-----------|
| ローカルファイル追加 | 親リポジトリで自然に管理 | サブモジュール内では複雑 |
| チームメンバーの`git clone` | そのまま動く（全ファイル含む） | `git submodule init && update`が必要 |
| CI/CD | 特別な設定不要 | サブモジュール初期化ステップが必要 |
| 知識の蓄積 | 親リポジトリに直接コミット | リポジトリ間の管理が煩雑 |
| 意図しない上流へのプッシュ | 明示的な`subtree push`がなければ安全 | 誤ったリモートにプッシュしやすい |

### KairosChainレイヤーとの連携

```
KairosChain_2026（上流）              YourProject（親リポジトリ）
┌──────────────────────────┐          ┌─────────────────────────────────┐
│ L0: フレームワークコード  │ subtree  │ server/                         │
│ L0: メタスキル            │ --pull-> │   KairosChain_mcp_server/       │
│ L1: 汎用テンプレート      │          │     knowledge/                  │
│   example_knowledge/     │          │       example_knowledge/ ← 同期 │
│   persona_definitions/   │          │       persona_definitions/← 同期│
│                          │          │       your_project/   ← ローカル│
│                          │          │       your_tools/     ← ローカル│
│                          │          │     context/          ← L2     │
└──────────────────────────┘          └─────────────────────────────────┘
```

| レイヤー | 場所 | 管理方法 |
|---------|------|---------|
| L0（メタスキル、フレームワーク） | 上流KairosChain_2026 | `subtree pull`で全プロジェクトに同期 |
| L1（プロジェクト知識） | 各プロジェクトの`knowledge/` | 親リポジトリにのみコミット |
| L2（セッションコンテキスト） | `context/` | 一時的、gitignore対象 |

### セットアップ：新しいプロジェクトにKairosChainを追加

**ステップ1: サブツリーを追加**

```bash
git subtree add --prefix=server https://github.com/masaomi/KairosChain_2026 main --squash
```

**ステップ2: リモートを登録（利便性のため）**

```bash
git remote add mcp_server https://github.com/masaomi/KairosChain_2026
```

**ステップ3: .gitignoreを設定**

`server/.gitignore`に以下を追加：

```gitignore
# Bundler
KairosChain_mcp_server/Gemfile.lock
KairosChain_mcp_server/.bundle/
KairosChain_mcp_server/vendor/

# L2セッションコンテキスト（一時的）
KairosChain_mcp_server/context/

# ベクトル検索インデックス（自動生成）
KairosChain_mcp_server/storage/embeddings/**/*.ann
KairosChain_mcp_server/storage/embeddings/**/*.json
!KairosChain_mcp_server/storage/embeddings/**/.gitkeep

# アクションログ
KairosChain_mcp_server/skills/action_log.jsonl
```

### 重要：サブツリー使用時のデータディレクトリ設定

gem化アップデート以降、KairosChainは`KairosMcp.data_dir`を通じてデータパスを解決するようになりました。デフォルトではカレントディレクトリの`.kairos/`を参照します。サブツリー方式で運用している場合、**必ず`--data-dir`でサブツリー内の既存データの場所を指定**してください。指定しないと、新しい空の`.kairos/`ディレクトリが作成され、既存の`skills/`、`knowledge/`、`storage/`のデータが参照されません。

**Cursor IDE（`mcp.json`）：**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

**Claude Code（`.mcp.json`）：**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

環境変数を使用する方法もあります：

```bash
export KAIROS_DATA_DIR=server/KairosChain_mcp_server
```

> **注意：** 以前に`--data-dir`を指定せずに実行し、`.kairos/`ディレクトリが自動生成されてしまった場合は、安全に削除できます。実際のデータは`server/KairosChain_mcp_server/`内にそのまま残っています。

### 日常の操作

**上流の更新をプル：**

```bash
git subtree pull --prefix=server mcp_server main --squash
```

- 上流のファイルが更新/マージされる
- ローカルに追加したファイル（プロジェクト知識）は影響を**受けない**
- ローカルと上流の両方に異なる内容のファイルが存在する場合、通常のマージコンフリクトが発生 — 通常通り解決

**プロジェクト固有の知識をコミット：**

```bash
# MCPサーバーが作成した知識ファイルは未追跡として表示される
git add server/KairosChain_mcp_server/knowledge/your_project/
git add server/KairosChain_mcp_server/storage/blockchain.json
git commit -m "Add project-specific knowledge"
```

これらのコミットは**親リポジトリにのみ**反映され、上流には影響しません。

**上流にプッシュ（注意）：**

```bash
# KairosChain_2026に変更を貢献したい場合のみ
# 通常、プロジェクト固有のファイルでは不要
git subtree push --prefix=server mcp_server main
```

> **警告：** KairosChain_2026リポジトリに変更を送信する意図がない限り、プッシュしないでください。プロジェクト固有の知識は親リポジトリに留めるべきです。

### コンフリクトの解決

`subtree pull`でコンフリクトが発生した場合：

```bash
$ git subtree pull --prefix=server mcp_server main --squash
# CONFLICT (add/add): Merge conflict in server/.../some_file.md

# 1. コンフリクトしたファイルを開いて解決
# 2. ステージしてコミット
git add server/KairosChain_mcp_server/...
git commit -m "Resolve subtree merge conflict, keep local changes"
```

**基本方針：** プロジェクト知識ファイルについては、上流よりもローカルの内容を優先してください。

### マルチプロジェクト展開の例

```
ProjectA/                           ProjectB/
├── .git/                           ├── .git/
└── server/ (subtree)               └── server/ (subtree)
    └── KairosChain_mcp_server/         └── KairosChain_mcp_server/
        ├── knowledge/                      ├── knowledge/
        │   ├── example_knowledge/ (共通)    │   ├── example_knowledge/ (共通)
        │   ├── tool_a/       (A固有)        │   ├── tool_b/       (B固有)
        │   └── utils_a/      (A固有)        │   └── utils_b/      (B固有)
        └── storage/                        └── storage/
            └── blockchain.json (A固有)         └── blockchain.json (B固有)
```

各プロジェクトは独立して：
- 同じ上流からフレームワーク更新をプル
- 独自のL1知識を蓄積
- 独自のブロックチェーン状態を管理

### サブツリープル後：テンプレートの更新

テンプレートファイル（`kairos.rb`、`kairos.md`、`config.yml`など）の変更を含む上流の更新をプルした場合、サブツリーディレクトリには完全なソースコードが含まれているため、変更は直接適用されます。ただし、これらのファイルをローカルで変更している場合は、`subtree pull`時にマージコンフリクトが発生する可能性があります。

サブツリーユーザーの場合、`system_upgrade` MCPツールや`kairos-chain upgrade` CLIコマンドは**不要**です。ファイルの更新はサブツリープル自体が処理します。アップグレードツールは、テンプレートファイルがgem内にバンドルされており、ユーザーのデータディレクトリへの移行が必要な**gemベースのインストール**向けに設計されています。

**更新方法のまとめ：**

| インストール方法 | 更新方法 | テンプレートの扱い |
|---|---|---|
| **Gem**（`gem install`） | `gem update kairos-chain` + `system_upgrade`ツール | `.kairos_meta.yml`による3wayハッシュマージ |
| **Subtree**（`git subtree`） | `git subtree pull` | 標準のgitマージ（コンフリクトは手動解決） |
| **リポジトリクローン** | `git pull` | 標準のgitマージ（コンフリクトは手動解決） |

### リファレンス

- 上流: `https://github.com/masaomi/KairosChain_2026`
- サブツリープレフィックス: `server/`（または任意のパス）
- リモートエイリアス: `mcp_server`

---
