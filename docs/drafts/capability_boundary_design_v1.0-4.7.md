---
name: capability_boundary_design
description: KairosChain Phase 1.5 — システムが自身の harness 依存を articulate できる仕組み (manifest + introspection + L1 doctrine)。masaomi 指摘の Claude Code / KairosChain 機能 conflation 問題への構造的回答。
tags: [design, capability-boundary, phase1.5, self-articulation, harness, l0, l1]
type: design_draft
version: "1.0"
authored_by: claude-opus-4-7-directive-anti-enumeration-high
date: 2026-05-02
---

# KairosChain Phase 1.5: Capability Boundary

## 動機

Phase 1 (Context Graph) 完了直後に masaomi が指摘した懸念:

> 「現状の機能や UX が Claude Code 特有の機能の恩恵なのか、KairosChain の恩恵なのか、を KairosChain 自体がわかっている必要がある」

これは命題 2 (partial autopoiesis: closure at L0、execution は外部基盤依存) と命題 7 (metacognitive self-referentiality: 自身について推論できる) の交点で要請される構造的課題。**KairosChain が自身の境界を articulate できない限り、自己言及性原則 (CLAUDE.md §1) は虚構**。Phase 1.5 はこの articulation 機構を最小実装する。

## §1 設計原則 (不変条件)

本 Phase 1.5 は L0/L1 framework infrastructure として **design-by-invariant** を適用する (cf. memory `feedback_design_by_invariant_scope.md` の "L0/L1 限定" 規定)。

### Self-articulation invariant

**KairosChain は実行時に自身の capability boundary を articulate できなければならない**。具体的には: 実行中の active_harness、利用される external CLI 群、各 tool の harness 依存 tier、これら全てを runtime introspection で取得可能。articulation の手段は MCP tool (`capability_status`) と L1 knowledge (`kairoschain_capability_boundary`) の二経路を持ち、harness の有無に関わらず機能する。

### Honest unknown invariant

**検出不能時に嘘をつかない**。active_harness が auto-detect で判定不能なら `:unknown` を返却する。"おそらく Claude Code" のような guess は禁止。これは命題 2 の partial autopoiesis を破壊するため (closure 内に虚偽が入ると definitional integrity が崩れる)。env var による明示宣言を最優先し、次に観測可能な hint で補う。

### Declare-not-enforce invariant

**Phase 1.5 の宣言は articulation のためであり、runtime gate のためではない**。harness mismatch (例: claude_cli 必要な tool を claude_cli 不在環境で呼ぶ) を runtime で検出しても refuse しない。既存 error handling (subprocess 失敗等) に委ねる。Pre-flight check は呼び出し側 (LLM) の主体的判断で `capability_status` を呼ぶことで成立する。enforcement が必要になれば Phase 2+ で別 invariant として追加する。

### Code-proximity invariant

**Capability metadata は tool 実装と同じファイル/クラスに置く**。中央集権 manifest (`capabilities.yml` 等) は持たない。理由: コード変更時に metadata 更新を忘れる drift を防ぐため、宣言を実装に隣接させる。集約 view は introspection tool が runtime に build する derived artifact であり、source of truth ではない。

### Active vs external separation invariant

**"KairosChain プロセスを駆動する harness (active_harness)" と "KairosChain プロセス内から起動する外部 CLI (used_externals)" は概念的に常に分離される**。両者を 1 つの list に flatten することは禁止。multi_llm_review が Claude Code 上で動きながら codex_cli/cursor_cli を subprocess 起動する典型例で、この分離なくして masaomi 指摘の conflation 問題は articulate できない。

### Forward-only metadata invariant

**`harness_requirement` 宣言は opt-in、無宣言の tool は `:core` 扱い**。既存の全 tool に metadata を遡及付与せず、後方互換を保つ。理由: 大多数の MCP tool は実際 core (MCP プロトコルとファイルシステムのみ) であり default として正しい。明示的に harness 依存があるもののみ宣言する。

## §2 Tier definition (3 段階の判定基準)

Tier は **「その機能を実行するために何が必要か」** で決定される。判定は以下の単一 invariant で行う:

> **tier の上位は下位を真包含する**: `:core` で動くものは `:harness_assisted` でも `:harness_specific` 環境でも動く。逆は成立しない。

具体的判定 rule:

- **`:core`** — MCP プロトコル + filesystem のみで完結する。subprocess 起動も harness-specific tool 呼び出しも行わない。例: `context_save`, `skillset_exchange`, `context_graph_traverse`
- **`:harness_assisted`** — 動作するが、いずれかの外部 CLI またはオプショナルな harness 機能を利用する。それらが不在でも degraded mode で動くか、明示的なエラーで失敗する。例: `multi_llm_review` (claude_cli/codex_cli/cursor_cli を subprocess 起動)
- **`:harness_specific`** — 特定 harness 内でのみ意味を持つ。原理的にその harness 外では呼べない。例: Claude Code Hooks 連携 tool (もしあれば)

判定 rule の境界例: 「harness 上で MCP tool として呼ばれるが、その harness の特殊機能 (subagent delegation 等) を必須とする」場合は `:harness_specific`。「外部 CLI を呼ぶが代替手段がある」場合は `:harness_assisted`。

## §3 Active harness 検出

検出は以下の優先順位で行われる:

1. **環境変数 `KAIROS_HARNESS`** が set されていれば、その値をそのまま採用 (例: `claude_code`, `codex_cli`, `cursor`, `raw_api`, など任意 String 受容、Symbol 化して返却)
2. **Auto-detect hints** を順に評価。hint は `capabilities.yml` 等に外出しせず、実装内の探索ロジックとして持つ (将来 hint 追加で拡張)。Hint 例: 親プロセス名、harness 固有の env var (`CLAUDE_CODE_*` 等)、CWD に CLAUDE.md/MEMORY.md 存在
3. いずれも match しなければ `:unknown` を返却

検出ロジックは pure function (副作用なし、現在時刻に独立) として実装し、test 容易性を確保する。検出結果は **process boot 時に 1 回 cache** する (再評価せず、env 変更に追従しない)。これは命題 2 の "L0 級閉包" を反映: 起動時の harness 認識が 1 process lifetime の閉包を構成する。

## §4 BaseTool DSL: `harness_requirement`

class-level macro として宣言:

```ruby
class ContextSave < KairosMcp::Tools::BaseTool
  harness_requirement :core
  # ... 既存実装変更なし
end

class MultiLLMReview < KairosMcp::Tools::BaseTool
  harness_requirement :harness_assisted,
                      requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
                      degrades_to: 'persona-only mode (no subprocess reviewers)',
                      note: 'persona Agent reviews delegate back to orchestrator harness'
end

class HookHandler < KairosMcp::Tools::BaseTool
  harness_requirement :harness_specific,
                      harness: :claude_code,
                      reason: 'requires Claude Code Hooks lifecycle events'
end

# 宣言なし → default :core (opt-in)
class LegacyTool < KairosMcp::Tools::BaseTool
  # harness_requirement 不在
end
```

引数 schema:

| 位置引数 | tier symbol (`:core` / `:harness_assisted` / `:harness_specific`) |
| `requires_externals:` | Array of Symbol、subprocess 起動する外部 CLI 名 (推奨命名: `claude_cli`, `codex_cli`, `cursor_cli`) |
| `degrades_to:` | String、不足時の degraded behavior 説明 (LLM が読む) |
| `harness:` | Symbol、`:harness_specific` の場合に required harness を 1 つ指定 |
| `reason:` | String、なぜ harness_specific か (LLM への doctrine 周知) |
| `note:` | String、自由記述 |

DSL は `Class.harness_requirement_metadata` (Hash 返却) をクラスメソッドとして提供し、introspection tool がここから集約する。

## §5 `capability_status` tool 仕様

入力: なし (引数不要)、または `verbose: true` で展開出力。

出力 (Hash):

```ruby
{
  kairos_version: "3.24.4",
  active_harness: :claude_code,           # 検出結果 (env or auto)
  active_harness_source: :env_var,        # :env_var / :auto_detect / :default
  declared: {
    tools_by_tier: {
      core: ["context_save", "skillset_exchange", ...],
      harness_assisted: ["multi_llm_review", ...],
      harness_specific: ["hook_handler", ...]
    },
    declared_externals: [:claude_cli, :codex_cli, :cursor_cli],   # union
    declared_harness_specific_to: { claude_code: ["hook_handler"] }
  },
  observed: {
    used_externals_in_session: [],         # 実行履歴から (Phase 1.5 では空 array で OK、Phase 2+ で track)
    note: "observed.used_externals_in_session is reserved for Phase 2+; currently empty"
  },
  notes: [
    "active_harness=:claude_code means KairosChain process is running under Claude Code harness.",
    "claude_cli is the same source as active_harness; not listed as external.",
    "Tools declared :core work on any harness (including raw API).",
    "Tools declared :harness_assisted may degrade or fail without their externals.",
    "Tools declared :harness_specific cannot work outside their named harness."
  ]
}
```

`active_harness_source` を含めることで、検出が **明示宣言由来か推測由来か** を呼び出し側が判断できる (`:env_var` は信頼度高、`:auto_detect` は中、`:default` は honest unknown)。

`declared` と `observed` の分離は **静的宣言** と **動的観測** を区別する命題 7 metacognitive 構造を反映する。Phase 1.5 では `observed` は stub (空)、Phase 2+ で実行履歴 tracking を追加する余地。

## §6 哲学的位置づけ

- **命題 2 (Partial autopoiesis)**: 「definitional closure は L0、execution は外部基盤依存」と宣言する以上、何が外部かを articulate できねばならない。Phase 1.5 はこの articulation 機構そのもの
- **命題 7 (Metacognitive self-referentiality)**: 自身について推論する metacognition は、自身の boundary を知らなければ成立しない。`capability_status` tool が KairosChain の自己認識の primary surface
- **命題 9 (Human-system composite)**: harness は人間-機械 composite の一部であり、これを暗黙化すると境界線が曖昧化する。Phase 1.5 は composite を articulate する操作

masaomi 指摘の conflation 問題 ("Claude Code 機能と KairosChain 機能の混同") は、上記 3 命題の同時要請から導かれる構造的課題。Phase 1.5 はこの 3 命題を同時に満たす最小機構として位置づけられる。

## §7 Phase 2 への含意

Phase 2 で予定される 4 案 (A: L1 skill `context_graph_recall` / B: `dream_scan mode:scan` の edges 拡張 / C: reverse traversal / D: CLAUDE.md hint で auto-recall promote) は、Phase 1.5 で定義した tier に則って分類される:

- 案 A (L1 skill): `:core` (MCP knowledge として読まれる、harness 非依存)
- 案 B (scan 拡張): `:core` (MCP tool 出力)
- 案 C (reverse traversal): `:core` (MCP tool)
- 案 D (CLAUDE.md hint): `:harness_specific` (Claude Code の auto-load が前提)

→ Phase 2 の 80% は `:core` で実現でき、Claude Code 限定機能 (案 D) は明示的に隔離される。これが Phase 1.5 の真の効用。

## §8 既存機能の declared tier 初期分類 (例)

| Tool/Feature | Declared tier | Externals | Note |
|---|---|---|---|
| `context_save` / `get_context` | `:core` | — | MCP + fs |
| `skillset_exchange` (browse/acquire/deposit) | `:core` | — | MCP + Meeting Place は P2P で harness 不問 |
| `context_graph` (Phase 1) | `:core` | — | filesystem walk + BFS |
| `agent_*` (OODA loop) | `:core` | — | MCP のみ |
| `dream_scan` | `:core` | — | filesystem walk |
| `chain_record` / `chain_verify` | `:core` | — | blockchain は内部実装、harness 不問 |
| `multi_llm_review` | `:harness_assisted` | `:claude_cli`, `:codex_cli`, `:cursor_cli` | persona Agent は harness 依存 (Claude Code 内 Agent tool) — Phase 2+ で再分類検討 |
| `multi_llm_review_collect` | `:harness_assisted` | (同上、persona 提出経路) | |
| (Hook handler、もしあれば) | `:harness_specific` | — | harness: `:claude_code` |

multi_llm_review の 2 つの依存 (subprocess CLI と Agent tool) のうち、Phase 1.5 では **subprocess 側のみ articulate**。Agent tool 依存は `note:` フィールドで言及するに留め、Phase 2+ で「persona Agent をどう harness 非依存化するか」を別 design として扱う。

## §9 実装ステップ

1. `lib/kairos_mcp/capability.rb` 新規: `Capability::TIERS` 定数、`Capability.active_harness` (env + auto + cache)、`Capability.aggregate_manifest` (BaseTool subclass walk による集約)
2. `lib/kairos_mcp/tools/base_tool.rb` (既存) に class macro `harness_requirement` 追加。class-level `@harness_requirement_metadata` を保持
3. `lib/kairos_mcp/tools/capability_status.rb` 新規 tool: `capability_status` を返却
4. 既存主要 tool への opt-in 宣言追加 (initial 5-10 個 — 上記 §8 表のもの)
5. `knowledge/kairoschain_capability_boundary/kairoschain_capability_boundary.md` 新規 L1 knowledge
6. `test_capability.rb` 新規テスト suite
7. multi-LLM review (design 段階で 1 round + 実装段階で 1 round)

## §10 テスト suite (列挙)

- env var 優先 (`KAIROS_HARNESS=foo` → `:foo` 返却)
- auto-detect (各 harness の hint で正しい detection)
- 検出不能時 `:unknown` 返却
- DSL 宣言: `:core` / `:harness_assisted` / `:harness_specific` 各 tier で `requires_externals`/`harness`/`note` 等が正しく metadata に格納される
- 宣言無しの tool は `:core` 扱い (forward-only metadata invariant)
- `aggregate_manifest`: 全 BaseTool subclass walk → tier ごとに分類
- `capability_status` tool: 返却 Hash の structure 検証 (`active_harness_source`, `declared`, `observed`, `notes` 全て存在)
- `capability_status` を `:env_var` / `:auto_detect` / `:default` 各 source で呼んだ時の `active_harness_source` 値
- `harness_specific` tool で `harness:` 引数が無い場合のエラー (DSL バリデーション)
- `requires_externals` に未知の Symbol を渡した時の挙動 (warn or accept、policy として decide)
- multi_llm_review が `:harness_assisted` + 3 externals を declared している (regression guard)

## §11 Phase 1.5 で持ち越さない事項 (明示)

- 中央集権 `capabilities.yml` (per-tool metadata に決定済)
- Runtime enforcement / refuse on mismatch (declare-only)
- Harness adapter 層実装 (out of scope)
- 全 SkillSet 改修 (opt-in 構造提供のみ)
- multi_llm_review の persona Agent の harness 非依存化 (Phase 2+)
- `observed` の実行履歴 tracking (Phase 2+)

→ 設計行数: 約 220 行、実装行数の見積もり: 500-800 行

---

*End of v1.0 (4.7 author).*
