---
name: capability_boundary_design
description: KairosChain Phase 1.5 v1.1 — round 1 multi-LLM review (4 APPROVE / 1 REJECT) で発見された P0/P1 を吸収。masaomi reframe で核心 invariant 追加 (Acknowledgment) — 依存を避けるのではなく依存を能動的に articulate することで自己過大評価を防ぐ。
tags: [design, capability-boundary, phase1.5, self-articulation, harness, l0, l1, acknowledgment]
type: design_draft
version: "1.1.1"
authored_by: claude-opus-4-7-with-masaomi-reframe
supersedes: capability_boundary_design_v1.0
date: 2026-05-03
---

# KairosChain Phase 1.5: Capability Boundary (v1.1)

## 動機 (v1.0 から不変)

masaomi 指摘の conflation 問題への構造的回答として、KairosChain が自身の harness 依存を articulate する機構を最小実装する。

## v1.0 → v1.1 の主要変更

v1.0 multi-LLM review (5 reviewers, 4A/1R, REVISE) と、masaomi の **reframe (依存を避けるのでなく能動的に認識する)** に基づく patch:

1. **新 invariant 追加 — Acknowledgment invariant** (静的宣言から runtime acknowledgment への拡張)
2. **F6 解決方針変更**: capability_status の subprocess 利用は否定せず、**per-section `tier_used:` self-annotation** で正直に申告
3. **F8 取り込み**: `delivery_channels:` section 追加 (LLM-recognition surface)
4. **F9 取り込み**: `requires_harness_features:` + `fallback_chain:` + runtime `harness_assistance_used:`
5. **F1〜F5、F7、F10、F11**: text fix で吸収 (詳細は §12 patch log)

## §1 設計原則 (8 不変条件、新 invariant 追加)

### Self-articulation invariant (v1.0 から不変)

KairosChain は実行時に自身の capability boundary を articulate できなければならない。articulation 手段は MCP tool (`capability_status`) と L1 knowledge (`kairoschain_capability_boundary`) の二経路。

### Honest unknown invariant (v1.0 から不変)

検出不能時に嘘をつかない。`:unknown` を返却。env var による明示宣言を最優先、次に **harness ネイティブな観測可能 hint で補う** (CWD 内の repository artifact = `CLAUDE.md`/`MEMORY.md` 等は **除外** — それらは harness の signature ではなく project の signature であり、循環的な self-conflation を起こす)。

### Declare-not-enforce invariant (v1.0 から不変、補強)

宣言は articulation のためであり、runtime gate のためではない。**Tension 報告は informational only** であり enforcement ではない。LLM caller が tension を見て tool 呼び出しを避ける (caller-side 自主判断) のは想定内であり、これは enforcement ではなく guidance pressure と区別される。

### Structural congruence invariant (v1.0 から不変)

Capability metadata の宣言は、既存の BaseTool DSL pattern (`name`, `category`, `usecase_tags`) と同じ method override pattern で表現される。

### Composability invariant (v1.0 から不変)

SkillSet 由来の tool も core tool と同一の宣言機構に参加する。

### Active vs external separation invariant (v1.0 から強化)

`active_harness` と `used_externals` は概念的に分離される。**Same-source exclusion rule (新明示)**: `active_harness` と同源の CLI (例: `active_harness=:claude_code` 時の `claude_cli`) は **`used_externals` から除外** する。理由: 同一 harness の reentrant 呼び出しは「他者協力」ではなく「自身の能力」の延長と見なすべき (acknowledgment invariant の境界規定)。

### Forward-only metadata invariant (v1.0 から強化)

`harness_requirement` 宣言は opt-in。**ただし manifest entry に `declared: true/false` boolean を含める** (新明示) — 「未宣言で `:core` default」と「明示宣言で `:core`」を articulate 上区別する。これにより capability_status は「N tool 中 M tool が明示宣言済」を honest に報告できる。

### Acknowledgment invariant (新、v1.1 で追加 — masaomi reframe より)

**KairosChain の operation が外部 (harness adapter, subprocess CLI, harness-specific feature) に依存する場合、その依存を operation の output で能動的に articulate しなければならない**。Silent absorption は禁止。Static manifest 宣言だけでなく **runtime acknowledgment** も含む。

**Honest unknown invariant との区別 (v1.1.1 明示)**: Honest unknown は **検出失敗 (epistemology)** を扱う — 「何が動いているか分からない時に嘘をつかない」。Acknowledgment は **成功した依存実行 (articulation duty)** を扱う — 「使ったものを正直に申告する」。両者は異なる軸で動作し、`:unknown` 返却と `harness_assistance_used:` field 出力は補完的。

具体的に:
- 静的: 各 tool の `harness_requirement` 宣言で依存を declare
- 動的: tool execution が実際に harness 経路を使った場合、response に `harness_assistance_used:` field を含めて「今回の呼び出しでどの依存が exercised されたか」を articulate
- 集約: capability_status の各 section に `tier_used:` annotation で「この情報をどの tier の操作で取得したか」を申告

動機 (masaomi articulation の引用):

> 「常に自分自身の能力で仕事をしているのか、誰かの協力で仕事が達成できているのかを認識していることは感謝の気持ちにもつながりますし、自己能力の過大評価を防げます」

これは命題 7 (metacognitive self-referentiality) を **静的 introspection から動的 awareness に拡張** する操作。冗長に見える acknowledgment も、conflation の根本予防として valuable。

## §2 Tier definition (v1.0 から拡張)

Tier は単一 invariant で決定: **tier の上位は下位を真包含する**。

- **`:core`** — MCP プロトコル + filesystem (`File.executable?` 等の syscall 含む) のみで完結。subprocess 起動も harness-specific tool 呼び出しも行わない
- **`:harness_assisted`** — 外部リソース (subprocess CLI、network endpoint、API credential 等) を利用。不在時は `degrades_to:` で記述された縮退 mode で動くか、graceful に失敗
- **`:harness_specific`** — 特定 harness 内でのみ意味を持つ。原理的にその harness 外では呼べない

`:harness_assisted` の **依存表現**: 一次形式は `requires_externals: [Symbol]` (CLI 名)、Phase 2+ で network endpoint や API credential も同様の構造で expand 可能 (Hash 形式で `{kind: :network_endpoint, url: ...}` 等)。Phase 1.5 では Symbol = CLI のみ実装。

## §3 Active harness 検出 (v1.0 から修正)

優先順位:

1. **環境変数 `KAIROS_HARNESS`** が set されていれば、その値を Symbol 化して採用。**Validation**: 値が String として well-formed (alnum + `_-`、長さ 1-64) であれば accept、malformed なら warn + `:unknown` (Honest unknown 適用)
2. **Auto-detect hints** (実装内に持つ): 親プロセス名、harness 固有 env var (`CLAUDE_CODE_*` 等の、harness が自己宣言的に set する変数)、MCP transport 特性 (stdio vs HTTP)。**CWD 内の `CLAUDE.md` / `MEMORY.md` 存在は hint に含めない** — これらは project artifact であり harness signature ではない (F5 改修)
3. いずれも match しなければ `:unknown` 返却

検出は pure function、process boot 時に 1 回 cache。Process lifetime 中に env が変更されても cache は不変 (operational stability、L0 governance closure の運用層反映 — 「L0 級閉包そのもの」とは区別する: L0 は governance/capability-definition level の closure、process boot cache はその運用反映)。**`Capability.reset!` は test-only escape hatch** であり production code では呼ばれない (v1.1.1 明示)。

返却:
```ruby
{
  active_harness: :claude_code,    # or :unknown
  detection_method: :env_var,      # :env_var | :auto_detect | :none
  confidence: :explicit            # :explicit | :inferred | :unknown
}
```

## §4 BaseTool DSL: `harness_requirement` (v1.0 から大幅拡張)

method override pattern (既存 `name` / `category` と同型):

```ruby
class ContextSave < KairosMcp::Tools::BaseTool
  def harness_requirement; :core; end   # default と同値、明示宣言
end

class MultiLLMReview < KairosMcp::Tools::BaseTool
  def harness_requirement
    {
      tier: :harness_assisted,
      requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
      requires_harness_features: [
        {
          feature: :agent_tool,
          target_harness: :claude_code,
          used_for: 'persona unanimity gate (default path)',
          degrades_to: 'direct API persona invocation'
        }
      ],
      fallback_chain: [
        { path: 'claude_code_agent_personas', tier: :harness_specific, target_harness: :claude_code,
          condition: 'running under Claude Code with Agent tool available' },
        { path: 'direct_api_personas',        tier: :harness_assisted,
          condition: 'API credentials configured for direct LLM calls' },
        { path: 'manual_suggestion',          tier: :core,
          condition: 'always available; KairosChain provides procedure, human executes' }
      ],
      acknowledgment: 'multi_llm_review primary value (persona unanimity gate) is harness-coupled; this declaration makes that explicit'
    }
  end
end
```

**返却値の正規化** (Capability::normalize_requirement):
- `:core` → `{ tier: :core }`
- Symbol その他 → `{ tier: <symbol> }`
- Hash → 入力 Hash (key 検証あり)

**Lazy validation** (F2): `normalize_requirement` 内で以下をチェック、違反時 `ArgumentError`:
- `tier` が `Capability::TIERS` のいずれか
- `tier == :harness_specific` の時 `target_harness:` 必須
- `requires_harness_features:` の各 entry が Hash で `feature:` + `target_harness:` を持つ
- `fallback_chain:` の各 entry が `path:` + `tier:` + `condition:` を持つ
- **fallback_chain entry の `tier == :harness_specific` の時、その entry にも `target_harness:` 必須** (v1.1.1、R3 fix — top-level rule との整合)

Validation は class 定義時ではなく `aggregate_manifest` / `capability_status` 呼び出し時に走る (lazy)。

**Partial-failure policy (v1.1.1 明示)**: `aggregate_manifest` 中に 1 tool の metadata が validation 失敗した場合、その tool は **skip + warn** — `tension[]` に `{tool:, issue: 'invalid harness_requirement: ...', severity: :declaration_error}` として記録、他の tool の集約は継続する。1 tool の宣言バグで全体集約が崩れない。

**引数 schema (Hash 形式時)**:

| Key | 型 | 必須 | 内容 |
|---|---|---|---|
| `:tier` | Symbol | yes | `:core` / `:harness_assisted` / `:harness_specific` |
| `:requires_externals` | Array of Symbol | no | subprocess 起動する外部 CLI 名 |
| `:requires_harness_features` | Array of Hash | no | harness 固有機能依存。各 Hash は `feature:`/`target_harness:`/`used_for:`/`degrades_to:` |
| `:fallback_chain` | Array of Hash | no | 依存解決経路の cascading 順。各 Hash は `path:`/`tier:`/`target_harness?:`/`condition:` |
| `:degrades_to` | String | no | 全 fallback 失敗時の縮退説明 |
| `:target_harness` | Symbol | `:harness_specific` 時 yes | 単一 harness 名 |
| `:reason` / `:note` / `:acknowledgment` | String | no | LLM への doctrine 周知 |

## §5 `capability_status` tool 仕様 (v1.0 から大幅拡張)

入力: `filter_tier` (optional)、`include_observed` (default true)、`probe_externals` (default false — true 時のみ subprocess 経由で version 取得)。

### 出力構造 (per-section `tier_used:` annotation 付き)

```ruby
{
  kairos_version: "3.24.4",

  # 全体の acknowledgment summary
  acknowledgment: 'KairosChain capability boundary self-articulation. Each section reports its own tier_used.',

  declared: {
    tier_used: :core,                       # 静的 manifest 集約は subprocess 不要
    summary: { core: 42, harness_assisted: 3, harness_specific: 1, undeclared_default_core: 5 },
    tools: [
      { name: 'context_save', tier: :core, declared: true, source: :core_tool },
      { name: 'legacy_tool',  tier: :core, declared: false, source: :core_tool,
        note: 'tier inferred from undeclared default (Forward-only metadata)' },
      { name: 'multi_llm_review', tier: :harness_assisted, declared: true,
        requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
        requires_harness_features: [{ feature: :agent_tool, target_harness: :claude_code, ... }],
        fallback_chain: [...],
        source: :core_tool },
      { name: 'plugin_project', tier: :harness_specific, declared: true,
        target_harness: :claude_code, source: 'skillset:plugin_projector' }
    ]
  },

  observed: {
    active_harness: {
      tier_used: :core,                     # env + filesystem only
      value: :claude_code,
      detection_method: :env_var,
      confidence: :explicit
    },
    used_externals: {
      tier_used: :core,                     # 宣言情報の集約のみ
      value: [:codex_cli, :cursor_cli],     # claude_cli は same-source exclusion
      same_source_excluded: [:claude_cli],
      acknowledgment: 'claude_cli excluded because active_harness=:claude_code (same-source rule)'
    },
    external_availability: {                 # probe_externals: true の時のみ存在
      tier_used: :harness_assisted,         # ← 正直に: subprocess 経由
      acknowledgment: 'this section was obtained via local CLI invocation (which-style PATH check + optional --version subprocess) — NOT a :core operation',
      claude_cli: { available: true, version: '...' },
      codex_cli:  { available: true, version: '...' },
      cursor_cli: { available: false, reason: 'not found in PATH' }
    }
  },

  # 新規 (F8): LLM が認識すべき harness 経由配信 channel
  delivery_channels: {
    tier_used: :core,                       # 集約自体は宣言情報のみ
    acknowledgment: 'these channels deliver content to the LLM but are NOT KairosChain native — content may be KairosChain doctrine, but delivery is harness feature',
    active: [
      {
        channel: :claude_md_autoload,
        harness: :claude_code,
        content_type: :doctrine,
        example_items: ['Multi-LLM Review Philosophy Briefing'],
        kairoschain_native_content: true,
        kairoschain_native_delivery: false,
        note: 'briefing content is KairosChain doctrine; delivery via Claude Code CLAUDE.md auto-load'
      },
      {
        channel: :memory_md_autoload,
        harness: :claude_code,
        content_type: :context_index,
        example_items: ['Active Resume Points'],
        kairoschain_native_content: true,
        kairoschain_native_delivery: false
      },
      {
        channel: :skill_auto_trigger,
        harness: :claude_code,
        content_type: :skill_invocation,
        kairoschain_native_content: 'depends on skill',
        kairoschain_native_delivery: false
      }
    ]
  },

  tension: [
    { tool: 'multi_llm_review',
      issue: 'declares cursor_cli but cursor_cli not found in PATH',
      severity: :degraded,
      acknowledgment: 'informational only; tool may still be invoked (Declare-not-enforce)' }
  ],

  notes: [
    "Same-source exclusion rule: active_harness と同源の CLI は used_externals から除外される。",
    "delivery_channels は capability boundary の 4 つ目の articulation 軸 (declared/observed/tension に加えて)。",
    "tier_used は per-section で異なる — capability_status 自身が複数 tier の操作を内包することの honest acknowledgment。",
    "include_observed: false の時、observed / tension / external_availability は省略される (tension は observed の cross-product なので)。"
  ]
}
```

**`include_observed: false` 時** (F1): observed / tension / external_availability すべて omit、`declared` と `delivery_channels` (これは静的 manifest なので observed 不要) と `notes` のみ返却。

**`probe_externals: false` (default) 時**: external_availability section omit、subprocess 起動なし、capability_status 全体が `:core` 操作で完結。

**`probe_externals: true` 時**: external_availability section が tier_used: `:harness_assisted` で含まれる。Phase 1.5 では `which`-style PATH check (Ruby 純実装、subprocess 不要) のみ default、`probe_versions: true` を別途渡すと `--version` subprocess が走る (これも acknowledgment で正直に申告)。

**Probe flag truth table (v1.1.1 明示)**:

| `probe_externals` | `probe_versions` | external_availability section | subprocess 起動 |
|---|---|---|---|
| `false` (default) | `*` (無視) | omit | なし |
| `true` | `false` (default) | 含む、PATH check のみ (`File.executable?` ベース) | なし |
| `true` | `true` | 含む、PATH check + 各 CLI の `--version` | あり (各 CLI で 1 回) |

**`delivery_channels.tier_used: :core` の意味 (v1.1.1 明示)**: この tier_used は **「この section の集約処理 (manifest を読んで articulation する) が core 操作」** の意。**section が報告している内容の依存性ではない**。Section 内の各 entry には `kairoschain_native_delivery: false` 等で「報告される依存」が個別に articulate されている。誤読防止の note を section 直下に含める。

**`declared` キーの二重語義 (v1.1.1 明示)**: 出力構造の最上位 section 名 `declared:` (静的 manifest を意味) と、各 tool entry 内の `declared: true/false` field (Forward-only metadata、明示宣言済か否か) は **同名で異なる意味**。Consumer 側はネスト深さで判別する (top-level vs nested)。L1 doctrine で読み取り pattern を明記。

## §6 Per-invocation acknowledgment helper

新 `:harness_assisted` / `:harness_specific` tool の response に **runtime acknowledgment** を含めるための共通 helper を BaseTool に追加:

**Helper の wrap pattern (v1.1.1 修正、R1 fix)**: MCP tool の response は `text_content(...)` (Array of `{type: 'text', text: <json>}`) で返却される。`with_acknowledgment` は **block が inner Hash を返すこと**を期待し、helper 自身が `harness_assistance_used:` を merge した上で `text_content(JSON.pretty_generate(...))` 化する。tool の `call` メソッドは block の戻り値が Hash (text_content 化前) であることに注意:

```ruby
class BaseTool
  # 使用例:
  #
  # def call(args)
  #   with_acknowledgment(path_taken: 'claude_code_agent_personas',
  #                       tier: :harness_specific,
  #                       target_harness: :claude_code) do
  #     # 内部 Hash を返す (text_content 化前)
  #     { result: '...', status: 'ok' }
  #   end
  # end
  #
  # 戻り値は text_content 化済 (MCP response format)
  #
  def with_acknowledgment(path_taken:, tier:, target_harness: nil, &block)
    inner = block.call
    raise ArgumentError, 'with_acknowledgment block must return Hash' unless inner.is_a?(Hash)
    ack = {
      path_taken: path_taken,
      tier_actually_used: tier,
      target_harness: target_harness,
      acknowledgment: "this invocation used #{tier} path '#{path_taken}'#{target_harness ? " (target_harness: #{target_harness})" : ''} — articulated per Acknowledgment invariant"
    }
    merged = inner.merge(harness_assistance_used: ack)
    text_content(JSON.pretty_generate(merged))
  end
end
```

**適用範囲**: Phase 1.5 では multi_llm_review に canonical example として適用。他の `:harness_assisted` / `:harness_specific` tool の adoption は **Forward-only metadata invariant pattern** で時間をかけて進める (一斉改修強制せず)。

**Forward-only と Acknowledgment の関係 (v1.1.1 明示)**: ある tool が静的に `harness_requirement` を declared している (declared: true) ことは、その tool が将来 `with_acknowledgment` を適用する **structural commitment** を意味する。declared without runtime ack は **既知の transient state** であり permanent exemption ではない。Phase 1.5 では multi_llm_review のみ完全実装、他は宣言のみ。

## §7 哲学的位置づけ

### masaomi reframe (v1.1 で吸収)

v1.0 設計は「依存を tier で分類」する static articulation 中心だった。masaomi reframe で **依存を runtime で能動的に認識する** dynamic awareness に拡張された。

人間メタファ: 「常に自分自身の能力か他者協力かを認識している」状態 = 感謝・自己過大評価防止。これを system 設計に翻訳: 各 operation で「今回どの依存を使ったか」を articulate する冗長性を valuable と認める。

**Acknowledgment invariant の Proposition 2 (Partial autopoiesis) との対応 (v1.1.1 明示)**: Acknowledgment invariant は命題 7 の運用拡張だけでなく、**命題 2 を honest に運用する条件**でもある。Partial autopoiesis は「定義レベルで closure、実行レベルで外部依存」と articulate するが、その外部依存が silent に absorb されていれば autopoiesis の境界主張は虚構化する。Acknowledgment は execution-layer の external dependence を能動的に surface することで partial autopoiesis を honest に保つ。

### conflation 問題への構造的回答 (深化)

v1.0 では tool tier 分類で conflation を articulate していた。v1.1 では追加で:

- **delivery channel 分類** (F8): CLAUDE.md/MEMORY.md auto-load が KairosChain native でないことを LLM 側が認識可能に
- **per-invocation acknowledgment** (F9): multi_llm_review が「今回 Claude Code Agent 経由だった」と毎回申告
- **per-section tier_used** (F6): capability_status 自身が「この section は core 操作、こっちは harness_assisted 操作」と自己申告

→ 「KairosChain 機能 vs Claude Code 機能」の境界が **静的構造 + 動的観測 + 配信経路** の 3 軸で articulate される。

## §8 既存機能の declared tier 分類 (v1.0 から拡張)

| Tool / Feature | Declared tier | 詳細 |
|---|---|---|
| `context_save` / `get_context` 等 (静的 L2 操作) | `:core` | MCP + fs |
| `chain_record` / `chain_verify` 等 | `:core` | blockchain は内部実装 |
| `knowledge_get` / `knowledge_list` 等 | `:core` | L1 操作 |
| `skills_*` / `skillset_*` | `:core` | layer 遷移、Meeting Place P2P |
| `dream_scan` (mode: scan / traverse) / `dream_propose` 等 | `:core` | filesystem walk + BFS |
| `capability_status` (新、Phase 1.5) | `:core` (但し `probe_externals: true` の時 external_availability section が `:harness_assisted` 操作で取得され self-acknowledge) | 自身が harness 依存では再帰的矛盾 |
| `agent_*` (OODA loop、現状の llm_client backend default) | `:harness_assisted` | LLM 呼出に llm_client SkillSet 経由、その backend が現状 subprocess CLI 依存。**Note**: tier 分類は現状 default backend 依存、planning-only mode 等の usage variation は `degrades_to:` で表現可 |
| `multi_llm_review` / `multi_llm_review_collect` | `:harness_assisted` (declared) + `requires_harness_features: [agent_tool@claude_code]` (実は default path は harness_specific) | **F9 完全宣言**: subprocess CLIs (graceful degrade 可) + Agent tool persona path (harness_specific だが fallback で direct API 可) + 最終的に manual_suggestion (`:core`) に縮退 |
| `plugin_project` 等 SkillSet `:harness_specific` 系 | `:harness_specific` | `target_harness: :claude_code` |

**Delivery channels** (F8 — tools と別カテゴリ):

| Channel | Content tier | Delivery tier | Note |
|---|---|---|---|
| Multi-LLM Review Philosophy Briefing | `:core` (philosophy doctrine) | `:harness_specific` (claude_code via CLAUDE.md auto-load) | content は L1 化可、delivery は harness 依存 |
| Active Resume Points UX | `:core` (L2 handoff content) | `:harness_specific` (claude_code via MEMORY.md auto-load) | 同上 |
| Skill auto-trigger | (skill content による) | `:harness_specific` (claude_code) | skill 起動 mechanism は Claude Code 専用 |

note: §8 表は initial assignment、各 tool maintainer が宣言を精査・修正する余地あり。

## §9 実装ステップ (v1.0 から修正)

1. **Capability module 新設** (`lib/kairos_mcp/capability.rb`): `Capability::TIERS` 定数、`Capability.detect_harness` (env + auto + cache)、`Capability.normalize_requirement` (Symbol/Hash → 正規 Hash + lazy validation)、`Capability.aggregate_manifest` (**ToolRegistry の `@tools` を walk**、`ObjectSpace` ではない)
2. **ToolRegistry 改修** (既存 `tool_registry.rb`): `register` 時に `@tool_sources[name] = source` を side table に記録 (`:core_tool` or `'skillset:<name>'`) — F3 取り込み
3. **BaseTool DSL** (既存 `base_tool.rb`): `harness_requirement` default 実装 (`:core`)、`with_acknowledgment` helper 追加
4. **capability_status tool 新設** (`lib/kairos_mcp/tools/capability_status.rb`): declared / observed / delivery_channels / tension の 4 層集約、per-section `tier_used:` annotation
5. **既存主要 tool への opt-in 宣言** (§8 の 10+ tool): `harness_requirement` method override 追加。multi_llm_review は `with_acknowledgment` で per-invocation acknowledgment を Phase 1.5 で実装 (canonical example)
6. **L1 knowledge 新設** (v1.1.1 path 明示): **canonical path は `KairosChain_mcp_server/knowledge/kairoschain_capability_boundary/kairoschain_capability_boundary.md`** (gem-bundled、read-only)、**かつ `KairosChain_mcp_server/templates/knowledge/kairoschain_capability_boundary/kairoschain_capability_boundary.md` に mirror** (memory `L1 Knowledge Distribution Policy` に従い、harness-aware doctrine は両 location 必要、`kairos init` 時に local copy + `system_upgrade` で 3-way merge 可能化)。**Content spec** (F10):
   - **8 invariants の解説** (LLM 向け、v1.1.1 wording 修正: 7+1 → 8)
   - 3 tier 判定基準と例
   - capability_status の使い方 (pre-flight check pattern)
   - Acknowledgment invariant の重要性 (masaomi reframe 引用)
   - delivery channels の認識 (CLAUDE.md/MEMORY.md auto-load が harness feature であること)
   - **Consumer**: KairosChain orchestrator LLM (どの harness で動くかに関わらず)
   - **Update cadence**: invariants 変更時 (= 設計 round 経由)、tier 分類変更時 (各 tool maintainer 改修時)
7. **Tests 新設** (`test_capability.rb`)
8. **Multi-LLM review** (round 2 が本 v1.1 review、その後実装)

## §10 テスト suite (v1.0 から拡張)

- env var 優先 / `KAIROS_HARNESS` malformed value で warn + `:unknown`
- auto-detect (CWD marker は hint から除外されていることの test)
- `:unknown` + `confidence: :unknown` 返却
- Process boot cache (Capability.reset! test helper で多 process simulation)
- DSL 宣言: Symbol / Hash 両形式の `normalize_requirement` 正規化
- Lazy validation: `:harness_specific` で `target_harness:` 不在時 `ArgumentError` (aggregate_manifest 呼び出し時に raise)
- 宣言無し tool は `declared: false, tier: :core` で manifest 集約される (F7)
- ToolRegistry `@tool_sources` が core_tool / skillset 由来を区別する (F3)
- Same-source exclusion: active_harness=:claude_code の時 used_externals に :claude_cli が含まれない (F4)
- `capability_status` 4 層構造 (declared / observed / delivery_channels / tension)
- per-section `tier_used:` annotation の存在検証
- `include_observed: false` で observed / tension / external_availability 全て omit (F1)
- `probe_externals: false` (default) で external_availability omit、subprocess 起動なし (F6)
- `probe_externals: true` で external_availability の `tier_used: :harness_assisted` annotation
- `delivery_channels` section に Multi-LLM briefing と Active Resume Points が含まれる (F8)
- multi_llm_review が `requires_harness_features:` + `fallback_chain:` で declared (F9)
- `with_acknowledgment` helper で multi_llm_review response に `harness_assistance_used:` field 追加される (F9 runtime)

## §11 Phase 1.5 で持ち越さない事項

- 中央集権 `capabilities.yml` (per-tool metadata に決定済)
- Runtime enforcement / refuse on mismatch (Declare-not-enforce)
- Harness adapter 層実装 (Phase 3+)
- 全 SkillSet 改修 (Composability invariant の構造提供のみ)
- multi_llm_review の persona Agent path harness 非依存化 (Phase 2+; Phase 1.5 では declaration で articulate のみ)
- `tension` 検出の fine-tuning (Phase 1.5 では `which`-style + declared external 一致確認のみ)
- 過去の実行履歴 tracking の永続化 (Phase 2+)
- `capability_status` の自動呼び出し / auto-pull mechanism (Phase 2+)
- raw API onboarding (no harness、no auto-load) UX (Phase 3+)
- 全 `:harness_assisted` / `:harness_specific` tool への `with_acknowledgment` 強制適用 (Phase 1.5 では multi_llm_review canonical example のみ、Forward-only adoption)
- network endpoint / API credential 等の non-CLI 依存表現 (Phase 2+ で `requires_externals:` を Hash 形式に拡張)

→ 設計行数: v1.0 約 250 → v1.1 約 360 行 (Acknowledgment invariant + delivery_channels + per-invocation acknowledgment + 各 fix で増)

## §12 Patch log (v1.0 → v1.1)

| Finding | 解決方法 | §影響 |
|---|---|---|
| F1 (`include_observed: false` と tension) | observed/tension/external_availability すべて omit を §5 に明記 | §5, §10 test |
| F2 (DSL validation point) | `normalize_requirement` で lazy validation、ArgumentError raise | §4, §10 test |
| F3 (Tool source attribution) | ToolRegistry に `@tool_sources` side table 追加 | §9 step 2 |
| F4 (Same-source exclusion rule) | §1 Active vs external invariant に明示 | §1, §5 example, §10 test |
| F5 (Auto-detect の CWD marker self-conflation) | hint から CWD marker 除外、§3 に理由併記 | §3 |
| F6 (capability_status tier 矛盾) | **masaomi reframe**: per-section `tier_used:` annotation で正直申告 (version probing 維持) | §1 acknowledgment, §5, §10 |
| F7 (opt-in default `:core` 曖昧) | manifest entry に `declared: true/false` boolean | §1 forward-only, §5, §10 |
| F8 (philosophy briefing 分離) | **delivery_channels** section 新設 | §5, §8 別 table |
| F9 (multi_llm_review 不正確) | `requires_harness_features:` + `fallback_chain:` + per-invocation `with_acknowledgment` | §4 DSL, §6 helper, §8 |
| F10 (L1 knowledge content spec) | §9 step 6 に schema/consumer/update cadence 明記 | §9 step 6 |
| F11 (`:harness_assisted` 射程) | §2 で network/API も同 tier、`requires_externals:` は Phase 2+ で Hash 形式拡張可と明記 | §2 |
| philosophy advisory: L0 closure 表現 | "L0 governance closure の運用層反映" に softening | §3 |
| philosophy advisory: tension guidance pressure | Declare-not-enforce 補強で「caller-side guidance pressure と enforcement は別」と明示 | §1 |

**新 invariant**: Acknowledgment invariant 追加 (8 invariants 化)。masaomi reframe の機械翻訳。

---

*End of v1.1 (integrated by claude-opus-4-7 with masaomi reframe).*
