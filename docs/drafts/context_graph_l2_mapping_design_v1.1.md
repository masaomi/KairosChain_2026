---
name: context_graph_l2_mapping_design
description: Context Graph v1.1 — v1.0-f-high の真 P0/P1 を最小 patch (regex dialect, unknown-version step 8, edges.jsonl record schema, read version dispatch, spoof clamp polish + multi-writer carve-out)。design-by-invariant + anti-enumeration 路線維持。
tags: [design, context-graph, L2, architecture, decision-trace]
type: design_draft
version: "1.1"
authored_by: claude-opus-4-7-directive-anti-enumeration-high
supersedes: context_graph_l2_mapping_design_v1.0-f-high
---

# Context Graph × KairosChain v1.1

## v1.0-f-high → v1.1 の patch 範囲

v1.0-f-high の persona 3/3 APPROVE 後に、両 review pool で重複検出された真 P0/P1 のみ in-place 吸収:

- 真P0-D: Ruby `\A\z` ↔ JSON Schema ECMA-262 `^$` の dialect 翻訳則未定 (newline injection vector) → §1.2 新設
- 真P0-E: unknown-version path で step 4-6 skip、step 8 が target 未検証で edges.jsonl に append → pollution → §5.2 step 8 precheck
- 新P1-F: edges.jsonl record schema (どの field が ts authoritative か) 未定義 → §5b 冒頭で record format 明示
- 新P1-G: read-side で `relations_schema != 1` の version dispatch 未明示 → §7 unknown traverse skip
- §5 step 5 wording polish: "now を上回らなければならず" の反転表現を修正 + §1 immutability 表現に first-set spoof clamp qualifier 追加
- §5 step 5 multi-writer carve-out 明文化: spoof clamp が initial set 限定であることを serialization invariant と接続

新セクション追加は §1.2 のみ (既存 §1 の自然な分岐)。それ以外は既存文の in-place 編集。§11 backlog に I-17..I-20 を追加。

## 設計原則

1. Forward-only (既存 L2 schema fail させない)
2. Phase 1 は L2 単独 (L0/L1 不変)
3. 手動 asserted は informed_by のみ (supersedes は Phase 2)
4. 新機能追加なし、整合性完成のみ
5. **Design-by-invariant**: 本設計は不変条件を規定する。不変条件を満たす機構の選択は実装に委任し §11 に列挙する。

## §1 エッジ schema (v1)

```yaml
relations_schema: 1
relations:
  - type: informed_by
    target: v1:session_20260420_051349_c68d4622/multi_llm_review_session
    _resolution:
      state: resolved
      observed_at: "2026-04-26T20:48:03+02:00"
      resolved_at: "2026-04-26T20:48:03+02:00"
```

- relations_schema: top-level、relations key 存在時のみ required、Phase 1 = 1
- type: enum [informed_by]
- target: canonical regex
  `\Av1:(?<sid>session_\d{8}_\d{6}_[0-9a-f]{8})/(?<name>[a-z][a-z0-9_]{0,63})\z`
  に従う。session_id segment と name segment の両方を含む完全形が target identifier の単一真実であり、§2 schema pattern / §4.2 resolver / §7 read-validate はこの canonical regex を共有する (真P0-A)。name 部分は先頭 1 文字 + 後続 0..63 文字 = 合計 1〜64 文字。
- _resolution (system-managed、user 入力は強制 strip — §5 step 3 参照):
  - state: resolved | dangling
  - observed_at: ISO8601、**immutable after first set (except first-set spoof clamp — §5 step 5)**、最初の resolve attempt 時刻
  - resolved_at: ISO8601、optional、mutable cache

### §1.1 System-managed keys (strip 対象)

以下の top-level/nested keys は **system-managed** であり、user 入力から常に strip される:

- `_resolution` (relation item 内)
- `relations_truncated_at` (top-level)

**Strip invariant**: system-managed keys は version dispatch の成否に関わらず、全 write path で user-supplied 値を除去する。System 以外の経路でこれらの値が永続化されることはない。

### §1.2 Regex dialect translation invariant (真P0-D)

§1 canonical regex (Ruby `\A...\z`) と §2 JSON Schema `pattern` (ECMA-262 `^...$`) は **同一 string set を accept しなければならない**。これを保証する不変条件:

- **Ruby canonical (read/match authoritative)**:
  `TARGET_RE_RUBY = /\Av1:(?<sid>session_\d{8}_\d{6}_[0-9a-f]{8})\/(?<name>[a-z][a-z0-9_]{0,63})\z/`
  read-path および resolve_target は本 regex を **唯一の match 機構** として使用する。
- **JSON Schema (write-validate authoritative)**:
  pattern は `^v1:session_\d{8}_\d{6}_[0-9a-f]{8}\/[a-z][a-z0-9_]{0,63}$` 形式とし、character class は `\d` `[0-9a-f]` `[a-z0-9_]` のみ使用 (newline / non-ASCII を含まない)。これにより ECMA-262 anchored-by-default を仮定する validator でも anchored-by-`^$` を仮定する validator でも、**newline injection (例: `v1:...valid...\nattacker_payload`) を accept する状態に陥らない**。
- **Equivalence proof obligation**: 本設計は両 regex が test fixture 上で round-trip equivalent (Ruby match ⇔ Schema accept) であることを実装責務として要求する。Newline injection corpus、Unicode confusables、長さ境界 (1, 64, 65 chars) を最小 corpus とする (具体実装 → §11 I-17)。
- **Synchronization mechanism**: Ruby string と JSON Schema string の drift を防ぐ機構 (codegen / build-time check / unit test) は implementation-determined (§11 I-17)。

## §2 JSON Schema (relations_v1.json)

Schema は v0.7 と同一構造。ただし以下の整合性を明示:

- top-level `additionalProperties: true` — 将来の top-level key 追加を許容
- items 内 `additionalProperties: false` — relation item は厳密
- `relations_truncated_at` は schema 上 optional だが system-managed key (§1.1)
- target field の `pattern` は §1.2 dialect translation invariant に従う ECMA-262 形式 (真P0-A: 単一 string set、真P0-D: dialect 明示)

**Read-validate subset invariant** (§7 との整合): read-side で行う minimal validate は write-side schema 制約の **部分集合** でなければならない。Write-side が許可する文書を read-side が拒否する状態は禁止。

## §3 Validator pinning

`gem 'json_schemer', '~> 2.0'`

## §4 Target 解決と path 防御

### §4.1 Context root 検証

CONTEXT_ROOT_REAL を process boot 時 1 回 realpath し (dev,ino) snapshot を保存。各 request 入口で再 stat 比較、不一致なら StaleContextRootError で fail-closed。

### §4.2 resolve_target

resolve_target(target_str): §1.2 `TARGET_RE_RUBY` で match、CONTEXT_ROOT_REAL 配下に realpath、start_with?(root + SEP) で prefix 同名衝突防止、PathEscapeError。ENOENT は dangling、その他 fs エラーは PathResolutionError。

### §4.3 Path containment invariant

**全ての target dereferencing (write-path AND read-path) は §4.2 と同等の path-escape guard を経由しなければならない。** Read-path (§7 の load_v1_target) が独自の path 構築で containment check を迂回することは禁止。共有 helper か同等ロジックかは implementation-determined (§11)。

## §5 Write path: context_save (8-step ordering)

### Write serialization invariant (P0-α)

**同一 target file に対する step 2.5 の読み取りから step 7 の rename 完了までの区間は、concurrent writer に対して serialized でなければならない。** すなわち、writer A が step 2.5 で読んだ observed_at が、writer A の step 7 完了時に依然として正しい (他の writer に上書きされていない) ことが保証される。Serialization mechanism (flock, rename-and-retry, advisory lock) は implementation-determined (§11)。

### Edges.jsonl best-effort scope invariant (P0-iv)

**直列化区間 (step 2.5–7) は frontmatter 書き換えのみを対象とする。step 8 の `edges.jsonl` append は当該区間の外で実行される best-effort 操作である。** これにより以下の不変条件が成立:

- frontmatter は constitutive source of truth であり、edges.jsonl は derived index (rebuildable cache)
- step 7 (frontmatter rename) 成功後に step 8 が失敗しても **context_save は成功**。失敗した append は `edges.jsonl.pending/` に drop され、次回 reindex で吸収される (§5b merge invariant)
- 観測可能な不変条件: **任意の commit 済み frontmatter edge は、有限時間内に edges.jsonl で観測可能になる** (eventual consistency)。即時性は保証しない

### Step sequence

```
step 1.   frontmatter parse (YAML.safe_load(permitted_classes: [Date, Time]))
            ParseError の扱い → §5.1
step 2.   relations_schema version dispatch
            未知 version → step 3 (strip) のみ実行し step 2.5/4-6 skip → step 7
                        + step 8 は §5.2 precheck 経由 (P0-γ + 真P0-E)
step 2.5. disk 上の既存 _resolution map を pre-load (P0-iii)
            条件: step 2 が v1 を返した path のみ実行。v1 以外では skip (P2-3)
            Re-add (削除済 edge の再追加) では observed_at を新規扱いとする (P2-4)
step 3.   system-managed keys を strip (§1.1 に定義された全 keys、全 version 共通)
step 4.   JSON Schema validate (§2)
step 4.5. maxItems hard cap 100
step 5.   resolve_target → _resolution inject
            observed_at 保持ロジック: 既存 disk 値 (step 2.5 で pre-load) を優先、
            disk 値が nil (= initial set) のときのみ now を採用。
            observed_at sanity-bound invariant (spoof clamp):
              採用候補 t に対して、t > now のときに限り t を now で上書きする
              (= "t は now 以下でなければならない")。
              この clamp は disk 値が nil の場合 (初回採用) のみ発火し、既存
              disk 値の preserved path では発火しない (multi-writer carve-out)。
              すなわち:
                - 初回 (disk_value is nil): t = now、ただし system clock 偽装で
                  得た t > now は now に clamp。ここでのみ §1 immutability に
                  対する例外が成立する ("first-set spoof clamp")。
                - 二回目以降: disk 値を preserved (clamp も上書きも発生しない)。
                  P0-α serialization invariant により、step 2.5 で読んだ disk 値
                  が step 7 完了時に他 writer によって変えられていないことが
                  保証されるため、multi-writer race でも immutability は破れない。
              この bound と §1 immutability の非対称性は意図的である —— clamp は
              未来時刻偽装の **初回採用のみ** に発動する。過去方向の不整合
              (file edit、NTP 後退補正、VM snapshot による ctime regression、
              新規 file で比較対象自体が存在しないケースを含む) では immutable な
              記録を尊重し、warning と observability emit に留める (clamp しない)。
              これにより真P0-B (immutability vs ctime 下限の衝突) と真P0-C
              (ENOENT で比較対象なし) は単一不変条件下で同時に成立し、ctime との
              比較は不要となる。
step 6.   post-injection validate
            §2 schema を post-inject document に対して再実行 AND
            system-managed fields の形式検証:
              state ∈ {resolved, dangling}、
              observed_at/resolved_at は valid ISO8601。(P1-4)
step 7.   atomic file write
            Atomic write invariant: successful return 後、target file content は
            durable かつ visible。Crash mid-write 時は target が unchanged か
            fully replaced (部分書き込み・zero-length 中間状態なし)。
            Mode/owner invariant: 既存 target 上書き時、post-rename file の
            mode/uid/gid は pre-rename target と一致 (non-root writer では
            owner は best-effort)。
            具体的 fsync sequence・tempfile API → §11。
step 8.   edges.jsonl best-effort append (NB flock + retry → pending file fallback)
            §5.2 precheck により target 未検証 relation は append しない。
```

### §5.1 Frontmatter parse error handling (P0-β)

**Fail-closed invariant**: disk 上の frontmatter が parse 不能 (YAML syntax error, encoding error, unexpected type) な場合、write は **失敗** しなければならない (FrontmatterCorruptionError)。Silent degradation to empty map は禁止。

区別すべき状態:
- **ENOENT** (file が存在しない): 正当な初回書き込み。_resolution map は空 (observed_at は now で新規生成)。
- **File 存在 + frontmatter parse 成功 + _resolution key 不在**: 正当。_resolution map は空。
- **File 存在 + frontmatter parse 失敗**: FrontmatterCorruptionError。Write 拒否。

Recovery path: operator が `--force-recovery` 等の explicit opt-in で corrupt file を empty-map 扱いにすることは許容するが、default path では禁止。

### §5.2 Unknown version path (P0-γ + 真P0-E step 8 precheck)

`relations_schema` が既知 version (Phase 1 = 1) 以外の場合:
1. step 3 (strip) は実行する — system-managed keys は version に依存しない不変条件
2. steps 4-6 は skip (未知 schema を validate できない)
3. step 7 は実行する (frontmatter は user-supplied 構造のまま、ただし system-managed keys は strip 済み)
4. **step 8 (edges.jsonl append) には schema-version-independent precheck を適用する** (真P0-E):
   - 各 relation item に対し、`type ∈ {informed_by}` whitelist (Phase 1 schema-independent set) かつ `target` が §1.2 `TARGET_RE_RUBY` に match するもののみ append する
   - `type` 不一致または `target` regex 不一致の relation は **append しない** + observability emit (`unknown_version_relation_skipped` counter)
   - これにより、未知 version 文書から edges.jsonl に未検証 target が混入する経路 (pollution) を物理的に閉じる

不変条件: **edges.jsonl に append される record の target は、append 時点で §1.2 `TARGET_RE_RUBY` に match することが保証される**。これは known/unknown version 共通の write-side invariant であり、§5b reindex の merge / dedup ロジックが target validity を再 check しなくても良いことの根拠となる。

結果: unknown version の relation は frontmatter には system-managed fields strip 済みで保存され、edges.jsonl には precheck 通過分のみが反映される。User-supplied `_resolution` が永続化される経路、および未検証 target が edges.jsonl に流入する経路はいずれも存在しない。

## §5b kairos reindex

### Edges.jsonl record schema invariant (新P1-F)

`edges.jsonl` の各 record は以下の format に従う:

```json
{"from": "<v1:sid/name>", "to": "<v1:sid/name>", "type": "informed_by",
 "ts": "<ISO8601>", "schema_version": 1}
```

- `from`, `to`: ともに §1.2 `TARGET_RE_RUBY` に match (write-side invariant、§5.2 で保証)
- `type`: Phase 1 では `informed_by` のみ (whitelist は schema_version に紐付く)
- **`ts` authoritative source invariant**: `ts` は frontmatter `_resolution.observed_at` を **唯一の authoritative source** とする (`from` 文書の当該 relation の値)。File mtime / ctime / 現在時刻 など disk metadata からの synthesis は **禁止** (§10 synthesis prohibition と整合)。Reindex が frontmatter walk から record を生成する場合も同じ invariant に従う。
- `schema_version`: append 時点の `relations_schema` 値 (Phase 1 = 1)。Unknown version path から append された record は §5.2 precheck により Phase 1 互換 (type/target が Phase 1 set に属する) なので、この field は record の Phase 1 visibility を示す。

### Merge invariant (P0-δ, P0-ii で bounded-pass と整合化)

**Reindex 開始後に commit された全ての save は、その edges が以下のいずれかで保全されなければならない**:

1. 当該 reindex run の rewrite 結果に含まれる、または
2. `edges.jsonl.pending/` または frontmatter 内に永続化され、**次回以降の reindex で回収可能** な状態にある

すなわち禁止される状態は **「edge が永久に消失する」** ことであり、「当該 reindex run で必ず取り込む」ではない。これにより bounded-pass invariant (下記) と論理的に両立する (P0-ii)。

具体的境界: 「reindex の最終 rescan pass 完了前に step 7 rename を完了した save」は当該 run で取り込まれるが、それ以降の save は次回 reindex に回される (永続化済みなので消失しない)。

Mechanism (mtime comparison, content-hash dedup, monotonic counter, explicit pending drain) は implementation-determined (§11)。fs mtime 粒度 (ext4/HFS+ 1s, NFS 2s) に起因する見落としを防ぐ手段の選択は実装責務。

Dedup 時の `latest ts` 比較は **`_resolution.observed_at` 値を対象とする** (上記 record schema invariant に従う)。同一 (from, to, type) で複数 record が存在する場合、record schema invariant により ts はすべて authoritative observed_at であるため、比較は well-defined。

### Bounded-pass invariant (P1-5)

Reindex の merge rescan は **有限回** で終了しなければならない。Active writer が連続 save しても reindex が永久に完了しない状態は禁止。Design bound: MAX_RESCAN_PASSES 回 rescan 後に未 merge の pending が残る場合、reindex は warning を emit して完了する。**残存 pending は frontmatter / edges.jsonl.pending/ に永続化されているため、次回 reindex 起動時に通常入力として処理される** (liveness 保証)。具体的 threshold → §11。

### Pending directory bound (P1-1)

`edges.jsonl.pending/` は advisory な size/age bound を持つ。Bound 超過時は warning を emit する (write を block しない)。Phase 1 では enforcement なし、monitoring のみ。具体的 threshold → §11。

### Process

LOCK_EX timeout、reindex_start 記録、frontmatter walk + edges 行生成 (record schema invariant に従う)、pending file 取り込み、(from,to,type) 単位 latest observed_at dedup、tempfile rewrite、merge invariant 確認 rescan (bounded)、完了。

## §6 哲学的位置づけ

Edges は L2-evidential、edge-relational ontology。Forward-only twin motivation: 哲学 (primary) + 工学 (derived)。Phase 2 boundary-crossing 防止に grep CI lint Phase 1 deliverable + 再 review 必須。

## §7 dream_scan traverse_informed_by

BFS、visited set、resolved_cache.fetch で false も cache、Hash entry のみ select。

Target node load は **§4.3 の path containment invariant を遵守** する経路で行う (load_v1_target が resolve_target/containment guard を bypass することは禁止)。

### §7.1 Read-side version dispatch (新P1-G)

Read-side でも write-side と対称的な version dispatch を行う:

- 文書 frontmatter の `relations_schema == 1` のとき: 通常の minimal read validate + traverse 対象とする
- `relations_schema` が **欠落** している (relations key も不在) とき: traverse 対象外 (no-op)、edges 観測なし
- `relations_schema` が存在するが **1 以外** のとき: 当該文書全体を **traverse skip** + observability emit (`read_unknown_version_skipped` counter)。Phase 1 では partial traverse (一部 relation のみ pickup) は **禁止** — write-side が unknown version で何を strip / append したかの保証範囲外にあり、read-side が独自解釈すると invariant が崩れる。
- `relations_schema == 1` でも minimal read validate (relations Array、items Hash、type/target String、target は §1.2 `TARGET_RE_RUBY` match) を満たさない relation は当該 item のみ skip + observability emit。**この validate は §2 schema の部分集合** であり (§2 read-validate subset invariant)、write-side が許可する文書を read-side が拒否しないことを保証。

不変条件: **read-side が traverse する edge は、§1.2 dialect / §1 schema / §5.2 precheck で write-side が保証する set の subset である**。

## §8 実装ステップ

8 ステップ + テスト suite (schema + integration + property + cycle + path + forward-compat + spoofing + observed_at preservation + truncation + reindex/race/pending + concurrent edges.jsonl + atomic write durability + file mode preservation + stale context_root + performance 1000×3 < 2s + write serialization correctness + parse error fail-closed + unknown version strip-only + reindex bounded termination + canonical target regex single-source (真P0-A) + observed_at clamp asymmetry (真P0-B/C) + **regex dialect round-trip equivalence** (真P0-D: newline injection corpus、Unicode confusables、長さ境界) + **unknown-version edges.jsonl precheck** (真P0-E: type whitelist + target regex の append-time enforcement) + **edges.jsonl record schema** (新P1-F: ts authoritative source = observed_at) + **read-side version dispatch** (新P1-G: unknown version skip + observability) + **first-set-only spoof clamp** (multi-writer carve-out: preserved disk value への上書き不発火))

## §9 Phase 1→2 gate

定量 floor (50+/3+/<20%) + 質的判断 (maintainer 書面 articulate + L2 として保存 + v0.8 への informed_by edge + supersede 候補 multi-LLM review)

### §9.1 Self-anchoring clarification (P2-6)

本設計 v0.8 を Phase 1→2 gate の L2 context が informed_by edge で参照することは **role-relational** な引用であり、L0/L2 区分の崩壊 (intrinsic identity collapse) を意味しない。v0.8 は L2 設計文書としての役割で参照される。Self-referentiality は KairosChain の構造的性質 (CLAUDE.md §命題1) であるが、ここでの参照はその特殊ケースではなく通常の evidential link。

## §10 Phase 2/3 stub

Phase 2: supersedes/led_to/derived edges/reverse traversal/contradicts/dangling GC/edges.jsonl compaction/silent-promotion fail-gate。

**Synthesis prohibition** (P2-5 統合): Phase 2 においても以下は禁止:
- mtime-based observed_at synthesis (v0.7 既定)
- **edges.jsonl timestamp synthesis** (既存 edge の ts を mtime 等から事後生成することは禁止。ts は write-time に記録された `_resolution.observed_at` 値のみ正当 — §5b record schema invariant)

Phase 3: L0 波及、命題8。

## §11 Implementation Decisions Backlog

本セクションは設計本文が規定する不変条件を満たすための **機構選択** を列挙する。実装者が判断し、実装 review で検証する。設計 review の対象外。

| ID | 関連不変条件 | 実装が決定する事項 |
|----|-------------|-------------------|
| I-1 | §5 write serialization | flock / advisory lock / rename-loop / other mechanism |
| I-2 | §5 step 7 atomic write | fsync call ordering (write→fsync→close→rename→dir-fsync or equivalent) |
| I-3 | §5 step 7 mode/owner | Tempfile API 選択、chmod/chown 呼び出し順序 |
| I-4 | §5 step 7 crash safety | tempfile cleanup (ensure block placement) |
| I-5 | §4.3 path containment | 共有 helper vs inline check、O_NOFOLLOW/openat usage |
| I-6 | §5.1 ENOENT detection | errno enumeration (ELOOP, EACCES, EPERM の分類) |
| I-7 | §5b merge invariant | mtime >=、content-hash dedup、monotonic counter、pending drain — mechanism choice |
| I-8 | §5b bounded-pass | MAX_RESCAN_PASSES 具体値 (推奨: 3-5) |
| I-9 | §5b pending bound | count/age threshold 具体値 |
| I-10 | §5 step 7 mode mask | 07777 vs 07000 (which bits to preserve) |
| I-11 | §7 target load | lstat vs realpath for metadata、read-path containment の具体実装 |
| I-12 | §5 step 7 new file default | mode for newly created files (no pre-existing target) |
| I-13 | §5 state value type | Symbol vs String internal representation |
| I-17 | §1.2 dialect sync | Ruby ↔ JSON Schema 同期機構 (codegen / build-time check / property test fixture corpus) |
| I-18 | §5b pending uniqueness | edges.jsonl.pending/ file naming scheme (collision-free 化) |
| I-19 | §5b reindex atomicity | tempfile rewrite の crash-safe sequence (write→fsync→rename→dir-fsync 等) |
| I-20 | §7.1 unknown version | observability counter naming、emit frequency、metrics integration |

---

*End of v1.1.*
