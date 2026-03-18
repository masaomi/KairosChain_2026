# Autonomos SkillSet Cross-Review Implementation Log — Round 5

**Date**: 2026-03-18
**Branch**: `feature/autonomos-skillset`
**Commit**: `b47a46a`
**Tests**: 90 runs, 203 assertions, 0 failures

## Review Input

Three independent LLM reviews of Round 4 implementation:
1. **Claude Opus 4.6** — 4-persona agent team + Persona Assembly → **No blocker**
2. **Codex/GPT-5.4** — 3-agent team + local reproduction → **Blocker: checkpoint resume re-pause**
3. **Cursor Premium** — Agent-team + Persona Assembly → **Conditional blocker: storage_path**

## Consensus Blockers (Round 5)

### Blocker 1: Checkpoint resume re-pause (Codex — locally reproduced)

**Root cause**: When resuming from `paused_at_checkpoint` via `cycle_complete`, the `already_recorded` guard skips `record_cycle` (correct), but `checkpoint_due?` re-evaluates immediately with the same `cycles_completed` value. Since `cycles_completed % checkpoint_every == 0` is still true, the loop pauses again at the same checkpoint. Result: infinite pause loop — the documented continue path is non-functional.

**Fix** (autonomos_loop.rb:195-247):
```ruby
# Track whether we are resuming from a checkpoint/risk pause
resuming_from_pause = %w[paused_at_checkpoint paused_risk_exceeded].include?(mandate[:status])

# ... reflection and record_cycle logic ...

# Check for checkpoint — skip if we just resumed from one
unless resuming_from_pause
  if ::Autonomos::Mandate.checkpoint_due?(mandate)
    return pause_at_checkpoint(mandate_id, mandate)
  end
end
```

The `resuming_from_pause` flag is captured before status changes to `active`, ensuring that checkpoint evaluation is skipped exactly once after resume.

### Blocker 2: storage_path uses nonexistent `kairos_dir` (Cursor)

**Root cause**: `Autonomos.storage_path` called `KairosMcp.kairos_dir` but the real API is `KairosMcp.data_dir`. Since `respond_to?(:kairos_dir)` always returned false, the fallback `Dir.pwd/.kairos` was always used. This works accidentally in typical setups but breaks when `KAIROS_DATA_DIR` or `--data-dir` is configured.

**Fix** (lib/autonomos.rb:69-70):
```ruby
base = if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
           File.join(KairosMcp.data_dir, 'autonomos', subdir)
```

**review_discipline applied**: Same-pattern scan found `kairos_dir` also defined in test mock (`test_autonomos.rb:17`), updated to `data_dir`.

## Should Fix (4 items)

### 3. Loop-detected orphan cycle (autonomos_loop.rb:313-326)

**Before**: `last_cycle_id` and `recent_gap_descriptions` were updated AFTER loop detection, so `terminate_loop` used stale mandate state and the final cycle was invisible from the mandate.

**After**: Mandate update (last_cycle_id, recent_gaps) moved BEFORE loop detection check. `terminate_loop` now sees correct mandate state including the cycle that triggered detection.

```ruby
# Update mandate with current cycle info BEFORE loop detection
mandate[:last_cycle_id] = cycle_id
mandate[:recent_gap_descriptions] = recent_gaps_updated
::Autonomos::Mandate.save(mandate_id, mandate)

# Loop detection (3-step lookback)
if ::Autonomos::Mandate.loop_detected?(proposal, recent_gaps)
  return terminate_loop(mandate_id, mandate, 'loop_detected')
end
```

### 4. paused_goal_drift unsaved cycle_id (autonomos_loop.rb:281)

Removed `cycle_id: cycle_id` from goal_drift response. The cycle was never saved to CycleStore at this point, so returning its ID was misleading.

### 5. nil last_cycle_id guard (autonomos_loop.rb:216)

Wrapped `record_cycle` call in `if cycle_id_to_reflect` check. Prevents recording a nil-keyed entry in `cycle_history` when `last_cycle_id` is unset.

### 6. Guide Known Limitations update (autonomos_guide.md:250-253)

Updated loop detection description from "string equality" to "number-normalized string comparison" reflecting the Round 4 `gsub(/\d+/, 'N')` fix. Removed orphaned cycle limitation (now fixed).

## Test Changes

### Modified
- `test_cycle_complete_skipped_advances_state` → `test_cycle_complete_skipped_with_no_prior_cycle`: Updated expectation — when `last_cycle_id` is nil, no cycle should be recorded (cycles_completed stays 0).

### Added
- `TestAutonomosCheckpointResume#test_checkpoint_resume_does_not_re_pause`: Creates a mandate with checkpoint_every=1, simulates 1 completed cycle + pause, then calls `cycle_complete` with feedback. Asserts result status is NOT `paused_at_checkpoint`.

### Same-pattern scan (review_discipline)
- `kairos_dir` in test mock caught and updated to `data_dir` (test_autonomos.rb:17)

## Diff Summary

```
4 files changed, 91 insertions(+), 33 deletions(-)
```

| File | Changes |
|------|---------|
| `lib/autonomos.rb` | storage_path: kairos_dir → data_dir |
| `tools/autonomos_loop.rb` | checkpoint resume fix, orphan cycle fix, goal_drift cycle_id removal, nil guard |
| `knowledge/autonomos_guide/autonomos_guide.md` | Known Limitations loop detection description |
| `test/test_autonomos.rb` | data_dir mock, checkpoint resume test, skipped-cycle test fix |

## Blocker Evolution (Rounds 1-5)

```
Round 1: ████████████████████  設計アーキテクチャ (5+ findings, BLOCKER)
Round 2: ████████████████     契約開示 (guide vs 実装, BLOCKER)
Round 3: ████████████         API存在 (load_context nonexistent, BLOCKER)
Round 4: ████████             API応答 (save_context return unchecked, BLOCKER)
Round 5: ██████               ワークフロー (checkpoint resume + storage_path, BLOCKER)
```

Note: Round 5 Claude team found no blockers (4/4 personas agreed). The two blockers were found by Codex (with local reproduction) and Cursor. This demonstrates the continued value of multi-LLM review triangulation.

## Items Deferred to v0.2

| Item | Rationale |
|------|-----------|
| Chain recording failure → intermediate state | State machine change, scope exceeds v0.1 |
| Mandate file locking | Single-terminal scope, documented |
| L1 promotion quality criteria | Human judges final promotion |
| `some` keyword too broad in regex | Edge case, non-blocker |
| release_lock exception swallowing | Defensive improvement |
| Mandate.load JSON::ParserError guard | Robustness |
| Loop detection whitespace normalization | Post-merge hardening |
| multiuser user_context propagation | v0.2 scope |
| Orient phase hardcoded same-pattern scan | v0.2 immune system |
| Multi-LLM review SkillSet | v0.3, MCP meeting |
