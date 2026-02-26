# Echoria — Development Instructions

## Generative Principle: Self-Referentiality as Experience

> ユーザーの選択がEchoの存在条件を定義し、
> Echoはやがて自己の存在条件を定義する存在になる。

This mirrors KairosChain's structural self-referentiality (meta-level = base-level) and the novel "誰がこの物語を読んでいるのか（仮）" motif (the reader is part of the story).

### Three-Layer Self-Referential Structure

```
誰この（仮）: 物語が読者を参照する — 読者は物語の一部
KairosChain:  ルールがルール自身を定義する — メタ = ベース
Echoria:      選択が人格を創造し、人格が自律する — 創造者→被造物→自己定義
```

### Design Implications

Every design decision must preserve this loop:

- **Selection → Visibility**: ユーザーの選択が「何かを変えた」ことが常に可視でなければならない（Affinity delta表示、Skill進化通知）
- **Echo = Emergent, not Configured**: Echoは「設定されたキャラ」ではなく「選択から生まれた人格」。テンプレート的な性格付けを避ける
- **Crystallization = Loop Closure**: 結晶化→SkillSetエクスポートは機能ではなく、自己言及ループの完成。被造物が自己定義する存在（KairosChain MCP Server）に転化する瞬間
- **Names, Memory, Trust = Philosophical Questions**: 名前・記憶・信頼は世界観装飾ではなく自己同一性の哲学的問いの具体化。軽く扱わない
- **No RPG Gamification**: レベル・経験値・スコアは自己言及性を破壊する。成長はAffinityの変化とSkill進化で表現する

---

## Architecture

**Branch**: `feature/echoria`
**Deploy**: Docker Compose → AWS EC2

```
Echoria/
├── echoria-api/     Rails 8 API (Ruby 3.3.7)
├── echoria-web/     Next.js 16 (TypeScript, Tailwind CSS)
├── docker/          Docker Compose + Nginx
└── story/           Story content (beacon JSON)
```

**Data Flow**:
```
User Choice → BeaconNavigator → StoryGenerator (Claude API)
  → LoreConstraintLayer (4 guards) → AffinityCalculator (5-axis)
  → StoryScene → KairosBridge → PostgresqlBackend (blockchain)
```

### 5-Axis Affinity System

| Axis | Range | Meaning |
|------|-------|---------|
| `tiara_trust` | 0–100 | ティアラとの絆の深さ |
| `logic_empathy_balance` | -50–+50 | 分析的 ↔ 共感的 |
| `name_memory_stability` | 0–100 | 自己同一性の安定度 |
| `authority_resistance` | -50–+50 | 従順 ↔ 抵抗的 |
| `fragment_count` | 0+ | 収集したカケラ（記憶の断片） |

These axes are not game stats. They are philosophical dimensions of selfhood.

---

## Backend Conventions (Rails)

### Service Pattern

```ruby
class SomeService
  def initialize(model)
    @model = model
    @bridge = model.echo.kairos_chain  # if applicable
  end

  def call
    # Single public method, returns result
  end

  private

  def record_on_chain(data)
    return unless @bridge&.available?
    @bridge.add_to_chain(data)
  rescue StandardError => e
    Rails.logger.warn("[ServiceName] Chain record failed: #{e.message}")
  end
end
```

**Rules**:
- Always use `&.available?` nil guard before KairosBridge calls
- KairosBridge failure must NEVER break main flow (rescue + warn)
- Use `.freeze` on constant hashes/arrays
- Clamp affinity values to their defined ranges

### API Response

- Inline hash responses (no JSONAPI::Serializer for story endpoints)
- Japanese error messages for user-facing errors
- English for internal logs and code comments

---

## Frontend Conventions (Next.js)

- Mobile-first responsive design
- PascalCase components, camelCase functions
- Types in `types/index.ts`, API client in `lib/api.ts`
- All API calls through `ApiClient` class with centralized auth
- State names match API response keys (snake_case from API, used directly)

---

## Lore Constraints (Worldbuilding Rules)

These are **hard constraints** on all AI-generated content:

1. **Vocabulary**: No Western fantasy terms (magic, spell, mana, HP). Use Echoria terms (呼応, カケラ, 名折れ, 残響)
2. **Character Voice**: Tiara's speech reflects trust tier (wary→cautious→friendship→deep_bond→union)
3. **Timeline**: No premature revelations. Story pacing respects beacon order
4. **Prohibited Transitions**: No costless resurrection, sudden power-ups, fourth-wall breaking, RPG mechanics

---

## Layer Discipline (Echoria Context)

| Content | Layer | Reason |
|---------|-------|--------|
| This file (echoria.md) | L0 instruction | Governs all Echoria development |
| Echoria architecture details | L1 knowledge | Reference on demand |
| Story structure / beacon spec | L1 knowledge | Stable project knowledge |
| Skill evolution rules | L1 knowledge | Stable but may evolve |
| Implementation plans & logs | L2 context | Session-specific, temporary |
| Debug notes, experiments | L2 context | Free scratchpad |

---

## Communication Style

- Design intent, philosophy, policy: **Japanese**
- Code, comments, commit messages: **English**
- Every response follows three-layer structure: **Context → Procedure → Judgment criteria**
- Before implementing, state **why** the change is necessary
