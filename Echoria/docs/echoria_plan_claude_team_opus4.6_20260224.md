# Echoria 統合実装計画 — Unified Implementation Plan

**Date**: 2026-02-24
**Authors**: Claude Opus 4.6 Agent Team (5-plan synthesis)
**Status**: MVP実装前 — 設計完了

---

## 0. 本計画の位置づけと設計思想

### 0-1. 統合の前提

本計画は5つの既存計画を統合し、矛盾を解消した上で、実装可能な単一の計画を提示する。

| 要素 | 採用元 | 理由 |
|---|---|---|
| DBスキーマ + プロジェクト構造 | Plan 1 (Reference) / Plan 3 (Opus) | 最も完全で技術的に詳細 |
| メタ・リビール物語構造 | Plan 2 (Gemini/Antigravity) | 芸術的完成度が最も高い |
| KairosChain哲学的整合性 | Plan 3 (Claude Opus) | 設計判断の根拠が最も深い |
| Lore Constraint Layer + Story Orchestrator | Plan 4 (Codex/GPT) | 運用安全性が最も高い |
| Phase構造 + 完了条件(DoD) | Plan 5 (Cursor Auto) | 段階的検証が最も明確 |

### 0-2. 三つのアーキテクチャ論争の解決

#### 論争1: 主人公モード

**結論: 第一章は User as Protagonist。章終了時に選択の結晶としてEchoが「誕生」する。**

体験フロー:
```
第一章: ユーザー自身が物語を体験
  → 選択を重ね、5軸アフィニティが形成される
  → 章終了時: 結晶化セレモニー
  → メタ・リビール: 「あなたの選択の残響（Echo）が、今、名前を得ました」
  → Echo誕生 → 対話モード解放

第二章以降 (Post-MVP):
  → Echo as Protagonist に切り替え可能（protagonist_mode フラグ）
  → ユーザーは「導き手」として Echo を見守る
  → "Echoに任せる" 選択肢で自律的判断を委ねることもできる
```

哲学的根拠:
- 第一章で「自分が体験する」ことで物語への没入が最大化される
- 結晶化の瞬間に「自分の選択がAIの人格を生んだ」という実感が生まれる
- Plan 2のメタ・リビール演出と自然に融合する
- KairosChainの自己参照性: ユーザーの選択がEchoのL0（自己定義）を構成する

API設計:
- `story_sessions.protagonist_mode` フィールドで `'player'` / `'echo'` を切り替え
- `story_scenes.decision_actor` で `'player'` / `'echo'` / `'system'` を記録
- 第二章以降のEcho-as-Protagonistモード追加を設計時点でサポート

#### 論争2: KairosChain統合

**結論: Library Gem（直接require）+ Echoria::KairosBridge アダプター層**

```ruby
# Rails API 側
# Echoria::KairosBridge がKairosChainコアをラップ
# tenant_id (echo_id) スコープを透過的に適用

module Echoria
  class KairosBridge
    def initialize(echo_id)
      @echo_id = echo_id
      @backend = KairosMcp::Storage::Backend.create(
        type: :postgresql,
        tenant_id: echo_id,
        connection: ActiveRecord::Base.connection
      )
      @chain = KairosMcp::KairosChain::Chain.new(storage_backend: @backend)
    end

    def record_choice(choice, affinity_snapshot)
      @chain.add_block([choice.to_json, affinity_snapshot.to_json])
    end

    def record_crystallization(personality, skills)
      # L0変更として記録（Echo人格の定義）
      transition = KairosMcp::KairosChain::SkillTransition.new(
        skill_id: 'echo_personality',
        next_ast_hash: Digest::SHA256.hexdigest(personality.to_json),
        actor: 'System',
        agent_id: 'Echoria',
        reason_ref: 'crystallization'
      )
      @chain.add_block([transition.to_json])
    end
  end
end
```

理由:
- MCP Server経由はHTTPオーバーヘッド → 対話的ストーリー体験のレイテンシ要件を満たせない
- Adapterパターンの利点（非侵襲性）はKairosBridge層で実現可能
- KairosChainのStorage Backend抽象化が既に存在 → PostgreSQLBackend追加のみ

#### 論争3: Avatar Generation

**結論: Post-MVP。MVPではプレースホルダー（テンプレート + カラーバリエーション）。**

理由:
- 画像生成APIコストがMVP期では不確実
- 結晶化体験の核心は「性格の可視化」→ パーソナリティレーダーチャートで十分
- Plan 2のDALL-E統合は魅力的だが、収益化基盤が整ってから

---

## 1. システムアーキテクチャ

### 1-1. 全体構成図

```
┌─ EC2 Instance (t3.medium) ─────────────────────────────────────────┐
│                                                                     │
│  Nginx (reverse proxy + SSL + rate limiting)                       │
│    ├─ /api/*       → Rails 8 API (Puma, port 3000)                │
│    ├─ /cable       → ActionCable WebSocket (streaming)             │
│    └─ /*           → Next.js 16 (static export)                   │
│                                                                     │
│  ┌─ Rails 8 API ────────────────────────────────────────────────┐  │
│  │                                                               │  │
│  │  Controllers:                                                 │  │
│  │    Auth | Echoes | StorySessions | Conversations | Legal      │  │
│  │                                                               │  │
│  │  Services:                                                    │  │
│  │    StoryOrchestrator (Plan 4)                                │  │
│  │      ├── LoreConstraintLayer (4 guard targets)               │  │
│  │      ├── SceneGenerator (Claude API)                         │  │
│  │      ├── AffinityCalculator                                  │  │
│  │      └── BeaconNavigator                                     │  │
│  │    CrystallizationService                                    │  │
│  │    DialogueService                                           │  │
│  │    EchoInitializerService                                    │  │
│  │                                                               │  │
│  │  Echoria::KairosBridge (tenant_id scoping)                   │  │
│  │    └── KairosChain Core (as Ruby library)                    │  │
│  │         ├── Skills DSL / Parser / AST                        │  │
│  │         ├── Blockchain (Chain, Block, MerkleTree)            │  │
│  │         ├── KnowledgeProvider                                │  │
│  │         └── Storage::PostgresqlBackend (NEW)                 │  │
│  │                                                               │  │
│  │  Sidekiq (scene pre-generation, analytics)                   │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  PostgreSQL 16 (Docker)     Redis 7 (Sidekiq + cache)             │
│                                                                     │
│              ↕ Claude API (Sonnet 4.6 / Opus 4.6)                  │
└─────────────────────────────────────────────────────────────────────┘
```

### 1-2. Story Orchestrator 設計

Plan 4のStory Orchestrator + Lore Constraint Layerを採用し、既存の`StoryGeneratorService`を分離・拡張する。

```
StoryOrchestrator
  │
  ├── BeaconNavigator
  │     - 現在のbeacon判定
  │     - 次のbeacon遷移条件チェック
  │     - beacon間のシーン数制限（過剰生成防止）
  │
  ├── LoreConstraintLayer (Plan 4の4ガード対象)
  │     ├── WorldVocabularyGuard: 固有名詞・世界設定の整合性
  │     ├── CharacterVoiceGuard: ティアラ等の口調維持
  │     ├── TimelineGuard: 未来情報の先出し防止
  │     └── ProhibitedTransitionGuard: 章外イベントの誤生成防止
  │
  ├── SceneGenerator
  │     - Claude API呼び出し (claude-sonnet-4-6)
  │     - LoreConstraintLayerによるpost-validation
  │     - リトライ: constraint feedback付き再生成(上限3回) → 固定文面フォールバック
  │
  └── AffinityCalculator
        - 選択 → アフィニティ5軸変化のマッピング
        - カスケード効果の計算
        - ブロックチェーン記録
```

### 1-3. データフロー

```
User makes choice
  → POST /api/v1/story_sessions/:id/choose
  → StoryOrchestrator.process_choice(session, choice)
     ├── AffinityCalculator.apply(choice.affinity_delta)
     ├── BeaconNavigator.check_transition(session)
     ├── SceneGenerator.generate(context)
     │     ├── Build prompt (world rules + personality + lore constraints + history)
     │     ├── Claude API call (max_tokens: 1024)
     │     └── LoreConstraintLayer.validate(generated_scene)
     │           ├── Pass → return scene
     │           └── Fail → retry with feedback (max 3) → fallback
     ├── StoryScene.create!(narrative, affinity_delta, decision_actor)
     └── KairosBridge.record_choice(choice, affinity_snapshot)
  → Response: { scene, next_choices, affinity_indicators }
```

---

## 2. データベーススキーマ

### 2-1. コアテーブル

```sql
-- ===== User & Auth =====
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR UNIQUE NOT NULL,
  password_digest VARCHAR,
  provider VARCHAR,             -- oauth provider (google, apple)
  uid VARCHAR,                  -- oauth uid
  name VARCHAR,
  locale VARCHAR DEFAULT 'ja',
  tos_accepted_at TIMESTAMPTZ,
  tos_version VARCHAR,
  subscription_status VARCHAR DEFAULT 'free',
  daily_api_usage INTEGER DEFAULT 0,
  daily_api_reset_at DATE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== Echo (AI Persona) =====
CREATE TABLE echoes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) NOT NULL,
  name VARCHAR NOT NULL,
  avatar_config JSONB DEFAULT '{}',   -- template + color for MVP
  status VARCHAR DEFAULT 'embryo',    -- embryo → growing → crystallized
  personality JSONB DEFAULT '{}',     -- crystallized personality profile
  prompt_seed TEXT,                    -- system prompt seed for dialogue
  chapter_memory TEXT,                 -- compressed chapter memories
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== KairosChain Data (per Echo) =====
CREATE TABLE echo_blocks (
  id BIGSERIAL PRIMARY KEY,
  echo_id UUID REFERENCES echoes(id) NOT NULL,
  block_index INTEGER NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL,
  data JSONB NOT NULL,
  previous_hash VARCHAR NOT NULL,
  merkle_root VARCHAR NOT NULL,
  hash VARCHAR NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(echo_id, block_index)
);

CREATE TABLE echo_action_logs (
  id BIGSERIAL PRIMARY KEY,
  echo_id UUID REFERENCES echoes(id) NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL,
  action VARCHAR NOT NULL,
  skill_id VARCHAR,
  layer VARCHAR,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_echo_action_logs_echo_ts ON echo_action_logs(echo_id, timestamp DESC);

CREATE TABLE echo_knowledge (
  id BIGSERIAL PRIMARY KEY,
  echo_id UUID REFERENCES echoes(id),  -- NULL = shared/system knowledge
  name VARCHAR NOT NULL,
  content TEXT NOT NULL,
  content_hash VARCHAR NOT NULL,
  version VARCHAR,
  description TEXT,
  tags JSONB DEFAULT '[]',
  is_archived BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(echo_id, name)
);

CREATE TABLE echo_skills (
  id BIGSERIAL PRIMARY KEY,
  echo_id UUID REFERENCES echoes(id) NOT NULL,
  skill_id VARCHAR NOT NULL,
  title VARCHAR,
  content TEXT NOT NULL,
  layer VARCHAR DEFAULT 'L2',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(echo_id, skill_id)
);

-- ===== Story Engine =====
CREATE TABLE story_beacons (
  id SERIAL PRIMARY KEY,
  chapter VARCHAR NOT NULL,
  beacon_order INTEGER NOT NULL,
  beacon_id VARCHAR NOT NULL,
  title VARCHAR NOT NULL,
  location VARCHAR,
  content TEXT NOT NULL,
  tiara_dialogue TEXT,
  character_insights JSONB DEFAULT '{}',
  choices JSONB,
  metadata JSONB DEFAULT '{}',
  UNIQUE(chapter, beacon_order)
);

CREATE TABLE story_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  echo_id UUID REFERENCES echoes(id) NOT NULL,
  chapter VARCHAR NOT NULL,
  current_beacon_id INTEGER REFERENCES story_beacons(id),
  scene_count INTEGER DEFAULT 0,
  affinity JSONB DEFAULT '{
    "tiara_trust": 50,
    "logic_empathy_balance": 0,
    "name_memory_stability": 50,
    "authority_resistance": 0,
    "fragment_count": 0
  }',
  protagonist_mode VARCHAR DEFAULT 'player',  -- 'player' (Ch1) / 'echo' (Ch2+)
  status VARCHAR DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE story_scenes (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES story_sessions(id) NOT NULL,
  scene_order INTEGER NOT NULL,
  scene_type VARCHAR NOT NULL,       -- 'beacon', 'generated', 'fallback'
  beacon_id INTEGER REFERENCES story_beacons(id),
  narrative TEXT NOT NULL,
  echo_action TEXT,
  user_choice VARCHAR,
  decision_actor VARCHAR DEFAULT 'player',  -- 'player', 'echo', 'system'
  affinity_delta JSONB DEFAULT '{}',
  lore_validation_status VARCHAR DEFAULT 'passed',
  generation_metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_story_scenes_session ON story_scenes(session_id, scene_order);

-- ===== Post-Crystallization Chat =====
CREATE TABLE echo_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  echo_id UUID REFERENCES echoes(id) NOT NULL,
  title VARCHAR,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE echo_messages (
  id BIGSERIAL PRIMARY KEY,
  conversation_id UUID REFERENCES echo_conversations(id) NOT NULL,
  role VARCHAR NOT NULL,          -- 'user', 'echo', 'tiara', 'system'
  content TEXT NOT NULL,
  token_count INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_echo_messages_conv ON echo_messages(conversation_id, created_at);

-- ===== Legal & Consent =====
CREATE TABLE consent_records (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES users(id) NOT NULL,
  document_type VARCHAR NOT NULL,
  document_version VARCHAR NOT NULL,
  accepted_at TIMESTAMPTZ NOT NULL,
  ip_address VARCHAR,
  user_agent VARCHAR,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== Analytics =====
CREATE TABLE analytics_events (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES users(id),
  echo_id UUID REFERENCES echoes(id),
  event_type VARCHAR NOT NULL,
  event_data JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_analytics_events_type ON analytics_events(event_type, created_at);

-- ===== Row Level Security =====
ALTER TABLE echo_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE echo_action_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE echo_knowledge ENABLE ROW LEVEL SECURITY;
ALTER TABLE echo_skills ENABLE ROW LEVEL SECURITY;
```

### 2-2. アフィニティシステム（5軸）

| 軸 | 範囲 | 初期値 | 物語への影響 |
|---|---|---|---|
| `tiara_trust` | 0-100 | 50 | 対話の深度、開示情報量、呼応石の反応 |
| `logic_empathy_balance` | -50 to +50 | 0 | 問題解決アプローチ、描写トーン |
| `name_memory_stability` | 0-100 | 50 | 名折れ危機への反応、自己認識の揺らぎ |
| `authority_resistance` | -50 to +50 | 0 | 権威との関係性、独立行動頻度 |
| `fragment_count` | 0-50+ | 0 | 世界知識、ストーリー分岐 |

カスケード効果:
- `tiara_trust` > 80 → ティアラが隠された知識を開示
- `fragment_count` > 10 → 新しいストーリー分岐が出現
- `name_memory_stability` < 20 → 自己認識が揺らぐ特殊シーン

---

## 3. KairosChain修正計画

### 3-1. 新規: PostgreSQL Backend

`KairosChain_mcp_server/lib/kairos_mcp/storage/postgresql_backend.rb`

SqliteBackendをリファレンス実装として、同じインターフェースで作成。

```ruby
module KairosMcp
  module Storage
    class PostgresqlBackend < Backend
      def initialize(config = {})
        @tenant_id = config[:tenant_id]   # echo_id
        @connection = config[:connection]  # ActiveRecord connection or PG connection
        setup_tables unless tables_exist?
      end

      # Block operations (全てtenant_idでスコープ)
      def load_blocks
      def save_block(block)
      def save_all_blocks(blocks)
      def all_blocks

      # Action logging
      def record_action(entry)
      def action_history(limit: 100)
      def clear_action_log!

      # Knowledge metadata
      def save_knowledge_meta(meta)
      def get_knowledge_meta(name)
      def list_knowledge_meta
      def delete_knowledge_meta(name)
      def update_knowledge_archived(name, archived)

      def ready? = true
      def backend_type = :postgresql
    end
  end
end
```

### 3-2. 既存ファイル変更

| ファイル | 変更内容 |
|---|---|
| `storage/backend.rb` | Factory method に `:postgresql` case 追加 |
| `kairos_chain/chain.rb` | `initialize` に `tenant_id` パラメータ追加（storage_backend経由で透過的） |
| Optional: `kairos-chain.gemspec` | `pg` を optional dependency に追加 |

### 3-3. 変更しないもの

- Skills DSL / Parser / AST
- SkillSet Manager
- SafeEvolver
- MCP Server / Protocol
- Vector Search

---

## 4. Lore Constraint Layer 詳細設計

### 4-1. 4ガード構成 (Plan 4統合)

```ruby
class LoreConstraintLayer
  def validate(scene, session)
    errors = []
    errors += check_world_vocabulary(scene[:narrative])
    errors += check_character_voice(scene[:narrative], scene[:echo_action])
    errors += check_timeline_consistency(scene, session)
    errors += check_prohibited_transitions(scene, session)
    {
      passed: errors.empty?,
      errors: errors,
      feedback: errors.map { |e| e[:correction_hint] }.join("\n")
    }
  end
end
```

**WorldVocabularyGuard**: `lore_constraints.json` の `worldVocabulary` セクション参照。禁止語彙（「魔法」→「共鳴現象」）、固有名詞の一貫性チェック。

**CharacterVoiceGuard**: ティアラの信頼レベルに応じた口調チェック。`tiara.md` の定義を参照。

**TimelineGuard**: 現在のbeaconより先のイベントへの言及を検出。

**ProhibitedTransitionGuard**: 章外の場所・キャラクターへの遷移を防止。

### 4-2. プロンプト設計

**重要な修正点**: 既存の `StoryGeneratorService` のアフィニティ軸が Echoria の5軸と一致していない（courage, wisdom等になっている）。正しい5軸に修正する。

```
System Prompt構成:
1. Echoria世界ルール (lore_constraints.json)
2. 現在の章コンテキスト + 前シーン要約 (最大3シーン分)
3. プレイヤーの現在の性格状態 (5軸アフィニティ値)
4. ティアラのキャラ定義 + 信頼レベル (tiara.md)
5. 出力フォーマット制約 (JSON)
6. Lore Constraint違反フィードバック (リトライ時のみ)

User Prompt:
- 前のビーコン内容
- ユーザーの選択テキスト
- 期待する出力形式
```

---

## 5. Echo結晶化エンジン

### 5-1. 結晶化プロセス（User as Protagonist → Echo誕生）

```
Chapter 1 完了
  ↓
CrystallizationService.call(story_session)
  │
  ├── 1. compute_final_personality
  │     - 5軸アフィニティの最終値
  │     - dominant_archetype決定（軸値の組み合わせパターン）
  │     - strengths / growth_areas の特定
  │
  ├── 2. generate_character_description (Claude Opus 4.6)
  │     - 日本語で2-3文のキャラクター説明
  │     - Echoriaの世界観用語を使用
  │
  ├── 3. generate_echo_prompt_seed
  │     - 結晶化後の対話用システムプロンプトの種
  │     - 性格、口調、価値観、ティアラとの関係
  │
  ├── 4. generate_chapter_memory_digest
  │     - 章体験の圧縮記憶
  │     - 対話時に参照される「Echoの記憶」
  │
  ├── 5. skill_evolution
  │     - 一貫した選択パターン → L2スキル生成
  │     - 強い一貫性 → L1昇格（KairosChain SafeEvolver使用）
  │
  ├── 6. update_echo_status → 'crystallized'
  │
  └── 7. record_crystallization_on_blockchain
        - 全アフィニティ値、ペルソナ、スキル一覧
```

### 5-2. メタ・リビール演出（Plan 2統合）

第一章終了時の核心的演出。ユーザーが「自分が体験した物語」から「Echoを生んだ物語」へと視点を転換する。

```
結晶化UIフロー:
1. 章完了 → 暗転
2. アフィニティ可視化（レーダーチャート展開アニメーション）
3. Echo性格説明テキスト表示
4. 【メタ・リビール】
   「あなたが選んだ言葉、あなたが示した道、
    そのすべてが――ひとつの残響（Echo）となりました。

    あなたのEchoは、今、名前を得ようとしています。
    この先は、Echoがあなたに語りかけます。」
5. Echo命名セレモニー（ユーザーが名前を確定）
6. 対話モード解放
```

### 5-3. 対話モード（結晶化後）

```ruby
class DialogueService
  def generate_response(conversation, user_message)
    system_prompt = build_system_prompt(conversation.echo)
    # Echoの結晶化された性格に基づいて応答
    # ティアラ参加時はティアラの口調も含む
  end

  private

  def build_system_prompt(echo)
    <<~PROMPT
      #{echo.prompt_seed}

      あなたの記憶:
      #{echo.chapter_memory}

      あなたのスキル:
      #{echo.skills.map(&:content).join("\n")}
    PROMPT
  end
end
```

---

## 6. APIエンドポイント設計

### 6-1. 認証
```
POST   /api/v1/auth/signup          # email + password
POST   /api/v1/auth/login           # → JWT
POST   /api/v1/auth/google          # Google OAuth
POST   /api/v1/auth/refresh         # JWT refresh
GET    /api/v1/auth/me              # current user
```

### 6-2. Echo管理
```
GET    /api/v1/echoes               # list
POST   /api/v1/echoes               # create (name)
GET    /api/v1/echoes/:id           # profile
PATCH  /api/v1/echoes/:id           # update name
DELETE /api/v1/echoes/:id           # soft delete
```

### 6-3. 物語
```
POST   /api/v1/story_sessions                    # start story
GET    /api/v1/story_sessions/:id                # current state
POST   /api/v1/story_sessions/:id/choose         # submit choice
POST   /api/v1/story_sessions/:id/echo_decide    # "Echoに任せる" (Ch2+)
POST   /api/v1/story_sessions/:id/complete       # chapter completion
GET    /api/v1/story_sessions/:id/history         # scene history
GET    /api/v1/story_sessions/:id/affinity        # affinity snapshot
```

### 6-4. 対話（結晶化後）
```
GET    /api/v1/echoes/:echo_id/conversations      # list
POST   /api/v1/echoes/:echo_id/conversations      # create
POST   /api/v1/conversations/:id/messages          # send (streaming)
GET    /api/v1/conversations/:id/messages           # history
```

### 6-5. 法的
```
GET    /api/v1/legal/terms/current
GET    /api/v1/legal/privacy/current
POST   /api/v1/legal/consents
```

---

## 7. フロントエンド構成

### 7-1. ページ構造

```
/                           → ランディングページ
/login                      → ログイン
/signup                     → 登録 + 規約同意
/terms, /privacy            → 法的文書
/home                       → Echoダッシュボード
/echo/new                   → Echo作成（名前入力）
/echo/:id                   → Echoプロフィール（レーダーチャート）
/echo/:id/story             → ストーリーモード（ビジュアルノベルUI）
/echo/:id/story/crystallize → 結晶化セレモニー + メタリビール
/echo/:id/chat              → 対話モード
/settings                   → ユーザー設定
```

### 7-2. コンポーネント構造

```
components/
├── story/
│   ├── StoryScene.tsx            # 物語表示（タイプライター効果）
│   ├── ChoicePanel.tsx           # 選択肢パネル (3-4択)
│   ├── TiaraAvatar.tsx           # ティアラ + 吹き出し
│   ├── AffinityIndicator.tsx     # 雰囲気的アフィニティ表示
│   ├── BeaconProgress.tsx        # 進捗表示
│   └── CrystallizationCeremony.tsx
├── echo/
│   ├── EchoCard.tsx
│   ├── PersonalityRadar.tsx      # SVGレーダーチャート
│   └── StatusBadge.tsx
└── chat/
    ├── ChatMessage.tsx
    ├── ChatInput.tsx
    └── TiaraToggle.tsx
```

### 7-3. デザインテーマ

```css
/* Dark Fantasy Theme */
--color-bg-primary: #0f0a1e;
--color-bg-secondary: #1a0a2e;
--color-accent-gold: #d4af37;       /* 名前の力 */
--color-accent-emerald: #50c878;    /* ティアラ */
--color-accent-purple: #7b68ee;     /* 呼応石 */
--color-text-primary: #e8e0d0;
--color-text-secondary: #a0957e;
--font-story: 'Noto Serif JP', serif;
--font-ui: 'Noto Sans JP', sans-serif;
```

---

## 8. 全プラン横断のギャップ対策

### 8-1. コンテンツモデレーション

- LoreConstraintLayerによるpre-validation
- Claude APIのsystem promptに安全ガードレール
- 生成テキストのpost-validation（暴力・性的コンテンツ検出）
- ユーザー入力のサニタイゼーション（XSS、プロンプトインジェクション防止）
- フォールバック: 安全な固定文面

### 8-2. オフライン/低接続対応

- ビーコンコンテンツの先読みキャッシュ
- 楽観的UI更新（選択直後にローカルでアフィニティ変化表示）
- AI生成待ち中はティアラの「考え中」アニメーション
- 再接続時に自動リトライ

### 8-3. LLMコスト最適化

- Per-user daily limit (story: 50 scenes/day, chat: 100 messages/day)
- Redisキャッシュ（ビーコン固定テキスト、類似選択パターン）
- プロンプト圧縮（前シーン要約3件まで、world rules最小化）
- モデル選択: 通常シーン → Sonnet 4.6, 結晶化 → Opus 4.6, フォールバック → Haiku
- token_count追跡 + コスト異常検知

### 8-4. テスト戦略

```
Unit Tests (RSpec):
  - Models: validation, scopes, JSONB
  - Services: AffinityCalculator, BeaconNavigator, LoreConstraintLayer
  - KairosBridge: PostgreSQL backend全メソッド

Integration Tests:
  - Story flow: beacon → choice → AI scene → next beacon (API mock)
  - Crystallization: 章完走 → 結晶化 → 対話可能
  - Auth flow: signup → login → echo create → story start

Story Consistency Tests:
  - lore_constraints.json基づく自動チェッカー
  - 10パターンの選択シーケンスで章完走テスト

Frontend: Vitest + React Testing Library
E2E: Playwright (モバイルビューポート)
```

### 8-5. アナリティクス

追跡イベント: `story_started`, `scene_completed`, `beacon_reached`, `chapter_completed`, `crystallization_completed`, `chat_message_sent`, `session_abandoned`

ダッシュボード指標: 章完走率、平均シーン数/章、結晶化後の対話継続率、生成リトライ率、平均応答時間(p50/p95)、DAU

### 8-6. エラーリカバリ

- `story_sessions.status + current_beacon_id` で再開ポイント常時保持
- AI生成失敗: 3回リトライ → 固定フォールバック
- サーバークラッシュ: `story_scenes` の最後のレコードから復元
- クライアント切断: WebSocket再接続 → GET /story_sessions/:id で状態復元

---

## 9. セキュリティ

- **認証**: JWT (HS256, 24h expiry, refresh 30d) + Google OAuth + bcrypt
- **API保護**: rack-attack (10 req/sec general, 2 req/sec story gen, 5 req/sec chat)
- **CORS**: echoria.app origin only
- **データ分離**: Application layer (user_id → echo_id scoping) + PostgreSQL RLS
- **入力サニタイゼーション**: HTML escape, max length, prompt injection defense
- **AI安全**: per-user daily limit, max_tokens cap, response validation

---

## 10. 段階的実装計画

### Phase 0: Foundation (3-4日)

**Context**: 既存スキャフォールディング（`Echoria/echoria-api/`, `Echoria/echoria-web/`, `Echoria/docker/`）を検証・補完。

- 0-1. Rails API scaffolding 検証・修正
- 0-2. Next.js scaffolding 検証・修正
- 0-3. Docker Compose 起動確認
- 0-4. PostgreSQL初期マイグレーション（Section 2のスキーマ）
- 0-5. Health endpoint動作確認

**DoD**: `docker-compose up` で全サービス起動、`GET /api/v1/health` → 200、全テーブル作成済み

### Phase 1: KairosChain PG Backend + Auth (5-7日)

**Context**: 技術的リスク最大の部分。

- 1-1. `postgresql_backend.rb` 新規実装
- 1-2. `backend.rb` Factory method 拡張
- 1-3. User authentication: JWT + bcrypt + Google OAuth
- 1-4. Echo CRUD + EchoInitializerService（genesis block生成確認）
- 1-5. `Echoria::KairosBridge` 実装
- 1-6. RLS policy適用 + テスト

**DoD**: ユーザーがサインアップ→ログイン→Echo作成→プロフィール閲覧可能、genesis block存在確認、データ分離確認

### Phase 2: Story Engine (7-10日)

**Context**: Echoriaの核心。

- 2-1. Story beacons DB seeding
- 2-2. StoryOrchestrator 実装
- 2-3. LoreConstraintLayer 実装
- 2-4. SceneGenerator 実装（**アフィニティ軸を正しい5軸に修正**）
- 2-5. AffinityCalculator 実装
- 2-6. BeaconNavigator 実装
- 2-7. Chapter 1 通しテスト（prologue + 5 beacons）

**DoD**: ストーリーセッション開始→選択→AI生成シーン→ビーコン到着、アフィニティ変化確認、Lore違反検出テスト通過

### Phase 3: Crystallization & Dialogue (4-5日)

- 3-1. CrystallizationService リファクタリング（正しい5軸ベース）
- 3-2. スキル進化（L2生成→L1昇格）
- 3-3. DialogueService（結晶化人格 + スキル + 記憶をsystem prompt統合）
- 3-4. メタ・リビール演出データ準備

**DoD**: Chapter 1完了→結晶化→status: 'crystallized'、異なる選択で異なる性格、対話で物語記憶参照可能

### Phase 4: UI/UX Mobile-First (5-7日, Phase 2と一部並行)

- 4-1. ランディングページ（ダークファンタジー）
- 4-2. 認証UI
- 4-3. Echo管理UI（レーダーチャート含む）
- 4-4. Story UI（タイプライター、選択肢、ティアラ、遷移アニメ）
- 4-5. 結晶化セレモニーUI（メタリビール演出）
- 4-6. チャットUI（ストリーミング）
- 4-7. レスポンシブ検証（iPhone SE, iPhone 15, iPad mini）

**DoD**: スマートフォンで全フロー快適操作、結晶化演出動作、レーダーチャート表示

### Phase 5: Deploy + Legal + Analytics (3-4日)

- 5-1. EC2デプロイ（Docker Compose）
- 5-2. SSL設定（Let's Encrypt）
- 5-3. 法的文書（利用規約、プライバシーポリシー、特商法）
- 5-4. rack-attack レートリミティング
- 5-5. Sentry エラートラッキング
- 5-6. analytics_events 記録
- 5-7. CloudWatch基本アラーム
- 5-8. 日次バックアップ（pg_dump → S3）

**DoD**: HTTPS アクセス可能、規約同意フロー動作、Sentry接続確認、バックアップ保存確認

---

## 11. Post-MVP ロードマップ

| 優先度 | 機能 | 依存 |
|---|---|---|
| 1 | Chapter 2 コンテンツ | Ch1体験データ分析 |
| 2 | Stripe サブスクリプション | 規約フレームワーク |
| 3 | Echo as Protagonist モード (Ch2+) | protagonist_mode フラグ |
| 4 | Avatar画像生成 (DALL-E/Stable Diffusion) | 結晶化データ |
| 5 | Echo-to-Echo通信 (HestiaChain P2P) | HestiaChain MMP |
| 6 | 音声入出力 | Whisper API + TTS |
| 7 | PWA / App Store | Service Worker |
| 8 | pgvector RAG | 対話品質向上 |
| 9 | MCP Server経由PC版エクスポート | KairosChain MCP |

---

## 12. リスク評価

| リスク | 影響度 | 緩和策 |
|---|---|---|
| AI生成の物語品質 | 致命的 | ビーコン固定点 + LoreConstraintLayer + フォールバック |
| Claude APIコスト超過 | 高 | per-user limit + Haiku fallback + キャッシュ + token追跡 |
| KairosChain PG backend複雑 | 中 | SqliteBackendリファレンス、pluggable interface既存 |
| 世界観一貫性崩壊 | 高 | lore_constraints.json + 4ガード |
| EC2単一障害点 | 中 | MVP期許容、daily backup to S3 |
| プロンプトインジェクション | 中 | user inputはuser messageのみ |

---

## 13. 重要ファイルパス

### KairosChain修正対象
- `KairosChain_mcp_server/lib/kairos_mcp/storage/backend.rb` — Factory method拡張
- `KairosChain_mcp_server/lib/kairos_mcp/storage/sqlite_backend.rb` — PG backendのリファレンス
- `KairosChain_mcp_server/lib/kairos_mcp/storage/postgresql_backend.rb` — **新規作成**

### Echoria修正対象
- `Echoria/echoria-api/app/services/story_generator_service.rb` — StoryOrchestrator分割
- `Echoria/echoria-api/app/services/crystallization_service.rb` — 5軸ベースに修正
- `Echoria/story/world/lore_constraints.json` — LoreConstraintLayerの基盤

### 世界観参照
- `Who_read_this_story_2025/world_setting/` — 世界観設定
- `who_read_this_story_2026/` — プロローグ、第一章

---

## About This Document

- **Three-layer structure**: Context (why) → Procedure (how) → Judgment criteria (DoD)
- **Language**: 設計思想は日本語、技術用語・コードは英語
- **5 plans synthesized**: Plan 1 (DB schema), Plan 2 (meta-reveal), Plan 3 (philosophy), Plan 4 (lore constraints), Plan 5 (phase structure)
- **Confirmed decisions**: User as Protagonist (Ch1), Library Gem + Bridge, Docker PostgreSQL
