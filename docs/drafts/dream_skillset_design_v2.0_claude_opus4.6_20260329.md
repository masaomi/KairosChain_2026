# Dream SkillSet Design Draft v2.0

**Date**: 2026-03-29
**Author**: Masaomi Hatakeyama (design intent, philosophical framework) + Claude Opus 4.6 (designer)
**Status**: Draft v2.0 — L2 Soft-Archive and memory philosophy integration
**Scope**: L1 SkillSet for memory consolidation, knowledge promotion, and L2 lifecycle management

---

## Changes from v1.1

| Change | Reason | Origin |
|--------|--------|--------|
| **2 tools → 4 tools**: Added `dream_archive` and `dream_recall` | L2 肥大化がブロックチェーンよりも深刻な現実の問題。L2ライフサイクル管理が必要 | chain_archive PR#2 レビューセッションでの議論 |
| **L2 Soft-Archive**: タグ+サマリーを残してフルテキストを圧縮 | 「完全削除ではなく、微かな思い出しpathを残す」という記憶哲学 | Masaomi: フレーム問題とアハ体験の考察 |
| **Bisociation detection**: 異なるタグクラスター間の意外な共起をスキャン | 既存知識との結びつきからアハ体験が生まれるという仮説 | Masaomi: 「アハ体験は既存知識との結び付けで起きる」 |
| **chain_archive との関係整理**: Dream を先に実装、chain_archive は後回し | ブロックチェーン肥大化は年単位、L2肥大化は週単位の問題 | chain_archive レビューでの合意 |
| **閾値の見直し**: L2 staleness をセッション数ではなく日数ベースに | 作業頻度は人によって異なる | 実運用の考慮 |

---

## 0. 設計意図と哲学的動機

### v1.1 からの継承

> The system that **defines how knowledge evolves** cannot currently **describe its
> own knowledge evolution rules** within its own framework. Dream closes this
> self-referential gap by making promotion discovery a SkillSet capability.

### v2.0 追加: 記憶のフレーム問題

現在のLLMのコンテキスト管理は本質的に **全件検索か忘却の二択** である：

- RAG/ベクトル検索: 「関連ありそうなもの」を引くが、何を検索すべきかは外部から与えられる
- Context window: 入れば見える、入らなければ完全に存在しない
- Memory tools: 明示的に保存したものだけが残る

人間の記憶はこれと根本的に異なる：

- **忘れるが、完全には消えない** — 微かな引っかかりが残る
- **関連付けで思い出す** — 直接の検索ではなく、別の文脈から想起される
- **睡眠中に統合される** — 断片が再構成されて新しいパターンになる

Dream v2.0 は「完全アーカイブ」ではなく **「断片だけが検索に引っかかる」状態** を作る。
これは Arthur Koestler の bisociation（二つの独立した思考枠が予期せず交差する瞬間）に
通じる設計であり、フレーム問題の**回避**（解決ではない）を目指す。

### 設計原則

1. **忘れても思い出せる** — フルコンテンツは圧縮するが、タグとサマリーは検索可能に残す
2. **意外な発見を促す** — 異なるドメインのタグ共起を検出し、bisociationの種を提示する
3. **Read-heavy, Write-light** (v1.1継承) — 発見と提案が主、実行は既存ツールに委譲
4. **Kairos的発火** — 量的閾値ではなく、パターンの質的成熟で処理を開始する

---

## 1. アーキテクチャ概要 (v2.0)

```
                    ┌─────────────────────────────────────────────┐
                    │           Dream SkillSet (L1)               │
                    │                                             │
                    │  dream_scan ──► dream_propose               │
                    │       │              │                      │
                    │       │         knowledge_update             │
                    │       │         skills_promote               │
                    │       │                                      │
                    │  dream_archive ──► L2 soft-archive           │
                    │       │              │                      │
                    │       │         context_save (stub)          │
                    │       │         gzip (full text)             │
                    │       │                                      │
                    │  dream_recall ──► L2 restore                 │
                    │       │              │                      │
                    │       │         gunzip + context_save        │
                    │       │                                      │
                    │       ▼                                      │
                    │  chain_record (findings + archive events)    │
                    └──────────┬──────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        Session Start    Autonomos         Manual
        (LLM decision)  Reflect Phase     Invocation
```

### ツール構成

```
v1.1:  dream_scan + dream_propose                    (発見・提案)
v2.0:  dream_scan + dream_propose                    (発見・提案)
     + dream_archive                                 (L2ソフトアーカイブ)
     + dream_recall                                  (アーカイブ復元)
```

### 依存グラフ

```
dream (v2.0)
├── depends_on: [] (no hard dependencies)
├── integrates_with: autonomos (optional, runtime-detected)
├── delegates_to:
│   ├── knowledge_update (L1 entry creation/update)
│   ├── skills_promote (L2→L1 single-source promotion)
│   └── skills_audit (archive, health check)
├── reads: context_manager (L2 scanning)
├── reads: knowledge_provider (L1 scanning)
├── writes: context_save (soft-archive stubs)
├── writes: filesystem (gzip compression / decompression)
└── writes: chain_record (scan findings + archive events)
```

---

## 2. ツール仕様

### 2.1 dream_scan (v2.0 拡張)

**v1.1 からの変更**: bisociation detection とarchive候補検出を追加。

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `scope` | string | No | `"l2"` (default), `"l1"`, `"all"` |
| `since_session` | string | No | Session ID — このセッション以降をスキャン |
| `min_recurrence` | integer | No | パターンが出現する最小セッション数 (default: 3) |
| `max_candidates` | integer | No | カテゴリごとの最大候補数 (default: 5) |
| `include_archive_candidates` | boolean | No | L2アーカイブ候補を検出するか (default: true) |

**Scan Signals (v2.0)**:

| Signal | Method | Category | Strength |
|--------|--------|----------|----------|
| Tag co-occurrence | N+セッションに出現するタグセット | promotion | **Primary** |
| Name token overlap | Jaccard on `_`-tokenized names | consolidation | Advisory |
| Cross-session recurrence | 同名/同パターンのN+セッション出現 | promotion | **Primary** |
| L1 staleness | 直近L2で参照されないL1エントリ | consolidation | **Primary** |
| **L2 staleness (NEW)** | N日間参照されていないL2 context | archive | **Primary** |
| **Bisociation (NEW)** | 通常共起しないタグクラスター間の共出現 | discovery | **Advisory** |

#### L2 Staleness 検出

```ruby
def detect_stale_l2(contexts, threshold_days: 90)
  now = Time.now
  contexts.select do |ctx|
    last_modified = parse_timestamp(ctx[:modified])
    days_since = (now - last_modified) / 86400
    days_since > threshold_days
  end
end
```

**閾値**: デフォルト90日。`dream.yml` で設定可能。
1000件のような件数ベースではなく、日数ベース。作業頻度に依存しない。

#### Bisociation 検出

「通常は共起しないタグペアが同一contextに出現する」ことを検出する。

```ruby
def detect_bisociations(tag_index, min_surprise: 0.8)
  # 1. タグペアの全体出現頻度を計算
  pair_freq = compute_pair_frequencies(tag_index)

  # 2. 各タグの独立出現頻度から期待共起頻度を計算
  # 3. 実際の共起 / 期待共起 の比率が高いペアを「意外な共起」として検出
  # PMI (Pointwise Mutual Information) ベース

  pair_freq.select do |pair, actual|
    expected = individual_freq[pair[0]] * individual_freq[pair[1]]
    pmi = Math.log2(actual.to_f / expected) rescue 0
    pmi > min_surprise
  end
end
```

**Example**:
- `[blockchain, biology]` — 通常は共起しない。同一contextに出現すれば、GenomicsChain的な
  洞察が含まれている可能性がある
- `[philosophy, deadlock]` — KairosChainの自己参照性とコンカレンシーの接点

これは単なるstaleness検出よりも**創造的な機能**であり、フレーム問題の「何を検索
すべきかわからない」を部分的に回避する。

**Output (v2.0 拡張)**:

```yaml
scan_result:
  # ... v1.1 の promotion_candidates, consolidation_candidates はそのまま ...

  archive_candidates:        # NEW: L2 soft-archive候補
    - name: "old_deployment_notes"
      session: "session_20260115_..."
      last_modified: "2026-01-15"
      days_since_modified: 73
      tags: [deployment, docker, notes]
      size_bytes: 4500
      signal_type: "l2_staleness"
      recommended_action: "dream_archive"

  bisociation_candidates:    # NEW: 意外な共起
    - tag_pair: ["blockchain", "biology"]
      contexts:
        - session: "session_20260220_..."
          name: "genomics_chain_concept"
      pmi_score: 2.4
      signal_type: "bisociation"
      note: "Unusual tag co-occurrence — may contain cross-domain insight"

  health_summary:
    total_l2: 34
    total_l1: 8
    promotion_ready: 2
    consolidation_needed: 1
    stale_l1: 1
    archive_candidates_l2: 5    # NEW
    bisociations_detected: 1    # NEW
```

### 2.2 dream_propose (v1.1 から変更なし)

L1昇格の提案パッケージング。v1.1の設計をそのまま継承。

### 2.3 dream_archive (NEW)

**Purpose**: L2 contextのソフトアーカイブ。フルテキストを圧縮し、タグとサマリーだけを
検索可能な状態で残す。

**設計哲学**: 「忘れるが、完全には消えない」— 微かな思い出しpathを残す。

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `targets` | array[object] | Yes | アーカイブ対象のL2 context（dream_scanの archive_candidates、または手動指定） |
| `summary_mode` | string | No | `"auto"` (default, LLMがサマリー生成), `"first_paragraph"`, `"tags_only"` |
| `dry_run` | boolean | No | trueの場合、実行せずプレビューのみ (default: false) |

各target object:
```json
{
  "session_id": "session_20260115_...",
  "context_name": "old_deployment_notes"
}
```

**処理フロー**:

```
1. 対象L2 contextのフルテキストを読み込み
2. サマリーを生成（auto: LLM呼び出し / first_paragraph: 冒頭抽出 / tags_only: タグのみ）
3. フルテキストを gzip 圧縮して .kairos/dream/archive/ に保存
4. 元のL2 contextをスタブ（タグ+サマリー+archive参照）に置換
5. chain_record でアーカイブイベントを記録
```

**スタブ形式** (soft-archived L2 context):

```yaml
---
title: "old_deployment_notes"
tags: [deployment, docker, notes]
description: "Docker ComposeでのKairosChain本番デプロイ手順メモ"
status: soft-archived
archived_at: "2026-03-29T10:00:00Z"
archived_by: dream_archive
archive_ref: "dream/archive/session_20260115_.../old_deployment_notes.md.gz"
original_size: 4500
summary: |
  Docker Compose v2 での本番デプロイ手順。ポート設定、ボリューム
  マウント、環境変数の注意点を記録。Puma workerの推奨設定あり。
---

# old_deployment_notes [ARCHIVED]

このコンテキストはソフトアーカイブされています。
フルテキストは `dream_recall` で復元できます。

**タグ**: deployment, docker, notes
**元のサイズ**: 4,500 bytes
**サマリー**: Docker Compose v2 での本番デプロイ手順。ポート設定、ボリューム
マウント、環境変数の注意点を記録。Puma workerの推奨設定あり。
```

**なぜこの設計か**:

- **タグ**: RAG/ベクトル検索でヒットする。「deployment」で検索すると、このスタブが見つかる
- **サマリー**: LLMが「あ、前にこれやったな」と判断できる最小限の情報
- **archive_ref**: 必要ならフル復元できるパス
- **フルテキストはない**: context windowを消費しない。記憶のリソースを開ける

**ストレージレイアウト**:

```
.kairos/
├── context/                           # L2 contexts（ライブ）
│   ├── session_20260115_.../
│   │   └── old_deployment_notes/
│   │       └── old_deployment_notes.md   ← スタブに置換
│   └── session_20260329_.../
│       └── current_work/
│           └── current_work.md           ← そのまま
└── dream/
    └── archive/                       # Dream アーカイブ
        └── session_20260115_.../
            └── old_deployment_notes.md.gz  ← gzip圧縮された元テキスト
```

**Output**:

```yaml
archive_result:
  archived: 3
  skipped: 0
  total_bytes_saved: 12400
  items:
    - name: "old_deployment_notes"
      session: "session_20260115_..."
      original_size: 4500
      stub_size: 650
      archive_path: "dream/archive/session_20260115_.../old_deployment_notes.md.gz"
      summary: "Docker Compose v2 での本番デプロイ手順..."
```

**Blockchain recording**: `dream_archive` イベント。対象リスト、圧縮前後のサイズ、
サマリーのハッシュを記録。

**Safety**:
- `can_modify_l2?` 権限チェック
- `dry_run: true` でプレビュー可能
- gzip ファイルが存在する限り、`dream_recall` で完全復元可能
- フルテキストの**削除**は行わない（圧縮・移動のみ）

### 2.4 dream_recall (NEW)

**Purpose**: ソフトアーカイブされたL2 contextを復元する。
「あれなんだっけ？」からフルテキストを取り戻す。

**Input**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | string | Yes | 復元対象のセッションID |
| `context_name` | string | Yes | 復元対象のコンテキスト名 |
| `preview` | boolean | No | trueの場合、解凍して表示するが元に戻さない (default: false) |

**処理フロー**:

```
1. スタブからarchive_refを読み取り
2. gzipファイルを解凍
3. preview=true の場合: 内容を表示して終了
4. preview=false の場合:
   a. スタブをフルテキストに置換
   b. gzipファイルを削除（or 保持、設定による）
   c. chain_record で recall イベントを記録
```

**Output**:

```yaml
recall_result:
  name: "old_deployment_notes"
  session: "session_20260115_..."
  restored_size: 4500
  status: "restored"  # or "preview"
```

**Safety**:
- `can_modify_l2?` 権限チェック
- `preview: true` で破壊的操作なしに内容確認可能
- アーカイブ参照が壊れている場合は明確なエラー

---

## 3. Autonomos 統合 (v1.1 から変更なし)

Orient phase で `dream_scan`、Reflect phase で結果確認。
ランタイム検出、コードパッチなし。

---

## 4. Blockchain Recording (v2.0)

| Event | Record Type | When | Data |
|-------|-------------|------|------|
| Scan with findings | `dream_scan_findings` | 非空結果のみ | Scope, candidate count, health summary |
| Scan without findings | *(not recorded)* | — | — |
| Proposal created | `dream_proposal` | Always | Candidate list, recommended actions |
| **L2 archived** | `dream_archive` | **Always** | Target list, sizes, summary hashes |
| **L2 recalled** | `dream_recall` | **Always** | Target, restored size |
| Promotion executed | *(delegated)* | Via `knowledge_update` | Standard knowledge record |

### Rationale: Archive/Recall は常に記録

Soft-archiveは情報の存在論的状態を変更する（フルアクセス → 断片アクセス）。
これは Proposition 5（記録は構成物的）に照らして、記録すべき変換である。
scan findings とは異なり、「何もしなかった」ことの記録ではない。

---

## 5. Kairotic Trigger Design (v2.0 拡張)

```yaml
triggers:
  # v1.1 からの継承
  session_start:
    condition: "last_scan_findings older than 5 sessions"
    action: "dream_scan(scope: 'all')"

  session_end:
    condition: "new L2 contexts created this session >= 2"
    action: "dream_scan(scope: 'l2', since_session: current_session)"

  autonomos_reflect:
    condition: "same goal cycled 3+ times"
    action: "dream_scan(scope: 'l2', since_session: first_cycle_session)"

  user_request:
    condition: "user says 'review knowledge' or similar"
    action: "dream_scan(scope: 'all')"

  # v2.0 追加
  l2_growth:
    condition: "total L2 contexts > 50 and last archive scan > 30 days ago"
    action: "dream_scan(scope: 'l2', include_archive_candidates: true)"
    note: "L2肥大化の予防的スキャン"

  bisociation_review:
    condition: "bisociation_candidates detected in previous scan"
    action: "LLMがbisociation候補を精査し、cross-domain insightをL1に昇格検討"
    note: "自動実行ではなくLLMの判断を促す"
```

---

## 6. L2 ライフサイクルモデル (NEW)

### 状態遷移

```
                    ┌─────────────┐
                    │   Active    │  ← context_save で作成
                    │  (L2 live)  │
                    └──────┬──────┘
                           │
              dream_scan detects staleness
                           │
                           ▼
                    ┌─────────────┐
                    │  Candidate  │  ← scan_result.archive_candidates
                    │ (proposed)  │
                    └──────┬──────┘
                           │
              user approves / dream_archive
                           │
                           ▼
                    ┌─────────────┐
                    │ Soft-Archived│  ← stub (tags + summary) + gzip
                    │ (dormant)   │
                    └──────┬──────┘
                           │
              dream_recall (user needs it again)
                           │
                           ▼
                    ┌─────────────┐
                    │   Active    │  ← 復元
                    │  (L2 live)  │
                    └─────────────┘
```

### なぜ「削除」ではなく「ソフトアーカイブ」か

1. **フレーム問題への対処**: 何が将来必要になるか予測できない。完全削除は取り返しがつかない
2. **思い出しpath**: タグとサマリーが残ることで、RAG検索やLLMの連想でヒットする
3. **リソース効率**: フルテキストはcontext windowを消費するが、stubは数百バイト
4. **復元可能性**: `dream_recall` でいつでもフル復元できる安心感

### chain_archive との比較

| 観点 | chain_archive | dream_archive |
|------|--------------|---------------|
| 対象 | ブロックチェーン（L0 audit trail） | L2 context（作業記憶） |
| 閾値 | 量的（100,000ブロック） | 質的（90日間未参照） |
| 残すもの | archive block（暗号的参照） | stub（タグ + サマリー + 参照） |
| 復元 | gunzip + JSON手動操作 | `dream_recall` ワンコマンド |
| 検索性 | アーカイブ内ブロックは検索不可 | **stubがRAGにヒットする** |
| 哲学 | ストレージ最適化 | **記憶の再構成** |
| 緊急度 | 低（年単位の問題） | 高（週単位の問題） |

**最大の違い**: chain_archive はアーカイブしたブロックを「見えなくする」。
dream_archive はアーカイブしたcontextの「断片を見えるまま残す」。

---

## 7. Bisociation Detection の詳細 (NEW)

### 理論的背景

Arthur Koestler (1964) の bisociation: 二つの独立した思考の枠組み (matrix of thought)
が予期せず交差する瞬間に創造的発見が生まれる。

KairosChainの文脈では：
- 各L2 contextは特定のドメイン（タグクラスター）に属する
- 通常、`[blockchain, security]` や `[rails, debugging]` のような同一クラスター内のタグが共起
- `[blockchain, biology]` のような異クラスター共起は、cross-domain insightの可能性

### 実装

```ruby
module Dream
  class BisociationDetector
    def initialize(tag_index)
      @tag_index = tag_index
      @cluster_cache = nil
    end

    def detect(min_pmi: 1.5, max_results: 5)
      # Phase 1: タグクラスターの推定（共起頻度ベース）
      clusters = estimate_clusters

      # Phase 2: クラスター間共起の検出
      cross_cluster_pairs = []
      @tag_index.each_pair do |context, tags|
        cluster_ids = tags.map { |t| clusters[t] }.compact.uniq
        next unless cluster_ids.size >= 2  # 2+クラスターにまたがる

        # このcontextは異なるクラスターのタグを含む
        cross_pairs = tags.combination(2).select do |a, b|
          clusters[a] != clusters[b]
        end
        cross_cluster_pairs.concat(cross_pairs.map { |p| [p, context] })
      end

      # Phase 3: PMI計算で意外性をスコアリング
      score_by_pmi(cross_cluster_pairs, max_results)
    end

    private

    def estimate_clusters
      # 簡易クラスタリング: 共起頻度が高いタグ同士を同一クラスターに
      # Connected components on co-occurrence graph with threshold
      # 本格的にはSpectral Clusteringだが、v2ではシンプルなグラフベースで十分
    end

    def score_by_pmi(pairs, max_results)
      # PMI(a,b) = log2(P(a,b) / (P(a) * P(b)))
      # 高PMI = 独立出現確率に比べて共起が多い = 「意外に関連している」
    end
  end
end
```

### 出力の使い方

bisociation候補はLLMへの**ヒント**として提示される。自動実行はしない。

```
Dream scan detected an unusual tag co-occurrence:
  [blockchain, biology] in "genomics_chain_concept"
  PMI score: 2.4 (high surprise)

This may contain cross-domain insight worth preserving as L1 knowledge.
Would you like to review this context?
```

LLMまたはユーザーが判断し、必要なら `dream_propose` で L1 昇格を提案する。

### 制限事項

- v2.0 ではタグベースのみ。セマンティック類似度は将来版
- クラスター推定は共起頻度ベースの簡易手法。タグ数が少ない初期は精度が低い
- **Advisory signal**: 判断はLLMに委ねる。自動昇格はしない

---

## 8. Self-Referentiality Assessment (v2.0 更新)

### SkillSet 構造

```
.kairos/skillsets/dream/
├── skillset.json
├── lib/dream/
│   ├── scanner.rb            # L2/L1 structural pattern detection
│   ├── proposer.rb           # Proposal packaging
│   ├── archiver.rb           # L2 soft-archive (NEW)
│   ├── recaller.rb           # L2 archive restore (NEW)
│   └── bisociation.rb        # Cross-cluster detection (NEW)
├── tools/
│   ├── dream_scan.rb
│   ├── dream_propose.rb
│   ├── dream_archive.rb      # NEW
│   └── dream_recall.rb       # NEW
├── knowledge/
│   └── dream_trigger_policy/
│       └── dream_trigger_policy.md
└── config/
    └── dream.yml
```

### Meta-Level Classification

| Component | Level | Description |
|-----------|-------|-------------|
| `dream_scan`, `dream_propose` | base-level | L2/L1コンテンツに作用 |
| `dream_archive`, `dream_recall` | base-level | L2ライフサイクル管理 |
| `bisociation detection` | meta-level | パターンのパターンを検出 |
| `dream_trigger_policy` | meta-level | 操作の発火条件を定義 |
| Dream SkillSet 自体 | meta-meta-level | 能力そのものを定義 |

### Dream は Dream 自身をアーカイブできるか？

Yes. Dream のスキャンはL2を走査するので、Dream自身の過去のscan結果contextも
アーカイブ候補になりうる。これは自己参照的だが問題はない — scan結果自体は
consumable な作業記憶であり、L1に昇格したパターンこそが永続的知識。

---

## 9. Safety Considerations (v2.0 更新)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Over-promotion | Medium | `min_recurrence` threshold; `max_candidates` cap |
| Scan performance on large L2 | Medium | `since_session` limits; tag index cache in future |
| **Accidental archive of active context** | **Medium** | `dry_run` default; staleness threshold 90 days |
| **Archive corruption (gzip)** | **Low** | SHA256 hash recorded in chain; verify before delete |
| **Summary quality** | **Medium** | `preview` mode in recall; user reviews before approve |
| Self-referential loop | Low | Standard L1 rules; no special-casing |
| Bisociation noise | Low | Advisory only; LLM evaluates substance |

### 新規: dream_archive の安全策

1. **dry_run デフォルト**: 初回は必ずプレビュー
2. **90日閾値**: 直近3ヶ月以内のcontextはアーカイブ候補にしない
3. **復元保証**: gzipファイルが存在する限り `dream_recall` で完全復元
4. **chain記録**: アーカイブイベントは常にブロックチェーンに記録
5. **権限チェック**: `can_modify_l2?` が必要

---

## 10. skillset.json (Draft v2.0)

```json
{
  "name": "dream",
  "version": "0.2.0",
  "description": "Memory consolidation and L2 lifecycle management. Scans L2 contexts for recurring patterns, detects cross-domain insights (bisociation), manages L2 soft-archive (preserve tags and summaries while compressing full text), and packages promotion proposals. Read-heavy, write-light: knowledge modifications delegated to existing tools.",
  "author": "Masaomi Hatakeyama",
  "layer": "L1",
  "depends_on": [],
  "provides": [
    "pattern_detection",
    "promotion_discovery",
    "knowledge_health_scan",
    "l2_soft_archive",
    "l2_recall",
    "bisociation_detection"
  ],
  "tool_classes": [
    "KairosMcp::SkillSets::Dream::Tools::DreamScan",
    "KairosMcp::SkillSets::Dream::Tools::DreamPropose",
    "KairosMcp::SkillSets::Dream::Tools::DreamArchive",
    "KairosMcp::SkillSets::Dream::Tools::DreamRecall"
  ],
  "config_files": ["config/dream.yml"],
  "knowledge_dirs": ["knowledge/dream_trigger_policy"],
  "min_core_version": "2.8.0"
}
```

---

## 11. dream.yml (Draft)

```yaml
# Dream SkillSet configuration
scan:
  default_scope: "l2"
  min_recurrence: 3
  max_candidates: 5

archive:
  staleness_threshold_days: 90        # L2 contextのstaleness閾値
  summary_mode: "auto"                # auto / first_paragraph / tags_only
  preserve_gzip: true                 # recall後もgzipを保持するか
  archive_dir: "dream/archive"        # .kairos/ 配下の相対パス

bisociation:
  enabled: true
  min_pmi: 1.5                        # PMIの最小閾値
  max_results: 5

recording:
  scan_findings_only: true            # 空スキャンは記録しない
  archive_events: true                # アーカイブ/リコールは常に記録
```

---

## 12. 実装フェーズ (v2.0)

| Phase | Deliverable | Dependencies | Priority |
|-------|-------------|--------------|----------|
| **Phase 1** | `dream_scan` (L2 tag co-occurrence + staleness + L2 archive候補) | ContextManager, KnowledgeProvider | **最優先** |
| **Phase 2** | `dream_archive` + `dream_recall` (L2 soft-archive) | Phase 1, ContextManager | **高** |
| **Phase 3** | `dream_propose` (proposal packaging) | Phase 1, knowledge_update | 中 |
| **Phase 4** | `dream_trigger_policy` (L1 knowledge) | Phase 1-3 | 中 |
| **Phase 5** | Bisociation detection | Phase 1 (tag index) | 低（実験的） |
| **Phase 6** | Autonomos integration | Phase 1, autonomos | 低（optional） |

### chain_archive との関係

```
Dream SkillSet (v2.0)          chain_archive SkillSet (PR #2)
├── Phase 1-2: 先に実装         ├── Fix Plan v3 の修正適用
├── Phase 3-4: 中期             ├── 閾値を100,000に引き上げ
├── Phase 5-6: 長期             └── 実装・レビュー・マージ
```

**chain_archive は Dream の後に着手**。理由:
- L2肥大化は週単位の問題、ブロックチェーン肥大化は年単位
- Dream Phase 2 (L2 soft-archive) が chain_archive より先に価値を提供
- chain_archive には Fix Plan v3 の8修正が必要（Dream は設計収束済み）

---

## 13. Open Questions (v2.0)

### Q1: summary_mode "auto" の LLM 呼び出し

`dream_archive` で `summary_mode: "auto"` を使う場合、LLMへのサマリー生成依頼が
必要。これは `llm_call` ツール経由か、`dream_archive` 内で直接呼び出すか？

**暫定回答**: `dream_archive` はサマリー生成をLLMに**依頼**するのではなく、
呼び出し元のLLM（Claude等）が `dream_archive` を呼ぶ前にサマリーを生成し、
パラメータとして渡す。Dream自体はLLMを呼ばない（Read-heavy, Write-light原則）。

### Q2: tag index キャッシュ

v1.1 では「1000 contexts まではフルスキャンで十分」としたが、soft-archiveの
stubも検索対象に含めると、長期的にはスタブが蓄積する。tag indexキャッシュは
Phase 2 実装時に判断。

### Q3: bisociation のクラスター推定精度

タグ数が少ない初期段階ではクラスター推定が不安定。最小タグ数（例: 全体で20種類以上）
のガードを設けるか？

**暫定回答**: `bisociation.enabled: true` かつタグ種類数 >= 15 の場合のみ実行。
それ以下ではスキップ。

### Q4: dream_archive と skills_audit archive の棲み分け

`skills_audit` には既にL1のアーカイブ機能がある。`dream_archive` はL2専用。
将来的に統一インターフェースにするか？

**暫定回答**: 分離したまま。L1アーカイブ（skills_audit）はknowledge整理、
L2アーカイブ（dream_archive）は作業記憶整理。対象レイヤーが異なるので統一は不適切。

---

*Generated: 2026-03-29 by Claude Opus 4.6*
*Review status: v2.0 — Ready for Multi-LLM review*
