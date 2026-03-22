# Review: Service Grant Bugfixes

- **Reviewer**: Cursor Composer
- **Model**: Composer (Cursor agent)
- **Date**: 2026-03-22
- **Mode**: auto

## Verdict: APPROVE

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| AccessGate owner bypass | PASS | `user_ctx[:role] == 'owner'` は `TokenStore#verify` が返すサーバー側コンテキストのみを参照。クライアントが任意に `role` を注入できない。`local_dev` と並ぶ早期 return で、`service_grant.rb` の `register_admin_policy!`（`can_manage_grants`: HTTP では owner のみ）と設計が揃う。 |
| record_with_retry kwargs | PASS | Ruby 3 系で「第一引数の Hash」と「メソッドへの keyword arguments」を混同しないよう明示的 Hash 化は正しい。`record_with_retry` の呼び出しは当該ファイル内のみ。 |

## New Findings (if any)

### [LOW] Documentation nuance (PlaceMiddleware vs ensure_grant)
- **File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/place_middleware.rb`（レビュープロンプトの文脈説明）
- **Description**: Place 側は `PlaceMiddleware#check` が `AccessChecker#check_access` を呼び、`AccessChecker` が `ensure_grant` を実行する。ミドルウェアが直接 `ensure_grant` を呼ぶわけではないが、因果関係としては正しい。
- **Recommendation**: ドキュメントや PR 説明で「middleware → check_access → ensure_grant」と書くと誤解が減る（コード変更は不要）。

### [LOW] Owner バイパスの意図の再確認（運用）
- **File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/access_gate.rb:25`
- **Description**: owner トークンは Service Grant のゲート全体をスキップするため、プラン／クォータに紐づく「サービス利用」系ツールも owner では無制限に見える。設計意図（管理者はサービス消費者ではない）と一致するが、運用で member/guest を広く配布し owner を絞る前提が明確だとよい。
- **Recommendation**: 必要なら README や運用メモに「HTTP の owner は管理用」と一行だけ追記（任意）。

## Summary

両修正は最小限で、問題の原因と一致している。`role` は認証済みトークンからサーバーが組み立てる値であり、owner バイパスによるクライアント側の権限昇格リスクは設計上想定内である。`record_with_retry` の呼び出しは `GrantManager` 内に限定され、同種の kwargs バグの重複はリポジトリ上見つからなかった。マージしてよい。
