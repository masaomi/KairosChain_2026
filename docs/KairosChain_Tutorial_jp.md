# KairosChain

AIスキルの進化をブロックチェーンで管理し、エージェント間通信を実現する次世代基盤

このチュートリアルでは、KairosChainの技術的構造、セットアップ、および最新のMMP（Model Meeting Protocol）を利用したエージェント間連携について解説します。

---

## 目次

1. KairosChain アーキテクチャ (L0 / L1 / L2)
2. セットアップ：Gem インストール vs クローン
3. MCPサーバーとしての動作原理
4. 自己言及性：AIが自らマニュアルを読み解く設計
5. MMP (Model Meeting Protocol)：エージェント間のスキル交換
6. スキル進化 (Evolution) のワークフロー
7. プラグイン・マーケットプレイスへの登録と利用
8. ディレクトリ構成とデータ永続化
9. 主要ツール・リファレンス

---

## 1. KairosChain アーキテクチャ (L0 / L1 / L2)

KairosChainは、情報の重要度と不変性に応じて、ナレッジを3つのレイヤーで管理します。

| レイヤー | 名称 | ファイルパス | 説明 |
|---|---|---|---|
| **L0-A** | 憲法 (Skills MD) | `skills/kairos.md` | KairosChain の根本思想。コードレベルで**変更不可**。 |
| **L0-B** | 法律 (Skills DSL) | `skills/kairos.rb` | 進化のルール自体を Ruby DSL で定義。変更には「人間の承認」と「完全なブロックチェーン記録」が必要。 |
| **L1** | 条例 (Knowledge) | `knowledge/` | チームで共有する技術スタックや規約。変更時には「データのハッシュ値」がチェーンに記録され、改ざんを防止。 |
| **L2** | 通達 (Context) | `context/` | 開発中の仮説やセッション固有の情報。チェーンには記録されず、AIが自由かつ高速に書き換え可能な作業領域。 |

レイヤーの判定は**ファイルのパスのみ**で行われます。`layer_registry.rb` がパスを見て自動的にレイヤーを決定するため、ファイル内にタグを書く必要はありません。

---

## 2. セットアップ：Gem インストール vs クローン

用途に合わせて2つの導入方法を選択できます。

### 方法A：Gem によるクイックインストール（推奨）

ツールとして利用・デプロイする場合に最適です。

```bash
# インストール
gem install kairos-chain

# プロジェクトの初期化（.kairos/ ディレクトリが作成されます）
kairos-chain init

# Claude Code に MCP サーバーとして登録
claude mcp add kairos-chain kairos-chain

# 登録確認
claude mcp list
```

### 方法B：GitHub からのクローン

KairosChain 自体の開発や、コアロジックのカスタマイズを行う場合に適しています。

```bash
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server
bundle install
chmod +x bin/kairos-chain

# Claude Code に MCP サーバーとして登録
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos-chain
```

---

## 3. MCPサーバーとしての動作原理

KairosChain は Model Context Protocol (MCP) に完全準拠しています。
Claude Code や Cursor などの MCP クライアントは、JSON-RPC を介して KairosChain の提供する「ツール」を呼び出します。

- **クライアント側**: 「この関数をL1知識に保存して」と依頼。
- **KairosChain側**: `knowledge_update` ツールを実行し、ハッシュを生成して blockchain に追記。

---

## 4. 自己言及性：AIが自らマニュアルを読み解く設計

KairosChain は、自分自身の設計図やマニュアルを Knowledge（L1）として内部に保持しています。
これにより、開発者がマニュアルを読み込まなくても、AIに「KairosChainのL0スキルの変更手順を教えて」と聞くだけで、AIが自律的に正しいコマンド（`skills_evolve` など）を選択できるようになります。

---

## 5. MMP (Model Meeting Protocol)：エージェント間のスキル交換

最新版で導入された **MMP (Model Meeting Protocol)** は、エージェント同士が「会議」を行い、動的にスキルを交換するための通信規格です。

1. **提案**: エージェントAが新しいスキル（MMP拡張など）を提案。
2. **合意**: エージェントBがそのスキルを検証し、自身の KairosChain に取り込む。
3. **実行**: 以降、両エージェントは新しい共通プロトコルで通信を開始。

これにより、ソースコードの変更なしにエージェント同士が自律的に連携ルールをアップデートできます。

さらに **HestiaChain**（`hestia` SkillSet）を導入すると、インターネット上の KairosChain エージェントが互いを発見し、スキルを共有できる「出会いの場（Meeting Place）」として機能します。

---

## 6. スキル進化 (Evolution) のワークフロー

L0スキルの変更は、以下の厳格なフローで行われます。

1. **Propose（提案）**: `skills/config.yml` で `evolution_enabled: true` に設定し、AIに変更を提案させます。
2. **Check（検証）**: 構文チェックや安全規則への適合を自動判定（5層バリデーション）。
3. **Human Approval（承認）**: 開発者が変更内容を確認し承認（`require_human_approval: true`）。
4. **Apply（適用）**: `skills/versions/` にスナップショットを保存し、ブロックチェーンに履歴を刻印して反映。

---

## 7. プラグイン・マーケットプレイスへの登録と利用

Claude Code 等のプラグインとして利用する場合、マーケットプレイス経由で管理できます。
フル機能を使うには **Ruby 3.0+** と gem のインストールが前提です。

```bash
# 前提：gem をインストール
gem install kairos-chain

# マーケットプレイスの追加
/plugin marketplace add https://github.com/masaomi/KairosChain_2026.git

# プラグインのインストール
/plugin install kairos-chain
```

これにより、開発環境（Claude Code / Cursor）と KairosChain がシームレスに結合されます。

---

## 8. ディレクトリ構成とデータ永続化

`kairos-chain init` を実行すると、以下の構造でデータディレクトリ（デフォルト: `.kairos/`）が作成されます。

```
.kairos/
├── skills/                        # L0: メタスキル定義
│   ├── kairos.md                  # L0-A: 根本思想（変更不可）
│   ├── kairos.rb                  # L0-B: DSLによるスキル定義（承認必須）
│   ├── config.yml                 # 進化・セキュリティ設定
│   └── versions/                  # 過去のスナップショット
├── knowledge/                     # L1: プロジェクト固有ナレッジ
├── context/                       # L2: セッション・コンテキスト
├── config/
│   ├── safety.yml                 # セキュリティ・ポリシー
│   └── tool_metadata.yml          # ツールメタデータ
└── storage/
    ├── embeddings/                # ベクトル検索インデックス（RAG用）
    │   ├── skills/
    │   └── knowledge/
    ├── snapshots/                 # state_commit のスナップショット
    └── export/                    # SQLite エクスポート
```

ブロックチェーンデータはデフォルトで `storage/` 以下に管理されます。ファイルバックエンド（デフォルト）と SQLite バックエンドの2種類から選択できます。

---

## 9. 主要ツール・リファレンス

利用可能なツールは 34 個以上あります。カテゴリ別の主要ツールは以下のとおりです。

| カテゴリ | ツール名 | 説明 |
|---|---|---|
| **Blockchain** | `chain_status` | 現在のハッシュ、ブロック高の確認 |
| **Blockchain** | `chain_verify` | 全ブロックの整合性検証（ハッシュチェック） |
| **Blockchain** | `chain_history` | ブロックチェーンの変更履歴を取得 |
| **Blockchain** | `chain_record` | 手動でブロックを記録 |
| **Blockchain** | `chain_export` / `chain_import` | チェーンデータのエクスポート・インポート |
| **Skills (L0)** | `skills_list` | 定義済みL0スキルの一覧取得 |
| **Skills (L0)** | `skills_dsl_get` | 特定スキルのDSL定義を取得 |
| **Skills (L0)** | `skills_evolve` | スキルの変更提案・承認・適用（要：人間） |
| **Skills (L0)** | `skills_promote` | L2 → L1 → L0 へのスキル昇格 |
| **Skills (L0)** | `skills_rollback` | スキルを過去バージョンに戻す |
| **Skills (L0)** | `skills_audit` | ナレッジの矛盾や陳腐化の自動検出 |
| **DSL/AST** | `definition_verify` | DSL定義の整合性をAST検証 |
| **DSL/AST** | `definition_drift` | スキル定義のドリフト（乖離）を検出 |
| **DSL/AST** | `definition_decompile` | バイナリ/スナップショットをDSLに逆コンパイル |
| **Knowledge (L1)** | `knowledge_update` | プロジェクト知識の追加・更新・ハッシュ記録 |
| **Knowledge (L1)** | `knowledge_get` / `knowledge_list` | 知識の取得・一覧表示 |
| **Context (L2)** | `context_save` | 一時的な作業ログの保存 |
| **State** | `state_commit` | 全レイヤーの一括スナップショット作成 |
| **State** | `state_status` / `state_history` | スナップショットの状態・履歴確認 |
| **Guide** | `tool_guide` | ツールの使い方ガイドを取得 |

---

KairosChainは、AI開発を「書き捨てのプロンプト」から「資産としてのスキル管理」へと変革します。
不具合の報告や新機能のプルリクエストは [GitHub リポジトリ](https://github.com/masaomi/KairosChain_2026) までお寄せください。
