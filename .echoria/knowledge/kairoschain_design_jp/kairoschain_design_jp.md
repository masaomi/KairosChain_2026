---
name: kairoschain_design_jp
description: Pure Skills設計とディレクトリ構造
version: 1.0
layer: L1
tags: [documentation, readme, design, architecture, directory-structure]
readme_order: 4
readme_lang: jp
---

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

### Gem構造（`gem install kairos-chain` でインストール）

```
kairos-chain (gem)
├── bin/
│   └── kairos-chain         # 実行ファイル（gem install後にPATHに追加）
├── lib/
│   ├── kairos_mcp.rb             # 中央モジュール（data_dir管理）
│   └── kairos_mcp/
│       ├── version.rb            # Gemバージョン
│       ├── initializer.rb        # `init`コマンド実装
│       ├── server.rb             # STDIOサーバー
│       ├── http_server.rb        # Streamable HTTPサーバー（Puma/Rack）
│       ├── protocol.rb           # JSON-RPCハンドラー
│       └── ...                   # （リポジトリ版と同じ構造）
├── templates/                    # `init`時にコピーされるデフォルトファイル
│   ├── skills/
│   │   ├── kairos.rb             # デフォルトL0 DSL
│   │   ├── kairos.md             # デフォルトL0哲学
│   │   └── config.yml            # デフォルト設定
│   └── config/
│       ├── safety.yml            # デフォルトセキュリティ設定
│       └── tool_metadata.yml     # デフォルトツールメタデータ
└── kairos-chain.gemspec            # Gem仕様
```

### データディレクトリ（`kairos-chain init` で作成）

```
.kairos/                          # デフォルトデータディレクトリ（設定可能）
├── skills/
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
├── config/
│   ├── safety.yml                # セキュリティ設定
│   └── tool_metadata.yml         # ツールガイドメタデータ
└── storage/
    ├── blockchain.json           # チェーンデータ（ファイルモード）
    ├── kairos.db                 # SQLiteデータベース（SQLiteモード）
    ├── embeddings/               # ベクトル検索インデックス（自動生成）
    └── snapshots/                # StateCommitスナップショット
```

### リポジトリ構造（GitHubからクローン）

```
KairosChain_mcp_server/
├── bin/
│   └── kairos-chain         # 実行ファイル
├── lib/
│   ├── kairos_mcp.rb             # 中央モジュール（data_dir管理）
│   └── kairos_mcp/
│       ├── version.rb            # Gemバージョン
│       ├── initializer.rb        # `init`コマンド実装
│       ├── server.rb             # STDIOサーバー
│       ├── http_server.rb        # Streamable HTTPサーバー（Puma/Rack）
│       ├── protocol.rb           # JSON-RPCハンドラー
│       ├── kairos.rb             # 自己参照モジュール
│       ├── safe_evolver.rb       # 安全性を伴う進化
│       ├── layer_registry.rb     # レイヤーアーキテクチャ管理
│       ├── anthropic_skill_parser.rb  # YAMLフロントマター + MDパーサー
│       ├── knowledge_provider.rb # L1知識管理
│       ├── context_manager.rb    # L2コンテキスト管理
│       ├── admin/                # 管理者UI（htmx + ERB）
│       │   ├── router.rb        # ルーティングとコントローラー
│       │   ├── helpers.rb       # ERBヘルパー、セッション、CSRF
│       │   ├── views/           # ERBテンプレート（レイアウト、ページ、パーシャル）
│       │   └── static/          # CSS（PicoCSS拡張）
│       ├── auth/                 # 認証モジュール
│       │   ├── token_store.rb    # トークンCRUD（SHA-256ハッシュ化）
│       │   └── authenticator.rb  # Bearerトークン検証
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
│       └── tools/                # MCPツール（コア25個）
│           ├── skills_*.rb       # L0ツール
│           ├── knowledge_*.rb    # L1ツール
│           ├── context_*.rb      # L2ツール
│           ├── state_*.rb        # StateCommitツール
│           └── token_manage.rb   # トークン管理（HTTPモード）
├── templates/                    # `init`コマンド用デフォルトファイル
│   ├── skills/                   # デフォルトスキルテンプレート
│   └── config/                   # デフォルト設定テンプレート
├── kairos-chain.gemspec            # Gem仕様
├── Gemfile                       # 開発用依存関係
├── Rakefile                      # ビルド/テストタスク
├── test_local.rb                 # ローカルテストスクリプト
└── README.md
```
