---
name: synoptis_development_jp
description: "Synoptis SkillSet 開発者ガイド — アーキテクチャ、拡張ポイント、内部構造"
version: "1.0"
layer: L1
tags: [synoptis, attestation, developer, architecture, extension]
---

# Synoptis SkillSet — 開発者ガイド

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────┐
│                     MCPツール (8個)                      │
│  attestation_request  attestation_issue  attestation_   │
│  attestation_verify   attestation_revoke  _list         │
│  attestation_challenge_open  _challenge_resolve         │
│  trust_score_get                                        │
├─────────────────────────────────────────────────────────┤
│                  AttestationEngine                      │
│  create_request → build_proof → verify_proof → revoke   │
├──────────┬──────────┬──────────┬────────────────────────┤
│ Verifier │ TrustScorer │ ChallengeManager │ RevocationMgr │
│ (6段階)  │ (複合スコア) │ (状態マシン)     │              │
├──────────┴──────────┴──────────┴────────────────────────┤
│              コアデータモデル                             │
│  ProofEnvelope │ MerkleTree │ ClaimTypes                │
├─────────────────────────────────────────────────────────┤
│             トランスポート層                              │
│  Router → [MMPTransport, HestiaTransport, LocalTransport]│
├─────────────────────────────────────────────────────────┤
│              レジストリ層                                 │
│  Base (インターフェース) → FileRegistry (JSONL)           │
├─────────────────────────────────────────────────────────┤
│              フック                                      │
│  mmp_hooks.rb (MMPプロトコル統合)                        │
└─────────────────────────────────────────────────────────┘
```

## ディレクトリ構造

```
templates/skillsets/synoptis/
├── skillset.json                         # SkillSetメタデータ (name, version, layer, provides)
├── config/
│   └── synoptis.yml                      # 全設定パラメータ
├── knowledge/
│   └── synoptis_attestation_protocol/
│       └── synoptis_attestation_protocol.md  # L1知識: プロトコル仕様
├── lib/
│   ├── synoptis.rb                       # トップレベルモジュール、autoloadハブ、load!/config
│   └── synoptis/
│       ├── claim_types.rb                # 7クレームタイプ（重み付き）
│       ├── proof_envelope.rb             # ProofEnvelopeデータモデル
│       ├── merkle.rb                     # バイナリMerkleツリー (SHA-256)
│       ├── verifier.rb                   # 6段階検証
│       ├── attestation_engine.rb         # ライフサイクルオーケストレータ
│       ├── revocation_manager.rb         # 失効ロジック
│       ├── trust_scorer.rb              # 複合信頼スコアリング
│       ├── graph_analyzer.rb            # グラフベース異常検知
│       ├── challenge_manager.rb          # チャレンジ状態マシン
│       ├── hooks/
│       │   └── mmp_hooks.rb             # MMPプロトコルアクション登録
│       ├── registry/
│       │   ├── base.rb                  # 抽象レジストリインターフェース
│       │   └── file_registry.rb         # JSONL ファイルベース実装
│       └── transport/
│           ├── base.rb                  # 抽象トランスポートインターフェース
│           ├── router.rb               # 優先順位付きトランスポートルーティング
│           ├── mmp_transport.rb         # MMP配信
│           ├── hestia_transport.rb      # Hestia発見 + MMP配信
│           └── local_transport.rb       # インスタンス内配信
└── tools/
    ├── attestation_request.rb
    ├── attestation_issue.rb
    ├── attestation_verify.rb
    ├── attestation_revoke.rb
    ├── attestation_list.rb
    ├── attestation_challenge_open.rb
    ├── attestation_challenge_resolve.rb
    └── trust_score_get.rb
```

## コアデータモデル: ProofEnvelope

ProofEnvelopeは認証の正準単位 — 署名済み、バージョン管理された自己完結型レコードです。

### フィールド定義

| フィールド | 型 | 説明 |
|-----------|------|------|
| `proof_id` | String | 自動生成: `"att_<uuid>"` |
| `claim_type` | String | 登録済み7クレームタイプのいずれか |
| `disclosure_level` | String | `'existence_only'` または `'full'` |
| `attester_id` | String | 認証発行エージェントのID |
| `attestee_id` | String | 被認証エージェントのID |
| `subject_ref` | String | 認証対象の参照（例: `"skill:fastqc_v1"`） |
| `target_hash` | String | `subject_ref` の `sha256:<hex>` |
| `evidence_hash` | String | エビデンスJSONの `sha256:<hex>` |
| `evidence` | Hash/nil | 実エビデンス（`disclosure_level == 'full'` の時のみ） |
| `merkle_root` | String | エビデンス値から構築されたMerkleツリーのルート |
| `merkle_proof` | Array | プルーフパス: `[{hash:, side:}, ...]` 最初のリーフ用 |
| `nonce` | String | 32文字hex乱数ノンス（または `request_id` にバインド） |
| `signature` | String | 正準JSON上のBase64 RSA-SHA256署名 |
| `attester_pubkey_fingerprint` | String | 署名鍵のフィンガープリント |
| `transport` | String | 使用トランスポート: デフォルト `'local'` |
| `issued_at` | ISO8601 | 作成タイムスタンプ (UTC) |
| `expires_at` | ISO8601 | 有効期限タイムスタンプ |
| `status` | String | `'active'`、`'revoked'`、または `'challenged'` |
| `revoke_ref` | Hash/nil | 失効時 `{reason:, revoked_at:}` |

### 署名用正準JSON

`SIGNABLE_FIELDS` が決定論的ペイロードを定義:

```ruby
SIGNABLE_FIELDS = %w[proof_id claim_type disclosure_level attester_id attestee_id
                     subject_ref target_hash evidence_hash merkle_root nonce
                     issued_at expires_at]
```

`canonical_json` はこれらのフィールドのみからソート済みキーJSONを生成。エビデンス自体は署名ペイロードから除外 — ハッシュのみが参加し、選択的開示を可能にします。

### 主要メソッド

```ruby
proof.canonical_json          # 署名用決定論的JSON
proof.sign!(crypto)           # MMP::Crypto使用でインプレース署名
proof.valid_signature?(key)   # RSA-SHA256署名を検証
proof.expired? / revoked? / active?  # ステータスヘルパー
proof.to_anchor               # Hestia::Chain::Core::Anchorに変換
ProofEnvelope.from_h(hash)    # Hashからデシリアライズ
```

## MerkleTree

SHA-256を使用するバイナリMerkleツリー。

### 構築アルゴリズム

```
入力:   [leaf_a, leaf_b, leaf_c]
Level 0: [SHA256(leaf_a), SHA256(leaf_b), SHA256(leaf_c)]
  → 奇数個: 最後を複製 → [H(a), H(b), H(c), H(c)]
Level 1: [SHA256(H(a)+H(b)), SHA256(H(c)+H(c))]
Level 2: [SHA256(L1[0]+L1[1])]  ← ルート
```

### プルーフ生成 (`proof_for(index)`)

ルート以下の各レベルで:
- 偶数インデックス: `index+1` の兄弟、side `:right`
- 奇数インデックス: `index-1` の兄弟、side `:left`
- 兄弟不在（奇数レベル長）: カレントを複製
- 親: `index /= 2`

### 検証 (`MerkleTree.verify(leaf, proof, expected_root)`)

```ruby
current = SHA256(leaf.to_s)
proof.each do |step|
  current = step[:side] == :right ?
    SHA256(current + step[:hash]) :
    SHA256(step[:hash] + current)
end
current == expected_root
```

### AttestationEngineでの使用

`evidence.values.map(&:to_s)` からエビデンスが1フィールド超の場合に構築。インデックス0（最初のリーフ）のプルーフを生成。

## Verifier: 6段階検証フロー

```ruby
verifier.verify(proof, options = {})
# => { valid: true/false, reasons: [], trust_hints: {} }
```

### 第1段階 — 署名検証

`canonical_json` 上のRSA-SHA256。公開鍵未提供の場合、`'no_public_key_provided'` を reasons に追加し trust_hints に記録。

### 第2段階 — エビデンスハッシュ検証

エビデンスJSONの `sha256:<hex>` を計算し、`proof.evidence_hash` と比較。`evidence` と `evidence_hash` の両方が存在する場合のみ実行。

### 第3段階 — 失効チェック（fullモードのみ）

`proof.revoked?` とレジストリの `find_revocation(proof_id)` を確認。失効詳細をtrust_hintsに格納。

### 第4段階 — 有効期限チェック（fullモードのみ）

`expires_at` を現在のUTC時刻と比較。

### 第5段階 — Merkleプルーフ検証（オプトイン）

`check_merkle: true` かつmerkleデータが存在する場合のみ実行。`evidence.values.first.to_s` をリーフ値として使用。`existence_only` モードでは `'merkle_proof_unverifiable'`（検証対象のエビデンスなし）。

### 第6段階 — クレームタイプ検証

`ClaimTypes.valid_claim_type?` に対して `claim_type` を検証。

### モード一覧

| モード | 段階 | 失効チェック | 期限チェック |
|--------|------|-------------|-------------|
| `full` | 1-6 | あり | あり |
| `signature_only` | 1, 2, 6 | なし | なし |

## 信頼スコアリング

### 数式

```
score = quality × freshness × diversity × (1.0 - revocation_penalty) × (1.0 - velocity_penalty)
score = score.clamp(0.0, 1.0)
```

### コンポーネント詳細

**quality_score** — 重み付きエビデンス完全性:
```
quality = Σ(ClaimTypes.weight_for(claim_type) × evidence_completeness(proof)) / proof_count
```

エビデンス完全性:
- `>= min_evidence_fields` キー: `1.0`
- エビデンスありだがフィールド不足: `0.5`
- エビデンスなし、`existence_only`: `0.7`
- エビデンスなし（その他）: `0.3`

**freshness_score** — 指数関数的時間減衰:
```
freshness = mean( exp(-age_days × ln(2) / half_life_days) )
```
デフォルト `half_life_days = 90`。

**diversity_score** — 認証者の一意性:
```
diversity = unique_attester_count / total_attestation_count
```

**revocation_penalty** — 認証者自身の失効発行率:
```
revocation_penalty = revoked_issued_count / total_issued_count
```

**velocity_penalty** — バースト発行ペナルティ:
```
if recent_24h_count > velocity_threshold:
  velocity_penalty = (count - threshold) / count
else: 0.0
```
デフォルト `velocity_threshold_24h = 10`。

## グラフ分析

エージェントごとに3つのメトリクスを計算:

### cluster_coefficient

エージェントの認証者間の相互認証率。

```
cluster_coeff = mutual_attesting_pairs / C(n, 2)
```

対象エージェントの認証者のうち、双方向認証が存在するペアの割合。フラグ: `'high_cluster_coefficient'`（> 0.8の場合）。

### external_connection_ratio

相互クラスタに含まれない認証者の割合。

```
ecr = external_attesters / total_unique_attesters
```

フラグ: `'low_external_connections'`（< 0.3の場合）。

### velocity_anomaly

エージェントが過去24時間に発行した認証の数。フラグ: `'velocity_anomaly'`（> 10の場合）。

`trust_score_get` ツールは `TrustScorer.anomaly_flags` + `GraphAnalyzer.anomaly_flags` を単一リストにマージします。

## チャレンジプロトコル

### 状態遷移図

```
                 open_challenge()
  active proof ─────────────────► challenged proof
       │                              │
       │                    ┌─────────┴─────────┐
       │                    │                   │
       │          resolve('uphold')    resolve('invalidate')
       │                    │                   │
       │                    ▼                   ▼
       │            proof → active      proof → revoked
       │            challenge →         challenge →
       │            resolved_valid      resolved_invalid
       │
       │         期限切れ（未解決）
       │                    │
       │                    ▼
       │            challenge → challenged_unresolved
       │            proof は 'challenged' のまま
```

### ガード条件

- `open_challenge`: プルーフが存在、未失効、同一プルーフのオープンチャレンジなし、チャレンジャーの `max_active_challenges`（5）未満
- `resolve_challenge`: チャレンジがオープン状態、decision が `'uphold'` または `'invalidate'`

### チャレンジレコードフィールド

```ruby
{
  challenge_id: "chl_<uuid>",
  challenged_proof_id:,
  challenger_id:,
  reason:,
  evidence_hash:,          # オプション: チャレンジャーエビデンスのsha256
  status: 'open',
  response: nil,
  response_at: nil,
  deadline_at:,            # 現在時刻 + response_window_hours（デフォルト72時間）
  resolved_at: nil,
  created_at:
}
```

## トランスポート層

### Routerの優先順位ロジック

```ruby
router.send(target_id, message)
```

設定済み優先順位リスト（デフォルト: `['mmp', 'hestia', 'local']`）を走査。利用不可のトランスポートをスキップ。最初の成功を返却。全失敗時:

```ruby
{ success: false, transport: 'none', error: 'All transports failed', details: [...] }
```

### トランスポート実装

| トランスポート | available? | 発見 | 配信 |
|-------------|-----------|------|------|
| **MMP** | `defined?(MMP::Protocol)` | N/A | `MeetingRouter.instance.handle_message` |
| **Hestia** | `defined?(Hestia) && Hestia.loaded?` | `Hestia::AgentRegistry.find` | MMPTransport経由 |
| **Local** | `defined?(Multiuser) && Multiuser.loaded?` | N/A | `Multiuser::TenantManager.deliver_to` |

Hestiaは発見専用: `AgentRegistry` 経由でエージェントを検索し、`capabilities.include?('mutual_attestation')` を確認後、MMP経由で配信。

## レジストリ

### Baseインターフェース

全メソッドが `NotImplementedError` を発生:

```ruby
save_proof(proof_hash)
find_proof(proof_id)
list_proofs(filters = {})
update_proof_status(proof_id, status, revoke_ref = nil)
save_revocation(revocation_hash)
find_revocation(proof_id)
save_challenge(challenge_hash)
find_challenge(challenge_id)
list_challenges(**filters)
update_challenge(challenge_id, updated_hash)
```

### FileRegistry実装

`Mutex` によるスレッドセーフなJSONLファイル:

```
storage_path/
  attestation_proofs.jsonl
  attestation_revocations.jsonl
  attestation_challenges.jsonl
```

フィルタサポート:
- `list_proofs`: `:agent_id`（認証者または被認証者に一致）、`:claim_type`、`:status`
- `list_challenges`: `:challenger_id`、`:challenged_proof_id`、`:status`

更新はメモリ内変更後にファイル全体を再書き込み。

## 拡張ポイント

### 新しいクレームタイプの追加

`lib/synoptis/claim_types.rb` を編集:

```ruby
TYPES = {
  # 既存タイプ...
  'MY_CUSTOM_TYPE' => { weight: 0.6, description: 'カスタム認証タイプ' }
}.freeze
```

重み（0.0〜1.0）は信頼品質スコアへの寄与度を決定します。

### カスタムトランスポートの実装

1. `lib/synoptis/transport/my_transport.rb` を作成:

```ruby
module Synoptis
  module Transport
    class MyTransport < Base
      def available?
        # トランスポートの依存が読み込まれていればtrue
      end

      def send_message(target_id, message)
        # ターゲットにメッセージを配信
        # { success: true/false, ... } を返す
      end
    end
  end
end
```

2. Routerに登録（`router.rb` を変更または動的登録を追加）。
3. `config/synoptis.yml` の `transport.priority` に追加。

### PostgreSQLレジストリ（Phase 5 — 計画中）

`Synoptis::Registry::PostgresRegistry < Base` を実装:

```ruby
class PostgresRegistry < Base
  def initialize(connection_config)
    @db = PG.connect(connection_config)
  end

  def save_proof(proof_hash)
    @db.exec_params("INSERT INTO attestation_proofs ...")
  end

  # ... 全Baseメソッドを実装
end
```

設定で切替:
```yaml
storage:
  backend: postgres
  postgres:
    host: localhost
    database: synoptis
```

## 設定リファレンス

`config/synoptis.yml` の全パラメータ:

```yaml
# マスタースイッチ
enabled: false

attestation:
  default_expiry_days: 180        # プルーフの有効期間
  min_evidence_fields: 2          # エビデンスハッシュの最小キー数
  allow_self_attestation: false   # エージェントが自身を認証できるか
  auto_reciprocate: false         # 逆方向認証の自動発行

trust:
  score_half_life_days: 90        # 鮮度の指数関数的減衰半減期
  cluster_threshold: 0.8          # cluster_coefficientがこの値を超えるとフラグ
  velocity_threshold_24h: 10      # 24時間でN件超の認証でフラグ/ペナルティ
  min_diversity: 0.3              # external_connection_ratioがこの値未満でフラグ

challenge:
  response_window_hours: 72       # チャレンジ応答の期限
  max_active_challenges: 5        # チャレンジャーごとの最大オープンチャレンジ数

storage:
  backend: file                   # 'file' (JSONL) または将来の 'postgres'
  file_path: storage/synoptis     # .kairosデータディレクトリからの相対パス

transport:
  priority: [mmp, hestia, local]  # トランスポート優先順位
```

## テスト実行方法

```bash
cd KairosChain_mcp_server

# Synoptis全テストスイート
ruby test_synoptis.rb

# 詳細出力で実行
ruby test_synoptis.rb -v

# Synoptis含む全テスト
ruby test_local.rb
ruby test_skillset_manager.rb
```

テストスイートのカバー範囲:
- ProofEnvelopeの構築とシリアライズ
- MerkleTreeの構築、プルーフ生成、検証
- 全6段階の検証
- 信頼スコア数式とエッジケース
- グラフ分析メトリクスと異常検知
- チャレンジプロトコルの状態遷移
- フォールバック付きトランスポートルーティング
- FileRegistryのCRUDとフィルタリング
- 全8MCPツールの統合テスト
