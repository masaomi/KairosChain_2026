# Handoff: KairosChain instruction-mode plugin projection bug

**Date:** 2026-05-12
**Reporter:** masaomi (masaomi.hatakeyama@uzh.ch)
**Target repo:** KairosChain (本体)
**Severity:** Medium — instruction mode is silently not delivered to consumer projects

## Summary

`kairos-chain mode project` (instruction-mode の plugin projection) は、kairos-chain を **本体ディレクトリ以外の作業ディレクトリで起動した場合**、コンシューマプロジェクト側に CLAUDE.md（あるいは `@`-import 行）を**生成しない/到達しない**可能性があります。結果として、コンシューマプロジェクトでは指定したモード（例: sushilover）がファイルベースで読み込まれず、MCP サーバの `instructions` フィールド経由でのみ部分的に注入される状態になります。

## Observed evidence

調査対象セッション:
- 作業ディレクトリ: `/srv/sushi/masa_test_sushi_20260512`
- MCP サーバ: `kairos-chain --data-dir /srv/sushi/SUSHI_self_maintenance_mcp_server/server/KairosChain_mcp_server/`
- セッション冒頭のリマインダーは以下を主張:
  ```
  # Active instruction mode (delivered via CLAUDE.md @-import)
  - mode_name: sushilover
  - source_path: /srv/sushi/SUSHI_self_maintenance_mcp_server/server/KairosChain_mcp_server/skills/sushilover.md
  The full mode body is delivered to the model through this project's
  CLAUDE.md `@`-import line and is not duplicated here.
  ```

実ファイル状況（消費側プロジェクト階層）:

| Path | CLAUDE.md |
|---|---|
| `/srv/sushi/masa_test_sushi_20260512/CLAUDE.md` | ❌ 存在しない |
| `/srv/sushi/CLAUDE.md` | ❌ |
| `/srv/CLAUDE.md` | ❌ |
| `~/.claude/CLAUDE.md` | ❌ |

唯一の関連 CLAUDE.md は本体側のみ:
- `/srv/sushi/SUSHI_self_maintenance_mcp_server/server/CLAUDE.md` (L171-172)
  ```
  <!-- Active mode: sushilover | source: .kairos/skills/sushilover.md -->
  @kairos/instruction_mode.md
  ```

つまり projection されるべき消費側プロジェクト (`/srv/sushi/masa_test_sushi_20260512/`) には CLAUDE.md が一切生成されておらず、`@`-import 連鎖が成立していません。

## Probable root cause (推定)

`kairos-chain mode project` 系コマンドが、

- **本体ディレクトリ (data-dir / kairos-chain インストールディレクトリ)** に対する CLAUDE.md は書き換える/維持する
- しかし **MCP クライアントから呼ばれた consumer 側 cwd** に対しては projection を実施しない/到達しない

という挙動になっている可能性が高い。具体的には、projection 先のパス解決が
- `Dir.pwd` / `__dir__` / kairos-chain 本体の data-dir を基点にしている
- もしくは MCP セッションから渡される client workspace path を参照していない

のいずれかが疑われる。

## Reproduction steps (要検証)

1. 任意の consumer project ディレクトリ（例: `/tmp/consumer_proj`）を作成し、そこに CLAUDE.md を**置かない**
2. その consumer project の `.mcp.json` で kairos-chain を `--data-dir <別の本体パス>` 起動として登録
3. Claude Code を consumer project で起動
4. `kairos-chain mode project sushilover` 相当の projection 操作を実行
5. consumer project 側に CLAUDE.md（または `@`-import 行）が生成されるかを確認

期待: consumer project に CLAUDE.md が生成され、本体側の instruction_mode.md を `@`-import する
実際: consumer project には何も生成されない（本観測ケース）

## Suggested fix direction

- `kairos-chain mode project` 内部で projection 先パスを決定する際、
  - MCP クライアント側の workspace path（CLAUDE_PROJECT_DIR 環境変数 or MCP セッション情報）を最優先で参照する
  - 取得できない場合は `Dir.pwd` をフォールバックに、本体 data-dir は projection 先として採用しない
- projection 結果（書き込んだファイルパス）を stdout に明示し、サイレント失敗を防ぐ
- 既に CLAUDE.md がある場合は idempotent な merge（既存の `@`-import を保持しつつ追加）

## Workaround (暫定)

consumer project ルートに以下の内容で CLAUDE.md を手動作成すれば、ファイルベース import が成立する：

```
@/srv/sushi/SUSHI_self_maintenance_mcp_server/server/kairos/instruction_mode.md
```

## Related paths (修正調査時の参照点)

- 本体 CLAUDE.md: `/srv/sushi/SUSHI_self_maintenance_mcp_server/server/CLAUDE.md`
- instruction_mode 中継ファイル: `/srv/sushi/SUSHI_self_maintenance_mcp_server/server/kairos/instruction_mode.md`
- mode 本体 (sushilover): `/srv/sushi/SUSHI_self_maintenance_mcp_server/server/KairosChain_mcp_server/skills/sushilover.md`
- MCP 登録: `/srv/sushi/masa_test_sushi_20260512/.mcp.json`
- 該当 CLI: `kairos-chain mode project` (本体側)

## Notes

- MCP server の `instructions` フィールドではモード名・source_path のメタ情報は届くが、モード本体は届かない（メタ情報自身が "delivered via CLAUDE.md @-import" と明言しているため）。したがってこのバグの影響は「モード本体がモデルに到達しない」ことであり、サイレントな挙動劣化を引き起こす。
