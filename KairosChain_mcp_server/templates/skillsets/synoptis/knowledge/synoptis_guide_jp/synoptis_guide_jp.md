---
name: synoptis_guide_jp
description: "Synoptis SkillSet ユーザーガイド — 相互認証ツールとワークフロー"
version: "1.0"
layer: L1
tags: [synoptis, attestation, trust, user-guide, skillset]
---

# Synoptis SkillSet — ユーザーガイド

## 概要

Synoptisは、KairosChainの相互認証（Mutual Attestation）SkillSetです。エージェント同士が暗号署名付きプルーフを通じて互いの主張を検証できます。

- **相互認証**: エージェントが互いの能力、出力、コンプライアンスについて署名付きプルーフを発行・検証
- **信頼スコア**: 品質・鮮度・多様性・異常検知を組み合わせた複合信頼メトリック
- **チャレンジプロトコル**: 異議のある認証への紛争解決メカニズム
- **選択的開示**: エビデンスの完全開示または存在証明のみ（Merkleプルーフ）

KairosChainアーキテクチャにおいて、SynoptisはL1（知識/ガバナンス層）で動作し、自律エージェントが中央集権的な権威なしに互いを評価するための信頼インフラを提供します。

## クイックスタート

### 1. Synoptisを有効化

KairosChainインスタンスの `config/synoptis.yml` で:

```yaml
enabled: true
```

またはSkillSetマネージャー経由でインストール:

```
"synoptis SkillSetをインストールして"
```

### 2. インストール確認

```
"attestation_listを実行して"
```

ツールが利用可能で空リストが返れば、Synoptisは有効です。

## ツールリファレンス

Synoptisは8つのMCPツールを提供します。

### attestation_request — 認証をリクエスト

ピアエージェントに認証リクエストを送信します。

```
"agent-Bにパイプラインfastqc_v1のPIPELINE_EXECUTION認証をリクエストして"
```

JSON-RPC:
```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "tools/call",
  "params": {
    "name": "attestation_request",
    "arguments": {
      "target_agent": "agent-B",
      "claim_type": "PIPELINE_EXECUTION",
      "subject_ref": "skill:fastqc_v1",
      "disclosure_level": "existence_only"
    }
  }
}
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `target_agent` | はい | ピアのエージェントID |
| `claim_type` | はい | 7種のクレームタイプのいずれか（下記参照） |
| `subject_ref` | はい | 認証対象の参照 |
| `disclosure_level` | いいえ | `existence_only`（デフォルト）または `full` |

戻り値: `request_id`、`nonce`、配信ステータス。

### attestation_issue — 署名付き認証を発行

ProofEnvelopeを構築・署名・配信します。

```
"agent-Bに対してPIPELINE_EXECUTIONの認証を発行、subject skill:fastqc_v1、evidence {\"output_hash\":\"abc123\",\"runtime_sec\":42}"
```

JSON-RPC:
```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {
    "name": "attestation_issue",
    "arguments": {
      "target_agent": "agent-B",
      "claim_type": "PIPELINE_EXECUTION",
      "subject_ref": "skill:fastqc_v1",
      "evidence": "{\"output_hash\":\"abc123\",\"runtime_sec\":42}",
      "request_id": "req_...",
      "disclosure_level": "full",
      "expires_in_days": 90
    }
  }
}
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `target_agent` | はい | 被認証者のエージェントID |
| `claim_type` | はい | クレームタイプ |
| `subject_ref` | はい | 対象の参照 |
| `evidence` | はい | エビデンスデータ（JSON文字列） |
| `request_id` | いいえ | 事前のattestation_requestとリンク（nonceをバインド） |
| `disclosure_level` | いいえ | `existence_only`（デフォルト）または `full` |
| `expires_in_days` | いいえ | デフォルト180日の有効期限を上書き |

戻り値: `proof_id`、`status`、`issued_at`、`expires_at`、署名有無、配信ステータス。

### attestation_verify — プルーフを検証

シリアライズされたProofEnvelopeを最大6段階で検証します。

```
"この認証プルーフを検証して: {proof JSON}"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `proof_payload` | はい | シリアライズされたProofEnvelope（JSON文字列） |
| `mode` | いいえ | `full`（デフォルト、全6段階）または `signature_only` |
| `public_key_pem` | いいえ | 署名検証用のPEM公開鍵 |

検証段階（fullモード）:
1. 署名検証（RSA-SHA256）
2. エビデンスハッシュ検証
3. 失効チェック
4. 有効期限チェック
5. Merkleプルーフ検証
6. クレームタイプ検証

### attestation_revoke — 認証を失効

```
"認証att_abc123を失効させて、理由: エビデンスが不正確と判明"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `proof_id` | はい | 失効するプルーフのID |
| `reason` | はい | 失効理由 |

戻り値: `revocation_id`、`revoked_by`、`revoked_at`。被認証者にベストエフォートで通知。

### attestation_list — 認証を一覧表示

```
"agent-BのPIPELINE_EXECUTIONアクティブ認証を一覧表示して"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `agent_id` | いいえ | 認証者または被認証者でフィルタ |
| `claim_type` | いいえ | クレームタイプでフィルタ |
| `status` | いいえ | `active`、`revoked`、または `expired` |

戻り値: `total_count`、`filters`、サマリーフィールド付きの `proofs[]` 配列。

### attestation_challenge_open — チャレンジを開始

アクティブな認証に異議を申し立てます。

```
"認証att_abc123にチャレンジ、理由: 出力ハッシュが再実行結果と一致しない"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `proof_id` | はい | チャレンジ対象のプルーフ |
| `reason` | はい | チャレンジ理由 |
| `evidence` | いいえ | 裏付けエビデンス（JSON文字列、sha256ハッシュとして保存） |

戻り値: `challenge_id`、`status: 'open'`、`deadline_at`（デフォルト72時間）。認証者に通知。

### attestation_challenge_resolve — チャレンジを解決

```
"チャレンジchl_xyz789をupholdで解決、response: '再実行で元の結果を確認'"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `challenge_id` | はい | 解決するチャレンジ |
| `decision` | はい | `uphold`（プルーフはアクティブ維持）または `invalidate`（プルーフ失効） |
| `response` | いいえ | 説明テキスト |

戻り値: 解決ステータス、判定、タイムスタンプ。双方に通知。

### trust_score_get — 信頼スコアを取得

```
"agent-Bの信頼スコアを取得して"
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `agent_id` | はい | 評価対象エージェント |
| `window_days` | いいえ | 遡及期間（デフォルト: 180日） |

戻り値:
- `score`: 0.0〜1.0の複合信頼スコア
- `breakdown`: quality、freshness、diversity、revocation_penalty、velocity_penalty
- `graph_metrics`: cluster_coefficient、external_connection_ratio、velocity_24h
- `anomaly_flags`: 検出された異常のリスト
- `attestation_count`: 期間内の認証数

## ワークフロー例

### パターン1: パイプライン認証 — 発行と検証

Agent Aがパイプラインを実行し、Agent Bが結果を検証する典型的なフロー:

```
# ステップ1: Agent BがAgent Aに認証をリクエスト
"agent-Aにskill:rnaseq_pipelineのPIPELINE_EXECUTION認証をリクエストして"

# ステップ2: Agent Aがエビデンス付き認証を発行
"agent-Bに対してPIPELINE_EXECUTION認証を発行、
 subject skill:rnaseq_pipeline、
 evidence {\"output_hash\":\"sha256:abc...\",\"sample_count\":12,\"runtime_sec\":3600}"

# ステップ3: Agent Bが受信したプルーフを検証
"この認証プルーフを検証して: {受信したproof JSON}"

# ステップ4: 信頼スコアを確認
"agent-Aの信頼スコアを取得して"
```

### パターン2: 不正な認証へのチャレンジ

認証が不正確と判明した場合:

```
# ステップ1: Agent Cが疑わしい認証を発見
"agent-XのGENOMICS_QC認証を一覧表示して"

# ステップ2: エビデンス付きでチャレンジを開始
"認証att_suspicious123にチャレンジ、
 reason: 'QCメトリクスが再分析と一致しない'、
 evidence: {\"reanalysis_hash\":\"sha256:def...\",\"discrepancy\":\"fastqcスコアが20%以上乖離\"}"

# ステップ3: 解決を待つ（72時間期限）
# 認証者またはリゾルバーが応答:
"チャレンジchl_abcをinvalidateで解決、
 response: '確認 — 元の分析は破損した入力ファイルを使用'"

# 結果: 認証は自動的に失効される
```

### パターン3: 協業前の信頼性評価

別のエージェントの出力に依存する前に:

```
# 内訳付きで信頼スコアを確認
"agent-candidateの信頼スコアを取得して"

# 結果の解釈:
# - score > 0.7: 概ね信頼できる
# - score 0.4-0.7: 中程度の信頼、重要な主張は検証推奨
# - score < 0.4: 低信頼、完全な検証が必要
# - anomaly_flagsあり: 進める前に調査が必要
```

## クレームタイプ

| クレームタイプ | 重み | 使用場面 |
|--------------|------|---------|
| `PIPELINE_EXECUTION` | 1.0 | 再現性検証のためのパイプライン/スキル再実行 |
| `GENOMICS_QC` | 0.8 | ゲノミクスデータ品質管理（GenomicsChain連携） |
| `DATA_INTEGRITY` | 0.7 | チェーン全体のデータ整合性検証 |
| `SKILL_QUALITY` | 0.6 | スキルの動作と出力品質の確認 |
| `L0_COMPLIANCE` | 0.5 | フレームワーク（L0）ルール準拠の検証 |
| `L1_GOVERNANCE` | 0.4 | ガバナンス/知識の正確性検証 |
| `OBSERVATION_CONFIRM` | 0.2 | 観測記録の確認のみ（最低重み） |

重みの高いクレームタイプは信頼スコアの品質コンポーネントにより大きく寄与します。

### 開示レベル

| レベル | 使用場面 |
|--------|---------|
| `existence_only` | デフォルト。エビデンスを開示せず認証の存在を証明。Merkleルート+プルーフパスのみ。 |
| `full` | 検証者が実際のエビデンスデータへのアクセスが必要な場合。 |

## トランスポート概要

Synoptisは3つのトランスポート機構を優先順位に従って使用し、認証メッセージを配信します:

1. **MMP**（Model Meeting Protocol）: KairosChainのミーティングシステム経由のP2P配信。両エージェントがMMP接続済みの場合に使用。
2. **Hestia**: Hestiaエージェントレジストリ経由で発見し、MMP経由で配信。ターゲットがHestiaネットワークに登録されている場合に使用。
3. **Local**: マルチユーザーテナントマネージャー経由のインスタンス内配信。同一KairosChainインスタンス上のエージェント間で使用。

トランスポート優先順位は `config/synoptis.yml` で設定可能:
```yaml
transport:
  priority: [mmp, hestia, local]
```

すべてのトランスポートが失敗した場合、操作自体はローカルで成功しますが（プルーフはレジストリに保存）、配信は失敗として記録されます。

## セキュリティ上の注意事項

1. **自己認証**: デフォルトで無効（`allow_self_attestation: false`）。エージェントは自身を認証できません。
2. **速度制限**: 24時間以内に10件以上の認証は異常フラグと信頼スコアペナルティを発動。
3. **チャレンジ制限**: 各エージェントは同時に最大5件のオープンチャレンジのみ可能。チャレンジ洪水を防止。
4. **署名検証**: すべてのプルーフはRSA-SHA256で署名。認証者の公開鍵なしでは署名検証はスキップされるが`trust_hints`に記録。
5. **エビデンス整合性**: エビデンスはハッシュ化（sha256）され、ハッシュが署名ペイロードに含まれる。署名後のエビデンス改ざんは検出可能。
6. **有効期限**: プルーフはデフォルトで180日後に期限切れ。期限切れプルーフはfullモードで検証失敗。
7. **選択的開示**: `existence_only`モードでは、エビデンスはエンベロープに含まれず、ハッシュとMerkleプルーフのみ。基礎データを明かさずに事実を証明可能。
