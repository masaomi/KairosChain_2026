---
name: multi_llm_review_v3.24.3_design
description: Worker pulse race fix (scope厳格化版) — per-thread ts + observability、defense items は v3.24.4 へ分離
type: design_draft
status: proposed
date: 2026-04-27
version: "3.24.3"
supersedes: multi_llm_review_v3.24.3_design_v0.1
---

# multi_llm_review v3.24.3 設計 v0.2：pulse race 完全修正 (scope 厳格化)

## v0.1 → v0.2 の変更

v0.1 multi-LLM review (3 persona) で **3/3 REVISE 全会一致**。主要指摘:

| 指摘 | 出元 | v0.2 対処 |
|------|------|----------|
| `||=` 簡略化が同じ race を再現 (T1 anchor が outlast) | Concurrency P1 | **per-thread ts (Hash) を Phase 1 で採用**、Phase 2 deferral 撤回 |
| heartbeat 自己 mask 撤廃は dual guarantee 原則違反 | Minimal-fix P1 | **heartbeat 自己 mask は残す** |
| Defense A + heartbeat unconditional は内部矛盾 | Minimal-fix P1 | heartbeat unconditional 撤回 (上記と同じ) |
| Scope creep (B/C/D/E は別問題) | Minimal-fix P1 | **B/C/D/E は v3.24.4 に分離**、本 patch は worker pulse のみ |
| 可観測性ゼロ | Operations P1 | **pulse 診断ログを worker.log に追加** |
| CRASH_REASONS 列挙なし | Operations P1 | **WaitForWorker::CRASH_REASONS 定数化** |
| integration test stub vs real 未指定 | Operations P1 | **stubbed reviewers + 固定 sleep 分布** |
| forensic 保存なし | Operations P2 | incident token を `_forensics/` に保存 (手動) |

## 真の root cause (再掲)

Token `5b75ff8c-...` post-mortem:
```
10:08:15  state created (pending)
10:09:42  worker.tick last touched     ← pulse 早期停止
10:10:10  worker.heartbeat last touched ← tick stale で自己 mask
10:10:28  state → 'done', results written
```

`MAIN_STATE.in_llm_call_since_mono` (process-global、単一 ts) が parallel reviewer threads と非互換。T1.exit が T2 still-in-call の状態で `ts=nil` にしてしまう (上書き race)。

## 修正対象 (worker のみ、wait 側は v3.24.4)

### 1. MainState: per-thread ts

```ruby
# main_state.rb 改訂版
module KairosMcp
  module SkillSets
    module MultiLlmReview
      MAIN_STATE = Struct.new(:counter, :ts_by_thread).new(0, {})
      MUTEX = Mutex.new

      module MainState
        module_function

        def enter_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.ts_by_thread[tid] =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        def exit_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.counter += 1
            MAIN_STATE.ts_by_thread.delete(tid)
          end
        end

        # snapshot returns (counter, in_flight, oldest_ts)
        # in_flight = current in-call thread count
        # oldest_ts = oldest enter ts among currently-in-call threads (nil if none)
        def snapshot
          MUTEX.synchronize do
            ts_values = MAIN_STATE.ts_by_thread.values
            [MAIN_STATE.counter, ts_values.size, ts_values.min]
          end
        end

        def reset!  # tests only
          MUTEX.synchronize do
            MAIN_STATE.counter = 0
            MAIN_STATE.ts_by_thread.clear
          end
        end
      end
    end
  end
end
```

**Concurrency persona P1 対処**:
- T1 enter (tid=A, ts=0) → ts_by_thread = {A: 0}
- T2 enter (tid=B, ts=10) → {A: 0, B: 10}
- T1 exit → {B: 10}, oldest_ts = 10 (T1 の anchor は消える)
- T2 が 350s 走行 → oldest_ts (10) との差 = 340s < 360s → alive=true ✅
- 旧 v0.1 だと oldest_ts = 0 のまま → 350s で alive=false (バグ)

**Why MUTEX**: Hash の delete/insert は MRI 内部で複数命令、torn read 可能性あり。Mutex で 1 critical section 化。性能影響: enter/exit は LLM call 当たり 1 回 (数十秒〜数分) で contention は無視可能。snapshot も同 mutex 取得で読み取り一貫性確保。

**Thread.kill 安全性**: `Mutex#synchronize` は Ruby 内部で `ensure unlock` を保証 (Thread.kill mid-block でも mutex 解放)。`main_state.rb` ヘッダコメントに不変条件として記載 (将来 manual lock/unlock 化を防ぐ)。

**Memory footprint**: ts_by_thread の size は in-flight thread 数。reviewers ≤ 5 + nil なので 5 entries 上限。GC 影響なし。

### 2. Pulse thread: 3-tuple snapshot

```ruby
# dispatch_worker.rb pulse_thread 改訂版
pulse_thread = Thread.new do
  begin
    last_counter = -1
    log_emit_at = 0  # observability: emit log at most every 5s
    loop do
      counter, in_flight, oldest_ts = MLR::MainState.snapshot
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      alive =
        if counter != last_counter
          true
        elsif in_flight > 0 && oldest_ts
          (now - oldest_ts) < (max_call_t + call_margin)  # 360s
        elsif in_flight > 0
          true  # in-call but ts not set yet — should be transient
        else
          false  # idle, no progress
        end
      FileUtils.touch(PS.worker_tick_path(token)) if alive

      # Diagnostic log (Operations persona P1): emit every ~5s
      if now - log_emit_at >= 5
        oldest_age = oldest_ts ? (now - oldest_ts).round(1) : nil
        warn "[pulse] counter=#{counter} in_flight=#{in_flight} " \
             "oldest_age=#{oldest_age || 'nil'}s alive=#{alive}"
        log_emit_at = now
      end

      last_counter = counter
      sleep 2
    end
  rescue StandardError => e
    FATAL_FLAG.set = true
    FATAL_FLAG.error = e
    warn "[pulse] #{e.class}: #{e.message}"
  end
end
```

**最古 ts 判定**: `oldest_ts = ts_values.min`。in_flight==0 なら nil。in_flight > 0 で oldest_ts があれば 360s 閾値で判定。

**`in_flight > 0 && oldest_ts.nil?`** は理論上ありえない (ts_by_thread.values.size == in_flight)。defensive: alive=true で transient race として通過 (snapshot の atomic 性で実際は到達不能だが防御的)。

### 3. heartbeat 自己 mask は維持 (dual guarantee)

v0.1 で提案した unconditional touch は撤回。`heartbeat_thread` は現行実装のまま:

```ruby
# unchanged from current implementation
heartbeat_thread = Thread.new do
  loop do
    last_tick = (File.mtime(PS.worker_tick_path(token)) rescue nil)
    if last_tick && (Time.now - last_tick) < 30
      FileUtils.touch(PS.worker_heartbeat_path(token))
    end
    sleep 2
  end
end
```

**Why 維持**: 
- pulse race fix が完璧でなくても heartbeat 自己 mask が二重防御として機能 (CLAUDE.md proposition #3 dual guarantee)
- main thread wedge 検出は heartbeat 自己 mask に依存 (zombie 検出能力)
- v0.1 の bootstrap problem (修正したばかりの fix を信頼して safety net を外す) を回避

### 4. CRASH_REASONS 定数化 (Operations P1)

```ruby
# wait_for_worker.rb header に追加
module WaitForWorker
  # All possible :crashed outcome reasons. Operators grep for these in logs
  # and metrics. Adding a new reason requires updating this list and the
  # tool description's enum.
  CRASH_REASONS = %w[
    heartbeat_stale
    heartbeat_never_started
    worker_never_started
    done_but_no_results
    crashed
    self_timed_out
    wait_exhausted
    internal_error
    malformed_state
  ].freeze
  ...
end
```

実際の使用箇所では既存文字列リテラルをそのまま残す (定数参照に置き換えるのは v3.24.4 での文字列ハードコード解消 PR で実施)。本 patch では**列挙の単一の真実源**として frozen array を提供するのみ。

### Worker shutdown 順序 (不変条件、文書化)

```
1. write_subprocess_results(token, payload)        [must succeed for 'done']
2. transition_to_terminal!('done')                 [atomic state.json rename]
3. exit 0
4. ensure: kill threads (pulse, heartbeat, log_rotator, watchdog)
```

step 1 失敗 → rescue → transition 'crashed' (既存)。state == 'done' を観測した瞬間、heartbeat はまだ touch 中もしくは直前 fresh。

### atomic_write_json tempfile 配置 (Concurrency persona P2)

`PendingState.atomic_write_json` を確認: tempfile を **target と同一ディレクトリ** に作成すること。すでにそうなっているなら nothing to do、別 FS なら修正必要。本 patch で確認のみ実施 (修正必要なら本 patch に含める)。

## scope (厳格化)

### 含まれる
- `lib/multi_llm_review/main_state.rb` (per-thread ts + Mutex)
- `bin/dispatch_worker.rb` (pulse_thread snapshot 3-tuple + 診断ログ)
- `lib/multi_llm_review/wait_for_worker.rb` (CRASH_REASONS 定数のみ追加、ロジック変更なし)
- テスト
- バージョン bump 3.24.2 → 3.24.3
- `PendingState.atomic_write_json` の tempfile 配置確認 (必要なら修正)

### 含まれない (v3.24.4 で別 PR)
- Wait Defense A (heartbeat_stale 返却前の re-check)
- Wait Defense B (TERMINAL_STATUSES 統合)
- Wait Defense C (load_state nil retry)
- Wait Defense D (waited_seconds 伝播)
- Wait Defense E (done_but_no_results next_action 区別)
- 文字列ハードコード → CRASH_REASONS 定数置換
- heartbeat semantics 再設計

**Why split**: 
- worker pulse fix が真の root cause、これだけで incident は再発しない
- defense items は worker fix の独立検証後にレビューしたい
- 一度に複雑度を上げると検証が難しい (v0.4→v0.5 の教訓)

## テスト戦略

### 削除
- `test_done_with_results_returns_ready` (v3.24.2 で追加した、step 1 で先に return するため patch を検証していないテスト)

### 新規
1. **`test_main_state.rb`**: 
   - 単一 thread enter/exit cycle で counter / ts_by_thread 整合性
   - 4 thread parallel enter/exit、各 thread が独自 ts を持つこと
   - T1 exit 後 T2 still-in-call で oldest_ts == T2 のものになること (Concurrency P1 検証)
   - 1000 iteration concurrency stress (4 thread × 250 cycles each, 各 enter/exit pair で size 整合性)、固定 srand、wall-clock <5s
   - reset! の clear 確認
2. **`test_pulse_thread_alive.rb`** (簡易 unit、worker fork なし): 
   - mock MainState で alive 判定の 4 分岐 (counter advanced / in-flight recent / in-flight no ts / idle) をテーブル駆動
3. **`test_dispatcher_pulse_integration.rb`** (stub LLM): 
   - 4 reviewer × stub adapter (sleep 30/70/120/130s 模擬) で実 worker fork、tick が完了直前まで touch 続くことを確認
   - stub adapter は固定 sleep 値で reviewers 間 race を再現 (real LLM 不使用、CI 安定性確保)
   - 受入基準 "tick が完了直前まで touch" の自動検証

### 既存維持
- 24 既存テスト全 pass (v3.24.2 の `test_done_with_stale_heartbeat_does_not_false_positive_crash` 含む)

合計: 24 既存 - 1 削除 + 3 ファイル (≥10 cases) = 33+ tests

### incident 再現性 (受入基準)

token `5b75ff8c-...` のような場面を stub で再現:
- 4 reviewer の sleep 分布 = (16, 73, 126, 133) seconds (実観測値)
- pulse_thread が 全 reviewer 完了直前 (≤ 5s 前) まで tick touch 続けること
- heartbeat 自己 mask が tick 維持中は隔靴掻痒なく heartbeat も touch 続けること

## 後方互換性

- `MainState.snapshot` 戻り値: 2-tuple → 3-tuple
  - **唯一の caller**: `bin/dispatch_worker.rb:118` の pulse_thread (verified by grep)
  - 同 patch で同時更新
  - 外部 caller なし (test_main_state.rb は新規追加)
- 公開 API (MCP tool) 変更なし
- state.json schema 変更なし
- `CRASH_REASONS` 追加は additive、既存挙動変化なし
- Rollback: `gem install kairos-chain --version 3.24.2` で可。in-flight workers が v3.24.3 で走行中の場合、downgrade 後の再起動で旧 worker は terminate されるため drain 不要 (worker process は session-scoped)

## 受入基準

- [ ] 全 33+ tests pass (24 既存 - 1 + 10+ 新規)
- [ ] `test_dispatcher_pulse_integration.rb` で stub 4-reviewer 走行中、tick が完了 5s 前まで touch 続く
- [ ] incident token (5b75ff8c) と同等の sleep 分布で再現できないこと (heartbeat_stale が出ない)
- [ ] grep `MainState.snapshot` で caller が dispatch_worker.rb のみであること再確認
- [ ] `[pulse] counter=N in_flight=M oldest_age=Ks alive=...` ログが worker.log に 5s 周期で出ること
- [ ] gem build + install + 簡易 multi_llm_review 実走行で v3.24.3 が読まれること

## v3.24.4 で扱う項目 (本 patch スコープ外)

| 項目 | 出元 |
|------|------|
| Wait Defense A (re-check before crashed) | v3.24.2 失敗 incident, Operations P1 |
| Wait Defense B (TERMINAL_STATUSES) | Minimal-fix P1 |
| Wait Defense C (load_state nil retry) | Concurrency P1 (v3.24.2 review) |
| Wait Defense D (waited_seconds) | cursor_composer2 P2 |
| Wait Defense E (done_but_no_results next_action) | Minimal-fix P1 |
| done_but_no_results forensic detail (path, size, parse error) | Operations P1 |
| heartbeat semantics 再設計 (wait 側 tick check 等) | Concurrency P1 |
| metrics jsonl (`_metrics.jsonl`) | Operations P2 |
| CRASH_REASONS 定数の使用箇所置換 | Operations P1 (本 patch では宣言のみ) |
| `test_pending_state_v3.rb` の atomic_write tempfile 配置検証 | Concurrency P2 |

## 参考

- v0.1 設計: `docs/drafts/multi_llm_review_v3.24.3_design.md` (REVISE 3/3、本 v0.2 で supersede)
- v0.1 review (Path B persona team): 本 session 内で実行 (Concurrency / Minimal-fix / Operations 3名)
- 不発 incident: `.kairos/multi_llm_review/pending/5b75ff8c-5890-498b-b32d-0227c730fe21/`
- v3.24.2 patch: `KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/wait_for_worker.rb` (現行)
