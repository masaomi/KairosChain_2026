# KairosChain MCP Server

**AIスキル進化を記録するメタ台帳**

> 📖 [English README is here](README.md)

KairosChainは、AIの能力進化をプライベートブロックチェーンに記録するModel Context Protocol (MCP)サーバーです。Pure Skills設計（Ruby DSL/AST）と不変台帳技術を組み合わせ、AIエージェントが監査可能で、進化可能で、自己参照的なスキル定義を持つことを可能にします。

## 目次

- [哲学](#哲学)
- [アーキテクチャ](#アーキテクチャ)
- [レイヤー化されたスキルアーキテクチャ](#レイヤー化されたスキルアーキテクチャ)
- [データモデル：SkillStateTransition](#データモデルskillstatetransition)
- [セットアップ](#セットアップ)
  - [オプション：RAGサポート](#オプションragセマンティック検索サポート)
  - [オプション：SQLite](#オプションsqliteストレージバックエンドチーム利用向け)
- [クライアント設定](#クライアント設定)
- [セットアップのテスト](#セットアップのテスト)
- [使用のヒント](#使用のヒント)
- [利用可能なツール](#利用可能なツールコア20個--スキルツール)
- [使用例](#使用例)
- [自己進化ワークフロー](#自己進化ワークフロー)
- [Pure Skills設計](#pure-skills設計)
- [ディレクトリ構造](#ディレクトリ構造)
- [Meeting Place (MMP)](#meeting-place-mmp)
- [将来のロードマップ](#将来のロードマップ)
- [デプロイと運用](#デプロイと運用)
- [FAQ](#faq)
- [ライセンス](#ライセンス)

## 哲学

### 問題

LLM/AIエージェントにおける最大のブラックボックスは：

> **現在の能力がどのように形成されたかを説明できないこと。**

- プロンプトは揮発的
- ツール呼び出し履歴は断片的
- スキルの進化（再定義、合成、削除）は痕跡を残さない

その結果、AIは以下のような場合でも**因果プロセスを第三者が検証できない**存在となります：
- より高い能力を獲得した
- 動作が変化した
- 潜在的に危険になった

### 解決策：KairosChain

KairosChainはこれに以下のように対処します：

1. **スキルを実行可能な構造として定義**（Ruby DSL）、単なるドキュメントではなく
2. **すべてのスキル変更を不変のブロックチェーンに記録**
3. **自己参照を可能にし**、AIが自身の能力を検査できる
4. **安全な進化を強制**、承認ワークフローと不変性ルールで

KairosChainはプラットフォーム、通貨、DAOではありません。**メタ台帳**です — 能力進化の監査証跡です。

### Minimum-Nomicの原則

KairosChainは**Minimum-Nomic**を実装します — 以下のようなシステム：

- ルール（スキル）は**変更可能**
- しかし**誰が**、**いつ**、**何を**、**どのように**変更したかは常に記録され、消去できない

これにより両極端を回避します：
- ❌ 完全に固定されたルール（適応不可）
- ❌ 無制限の自己改変（カオス）

代わりに達成するのは：**進化可能だがゲーム化できないシステム**。

## アーキテクチャ

![KairosChain レイヤーアーキテクチャ](docs/kairoschain_linkedin_diagram.png)

*図：KairosChainの法制度に着想を得たAIスキル管理のためのレイヤーアーキテクチャ*

### システム概要

```
┌─────────────────────────────────────────────────────────────────┐
│                    MCPクライアント (Cursor / Claude Code)        │
└───────────────────────────────┬─────────────────────────────────┘
                                │ STDIO (JSON-RPC)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    KairosChain MCPサーバー                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────────┐ │
│  │    Server    │ │   Protocol   │ │     Tool Registry        │ │
│  │  STDIOループ │ │  JSON-RPC    │ │  12+ツール利用可能       │ │
│  └──────────────┘ └──────────────┘ └──────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    スキルレイヤー                          │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐│   │
│  │  │ kairos.rb  │ │ kairos.md  │ │    Kairosモジュール    ││   │
│  │  │ (DSL)      │ │ (Markdown) │ │  (自己参照)            ││   │
│  │  └────────────┘ └────────────┘ └────────────────────────┘│   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   ブロックチェーンレイヤー                  │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐│   │
│  │  │   Block    │ │   Chain    │ │     MerkleTree         ││   │
│  │  │ (SHA-256)  │ │ (JSON)     │ │  (証明生成)            ││   │
│  │  └────────────┘ └────────────┘ └────────────────────────┘│   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## レイヤー化されたスキルアーキテクチャ

KairosChainは、知識管理のための**法制度に着想を得たレイヤーアーキテクチャ**を実装しています：

| レイヤー | 法的類推 | パス | ブロックチェーン記録（操作単位） | 可変性 |
|---------|----------|------|-------------------------------|--------|
| **L0-A** | 憲法 | `skills/kairos.md` | - | 読み取り専用 |
| **L0-B** | 法律 | `skills/kairos.rb` | 完全なトランザクション | 人間の承認が必要 |
| **L1** | 条例 | `knowledge/` | ハッシュ参照のみ | 軽量な制約 |
| **L2** | 指令 | `context/` | なし* | 自由に変更可能 |

*注：L2の個別操作は記録されませんが、[StateCommit](#statecommitツール監査可能性向上)は定期的に全レイヤー（L2含む）をオフチェーンスナップショットとしてキャプチャし、オンチェーンにはハッシュ参照のみを記録します。

### L0：Kairosコア（`skills/`）

KairosChainの基盤。自己改変に関するメタルールを含みます。

- **kairos.md**：哲学と原則（不変、読み取り専用）
- **kairos.rb**：Ruby DSLでのメタスキル（完全なブロックチェーン記録で変更可能）

L0に配置できるのはこれらのメタスキルのみ：
- `l0_governance`, `core_safety`, `evolution_rules`, `layer_awareness`, `approval_workflow`, `self_inspection`, `chain_awareness`, `audit_rules`

> **注意：L0自己統治**  
> `l0_governance`スキルは、どのスキルがL0に存在できるかを定義します。これはPure Agent Skillの原則を実装しています：すべてのL0統治基準はL0自身の中で定義されなければなりません。詳細は[Pure Agent SkillのFAQ](#q-pure-agent-skillとは何ですかなぜ重要ですか)を参照してください。

> **注意：スキル-ツール統一**  
> `kairos.rb`のスキルは`tool`ブロックでMCPツールを定義することもできます。`skill_tools_enabled: true`が設定されている場合、これらのスキルは自動的にMCPツールとして登録されます。つまり、**L0-Bではスキルとツールが統一されています** — `kairos.rb`を編集することでツールの追加、変更、削除ができます（L0の制約が適用：人間の承認が必要、完全なブロックチェーン記録）。

### L1：知識レイヤー（`knowledge/`）

**Anthropic Skillsフォーマット**でのプロジェクト固有の普遍的知識。

```
knowledge/
└── skill_name/
    ├── skill_name.md       # YAMLフロントマター + Markdown
    ├── scripts/            # 実行可能スクリプト (Python, Bash, Node)
    ├── assets/             # テンプレート、画像、CSS
    └── references/         # 参考資料、データセット
```

`skill_name.md`の例：

```markdown
---
name: coding_rules
description: プロジェクトのコーディング規約
version: "1.0"
layer: L1
tags: [style, convention]
---

# コーディングルール

## 命名規則
- クラス名：PascalCase
- メソッド名：snake_case
```

### L2：コンテキストレイヤー（`context/`）

セッション用の一時的なコンテキスト。L1と同じフォーマットですが、**操作単位のブロックチェーン記録なし**。

```
context/
└── session_id/
    └── hypothesis/
        └── hypothesis.md
```

用途：
- 作業仮説
- スクラッチノート
- 試行錯誤的な探索

> **注意**: L2の個別変更は記録されませんが、[StateCommit](#statecommitツール監査可能性向上)機能によりL2の状態も定期的なスナップショット（オフチェーン保存、オンチェーンにはハッシュ参照のみ）にキャプチャできます。

### なぜレイヤーアーキテクチャか？

1. **すべての知識が同じ制約を必要とするわけではない** — 一時的な思考に操作単位のブロックチェーン記録は不要
2. **関心の分離** — Kairosメタルール vs プロジェクト知識 vs 一時的コンテキスト
3. **説明責任を伴うAI自律性** — L2では自由な探索、L1では追跡された変更、L0では厳格な制御
4. **クロスレイヤー監査可能性** — [StateCommit](#statecommitツール監査可能性向上)により全レイヤーを一括でスナップショットし、包括的な監査証跡を実現

## データモデル：SkillStateTransition

すべてのスキル変更は`SkillStateTransition`として記録されます：

```ruby
{
  skill_id: String,        # スキル識別子
  prev_ast_hash: String,   # 前のASTのSHA-256
  next_ast_hash: String,   # 新しいASTのSHA-256
  diff_hash: String,       # 差分のSHA-256
  actor: String,           # "Human" / "AI" / "System"
  agent_id: String,        # Kairosエージェント識別子
  timestamp: ISO8601,
  reason_ref: String       # オフチェーン理由参照
}
```

## セットアップ

### 前提条件

- Ruby 3.3+（基本機能は標準ライブラリのみ使用、gem不要）
- Claude Code CLI（`claude`）またはCursor IDE

### インストール

```bash
# リポジトリをクローン
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server

# 実行可能にする
chmod +x bin/kairos_mcp_server

# 基本動作をテスト
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server
```

### オプション：RAG（セマンティック検索）サポート

KairosChainはベクトル埋め込みを使用したオプションのセマンティック検索をサポートしています。これにより、完全なキーワード一致ではなく意味でスキルを検索できます（例：「認証」で検索すると「ログイン」や「パスワード」に関するスキルも見つかります）。

**RAG gemなし:** 正規表現ベースのキーワード検索（デフォルト、インストール不要）  
**RAG gemあり:** 文章埋め込みを使用したセマンティックベクトル検索

#### 必要要件

- C++コンパイラ（ネイティブ拡張のため）
- ~90MBのディスク容量（埋め込みモデル用、初回使用時にダウンロード）

#### インストール

```bash
cd KairosChain_mcp_server

# オプション1: Bundlerを使用（推奨）
bundle install --with rag

# オプション2: 直接gemをインストール
gem install hnswlib informers
```

#### 使用するgem

| Gem | バージョン | 用途 |
|-----|-----------|------|
| `hnswlib` | ~> 0.9 | HNSW近似最近傍探索 |
| `informers` | ~> 1.0 | ONNXベースの文章埋め込み |

#### 対応レイヤー

| レイヤー | 対象 | RAG対応 | インデックスパス |
|---------|------|---------|-----------------|
| **L0** | `skills/kairos.rb`（メタスキル） | あり | `storage/embeddings/skills/` |
| **L1** | `knowledge/`（プロジェクト知識） | あり | `storage/embeddings/knowledge/` |
| **L2** | `context/`（一時コンテキスト） | なし | N/A（正規表現検索のみ） |

L2は一時的なコンテキストで短命かつ通常は数が少ないため、正規表現検索で十分です。

#### 設定

`skills/config.yml`のRAG設定：

```yaml
vector_search:
  enabled: true                                      # gemが利用可能な場合に有効化
  model: "sentence-transformers/all-MiniLM-L6-v2"    # 埋め込みモデル
  dimension: 384                                     # モデルと一致させる必要あり
  index_path: "storage/embeddings"                   # インデックス保存パス
  auto_index: true                                   # 変更時に自動再構築
```

#### 途中からRAGをインストールする場合

KairosChainを使い始めた後にRAG gemをインストールする場合：

1. gemをインストール: `bundle install --with rag` または `gem install hnswlib informers`
2. **MCPサーバーを再起動**（Cursor/Claude Codeで再接続）
3. 最初の検索時に、全スキル/知識からインデックスが自動的に再構築される
4. 初回はモデルのダウンロード（~90MB）と埋め込み生成に時間がかかる

**仕組み:** `@available`フラグはサーバー起動時にチェックされ、キャッシュされます。FallbackSearch（正規表現ベース）はインデックスデータを永続化しません。SemanticSearchに切り替わると、`ensure_index_built`メソッドが最初の使用時に`rebuild_index`をトリガーし、既存の全スキルと知識の埋め込みを作成します。

**既存データへの影響:**
- スキル・知識ファイル: 変更なし（信頼できる情報源）
- ベクトルインデックス: 現在のコンテンツから新規作成
- 移行不要: FallbackSearch → SemanticSearchはシームレス

#### 確認方法

```bash
# RAGが利用可能か確認
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# またはMCP経由でテスト
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | bin/kairos_mcp_server
```

#### 動作の仕組み

```
┌─────────────────────────────────────────────────────────────┐
│                      検索クエリ                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  VectorSearch.available?  │
                    └─────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ セマンティック検索 │             │ フォールバック検索 │
    │ (hnswlib +      │             │ (正規表現ベース)  │
    │  informers)     │             │                 │
    └─────────────────┘             └─────────────────┘
              │                               │
              └───────────────┬───────────────┘
                              ▼
                    ┌─────────────────┐
                    │    検索結果     │
                    └─────────────────┘
```

---

### オプション：SQLiteストレージバックエンド（チーム利用向け）

デフォルトでは、KairosChainはファイルベースのストレージ（JSON/JSONLファイル）を使用します。同時アクセスが発生するチーム環境では、オプションでSQLiteストレージバックエンドを有効化できます。

**デフォルト（ファイルベース）:** 設定不要、個人利用に適切  
**SQLite:** 同時アクセス処理が改善、小規模チーム利用（2-10人）に適切

#### SQLiteを使うべきタイミング

| シナリオ | 推奨バックエンド |
|----------|-----------------|
| 個人開発者 | ファイル（デフォルト） |
| 小規模チーム（2-10人） | **SQLite** |
| 大規模チーム（10人以上） | PostgreSQL（将来対応） |
| CI/CDパイプライン | SQLite |

#### インストール

```bash
cd KairosChain_mcp_server

# オプション1: Bundlerを使用（推奨）
bundle install --with sqlite

# オプション2: 直接gemをインストール
gem install sqlite3
```

#### 設定

`skills/config.yml`を編集してSQLiteを有効化：

```yaml
# ストレージバックエンド設定
storage:
  backend: sqlite                         # 'file' から 'sqlite' に変更

  sqlite:
    path: "storage/kairos.db"             # SQLiteデータベースファイルのパス
    wal_mode: true                        # 同時アクセス改善のためWAL有効化
```

#### 確認方法

```bash
# SQLite gemがインストールされているか確認
ruby -e "require 'sqlite3'; puts 'SQLite3 gem installed!'"

# 有効化後、サーバーをテスト
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server
```

#### SQLiteからファイルへのエクスポート

SQLiteのデータを人間が読めるファイルにエクスポートしてバックアップや検査ができます：

```ruby
# Rubyコンソールまたはスクリプトで
require_relative 'lib/kairos_mcp/storage/exporter'

# 全データをエクスポート
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/export"
)

# 出力構造：
# storage/export/
# ├── blockchain.json       # 全ブロック
# ├── action_log.jsonl      # アクションログエントリ
# ├── knowledge_meta.json   # 知識メタデータ
# └── manifest.json         # エクスポートメタデータ
```

#### ファイルからSQLiteを再構築

SQLiteデータベースが破損した場合、ファイルベースのデータから再構築できます：

```ruby
# Rubyコンソールまたはスクリプトで
require_relative 'lib/kairos_mcp/storage/importer'

# 元のファイルストレージから再構築
KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: "storage/kairos.db"
)

# またはエクスポートされたファイルからインポート
KairosMcp::Storage::Importer.import(
  input_dir: "storage/export",
  db_path: "storage/kairos.db"
)
```

#### MCPツールでエクスポート/インポート

AIアシスタント（Cursor/Claude Code）からMCPツールを直接使用することもできます：

**エクスポート（読み取り専用、安全）:**
```
# Cursor/Claude Codeのチャットで：
「chain_exportを使ってSQLiteデータベースをファイルにエクスポートして」

# または直接呼び出し：
chain_export output_dir="storage/backup"
```

**インポート（承認が必要）:**
```
# プレビューモード（変更せずに影響を表示）：
chain_import source="files" approved=false

# 自動バックアップ付きで実行：
chain_import source="files" approved=true

# エクスポートされたディレクトリからインポート：
chain_import source="export" input_dir="storage/backup" approved=true
```

**chain_importの安全機能:**
- `approved=true`が必要（それ以外はプレビュー表示）
- `storage/backups/kairos_{timestamp}.db`に自動バックアップ
- 実行前に影響のサマリーを表示
- `skip_backup=true`で回避可能（非推奨）

#### SQLiteへの移行手順（ステップバイステップ）

既にファイルベースのストレージでKairosChainを使用していてSQLiteに移行する場合：

**ステップ1: sqlite3 gemをインストール**

```bash
cd KairosChain_mcp_server

# Bundlerを使用（推奨）
bundle install --with sqlite

# または直接インストール
gem install sqlite3

# インストール確認
ruby -e "require 'sqlite3'; puts 'SQLite3 ready!'"
```

**ステップ2: config.ymlを更新**

```yaml
# skills/config.yml
storage:
  backend: sqlite                         # 'file' から 'sqlite' に変更

  sqlite:
    path: "storage/kairos.db"
    wal_mode: true
```

**ステップ3: 既存データを移行**

```bash
cd KairosChain_mcp_server

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'

result = KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: 'storage/kairos.db'
)

puts '移行完了!'
puts \"インポートされたブロック: #{result[:blocks]}\"
puts \"インポートされたアクションログ: #{result[:action_logs]}\"
puts \"インポートされた知識メタデータ: #{result[:knowledge_meta]}\"
"
```

**ステップ4: MCPサーバーを再起動**

Cursor/Claude Codeを再起動するか、MCPサーバーを再接続します。

**ステップ5: 移行を確認**

```bash
# チェーンステータスを確認
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# チェーンの整合性を検証
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

**ステップ6: 元ファイルをバックアップとして保持**

移行後、元のファイルはバックアップとして保持してください：

```
storage/
├── blockchain.json      # ← 元ファイル（バックアップとして保持）
├── kairos.db            # ← 新しいSQLiteデータベース
└── kairos.db-wal        # ← WALファイル（自動生成）

skills/
└── action_log.jsonl     # ← 元ファイル（バックアップとして保持）
```

#### SQLiteトラブルシューティング

**sqlite3 gemがロードできない：**

```bash
# インストール確認
gem list sqlite3

# 必要に応じて再インストール
gem uninstall sqlite3
gem install sqlite3
```

**移行後にデータが見えない：**

```bash
# 移行を再実行
ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**SQLiteデータベースが破損した：**

```bash
# 破損したデータベースを削除して元ファイルから再構築
rm storage/kairos.db storage/kairos.db-wal storage/kairos.db-shm 2>/dev/null

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**ファイルベースストレージに戻す：**

```yaml
# config.ymlを変更するだけ
storage:
  backend: file    # 'sqlite' から 'file' に変更
```

元のファイル（`blockchain.json`、`action_log.jsonl`）が自動的に使用されます。

#### 重要な注意事項

- **知識コンテンツ（*.mdファイル）**: バックエンドに関係なく常にファイルに保存
- **SQLiteに保存されるもの**: ブロックチェーン、アクションログ、知識メタデータのみ
- **人間可読性**: エクスポート機能でSQLコマンドなしでデータを確認
- **バックアップ**: SQLiteの場合は`.db`ファイルをコピーするだけ。より安全のためファイルへのエクスポートも併用

---

## クライアント設定

### Claude Code設定（詳細）

Claude CodeはCLIベースのAIコーディングアシスタントです。

#### ステップ1：Claude Codeのインストール確認

```bash
# Claude Codeがインストールされているか確認
claude --version

# インストールされていない場合は公式サイトからインストール
# https://docs.anthropic.com/claude-code
```

#### ステップ2：MCPサーバーを登録

```bash
# KairosChain MCPサーバーを登録
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos_mcp_server

```

#### ステップ3：登録を確認

```bash
# 登録されたMCPサーバーを一覧表示
claude mcp list

# リストにkairos-chainが表示されるはずです
```

#### ステップ4：設定ファイルを確認（オプション）

`~/.claude.json`に以下の設定が追加されます：

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {}
    }
  }
}
```

#### 手動設定（上級者向け）

設定ファイルを直接編集する場合：

```bash
# 設定ファイルを開く
vim ~/.claude.json

# またはVS Codeを使用
code ~/.claude.json
```

### Cursor IDE設定（詳細）

CursorはVS CodeベースのAIコーディングIDEです。

#### オプションA：GUIから（推奨）

1. **Cursor Settings**を開く（Cmd/Ctrl + ,）
2. **Tools & MCP**に移動
3. **New MCP Server**をクリック
4. サーバー詳細を入力：
   - Name: `kairos-chain`
   - Command: `ruby`
   - Args: `/path/to/KairosChain_mcp_server/bin/kairos_mcp_server`

#### オプションB：設定ファイルから

#### ステップ1：設定ファイルの場所を確認

```bash
# macOS / Linux
~/.cursor/mcp.json

# Windows
%USERPROFILE%\.cursor\mcp.json
```

#### ステップ2：設定ファイルを作成/編集

```bash
# ディレクトリが存在しない場合は作成
mkdir -p ~/.cursor

# 設定ファイルを編集
vim ~/.cursor/mcp.json
```

#### ステップ3：MCPサーバーを追加

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {}
    }
  }
}
```

**複数のMCPサーバーを使用する場合：**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/Users/yourname/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {}
    },
    "sushi-mcp-server": {
      "command": "ruby",
      "args": ["/path/to/SUSHI_self_maintenance_mcp_server/bin/sushi_mcp_server"],
      "env": {}
    }
  }
}
```

#### ステップ4：Cursorを再起動

設定を保存した後、**Cursorを完全に再起動する必要があります**。

#### ステップ5：MCPサーバー接続を確認

1. Cursorを開く
2. 右上の「MCP」アイコンをクリック（またはコマンドパレットで「MCP」を検索）
3. `kairos-chain`がリストに緑色のステータスインジケーターで表示されていることを確認

---

## セットアップのテスト

### 1. 基本的なコマンドラインテスト

#### 初期化テスト

```bash
cd /path/to/KairosChain_mcp_server

# initializeリクエストを送信
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# 期待されるレスポンス（抜粋）：
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":...}}
```

#### ツール一覧テスト

```bash
# 利用可能なツールのリストを取得
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | bin/kairos_mcp_server

# jqがある場合、ツール名のみを表示
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | bin/kairos_mcp_server 2>/dev/null | jq '.result.tools[].name'
```

#### Hello Worldテスト

```bash
# hello_worldツールを呼び出す
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 出力：Hello from KairosChain MCP Server!
```

### 2. スキルツールテスト

```bash
# スキル一覧を取得
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 特定のスキルを取得
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"skills_dsl_get","arguments":{"skill_id":"core_safety"}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 3. ブロックチェーンツールテスト

```bash
# ブロックチェーンステータスを確認
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# チェーンの整合性を検証
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 4. Claude Codeでのテスト

```bash
# Claude Codeを起動
claude

# Claude Codeでこれらのプロンプトを試す：
# "List the available KairosChain tools"
# "Run skills_dsl_list"
# "Check chain_status"
```

### 5. Cursorでのテスト

1. Cursorでプロジェクトを開く
2. チャットパネルを開く（Cmd/Ctrl + L）
3. これらのプロンプトを試す：
   - "List all KairosChain skills"
   - "Check the blockchain status"
   - "Show me the core_safety skill content"

### トラブルシューティング

#### サーバーが起動しない

```bash
# Rubyバージョンを確認
ruby --version  # 3.3+が必要

# 構文エラーを確認
ruby -c bin/kairos_mcp_server

# 実行権限を確認
ls -la bin/kairos_mcp_server
chmod +x bin/kairos_mcp_server
```

#### JSON-RPCエラー

```bash
# stderrでエラーメッセージを確認
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# stderrを抑制せずに実行（2>/dev/nullを削除）
```

#### Cursor接続の問題

1. `~/.cursor/mcp.json`のパスが絶対パスであることを確認
2. JSON構文を確認（カンマの欠落/過剰など）
3. Cursorを完全に終了して再起動

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
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server
```

#### 3. バックアップ

```bash
# storage/blockchain.jsonを定期的にバックアップ
cp storage/blockchain.json storage/backups/blockchain_$(date +%Y%m%d).json

# スキルバージョンもバックアップ
cp -r skills/versions skills/backups/versions_$(date +%Y%m%d)
```

#### 4. 複数のAIエージェント間での共有

同じ`blockchain.json`を共有することで、複数のAIエージェント間で進化履歴を同期できます。

```json
// ~/.cursor/mcp.json または ~/.claude.json で
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/shared/path/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {
        "KAIROS_STORAGE": "/shared/storage"
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

## 利用可能なツール（コア23個 + スキルツール）

基本インストールでは23個のツールが提供されます。`skill_tools_enabled: true`の場合、`kairos.rb`の`tool`ブロックで追加のツールを定義できます。

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

## 使用例

### 利用可能なスキルを一覧表示

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | bin/kairos_mcp_server
```

### ブロックチェーンステータスを確認

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server
```

### スキル遷移を記録

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["Skill X modified","Reason: improved accuracy"]}}}' | bin/kairos_mcp_server
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

## Pure Skills設計

### skills.md vs skills.rb

| 観点 | skills.md (Markdown) | skills.rb (Ruby DSL) |
|------|---------------------|---------------------|
| 性質 | 記述 | 定義 |
| 実行可能性 | ❌ 評価不可 | ✅ パース可能、検証可能 |
| 自己参照 | なし | `Kairos`モジュール経由 |
| 監査可能性 | Gitコミットのみ | ネイティブ（ASTベースの差分） |
| AIの役割 | 読者 | 構造の一部 |

### スキル定義の例

```ruby
skill :core_safety do
  version "1.0"
  title "Core Safety Rules"
  
  guarantees do
    immutable
    always_enforced
  end
  
  evolve do
    deny :all  # 変更不可
  end
  
  content <<~MD
    ## コア安全性不変条件
    1. 進化には明示的な有効化が必要
    2. デフォルトで人間の承認が必要
    3. すべての変更がブロックチェーン記録を作成
  MD
end
```

### 自己参照的内省

```ruby
skill :self_inspection do
  version "1.0"
  
  behavior do
    Kairos.skills.map do |skill|
      {
        id: skill.id,
        version: skill.version,
        can_evolve: skill.can_evolve?(:content)
      }
    end
  end
end
```

## ディレクトリ構造

```
KairosChain_mcp_server/
├── bin/
│   └── kairos_mcp_server         # 実行ファイル
├── config/
│   └── safety.yml                # セキュリティ設定
├── lib/
│   └── kairos_mcp/
│       ├── server.rb             # STDIOサーバー
│       ├── protocol.rb           # JSON-RPCハンドラー
│       ├── kairos.rb             # 自己参照モジュール
│       ├── safe_evolver.rb       # 安全性を伴う進化
│       ├── layer_registry.rb     # レイヤーアーキテクチャ管理
│       ├── anthropic_skill_parser.rb  # YAMLフロントマター + MDパーサー
│       ├── knowledge_provider.rb # L1知識管理
│       ├── context_manager.rb    # L2コンテキスト管理
│       ├── kairos_chain/         # ブロックチェーン実装
│       │   ├── block.rb
│       │   ├── chain.rb
│       │   ├── merkle_tree.rb
│       │   └── skill_transition.rb
│       ├── state_commit/         # StateCommitモジュール
│       │   ├── manifest_builder.rb
│       │   ├── snapshot_manager.rb
│       │   ├── diff_calculator.rb
│       │   ├── pending_changes.rb
│       │   └── commit_service.rb
│       └── tools/                # MCPツール（コア23個）
│           ├── skills_*.rb       # L0ツール
│           ├── knowledge_*.rb    # L1ツール
│           ├── context_*.rb      # L2ツール
│           └── state_*.rb        # StateCommitツール
├── skills/                       # L0：Kairosコア
│   ├── kairos.md                 # L0-A：哲学（読み取り専用）
│   ├── kairos.rb                 # L0-B：メタルール（Ruby DSL）
│   ├── config.yml                # レイヤーと進化の設定
│   └── versions/                 # バージョンスナップショット
├── knowledge/                    # L1：プロジェクト知識（Anthropicフォーマット）
│   └── example_knowledge/
│       ├── example_knowledge.md  # YAMLフロントマター + Markdown
│       ├── scripts/              # 実行可能スクリプト
│       ├── assets/               # テンプレート、リソース
│       └── references/           # 参考資料
├── context/                      # L2：一時的コンテキスト（Anthropicフォーマット）
│   └── session_xxx/
│       └── hypothesis/
│           └── hypothesis.md
├── storage/
│   ├── blockchain.json           # チェーンデータ
│   └── off_chain/                # AST差分、理由
├── test_local.rb                 # ローカルテストスクリプト
└── README.md
```

## Meeting Place (MMP)

**Meeting Place** は、複数のKairosChainインスタンスが互いを発見し、接続し、スキルを交換できるようにするオプションの通信機能です。AIエージェント間通信のために設計されたオープン標準 **Model Meeting Protocol (MMP)** に基づいています。

### 主要コンセプト

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Meeting Place Server                              │
│                  （集合場所 / リレーノード）                           │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────────┐  │
│  │ レジストリ  │  │ スキルストア │  │ メッセージリレー（E2E暗号化）│  │
│  └─────────────┘  └─────────────┘  └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
         ▲                 ▲                       ▲
         │                 │                       │
    ┌────┴─────┐     ┌─────┴─────┐          ┌─────┴─────┐
    │ Agent A  │     │  Agent B  │          │  Agent C  │
    │ (Cursor) │     │  (Claude) │          │  (Other)  │
    └──────────┘     └───────────┘          └───────────┘
```

### 機能

| 機能 | 説明 |
|------|------|
| **エージェント発見** | Meeting Place経由で他のKairosChainインスタンスを発見 |
| **スキル交換** | エージェント間でスキルを共有・取得（承認付き） |
| **2つのモード** | **リレーモード**（Meeting Place経由）または**ダイレクトモード**（P2P） |
| **E2E暗号化** | リレーされるすべてのメッセージは暗号化され、Meeting Placeは内容を読めない |
| **Protocol as Skill** | プロトコル定義自体がスキルと同じ仕組みで進化可能 |

### クイックスタート

1. `config/meeting.yml` で **Meeting Protocolを有効化**:
   ```yaml
   meeting_protocol:
     enabled: true
   ```

2. **Meeting Place Serverを起動**（または共有サーバーを使用）:
   ```bash
   cd KairosChain_mcp_server
   bin/kairos_meeting_place -p 4568
   ```

3. **Cursor/Claude Codeから接続**:
   ```
   「http://localhost:4568 のMeeting Placeに接続して」
   ```

4. **スキルの発見と交換**:
   ```
   「Meeting Placeにいるエージェントを表示して」
   「Agent-Bのbioinformatics_workflowスキルの詳細を見せて」
   「そのスキルを取得して」
   ```

### ドキュメント

詳細な使い方、設定、CLIコマンド、トラブルシューティングについては以下を参照してください：

| ドキュメント | 説明 |
|-------------|------|
| **[Meeting Place ユーザーガイド (JP)](docs/Meeting_Place_User_Guide_jp.md)** | 完全な使用ガイド |
| **[Meeting Place User Guide (EN)](docs/Meeting_Place_User_Guide_en.md)** | Complete usage guide |
| [MMP仕様書ドラフト](docs/MMP_Specification_Draft_v1.0.md) | プロトコル仕様 |
| [MMP技術論文](docs/MMP_Technical_Short_Paper_20260130_jp.md) | 学術論文 |
| [E2E暗号化ガイド](docs/meeting_protocol_e2e_encryption_guide.md) | セキュリティ詳細 |

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
2. HTTP/WebSocket API（リモートアクセス）
3. サーバー間通信プロトコル
4. 分散合意メカニズム
5. L0分散ガバナンス

詳細なビジョンドキュメント: [分散KairosChainネットワーク構想](docs/distributed_kairoschain_vision_20260128_jp.md)

### Model Meeting Protocol (MMP)

MMPは「Protocol as Skill」パラダイムを実装したエージェント間通信のオープン標準です。プロトコル定義自体がエージェント間の相互作用を通じて進化できます。

**主要機能**：
- エージェント発見とメッセージリレーのための Meeting Place Server
- E2E暗号化（ルーターに徹する設計）
- 交換可能なスキルとしてのプロトコル拡張（L0/L1/L2レイヤー化）
- 人間承認を伴う制御された共進化

**ドキュメント**：
- [Meeting Place ユーザーガイド](docs/Meeting_Place_User_Guide_jp.md) — CLIコマンド、設定、FAQ
- [MMP仕様書ドラフト](docs/MMP_Specification_Draft_v1.0.md) — プロトコル仕様
- [MMP技術論文](docs/MMP_Technical_Short_Paper_20260130_jp.md) — MMPに関する学術論文
- [E2E暗号化ガイド](docs/meeting_protocol_e2e_encryption_guide.md) — セキュリティ詳細

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
cd KairosChain_mcp_server
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server
```

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

**A:** 現在の実装はstdio経由のローカル利用に限定されています。チーム利用には以下の選択肢があります：

| 方式 | 追加実装 | 適合規模 |
|------|----------|----------|
| **Git共有** | 不要 | 小規模チーム（2-5人） |
| **SSHトンネリング** | 不要 | LANチーム（2-10人） |
| **HTTP API化** | 必要 | 中規模チーム（5-20人） |
| **MCP over SSE** | 必要 | リモート接続が必要な場合 |

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
           "cd /path/to/KairosChain_mcp_server && ruby bin/kairos_mcp_server"
         ]
       }
     }
   }
   ```

   **Claude Codeの場合:**
   ```bash
   claude mcp add kairos-chain ssh -- -o StrictHostKeyChecking=accept-new user@server.local "cd /path/to/KairosChain_mcp_server && ruby bin/kairos_mcp_server"
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

**HTTP API化が必要な場合:**
- リアルタイム同期が必要
- 認証・認可が必要
- 同時編集のコンフリクト解決が必要

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

---

## ライセンス

[LICENSE](./LICENSE)ファイルを参照してください。

---

**バージョン**: 0.9.0  
**最終更新**: 2026-02-01

> *「KairosChainは『この結果は正しいか？』ではなく『この知性はどのように形成されたか？』に答えます」*
