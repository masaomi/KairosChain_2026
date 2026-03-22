# Review: Service Grant Bugfixes

- **Reviewer**: Claude Code (Agent Team)
- **Model**: claude_team_opus4.6
- **Date**: 2026-03-22
- **Mode**: auto

## Verdict: APPROVE

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| AccessGate owner bypass | PASS | Correct, minimal, and secure. The `return if user_ctx[:role] == 'owner'` on line 25 is placed after the nil check (line 22) and the local_dev check (line 24), following the existing early-return pattern. Role originates from `TokenStore.verify` which reads server-side storage only -- no client-supplied role injection is possible. |
| record_with_retry kwargs | PASS | Correct fix. Without braces, Ruby parses `record_with_retry(type: ..., layer: ..., ...)` as keyword arguments to `record_with_retry` itself, leaving the positional `event` parameter unfilled. The explicit `{}` on line 180 forces Ruby to treat it as a Hash positional argument. The only caller of `record_with_retry` is `record_grant_event` (line 180), and the recursive retry call on line 199 already passes `event` as a local variable, so no other call sites are affected. |

## Security Analysis: Owner Bypass

**Role trust chain verified.** The `:role` field in `user_ctx` is set exclusively through trusted server-side code:

1. `TokenStore.verify` (token_store.rb:125-132) reads role from the server-side token store (JSON file, never client-supplied)
2. `Authenticator.authenticate!` (authenticator.rb:58-61) passes this through as `user_context`
3. `Safety.set_user` (safety.rb:50-51) stores it on the Safety instance
4. `AccessGate.call` reads it via `safety.current_user`

At no point can an HTTP client inject or override the `:role` value. The only way to obtain `role: 'owner'` is:
- Via `--init-admin` CLI command (system bootstrap)
- Via `token_manage` tool (which itself requires `can_manage_tokens?` authorization)
- Via the `local_dev: true` path (empty token store), which is already bypassed on line 24

The owner bypass is also consistent with the existing pattern in `admin/router.rb` (lines 75, 193) which gates admin operations on `user_info[:role] == 'owner'`.

## New Findings (if any)

### [LOW] Hardcoded fallback path in record_with_retry

- **File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/grant_manager.rb:205`
- **Description**: The failed recordings fallback writes to `'storage/failed_recordings.jsonl'` using a relative path. This will resolve relative to the process working directory, which may differ from the KairosChain workspace root. In HTTP server mode with a non-standard CWD, failed recordings could be written to an unexpected location or fail silently.
- **Recommendation**: Use an absolute path derived from the workspace root (e.g., `File.join(KairosMcp.workspace_root, 'storage', 'failed_recordings.jsonl')`). This is pre-existing and non-blocking.

### [LOW] Thread safety of retry mechanism

- **File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/grant_manager.rb:197-200`
- **Description**: `record_with_retry` spawns a new `Thread` for each retry attempt. If the chain is persistently down, multiple concurrent requests could spawn many retry threads (up to 3 threads per failed event * N concurrent requests). This is a pre-existing design acknowledged by the Phase 3 comment on line 189, but worth noting for operational awareness.
- **Recommendation**: No action needed now. The Phase 3 WAL-backed queue plan already addresses this.

## Summary

Both fixes are correct, minimal, and well-targeted. The owner bypass is secure because the role value is set exclusively by trusted server-side code (TokenStore -> Authenticator -> Safety), with no client-injectable path. The kwargs fix correctly addresses a Ruby parsing ambiguity that would cause ArgumentError on every chain recording call. No new blocking issues found; two pre-existing LOW-severity observations noted for future phases.
