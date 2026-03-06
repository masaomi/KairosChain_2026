---
name: synoptis_attestation_jp
description: "Synoptis 相互証明 — 暗号署名付き証明エンベロープによるクロスエージェント信頼検証"
version: 1.0
layer: L1
tags: [documentation, readme, synoptis, attestation, trust, p2p, audit, challenge]
readme_order: 4.7
readme_lang: jp
---

## Synoptis：相互証明プロトコル (v2.7.0)

### Synoptis とは

Synoptis は、暗号署名付き証明プルーフによるクロスエージェント信頼検証のためのオプトイン SkillSet です。エージェントはあらゆるサブジェクト（知識エントリ、スキルハッシュ、チェーンブロック、パイプライン出力など）に対して事実を証明でき、その証明を検証・取り消し・チャレンジする仕組みを提供します。

Synoptis は完全に SkillSet として実装されており、新機能をコアではなく SkillSet として表現するという KairosChain の設計原則を保持しています。

### アーキテクチャ

```
KairosChain (MCP Server)
├── [core] L0/L1/L2 + private blockchain
├── [SkillSet: mmp] P2P direct mode, /meeting/v1/*
├── [SkillSet: hestia] Meeting Place + 信頼アンカー
└── [SkillSet: synoptis] 相互証明プロトコル
      ├── ProofEnvelope       ← 署名付き証明データ構造
      ├── Verifier            ← 構造的 + 暗号学的検証
      ├── AttestationEngine   ← 証明ライフサイクル（作成・検証・一覧）
      ├── RevocationManager   ← 認可チェック付き取り消し
      ├── ChallengeManager    ← チャレンジ/応答ライフサイクル
      ├── TrustScorer         ← 加重信頼スコア計算
      ├── Registry::FileRegistry ← ハッシュチェーン付き追記専用 JSONL
      ├── Transport            ← MMP / Hestia / Local トランスポート抽象
      └── tools/               ← 7 MCP ツール
```

### クイックスタート

#### 1. synoptis SkillSet のインストール

```bash
# Synoptis は MMP に依存します。両方をインストール:
kairos-chain skillset install templates/skillsets/mmp
kairos-chain skillset install templates/skillsets/synoptis
```

#### 2. 証明の発行

Claude Code / Cursor で：

```
「knowledge/my_skill の整合性を検証済みとして証明して」
```

これは `attestation_issue(subject_ref: "knowledge/my_skill", claim: "integrity_verified")` を呼び出します。

#### 3. 検証と信頼クエリ

```
「knowledge/my_skill の信頼スコアは？」
```

これは `trust_query(subject_ref: "knowledge/my_skill")` を呼び出します。

### MCP ツール

| ツール | 説明 |
|--------|------|
| `attestation_issue` | サブジェクトに対する署名付き証明プルーフを発行 |
| `attestation_verify` | プルーフの有効性を検証（構造、署名、有効期限、取り消し） |
| `attestation_revoke` | 証明を取り消し（元の証明者または管理者のみ） |
| `attestation_list` | 証明一覧を表示（subject_ref、attester_id でフィルタ可能） |
| `trust_query` | 証明履歴に基づく信頼スコアを計算 |
| `challenge_create` | 既存の証明にチャレンジ（validity、evidence_request、re_verification） |
| `challenge_respond` | チャレンジに追加証拠で応答 |

### MMP 統合

Synoptis は `MMP::Protocol.register_handler` 経由で5つの MMP アクションを登録し、P2P 証明交換を可能にします：

| MMP アクション | 説明 |
|---------------|------|
| `attestation_request` | ピアに証明をリクエスト |
| `attestation_response` | 署名付き ProofEnvelope で応答 |
| `attestation_revoke` | 取り消しをブロードキャスト |
| `challenge_create` | 元の証明者にチャレンジを送信 |
| `challenge_respond` | MMP 経由でチャレンジに応答 |

すべての P2P メッセージは `MMP::PeerManager` 経由の Bearer トークン認証を使用します。認証済みピア ID は `MeetingRouter` が `_authenticated_peer_id` として注入します。

### 信頼スコアリング

信頼スコアは加重複合値として計算されます：

| 要素 | 重み | 説明 |
|------|------|------|
| 品質 (Quality) | 0.30 | 有効な（未取消・未期限切れ）証明の比率 |
| 鮮度 (Freshness) | 0.25 | 最新証明の新しさ（指数減衰、24時間半減期） |
| 多様性 (Diversity) | 0.25 | ユニーク証明者の数（上限5） |
| 速度 (Velocity) | 0.10 | 過去7日間の証明レート |
| 取消ペナルティ | −0.10 | 取り消された証明に対するペナルティ |

### レジストリと構成的記録

すべての証明データはハッシュチェーン連結（`_prev_entry_hash`）付きの追記専用 JSONL ファイルに保存されます。これは構成的記録（命題5）を実装しています：各レコードはシステムの履歴を不可逆的に拡張します。

レジストリ種別：
- `proofs.jsonl` — 証明プルーフエンベロープ
- `revocations.jsonl` — 取り消しレコード
- `challenges.jsonl` — チャレンジと応答レコード

`trust_query` でレジストリの整合性を検証できます — 応答に `registry_integrity.valid` フィールドが含まれます。

### ProofEnvelope 構造

```json
{
  "proof_id": "uuid",
  "attester_id": "agent_instance_id",
  "subject_ref": "knowledge/my_skill",
  "claim": "integrity_verified",
  "evidence": "ハッシュチェーンの手動レビュー",
  "merkle_root": "sha256_of_content",
  "content_hash": "sha256_of_canonical_json",
  "signature": "rsa_sha256_signature",
  "timestamp": "2026-03-06T12:00:00Z",
  "ttl": 86400,
  "version": "1.0.0"
}
```

### チャレンジワークフロー

1. 任意のエージェントが `challenge_create(proof_id, challenge_type, details)` で証明にチャレンジ
2. 元の証明者がチャレンジを受信（MMP またはローカル通知）
3. 証明者が `challenge_respond(challenge_id, response, evidence)` で追加証拠とともに応答
4. チャレンジ種別：`validity`（プルーフが正しくない可能性）、`evidence_request`（追加証拠が必要）、`re_verification`（条件が変化した可能性）

### トランスポート層

Synoptis は複数のトランスポート機構をサポートします：

| トランスポート | バックエンド | 用途 |
|--------------|------------|------|
| MMP | `MMP::PeerManager` | P2P 直接証明交換 |
| Hestia | `Hestia::PlaceRouter` | Meeting Place 経由（将来） |
| Local | レジストリ直接アクセス | シングルインスタンスおよび Multiuser モード |

トランスポート選択は利用可能な SkillSet に基づいて自動的に行われます。

### 依存関係

- **必須**: MMP SkillSet (>= 1.0.0)
- **オプション**: Hestia SkillSet（Meeting Place トランスポート用）

プロトコルの完全な仕様については、synoptis SkillSet をインストールし、同梱の knowledge（`synoptis_protocol`）を参照してください。
