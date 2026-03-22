# Review: Service Grant SkillSet Bugfixes (2 commits)

## Output

Save your review to: `log/service_grant_bugfix_review1_{your_llm_id}_20260322.md`

## Output Filenames

| Reviewer | Output filename |
|----------|----------------|
| Claude Agent Team | `log/service_grant_bugfix_review1_claude_team_opus4.6_20260322.md` |
| Cursor Composer-2 | `log/service_grant_bugfix_review1_cursor_composer2_20260322.md` |
| Cursor GPT-5.4 (manual) | `log/service_grant_bugfix_review1_cursor_gpt5.4_20260322.md` |

## Auto-Execution Commands

### Cursor Composer-2
```bash
agent -p --trust "Read the file log/service_grant_bugfix_review1_prompt_20260322.md in /Users/masa/forback/github/KairosChain_2026 and follow the review instructions. Save your review to log/service_grant_bugfix_review1_cursor_composer2_20260322.md" > /dev/null 2>&1
```

### Cursor GPT-5.4 (manual)
```bash
agent --model gpt-5.4-high -p "Read the file log/service_grant_bugfix_review1_prompt_20260322.md in /Users/masa/forback/github/KairosChain_2026 and follow the review instructions. Save your review to log/service_grant_bugfix_review1_cursor_gpt5.4_20260322.md"
```

---

## Review Instructions

You are reviewing 2 bugfix commits on the `main` branch of KairosChain's Service Grant SkillSet.

### Commit 1: AccessGate owner bypass

**File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/access_gate.rb`

**Problem**: Admin tokens created by `--init-admin` lack `pubkey_hash` (they are system management tokens, not service consumers). The AccessGate blocked ALL MCP tool calls in HTTP mode with "pubkey_hash missing from auth context" when using the admin token.

**Fix**: Added `return if user_ctx[:role] == 'owner'` before the pubkey_hash check (line 25). This allows owner-role tokens to bypass Service Grant access control, consistent with the existing `local_dev` bypass on line 24.

**Design rationale**: Admin/owner tokens are for system management, not service consumption. Service Grant controls service consumption quotas (deposit_skill, acquire_skill, etc.) — these should not apply to the system administrator.

### Commit 2: GrantManager record_with_retry kwargs bug

**File**: `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/grant_manager.rb`

**Problem**: `record_grant_event` (line 179-185) passed keyword arguments directly to `record_with_retry(event, attempt: 0)` (line 190). Ruby interprets the bare kwargs as keyword args to `record_with_retry` itself, leaving the `event` positional parameter empty. This caused `ArgumentError: wrong number of arguments (given 0, expected 1)` and resulted in 500 errors on Place API endpoints when Service Grant middleware called `ensure_grant`.

**Fix**: Wrapped the hash literal in explicit braces `{}` (line 180):

Before:
```ruby
record_with_retry(
  type: 'service_grant_event', ...
)
```

After:
```ruby
record_with_retry({
  type: 'service_grant_event', ...
})
```

### Your Task

1. Read both modified files completely
2. Verify each fix is correct and minimal
3. Check for:
   - **Security**: Does the owner bypass introduce any privilege escalation risk?
   - **Completeness**: Are there other callers of `record_with_retry` with the same kwargs bug?
   - **Edge cases**: What happens if `user_ctx[:role]` is manipulated? Is the role set by trusted code only?
   - **Consistency**: Does the owner bypass pattern match existing patterns in the codebase?
4. Check for any new issues introduced

### Context Files (read these for full understanding)

1. `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/access_gate.rb`
2. `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/grant_manager.rb`
3. `KairosChain_mcp_server/lib/kairos_mcp/auth/token_store.rb` (how tokens and roles are created)
4. `KairosChain_mcp_server/lib/kairos_mcp/auth/authenticator.rb` (how user_context is built)
5. `KairosChain_mcp_server/templates/skillsets/service_grant/lib/service_grant/place_middleware.rb` (Place API middleware that calls ensure_grant)

### Severity Ratings

- **BLOCKER**: Must fix before merge
- **HIGH**: Should fix before merge
- **MEDIUM**: Fix after merge
- **LOW**: Nice to have

### Output Format

```markdown
# Review: Service Grant Bugfixes

- **Reviewer**: [your tool name]
- **Model**: [model ID]
- **Date**: 2026-03-22
- **Mode**: auto | manual

## Verdict: APPROVE | CONDITIONAL APPROVE | REJECT

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| AccessGate owner bypass | PASS/FAIL | ... |
| record_with_retry kwargs | PASS/FAIL | ... |

## New Findings (if any)

### [SEVERITY] Finding Title
- **File**: path/to/file:line
- **Description**: ...
- **Recommendation**: ...

## Summary

Overall assessment (2-3 sentences).
```
