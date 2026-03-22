# Review: Service Grant Bugfixes

- **Reviewer**: Cursor GPT-5.4
- **Model**: gpt-5.4-high
- **Date**: 2026-03-22
- **Mode**: manual

## Verdict: APPROVE

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| AccessGate owner bypass | PASS | `access_gate.rb` now returns early for `user_ctx[:role] == 'owner'` before enforcing `pubkey_hash`. This is minimal, matches the existing `local_dev` bypass, and is consistent with the broader codebase pattern where owner is treated as a trusted administrator, including `multiuser/authorization_gate.rb`. |
| record_with_retry kwargs | PASS | `grant_manager.rb` now passes an explicit hash object to `record_with_retry`, which correctly satisfies the positional `event` parameter and removes the Ruby kwargs ambiguity that caused `ArgumentError`. I found no other `record_with_retry(` call sites with the same bug pattern. |

## New Findings (if any)

None.

## Summary

Both bugfixes are correct and appropriately scoped. The owner bypass does not introduce a new privilege-escalation path because `role` is populated from trusted token verification in `TokenStore#verify` / `Authenticator`, not from arbitrary request input, and the kwargs fix fully resolves the `record_grant_event` failure mode without broader behavioral changes.
