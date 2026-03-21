---
description: Service Grant SkillSet — KairosChainサービス向け汎用アクセス制御・使用量追跡・課金
tags: [documentation, readme, service-grant, access-control, billing, payment, subscription]
readme_order: 4.9
readme_lang: jp
---

# Service Grant SkillSet

Service Grantは、KairosChainベースのあらゆるサービスに対する**汎用的かつサービス非依存のアクセス制御・課金**を提供します。認証済みエージェントに対して「何が許可されているか」を管理し、アイデンティティ管理は行いません（アイデンティティ = MMP経由のRSA鍵ペア）。

## 主要概念

- **pubkey_hash**: エージェントの公開鍵のSHA-256ハッシュ — これがアイデンティティ
- **Grant**: (pubkey_hash, service)ごとのエントリ（プラン、ステータス、使用量）
- **Plan**: YAML定義のクォータ/課金設定（free, pro等）
- **デュアルパス適用**: `/mcp`（AccessGate）と `/place/*`（PlaceMiddleware）の両方をゲート

## アーキテクチャ

```
パスA (/mcp):   Token -> pubkey_hash -> AccessGate -> AccessChecker
パスB (/place): Bearer -> peer_id -> PlaceMiddleware -> AccessChecker

AccessCheckerパイプライン:
  停止確認 -> クールダウン -> 有効期限 -> 信頼スコア -> クォータ
```

### コンポーネント

| コンポーネント | 責務 |
|--------------|------|
| **GrantManager** | Grant ライフサイクル（作成、アップグレード、停止、ダウングレード） |
| **AccessChecker** | 統合アクセス判定パイプライン |
| **UsageTracker** | サイクル管理付きアトミッククォータ消費 |
| **PlanRegistry** | バリデーション付きYAML設定ローダー |
| **PaymentVerifier** | 暗号学的支払い証明の検証 |
| **PgConnectionPool** | サーキットブレーカー付きスレッドセーフPostgreSQL |
| **TrustScorerAdapter** | キャッシュ付きSynoptis信頼スコア統合 |

## 課金モデル

```yaml
billing_model: free          # 無料
billing_model: per_action    # APIコール単位課金
billing_model: metered       # 使用量ベース（サイクル内追跡）
billing_model: subscription  # 期間ベース（自動期限管理）
```

## 支払いフロー（証明中心設計）

```
Payment Agent（外部）が証明（attestation proof）を作成
  -> PaymentVerifierが検証: 署名、発行者、鮮度、金額、ノンス
  -> アトミックトランザクション: ensure_grant + upgrade_plan + record_payment
  -> サブスクリプション期限は自動管理（アクセス時の遅延ダウングレード）
```

支払い検証にはSynoptis ProofEnvelope — 信頼スコアリングと同じ暗号学的証明インフラ — を使用します。

## アンチシビル対策

- IP レート制限（IP あたり 5 新規 Grant/時間、PostgreSQL バック）
- 遅延アクティベーションクールダウン（書き込み操作に5分）
- Synoptis 信頼スコア要件（アクション単位で設定可能）
- 外部証明重み付けのアンチ共謀 PageRank

## MCPツール

| ツール | アクセス | 説明 |
|-------|---------|------|
| `service_grant_status` | 全ユーザー | Grant と使用状況の表示 |
| `service_grant_manage` | オーナーのみ | プラン変更、停止/再開 |
| `service_grant_migrate` | オーナーのみ | データベーススキーマ移行 |
| `service_grant_pay` | 全ユーザー | 支払い証明の提出 |

## 設定例

```yaml
services:
  meeting_place:
    billing_model: per_action
    currency: USD
    cycle: monthly
    write_actions: [deposit_skill]
    action_map:
      meeting_deposit: deposit_skill
      meeting_browse: browse
    plans:
      free:
        limits:
          deposit_skill: 5
          browse: -1  # 無制限
        trust_requirements:
          deposit_skill: 0.1
      pro:
        subscription_price: "9.99"
        subscription_duration: 30  # 日
        limits:
          deposit_skill: -1
          browse: -1
```

## 依存関係

- **必須**: PostgreSQL（Grant、使用量、支払い記録）
- **必須**: Synoptis SkillSet（証明検証、信頼スコアリング）
- **任意**: Hestia SkillSet（Meeting Place ミドルウェア統合）
