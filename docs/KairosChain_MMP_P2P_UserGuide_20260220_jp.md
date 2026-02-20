# KairosChain MMP P2P Skill/SkillSet 交換ユーザーガイド

**日付**: 2026-02-20
**バージョン**: 1.0.0
**著者**: 畠山 正 博士
**ブランチ**: `feature/skillset-plugin`

---

## 目次

1. [概要](#1-概要)
2. [前提条件](#2-前提条件)
3. [セットアップ](#3-セットアップ)
4. [SkillSet管理（CLI）](#4-skillset管理cli)
5. [P2P 個別Skill交換](#5-p2p-個別skill交換)
6. [P2P SkillSet交換](#6-p2p-skillset交換)
7. [オフライン交換（CLI）](#7-オフライン交換cli)
8. [設定リファレンス](#8-設定リファレンス)
9. [セキュリティモデル](#9-セキュリティモデル)
10. [トラブルシューティング](#10-トラブルシューティング)

---

## 1. 概要

KairosChainは**Model Meeting Protocol (MMP)** を使用し、エージェントインスタンス間でのピアツーピア知識交換を実現します。2つのレベルの交換をサポートしています：

| レベル | 単位 | 内容 | ユースケース |
|--------|------|------|-------------|
| **Skill** | 単一Markdownファイル | YAML frontmatter付きの知識ファイル1件 | 特定のプロトコルやパターンの素早い共有 |
| **SkillSet** | パッケージ化ディレクトリ（tar.gz） | `skillset.json` + `knowledge/` + `config/` | バージョン管理された完全な知識パッケージの共有 |

どちらのレベルでも**knowledge-only制約**が適用されます：ネットワーク経由で交換できるのは、実行可能でないコンテンツ（Markdown、YAMLなど）のみです。コードを含むSkillSet（`tools/`、`lib/`内の`.rb`、`.py`、`.sh`など）は、信頼できるチャネル経由で手動インストールする必要があります。

### アーキテクチャ

```
エージェントA (KairosChain)              エージェントB (KairosChain)
┌─────────────────────┐                  ┌─────────────────────┐
│ HttpServer :8080    │                  │ HttpServer :9090    │
│  └─ MeetingRouter   │  HTTP/JSON       │  └─ MeetingRouter   │
│      /meeting/v1/*  │ ◄──────────────► │      /meeting/v1/*  │
│                     │                  │                     │
│ SkillSetManager     │                  │ SkillSetManager     │
│  └─ .kairos/        │                  │  └─ .kairos/        │
│     skillsets/      │                  │     skillsets/       │
│     knowledge/      │                  │     knowledge/       │
└─────────────────────┘                  └─────────────────────┘
```

---

## 2. 前提条件

- Ruby 3.0以上
- KairosChain MCPサーバー（`KairosChain_mcp_server/`）
- gem: `rack`, `puma`（HTTPモード用）

```bash
cd KairosChain_mcp_server
bundle install   # または: gem install rack puma
```

---

## 3. セットアップ

### 3.1 データディレクトリの初期化

各エージェントには独立したデータディレクトリが必要です：

```bash
# エージェントA
kairos-chain init --data-dir /path/to/agent_a/.kairos

# エージェントB
kairos-chain init --data-dir /path/to/agent_b/.kairos
```

### 3.2 MMP SkillSetのインストール

MMP SkillSetはテンプレートとして同梱されています。各エージェントにインストールします：

```bash
# エージェントA
kairos-chain skillset install templates/skillsets/mmp --data-dir /path/to/agent_a/.kairos

# エージェントB
kairos-chain skillset install templates/skillsets/mmp --data-dir /path/to/agent_b/.kairos
```

### 3.3 MMPの設定

`.kairos/skillsets/mmp/config/meeting.yml` を編集します：

```yaml
# MMPを有効化
enabled: true

# このエージェント固有のアイデンティティを設定
identity:
  name: "Agent Alpha"
  description: "ゲノミクス知識エージェント"
  scope: "bioinformatics"

# Skill交換設定
skill_exchange:
  public_by_default: true     # すべてのSkillをピアに公開
  allow_executable: false      # 実行可能コンテンツは決して受け入れない

# SkillSet交換設定
skillset_exchange:
  enabled: true
  knowledge_only: true         # knowledge-only SkillSetのみ交換
  auto_install: false          # 手動承認を要求
```

### 3.4 HTTPサーバーの起動

各エージェントを異なるポートで起動します：

```bash
# ターミナル1: エージェントAをポート8080で起動
kairos-chain --http --port 8080 --data-dir /path/to/agent_a/.kairos

# ターミナル2: エージェントBをポート9090で起動
kairos-chain --http --port 9090 --data-dir /path/to/agent_b/.kairos
```

---

## 4. SkillSet管理（CLI）

### インストール済みSkillSetの一覧

```bash
kairos-chain skillset list
```

出力例：
```
Installed SkillSets:

  mmp v1.0.0 [L1] (enabled)
    Model Meeting Protocol for P2P agent communication and skill exchange
    Tools: 4, Deps: none

  my_knowledge v1.0.0 [L2] (enabled)
    カスタム知識パック
    Tools: 0, Deps: none
```

### その他のコマンド

```bash
kairos-chain skillset info <名前>       # SkillSetの詳細情報を表示
kairos-chain skillset enable <名前>     # SkillSetを有効化
kairos-chain skillset disable <名前>    # SkillSetを無効化
kairos-chain skillset remove <名前>     # SkillSetを削除
```

---

## 5. P2P 個別Skill交換

個別のSkillは、エージェントの`knowledge/`ディレクトリに格納されたYAML frontmatter付きMarkdownファイルです。

### 5.1 共有可能なSkillの作成

`.kairos/knowledge/my_protocol/my_protocol.md` に知識ファイルを作成します：

```markdown
---
name: my_protocol
description: カスタム通信プロトコル
version: 1.0.0
tags:
  - protocol
  - custom
public: true
---

# My Protocol

プロトコルのルールとドキュメント...
```

`public: true` フラグにより、このSkillがピアから参照可能になります。

### 5.2 交換フロー（HTTP API）

**ステップ1 — 自己紹介**: エージェントBがエージェントAを発見します。

```bash
curl http://localhost:8080/meeting/v1/introduce
```

レスポンス：
```json
{
  "identity": {
    "name": "Agent Alpha",
    "instance_id": "abc123...",
    "protocol_version": "1.0.0"
  },
  "capabilities": { "skills": true, "skillsets": true },
  "skills": [
    {
      "id": "sha256-...",
      "name": "my_protocol",
      "layer": "L1",
      "format": "markdown",
      "tags": ["protocol", "custom"],
      "content_hash": "e3b0c4..."
    }
  ]
}
```

**ステップ2 — Skill一覧**: 公開されているすべてのSkillを一覧表示します。

```bash
curl http://localhost:8080/meeting/v1/skills
```

**ステップ3 — 詳細取得**: 特定のSkillの詳細を確認します。

```bash
curl "http://localhost:8080/meeting/v1/skill_details?skill_id=my_protocol"
```

**ステップ4 — コンテンツ取得**: Skillの全コンテンツをリクエストします。

```bash
curl -X POST http://localhost:8080/meeting/v1/skill_content \
  -H "Content-Type: application/json" \
  -d '{"skill_id": "my_protocol", "to": "agent-beta"}'
```

レスポンスには、コンテンツとハッシュ値を含むパッケージ化されたSkillが含まれます。

---

## 6. P2P SkillSet交換

SkillSet交換は、バージョン管理された知識パッケージ全体（複数ファイル、設定、メタデータ）を転送します。

### 6.1 Knowledge-Only SkillSetの作成

以下のディレクトリ構造を作成します：

```
my_knowledge_pack/
  skillset.json
  knowledge/
    topic_a/
      topic_a.md
    topic_b/
      topic_b.md
```

`skillset.json`:
```json
{
  "name": "my_knowledge_pack",
  "version": "1.0.0",
  "description": "ゲノミクス解析パターン集",
  "author": "あなたの名前",
  "layer": "L2",
  "depends_on": [],
  "provides": ["genomics_patterns"],
  "tool_classes": [],
  "config_files": [],
  "knowledge_dirs": ["knowledge/topic_a", "knowledge/topic_b"]
}
```

インストール：
```bash
kairos-chain skillset install ./my_knowledge_pack
```

### 6.2 交換フロー（HTTP API）

**ステップ1 — エージェントAの交換可能SkillSet一覧**:

```bash
curl http://localhost:8080/meeting/v1/skillsets
```

レスポンス：
```json
{
  "skillsets": [
    {
      "name": "my_knowledge_pack",
      "version": "1.0.0",
      "layer": "L2",
      "description": "ゲノミクス解析パターン集",
      "knowledge_only": true,
      "content_hash": "a1b2c3...",
      "file_count": 3
    }
  ],
  "count": 1
}
```

注: 実行可能コードを含むSkillSet（`mmp`自体など）は除外されます。

**ステップ2 — SkillSet詳細取得**:

```bash
curl "http://localhost:8080/meeting/v1/skillset_details?name=my_knowledge_pack"
```

ファイル一覧とコンテンツハッシュを含む完全なメタデータが返されます。

**ステップ3 — SkillSetアーカイブのダウンロード**:

```bash
curl -X POST http://localhost:8080/meeting/v1/skillset_content \
  -H "Content-Type: application/json" \
  -d '{"name": "my_knowledge_pack"}' \
  > received_package.json
```

レスポンス：
```json
{
  "skillset_package": {
    "name": "my_knowledge_pack",
    "version": "1.0.0",
    "content_hash": "a1b2c3...",
    "archive_base64": "H4sIAAAA...",
    "file_list": ["skillset.json", "knowledge/topic_a/topic_a.md", ...],
    "packaged_at": "2026-02-20T12:00:00Z"
  }
}
```

**ステップ4 — エージェントBにインストール**:

```bash
# CLIを使用（推奨）
kairos-chain skillset install-archive received_package.json \
  --data-dir /path/to/agent_b/.kairos

# または標準入力からパイプ
cat received_package.json | kairos-chain skillset install-archive - \
  --data-dir /path/to/agent_b/.kairos
```

インストーラーは自動的に以下を実行します：
1. SkillSet名の検証（安全な文字のみ）
2. パストラバーサル保護付きでアーカイブを展開
3. コンテンツハッシュの一致を検証
4. 実行可能コードがないことを確認
5. `.kairos/skillsets/my_knowledge_pack/` にインストール

---

## 7. オフライン交換（CLI）

HTTPサーバーを起動せずに、CLIの`package`と`install-archive`コマンドでSkillSetを交換できます。

### エクスポート（エージェントA）

```bash
kairos-chain skillset package my_knowledge_pack > my_knowledge_pack.json
```

`my_knowledge_pack.json` を任意の方法（USB、メール、scpなど）で転送します。

### インポート（エージェントB）

```bash
kairos-chain skillset install-archive my_knowledge_pack.json
```

### エージェント間のパイプ

```bash
# SSH経由の直接パイプ
ssh agent_a "kairos-chain skillset package my_knowledge_pack" | \
  kairos-chain skillset install-archive -
```

---

## 8. 設定リファレンス

### meeting.yml（完全リファレンス）

```yaml
# マスタースイッチ
enabled: true                    # MMP全体の有効/無効

# エージェントアイデンティティ
identity:
  name: "エージェント名"           # 表示名
  description: "説明"             # エージェントの役割
  scope: "general"               # ドメインスコープ

# 個別Skill交換
skill_exchange:
  allowed_formats:               # 受け入れ可能なコンテンツ形式
    - markdown
    - yaml_frontmatter
  allow_executable: false        # P2Pでは絶対にtrueにしない
  public_by_default: false       # Skillのデフォルト公開設定

# SkillSetパッケージ交換
skillset_exchange:
  enabled: true                  # SkillSet交換エンドポイントの有効化
  knowledge_only: true           # knowledge-onlyパッケージのみ交換
  auto_install: false            # 受信SkillSetの自動インストール

# レート制限
constraints:
  max_skill_size_bytes: 100000   # 個別Skillの最大サイズ
  rate_limit_per_minute: 10      # リクエストレート制限

# HTTPサーバー（MMPエンドポイント用）
http_server:
  enabled: true
  host: "127.0.0.1"             # バインドアドレス
  port: 8080                     # ポート番号
  timeout: 10                    # リクエストタイムアウト（秒）
```

### skillset.json（SkillSetメタデータ）

```json
{
  "name": "my_skillset",          // 必須: 安全な名前 [a-zA-Z0-9_-]
  "version": "1.0.0",            // 必須: SemVer
  "description": "...",          // 推奨
  "author": "...",               // 推奨
  "layer": "L2",                 // L0=コア, L1=標準, L2=コミュニティ
  "depends_on": [],              // SkillSet依存関係
  "provides": ["capability"],    // 宣言された機能
  "tool_classes": [],             // knowledge-onlyの場合は空
  "config_files": [],             // 設定ファイルパス
  "knowledge_dirs": ["knowledge/topic"]  // 知識ディレクトリ
}
```

---

## 9. セキュリティモデル

### Knowledge-Only制約

P2P経由で交換できるのは、**実行可能コードを含まない**SkillSetのみです。システムは`tools/`と`lib/`ディレクトリを以下の観点でスキャンします：

- **実行可能ファイル拡張子**: `.rb`, `.py`, `.sh`, `.js`, `.ts`, `.pl`, `.lua`, `.exe`, `.so`, `.dylib`, `.dll`, `.class`, `.jar`, `.wasm`
- **Shebang行**: `#!` で始まるファイル（例: `#!/usr/bin/env python3`）

これらのいずれかが検出されたSkillSetは、パッケージングとアーカイブ経由のインストールの両方がブロックされます。

### 名前の検証

SkillSet名の要件：
- パターン `[a-zA-Z0-9][a-zA-Z0-9_-]*` に一致すること
- 64文字以下であること
- パスセパレータ（`/`、`\`、`..`）を含まないこと

### アーカイブのパストラバーサル保護

tar.gzアーカイブ展開時：
- すべてのパスを絶対パスに解決し、ターゲットディレクトリ内にとどまることを検証
- アーカイブ内のシンボリックリンクとハードリンクは暗黙的にスキップ
- パストラバーサルの試み（例: `../../etc/passwd`）は`SecurityError`を発生

### コンテンツハッシュ検証

すべてのSkillSetは、全ファイルから算出されたコンテンツハッシュ（SHA-256）を持ちます。アーカイブからのインストール時：
1. アーカイブを一時ディレクトリに展開
2. 展開されたファイルからコンテンツハッシュを再計算
3. 宣言されたハッシュと一致しない場合、インストールを拒否

### レイヤーベースのガバナンス

| レイヤー | 記録 | 承認 | 一般的な用途 |
|---------|------|------|-------------|
| L0 | 完全なブロックチェーン記録（全ファイルハッシュ） | 無効化/削除に人間の承認が必要 | コアプロトコル |
| L1 | ハッシュのみのブロックチェーン記録 | 標準的な有効/無効操作 | 標準SkillSet |
| L2 | ブロックチェーン記録なし | 自由な有効/無効操作 | コミュニティ/実験的 |

---

## 10. トラブルシューティング

### "MMP SkillSet is not installed or not enabled" (503)

- MMPがインストールされているか確認: `kairos-chain skillset list`
- `.kairos/skillsets/mmp/config/meeting.yml` で `enabled: true` を確認

### "SkillSet exchange is not enabled" (403)

- `meeting.yml` で `skillset_exchange.enabled: true` を設定

### "Only knowledge-only SkillSets can be packaged" (SecurityError)

- SkillSetの`tools/`または`lib/`に実行可能ファイルが含まれています
- 実行可能ファイルを削除するか、`kairos-chain skillset install <path>` で手動インストール

### "Invalid SkillSet name" (ArgumentError)

- 名前は `[a-zA-Z0-9][a-zA-Z0-9_-]*` に一致し、最大64文字である必要があります
- スラッシュ、ドット、特殊文字は使用不可

### "Content hash mismatch" (SecurityError)

- アーカイブが転送中に変更された可能性があります
- ソースからSkillSetを再ダウンロードしてください

### "SkillSet already installed" (ArgumentError)

- 既存のものを先に削除: `kairos-chain skillset remove <名前>`
- その後再インストール

### 接続確認

```bash
# エージェントAのMMPエンドポイントが到達可能か確認
curl http://localhost:8080/meeting/v1/introduce

# ヘルスチェック
curl http://localhost:8080/health
```

---

## 付録: MMPエンドポイント早見表

| メソッド | エンドポイント | 説明 |
|---------|---------------|------|
| GET | `/meeting/v1/introduce` | 自己紹介 |
| POST | `/meeting/v1/introduce` | ピアの紹介を受信 |
| GET | `/meeting/v1/skills` | 公開Skill一覧 |
| GET | `/meeting/v1/skill_details?skill_id=X` | Skillメタデータ |
| POST | `/meeting/v1/skill_content` | Skillコンテンツをリクエスト |
| POST | `/meeting/v1/request_skill` | Skillリクエストを送信 |
| POST | `/meeting/v1/reflect` | リフレクションを送信 |
| POST | `/meeting/v1/message` | 汎用MMPメッセージ |
| GET | `/meeting/v1/skillsets` | 交換可能SkillSet一覧 |
| GET | `/meeting/v1/skillset_details?name=X` | SkillSetメタデータ |
| POST | `/meeting/v1/skillset_content` | SkillSetアーカイブをダウンロード |

ワイヤープロトコルの完全な仕様については以下を参照:
`templates/skillsets/mmp/knowledge/meeting_protocol_wire_spec/meeting_protocol_wire_spec.md`
