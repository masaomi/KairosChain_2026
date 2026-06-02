---
タイトル: plugin_projector — instance mode artifact type の追加 (v3)
状態: round 3 multi-LLM review 用ドラフト
読者: masaomi（review 用）
スタイル: 既存 SkillSet への最小差分
日付: 2026-05-06
著者: Masaomi Hatakeyama (Claude Code, Opus 4.7 起草)
置き換え対象: plugin_projector_instance_mode_extension_v2_draft.md (round 2 で REJECT、scope 膨張)
実証根拠: .kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/
---

# Scope の修正（最初に読む）

v2 は invariant を 12 個並べた自己完結的な設計として書かれた。レビュアーは正しく「review 面積が変更の本体に対して大きすぎる」と指摘した。v3 はこれを受けて、**既存 SkillSet `plugin_projector` への最小差分**として書き直す。

原子性、idempotency（再実行で同じ結果）、manifest 管理、stale な投射物の削除、single-writer 前提、path 安全性、host file への協調的書き込み、`:project` / `:plugin` の二重 mode といった項目は、**全て既存の `KairosMcp::PluginProjector` クラス**（`KairosChain_mcp_server/lib/kairos_mcp/plugin_projector.rb`）から無修正で継承する。

このドラフトは新しい artifact type に固有の事項のみを記述する。

# 何が変わるか

`plugin_projector` に新しい投射対象「アクティブな instance mode 本体」（Masa Mode、Tutorial Mode、…）が 1 種類追加される。変更後、投射が産むものは:

- 既存のもの: SkillSet の skills, agents, hooks, knowledge meta skill（変更なし）
- **新規**: flat 化された `.claude/kairos/instance_mode.md` ファイル 1 つと、プロジェクトルート `CLAUDE.md` 内のマーカー領域（その file を `@`-import で参照する）

# なぜ必要か

L2 観察ログ（`.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`）に記録された 3 つの欠落:

1. **MCP `instructions` は Claude Code harness によって途中で切り捨てられる。** mode 本体の identity 部分（冒頭）は届くが、normative 部分（規範本体）は届かない。「記録された憲法と動作している憲法が違う」という Prop 5 違反。

2. **Agent tool sub-agent は MCP `instructions` を継承しない。** sub-agent は CLAUDE.md（および `@`-import で取り込まれた file）を継承するが、MCP server の `instructions` は受け取らない。multi-LLM review で Reviewer 1 を担う Persona Agent team は、**そもそも mode 本体を一切受け取っていなかった**。これは MCP truncation を直しても解決しない、より大きいギャップ。

3. **CLAUDE.md `@`-import 経路は実証的に privileged（特権的）である。** Theme A 検証（round 2、新規セッション 3 経路で確認）で、parent / `claude -p` subprocess / Agent sub-agent の全部に、107KB まで欠損なく届くことを確認。Opus 4.6 と 4.7 で挙動差なし。なお、nested な `@`-import は再帰展開**されない**（深さ 1 まで）。

# 何をするか（差分）

## 新しい artifact source

`kairos-chain` mode registry がアクティブな instance mode を解決し、その本体を flat な文字列として返す（中に `@`-import directive を含めない。これは検証ログの F2「nested は展開されない」に対応）。projector はこの本体を、既存の `plugin/SKILL.md` や `plugin/agents/*.md` と並ぶ新しい artifact source として扱う。

## 新しい投射先

出力は 2 つ:

1. **`<output_root>/kairos/instance_mode.md`** — flat 化された mode 本体。書き込みは既存の `atomic_write` helper を使う。tracking は既存の `projection_manifest.json` に `{type: 'instance_mode', mode_id, mode_version}` というエントリを追加。

2. **プロジェクトルート `CLAUDE.md` 内のマーカー領域** — 新しい helper メソッド `write_instance_mode_to_claudemd!` で書き込む。このメソッドは既存の `write_hooks_to_settings!` をモデルにする。領域の書式:

   ```
   <!-- BEGIN kairos-chain:instance-mode _projected_by=kairos-chain -->
   @.claude/kairos/instance_mode.md
   <!-- END kairos-chain:instance-mode -->
   ```

   書き込み手続きは `settings.json` への hooks merge と同型: 既存のマーカー領域があれば marker で位置特定して削除し、新しく構築した領域を追記する。マーカー外のバイトは触らない。原子性は既存の `atomic_write`（CLAUDE.md 全体を tmpfile に書いて rename）で担保する。

   削除（mode 非活性化、active mode のない状態での再投射）の場合は、既存の `cleanup_stale!` と同じ経路で領域を消す。manifest が領域を logical output として記録しており、現在の outputs に存在しなければ削除が発火する。

## manifest エントリ

`projection_manifest.json` の `outputs` に 2 つのエントリが追加される:

- ファイルパス `<output_root>/kairos/instance_mode.md` に `{type: 'instance_mode', mode_id, mode_version}`
- 記号キー `claudemd:instance-mode-region` に `{type: 'claudemd_region', mode_id, mode_version}` — 上記ファイルと同じ contention で書かれ、消される

既存の `compute_source_digest` を拡張して mode_id と registry record の hash を含めるので、mode 切り替えが発生したとき `project_if_changed!` が再投射を発火する。これは既存の knowledge_entries を digest に含めているのと同じパターン。

## MCP `instructions` の移行

MCP の `instructions` payload は次の形に変える:

- mode の identity（id + version）
- registry record への短い参照（registry record hash + 取得方法）

mode 本体は MCP には載せない。後方互換: `instructions` を読む消費者は identity 情報と registry pointer を受け取る。Claude Code 以外の MCP client は registry を直接参照して本体を取得できる。round 2 で唯一残った Prop 5 関連の懸念（C9: 非 Claude Code consumer に本体が届かない）はこれで解消される。記録された本体は依然として全 consumer から到達可能。途中で truncate される channel 経由ではなくなるだけ。

# 何を継承するか（新しい設計はしない）

以下は既存 PluginProjector の挙動で、無修正で再利用される。レビュアーが round 2 で挙げた懸念のうち、ここに含まれる項目は新規設計の対象ではない:

- **原子的書き込み**: `atomic_write`（tmpfile + rename）
- **idempotency**: `project_if_changed!` が `source_digest` 比較で no-op 判定する
- **manifest を外部 state として持つ**: `.kairos/projection_manifest.json` が全 hash と output path を保持する。投射ファイルの中に hash を埋めない（ので自己参照ハッシュ問題が起きない）
- **stale 削除**: `cleanup_stale!` が、前回の manifest にあって今回の outputs にない file（および領域）を消す
- **path 安全性**: `safe_path?`, `safe_name?`
- **host file への協調的書き込み**: `_projected_by` tag による識別パターン（`write_hooks_to_settings!` から借用）
- **二重 mode**: `:project` は `.claude/` に、`:plugin` は plugin root に書く。instance mode artifact もこのルーティングに従う
- **hook 駆動の再投射**: 既存 hook（`skills_promote`, `skills_evolve`, `skillset_acquire`, `skillset_withdraw`）が再投射を発火する。mode 切り替えは初期化経路と新たな `mode_activate` event で発火する（後者は本ドラフトの scope 外。projector は registry が解決したものに反応するだけ）

# Scope 外（明示）

本変更で扱わない事項。これらは既存 PluginProjector に対しても同様であり、本拡張で新たに導入される懸念ではない:

- **1 プロジェクトに複数の KairosChain インスタンスを共存させる場合の投射**: 既存 plugin_projector も対応していない。同じ scope。
- **git worktree（同じ `.git` を共有する複数の作業 tree）**: 既存 plugin_projector と同じ scope。
- **複数の projector プロセスが同時に走る場合**: 既存 plugin_projector はプロジェクトあたり single-writer 前提。本変更はこの制約を継承する。
- **`/init` がマーカー領域を消した場合の自動回復**: 既存の manifest + `project_if_changed!` で再投射すれば exact に復旧する。マーカー内のヒントコメントが、再実行された LLM 駆動の `/init` に保護を促す（best-effort）。完全な回復は再投射で得られる。
- **projector 自身の self-projection**（Prop 1 自己言及性を projector レベルにも適用するか）: 哲学的に open な問題。本差分の対象外。

# 移行

本変更が ship したあと、最初の投射実行で file と CLAUDE.md 領域が同時に作られる。別途の migration step は不要。`project_if_changed!` が新しい source digest を検出して、次の trigger で投射する。CLAUDE.md を初めて変更する際の consent surface（同意表面）は、既存 plugin_projector が `.claude/settings.json` を初めて変更するときに使っている channel と同じものを再利用する（既存実装をそのまま使う）。

# Open question（policy 系のみ）

1. **mode 本体のサイズ閾値**: Theme A は 107KB まで配信を確認した。CLAUDE.md は毎ターン読まれるので、registry は閾値を超える本体を refuse すべきか。初期案: 150KB で warn、256KB で refuse。これは policy であって invariant ではない。

2. **`.claude/kairos/instance_mode.md` の `.gitignore` 既定**: 個人 mode（Masa Mode）は private なので track しない方が良い。共有 mode（Tutorial Mode）は track した方が良い。推奨デフォルト: ignore。プロジェクトごとに operator が override できる。

3. **MCP pointer の format**: 縮小後の `instructions` payload は具体的に何を含めるか。最小案: `{mode_id, mode_version, registry_record_hash, retrieval_hint}`。レビュアーが standard な形を提案するかもしれない。

# 検証根拠

- **Theme A 検証ログ**: `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`。107KB までの `@`-import privilege を parent / subprocess / sub-agent の 3 経路で Opus 4.6 / 4.7 両方で実証。
- **既存実装 `KairosMcp::PluginProjector`**: `KairosChain_mcp_server/lib/kairos_mcp/plugin_projector.rb`。本ドラフトが「継承する」と書いた挙動は、すべて直接コードを読んで確認できる。

# masaomi さんへの review チェックポイント

以下が違和感ないかを確認してほしい:

1. **「既存仕組みの継承」と書いている部分**が、本当に既存コードでカバーされているか（疑わしい行があれば指摘ください）
2. **Scope 外として明示した 5 項目**（multi-instance / git worktree / 並行書き込み / `/init` 自動回復 / projector self-projection）に、実は本来この差分で扱うべきものが混じっていないか
3. **MCP pointer 化（C9 解消案）**が masa mode 運用上の問題にならないか（非 Claude Code consumer は registry を直接読む必要が出る）
4. **マーカー領域の書式**: `_projected_by=kairos-chain` を BEGIN コメントに含めているが、これは settings.json hooks の `_projected_by` tag と同型にするため。違和感あれば調整可
5. **instance_mode.md の配置先**: `<output_root>/kairos/instance_mode.md` が `:project` mode のとき `.claude/kairos/instance_mode.md` になる。`.claude/skills/` や `.claude/agents/` と並ぶ位置関係で良いか
