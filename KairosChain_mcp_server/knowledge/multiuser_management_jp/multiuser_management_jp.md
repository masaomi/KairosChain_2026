---
name: multiuser_management_jp
description: "Multiuser SkillSet — PostgreSQL、RBAC、テナント分離によるマルチテナントユーザー管理"
version: 1.0
layer: L1
tags: [documentation, readme, multiuser, postgresql, rbac, tenant, authentication]
readme_order: 4.8
readme_lang: jp
---

## Multiuser：マルチテナントユーザー管理

### Multiuser とは

Multiuser は、PostgreSQL バックエンドのストレージ、RBAC（ロールベースアクセス制御）、テナント分離によるマルチテナントユーザー管理を KairosChain に追加するオプトイン SkillSet です。各ユーザーは独自の PostgreSQL スキーマを持ち、テナント間のデータ完全分離を実現します。

Multiuser は 6 つの汎用フックを KairosChain コアに登録する SkillSet として実装されています（Option C アーキテクチャ）。新機能をコアではなく SkillSet として表現するという設計原則を保持しています。コアへの変更は後方互換性があり、Multiuser SkillSet がインストールされていない場合、KairosChain は従来と同一の動作をします。

### アーキテクチャ

```
KairosChain（MCP サーバー）
├── [core] L0/L1/L2 + プライベートブロックチェーン
│     ├── Backend.register()          ← フック1: ストレージバックエンドファクトリ
│     ├── Safety.register_policy()    ← フック2: RBACポリシー注入
│     ├── ToolRegistry.register_gate()← フック3: 認可ゲート
│     ├── Protocol.register_filter()  ← フック4: リクエストフィルタパイプライン
│     ├── TokenStore.register()       ← フック5: トークンストアファクトリ
│     └── KairosMcp.register_path_resolver() ← フック6: テナントパス解決
└── [SkillSet: multiuser] マルチテナントユーザー管理
      ├── PgConnectionPool     ← Mutex ベースの PostgreSQL コネクションプール
      ├── PgBackend            ← PostgreSQL 用 Storage::Backend 実装
      ├── TenantManager        ← スキーマ作成、マイグレーション、テナントライフサイクル
      ├── UserRegistry         ← ユーザーアカウント（テナント自動プロビジョニング）
      ├── TenantTokenStore     ← PostgreSQL バックエンドのトークンストア
      ├── AuthorizationGate    ← デフォルト拒否の RBAC 適用
      ├── RequestFilter        ← Bearer トークンからのテナント解決
      └── tools/               ← 3 つの MCP ツール
```

### 前提条件

- **PostgreSQL** サーバー（インストール済み・起動済み）
- **pg gem**: `gem install pg`（`libpq` — PostgreSQL クライアントライブラリが必要）

macOS（Homebrew）の場合：

```bash
brew install postgresql@16
brew services start postgresql@16
gem install pg
```

### クイックスタート

#### 1. Multiuser SkillSet のインストール

```bash
kairos-chain skillset install templates/skillsets/multiuser
```

#### 2. PostgreSQL 接続設定

`.kairos/skillsets/multiuser/config/multiuser.yml` を編集：

```yaml
postgresql:
  host: 127.0.0.1
  port: 5432
  dbname: kairoschain
  user: postgres
  password: ""
  pool_size: 5
  connect_timeout: 5

token_backend: postgresql
```

#### 3. データベース作成とマイグレーション実行

```bash
createdb kairoschain
```

MCP 経由で実行：

```
「マルチユーザーのマイグレーションを実行して」
→ multiuser_migrate(command: "run")
```

#### 4. 最初のユーザーを作成

```
「admin という名前の owner ユーザーを作成して」
→ multiuser_user_manage(command: "create", username: "admin", role: "owner")
```

#### 5. ステータス確認

```
「マルチユーザーのステータスを確認して」
→ multiuser_status()
```

### MCP ツール

| ツール | 説明 |
|--------|------|
| `multiuser_status` | 診断レポート：PostgreSQL 接続、テナント数、ユーザー数 |
| `multiuser_user_manage` | ユーザーライフサイクル：`list`、`create`、`delete`、`update_role` |
| `multiuser_migrate` | データベースマイグレーション：`status`、`run`、`dry_run` |

### コアフック（Option C：汎用フック）

Multiuser SkillSet は 6 つのフックを KairosChain コアに登録します。これらは汎用的な拡張ポイントであり、Multiuser 以外の SkillSet も利用できます。

| フック | コアクラス | 目的 |
|--------|-----------|------|
| 1 | `Storage::Backend.register` | `PgBackend` を `'postgresql'` ストレージバックエンドとして登録 |
| 2 | `Safety.register_policy` | `can_modify_l0`、`can_modify_l1`、`can_modify_l2`、`can_manage_tokens` の RBAC ポリシーを注入 |
| 3 | `ToolRegistry.register_gate` | 認可ゲート — 全ツール呼び出し前のデフォルト拒否チェック |
| 4 | `Protocol.register_filter` | 受信リクエストの Bearer トークンからテナント解決 |
| 5 | `Auth::TokenStore.register` | `TenantTokenStore` を `'postgresql'` トークンバックエンドとして登録 |
| 6 | `KairosMcp.register_path_resolver` | テナントごとの `knowledge/` と `context/` パス解決 |

全フックは `unregister` によるクリーンな解除をサポートしています。

### RBAC（ロールベースアクセス制御）

| ロール | L0（コア） | L1（知識） | L2（コンテキスト） | トークン管理 |
|--------|-----------|-----------|-------------------|-------------|
| **owner** | 読み書き | 読み書き | 読み書き | フルアクセス |
| **member** | 読み取りのみ | 読み書き | 読み書き | アクセス不可 |
| **guest** | 読み取りのみ | 読み取りのみ | 読み書き | アクセス不可 |

### グレースフルデグラデーション

Multiuser は各レベルで適切に機能低下するよう設計されています：

| 条件 | 動作 |
|------|------|
| pg gem 未インストール | `multiuser_status` が `pg_gem_missing` とインストール手順を返す |
| PostgreSQL 未起動 | `multiuser_status` が `pg_server_unavailable` とセットアップ手順を返す |
| PostgreSQL 設定エラー | `multiuser_status` が `pg_error` と設定ファイルの参照先を返す |
| その他のエラー | `rescue StandardError` でキャッチし、完全なコンテキストをログ出力 |

いずれの場合でも、3 つの Multiuser MCP ツールは登録・呼び出し可能な状態を維持し、クラッシュではなく診断情報を返します。他の KairosChain ツール（コア 34 個）は正常に動作し続けます。

### 設定

設定ファイル：`.kairos/skillsets/multiuser/config/multiuser.yml`

```yaml
postgresql:
  host: 127.0.0.1          # PostgreSQL ホスト
  port: 5432                # PostgreSQL ポート
  dbname: kairoschain       # データベース名
  user: postgres            # データベースユーザー
  password: ""              # データベースパスワード
  pool_size: 5              # コネクションプールサイズ
  connect_timeout: 5        # 接続タイムアウト（秒）

token_backend: postgresql   # トークンストレージバックエンド
```

データベーススキーマは共有テーブル（users、tokens、audit log）に `public`、ユーザーごとのデータ（blocks、action_logs、knowledge_meta）に `tenant_{id}` スキーマを使用します。
