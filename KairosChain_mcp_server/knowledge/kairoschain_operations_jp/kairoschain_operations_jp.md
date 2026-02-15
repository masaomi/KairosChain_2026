---
name: kairoschain_operations_jp
description: 将来のロードマップ、デプロイ、運用ガイド
version: 1.0
layer: L1
tags: [documentation, readme, operations, deployment, roadmap, backup]
readme_order: 5
readme_lang: jp
---

## 将来のロードマップ

### 近期

1. **Ethereumアンカー**：公開チェーンへの定期的なハッシュアンカリング
2. **マルチエージェントサポート**：`agent_id`で複数のAIエージェントを追跡
3. **ゼロ知識証明**：プライバシーを保護した検証
4. **Webダッシュボード**：スキル進化履歴の可視化
5. **チームガバナンス**：L0変更のための投票システム（FAQを参照）

### 長期ビジョン：分散KairosChainネットワーク

KairosChainの将来構想：複数のKairosChain MCPサーバーがインターネット上で公開MCPプロトコルを介して通信し合い、各サーバーがL0憲法に従って自律的に知識を進化させる。

**主要コンセプト**：
- 分散ガバナンスとしてのL0憲法
- 専門ノード間での知識の相互受粉
- 憲法の範囲内での自律的進化
- GenomicsChain PoC/DAOとの統合

**実装フェーズ**：
1. Docker化（デプロイメント基盤）
2. ~~HTTP/WebSocket API（リモートアクセス）~~ ✅ Streamable HTTPトランスポート（Phase 1 完了）
3. サーバー間通信プロトコル
4. 分散合意メカニズム
5. L0分散ガバナンス

詳細なビジョンドキュメント: [分散KairosChainネットワーク構想](docs/distributed_kairoschain_vision_20260128_jp.md)

---

## デプロイと運用

### データストレージの概要

KairosChainは以下の場所にデータを保存します：

| ディレクトリ | 内容 | Git追跡 | 重要度 |
|-------------|------|---------|--------|
| `skills/kairos.rb` | L0 DSL（進化可能） | Yes | 高 |
| `skills/kairos.md` | L0 哲学（不変） | Yes | 高 |
| `skills/config.yml` | 設定 | Yes | 高 |
| `skills/versions/` | DSLスナップショット | Yes | 中 |
| `knowledge/` | L1プロジェクト知識 | Yes | 高 |
| `context/` | L2一時コンテキスト | Yes | 低 |
| `storage/blockchain.json` | ブロックチェーンデータ（ファイルモード） | Yes | 高 |
| `storage/kairos.db` | SQLiteデータベース（SQLiteモード） | No | 高 |
| `storage/embeddings/*.ann` | ベクトルインデックス（自動生成） | No | 低 |
| `storage/snapshots/` | StateCommitスナップショット（オフチェーン） | No | 中 |
| `skills/action_log.jsonl` | アクションログ（ファイルモード） | No | 低 |

### ブロックチェーンのストレージ形式

デフォルトでは、プライベートブロックチェーンは`storage/blockchain.json`に**JSONフラットファイル**として保存されます。オプションでSQLiteバックエンドも使用可能です（「オプション：SQLiteストレージバックエンド」セクションを参照）。

**ファイルモード（デフォルト）** - `storage/blockchain.json`：

```json
[
  {
    "index": 0,
    "timestamp": "1970-01-01T00:00:00.000000Z",
    "data": ["Genesis Block"],
    "previous_hash": "0000...0000",
    "merkle_root": "0000...0000",
    "hash": "a1b2c3..."
  },
  {
    "index": 1,
    "timestamp": "2026-01-20T10:30:00.123456Z",
    "data": ["{\"type\":\"skill_evolution\",\"skill_id\":\"...\"}"],
    "previous_hash": "a1b2c3...",
    "merkle_root": "xyz...",
    "hash": "789..."
  }
]
```

**なぜJSONフラットファイルか？**
- **シンプルさ**：外部依存なし
- **可読性**：監査のために人間が直接確認可能
- **ポータビリティ**：コピーするだけでバックアップ/移行可能
- **哲学への適合**：監査可能性はKairosの核心

**SQLiteモード** - `storage/kairos.db`：

```sql
-- blocksテーブル
CREATE TABLE blocks (
  id INTEGER PRIMARY KEY,
  idx INTEGER NOT NULL,
  timestamp TEXT NOT NULL,
  data TEXT NOT NULL,        -- JSON配列
  previous_hash TEXT NOT NULL,
  merkle_root TEXT NOT NULL,
  hash TEXT NOT NULL UNIQUE
);

-- action_logsテーブル
CREATE TABLE action_logs (
  id INTEGER PRIMARY KEY,
  timestamp TEXT NOT NULL,
  entry TEXT NOT NULL        -- JSONエントリ
);
```

**なぜSQLiteか？（チーム利用時）**
- **同時アクセス**：WALモードで複数の読み取り + 単一書き込み
- **ACIDトランザクション**：データ整合性の保証
- **クエリ能力**：複雑なクエリがSQLで可能
- **自己完結型**：単一ファイルでサーバー不要

**ファイル vs SQLiteの選択：**

| シナリオ | 推奨 |
|----------|------|
| 個人開発者 | ファイル（シンプル） |
| チーム（2-10人） | SQLite（同時アクセス） |
| 監査/検査 | ファイルへエクスポート |

### 推奨運用パターン

#### パターン1：Fork + プライベートリポジトリ（推奨）

KairosChainをフォークしてプライベートリポジトリとして保持します。最もシンプルなアプローチです。

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub                                                         │
│  ┌─────────────────────┐    ┌─────────────────────┐            │
│  │ KairosChain (公開)  │───▶│ your-fork (非公開)  │            │
│  │ - コード更新        │    │ - skills/           │            │
│  └─────────────────────┘    │ - knowledge/        │            │
│                             │ - storage/          │            │
│                             └─────────────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

**メリット:** シンプル、すべてが一箇所、完全バックアップ  
**デメリット:** 上流の更新をプルする際にコンフリクトの可能性

**セットアップ:**
```bash
# GitHubでフォークし、プライベートフォークをクローン
git clone https://github.com/YOUR_USERNAME/KairosChain_2026.git
cd KairosChain_2026

# 更新用にupstreamを追加
git remote add upstream https://github.com/masaomi/KairosChain_2026.git

# 上流の更新をプル（必要時）
git fetch upstream
git merge upstream/main
```

#### パターン2：データディレクトリ分離

KairosChainのコードとデータを別々のリポジトリで管理します。

```
┌─────────────────────────────────────────────────────────────────┐
│  2つのリポジトリ                                                 │
│                                                                 │
│  ┌────────────────────┐    ┌─────────────────────────────┐     │
│  │ KairosChain (公開) │    │ my-kairos-data (非公開)     │     │
│  │ - lib/             │    │ - skills/                   │     │
│  │ - bin/             │    │ - knowledge/                │     │
│  │ - config/          │    │ - context/                  │     │
│  └────────────────────┘    │ - storage/                  │     │
│                            └─────────────────────────────┘     │
│                                                                 │
│  シンボリックリンクで接続：                                       │
│  $ ln -s ~/my-kairos-data/skills ./skills                       │
│  $ ln -s ~/my-kairos-data/knowledge ./knowledge                 │
│  $ ln -s ~/my-kairos-data/storage ./storage                     │
└─────────────────────────────────────────────────────────────────┘
```

**メリット:** 上流の更新を取り込みやすい、明確な分離  
**デメリット:** シンボリックリンクの設定が必要、2つのリポジトリを管理

#### パターン3：クラウド同期（非Git）

データディレクトリをクラウドストレージ（Dropbox、iCloud、Google Drive）と同期します。

```bash
# 例：Dropboxへのシンボリックリンク
ln -s ~/Dropbox/KairosChain/skills ./skills
ln -s ~/Dropbox/KairosChain/knowledge ./knowledge
ln -s ~/Dropbox/KairosChain/storage ./storage
```

**メリット:** 自動同期、Git知識不要  
**デメリット:** バージョン管理が弱い、コンフリクト解決が難しい

### バックアップ戦略

#### 定期バックアップ

```bash
# バックアップスクリプトを作成
#!/bin/bash
BACKUP_DIR=~/kairos-backups/$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR

# 重要データをバックアップ
cp -r skills/ $BACKUP_DIR/
cp -r knowledge/ $BACKUP_DIR/
cp -r storage/ $BACKUP_DIR/

# 古いバックアップを削除（30日以上前）
find ~/kairos-backups -mtime +30 -type d -exec rm -rf {} +

echo "バックアップ作成: $BACKUP_DIR"
```

#### バックアップ対象

| 優先度 | ディレクトリ | 理由 |
|--------|-------------|------|
| **最重要** | `storage/blockchain.json` | 不変の進化履歴 |
| **最重要** | `skills/kairos.rb` | L0メタルール |
| **高** | `knowledge/` | プロジェクト知識 |
| **中** | `skills/versions/` | 進化スナップショット |
| **低** | `context/` | 一時的（再作成可能） |
| **スキップ** | `storage/embeddings/` | 自動再生成 |

#### リストア後の検証

```bash
# バックアップからリストア後、整合性を検証
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server
```

### ドキュメント管理

README.mdとREADME_jp.mdは**L1 knowledgeファイルから自動生成**されます。直接編集しないでください。

#### Single Source of Truth（情報源の一元化）

ドキュメントの内容は`KairosChain_mcp_server/knowledge/`以下のL1 knowledgeファイルに管理されています：

| L1 Knowledge | 内容 |
|---|---|
| `kairoschain_philosophy` / `_jp` | 哲学、アーキテクチャ、レイヤー設計 |
| `kairoschain_setup` / `_jp` | インストール、設定、テスト |
| `kairoschain_usage` / `_jp` | ツールリファレンス、使い方 |
| `kairoschain_design` / `_jp` | Pure Skills設計、ディレクトリ構造 |
| `kairoschain_operations` / `_jp` | ロードマップ、デプロイ、運用 |
| `kairoschain_faq` / `_jp` | FAQ、サブツリー統合 |

ヘッダー/フッターテンプレートは`scripts/readme_templates/`にあります。

#### ドキュメントの更新方法

1. `KairosChain_mcp_server/knowledge/`内の該当するL1 knowledgeファイルを編集
2. READMEを再生成：

```bash
# L1 knowledgeからREADME.mdとREADME_jp.mdを生成
rake build_readme

# またはスクリプトを直接実行
ruby scripts/build_readme.rb
```

3. L1 knowledgeの変更と再生成されたREADMEの両方をコミット

#### その他のコマンド

```bash
# READMEが最新か確認（CI向け）
rake check_readme

# 書き込みなしで生成プレビュー
rake preview_readme

# ヘルプとオプションを表示
ruby scripts/build_readme.rb --help
```

#### なぜ自動生成か？

- **情報源の一元化**: L1 knowledgeのみを編集すればよい
- **MCPアクセス可能**: LLMが`knowledge_get` / `knowledge_list`経由でドキュメントを参照可能
- **監査可能**: ドキュメント変更はL1知識の更新として追跡（ハッシュがブロックチェーンに記録）
- **セマンティック検索**: MCP経由でRAG対応の全ドキュメント検索が可能

---
