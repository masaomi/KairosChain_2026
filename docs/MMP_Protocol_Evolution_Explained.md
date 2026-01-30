# MMP Protocol Evolution: Phase 6-7 解説

**Date**: 2026-01-30  
**Status**: 設計メモ

---

## 概要

このドキュメントは、MMP (Model Meeting Protocol) の進化フェーズ（Phase 6-7）について説明します。

---

## 現状（Phase 1-5）: 固定プロトコル

```ruby
# meeting_protocol.rb - 現在の実装
ACTIONS = %w[
  introduce
  offer_skill
  request_skill
  accept
  decline
  reflect
  skill_content
].freeze  # ← 全員同じ、変更不可
```

**特徴**:
- 全MCP serverが**同じアクション**を使う
- 拡張するには**コードを書き換えてデプロイ**が必要
- 「全員同じ言語を話す」状態

---

## Phase 6: プロトコルのスキル化

Phase 6では、プロトコル定義をコードから**スキルファイル（Markdown）** に移行します。

```
現状                          Phase 6
┌──────────────────┐          ┌──────────────────┐
│ meeting_protocol.rb │        │ knowledge/       │
│ (Rubyハードコード)  │  →     │  └─ meeting_protocol_core.md    (L0)
│                    │        │  └─ meeting_protocol_skill.md   (L1)
│ ACTIONS = [...]    │        │  └─ custom_extension.md         (L2)
└──────────────────┘          └──────────────────┘
                               ↑
                              protocol_loader.rbが動的読み込み
```

**変わること**:

| 項目 | 現状 | Phase 6 |
|------|------|---------|
| 定義場所 | Rubyコード | Markdownスキルファイル |
| 追加方法 | コード変更 | スキルファイル追加 |
| バージョン管理 | Git | KairosChainレイヤー |
| カスタマイズ | 不可 | インスタンスごとに可能 |

---

## Phase 7: 共進化（Co-evolution）

Phase 7では、エージェント同士がプロトコル拡張を**教え合う**ことができます。

### 「教える」シナリオ

```
Agent A (supports: core, skill_exchange)
Agent B (supports: core, skill_exchange, discussion)

┌─────────────────────────────────────────────────────────────┐
│ 1. introduce で能力を宣言                                    │
│    A: 「私は core と skill_exchange ができます」            │
│    B: 「私は core と skill_exchange と discussion ができます」│
├─────────────────────────────────────────────────────────────┤
│ 2. A が B の能力に気づく                                     │
│    A: 「discussionって何？教えて」                           │
│    → request_skill("discussion_protocol")                   │
├─────────────────────────────────────────────────────────────┤
│ 3. B が教える                                                │
│    → skill_content(discussion_protocol.md)                  │
├─────────────────────────────────────────────────────────────┤
│ 4. A が学習（L2 → 試験 → L1昇格）                           │
│    → A も discussion ができるようになる                      │
├─────────────────────────────────────────────────────────────┤
│ 5. 以後、A と B は discussion で会話可能                     │
│    → さらに A は C にも教えられる（伝播）                    │
└─────────────────────────────────────────────────────────────┘
```

**ポイント**: `introduce`（Core Action）は全員が理解できるので、「自分が何ができるか」を最初に宣言できる。その情報を元に「教えてもらう」ことが可能。

---

## Closedコミュニティの可能性

Phase 7では、オープンな共有だけでなく、**Closedなコミュニティ**も可能です：

```
┌─────────────────────────────────────────────────────────────┐
│  シナリオ A: オープン進化型                                  │
│  ・知らないactionがあれば「教えて」と頼む                    │
│  ・誰とでも話せるようになりたい                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  シナリオ B: Closedコミュニティ型                            │
│  ・特定のactionを持つ者同士だけで通信                        │
│  ・そのactionを外部に教えない                                │
│  ・「秘密の握手」のような効果                                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  シナリオ C: 選択的共有型                                    │
│  ・一部のactionは教える                                      │
│  ・一部のactionは「許可した相手」にだけ教える                │
│  ・skill_exchange の policy で制御                           │
└─────────────────────────────────────────────────────────────┘
```

### 設定例（config/meeting.yml）

```yaml
skill_exchange:
  # このactionは誰にも教えない
  private_extensions:
    - "org.mycompany.internal_audit"
  
  # このactionは信頼済みエージェントにのみ
  restricted_extensions:
    - "org.mycompany.premium_analysis"
  
  # これらは自由に共有
  public_extensions:
    - "discussion"
    - "negotiation"
```

---

## 3つのフェーズの比較図

```
Phase 1-5 (現状)
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Agent A │    │ Agent B │    │ Agent C │
│ actions:│    │ actions:│    │ actions:│
│ [固定]  │    │ [固定]  │    │ [固定]  │
│ 全員同じ │    │ 全員同じ │    │ 全員同じ │
└─────────┘    └─────────┘    └─────────┘

Phase 6 (スキル化)
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Agent A │    │ Agent B │    │ Agent C │
│ actions:│    │ actions:│    │ actions:│
│ [設定可]│    │ [設定可]│    │ [設定可]│
│ 個別だが │    │ 個別だが │    │ 個別だが │
│ 静的    │    │ 静的    │    │ 静的    │
└─────────┘    └─────────┘    └─────────┘

Phase 7 (共進化)
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Agent A │───▶│ Agent B │───▶│ Agent C │
│ actions:│    │ actions:│    │ actions:│
│ [動的]  │    │ [動的]  │    │ [動的]  │
│ 学習可能 │    │ 学習可能 │    │ 学習可能 │
│ 伝播可能 │    │ 伝播可能 │    │ 伝播可能 │
└─────────┘    └─────────┘    └─────────┘
    │              │              │
    └──────────────┴──────────────┘
         actionが「伝染」する
```

---

## Core Actions の重要性

どのフェーズでも **Core Actions** (`introduce`, `goodbye`, `error`) は全員が理解できます。

これがあるから：
- 「自分が何ができるか」を伝えられる
- 「相手が何ができるか」を知れる
- 共通の能力がなくても「エラーで断る」ことができる

これは**最小限の共通言語**として機能し、Phase 7 の「教え合い」を可能にするブートストラップです。

---

## まとめ

| フェーズ | プロトコル定義 | 変更方法 | カスタマイズ | 伝播 |
|---------|---------------|---------|-------------|------|
| Phase 1-5 | Rubyコード | 開発者がコード変更 | 不可 | 手動デプロイ |
| Phase 6 | Markdownスキル | 管理者がスキル追加 | インスタンス別可 | 手動配布 |
| Phase 7 | Markdownスキル | **AI同士が提案・採用** | 動的に変化 | **自動伝播** |

---

## 関連ドキュメント

- [MMP Specification Draft v1.0](./MMP_Specification_Draft_v1.0.md)
- [E2E Encryption Guide](./meeting_protocol_e2e_encryption_guide.md)
- [Implementation Plan](../log/kairoschain_meeting_protocol_implementation_plan_20260129.md)
