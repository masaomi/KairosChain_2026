# 実装レビュー仕様（事前宣言）— 無署名 proof の修正 C-1 / C-2

- 日付: 2026-07-31
- 状態: DECLARED（投函前に宣言。投函後は変更しない）
- 根拠: L1 `loop_validation` v0.4（事前宣言 spec → fail-closed 判定）
- 経緯: 設計ループ R1〜R4 が頭打ちになった際、レビュアー 3 者が独立に「提出経路の proof 封筒は署名されていない」を発見。orchestrator が実物を動かして再現し、設計ではなく実装の修正へ移行した。裁定 C（名乗る鍵と署名する鍵を揃える）を masaomi が選択

---

## 1. レビュー対象（出荷物）— これだけが P0/P1 の的

| ファイル | sha256 | 変更 |
|---|---|---|
| `KairosChain_2026/KairosChain_mcp_server/templates/skillsets/synoptis/lib/synoptis/proof_envelope.rb` | `86bd8e53…3e5d1d11` | `submitter_pubkey` を新設。正準形の欄の集合を**版**が選ぶ（`1.0.0` は従来どおり／`1.1.0` が新欄を持つ）。署名の外に置こうとしたら `ArgumentError` |
| 同 `attestation_engine.rb` | `c2405d5d…d242f0a5` | `create_attestation` が `submitter_pubkey:` を受けて封筒へ渡す |
| `GenomicsChain_MVP2_2026/.kairos/skillsets/genomicschain_core/lib/genomicschain_core/attestation/synoptis_attestor.rb` | `af3fee0c…e7e52b769a` | `attester_id` を anchor 自身の MMP `instance_id` へ。`crypto:` を渡す。鍵か身元が無ければ記録せず raise |
| 同 `test/synoptis_attestor_signing_test.rb` | `25fe155b…7cfb1d04d02` | 新規 10 本。本物の attestor → engine → `sign!` → Verifier を駆動 |

**配布**: 正本は templates。`KairosChain_2026/.kairos/skillsets/synoptis/` と `GenomicsChain_MVP2_2026/.kairos/skillsets/synoptis/` へ同期済み（3 か所同一を確認）。`KairosChain_mcp_server/.kairos/` は既知の副産物ディレクトリなので**意図的に同期していない**。

---

## 2. 各修正が新しく主張すること

### C-1 — anchor が自分の名義で attest し、自分の鍵で署名する

**新しく主張すること**:

- 出荷設定（`synoptis.yml` の `require_signature: true`）の下で、提出経路が記録する封筒は**署名を持ち、`Verifier` が緑を返す**
- `attester_id` は anchor の MMP `instance_id`。これは `Synoptis::ToolHelpers#resolve_agent_id` が `attestation_revoke` に渡す `revoker_id` と**同じ値**なので、記録した anchor がその proof を失効できる
- 提出者の ed25519 公開鍵は attester ではない。**別の欄で運ぶ**（C-2）
- 鍵または身元が解決できないとき、`issue` は raise し、**registry に何も残らない**。従来は署名なしで記録に成功していた
- 重複検出の鍵 `(attester_id, subject_ref, claim)` のうち `claim` は content hash と submission key を含むので、**別々の執行者が同じ論文を評価しても衝突しない**

### C-2 — 提出者を署名対象の正準形へ

**新しく主張すること**:

- `submitter_pubkey` は正準形の欄なので、**運搬中に書き換えると署名が壊れる**
- 正準形の欄の集合は**版が選ぶ**。版 `1.0.0` の封筒の正準形は 1 バイトも変わらない → **既存の署名は無効化されない**
- `submitter_pubkey` を渡しながら版が `1.0.0` のときは `ArgumentError`。署名の外に値を置く経路は存在しない
- `create_attestation` の他の呼び手 4 か所（`attestation_issue` / `pm_record` / `hestia/skill_auditor` / `chain_distillation/carrier_wiring`）は新欄を渡さないので、**振る舞いは変わらない**

---

## 3. 的にしない（付録）— (c) 相当。判定を動かさない

- **`mmp` SkillSet が GenomicsChain instance に無い件**。これは deployment の前提であってコードの欠陥ではない。§5 に測定を記す。masaomi の裁定待ち
- 廃止された monolith `genomicschain` SkillSet（`config.yml` で disabled）の自前 attestor
- 既存の失敗: `topology_test.rb` 3 件（道具登録・monolith 設定）、`service_grant` 1 件（`MockGrantManager#cooldown` 欠落）。いずれも本変更と無関係
- `KairosChain_mcp_server/.kairos/` の 4 つ目の写しとの差分
- 設計文書 v0.6 の残る指摘（追記中断・TTL・token_manage）。別の作業
- 命名・文体・行の並べ方

---

## 4. 合格条件（fail-closed。すべて満たすこと）

1. §1 の出荷物に対する (a) 指摘（仕様違反・実行時欠陥・データ破損・並行性・後方互換の破壊）がゼロ
2. §2 の「新しく主張すること」がいずれも反証されない
3. 既存の署名済み封筒が無効化されないこと（版 `1.0.0` の正準形不変）が反証されない
4. fail-closed が本物であること — 拒否したときに registry に何も残らない、が反証されない

破られれば REVISE / REJECT。

**閉じ方**: 閾値 3/4 APPROVE、**または** (a)+(b) の消尽を masaomi が確認して freeze 宣言。

---

## 5. 実施記録（測定値）

- **赤→緑**: 新テスト 10 本 / 37 assertions 緑。**変異で弁別を確認** — `crypto: @crypto` を `nil` に置換 → 3 失敗。正準形から `canonical[:submitter_pubkey]` の行を落とす → 2 失敗。どちらも正本から復元して緑に復帰
- **影響範囲**: synoptis 自身のテスト **88 passed / 0 failed**（templates 側・instance 側の両方）。`genomicschain_core` の他のテスト（`b1_manifest_hash` 3 / `tier1_submit` 16 / `tier2_submit` 14 / `tip_source` 5）すべて緑
- **既存テストが本物を呼んでいなかった**: `tier1_submit_test.rb` と `tier2_submit_test.rb` は `StubAttestor` を使い、本物の `SynoptisAttestor` を一度も呼んでいない。この欠陥が生き延びた理由
- **修正前の実測**（orchestrator が出荷設定で実物を駆動）: `create_attestation` は `status: created` を返し、`envelope.signature` は `nil`、`verify_attestation` は `{"valid": false, "errors": ["missing_signature"]}`
- **deployment の測定（的にしない、記録のみ）**: `GenomicsChain_MVP2_2026/.kairos/skillsets/` に `mmp` ディレクトリが無く、`config.yml` にも列挙が無い。MMP は core ではなく SkillSet（`KairosChain_mcp_server/lib/` に MMP 無し）。したがってその instance では `MMP::Identity` が定義されず、C-1 の fail-closed により submit が全部止まる。**この変更は破壊的である**。deployed anchor（genomicschain.ch / docker）の状態は未確認

---

## 6. 投函の形

- 成果物はパス＋sha256 で原本を指す。転記しない
- roster: persona 4 体（`signature_integrity` / `backward_compatibility` / `failure_modes` / `test_adequacy`）＋外部 3 機（cli_opus4.6 / codex_gpt5.6-sol / cursor_composer2.5）
- prompt には CLAUDE.md の philosophy briefing と本仕様の §1〜§4 を前置する
- **これは実装レビューである。** 設計の議論（不変量、名義の哲学、段階の切り方）は的でない
