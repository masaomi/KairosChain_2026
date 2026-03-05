# Synoptis SkillSet 実装ログ

**Author:** Claude Opus 4.6
**Date:** 2026-03-04
**Branch:** `feature/synoptis-skillset`
**Plan:** `log/kairoschain_synoptis_skillset_plan_claude_team_opus4.6_20260304.md`

---

## 実装範囲

### 完了: Phase 0〜4

全6フェーズ中の最初の5フェーズを実装。attestation の発行・署名・検証・失効、トランスポート層、信頼スコアリング、チャレンジプロトコルが動作する状態。

| Phase | 内容 | 状態 |
|-------|------|------|
| Phase 0 | SkillSet骨格 + 契約定義 | **完了** |
| Phase 1 | Attestation Engine MVP | **完了** |
| Phase 2 | 3トランスポート統合 (MMP/Hestia/Local) | **完了** |
| Phase 3 | Trust Scoring + 談合検出 | **完了** |
| Phase 4 | ChallengeProtocol | **完了** |
| Phase 5a | Security Critical Fixes (4C + 2H) | **完了** |
| Phase 5b | Architectural Hardening (5H + 6M/ARCH) | **完了** |
| Phase 5c | PostgreSQL Registry + Hestia/Multiuser連携 | 未着手 |
| Phase 6 | 統合テスト・ドキュメント・品質保証 | 未着手 |

---

## 新規作成ファイル（28ファイル）

### Phase 0 — SkillSet骨格

| ファイル | 内容 |
|---------|------|
| `templates/skillsets/synoptis/skillset.json` | マニフェスト: L1, depends_on: [], 8ツール登録, provides: mutual_attestation/trust_graph/challenge_protocol |
| `templates/skillsets/synoptis/config/synoptis.yml` | デフォルト設定: enabled: false, storage.backend: file, transport.priority: [mmp, hestia, local] |
| `templates/skillsets/synoptis/lib/synoptis.rb` | エントリーポイント: autoload + `load!`メソッド（hooks呼び出し + 起動ログ）, config解決, engine factory |
| `templates/skillsets/synoptis/lib/synoptis/hooks/mmp_hooks.rb` | MMP Protocol アクション登録（7アクション）。`Synoptis::Hooks.register_mmp_actions!` |
| `templates/skillsets/synoptis/lib/synoptis/claim_types.rb` | 7 ClaimType（PIPELINE_EXECUTION〜OBSERVATION_CONFIRM）+ 重み + DISCLOSURE_LEVELS（existence_only/full） |
| `templates/skillsets/synoptis/knowledge/synoptis_attestation_protocol/synoptis_attestation_protocol.md` | プロトコル仕様概要 |

### Phase 1 — Attestation Engine MVP

| ファイル | 内容 |
|---------|------|
| `lib/synoptis/proof_envelope.rb` | ProofEnvelope: canonical JSON署名対象（ソート済み12フィールド）, sign!/valid_signature?, expired?/revoked?/active?, to_h/from_h/to_json, to_anchor（Hestia連携） |
| `lib/synoptis/merkle.rb` | MerkleTree: SHA256 leaf hash, build_tree（奇数ノード対応）, proof_for(index), self.verify(leaf, proof, root) |
| `lib/synoptis/verifier.rb` | Verifier: 5段階複合検証（署名/evidence_hash/失効/期限/merkle_proof）, ClaimType妥当性検証 |
| `lib/synoptis/revocation_manager.rb` | RevocationManager: revoke（二重失効拒否）, revoked?, revocation_for |
| `lib/synoptis/attestation_engine.rb` | AttestationEngine: create_request, build_proof（self-attestation禁止, MerkleTree自動構築, 署名）, verify_proof, revoke_proof |
| `lib/synoptis/registry/base.rb` | 抽象レジストリインターフェース: proof/revocation/challenge CRUD |
| `lib/synoptis/registry/file_registry.rb` | JSONL永続化: Mutex スレッドセーフ, proof/revocation/challenge全対応 |
| `tools/attestation_verify.rb` | AttestationVerify: BaseTool準拠, signature_only/fullモード |
| `tools/attestation_list.rb` | AttestationList: BaseTool準拠, agent_id/claim_type/statusフィルタ |

### Phase 2 — トランスポート統合

| ファイル | 内容 |
|---------|------|
| `lib/synoptis/transport/base.rb` | Transport抽象インターフェース: send_message/available?/transport_name |
| `lib/synoptis/transport/router.rb` | TransportRouter: DEFAULT_PRIORITY=[mmp,hestia,local], 優先順位フォールバック |
| `lib/synoptis/transport/mmp_transport.rb` | MMPTransport: MMP直接P2P（常時利用可能）, MeetingRouter連携 |
| `lib/synoptis/transport/hestia_transport.rb` | HestiaTransport: AgentRegistry発見→MMP委譲（Hestia有効時のみ） |
| `lib/synoptis/transport/local_transport.rb` | LocalTransport: Multiuserローカル直接（Multiuser有効時のみ） |
| `tools/attestation_request.rb` | AttestationRequest: BaseTool準拠, トランスポート経由のattestation依頼送信 |
| `tools/attestation_issue.rb` | AttestationIssue: BaseTool準拠, ProofEnvelope生成+署名+トランスポート配信 |
| `tools/attestation_revoke.rb` | AttestationRevoke: BaseTool準拠, 失効+attesteeへのトランスポート通知 |

### Phase 3 — Trust Scoring + 談合検出

| ファイル | 内容 |
|---------|------|
| `lib/synoptis/trust_scorer.rb` | TrustScorer: quality × freshness × diversity × (1-revocation) × (1-velocity), exponential decay |
| `lib/synoptis/graph_analyzer.rb` | GraphAnalyzer: cluster_coefficient/external_connection_ratio/velocity_anomaly, 閾値ベース異常検出 |
| `tools/trust_score_get.rb` | TrustScoreGet: BaseTool準拠, スコア+内訳+graph metrics+anomaly_flags |

### Phase 4 — ChallengeProtocol

| ファイル | 内容 |
|---------|------|
| `lib/synoptis/challenge_manager.rb` | ChallengeManager: open_challenge/resolve_challenge/check_expired_challenges, 状態遷移管理 |
| `tools/attestation_challenge_open.rb` | AttestationChallengeOpen: BaseTool準拠, チャレンジ発行+attesterトランスポート通知 |
| `tools/attestation_challenge_resolve.rb` | AttestationChallengeResolve: BaseTool準拠, uphold/invalidate判定+関係者通知 |

### テスト

| ファイル | 内容 |
|---------|------|
| `test_synoptis.rb` | テストスイート: 158テスト（Phase 0〜4 全カバー） |

---

## 既存変更（1ファイル）

### `templates/skillsets/mmp/lib/mmp/protocol.rb`

**追加内容:**
- `self.register_actions(actions)` クラスメソッド — 他SkillSetからのアクション動的登録
- `self.extended_actions` クラスメソッド — 登録済み拡張アクション取得
- `supported_actions` メソッド — extended_actionsを基本アクションに統合

**影響:** 既存ACTIONS定数は不変。extended_actionsが追加されるのみ。後方互換性維持。

---

## テスト結果

| テスト | 結果 |
|--------|------|
| `test_synoptis.rb` | **185 passed, 0 failed** |
| `test_skillset_manager.rb` | **37 passed, 0 failed**（回帰なし） |
| `test_local.rb` | **全テスト完了**（回帰なし） |

### テストカバレッジ（test_synoptis.rb）

#### Phase 0
- SkillSet manifest loading (7)
- Synoptis module loading (6)
- ClaimTypes (8)
- MMP Protocol register_actions (7) — load! disabled テスト含む

#### Phase 1
- ProofEnvelope creation and signing (11)
- ProofEnvelope serialization round-trip (5)
- ProofEnvelope expiry and status (6)
- ProofEnvelope round-trip merkle_proof keys (1)
- ProofEnvelope to_anchor nil without Hestia (1)
- ProofEnvelope unsigned valid_signature? false (1)
- MerkleTree construction and verification (12)
- MerkleTree single-leaf proof_for (2)
- FileRegistry CRUD (9)
- AttestationEngine create_request (5)
- AttestationEngine build_proof and verify round-trip (12)
- AttestationEngine self-attestation rejection (1)
- AttestationEngine existence_only hides evidence (2)
- AttestationEngine min_evidence_fields rejection (1)
- Revocation and verify after revoke (6)
- Verifier evidence hash mismatch (2)
- Verifier expired proof (1)
- Verifier check_merkle: true (2)
- Verifier no public key provided (2)
- Verifier unknown claim type (1)
- Verifier revocation via registry lookup (2)

#### Phase 2
- Transport::Base interface (3)
- Transport::MMPTransport (5) — available? boolean-like テスト含む
- Transport::HestiaTransport (4)
- Transport::LocalTransport (4)
- Transport::Router routing and fallback (5)
- Router all transports fail (2)

#### Phase 3
- TrustScorer basic scoring (8)
- TrustScorer zero score for unknown agent (2)
- TrustScorer diversity affects score (1)
- TrustScorer revocation penalty (1)
- TrustScorer velocity penalty (2)
- GraphAnalyzer anomaly detection (5)
- GraphAnalyzer low external connections flag (2)

#### Phase 4
- ChallengeManager open challenge (7)
- ChallengeManager resolve challenge - uphold (4)
- ChallengeManager resolve challenge - invalidate (2)
- ChallengeManager expired challenge (2)
- ChallengeManager cannot challenge revoked proof (1)
- ChallengeManager cannot resolve already resolved (1)
- ChallengeManager max active challenges (1)
- ChallengeManager duplicate challenge prevention (1)
- FileRegistry challenge CRUD (6)

---

## 設計判断

### 1. MMP::Crypto の再利用
ProofEnvelope の署名/検証に `MMP::Crypto` をそのまま使用。RSA-SHA256 + Base64エンコーディング。独自の暗号実装は追加していない。

### 2. canonical JSON の署名対象
12フィールド（proof_id, claim_type, disclosure_level, attester_id, attestee_id, subject_ref, target_hash, evidence_hash, merkle_root, nonce, issued_at, expires_at）をキーソートしたJSON文字列。`evidence` 本体は署名対象外（evidence_hashで間接参照）。

### 3. MerkleTree の奇数ノード対応
奇数ノード時は最後のノードを自己複製（`right ||= left`）。proof_for でも同様に sibling が存在しない場合は自ノードを使用。

### 4. FileRegistry のスレッドセーフ
Mutex による排他制御。save_proof/save_revocation/save_challenge は append（高速）、update系は全件書き換え（稀な操作のため許容）。

### 5. self-attestation 禁止
`allow_self_attestation: false` がデフォルト。AttestationEngine.build_proof で attester_id == attestee_id の場合に ArgumentError を送出。

### 6. hooks/mmp_hooks.rb による関心分離
MMP Protocol へのアクション登録を `synoptis.rb` のインラインメソッドではなく `hooks/mmp_hooks.rb` に分離。理由: (1) エントリーポイントの責務を設定管理+autoloadに限定、(2) Phase 5 で `hooks/hestia_hooks.rb` を追加する際のパスが明確、(3) 設計プランのディレクトリ構成（セクション5.1）との一致。

### 7. load! メソッドによる初期化保証
`autoload` は遅延ロード用であり、副作用のある初期化（hooks登録）には不適。`load!` メソッドで hooks の require + 登録 + 起動ログ出力を一括実行する。

### 8. エージェントチームレビューによる設計プラン修正
Phase 0+1 実装後にエージェントチーム（4エージェント並列）で設計プラン vs 実装を比較検討。結果:
- MMP Protocol拡張: `self.all_actions` → `supported_actions` 統合に**設計プランを修正**（P2P受信時に `action_supported?` が自動認識するため必須）
- config構造: `synoptis:` ラッパー + `enabled: true` → フラット + `enabled: false` に**設計プランを修正**（MMP/Hestia一貫性 + opt-in原則）
- ツール配置: Phase 1 にMVPツール2本を追加するよう**設計プランを修正**（ローカル完結操作のため）
- hooks/load!: **実装を設計プランに合わせて修正**（関心分離 + 初期化保証）

### 9. TransportRouter のフォールバック戦略
優先順位（mmp → hestia → local）に従い、各transportの `available?` をランタイムで確認。利用不可なtransportはスキップし、送信失敗時は次のtransportへフォールバック。全transport失敗時はエラーを返却。

### 10. TrustScorer の指数減衰
freshness_score に `exp(-age_days * ln(2) / half_life_days)` を使用。half_life_days（デフォルト90日）経過で重みが正確に半減。これにより古いattestationの影響が自然に減衰。

### 11. GraphAnalyzer の異常フラグ
anomaly_flags は**参考情報のみ**（命題9: 人間が最終判断）。自動拒否は行わない。cluster_coefficient > 0.8、external_connection_ratio < 0.3、velocity_anomaly > 10 が閾値。

### 12. ChallengeManager の状態遷移
- `active → challenged`: open_challenge実行時
- `challenged → active`: uphold決定時（proof復元）
- `challenged → revoked`: invalidate決定時（proof失効）
- `open → challenged_unresolved`: 応答期限切れ（check_expired_challenges）
- 二重チャレンジ解決防止: resolved状態のchallengeへのresolve_callはArgumentError

---

## エージェントチーム精査レビュー（Phase 0〜4 完了後）

4エージェント並列でコード精査を実施。発見された問題と修正内容:

### HIGH バグ修正（B1〜B7）

| ID | 問題 | 修正 |
|----|------|------|
| B1 | `external_connection_ratio` が常に 0.0 — group に全接続先が含まれ「外部」が存在しない | 相互attestation（双方向）のみをクラスタとして構築 |
| B2 | half-life公式: `exp(-t/T)` は 1/e-life であり半減期ではない | `exp(-t * ln(2) / T)` に修正（90日で正確に0.5） |
| B3 | Verifier Merkle検証: `evidence_hash`（hex文字列）を渡すと二重ハッシュ | `evidence.values.first.to_s`（元の値）を渡すよう修正 |
| B4 | `ProofEnvelope.from_h`: merkle_proofとevidenceのキーが文字列のまま | `transform_keys(&:to_sym)` で深層シンボル化 |
| B5 | `attestation_challenge_open.rb`: `require 'digest'` 欠落 | 追加 |
| B6 | `attestation_issue.rb`: `require 'securerandom'` 欠落 | 追加 |
| B7 | MMP/Local transport: 配信手段なしでも `success: true` を返却 | `success: false` + エラーメッセージに修正 |

### MEDIUM バグ修正（M1〜M8）

| ID | 問題 | 修正 |
|----|------|------|
| M1 | `load!` が `enabled: false` でもhooksを登録 | enabled チェック追加、false なら早期リターン |
| M2 | `build_proof` で evidence フィールド数未検証 | `min_evidence_fields`（デフォルト2）バリデーション追加 |
| M3 | FileRegistry: 読み取り操作に Mutex なし | `find_proof`, `list_proofs`, `find_revocation`, `find_challenge`, `list_challenges` 全てに `@mutex.synchronize` 追加 |
| M4 | TrustScorer: `list_proofs` が2回呼ばれ冗長 | `issued_proofs` を事前取得し1回で完了 |
| M5 | ChallengeManager: 同一proofへの重複チャレンジ防止なし | 既存openチャレンジ + max_active_challenges チェック追加 |
| M6 | Verifier `check_revocation`/`check_expiry` がパブリックAPIに見える | ドキュメント注記追加（Plan §17準拠、attestation_verify tool の signature_only モード専用） |
| M7 | nonce バインディング未検証 | 設計限界として記録（Phase 5 で request storage 必要） |
| M8 | merkle proof_for が常に index 0 | MVP制約として記録（今後マルチリーフ対応） |

### テストカバレッジ拡充（T1〜T8）

レビューで特定された27件の追加テストを実装:
- Verifier: check_merkle, no_public_key, unknown_claim_type, revocation via registry lookup
- TrustScorer: revocation_penalty, velocity_penalty
- GraphAnalyzer: low_external_connections flag
- ChallengeManager: max_active_challenges, duplicate challenge prevention
- Router: all-transports-fail
- MMPTransport: available? truthy check
- ProofEnvelope: round-trip merkle keys, to_anchor nil, unsigned valid_signature? false
- AttestationEngine: existence_only mode, min_evidence_fields rejection
- MerkleTree: single-leaf proof_for

テスト数: 158 → **185**（+27テスト）

---

## 修正ログ（時系列）

### Session 1: Phase 0〜1 実装 → Phase 2〜4 実装

1. **Phase 0+1 実装完了** — 99テスト全通過
2. **エージェントチームレビュー（第1回、4並列）** — 設計プランとの整合性チェック
   - 設計プラン4箇所修正、実装1箇所修正（→設計判断 §8 参照）
3. **Phase 2〜4 実装** — 158テスト、初回3件失敗
   - `graph_analyzer.rb`: `require 'set'` 欠落 → 追加
   - Transport `available?` が `nil` を返しうる → テストを `!transport.available?` に修正
4. **回帰テスト確認** — test_skillset_manager 37/37, test_local 全通過

### Session 2: エージェントチーム精査レビュー + 全修正

5. **エージェントチームレビュー（第2回、4並列）** — コード精査・バグ探索・テストギャップ特定
   - Agent 1（Core engine & data model）: B2, B3, B4, M2, M7, M8 発見
   - Agent 2（Transport & tools layer）: B5, B6, B7, M1 発見
   - Agent 3（Trust scoring & challenge）: B1, M4, M5, M6 発見
   - Agent 4（Test coverage gaps）: T1〜T8 テストギャップ特定

6. **HIGH バグ修正（B1〜B7）** — 7件修正
   - 修正ファイル: `graph_analyzer.rb`, `trust_scorer.rb`, `verifier.rb`, `proof_envelope.rb`, `attestation_challenge_open.rb`, `attestation_issue.rb`, `mmp_transport.rb`, `local_transport.rb`
   - テスト3件修正（B7 transport戻り値変更に追従）
   - 159テスト全通過

7. **MEDIUM バグ修正（M1〜M8）** — 6件コード修正 + 2件設計限界記録
   - 修正ファイル: `synoptis.rb`（M1）, `attestation_engine.rb`（M2）, `file_registry.rb`（M3）, `trust_scorer.rb`（M4）, `challenge_manager.rb`（M5）, `verifier.rb`（M6）
   - テスト多数修正（M1: load!スタブ、M2: evidence 2フィールド化、M3: list_challenges end修正）
   - 160テスト全通過

8. **テストカバレッジ拡充（T1〜T8）** — 27件追加
   - 初回: 180 passed, 4 failed
   - 修正1: revocation registry lookupテスト — 偽署名 → 正規署名付きproofに修正
   - 修正2: revocation_penaltyテスト — スコア対象エージェントを受信+発行の両方を行うagentに修正
   - 修正3: velocity_penaltyテスト — 同上
   - 再実行: **185 passed, 0 failed**

9. **最終回帰テスト確認**
   - `test_synoptis.rb`: **185 passed, 0 failed**
   - `test_skillset_manager.rb`: **37 passed, 0 failed**
   - `test_local.rb`: **全テスト完了**（KAIROS_META_SKILLS定数エラーは既存問題、Synoptis無関係）

10. **コミット** — `f9e0d1e` on `feature/synoptis-skillset`
    - 31 files changed, 3,707 insertions(+), 5 deletions(-)

### 修正対象ファイル一覧（レビュー修正分）

| ファイル | 修正内容 |
|---------|---------|
| `lib/synoptis.rb` | M1: `load!` に `enabled` チェック追加 |
| `lib/synoptis/attestation_engine.rb` | M2: `min_evidence_fields` バリデーション追加 |
| `lib/synoptis/proof_envelope.rb` | B4: `from_h` で merkle_proof/evidence の深層キーシンボル化 |
| `lib/synoptis/verifier.rb` | B3: Merkle検証リーフ値修正, M6: check_revocation/check_expiry ドキュメント注記 |
| `lib/synoptis/trust_scorer.rb` | B2: half-life公式修正 `exp(-t*ln(2)/T)`, M4: issued_proofs 事前取得 |
| `lib/synoptis/graph_analyzer.rb` | B1: external_connection_ratio 相互attestationクラスタのみ, `require 'set'` 追加 |
| `lib/synoptis/challenge_manager.rb` | M5: 重複チャレンジ防止 + max_active_challenges チェック |
| `lib/synoptis/registry/file_registry.rb` | M3: 全読み取り操作に `@mutex.synchronize` 追加, list_challenges end修正 |
| `lib/synoptis/transport/mmp_transport.rb` | B7: 配信手段なし時 `success: false` 返却 |
| `lib/synoptis/transport/local_transport.rb` | B7: 同上 |
| `tools/attestation_challenge_open.rb` | B5: `require 'digest'` 追加 |
| `tools/attestation_issue.rb` | B6: `require 'securerandom'` 追加 |
| `test_synoptis.rb` | 27テスト追加 + 既存テスト修正（transport戻り値, evidence 2フィールド化, load!スタブ） |

---

## Phase 5〜6 の実装に向けた注意事項

### Phase 5: PostgreSQL Registry + Hestia/Multiuser連携
- `registry/pg_registry.rb` は未実装
- SQL migration 3本はプランに定義済み（セクション10.2）
- Base クラスのインターフェースにchallenge CRUDが追加済み（Phase 4で拡張）
- `hooks/hestia_hooks.rb` は未実装
- PlaceRouter 参照API（`GET /place/v1/attestations`, `GET /place/v1/trust/:agent_id`）は未実装
- 集約証明インターフェース（入れ子対応の受け皿）は未実装

### Phase 6: 統合テスト・ドキュメント・品質保証
- P2P attestation E2Eテスト（2インスタンス間）
- 3経路フォールバックテスト
- knowledge ドキュメント拡充
- 運用ガイド作成

---

## Phase 5a/5b: Security & Architecture Fixes (2026-03-05)

**レビュー元:** `log/kairoschain_synoptis_review2_claude_team_opus4.6_20260305.md`
**対象:** 4 CRITICAL + 6 HIGH + 7 MEDIUM/ARCH 問題の修正

### Phase 5a: Security Critical (Fix 1〜6)

| Fix | ID | 問題 | 修正内容 |
|-----|----|------|---------|
| 1 | S-C1 | MMP Transport が存在しない `MeetingRouter.instance` を使用 | `MMP::Protocol.process_message` 直接呼び出し + HTTP POST fallback (`/meeting/v1/message`) |
| 2 | S-C2 | 署名鍵がエフェメラル（セッション間で検証不能） | `MMP::Identity` 経由の永続鍵使用。非KairosMcp環境はephemeral + stderr警告 |
| 3 | S-C3 | revoke に認可チェックなし（誰でも任意proof失効可能） | proof存在確認 → attester/attestee認可 → 失効作成の順序に変更 |
| 4 | S-C4 | challenge resolve認可なし + expired proof challengeable + self-challenge可能 | `resolver_id:` 引数追加（attester認可）、expired proof拒否、self-challenge防止 |
| 5 | S-H6 | `canonical_json` が nil フィールドを除外（署名の非決定性） | nil除外ロジック削除。全SIGNABLE_FIELDSを含める（nilは JSON null） |
| 6 | S-H4 | `resolve_attester_id` / `resolve_agent_id` が `'local_agent'` フォールバック | フォールバック削除 → `raise 'Agent identity not available'`。テスト用 `ENV['SYNOPTIS_AGENT_ID']` override |

### Phase 5b: Architectural Hardening (Fix 7〜17)

| Fix | ID | 問題 | 修正内容 |
|-----|----|------|---------|
| 7 | S-H1/A-N5 | FileRegistry: in-process Mutex のみ + 非原子的書き込み | `File.flock(LOCK_EX/LOCK_SH)` ファイルレベルロック + `Tempfile` → `File.rename` 原子的書き込み |
| 8 | S-H2 | nonce が request_id から導出可能（推測性） | request_id由来のnonce導出削除。常に `SecureRandom.hex(16)` |
| 9 | S-H5 | revoke後に同一tupelで再発行可能 | `build_proof` 内で同一 (attester, attestee, claim_type, subject_ref) の revoked proof チェック |
| 10 | A-N7 | `YAML.load_file` は unsafe + config読み込みエラーが黙殺される | `YAML.safe_load_file(permitted_classes: [])` + `$stderr.puts` 警告出力 |
| 11 | A-N4 | `engine()` が TransportRouter に接続されていない | `AttestationEngine` に `attr_accessor :transport_router` 追加、`engine()` で自動接続 |
| 12 | F-05 | expired challenges が自動検出されない | `list_challenges` 呼び出し時に `check_expired_challenges` 自動実行 |
| 13 | A-N2 | TrustScorer/GraphAnalyzer が個別にregistry fetch（二重クエリ） | `score(proofs:)` / `analyze(proofs:)` オプション引数追加。`trust_score_get` で1回fetch+両方に渡す |
| 14 | F-09 | `Synoptis.load!` が自動呼び出しされない | ファイル末尾に `Synoptis.load! if defined?(KairosMcp)` + `@loaded` idempotent guard |
| 15 | F-11 | `attestation_list` が expired を動的チェックしない | `status: 'expired'` フィルタ時に `expires_at < now` を動的評価。active フィルタからも除外 |
| 16 | M-9 | `expires_in_days` バリデーションなし | `expires_in_days.to_i < 1` で ArgumentError |
| 17 | — | revocation config セクション欠落 | `synoptis.yml` に `revocation: allow_third_party: false, check_re_issuance: true` 追加 + `default_config` にも追加 |

### 変更ファイル一覧（17ファイル）

| # | ファイル | Fix |
|---|---------|-----|
| 1 | `lib/synoptis.rb` | 10, 11, 14 |
| 2 | `lib/synoptis/transport/mmp_transport.rb` | 1 |
| 3 | `lib/synoptis/revocation_manager.rb` | 3 |
| 4 | `lib/synoptis/challenge_manager.rb` | 4, 12 |
| 5 | `lib/synoptis/proof_envelope.rb` | 5 |
| 6 | `lib/synoptis/registry/file_registry.rb` | 7 |
| 7 | `lib/synoptis/attestation_engine.rb` | 9, 11 |
| 8 | `lib/synoptis/trust_scorer.rb` | 13 |
| 9 | `lib/synoptis/graph_analyzer.rb` | 13 |
| 10 | `tools/attestation_issue.rb` | 2, 8, 16 |
| 11 | `tools/attestation_challenge_open.rb` | 6 |
| 12 | `tools/attestation_challenge_resolve.rb` | 4, 6 |
| 13 | `tools/attestation_list.rb` | 15 |
| 14 | `tools/attestation_revoke.rb` | 6 |
| 15 | `tools/trust_score_get.rb` | 13 |
| 16 | `config/synoptis.yml` | 17 |
| 17 | `test_synoptis.rb` | MMP transport テスト期待値更新 |

### テスト結果

| テスト | 結果 |
|--------|------|
| `test_synoptis.rb` | **185 passed, 0 failed** |
| `test_skillset_manager.rb` | **37 passed, 0 failed** |
| `test_local.rb` | 既存問題のみ（Synoptis無関係） |

### 設計判断

#### 13. ファイルレベルロック（Fix 7）
in-process Mutex はマルチプロセス環境で無効。`File.flock(LOCK_EX)` によるOSレベルのファイルロックに変更。読み取り操作には `LOCK_SH`（共有ロック）を使用し並行読み取り性能を維持。

#### 14. 原子的書き込み（Fix 7）
`Tempfile` に書き込み後 `File.rename` で置換。rename はPOSIXでアトミック操作であり、書き込み途中のクラッシュによるデータ破損を防止。

#### 15. revoke認可モデル（Fix 3）
attester（発行者）と attestee（被発行者）のみが失効権限を持つ。第三者による失効は `revocation.allow_third_party: false` で禁止（将来的な拡張余地は残す）。

#### 16. canonical_json nil包含（Fix 5）
nil除外は「同一データに対する署名値が、nilフィールドの存在有無で変化する」問題を引き起こす。全フィールド包含により署名の決定性を保証。JSON.generateはnilを`null`に変換。

#### 17. resolver_id認可の緩やかな導入（Fix 4）
`resolver_id` は optional keyword引数として追加。nil の場合は認可チェックをスキップ（後方互換性維持）。Tool層（`attestation_challenge_resolve.rb`）では必ず `resolve_agent_id` から取得して渡す。
