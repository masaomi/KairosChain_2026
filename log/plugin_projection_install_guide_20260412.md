# KairosChain Plugin Projection — インストール手順

## 前提条件

- Ruby 3.0+（推奨: 3.3+）
- Claude Code（最新版）

```bash
gem install kairos-chain
```

## Project モード（推奨）

プロジェクトディレクトリに KairosChain を設定する。`.kairos/` と `.claude/` がプロジェクト内に作られる。
ディレクトリ削除で完全にアンインストール可能。

### セットアップ（2ステップ）

```bash
cd your-project
kairos-chain init     # .kairos/ 初期化 + .mcp.json 自動生成
claude                # 起動 → auto-install SkillSets → auto-projection
```

`kairos-chain init` が行うこと:
- `.kairos/` データディレクトリ作成（L0/L1/L2 + blockchain + config）
- `.mcp.json` 自動生成（既存なら追加するか確認）
- L1 knowledge テンプレート（29件）のインストール

`claude` 初回起動時に自動で行われること:
- 全 SkillSet の自動インストール（system_upgrade 相当）
- Plugin 投影（skills, agents, hooks を `.claude/` に書き出し）

### 確認

```bash
ls .claude/skills/    # agent, plugin_projector, skillset_*, kairos-knowledge
ls .claude/agents/    # agent-monitor.md, skillset_exchange-reviewer.md
cat .claude/settings.json   # hooks セクション
cat .kairos/projection_manifest.json   # 投影記録
```

Claude Code 内で:
```
/hooks              # 投影された hooks が表示される
/reload-plugins     # skills/agents を認識（初回のみ必要）
```

### アンインストール

```bash
# プロジェクトディレクトリごと削除で完全クリーン
rm -rf your-project

# または個別に削除
rm .mcp.json                    # MCP サーバー接続解除
rm -rf .kairos                  # KairosChain データ
rm -rf .claude/skills .claude/agents  # 投影ファイル
# .claude/settings.json の hooks セクションは手動で削除
```

## Plugin モード（配布用）

KairosChain リポジトリを Claude Code Plugin として読み込む。
Marketplace 配布や `--plugin-dir` で共有するときに使用。

### セットアップ

```bash
claude --plugin-dir /path/to/KairosChain_2026
```

起動時に自動で行われること:
- `.mcp.json` → MCP サーバー自動接続
- `handle_initialize` → `.kairos/` 自動初期化 → SkillSet 自動インストール → 投影
- `skills/kairos-chain/SKILL.md`（seed）が即座に見える

### Plugin モードの特徴

| 項目 | Project モード | Plugin モード |
|------|--------------|-------------|
| スキル名 | `/agent` | `/kairos-chain:agent` (namespace 付き) |
| `/plugin list` | 表示されない | 表示される |
| アンインストール | ファイル削除 | `/plugin uninstall` |
| `.kairos/` の場所 | カレントディレクトリ | カレントディレクトリ |
| hooks の場所 | `.claude/settings.json` | `hooks/hooks.json`（Plugin root） |

### アンインストール

Claude Code 内で:
```
/plugin uninstall kairos-chain
```

データを削除する場合:
```bash
rm -rf .kairos
```

## 仕組み

```
kairos-chain init
  → .kairos/ 作成 + .mcp.json 自動生成

claude 起動
  → .mcp.json → MCP サーバー起動
  → handle_initialize
    → .kairos/ 未初期化なら自動 init
    → SkillSet 未インストールなら自動インストール
    → PluginProjector.project!
      → .claude/skills/{name}/SKILL.md     ← ワークフローガイド
      → .claude/agents/{name}.md           ← 専用サブエージェント
      → .claude/settings.json              ← hooks マージ
      → .kairos/projection_manifest.json   ← 投影記録
```

## 更新時

SkillSet を追加・変更した場合（`skills_promote`, `skillset_acquire` 等）、
hooks が自動で再投影をトリガーします。`/reload-plugins` で新しいスキルが反映されます。

gem 更新後は Claude Code 内で `system_upgrade` を実行すると、
新しいテンプレートが適用され、投影も自動更新されます。

## トラブルシューティング

### skills/ が生成されない
- `.claude/` ディレクトリが存在するか確認（Project モードでは自動作成されない場合がある）
- `kairos-chain init` が完了しているか確認
- `.kairos/skillsets/` に SkillSet がインストールされているか確認

### agents/ が生成されない
- SkillSet の `plugin/agents/` ディレクトリにファイルがあるか確認
- `.kairos/projection_manifest.json` の outputs を確認

### hooks が動作しない
- `/hooks` で hooks が登録されているか確認
- `.claude/settings.json` に `hooks` セクションがあるか確認

### 初回起動で投影されない
- MCP サーバーが正常に起動しているか確認（`.mcp.json` の内容）
- `kairos-chain` コマンドがパスに通っているか確認（`which kairos-chain`）
