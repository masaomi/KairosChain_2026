---
name: kairoschain_self_development_jp
description: 自己言及的開発ワークフロー：KairosChain自身をKairosChainで開発する
version: "1.2"
layer: L1
tags: [workflow, self-referentiality, development, dogfooding, meta, contributing]
readme_order: 5.5
readme_lang: jp
---

# KairosChain 自己開発ワークフロー

KairosChainの開発自体が、KairosChainをナレッジ管理レイヤーとして使用します。
これは構造的自己言及性（命題7）を開発プロセスレベルで実現するものです：
システムを設計する行為が、システム内の操作となります。

## セットアップ

プロジェクトルートに `.kairos/` データディレクトリを初期化します：

```bash
cd KairosChain_2026
kairos-chain init
```

`.kairos/` は `.gitignore` に含まれています — ランタイムデータはローカルに留まり、
検証済みの知識は明示的なcommitを通じてコードベースに昇格されます。

## 開発サイクル

```
┌─────────────────────────────────────────────────┐
│  1. KairosChainで開発する                        │
│     - context_save (L2) でセッション作業を記録   │
│     - knowledge_update (L1) で発見を記録         │
│     - skills_evolve (L0) でメタルール変更        │
│                                                 │
│  2. コードベースに昇格する                       │
│     - .kairos/ から KairosChain_mcp_server/ へ   │
│       検証済みスキル/知識をコピー                 │
│     - 必要に応じてコアコードを直接編集           │
│     - git commit                                │
│                                                 │
│  3. 再構成する                                   │
│     - gem build + gem install                   │
│     - kairos-chain upgrade                      │
│     - .kairos/ が新しいテンプレートで更新される  │
│                                                 │
│  (ループ: 更新されたシステムがステップ1で使われる)│
└─────────────────────────────────────────────────┘
```

各commitはKairos的瞬間（命題5）です：システムは自身の使用を通じて発見された知識により、
不可逆的に自己を再構成します。

## 昇格先の選択

`.kairos/` からコードベースにコピーする際、適切なコピー先を選択します：

| .kairos/ のソース | コピー先 | 効果 |
|-------------------|---------|------|
| `knowledge/{name}/` | `templates/knowledge/{name}/` | `kairos-chain init` で全ユーザーに配布 |
| `knowledge/{name}/` | `knowledge/{name}/` | 開発リポジトリ内のみ |
| `skills/kairos.rb` の変更 | `templates/skills/kairos.rb` | 全ユーザーのデフォルトL0を変更 |
| `skillsets/{name}/` | `templates/skillsets/{name}/` | 新しいSkillSetを全ユーザーに配布 |

新しいパターンは `knowledge/`（開発専用）から始めます。
複数の開発サイクルで価値が証明されてから `templates/` に昇格します。

## 順序制約

発見したパターンが `kairos-chain init` や `upgrade` の動作自体を変更する場合：

1. `lib/` のコアコードを直接編集する（`.kairos/` 経由ではなく）
2. テスト実行：`rake test`
3. commit して gem を再ビルド
4. `kairos-chain upgrade` で `.kairos/` に変更を適用

これにより、アップグレード対象のツール自身でアップグレードを行う
鶏と卵の問題を回避します。

## 哲学的根拠

このワークフローはいくつかの核心的命題を直接実現しています：

- **命題5**（構成的記録）：各commitはシステムの存在の新しいバージョンを
  単に記録するのではなく、構成します。
- **命題6**（駆動力としての不完全性）：KairosChainを自己開発に使うことで
  不可避的にギャップが明らかになり、それが進化を駆動します。
- **命題7**（設計-実装の閉合）：設計する行為（KairosChainを使う）と
  実装する行為（KairosChainをコーディングする）が同一の操作構造内で行われます。
- **命題9**（人間-システム複合体）：自己言及的使用における開発者のメタ認知的
  観察がシステムの境界を構成します。

## インストラクションモード：`self_developer`

KairosChain開発用のカスタムインストラクションモード（`self_developer`）が利用可能です。
developerモードを拡張し、自己開発固有の振る舞いを追加しています：

- セッション開始時に `kairoschain_self_development` ナレッジを自動読み込み
- proactive tool usage による完全なL0哲学（`kairos.md`）の参照
- 昇格ガイドラインと順序制約の組み込み

有効化：

```
instructions_update(command: "set_mode", mode_name: "self_developer")
```

標準のdeveloperモードに戻す場合：

```
instructions_update(command: "set_mode", mode_name: "developer")
```

## 将来：共同自己開発

複数のコントリビューターがKairosChain開発に参加した際、
以下の進化を計画しています：

1. **`self_developer` モードをテンプレートに昇格**：`self_developer.md` を
   `templates/skills/` に移動し、`kairos-chain init` で配布
2. **現在の `developer` モードを置き換え**：`self_developer` を `developer` に
   リネームし、自己言及的ワークフローを全KairosChainコントリビューターの
   デフォルトに
3. **このナレッジをテンプレートに昇格**：`kairoschain_self_development` を
   `templates/knowledge/` に移動して配布

これは標準的な昇格パターンに従います：開発リポジトリ（`knowledge/`）から始め、
使用を通じて価値を証明し、`templates/` に昇格して全ユーザーに配布します。

## SkillSet リリースチェックリスト

新しい SkillSet の実装とテストが完了したら、以下のチェックリストに従ってリリースします：

### 1. README 用 L1 Knowledge の作成

`readme_order` と `readme_lang` フロントマターを持つ L1 knowledge ファイル（EN + JP）を
作成し、自動生成される README に SkillSet が含まれるようにします：

```
KairosChain_mcp_server/knowledge/{skillset_name}/
  {skillset_name}.md          # readme_order: N, readme_lang: en
KairosChain_mcp_server/knowledge/{skillset_name}_jp/
  {skillset_name}_jp.md       # readme_order: N, readme_lang: jp
```

配布用にテンプレートにもコピー：

```
KairosChain_mcp_server/templates/knowledge/{skillset_name}/
KairosChain_mcp_server/templates/knowledge/{skillset_name}_jp/
```

### 2. README の再生成

```bash
ruby scripts/build_readme.rb          # または: rake build_readme
ruby scripts/build_readme.rb --check  # 最新状態の確認
```

`readme_order`/`readme_lang` フロントマターを持つ全 L1 knowledge ファイルを読み取り、
ヘッダー/フッターテンプレートと組み合わせて、プロジェクトルートに
`README.md` + `README_jp.md` を生成します。

### 3. バージョンとチェンジログ

1. `lib/kairos_mcp/version.rb` のバージョンを更新
2. `CHANGELOG.md` にエントリを追加（既存のフォーマットに従う）
3. 全変更をコミット
4. タグ付け：`git tag v{VERSION}`

### 4. Gem のビルドと公開

```bash
cd KairosChain_mcp_server
gem build kairos-chain.gemspec
gem install kairos-chain-{VERSION}.gem   # ローカルテスト
gem push kairos-chain-{VERSION}.gem      # 公開（テスト後）
```

このチェックリストは `self_developer` モードの AI アシスタントが
SkillSet の実装とテスト完了時に自動的に提案すべきものです。

## これが意味しないもの

- すべての開発タスクにKairosChainを使うことを要求するものではありません。
  シンプルなツールの方が適切な場合はそちらを使ってください。
- 閉じたループではありません。外部基盤（Ruby VM、git、gemインフラ）は
  自己言及的境界の外に留まります。これは意図的です
  （「十分な自己言及性」、命題1）。
