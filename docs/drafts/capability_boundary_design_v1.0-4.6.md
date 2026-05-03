---
version: "1.0"
authored_by: claude-opus-4-6-directive-anti-enumeration
type: design_draft
phase: "1.5"
title: "Capability Boundary — Self-Articulation of Harness Dependence"
date: "2026-05-02"
---

# Phase 1.5: Capability Boundary Design

## §1 設計原則 / 不変条件

Phase 1.5 は KairosChain が自らの harness 依存構造を articulate する機構を導入する。以下の不変条件がこの設計全体を制約する。

**Invariant 1 — Self-Articulation (自己記述不変条件)**
KairosChain は、自身の各機能が外部 harness に対してどの依存関係にあるかを、自身の introspection 機構を通じて記述できなければならない。この記述は外部設定ファイルではなく、各 tool が自身について宣言する形式をとる。

根拠: 命題 7 (metacognitive self-referentiality) の具体化。System が自己について推論する能力は、まず自身の構成要件を articulate できることを前提とする。中央 manifest は "system について外部が記述する" 構造であり、self-referentiality を損なう。Per-tool 宣言は "各構成要素が自身について語る" 構造であり、self-referentiality を保存する。

**Invariant 2 — Honest Unknown (誠実不明不変条件)**
Harness 検出が不確定なとき、KairosChain は推測せず `:unknown` を返す。`:unknown` は正当な状態であり、エラーでも degradation でもない。

根拠: Partial autopoiesis の帰結。KairosChain は外部基盤 (Ruby VM, filesystem, harness) に依存する。依存先が不明であることを正直に表明することは、autopoietic boundary の誠実な articulation である。偽の確定は boundary の歪曲にあたる。

**Invariant 3 — Declare-Only (宣言専用不変条件)**
Tier 宣言は articulation のためにのみ存在し、実行時の拒否・制限に使用してはならない。Tool は harness mismatch があっても呼び出し可能であり、失敗は既存の error handling に委ねる。

根拠: Phase 1.5 の目的は "KairosChain が自身を知ること" であり "KairosChain が自身を制限すること" ではない。Enforcement は KairosChain の capability space を狭める操作であり、別の設計判断 (Phase 1.5 scope 外) を要する。

**Invariant 4 — Structural Congruence (構造一致不変条件)**
Harness 依存の宣言は、既存の BaseTool DSL パターン (category, usecase_tags 等) と同じ構造的手法で表現される。新しい宣言機構を導入しない。

根拠: Structural self-referentiality の要請。"Tool のメタデータを記述する方法" と "Tool の harness 依存を記述する方法" が異なる構造をとれば、meta-level と base-level の構造的対応が崩れる。既存の method override パターンに乗ることで、harness_requirement は category や usecase_tags と同格の self-description となる。

**Invariant 5 — Composability (合成不変条件)**
SkillSet の tool も core tool と同一の宣言機構を使う。SkillSet が KairosChain に統合されたとき、その tool の tier 宣言は core tool と区別なく introspection 可能でなければならない。

根拠: SkillSet は KairosChain の能力拡張の主要経路である。SkillSet tool が tier 宣言に参加できなければ、capability_status の view は常に不完全になり、Invariant 1 (Self-Articulation) が SkillSet 境界で破れる。

## §2 Tier Definition

Tool の harness 依存は以下の判定規則で 3 tier に分類される。

**判定規則**: Tool の実行に必要な外部リソースのうち、MCP プロトコルと filesystem 以外のものが存在するか、存在するなら代替動作が可能か、の 2 段階で tier が決まる。

- **`:core`** — MCP プロトコル + filesystem のみで完全に動作する。Harness が何であるか (あるいは不明であるか) に関わらず、機能の欠損がない。
- **`:harness_assisted`** — 外部プロセス起動、harness 固有 API、ネットワーク接続等の追加リソースを利用する。これらが不在でも部分的に動作するか、graceful に失敗する。`requires_externals` で依存先を列挙し、`degrades_to` で縮退時の動作を記述する。
- **`:harness_specific`** — 特定の harness なしでは原理的に動作しない。その harness の提供する機構 (Hooks, Subagent, etc.) が tool の動作の前提条件である。

**Default**: 宣言のない tool は `:core` とみなす。これは "宣言忘れ" を安全側に倒す設計判断であると同時に、既存の全 tool が暗黙に `:core` として扱われてきた歴史的事実の codification でもある。

## §3 Active Harness 検出

### 環境変数 (優先)

`ENV['KAIROS_HARNESS']` が設定されていれば、その値をシンボル化して返す。想定値: `claude_code`, `codex`, `cursor`, `raw_mcp`, 等。Enum 制約は設けない — 未知の harness 名もそのまま受容する (Invariant 2 の精神: 知っている情報を歪めない)。

### Auto-detect (fallback)

ENV 未設定時、以下の hint から推定を試みる。

- `CLAUDE.md` の存在 + `CLAUDE_CODE_*` 系 ENV → `:claude_code` 候補
- 親プロセス名の検査 → harness 固有のプロセスシグネチャ
- MCP transport 特性 (stdio vs HTTP) → harness の傾向

Auto-detect は best-effort であり、hint が矛盾するか不十分であれば `:unknown` を返す。実装は `Capability.detect_harness` に集約し、検出ロジックの詳細は実装フェーズで確定する。

### 返却構造

```ruby
{
  active_harness: :claude_code,        # or :unknown
  detection_method: :env_var,          # :env_var | :auto_detect | :none
  confidence: :explicit,               # :explicit | :inferred | :unknown
  used_externals: [:codex_cli, :cursor_cli]
}
```

`used_externals` は active harness とは概念的に独立。"KairosChain プロセスを駆動するもの" (active) と "KairosChain プロセス内から起動されるもの" (externals) の区別を構造に反映する。

## §4 BaseTool DSL

既存の BaseTool metadata パターン (`category`, `usecase_tags`) と構造一致する形で `harness_requirement` を追加する。

```ruby
module KairosMcp
  module Tools
    class ContextSave < BaseTool
      def name; 'context_save'; end
      def category; :context; end
      def harness_requirement; :core; end   # default と同値だが明示
      # ...
    end
  end
end
```

```ruby
module KairosMcp
  module Tools
    class MultiLLMReview < BaseTool
      def name; 'multi_llm_review'; end
      def category; :skills; end

      def harness_requirement
        {
          tier: :harness_assisted,
          requires_externals: [:claude_cli, :codex_cli, :cursor_cli],
          degrades_to: 'persona-only review (Agent tool personas within active harness)'
        }
      end
      # ...
    end
  end
end
```

```ruby
# SkillSet tool (同一パターン)
module KairosMcp
  module SkillSets
    module PluginProjector
      module Tools
        class PluginProject < BaseTool
          def harness_requirement
            {
              tier: :harness_specific,
              target_harness: :claude_code,
              reason: 'Generates Claude Code plugin artifacts (SKILL.md, agents/)'
            }
          end
        end
      end
    end
  end
end
```

**BaseTool default 実装**:

```ruby
class BaseTool
  def harness_requirement
    :core
  end
end
```

返却値は Symbol (`:core`) または Hash (`{ tier:, requires_externals:, ... }`) のどちらか。Introspection tool は両形式を正規化して集約する。

## §5 capability_status Tool 仕様

### 入力 schema

```json
{
  "type": "object",
  "properties": {
    "filter_tier": {
      "type": "string",
      "enum": ["core", "harness_assisted", "harness_specific"],
      "description": "指定 tier の tool のみ表示"
    },
    "include_observed": {
      "type": "boolean",
      "description": "動的検出結果 (observed) を含めるか (default: true)"
    }
  }
}
```

### 出力構造

```ruby
{
  # Observed (動的 — 現在の実行環境)
  observed: {
    active_harness: :claude_code,
    detection_method: :env_var,
    confidence: :explicit,
    used_externals: [:codex_cli, :cursor_cli],
    external_availability: {
      codex_cli: { available: true, version: '0.1.2025060601' },
      cursor_cli: { available: false, reason: 'not found in PATH' }
    }
  },

  # Declared (静的 — tool の自己宣言)
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

  # Tension (declared と observed の交差)
  tension: [
    { tool: 'multi_llm_review', issue: 'requires cursor_cli but not found in PATH',
      severity: :degraded }
  ]
}
```

**declared と observed の区別**: declared は tool の自己宣言 (build 時に確定)、observed は実行環境の検出結果 (起動時に変動)。`tension` セクションは両者を交差させ、宣言された依存が実際に利用可能かを報告する。Tension の報告は informational であり enforcement ではない (Invariant 3)。

## §6 哲学的位置づけ

### masaomi 指摘の conflation 問題への構造的回答

「KairosChain の機能なのか Claude Code の機能なのか区別がつかない」という問題は、命題 2 (partial autopoiesis) の実践的帰結として構造的に必然である。KairosChain は定義レベルでは自己閉鎖的だが、実行レベルでは外部基盤に依存する。この依存が不透明であるとき、system は自身の autopoietic boundary を正確に認識できない。

Phase 1.5 は、この boundary を system 自身が articulate する機構を導入することで、命題 2 の "at which abstraction level does the loop close?" という問いに実装レベルで答える。Answer: 定義・宣言レベルでは close する (tool は自身の tier を宣言できる)。実行レベルでは open のまま (harness が何であれ tool は呼べる)。

### 命題 7 (Metacognitive self-referentiality) との対応

capability_status は system が自身の構成と環境について推論する具体的 interface である。"どの機能が harness に依存し、その harness は今利用可能か" という問いに答えられることは、metacognitive self-referentiality の最小要件の一つ。

### 命題 9 (Human-system composite) との対応

Harness (Claude Code, Codex, Cursor) は human-system composite の interface 層である。Human は harness を通じて KairosChain と対話する。Phase 1.5 が harness 依存を articulate することは、composite のどの層がどの能力を提供しているかを明示化する行為であり、命題 9 の "human is on the boundary" を構造に反映する。

## §7 Phase 2 への含意

Phase 1.5 の capability boundary manifest は、Phase 2 の設計判断空間を以下のように構造化する。

Phase 2 が「利用面整備」であるなら、その整備対象は tier によって異なる戦略を要する。`:core` tool の UX 改善は harness 非依存に設計できる。`:harness_assisted` tool の UX 改善は degradation path の品質向上を含む。`:harness_specific` tool は、その harness のユーザにのみ relevance がある。

Phase 1.5 の tier 宣言が存在することで、Phase 2 は "全機能を一律に整備する" のではなく "tier ごとに適切な整備戦略を選択する" ことが可能になる。これは Phase 2 の scope 判断を inform するが、特定の案 (A〜D) を強制しない。

## §8 既存機能の tier 分類

| Tool | Declared Tier | Rationale |
|------|--------------|-----------|
| `context_save` | `:core` | MCP + filesystem のみ |
| `context_create_subdir` | `:core` | MCP + filesystem のみ |
| `chain_record` / `chain_verify` | `:core` | Blockchain 操作、filesystem 完結 |
| `knowledge_get` / `knowledge_list` | `:core` | L1 knowledge 読み出し |
| `skills_promote` | `:core` | Layer 遷移、persona assembly は内部 LLM 呼出 |
| `capability_status` (新規) | `:core` | 自身が harness 依存では self-articulation が再帰的矛盾 |
| `multi_llm_review` | `:harness_assisted` | subprocess CLI (claude, codex, cursor) を利用。不在時は persona-only mode に縮退 |
| `agent_start` / `agent_step` | `:harness_assisted` | LLM 呼出に llm_client SkillSet 使用。llm_client の backend 設定に依存 |
| `dream_scan` / `dream_propose` | `:core` | Filesystem scan + 内部推論 |
| `plugin_project` | `:harness_specific` | Claude Code plugin artifact 生成が存在理由 |

Note: この表は initial assignment であり、各 tool maintainer (≒実装時の author) が宣言を精査・修正する。

## §9 実装ステップ

1. **Capability module 新設** — `lib/kairos_mcp/capability.rb` に `Capability::Tier` 定数 (`:core`, `:harness_assisted`, `:harness_specific`) と `Capability.detect_harness` メソッドを定義。
2. **BaseTool DSL 拡張** — `base_tool.rb` に `harness_requirement` default 実装 (`:core`) を追加。返却値の正規化 helper (`normalize_tier`) を Capability module に配置。
3. **capability_status tool 実装** — ToolRegistry から全 tool を走査し、declared tier を集約。Capability.detect_harness の結果と交差して tension を報告。
4. **主要 tool への tier 宣言付与** — §8 の 10 tool に `harness_requirement` を追加。
5. **L1 knowledge 作成** — `knowledge/kairoschain_capability_boundary/` に doctrine document を配置。LLM が capability_status を pre-flight check として使う指針を含む。
6. **テスト実装** — §10 の test suite。
7. **Context Graph (Phase 1) との接続確認** — informed_by edge mapping が capability_status を参照できることを verify。

## §10 テスト suite

- **Tier 定数**: 3 tier が定義されていること。未知の tier symbol に対する正規化の挙動。
- **BaseTool default**: `harness_requirement` 未 override の tool が `:core` を返すこと。
- **Hash 形式**: `{ tier:, requires_externals:, degrades_to: }` 形式が正規化可能なこと。
- **detect_harness (env var)**: `ENV['KAIROS_HARNESS']` 設定時に対応 symbol を返すこと。
- **detect_harness (unknown)**: ENV 未設定かつ auto-detect 不能時に `{ active_harness: :unknown, confidence: :unknown }` を返すこと。
- **capability_status declared**: 全登録 tool の tier 集約が summary count と一致すること。
- **capability_status observed**: detect_harness 結果が observed セクションに反映されること。
- **capability_status tension**: `:harness_assisted` tool の requires_externals が PATH に不在のとき tension に報告されること。
- **SkillSet tool 参加**: SkillSet 由来 tool の tier 宣言が core tool と同等に集約されること (Invariant 5)。
- **Declare-only**: tier mismatch 状態で tool 呼び出しが refuse されないこと (Invariant 3)。
