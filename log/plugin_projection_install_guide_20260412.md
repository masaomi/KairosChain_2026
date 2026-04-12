# KairosChain Plugin Projection — インストール手順

## 前提条件

- Ruby 3.0+（推奨: 3.3+）
- Claude Code（最新版）

## 手順

### 1. KairosChain gem のインストール

```bash
gem install kairos-chain
```

### 2. プロジェクトの初期化

```bash
cd your-project
```

#### .mcp.json を作成（MCP サーバー接続設定）

```bash
cat > .mcp.json << 'EOF'
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": ["--data-dir", ".kairos"]
    }
  }
}
EOF
```

#### KairosChain データディレクトリを初期化

```bash
kairos-chain --data-dir .kairos --init
```

#### .claude/ ディレクトリを作成（Claude Code Project モード用）

```bash
mkdir -p .claude
```

### 3. Claude Code を起動

```bash
claude
```

### 4. SkillSet をインストール

Claude Code 内で以下を実行:

```
system_upgrade を実行して、全 SkillSet をインストールしてください
```

インストール後、Claude Code を再起動（`/exit` → `claude`）。

### 5. 動作確認

再起動後、自動的に Plugin Projection が実行されます。

Claude Code 内で:
```
/reload-plugins
```

以下のスキルが表示されれば成功:
- `agent` — Cognitive OODA Loop
- `skillset_exchange` — SkillSet Exchange
- `skillset_creator` — SkillSet Creator
- `plugin_projector` — Plugin Projector（自己投影）
- `kairos-knowledge` — Knowledge Base

別ターミナルで確認:
```bash
ls .claude/skills/        # agent, plugin_projector, skillset_* 等
ls .claude/agents/        # agent-monitor.md, skillset_exchange-reviewer.md
cat .kairos/projection_manifest.json  # 投影記録
```

## 仕組み

```
MCP サーバー起動 (handle_initialize)
  → PluginProjector.project!
  → .claude/skills/{name}/SKILL.md       ← SkillSet ワークフローガイド
  → .claude/agents/{name}.md             ← 専用サブエージェント
  → .claude/settings.json                ← hooks マージ
  → .kairos/projection_manifest.json     ← 投影記録

/reload-plugins
  → Claude Code が新しい skills/agents を認識
```

## 更新時

SkillSet を追加・変更した場合（`skills_promote`, `skillset_acquire` 等）、
hooks が自動で再投影をトリガーします。`/reload-plugins` で新しいスキルが反映されます。

## トラブルシューティング

### skills/ が生成されない
- `.claude/` ディレクトリが存在するか確認
- `system_upgrade` で SkillSet がインストール済みか確認
- SkillSet の `skillset.json` に `"plugin"` セクションがあるか確認

### agents/ が生成されない
- SkillSet の `plugin/agents/` ディレクトリにファイルがあるか確認
- `projection_manifest.json` を確認

### hooks が動作しない
- `.claude/settings.json` に `hooks` セクションがあるか確認
- `/hooks` で hooks が登録されているか確認
