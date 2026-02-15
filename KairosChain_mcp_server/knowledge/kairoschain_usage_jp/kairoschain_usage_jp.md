---
name: kairoschain_usage_jp
description: KairosChainのツール一覧、使用方法、進化ワークフロー
version: 1.0
layer: L1
tags: [documentation, readme, usage, tools, workflow, examples]
readme_order: 3
readme_lang: jp
---

## 使用のヒント

### 基本的な使用方法

#### 1. スキルを操作する

KairosChainはAI能力定義を「スキル」として管理します。

```
# Cursor / Claude Codeで：
"List all current skills"
"Show me the core_safety skill content"
"Use self_introspection to check Kairos state"
```

#### 2. ブロックチェーン記録

AI進化プロセスはブロックチェーンに記録されます。

```
# 記録を確認
"Show me the chain_history"
"Verify chain integrity with chain_verify"
```

### 実践的な使用パターン

#### パターン1：開発セッションの開始

```
# セッション開始チェックリスト
1. "Check blockchain status with chain_status"
2. "List available skills with skills_dsl_list"
3. "Verify chain integrity with chain_verify"
```

#### パターン2：スキル進化（人間の承認が必要）

```yaml
# config/safety.ymlで進化を有効にする
evolution_enabled: true
require_human_approval: true
```

```
# 進化ワークフロー：
1. "Propose a change to my_skill using skills_evolve"
2. [人間] 提案をレビューして承認
3. "Apply the change with skills_evolve (approved=true)"
4. "Verify the record with chain_history"
```

#### パターン3：監査とトレーサビリティ

```
# 特定の変更履歴を追跡
"Show recent skill changes with chain_history"
"Get details of a specific block"

# 定期的な整合性検証
"Verify the entire chain with chain_verify"
```

### ベストプラクティス

#### 1. 進化には慎重に

- デフォルトでは`evolution_enabled: false`を維持
- 進化セッションを明示的に開始し、完了後に無効にする
- すべての変更を人間の承認を通す

#### 2. 定期的な検証

```bash
# 毎日/毎週実行
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server
```

#### 3. バックアップ

```bash
# storage/blockchain.jsonを定期的にバックアップ
cp storage/blockchain.json storage/backups/blockchain_$(date +%Y%m%d).json

# スキルバージョンもバックアップ
cp -r skills/versions skills/backups/versions_$(date +%Y%m%d)
```

#### 4. 複数のAIエージェント間での共有

同じデータディレクトリを共有することで、複数のAIエージェント間で進化履歴を同期できます。

```json
// ~/.cursor/mcp.json または ~/.claude.json で
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/shared/kairos-data"],
      "env": {}
    }
  }
}
```

または環境変数で指定：

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": [],
      "env": {
        "KAIROS_DATA_DIR": "/shared/kairos-data"
      }
    }
  }
}
```

### tool_guideによるツール発見

`tool_guide`ツールは、KairosChainツールの発見と学習を動的にサポートします。

```
# カテゴリ別に全ツールを閲覧
"tool_guide command='catalog'を実行して"

# キーワードでツールを検索
"tool_guide command='search' query='blockchain'を実行して"

# タスクに適したツールの推奨を取得
"tool_guide command='recommend' task='knowledge healthを監査'を実行して"

# 特定ツールの詳細情報を取得
"tool_guide command='detail' tool_name='skills_audit'を実行して"

# 一般的なワークフローパターンを学ぶ
"tool_guide command='workflow'を実行して"
"tool_guide command='workflow' workflow_name='skill_evolution'を実行して"
```

**ツール開発者向け（LLM支援メタデータ生成）：**

```
# ツールのメタデータを提案
"tool_guide command='suggest' tool_name='my_new_tool'を実行して"

# 提案されたメタデータを検証
"tool_guide command='validate' tool_name='my_new_tool' metadata={...}を実行して"

# 人間の承認付きでメタデータを適用
"tool_guide command='apply_metadata' tool_name='my_new_tool' metadata={...} approved=trueを実行して"
```

### よく使うコマンドリファレンス

| タスク | Cursor/Claude Codeプロンプト |
|--------|------------------------------|
| スキル一覧 | "Run skills_dsl_list" |
| 特定のスキルを取得 | "Get core_safety with skills_dsl_get" |
| チェーンステータス | "Check chain_status" |
| 履歴を表示 | "Show chain_history" |
| 整合性検証 | "Run chain_verify" |
| データを記録 | "Record a log with chain_record" |
| ツール一覧を閲覧 | "Run tool_guide command='catalog'" |
| ツールを検索 | "Run tool_guide command='search' query='...'" |
| ツールのヘルプを取得 | "Run tool_guide command='detail' tool_name='...'" |

### セキュリティ考慮事項

1. **安全な進化設定**
   - `require_human_approval: true`を維持
   - 必要な時のみ`evolution_enabled: true`に設定

2. **アクセス制御**
   - `config/safety.yml`で許可パスを制限
   - 機密ファイルをブロックリストに追加

3. **監査ログ**
   - すべての操作は`action_log`に記録される
   - 定期的にログをレビュー

## 利用可能なツール（コア25個 + スキルツール）

基本インストールでは24個のツール（23 + HTTP専用1個）が提供されます。`skill_tools_enabled: true`の場合、`kairos.rb`の`tool`ブロックで追加のツールを定義できます。

### L0-A：スキルツール（Markdown） - 読み取り専用

| ツール | 説明 |
|--------|------|
| `skills_list` | kairos.mdからすべてのスキルセクションを一覧表示 |
| `skills_get` | IDで特定のセクションを取得 |

### L0-B：スキルツール（DSL） - 完全なブロックチェーン記録

| ツール | 説明 |
|--------|------|
| `skills_dsl_list` | kairos.rbからすべてのスキルを一覧表示 |
| `skills_dsl_get` | IDでスキル定義を取得 |
| `skills_evolve` | スキル変更を提案/適用 |
| `skills_rollback` | バージョンスナップショットを管理 |

> **スキル定義ツール**：`skill_tools_enabled: true`の場合、`kairos.rb`内の`tool`ブロックを持つスキルもここにMCPツールとして登録されます。

### クロスレイヤー昇格ツール

| ツール | 説明 |
|--------|------|
| `skills_promote` | オプションのPersona Assemblyで知識をレイヤー間で昇格（L2→L1、L1→L0） |

コマンド:
- `analyze`: 昇格判断のためのペルソナアセンブリ議論を生成
- `promote`: 直接昇格を実行
- `status`: 昇格要件を確認

### 監査ツール - 知識ライフサイクル管理

| ツール | 説明 |
|--------|------|
| `skills_audit` | オプションのPersona AssemblyでL0/L1/L2全レイヤーの知識健全性を監査 |

コマンド:
- `check`: 指定レイヤーの健全性チェック
- `stale`: 古くなった項目を検出（L0: 日付チェックなし、L1: 180日、L2: 14日）
- `conflicts`: 知識間の潜在的矛盾を検出
- `dangerous`: L0安全性と矛盾するパターンを検出
- `recommend`: 昇格とアーカイブの推奨を取得
- `archive`: L1知識をアーカイブ（人間の承認が必要）
- `unarchive`: アーカイブから復元（人間の承認が必要）

### リソースツール - 統一アクセス

| ツール | 説明 |
|--------|------|
| `resource_list` | 全レイヤー（L0/L1/L2）のリソースをURIで一覧表示 |
| `resource_read` | URIでリソースコンテンツを取得 |

URI形式：
- `l0://kairos.md`, `l0://kairos.rb` (L0スキル)
- `knowledge://{name}`, `knowledge://{name}/scripts/{file}` (L1)
- `context://{session}/{name}` (L2)

### L1：知識ツール - ハッシュ参照記録

| ツール | 説明 |
|--------|------|
| `knowledge_list` | すべての知識スキルを一覧表示 |
| `knowledge_get` | 名前で知識コンテンツを取得 |
| `knowledge_update` | 知識を作成/更新/削除（ハッシュ記録） |

### L2：コンテキストツール - ブロックチェーン記録なし

| ツール | 説明 |
|--------|------|
| `context_save` | コンテキストを保存（自由に変更可能） |
| `context_create_subdir` | scripts/assets/referencesサブディレクトリを作成 |

### ブロックチェーンツール

| ツール | 説明 |
|--------|------|
| `chain_status` | ブロックチェーンステータスを取得（ストレージバックエンド情報含む） |
| `chain_record` | ブロックチェーンにデータを記録 |
| `chain_verify` | チェーンの整合性を検証 |
| `chain_history` | ブロック履歴を表示（拡張版：StateCommitブロックをフォーマット表示） |
| `chain_export` | SQLiteデータをファイルにエクスポート（SQLiteモードのみ） |
| `chain_import` | ファイルをSQLiteにインポート、自動バックアップ付き（SQLiteモードのみ、`approved=true`必須） |

### StateCommitツール（監査可能性向上）

StateCommitは、特定の「コミットポイント」で全レイヤー（L0/L1/L2）のスナップショットを作成し、クロスレイヤーの監査可能性を提供します。

| ツール | 説明 |
|--------|------|
| `state_commit` | 理由を付けて明示的な状態コミットを作成（ブロックチェーンに記録） |
| `state_status` | 現在の状態、保留中の変更、自動コミットトリガー状況を表示 |
| `state_history` | 状態コミット履歴を閲覧、スナップショットの詳細を表示 |

### 認証ツール（HTTPモード専用）

| ツール | 説明 |
|--------|------|
| `token_manage` | Bearerトークンを管理（作成、失効、一覧、ローテーション）。`owner`ロールが必要。 |

### ガイドツール（ツール発見）

KairosChainツールを発見し学ぶための動的ツールガイドシステム。

| ツール | 説明 |
|--------|------|
| `tool_guide` | 動的なツール発見、検索、ドキュメンテーション |

コマンド:
- `catalog`: カテゴリ別に全ツールを一覧表示
- `search`: キーワードでツールを検索
- `recommend`: 特定のタスク用にツールを推奨
- `detail`: 特定のツールの詳細情報を取得
- `workflow`: 一般的なワークフローパターンを表示
- `suggest`: ツールのメタデータ提案を生成（LLM支援）
- `validate`: 適用前に提案されたメタデータを検証
- `apply_metadata`: ツールにメタデータを適用（人間の承認が必要）

**主な機能：**
- スナップショットはオフチェーン保存（JSONファイル）、ハッシュ参照のみオンチェーン
- 自動コミットトリガー：L0変更、昇格/降格、閾値ベース（L1変更5件または合計10件）
- 空コミット防止：マニフェストハッシュが実際に変更された場合のみコミット

### システム管理ツール

| ツール | 説明 |
|--------|------|
| `system_upgrade` | gemの更新を確認し、データディレクトリのテンプレートを安全にマイグレーション |

コマンド:
- `check`: 現在のバージョンとgemバージョンを比較、影響ファイルを表示
- `preview`: ファイル別の詳細分析とマージプレビュー
- `apply`: アップグレードを実行（`approved=true`が必要）
- `status`: `.kairos_meta.yml`の状態を表示

## 使用例

### 利用可能なスキルを一覧表示

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | kairos_mcp_server
```

### ブロックチェーンステータスを確認

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server
```

### スキル遷移を記録

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["Skill X modified","Reason: improved accuracy"]}}}' | kairos_mcp_server
```

## 自己進化ワークフロー

KairosChainは**安全な自己進化**をサポートします：

1. **進化を有効にする**（`skills/config.yml`で）：
   ```yaml
   evolution_enabled: true
   require_human_approval: true
   ```

2. **AIが変更を提案**：
   ```bash
   skills_evolve command=propose skill_id=my_skill definition="..."
   ```

3. **人間がレビューして承認**：
   ```bash
   skills_evolve command=apply skill_id=my_skill definition="..." approved=true
   ```

4. **変更が適用され記録される**：
   - `skills/versions/`にスナップショットが作成される
   - ブロックチェーンに遷移が記録される
   - `Kairos.reload!`がメモリ内の状態を更新

5. **検証**：
   ```bash
   chain_verify  # 整合性を確認
   chain_history # 遷移記録を表示
   ```
