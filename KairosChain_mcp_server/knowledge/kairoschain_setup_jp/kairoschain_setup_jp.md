---
name: kairoschain_setup_jp
description: KairosChainのインストール、設定、テスト手順
version: 1.0
layer: L1
tags: [documentation, readme, setup, installation, configuration, testing]
readme_order: 2
readme_lang: jp
---

## セットアップ

### 前提条件

- Ruby 3.0+（基本機能は標準ライブラリのみ使用、gem不要）
- Claude Code CLI（`claude`）またはCursor IDE

### インストール

KairosChainは**Ruby gem**（推奨）または**リポジトリのクローン**でインストールできます。

#### オプションA：gemとしてインストール（推奨）

```bash
# gemをインストール
gem install kairos_mcp

# データディレクトリを初期化（現在のディレクトリに .kairos/ を作成）
kairos_mcp_server init

# または特定のパスに初期化
kairos_mcp_server init --data-dir /path/to/my-kairos-data

# 基本動作をテスト
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos_mcp_server
```

gemにはランタイム依存関係はありません。オプション機能（SQLite、RAG、HTTP）は追加のgemをインストールすることで利用できます — 以下のオプションセクションを参照してください。

**データディレクトリの解決順序**（優先度順）：
1. `--data-dir` CLIオプション
2. `KAIROS_DATA_DIR` 環境変数
3. 現在のディレクトリの `.kairos/`

#### オプションB：リポジトリをクローン

```bash
# リポジトリをクローン
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server

# 実行可能にする
chmod +x bin/kairos_mcp_server

# 基本動作をテスト
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server
```

> **注意**: リポジトリから実行する場合、データディレクトリはデフォルトで現在のディレクトリの `.kairos/` になります。データディレクトリが存在しない場合、サーバーは初回起動時に自動初期化します。

### オプション：RAG（セマンティック検索）サポート

KairosChainはベクトル埋め込みを使用したオプションのセマンティック検索をサポートしています。これにより、完全なキーワード一致ではなく意味でスキルを検索できます（例：「認証」で検索すると「ログイン」や「パスワード」に関するスキルも見つかります）。

**RAG gemなし:** 正規表現ベースのキーワード検索（デフォルト、インストール不要）  
**RAG gemあり:** 文章埋め込みを使用したセマンティックベクトル検索

#### 必要要件

- C++コンパイラ（ネイティブ拡張のため）
- ~90MBのディスク容量（埋め込みモデル用、初回使用時にダウンロード）

#### インストール

```bash
# gemの場合：
gem install hnswlib informers

# リポジトリの場合（Bundler使用）：
cd KairosChain_mcp_server
bundle install --with rag
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

設定ファイルのRAG設定（gemの場合 `<data-dir>/skills/config.yml`、リポジトリの場合 `skills/config.yml`）：

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
# RAG gemが利用可能か確認
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# gem版でRAGをテスト（L0スキルのセマンティック検索）
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | kairos_mcp_server

# リポジトリ版でRAGをテスト
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | bin/kairos_mcp_server
```

> **注意**: 初回のRAG検索では埋め込みモデル（~90MB）のダウンロードとベクトルインデックスの構築が行われます。以降の検索は高速です。

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
# gemの場合：
gem install sqlite3

# リポジトリの場合（Bundler使用）：
cd KairosChain_mcp_server
bundle install --with sqlite
```

#### 設定

設定ファイルを編集してSQLiteを有効化（gemの場合 `<data-dir>/skills/config.yml`、リポジトリの場合 `skills/config.yml`）：

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

# gem版でテスト
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server

# リポジトリ版でテスト
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server
```

#### SQLiteからファイルへのエクスポート

SQLiteのデータを人間が読めるファイルにエクスポートしてバックアップや検査ができます：

```ruby
# Rubyコンソールまたはスクリプトで
require 'kairos_mcp/storage/exporter'  # gem版
# または: require_relative 'lib/kairos_mcp/storage/exporter'  # リポジトリ版

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
# チェーンステータスを確認（gem版 / リポジトリ版）
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# チェーンの整合性を検証
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
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

### オプション：Streamable HTTPトランスポート（リモート/チームアクセス）

デフォルトではKairosChainはstdioトランスポート（ローカルプロセス）を使用します。リモートアクセスやチーム共有のために、オプションでStreamable HTTPトランスポートとBearerトークン認証を有効化できます。

**デフォルト（stdio）:** stdin/stdout経由のローカルプロセス、追加設定不要  
**Streamable HTTP:** `POST /mcp`経由のリモートアクセス、Bearerトークン認証、チーム共有

#### HTTPトランスポートを使うべきタイミング

| シナリオ | 推奨トランスポート |
|----------|-------------------|
| 個人開発者（ローカルのCursor/Claude Code） | stdio（デフォルト） |
| 単一のKairosChainインスタンスをチーム共有 | **Streamable HTTP** |
| ネットワーク越しのリモートアクセス | **Streamable HTTP** |
| HTTP経由のCI/CD統合 | **Streamable HTTP** |

#### インストール

```bash
# gemの場合：
gem install puma rack

# リポジトリの場合（Bundler使用）：
cd KairosChain_mcp_server
bundle install --with http

# フルチームセットアップ（HTTP + 同時アクセス用SQLite）：
gem install puma rack sqlite3          # gem版
bundle install --with http sqlite      # またはBundler版

# インストール確認
ruby -e "require 'puma'; require 'rack'; puts 'HTTP transport gems installed!'"
```

#### 使用するgem

| Gem | バージョン | 用途 |
|-----|-----------|------|
| `puma` | ~> 6.0 | 高性能並行Webサーバー |
| `rack` | ~> 3.0 | モジュラーRuby Webサーバーインターフェース |

#### クイックスタート

```bash
# gem版の場合：
kairos_mcp_server --init-admin
kairos_mcp_server --http --port 8080

# リポジトリ版の場合：
ruby bin/kairos_mcp_server --init-admin
ruby bin/kairos_mcp_server --http --port 8080

# curlでテスト（別ターミナルで）
curl http://localhost:8080/health
```

#### セットアップ手順

**ステップ1: 管理者トークンの生成**

```bash
# gem版：
kairos_mcp_server --init-admin

# リポジトリ版：
ruby bin/kairos_mcp_server --init-admin
```

出力：
```
============================================================
  KairosChain Admin Token Generated
============================================================

  Token: kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  User:  admin
  Role:  owner
  Expires: 2026-05-13T10:00:00+01:00

  IMPORTANT: Store this token securely.
  It will NOT be shown again.
============================================================
```

**ステップ2: HTTPサーバーの起動**

```bash
# gem版：
kairos_mcp_server --http                                    # デフォルトポート8080
kairos_mcp_server --http --port 9090                        # カスタムポート
kairos_mcp_server --http --port 8080 --data-dir /path/to/data  # カスタムデータディレクトリ

# リポジトリ版：
ruby bin/kairos_mcp_server --http
ruby bin/kairos_mcp_server --http --port 9090
ruby bin/kairos_mcp_server --http --host 127.0.0.1 --port 8080
```

**ステップ3: Cursorからの接続設定**

`~/.cursor/mcp.json`に追加：

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

保存後にCursorを再起動してください。

#### HTTPトランスポートのテスト

**ユニットテスト（gem不要）：**

```bash
ruby test_http.rb
```

**インテグレーションテスト（puma + rack必要）：**

```bash
ruby test_http.rb --integration
```

**curlによる手動テスト：**

```bash
# ヘルスチェック（認証不要）
curl http://localhost:8080/health

# MCP初期化（認証あり）
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <トークン>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# ツール一覧
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <トークン>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# ツール呼び出し
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <トークン>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{"name":"HTTP"}}}'
```

#### トークン管理

初期セットアップ後は`token_manage` MCPツールでトークンを管理できます：

```bash
# チームメンバーのトークンを作成
token_manage command="create" user="alice" role="member"

# アクティブなトークンを一覧表示
token_manage command="list"

# トークンをローテーション（旧トークンを失効、新トークンを発行）
token_manage command="rotate" user="alice"

# トークンを失効
token_manage command="revoke" user="alice"
```

**トークンロール（Phase 1: 全ロールが同等のアクセス権）：**

| ロール | 説明 | Phase 2での権限 |
|--------|------|----------------|
| `owner` | システム管理者 | フルアクセス + トークン管理 |
| `member` | チームメンバー | L1/L2書き込み、L0読み取り専用 |
| `guest` | 外部コラボレーター | 読み取り専用、自分のL2のみ |

**トークンの有効期限：**

| 期間 | オプション | 用途 |
|------|----------|------|
| 90日（デフォルト） | `expires_in="90d"` | Cursorでの日常利用 |
| 24時間 | `expires_in="24h"` | CI/CD、一時アクセス |
| 7日 | `expires_in="7d"` | 短期コラボレーション |
| 無期限 | `expires_in="never"` | ownerトークンのみ |

#### CLIオプション

```
Usage: kairos_mcp_server [command] [options]

コマンド:
    init              データディレクトリをデフォルトテンプレートで初期化
    upgrade           gem更新後のテンプレートマイグレーションをプレビュー
    upgrade --apply   テンプレートマイグレーションを適用

オプション:
    --data-dir DIR  データディレクトリのパス（デフォルト: カレントディレクトリの .kairos/）
    --http          Streamable HTTPモードで起動（デフォルト: stdio）
    --port PORT     HTTPポート（デフォルト: 8080）
    --host HOST     HTTPバインドホスト（デフォルト: 0.0.0.0）
    --init-admin    初期管理者トークンを生成して終了
    --token-store PATH  トークンストアファイルのパス
    -v, --version   バージョン表示
    -h, --help      ヘルプ表示

環境変数:
    KAIROS_DATA_DIR   データディレクトリのパスを上書き
```

#### 本番環境でのHTTPSデプロイ

本番運用では、Pumaの前段にリバースプロキシを配置してTLS/HTTPSを処理します。Puma内部はプレーンHTTPのみを処理し、リバースプロキシがSSLを終端します。

```
クライアント (Cursor) ──HTTPS──▶ リバースプロキシ ──HTTP──▶ Puma (:8080)
                                 (Caddy/Nginx)
                                 TLS終端
```

**オプションA: Caddy（推奨 — 最もシンプル）**

CaddyはLet's Encrypt証明書による自動HTTPS（TLSの設定不要）を提供します。

```bash
# Caddyをインストール
# macOS
brew install caddy

# Ubuntu/Debian
sudo apt install -y caddy

# その他: https://caddyserver.com/docs/install
```

`Caddyfile`を作成：

```
kairos.example.com {
    reverse_proxy localhost:8080
}
```

Caddyを起動：

```bash
# フォアグラウンド（テスト用）
caddy run

# サービスとして（本番）
sudo systemctl enable --now caddy
```

これだけです。Caddyは自動的に：
- `kairos.example.com`のLet's Encrypt証明書を取得
- 有効期限前に自動更新
- HTTPからHTTPSへリダイレクト
- TLS終端を処理

**オプションB: Nginx**

既にNginxが利用可能な環境やNginxを好む場合。

```bash
# Nginx + Certbotをインストール
# macOS
brew install nginx

# Ubuntu/Debian
sudo apt install -y nginx certbot python3-certbot-nginx
```

Nginx設定を作成（`/etc/nginx/sites-available/kairos`）：

```nginx
server {
    listen 80;
    server_name kairos.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

有効化してSSL証明書を取得：

```bash
# サイトを有効化
sudo ln -s /etc/nginx/sites-available/kairos /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Let's Encrypt証明書を取得（Nginx設定を自動更新）
sudo certbot --nginx -d kairos.example.com
```

CertbotがNginx設定にSSLを自動追加し、自動更新をセットアップします。

**オプションC: 自己署名証明書（LAN / 開発用）**

公開ドメインがないLANチームや開発環境の場合：

```bash
# 自己署名証明書を生成（1年間有効）
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes -subj "/CN=kairos.local"
```

Caddyで自己署名証明書を使用：

```
kairos.local {
    tls /path/to/certs/cert.pem /path/to/certs/key.pem
    reverse_proxy localhost:8080
}
```

Nginxで自己署名証明書を使用：

```nginx
server {
    listen 443 ssl;
    server_name kairos.local;

    ssl_certificate /path/to/certs/cert.pem;
    ssl_certificate_key /path/to/certs/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Cursorの設定（HTTPS）**

HTTPSをセットアップ後、`~/.cursor/mcp.json`を更新：

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "https://kairos.example.com/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

**Caddy vs Nginxの比較**

| 観点 | Caddy | Nginx |
|------|-------|-------|
| HTTPSセットアップ | 自動（設定不要） | 手動（certbot必要） |
| 証明書更新 | 自動 | 自動（certbotタイマー経由） |
| 設定 | シンプルなCaddyfile | より冗長 |
| パフォーマンス | 良好 | 優秀（実績あり） |
| 推奨場面 | 新規セットアップ、シンプルさ重視 | 既存Nginxインフラがある場合 |

#### 設定

`skills/config.yml`のHTTP設定：

```yaml
http:
  enabled: false                          # trueに設定、または--httpフラグを使用
  port: 8080                              # HTTPリッスンポート
  host: "0.0.0.0"                         # バインドアドレス
  token_store: "storage/tokens.json"      # トークンストレージパス
  default_token_expiry_days: 90           # デフォルトのトークン有効期限
```

#### テスト後のクリーンアップ

生成されたファイルはすべて`.gitignore`に含まれています。クリーンアップ方法：

```bash
cd KairosChain_mcp_server

rm -f storage/tokens.json       # 生成されたトークン
rm -rf vendor/bundle vendor/    # ローカルインストールしたgem
rm -rf .bundle/                 # Bundlerキャッシュ
rm -f Gemfile.lock              # ロックファイル
```

クリーンな状態を確認: `git status`が`working tree clean`と表示されるはず。

#### 将来のフェーズ（未実装）

**Phase 2: ロールベース認可**
- ロール別のレイヤー固有権限（owner/member/guest）
- 動的ツール更新のための`notifications/tools/list_changed`
- ユーザー単位の権限オーバーライド

**Phase 3: ウォレット / JWT統合（GenomicsChain）**
- GenomicsChain Rails APIが発行するJWTトークン
- ウォレットベース認証（MetaMask署名）
- PoC（Proof of Contribution）トークンシステムとの統合

---

### 管理者UI（ブラウザベースの管理画面）

HTTPモードで実行中の場合、KairosChainは`/admin`に組み込みのブラウザベース管理UIを提供します。サーバー管理者向けの軽量な管理画面であり、追加のフレームワークやgemは不要です。

#### 管理者UIへのアクセス

1. HTTPサーバーを起動: `kairos_mcp_server --http`（gem版）または `ruby bin/kairos_mcp_server --http`（リポジトリ版）
2. ブラウザで `http://localhost:8080/admin` を開く
3. `owner`ロールのBearerトークンでログイン

#### 利用可能な画面

| 画面 | パス | 用途 |
|------|------|------|
| **ダッシュボード** | `/admin` | チェーン状態、トークン数、L0/L1概要、StateCommit状況 |
| **トークン** | `/admin/tokens` | Bearerトークンの作成、一覧、失効、ローテーション |
| **チェーン** | `/admin/chain` | ブロック履歴の閲覧、ブロック詳細、チェーン整合性の検証 |
| **スキル** | `/admin/skills` | L0 DSLスキルとその定義の表示（読み取り専用） |
| **ナレッジ** | `/admin/knowledge` | L1知識エントリの閲覧と検索（読み取り専用） |
| **設定** | `/admin/config` | 設定、レイヤー設定、ストレージ情報の表示（読み取り専用） |

#### 技術的な詳細

- **技術**: htmx + PicoCSS + ERB（Ruby標準ライブラリ）— 新規gemは不要
- **認証**: セッションCookie（HMAC-SHA256署名）で既存のBearerトークンをラップ
- **認可**: `owner`ロールのみ — 他のロールはログイン画面にリダイレクト
- **CSRF保護**: すべてのPOSTリクエストにトークンベースの保護
- **データソース**: 既存のツールクラスを直接呼び出し（MCPプロトコルのオーバーヘッドなし）
- **同一プロセス**: 既存のPuma/Rack HTTPサーバー内で動作

#### 設計思想

管理者UIは意図的にミニマルです。これは**Phase 1の管理ツール**です（[MCP-to-SaaS開発ワークフロー](KairosChain_mcp_server/knowledge/mcp_to_saas_development_workflow/mcp_to_saas_development_workflow.md)を参照）。より高機能なUIが必要な場合は、Backend APIとMCPツールを利用するカスタムSaaSフロントエンドを構築してください。

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
# gem版の場合（推奨）：
claude mcp add kairos-chain kairos_mcp_server

# リポジトリ版の場合：
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos_mcp_server

# カスタムデータディレクトリを指定する場合：
claude mcp add kairos-chain kairos_mcp_server -- --data-dir /path/to/my-kairos-data
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
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

リポジトリ版の場合：

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
   - **gem版の場合：**
     - Name: `kairos-chain`
     - Command: `kairos_mcp_server`
     - Args: `--data-dir /path/to/my-kairos-data`（オプション）
   - **リポジトリ版の場合：**
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

**gem版の場合（推奨）：**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

**リポジトリ版の場合：**

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
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/Users/yourname/.kairos"],
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

## Gemのアップグレード

`kairos_mcp`の新バージョンがリリースされた場合（新しいスキル、設定キー、バグ修正など）、gemコード自体の更新は簡単です：

```bash
gem update kairos_mcp
```

ただし、データディレクトリ（`.kairos/`）にはinit時にコピーされたテンプレートファイルが含まれており、ユーザーによってカスタマイズされている可能性があります。内蔵のアップグレードシステムは**3-way hash比較**を使用して、これらのファイルを安全にマイグレーションします。

### 仕組み

アップグレードシステムは各テンプレートファイルの3つのバージョンを比較します：
- **オリジナル**: init時に`.kairos_meta.yml`に記録されたテンプレートハッシュ
- **現在**: データディレクトリ内のユーザーバージョン（カスタマイズされている可能性）
- **新規**: gemに同梱された最新テンプレート

この比較に基づき、各ファイルを分類します：

| パターン | ユーザー変更? | テンプレート変更? | アクション |
|---------|-------------|-----------------|---------|
| 0 (変更なし) | いいえ | いいえ | 何もしない |
| 1 (自動更新可) | いいえ | はい | 安全に自動更新 |
| 2 (ユーザー変更のみ) | はい | いいえ | ユーザー版を保持 |
| 3 (コンフリクト) | はい | はい | マージ/レビューが必要 |

**config系YAMLファイル**（パターン3）の場合、構造的マージにより新しいキーを追加しつつユーザーの値を保持します。**L0 kairos.rb**（パターン3）の場合、`skills_evolve`提案が生成され、人間による承認とブロックチェーン記録が必要です。

### アップグレードコマンド

#### CLI経由

```bash
# 変更内容のプレビュー（推奨される最初のステップ）
kairos_mcp_server upgrade

# アップグレードの適用
kairos_mcp_server upgrade --apply

# カスタムデータディレクトリの場合
kairos_mcp_server upgrade --data-dir /path/to/data --apply
```

#### MCPツール経由（AIセッション内から）

```
system_upgrade command="check"       # クイックバージョンチェック
system_upgrade command="preview"     # 詳細なファイル別分析
system_upgrade command="apply" approved=true   # アップグレード適用
system_upgrade command="status"      # 現在のメタ状態を表示
```

### バージョン不一致の警告

MCPサーバーの起動時にgemとデータディレクトリのバージョン不一致を検出すると、警告が表示されます：

```
[KairosChain] Data directory was initialized with v0.9.0, current gem is v0.10.0.
[KairosChain] Run 'system_upgrade command="check"' or 'kairos_mcp_server upgrade' to see available updates.
```

### アップグレードワークフロー

1. gemを更新: `gem update kairos_mcp`
2. 変更をプレビュー: `kairos_mcp_server upgrade`
3. 出力を確認（特にコンフリクトに注意）
4. 適用: `kairos_mcp_server upgrade --apply`
5. L0提案については`skills_evolve`を使用してレビュー・承認
6. MCPサーバーを再起動

すべてのアップグレード操作はトレーサビリティのためKairosChainブロックチェーンに記録されます。

---

## セットアップのテスト

> **注意**: 以下の例ではgem版のコマンド（`kairos_mcp_server`）とリポジトリ版のコマンド（`bin/kairos_mcp_server`）の両方を示しています。インストール方法に応じて使い分けてください。

### 1. 基本的なコマンドラインテスト

#### 初期化テスト

```bash
# gem版：
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos_mcp_server

# リポジトリ版：
cd /path/to/KairosChain_mcp_server
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# 期待されるレスポンス（抜粋）：
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":...}}
```

#### ツール一覧テスト

```bash
# 利用可能なツールのリストを取得
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos_mcp_server

# jqがある場合、ツール名のみを表示
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos_mcp_server 2>/dev/null | jq '.result.tools[].name'
```

#### Hello Worldテスト

```bash
# hello_worldツールを呼び出す
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 出力：Hello from KairosChain MCP Server!
```

### 2. スキルツールテスト

```bash
# スキル一覧を取得
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 特定のスキルを取得
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"skills_dsl_get","arguments":{"skill_id":"core_safety"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 3. ブロックチェーンツールテスト

```bash
# ブロックチェーンステータスを確認
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# チェーンの整合性を検証
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 4. SQLiteバックエンドのテスト（オプション）

```bash
# 1. sqlite3 gemをインストール
gem install sqlite3

# 2. 設定でSQLiteを有効化
#    <data-dir>/skills/config.yml の storage.backend を 'file' から 'sqlite' に変更

# 3. chain_statusをテスト（SQLiteバックエンド情報が表示されるはず）
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 4. 記録と検証
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["SQLite test record"]}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 5. RAG / セマンティック検索のテスト（オプション）

```bash
# 1. RAG gemをインストール
gem install hnswlib informers

# 2. gemが利用可能か確認
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# 3. 設定でRAGを有効化
#    <data-dir>/skills/config.yml の vector_search.enabled を true に設定

# 4. セマンティック検索をテスト（初回は ~90MB の埋め込みモデルをダウンロード）
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety rules"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 5. 知識検索をテスト
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"knowledge_list","arguments":{"query":"layer placement"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 6. HTTPモードのテスト（オプション）

```bash
# 1. HTTP gemをインストール
gem install puma rack

# 2. データを初期化して管理者トークンを生成
kairos_mcp_server init --data-dir /tmp/kairos_test
kairos_mcp_server --init-admin --data-dir /tmp/kairos_test
# 表示されたトークンを保存！

# 3. HTTPサーバーを起動
kairos_mcp_server --http --port 9090 --data-dir /tmp/kairos_test

# 4. 別ターミナルからテスト
curl http://localhost:9090/health

curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <あなたのトークン>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

### 7. Claude Codeでのテスト

```bash
# Claude Codeを起動
claude

# Claude Codeでこれらのプロンプトを試す：
# "List the available KairosChain tools"
# "Run skills_dsl_list"
# "Check chain_status"
```

### 8. Cursorでのテスト

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
ruby --version  # 3.0+が必要

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

#### gemコマンドが見つからない

```bash
# gem installの後でkairos_mcp_serverが見つからない場合
# gem binディレクトリがPATHに含まれているか確認
gem environment gemdir
# 実行ファイルはそのパスの bin/ ディレクトリにあるはず

# rbenvユーザーはrehashが必要な場合があります
rbenv rehash

# 正しいRubyバージョンにgemがインストールされているか確認
gem list kairos_mcp
```

#### Cursor接続の問題

1. `~/.cursor/mcp.json`のパスが絶対パスであることを確認（リポジトリ版の場合）
2. JSON構文を確認（カンマの欠落/過剰など）
3. Cursorを完全に終了して再起動

---
