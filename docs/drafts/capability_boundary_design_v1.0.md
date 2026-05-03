---
name: capability_boundary_design
description: KairosChain Phase 1.5 — システムが自身の harness 依存を articulate できる仕組み (manifest + introspection + L1 doctrine)。masaomi 指摘の Claude Code / KairosChain 機能 conflation 問題への構造的回答。
tags: [design, capability-boundary, phase1.5, self-articulation, harness, l0, l1]
type: design_draft
version: "1.0"
authored_by: claude-opus-4-7-integrated-with-4.6-subauthor
date: 2026-05-02
---

# KairosChain Phase 1.5: Capability Boundary

## 動機

Phase 1 (Context Graph) 完了直後に masaomi が指摘した懸念:

> 「現状の機能や UX が Claude Code 特有の機能の恩恵なのか、KairosChain の恩恵なのか、を KairosChain 自体がわかっている必要がある」

これは命題 2 (partial autopoiesis: closure at L0、execution は外部基盤依存) と命題 7 (metacognitive self-referentiality: 自身について推論できる) の交点で要請される構造的課題。**KairosChain が自身の境界を articulate できない限り、自己言及性原則 (CLAUDE.md §1) は虚構**。Phase 1.5 はこの articulation 機構を最小実装する。

## §1 設計原則 (不変条件)

本 Phase 1.5 は L0/L1 framework infrastructure として **design-by-invariant** を適用する (memory `feedback_design_by_invariant_scope.md` の "L0/L1 限定" 規定)。

### Self-articulation invariant

**KairosChain は実行時に自身の capability boundary を articulate できなければならない**。具体的には: 実行中の active_harness、利用される external CLI 群、各 tool の harness 依存 tier を runtime introspection で取得可能。articulation の手段は MCP tool (`capability_status`) と L1 knowledge (`kairoschain_capability_boundary`) の二経路を持ち、harness の有無に関わらず機能する。

### Honest unknown invariant

**検出不能時に嘘をつかない**。active_harness が auto-detect で判定不能なら `:unknown` を返却する。"おそらく Claude Code" のような guess は禁止。これは命題 2 の partial autopoiesis を破壊するため (closure 内に虚偽が入ると definitional integrity が崩れる)。env var による明示宣言を最優先し、次に観測可能な hint で補う。

### Declare-not-enforce invariant

**Phase 1.5 の宣言は articulation のためであり、runtime gate のためではない**。harness mismatch (例: claude_cli 必要な tool を claude_cli 不在環境で呼ぶ) を runtime で検出しても refuse しない。既存 error handling (subprocess 失敗等) に委ねる。Pre-flight check は呼び出し側 (LLM) の主体的判断で `capability_status` を呼ぶことで成立する。enforcement が必要になれば Phase 2+ で別 invariant として追加する。

### Structural congruence invariant

**Capability metadata の宣言は、既存の BaseTool DSL pattern (`name`, `category`, `usecase_tags`) と同じ構造的手法 (method override) で表現される**。新しい宣言機構 (class-level macro、外部 manifest 等) は導入しない。理由: 「tool の他のメタデータを記述する方法」と「harness 依存を記述する方法」が異なる構造を取れば、meta-level / base-level の structural correspondence (CLAUDE.md §"Generative Principle") が崩れる。`harness_requirement` は `category` と同格の self-description として配置される。

### Composability invariant

**SkillSet 由来の tool も core tool と同一の宣言機構に参加する**。SkillSet が KairosChain に統合されたとき、その tool の tier 宣言は core tool と区別なく `capability_status` で集約可能でなければならない。これが破れると capability_status の view は SkillSet 境界で常に不完全となり、self-articulation invariant が局所的に破綻する。

### Active vs external separation invariant

**"KairosChain プロセスを駆動する harness (active_harness)" と "KairosChain プロセス内から起動する外部 CLI (used_externals)" は概念的に常に分離される**。両者を 1 つの list に flatten することは禁止。multi_llm_review が Claude Code 上で動きながら codex_cli/cursor_cli を subprocess 起動する典型例で、この分離なくして masaomi 指摘の conflation 問題は articulate できない。

### Forward-only metadata invariant

**`harness_requirement` 宣言は opt-in、無宣言の tool は `:core` 扱い**。既存の全 tool に metadata を遡及付与せず、後方互換を保つ。理由: 大多数の MCP tool は実際 core (MCP プロトコルとファイルシステムのみ) であり default として正しい。明示的に harness 依存があるもののみ宣言する。

## §2 Tier definition (3 段階の判定基準)

Tier は **「その機能を実行するために何が必要か」** で決定される。判定は以下の単一 invariant で行う:

> **tier の上位は下位を真包含する**: `:core` で動くものは `:harness_assisted` でも `:harness_specific` 環境でも動く。逆は成立しない。

具体的判定 rule:

- **`:core`** — MCP プロトコル + filesystem のみで完結する。subprocess 起動も harness-specific tool 呼び出しも行わない。harness が何であるか (あるいは `:unknown`) に関わらず機能の欠損がない。
- **`:harness_assisted`** — 外部プロセス起動 (subprocess CLI)、harness 固有 API、ネットワーク接続等の追加リソースを利用する。これらが不在でも graceful に失敗するか、`degrades_to:` で記述された縮退 mode で動く。
- **`:harness_specific`** — 特定 harness 内でのみ意味を持つ。原理的にその harness 外では呼べない。例: Claude Code Hooks 連携、plugin projection 系。

判定境界例: 「harness 上で MCP tool として呼ばれるが、その harness の特殊機能 (subagent delegation 等) を必須とする」場合は `:harness_specific`。「外部 CLI を呼ぶが代替手段がある」場合は `:harness_assisted`。

## §3 Active harness 検出

検出は以下の優先順位で行われる:

1. **環境変数 `KAIROS_HARNESS`** が set されていれば、その値をそのまま採用 (Symbol 化して返却)。Enum 制約は設けず、未知の harness 名もそのまま受容する (Honest unknown 精神)
2. **Auto-detect hints** を順に評価。hint は実装内の探索ロジックとして持つ (将来 hint 追加で拡張)。Hint 例: 親プロセス名、harness 固有の env var (`CLAUDE_CODE_*` 等)、CWD に CLAUDE.md/MEMORY.md 存在、MCP transport 特性 (stdio vs HTTP)
3. いずれも match しなければ `:unknown` を返却

検出ロジックは pure function (副作用なし) として実装し、test 容易性を確保する。**検出結果は process boot 時に 1 回 cache** する (再評価せず、env 変更に追従しない)。これは命題 2 の "L0 級閉包" を反映: 起動時の harness 認識が 1 process lifetime の閉包を構成する。

返却構造:

```ruby
{
  active_harness: :claude_code,    # or :unknown
  detection_method: :env_var,      # :env_var | :auto_detect | :none
  confidence: :explicit            # :explicit | :inferred | :unknown
}
```

`detection_method` と `confidence` は冗長に見えるが、用途が異なる: `detection_method` は **どこから情報を得たか** (provenance)、`confidence` は **どれだけ信頼してよいか** (epistemic)。`:env_var` は常に `:explicit`、`:auto_detect` は `:inferred`、`:none` は `:unknown`。

## §4 BaseTool DSL: `harness_requirement`

既存 BaseTool の `name` / `category` / `usecase_tags` と同じ method override pattern で宣言する (Structural congruence invariant)。

```ruby
class ContextSave < KairosMcp::Tools::BaseTool
  def name; 'context_save'; end
  def category; :context; end
  def harness_requirement; :core; end   # default と同値だが明示
  # ... 既存実装変更なし
end

class MultiLLMReview < KairosMcp::Tools::BaseTool
  def name; 'multi_llm_review'; end
  def category; :skills; end
  def harness_requirement
    {
      tier: :harness_assisted,
      requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
      degrades_to: 'persona-only review (Agent tool personas within active harness)',
      note: 'persona Agent reviews delegate back to orchestrator harness — Phase 2+ refactor candidate'
    }
  end
end

# SkillSet tool — core tool と同一機構 (Composability invariant)
class PluginProject < KairosMcp::Tools::BaseTool
  def harness_requirement
    {
      tier: :harness_specific,
      target_harness: :claude_code,
      reason: 'Generates Claude Code plugin artifacts (SKILL.md, agents/)'
    }
  end
end

# 宣言なし → BaseTool default の :core (Forward-only metadata invariant)
class LegacyTool < KairosMcp::Tools::BaseTool
  # harness_requirement 不在
end
```

返却値は **Symbol** (`:core`) **または Hash** (`{ tier:, requires_externals:, ... }`) のいずれか。Capability module の `normalize_requirement` helper が両形式を Hash 形式に正規化して introspection に渡す。

引数 schema (Hash 形式時):

| Key | 型 | 必須? | 内容 |
|---|---|---|---|
| `:tier` | Symbol | yes | `:core` / `:harness_assisted` / `:harness_specific` |
| `:requires_externals` | Array of Symbol | no | subprocess 起動する外部 CLI 名 (推奨命名: `:claude_cli`, `:codex_cli`, `:cursor_cli`) |
| `:degrades_to` | String | no | 不足時の degraded behavior 説明 (LLM が読む) |
| `:target_harness` | Symbol | `:harness_specific` 時 yes | required harness 名 |
| `:reason` | String | no | なぜこの tier か (LLM への doctrine) |
| `:note` | String | no | 自由記述 (Phase 移行メモ等) |

BaseTool の default 実装:

```ruby
class BaseTool
  def harness_requirement
    :core
  end
end
```

## §5 `capability_status` tool 仕様

入力: `filter_tier`, `include_observed` (両方 optional)。

出力 (3 層構造: declared / observed / tension):

```ruby
{
  kairos_version: "3.24.4",

  # Observed: 実行環境の動的検出結果
  observed: {
    active_harness: :claude_code,
    detection_method: :env_var,
    confidence: :explicit,
    used_externals: [:codex_cli, :cursor_cli],   # active_harness と同源は除外
    external_availability: {
      claude_cli: { available: true, version: '...' },
      codex_cli: { available: true, version: '...' },
      cursor_cli: { available: false, reason: 'not found in PATH' }
    }
  },

  # Declared: tool の自己宣言の集約 (build 時に確定)
  declared: {
    summary: { core: 42, harness_assisted: 3, harness_specific: 1, undeclared: 0 },
    tools: [
      { name: 'context_save', tier: :core, source: :core_tool },
      { name: 'multi_llm_review', tier: :harness_assisted,
        requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
        degrades_to: 'persona-only review',
        source: :core_tool },
      { name: 'plugin_project', tier: :harness_specific,
        target_harness: :claude_code,
        source: 'skillset:plugin_projector' }
    ]
  },

  # Tension: declared と observed の交差検出 (informational only、Declare-not-enforce)
  tension: [
    { tool: 'multi_llm_review',
      issue: 'declares cursor_cli but cursor_cli not found in PATH',
      severity: :degraded }
  ],

  notes: [
    "active_harness=:claude_code means KairosChain process is running under Claude Code harness.",
    "claude_cli is the same source as active_harness (claude_code); not listed as external when active_harness=:claude_code.",
    "Tools declared :core work on any harness (including raw API).",
    "tension entries are informational; tools are not refused at runtime (Declare-not-enforce invariant)."
  ]
}
```

`declared` / `observed` / `tension` の三層は metacognitive self-referentiality (命題 7) を構造に反映: **静的な自己宣言 + 動的な環境観測 + 両者の交差** という 3 視点を併置する。`tension` セクションは harness_assisted tool の externals が PATH に不在の時に自動的に populated される (但し refuse はしない)。

`include_observed: false` を渡すと declared のみ返却 (LLM が静的構造だけ知りたい場合の軽量 view)。

## §6 哲学的位置づけ

### masaomi 指摘の conflation 問題への構造的回答

「KairosChain の機能なのか Claude Code の機能なのか区別がつかない」という問題は、命題 2 (partial autopoiesis) の実践的帰結として構造的に必然である。KairosChain は定義レベルでは自己閉鎖的だが、実行レベルでは外部基盤に依存する。この依存が不透明であるとき、system は自身の autopoietic boundary を正確に認識できない。

Phase 1.5 は、この boundary を system 自身が articulate する機構を導入することで、命題 2 の "at which abstraction level does the loop close?" という問いに実装レベルで答える: **定義・宣言レベルでは close する** (tool は自身の tier を宣言できる)、**実行レベルでは open のまま** (harness が何であれ tool は呼べる)。

### 命題 7 (Metacognitive self-referentiality) との対応

`capability_status` は system が自身の構成と環境について推論する具体的 interface である。「どの機能が harness に依存し、その harness は今利用可能か」という問いに答えられることは、metacognitive self-referentiality の最小要件の一つ。3 層構造 (declared / observed / tension) は metacognition の 3 視点 (静的自己理解 / 動的環境認識 / 交差による不整合検出) に対応する。

### 命題 9 (Human-system composite) との対応

Harness (Claude Code, Codex, Cursor) は human-system composite の interface 層である。Human は harness を通じて KairosChain と対話する。Phase 1.5 が harness 依存を articulate することは、composite のどの層がどの能力を提供しているかを明示化する行為であり、命題 9 の「human is on the boundary」を構造に反映する。

## §7 Phase 2 への含意

Phase 2 で予定される 4 案は、Phase 1.5 で定義した tier に則って分類される:

| Phase 2 案 | Declared tier | 理由 |
|---|---|---|
| 案 A: L1 skill `context_graph_recall` | `:core` | MCP knowledge として読まれる、harness 非依存 |
| 案 B: `dream_scan mode:scan` の edges 拡張 | `:core` | MCP tool 出力 |
| 案 C: reverse traversal | `:core` | MCP tool |
| 案 D: CLAUDE.md hint で auto-recall promote | `:harness_specific` (claude_code) | Claude Code の auto-load が前提 |

**Phase 2 の 80% は `:core` で実現でき、Claude Code 限定機能 (案 D) は明示的に隔離される**。これが Phase 1.5 の真の効用 — Phase 2 設計時に「これは KairosChain native か、Claude Code 上での便利機能か」を tier 宣言で構造的に明示できる。

加えて、Phase 1.5 の tier 宣言が存在することで、Phase 2 は「全機能を一律に整備する」のではなく「tier ごとに適切な整備戦略を選択する」ことが可能になる。

## §8 既存機能の declared tier 初期分類

| Tool / Feature | Declared tier | Externals / Note |
|---|---|---|
| `context_save` / `get_context` | `:core` | MCP + fs |
| `context_create_subdir` | `:core` | MCP + fs |
| `chain_record` / `chain_verify` / `chain_history` | `:core` | blockchain は内部実装 |
| `knowledge_get` / `knowledge_list` / `knowledge_update` | `:core` | L1 knowledge 読み出し/更新 |
| `skills_promote` / `skills_evolve` / `skills_rollback` | `:core` | layer 遷移、persona assembly は LLM 内部 |
| `skillset_*` (browse / acquire / deposit / withdraw) | `:core` | Meeting Place は P2P で harness 不問 |
| `context_graph` (Phase 1: `dream_scan mode:traverse`) | `:core` | filesystem walk + BFS |
| `dream_scan` (mode: scan) / `dream_propose` / `dream_archive` | `:core` | filesystem walk |
| `agent_start` / `agent_step` / `agent_status` / `agent_stop` | `:harness_assisted` | LLM 呼出に llm_client SkillSet 使用、その backend が subprocess CLI 依存 |
| `multi_llm_review` / `multi_llm_review_collect` | `:harness_assisted` | requires_externals: `[:claude_cli, :codex_cli, :cursor_cli]` / persona Agent は active_harness 経由 |
| `capability_status` (新規、Phase 1.5) | `:core` | 自身が harness 依存では self-articulation が再帰的矛盾になる |
| `plugin_project` (skillset_creator 系) | `:harness_specific` | `target_harness: :claude_code`、Claude Code plugin artifact 生成が存在理由 |

multi_llm_review の 2 つの依存 (subprocess CLI と Claude Code 内 Agent tool への persona delegation) のうち、Phase 1.5 では **subprocess 側を `requires_externals` で articulate**。Agent tool 依存は `note:` フィールドで言及するに留め、Phase 2+ で「persona Agent をどう harness 非依存化するか」を別 design として扱う。

note: この表は initial assignment であり、各 tool maintainer (実装時の author) が宣言を精査・修正する。

## §9 実装ステップ

1. **Capability module 新設** (`lib/kairos_mcp/capability.rb`): `Capability::TIERS` 定数、`Capability.detect_harness` (env + auto + cache)、`Capability.normalize_requirement` (Symbol/Hash → 正規 Hash)、`Capability.aggregate_manifest` (BaseTool subclass walk)
2. **BaseTool DSL** (既存 `lib/kairos_mcp/tools/base_tool.rb`): `harness_requirement` default 実装 (`:core`) を追加
3. **capability_status tool 新規** (`lib/kairos_mcp/tools/capability_status.rb`): declared / observed / tension の 3 層集約
4. **既存主要 tool への opt-in 宣言** (§8 の 10+ tool): `harness_requirement` method override 追加
5. **L1 knowledge 新規** (`knowledge/kairoschain_capability_boundary/`): doctrine document、LLM が capability_status を pre-flight check として使う指針を含む
6. **Tests 新規** (`test_capability.rb`)
7. **Multi-LLM review** (設計段階で 1 round + 実装段階で 1 round)

## §10 テスト suite (列挙)

- env var 優先 (`KAIROS_HARNESS=foo` → `:foo` 返却)
- auto-detect (各 harness の hint で正しい detection)
- 検出不能時 `:unknown` + `confidence: :unknown` 返却
- Process boot cache (env を mid-runtime 変更しても detection 結果は変わらない)
- DSL 宣言: Symbol 形式 / Hash 形式の両方が正しく `normalize_requirement` で正規化される
- 宣言無しの tool は `:core` 扱い (Forward-only metadata invariant)
- `aggregate_manifest`: 全 BaseTool subclass walk → tier ごとに分類
- SkillSet 由来 tool が core tool と同等に集約される (Composability invariant)
- `capability_status` 返却 Hash の structure 検証 (declared / observed / tension / notes 全て存在)
- `capability_status` の `:env_var` / `:auto_detect` / `:none` 各 detection_method 値
- Tension: `:harness_assisted` tool で declared external が PATH 不在のとき tension に entry 追加
- Declare-only: tension 存在時も tool は呼び出し可能 (refuse されない)
- `harness_specific` tool で `target_harness:` 不在時のエラー (DSL バリデーション)
- multi_llm_review が `:harness_assisted` + 3 externals で declared (regression guard)

## §11 Phase 1.5 で持ち越さない事項 (明示)

- 中央集権 `capabilities.yml` (per-tool metadata に決定済、Structural congruence invariant)
- Runtime enforcement / refuse on mismatch (Declare-not-enforce invariant)
- Harness adapter 層実装 (out of scope、Phase 3+ で個別検討)
- 全 SkillSet 改修 (Composability invariant の構造提供のみ、各 SkillSet maintainer が後付け)
- multi_llm_review の persona Agent の harness 非依存化 (Phase 2+)
- `tension` 検出ロジックの fine-tuning (Phase 1.5 では PATH which-style check のみ、より高度な availability check は Phase 2+)
- 過去の実行履歴 tracking (動的観測の永続化、Phase 2+)

→ 設計行数: 約 250 行、実装行数の見積もり: 500-800 行

---

## Appendix: Reject log (4.7 author × 4.6 sub-author 統合の意思決定)

本 v1.0 は 4.7 と 4.6 の独立 draft (`v1.0-4.7.md` / `v1.0-4.6.md`) を 4.7 が統合した。重要な統合判断:

| 項目 | 採否 | 理由 |
|---|---|---|
| 4.6: Structural Congruence invariant (DSL は既存 method override pattern と一致) | **採用** | 命題 1 (structural self-referentiality) との整合が強く、4.7 案の class macro より哲学的に正しい |
| 4.6: Composability invariant (SkillSet tool も同一機構) | **採用** | self-articulation が SkillSet 境界で破綻しないために必須、4.7 案には欠落 |
| 4.6: capability_status の 3 層 (declared/observed/tension) | **採用** | 4.7 案の 2 層 (declared/observed) より metacognitive 構造を反映、tension が actionable |
| 4.6: `external_availability` の runtime PATH check | **採用** | tension 検出に必要、4.7 案には無し |
| 4.6: `detection_method` + `confidence` 別フィールド | **採用** | provenance と epistemic が概念的に独立、4.7 案の `active_harness_source` 単一より articulate |
| 4.7: Forward-only metadata invariant の明示化 | **採用** | 4.6 案では §2 default に implicit、明示する方が後方互換要請が明確 |
| 4.7: Phase 2 案 A〜D の tier 分類表 (§7) | **採用** | 4.6 案は abstract、具体的 mapping が Phase 2 設計判断を inform する |
| 4.7: §11 持ち越さない事項の明示 | **採用** | anti-enumeration スタイルで scope を rigid に articulate |
| 4.7: Process boot 時 cache の明示 | **採用** | 命題 2 の "L0 級閉包" を反映、4.6 案では implicit |
| 4.6: agent_* を `:harness_assisted` に分類 | **採用** | llm_client SkillSet 経由で subprocess CLI を呼ぶため、4.7 案の `:core` 分類は誤り |
| 4.7: class macro DSL (`harness_requirement :core`) | **却下** | 4.6 の method override pattern (既存 BaseTool と一致) の方が Structural congruence invariant に整合 |
| 4.7: `active_harness_source` 単一フィールド | **却下** | 4.6 の `detection_method` + `confidence` の方が articulate |
| 4.7: 5 invariants (composability 欠落版) | **却下** | 4.6 の 5 invariants をベースに 7 invariants へ拡張 (4.7 の Forward-only と Active-vs-external を追加) |
| 4.6: 5 invariants (Forward-only と Active-vs-external が欠落) | **部分却下** | 5 invariants をベースとし、4.7 の 2 つを補う形で 7 invariants 構成に |
| 4.6: §8 で Note: this table is initial assignment | **採用** | maintainer 精査の余地を明示するのが正直 |

→ 結果として **invariants 7 個** (4.6 由来 5 + 4.7 由来 2)、**DSL は 4.6 method override pattern**、**capability_status output は 4.6 の 3 層構造**、**Phase 2 mapping と §11 持ち越し明示は 4.7**。

---

*End of v1.0 (integrated by claude-opus-4-7 from 4.7 + 4.6 sub-author drafts).*
