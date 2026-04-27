---
name: multi_llm_review_v3.24.3_design
description: Worker pulse race fix v0.3 — with_call wrapper + alive 抽出 + caller 訂正 + ordering 不変条件
type: design_draft
status: proposed
date: 2026-04-27
version: "3.24.3"
supersedes: multi_llm_review_v3.24.3_design_v0.2
---

# multi_llm_review v3.24.3 設計 v0.3：詳細精度向上

## v0.2 → v0.3 の変更

v0.2 multi-LLM review (7 reviewer = Path A 4 + Path B 3) で **4 APPROVE / 3 REJECT**。R2 で実コードを参照した結果、設計書側に詳細レベルの誤り/欠落が判明:

| 指摘 | 出元 | severity | v0.3 対処 |
|------|------|----------|----------|
| `MainState.snapshot` caller 主張誤り (test_pending_state_v3.rb 等が caller) | cursor_composer2 | **P0** | scope に test 更新を追加、「唯一の caller」主張を削除 |
| `enter_call!`/`exit_call!` ensure 義務化 (exception で leak) | claude_cli, codex_gpt5.4, codex_gpt5.5 | **P1 ×3** | **`MainState.with_call { yield }` wrapper 新設**、enter/exit を private 化 |
| alive 判定の unit test 不可能性 (inline のまま) | codex_gpt5.5 | P1 | **`MainState.compute_alive(...)` として抽出** |
| post-LLM window で `in_flight=0 && counter unchanged` → alive=false | codex_gpt5.4 | P1 | v3.24.4 deferral 表に明記 (incident と独立 edge case) |
| snapshot ordering 不変条件の再記述漏れ | cursor_composer2 | P1 | main_state.rb ヘッダコメント記述案を設計に含める |
| warn → worker.log routing 未明記 | codex_gpt5.4 | P2 | "Why 安全" 節に明記 |
| atomic_write_json tempfile 同一ディレクトリ確認 | cursor_composer2 | (情報) | **実施済み確定** (pending_state.rb line 244-248) |

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

### 1. MainState: per-thread ts + with_call wrapper (P1 解消)

```ruby
# main_state.rb 改訂版
module KairosMcp
  module SkillSets
    module MultiLlmReview
      MAIN_STATE = Struct.new(:counter, :ts_by_thread).new(0, {})
      MUTEX = Mutex.new

      # ──────────────────────────────────────────────────────────────
      # MainState — main-thread liveness state for the worker pulse
      # ──────────────────────────────────────────────────────────────
      #
      # ORDERING / ATOMICITY INVARIANTS (v3.24.3):
      #
      # 1. ts_by_thread mutations and counter mutations are bracketed by
      #    a single Mutex critical section. Reads (snapshot) take the same
      #    mutex, so readers never observe a torn (counter, ts_by_thread)
      #    pair. Replaces the v0.3.2 "ts-first/counter-second" ordering
      #    invariant which assumed single-threaded callers.
      #
      # 2. with_call { ... } is the ONLY supported call-bracketing pattern.
      #    Direct enter_call!/exit_call! calls are private to this module
      #    (Ruby `private_class_method`). This guarantees that any
      #    exception from the LLM call propagates AFTER ts_by_thread has
      #    been cleaned up, preventing thread-local entry leaks.
      #
      # 3. Thread.current.object_id is used as the per-thread key. MRI's
      #    object_id stays stable for the lifetime of a Thread object;
      #    reuse only happens after the Thread has been GC'd. Within a
      #    single with_call invocation, the Thread is on-stack and
      #    therefore not GC-eligible, so the key is unique.
      #
      # 4. Mutex#synchronize is Thread.kill-safe (Ruby internal `ensure
      #    unlock`). The `ensure exit_call!` inside with_call also runs
      #    under Thread.kill, so the cleanup is guaranteed even if the
      #    dispatch thread is forcibly terminated.

      module MainState
        module_function

        # PUBLIC API: bracket an LLM call. Use this — DO NOT call
        # enter_call!/exit_call! directly. Returns the value of the block.
        def with_call
          enter_call!
          yield
        ensure
          exit_call!
        end

        # SNAPSHOT API: returns (counter, in_flight, oldest_ts).
        #   counter   — total number of completed exit_call!s since boot
        #   in_flight — current in-call thread count (== ts_by_thread.size)
        #   oldest_ts — oldest enter ts among in-call threads (nil if idle)
        def snapshot
          MUTEX.synchronize do
            ts_values = MAIN_STATE.ts_by_thread.values
            [MAIN_STATE.counter, ts_values.size, ts_values.min]
          end
        end

        # PURE FUNCTION (testable): determine alive state from a snapshot
        # tuple. Extracted so test_main_state_alive.rb can table-drive
        # the four branches without forking a worker. Pulse thread calls
        # this with the result of snapshot().
        #
        # @return [Boolean]
        def compute_alive(counter, last_counter, in_flight, oldest_ts, now_mono, threshold_seconds)
          if counter != last_counter
            true                                                  # progress observed
          elsif in_flight > 0 && oldest_ts
            (now_mono - oldest_ts) < threshold_seconds            # in-call, recent
          elsif in_flight > 0
            true                                                  # in-call but ts not set yet (transient)
          else
            false                                                 # idle, no progress
          end
        end

        # TEST API: clear all state. Not safe for runtime use.
        def reset!
          MUTEX.synchronize do
            MAIN_STATE.counter = 0
            MAIN_STATE.ts_by_thread.clear
          end
        end

        # ── private ──

        def enter_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.ts_by_thread[tid] =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
        private_class_method :enter_call!

        def exit_call!
          tid = Thread.current.object_id
          MUTEX.synchronize do
            MAIN_STATE.counter += 1
            MAIN_STATE.ts_by_thread.delete(tid)
          end
        end
        private_class_method :exit_call!
      end
    end
  end
end
```

### 2. Caller migration (P1 — ensure 義務化)

#### 2.1 llm_client/headless.rb

```ruby
# Before (v3.24.2):
KairosMcp::SkillSets::MultiLlmReview::MainState.enter_call!
result = adapter.call(...)
KairosMcp::SkillSets::MultiLlmReview::MainState.exit_call!

# After (v3.24.3):
result = KairosMcp::SkillSets::MultiLlmReview::MainState.with_call do
  adapter.call(...)
end
```

`with_call` は `ensure` で `exit_call!` を保証 → exception/Thread.kill でも leak なし。

注: 既存実装が `ensure exit_call!` パターンを使っているかは確認必要 (v0.2 review で「ensure があるとは保証されていない」と指摘)。**実装フェーズで `enter_call!`/`exit_call!` の全 caller を grep し、`with_call` への置換 PR を本 patch に含める**。

#### 2.2 dispatcher.rb の bump_main_state_counter

dispatcher.rb の `bump_main_state_counter` (line 133-) は `MainState` を介してではなく直接 counter を bump する path。仕様変更後は:

```ruby
def bump_main_state_counter
  return unless defined?(KairosMcp::SkillSets::MultiLlmReview::MainState)
  # exit_call! is now private. Use a public bump_counter! method instead.
  KairosMcp::SkillSets::MultiLlmReview::MainState.bump_counter!
end
```

`MainState.bump_counter!` を新設 (counter のみ +1、ts_by_thread は触らない、join 待ちでの "alive but no LLM call in flight" 状態を表現する用途):

```ruby
def bump_counter!
  MUTEX.synchronize { MAIN_STATE.counter += 1 }
end
```

これで join loop 中も counter が advance し pulse が alive 判定継続。

### 3. Pulse thread: compute_alive 利用 + 診断ログ

```ruby
# dispatch_worker.rb pulse_thread 改訂版
pulse_thread = Thread.new do
  begin
    last_counter = -1
    log_emit_at = 0
    threshold = 360  # max_call_t (300) + call_margin (60)
    loop do
      counter, in_flight, oldest_ts = MLR::MainState.snapshot
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      alive = MLR::MainState.compute_alive(
        counter, last_counter, in_flight, oldest_ts, now, threshold
      )
      FileUtils.touch(PS.worker_tick_path(token)) if alive

      # Diagnostic log (Operations persona P1): emit ~ every 5s
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

**warn → worker.log routing** (codex_gpt5.4 P2): worker boot 早期に `STDERR.reopen(worker_log_path)` が `log_rotator_thread` 起動前に走っている (dispatch_worker.rb の log redirect セクション、要確認)。`warn` は STDERR に書き、STDERR は worker.log にリダイレクト済み。実装フェーズで明示確認。

### 4. heartbeat 自己 mask は維持 (dual guarantee、v0.2 から変更なし)

```ruby
# unchanged
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

### 5. CRASH_REASONS 定数化 (v0.2 から変更なし)

```ruby
module WaitForWorker
  CRASH_REASONS = %w[
    heartbeat_stale heartbeat_never_started worker_never_started
    done_but_no_results crashed self_timed_out
    wait_exhausted internal_error malformed_state
  ].freeze
end
```

### 6. atomic_write_json tempfile 配置 (確認結果)

v0.2 で「確認のみ実施」としていた件、**確認済み・問題なし**:

```ruby
# pending_state.rb:244-249 (現行コード)
def atomic_write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
  ...
  File.rename(tmp, path)
end
```

`tmp` は `path` と同じパス + サフィックス → 同一ディレクトリ → 同一 FS → `rename(2)` atomic 保証。修正不要。本確認結果を v3.24.3 PR description にも記載 (operational discipline)。

### 7. test_pending_state_v3.rb 更新 (P0 解消)

cursor 指摘により、`MainState.snapshot` の caller は dispatch_worker.rb 以外に test も含まれることが判明。本 patch のスコープに追加:

```ruby
# test_pending_state_v3.rb (該当箇所、grep して全て更新)
# Before:
counter, ts = MainState.snapshot
# After:
counter, in_flight, oldest_ts = MainState.snapshot
```

実装フェーズで `grep -rn "MainState.snapshot\|MainState\.snapshot"` を全 codebase で実施し、全 caller を 3-tuple 受けに変更。

## scope (v0.3 改訂)

### 含まれる
- `lib/multi_llm_review/main_state.rb` (per-thread ts + Mutex + with_call wrapper + compute_alive 抽出 + bump_counter!)
- **全 caller の `with_call` 移行** (`llm_client/headless.rb` 等、grep で洗い出し)
- `bin/dispatch_worker.rb` (snapshot 3-tuple + compute_alive 利用 + 診断ログ)
- `lib/multi_llm_review/wait_for_worker.rb` (CRASH_REASONS 定数のみ追加)
- **`test_pending_state_v3.rb` 等の既存テスト 3-tuple 対応** (P0 解消)
- 新規テスト (test_main_state.rb, test_main_state_alive.rb, test_dispatcher_pulse_integration.rb)
- バージョン bump 3.24.2 → 3.24.3
- `PendingState.atomic_write_json` 確認結果を PR description に記載

### 含まれない (v3.24.4)
- Wait Defense A〜E
- post-LLM window (in_flight==0 + counter unchanged) の対策 (codex P1)
- 文字列 → CRASH_REASONS 定数置換
- heartbeat semantics 再設計
- metrics jsonl
- forensics CLI

**post-LLM window 説明** (codex P1 への応答): worker は dispatch 完了後、`write_subprocess_results` (ms 単位) → `transition_to_terminal!` (ms 単位) → exit。この区間 in_flight==0 + counter 不変なので alive=false → tick 停止。但し:
- 通常 5s 以内に exit → heartbeat 自己 mask threshold (30s) より十分短い
- 万一 disk slow 等で 30s 超 → heartbeat stale → wait crashed (まれ)
- v3.24.4 で `MainState.bump_counter!` を post-LLM phase に挿入して対処予定
- 本 patch では受入基準で「pulse race 由来の incident は再発しない」のみ保証 (incident とは別の edge case)

## テスト戦略

### 削除
- `test_done_with_results_returns_ready` (Test persona P0、step 1 で先 return するため patch 検証していない)

### 新規
1. **`test_main_state.rb`** (unit、worker fork なし):
   - `with_call` が正常終了で counter+1、ts_by_thread.delete
   - `with_call` が exception で counter+1、ts_by_thread.delete (ensure 検証、**P1 解消**)
   - 4 thread parallel `with_call`、各 thread が独自 ts を持つ
   - T1 exit 後 T2 still-in-call で oldest_ts == T2 のもの (Concurrency P1 検証)
   - 1000 iteration concurrency stress (4 thread × 250 cycles)、固定 srand、wall-clock <10s (Operations persona R2 P2 緩和)
   - `bump_counter!` が ts_by_thread を触らないこと
   - `enter_call!`/`exit_call!` が `private_class_method` であること (NoMethodError 検証)
   - `reset!` の clear 確認
2. **`test_main_state_alive.rb`** (unit、worker fork なし):
   - `compute_alive` の 4 分岐をテーブル駆動 (counter advanced / in-flight recent / in-flight no ts / idle)、threshold 境界含む 8+ ケース (codex_gpt5.5 P1 解消)
3. **`test_dispatcher_pulse_integration.rb`** (stub LLM、worker fork):
   - 4 reviewer × stub adapter、sleep 分布 = **incident 観測値 (16, 73, 126, 133)s** (claude_cli P2 修正)
   - tick が完了 5s 前まで touch 続くこと
   - `[pulse] ...` ログが出ていること
   - macOS CI flakey 対策: `RUBY_PLATFORM =~ /darwin/ && ENV['CI']` で 1 回 retry (Operations P2)

### 既存維持
- 全 24 既存テスト pass (`test_pending_state_v3.rb` の snapshot 呼び出しのみ修正、その他維持)

合計: 24 既存 (1 修正) - 1 削除 + 3 新規 (≥10 cases) ≈ 33 tests

## 後方互換性

- `MainState.snapshot` 戻り値: 2-tuple → 3-tuple
  - **caller**: `dispatch_worker.rb` の pulse_thread + `test_pending_state_v3.rb` (** v0.2 訂正**)
  - 全 caller を本 patch で同時更新
- `MainState.enter_call!` / `exit_call!` を private 化 → 外部から直接呼び出し不可
  - 全外部 caller を `with_call { yield }` に移行 (実装で grep 必須)
- 公開 MCP tool API 変更なし
- state.json schema 変更なし
- Rollback: `gem install kairos-chain --version 3.24.2`、worker process は session-scoped で drain 不要

## 受入基準 (v0.3 改訂)

- [ ] 全 33 tests pass (24 既存 - 1 + 3 新規ファイル ≥10 cases)
- [ ] `grep MainState.snapshot` で全 caller が 3-tuple 受け
- [ ] `grep MainState.enter_call!\|MainState.exit_call!` で外部 caller ゼロ (with_call 移行完了)
- [ ] `test_dispatcher_pulse_integration.rb` で stub 4-reviewer (sleep 16/73/126/133) 走行中、tick が完了 5s 前まで touch 続く
- [ ] `[pulse] counter=N in_flight=M oldest_age=Ks alive=...` ログが worker.log に 5s 周期で出ること
- [ ] gem build + install + 簡易 multi_llm_review 実走行で v3.24.3 が読まれること
- [ ] PR description に `atomic_write_json` 同一ディレクトリ確認結果記載

## v3.24.4 で扱う項目 (本 patch スコープ外、v0.3 で 1 項目追加)

| 項目 | 出元 |
|------|------|
| Wait Defense A (re-check before crashed) | v3.24.2 incident, Operations P1 |
| Wait Defense B (TERMINAL_STATUSES) | Minimal-fix P1 |
| Wait Defense C (load_state nil retry) | Concurrency P1 (v3.24.2 review) |
| Wait Defense D (waited_seconds) | cursor_composer2 P2 |
| Wait Defense E (done_but_no_results next_action) | Minimal-fix P1 |
| done_but_no_results forensic detail | Operations P1 |
| heartbeat semantics 再設計 | Concurrency P1 |
| metrics jsonl | Operations P2 |
| CRASH_REASONS 使用箇所置換 | Operations P1, codex_gpt5.4/5/cursor R2 |
| **post-LLM window: bump_counter! 挿入で in_flight==0 区間も alive 維持** | **codex_gpt5.4 R2 P1** |
| forensics CLI (`kairos-chain forensics save <token>`) | Operations P2 |

## 参考

- v0.2 設計: `docs/drafts/multi_llm_review_v3.24.3_design_v0.2.md` (4A/3R、本 v0.3 で supersede)
- v0.2 review (Path A 4 + Path B 3): subprocess は `.kairos/multi_llm_review/pending/06e0896e-657d-48c9-96ec-eed3e18213c6/subprocess_results.json`
- 不発 incident: `.kairos/multi_llm_review/pending/5b75ff8c-5890-498b-b32d-0227c730fe21/`
- v3.24.2 patch: `KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/wait_for_worker.rb`
