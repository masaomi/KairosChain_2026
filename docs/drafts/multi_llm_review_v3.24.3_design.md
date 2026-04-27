---
name: multi_llm_review_v3.24.3_design
description: Worker pulse race fix + wait defense in depth + persona-feedback応答
type: design_draft
status: proposed
date: 2026-04-27
version: "3.24.3"
supersedes: multi_llm_review_v3.24.2 (incomplete fix)
---

# multi_llm_review v3.24.3 設計：pulse race 完全修正 + wait defense

## v3.24.2 の不足

v3.24.2 は wait 側に `state == 'done'` 分岐を追加したが、**実際の incident は再現した**。post-mortem (token `5b75ff8c-...`):

```
10:08:15  state.json created  (subprocess_status: pending)
10:09:42  worker.tick last touched      ← pulse_thread が touch を停止
10:10:10  worker.heartbeat last touched ← heartbeat が tick stale 検知で自己 mask
10:10:28  state → 'done', results written
                          ↑ wait は 10:10:10〜10:10:28 の 18秒間 pending かつ heartbeat stale を観測
```

つまり真の root cause は wait 側ではなく **worker 側 pulse_thread の早期停止**。

## Root cause: MAIN_STATE process-global race

`MainState` (`lib/multi_llm_review/main_state.rb`) は process-global な `Struct.new(:counter, :in_llm_call_since_mono)`:

- `enter_call!`: `ts = Process.clock_gettime(MONOTONIC)` を**上書き**
- `exit_call!`: `counter += 1`、続いて `ts = nil`

Dispatcher は parallel threads (`Thread.new` × N reviewers) で各 thread が `enter_call!`/`exit_call!` を呼ぶ。Race scenario:

```
T1.enter  → ts = t1
T2.enter  → ts = t2  (T1 上書き)
T1.exit   → counter += 1, ts = nil   ← T2 still in call!
[long]
pulse snapshot → (counter=N, ts=nil)
                 → counter unchanged from last_counter
                 → ts nil → alive=false
                 → tick NOT touched
30s 後: heartbeat_thread が tick stale を見て heartbeat も停止
15s 後: wait が heartbeat_stale を crash 判定
```

実観測 (10:09:42 停止) と整合: 4 reviewer のうち cursor (+73s) が最初に終わって T2 のような状況 (claude_cli 126s + codex_gpt5.4 133s 残存) を作り、その後 pulse が dead 判定。

## 修正方針

### Worker 側: pulse race 解消 (真の root cause、必須)

**Option A (採用): in-flight call counter** — `in_llm_call_since_mono` を thread-local 化、または「in-flight count + 最古 enter ts」で管理

```ruby
# main_state.rb 改訂版
MAIN_STATE = Struct.new(:counter, :in_flight, :oldest_in_flight_ts).new(0, 0, nil)
MUTEX = Mutex.new

def enter_call!
  MUTEX.synchronize do
    MAIN_STATE.in_flight += 1
    MAIN_STATE.oldest_in_flight_ts ||= Process.clock_gettime(MONOTONIC)
  end
end

def exit_call!
  MUTEX.synchronize do
    MAIN_STATE.counter += 1
    MAIN_STATE.in_flight -= 1
    MAIN_STATE.oldest_in_flight_ts = nil if MAIN_STATE.in_flight == 0
    # else: keep ts (oldest still pending). Phase 2 enhancement: track per-thread ts and recompute oldest on exit.
  end
end

def snapshot
  MUTEX.synchronize do
    [MAIN_STATE.counter, MAIN_STATE.in_flight, MAIN_STATE.oldest_in_flight_ts]
  end
end
```

Pulse thread:
```ruby
counter, in_flight, oldest_ts = MainState.snapshot
alive =
  if counter != last_counter
    true                                                   # progress observed
  elsif in_flight > 0 && oldest_ts
    (Process.clock_gettime(MONOTONIC) - oldest_ts) < 360   # in-call, recent
  elsif in_flight > 0
    true                                                   # in-call but ts not set yet (just-entered race)
  else
    false                                                  # idle, no progress
  end
```

**互換性**: 旧 `MainState.snapshot` は 2-tuple を返した。新仕様は 3-tuple。dispatch_worker.rb の pulse_thread (`counter, ts = ...`) を 3-tuple 受けに変更する。

**Why MUTEX**: MRI GVL は単一フィールドの read/write を atomic にするが、複合操作 (`in_flight += 1; ts ||= ...`) は torn read 可能。Mutex で 1 critical section に。pulse の snapshot 側も同 mutex で読むことで一貫性確保。性能影響: enter/exit は LLM call 当たり 1 回 (数十秒〜数分) なので mutex 取得コストは無視可能。

**`oldest_in_flight_ts` 簡略化**: in_flight==0 の時のみ ts=nil にする。in_flight>0 で別 thread が exit してもそのまま (もう少し新しい ts でもよいが pulse の `<360s` 判定には影響しない)。Phase 2 で per-thread ts に拡張可能。

### Worker 側: heartbeat 自己 mask 撤廃 (defense in depth)

現行 `heartbeat_thread` は `tick stale (>30s) ⇒ heartbeat 更新停止` で自己 mask する。pulse race 修正後はこの mask 自体不要 (pulse が正しく tick を更新するから)。だが**二重防御として削除**する: 

```ruby
# Before
heartbeat_thread = Thread.new do
  loop do
    last_tick = (File.mtime(...) rescue nil)
    if last_tick && (Time.now - last_tick) < 30
      FileUtils.touch(heartbeat_path)
    end
    sleep 2
  end
end

# After: heartbeat は無条件 touch。worker exit で ensure block が kill するので zombie heartbeat は発生しない
heartbeat_thread = Thread.new do
  loop do
    FileUtils.touch(heartbeat_path)
    sleep 2
  end
end
```

**zombie heartbeat 懸念**: worker process が main thread wedge で生きているが進捗ゼロの場合、heartbeat は touch 続ける → wait は alive 判定 → 永久 hang? **対処**: pulse mechanism (tick) は zombie 検出に必要なので残す。wait tool 側で **tick** も併せて見ることで二重検証可能 (Phase 2)。Phase 1 では tick は worker 内の自己診断用、wait は heartbeat のみ依存に簡略化。

### Wait 側: defense in depth (persona feedback 応答)

#### A. heartbeat_stale 返却前の re-check (必須)

WaitForWorker.wait の step 3 で heartbeat stale 検知時、**直前に results file と state を再読取**してから crashed 判定:

```ruby
elsif heartbeat_mtime
  age = Time.now - heartbeat_mtime
  age = 0 if age < 0
  if age > hb_stale
    # Defense in depth: re-check terminal signals before declaring crash.
    # Worker shutdown order is: write_results → state='done' → kill heartbeat,
    # so a stale heartbeat with results-on-disk or state==done means
    # successful completion, not crash.
    if File.exist?(PendingState.subprocess_results_path(token))
      data = PendingState.load_subprocess_results(token)
      return { status: :ready, results: data['results'], elapsed: data['elapsed_seconds'] } if data
    end
    state2 = PendingState.load_state(token)
    if state2 && state2['subprocess_status'] == 'done'
      sleep poll_interval; next  # let step 1 catch results on next iteration
    end
    return {
      status: :crashed, reason: 'heartbeat_stale',
      pid: pid_info&.dig('pid'), pgid: live_pgid(pid_info),
      heartbeat_age: age, log_tail: tail_log(token)
    }
  end
end
```

これにより worker pulse fix と独立して、wait 単独でも v3.24.2 で起きた失敗は再発しない。

#### B. TERMINAL_STATUSES 抽象化 (Minimal-fix persona P1)

`PendingState::TERMINAL_STATUSES` (既に存在: `%w[done crashed self_timed_out]`) を WaitForWorker でも使う。step 2 を統一:

```ruby
state = PendingState.load_state(token)
if state
  status = state['subprocess_status']
  case status
  when 'crashed', 'self_timed_out'
    return { status: :crashed, reason: state['crash_reason'] || status, ... }
  when 'done'
    if now_mono > deadline
      return { status: :crashed, reason: 'done_but_no_results', ... }
    end
    sleep poll_interval; next
  end
end
```

将来 `'cancelled'` 等を追加する場合は明示的にハンドル必須。

#### C. load_state nil 時 transient retry (Concurrency persona P1)

state.json が rename 中で `load_state` が nil を返すケース。現行は step 3 (heartbeat) に落下。修正後: nil retry を 1 回挟む。

```ruby
state = PendingState.load_state(token) || (sleep 0.05; PendingState.load_state(token))
```

50ms の sleep は rename(2) の lockless atomic 完了を待つ実用値。

#### D. elapsed propagation (cursor_composer2 P2)

WaitForWorker の `:crashed` / `:timeout` outcome に `waited_seconds: now_mono - first_poll` を追加。translate_outcome は既に `outcome[:waited_seconds]` を読む実装なので変更不要。

#### E. `done_but_no_results` の next_action 区別 (Minimal-fix persona P1)

現行は redispatch ("Re-run multi_llm_review") を案内。worker が成功したのに results 不読の場合、再実行は同じ結果になる可能性が高い → 別経路を案内:

```ruby
when :crashed
  reset_streak(token)
  if outcome[:reason] == 'done_but_no_results'
    return reply('crashed', token, elapsed,
      crashed_reason: outcome[:reason],
      subprocess_total: subprocess_total,
      next_action: {
        'tool' => 'multi_llm_review_collect',  # 直接 collect を試す (results が disk にあれば回収可)
        'args' => { 'collect_token' => token, 'orchestrator_reviews' => '<persona findings>' },
        'purpose' => 'Worker reported done but results unloadable from wait. ' \
                     'Try collect directly (subprocess_results.json may still be readable). ' \
                     'If collect fails, inspect worker.log before redispatch.'
      })
  end
  ... (default: redispatch)
```

### テスト戦略

#### 削除
- `test_done_with_results_returns_ready` (Test persona P0: step 1 で先に return するため patch を検証していない)

#### 新規追加
1. **MainState parallel race test** (`test_main_state.rb`): 4 thread で enter/exit を交互実行、`oldest_in_flight_ts` が in_flight==0 でのみ nil になることを検証。1000 iteration の concurrency stress
2. **Heartbeat unconditional touch test** (`test_worker_heartbeat.rb`): tick が stale でも heartbeat が touch され続けることを観測 (worker fork で実 process 起動)
3. **Wait re-check before crashed test** (`test_multi_llm_review_wait.rb`): heartbeat stale + results file present → ready 返却 (新 defense)
4. **Wait re-check before crashed (state=done variant)**: heartbeat stale + state=done + no results → 1回 retry してから次 iteration へ
5. **Mid-poll race test**: state=done + results 後出し (poll loop 中で出現) → ready 返却
6. **load_state nil retry test**: state.json mid-rename simulation (file unlink + immediate rewrite) で wait が transient扱い
7. **done_but_no_results next_action test**: redispatch ではなく collect を案内

#### 既存維持
- `test_done_with_stale_heartbeat_does_not_false_positive_crash` は維持 (defense Aで強化された動作を検証)
- 全 24 既存テスト pass 必須

### Worker shutdown 順序の不変条件 (文書化)

dispatch_worker.rb 末尾の shutdown は以下を**固定**:

```
1. write_subprocess_results(token, payload)        [must succeed for 'done']
2. transition_to_terminal!('done')                 [atomic state.json rename]
3. exit 0
4. ensure: kill threads (pulse, heartbeat, log_rotator, watchdog)
```

不変条件:
- step 1 失敗 → rescue が transition_to_terminal!('crashed') を呼ぶ → state は 'crashed' (これは既存挙動)
- step 1 成功 ⟹ step 2 成功 (atomic rename は MEM/disk の問題で稀に失敗するが、その時 worker は exit 1 → state は 'pending' のまま GC 対象)
- step 4 でしか thread kill しない → state.subprocess_status == 'done' を観測した瞬間、heartbeat は依然 touch 中 (まだ ensure に到達していない可能性) もしくは touch 直後の数秒以内 (mtime fresh)

これにより wait 側 defense A の「state==done なら sleep & retry」は 安全 (heartbeat も同じく fresh かやがて消える、いずれにしても results は揃う)。

### 影響範囲とバージョン

- **Worker**: `lib/multi_llm_review/main_state.rb` (Mutex + 3-tuple)、`bin/dispatch_worker.rb` (snapshot 3-tuple 対応 + heartbeat unconditional)
- **Wait**: `lib/multi_llm_review/wait_for_worker.rb` (TERMINAL_STATUSES 統合、re-check before crashed、load_state retry、waited_seconds 伝播)、`tools/multi_llm_review_wait.rb` (`done_but_no_results` の next_action 区別)
- **Tests**: 7 新規 + 1 削除
- **Version**: 3.24.2 → **3.24.3**

### 後方互換性

- `MainState.snapshot` の戻り値が 2-tuple → 3-tuple。**唯一の caller は dispatch_worker.rb の pulse_thread**。同時に修正 (atomic patch)
- 公開 API (MCP tool inputs/outputs) は変更なし
- 新 reason `'done_but_no_results'` は v3.24.2 で既に導入済み、next_action のみ変更
- state.json schema: 変更なし

## 受入基準 (実装フェーズの gate)

- [ ] 全 31 (24 既存 + 7 新規 - 1 削除) tests pass
- [ ] Real-process integration test: parallel 4-reviewer worker で tick が完了直前まで touch 続く (pulse race fix 検証)
- [ ] v3.24.2 不発の incident (token 5b75ff8c) と同等条件で wait が ready or done_but_no_results を返す (heartbeat_stale を返さない)
- [ ] 過去 multi_llm_review tests (24 + 関連 SkillSet tests) 全 pass

## 参考

- v3.24.2 patch: `KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/wait_for_worker.rb` (現状)
- 不発 incident: `.kairos/multi_llm_review/pending/5b75ff8c-5890-498b-b32d-0227c730fe21/`
- Persona reviews: 同 incident の `subprocess_results.json` (Path A 4本) + 本 session 内 (Path B 3本)
- 関連旧 fix: dispatcher.rb 113-126 行 "v0.3.1 meta-review bug #1" (counter bump in join loop) — 同種の race を別経路で対処した先行例
