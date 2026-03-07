# Multiuser SkillSet Implementation Log (Plan v3.1)

**Author:** Cursor Opus 4.6  
**Date:** 2026-03-07  
**Branch:** `feature/multiuser-skillset` (from `main` v2.7.0)  
**Plan:** `log/kairoschain_multiuser_skillset_plan3.1_cursor_opus4.6_20260307.md`  
**Commits:** 7 (d77352a → f3e3277)

---

## Summary

Plan v3.1 の Phase 0（6 Core Hooks + Provider user_context 対応）、Phase 1（Multiuser SkillSet 実装）、Phase 3 の一部（L1 knowledge + README 自動生成）を実装完了。Phase 2（Integration + Testing + Docker Compose）は未実施。PostgreSQL 非依存のローカルテストを全て通過し、グレースフルデグラデーション（PostgreSQL 未起動時の診断レポート出力）の動作を確認。

## Implementation Status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 0: 6 Core Hooks + Provider user_context | **Done** | 10 core files modified, all backward compatible |
| Phase 1: Multiuser SkillSet | **Done** | 15 new files + 11 tool call site updates |
| Phase 2: Integration + Testing | **Pending** | Requires PostgreSQL; Docker Compose not yet created |
| Phase 3: Documentation + Release | **Partial** | L1 knowledge (EN/JP) + README regeneration done; CHANGELOG + version bump pending |

## Additional Features (Beyond Plan)

| Feature | Commit | Description |
|---------|--------|-------------|
| `kairos-chain skillset upgrade` | 8656f30 | New CLI command to check/apply SkillSet updates from gem templates |
| Enhanced multiuser_status diagnostics | 8656f30 | 3-level diagnosis: `pg_gem_missing` / `pg_server_unavailable` / `pg_error` |
| `Multiuser.load!` auto-invocation | dde5d57 | Auto-call at require time so SkillSet loader triggers hook registration |

---

## Commit History

### d77352a — feat: Add Multiuser SkillSet with 6 generic core hooks

**Date:** 2026-03-07 07:21:57 +0100

Main implementation commit. Phase 0 (core hooks) + Phase 1 (SkillSet) in a single commit.

**Phase 0 — Core Hooks (10 files):**

| # | Hook | File | Change |
|---|------|------|--------|
| 1 | `Backend.register` | `storage/backend.rb` | Named registry + `create` factory (+21 lines) |
| 2 | `Safety.register_policy` | `safety.rb` | Named policies + 4 RBAC methods (+59 lines) |
| 3 | `ToolRegistry.register_gate` | `tool_registry.rb` | Named gates + `GateDeniedError` (+44 lines) |
| 4 | `Protocol.register_filter` | `protocol.rb` | Named filters + `apply_all_filters` (+35 lines) |
| 5 | `Auth::TokenStore.register` | `auth/token_store.rb` | Registry + `create` factory (+28 lines) |
| 6 | `KairosMcp.register_path_resolver` | `kairos_mcp.rb` | Tenant-aware `knowledge_dir` / `context_dir` (+47 lines) |
| — | HttpServer boot order | `http_server.rb` | `eager_load_skillsets` before `TokenStore.create` (Blocker 2) |
| — | Provider user_context | `knowledge_provider.rb`, `context_manager.rb`, `resource_registry.rb` | `user_context:` keyword arg (Blocker 3) |

**Phase 1 — Multiuser SkillSet (15 new files):**

| File | Purpose |
|------|---------|
| `skillset.json` | SkillSet metadata (name, version 0.1.0, layer L1) |
| `config/multiuser.yml` | PostgreSQL connection config template |
| `lib/multiuser.rb` | Entry point: `load!` registers 6 hooks, `unload!` for teardown |
| `lib/multiuser/pg_connection_pool.rb` | Mutex pool, `SET LOCAL`, `quote_ident`, schema validation |
| `lib/multiuser/pg_backend.rb` | `Storage::Backend` subclass for PostgreSQL |
| `lib/multiuser/tenant_manager.rb` | Schema CRUD + SQL migration runner |
| `lib/multiuser/user_registry.rb` | User CRUD + auto-tenant + blockchain recording |
| `lib/multiuser/tenant_token_store.rb` | PostgreSQL-backed `Auth::TokenStore` |
| `lib/multiuser/authorization_gate.rb` | Default-deny RBAC gate |
| `lib/multiuser/request_filter.rb` | Bearer token → tenant_schema resolution |
| `migrations/001_public_schema.sql` | Public schema (users, tokens, audit_log) |
| `migrations/002_tenant_template.sql` | Tenant schema (blocks, action_logs, knowledge_meta) |
| `tools/multiuser_status.rb` | Diagnostic status tool |
| `tools/multiuser_user_manage.rb` | User lifecycle tool (owner only) |
| `tools/multiuser_migrate.rb` | Migration runner tool (owner only) |

**Phase 1 — 11 Tool Call Site Updates:**

| File | Change |
|------|--------|
| `tools/knowledge_update.rb` | `user_context: @safety&.current_user` |
| `tools/knowledge_get.rb` | Same |
| `tools/knowledge_list.rb` | Same |
| `tools/context_save.rb` | Same |
| `tools/context_create_subdir.rb` | Same |
| `tools/resource_list.rb` | Same |
| `tools/resource_read.rb` | Same |
| `tools/skills_audit.rb` | All call sites |
| `tools/skills_promote.rb` | All call sites |
| `admin/router.rb` | All call sites |
| `state_commit/manifest_builder.rb` | All call sites |

### 8656f30 — feat: Add 'skillset upgrade' command and improve multiuser diagnostics

**Date:** 2026-03-07 12:07:57 +0100

- `kairos-chain skillset upgrade` — checks installed vs gem template, reports diff
- `kairos-chain skillset upgrade --apply` — applies updates (copies changed files)
- `skillset_manager.rb`: `upgrade_check` and `upgrade_apply` methods (+80 lines)
- `bin/kairos-chain`: CLI routing for new subcommand (+24 lines)
- `multiuser_status` error messages improved: granular 3-level diagnosis

### f1bb2e6 — fix: Use correct method name all_skillsets in upgrade_check

**Date:** 2026-03-07 12:09:27 +0100

Bug fix: `installed_skillsets` → `all_skillsets` (correct method name in `SkillSetManager`).

### dde5d57 — fix: Auto-call Multiuser.load! when entry point is required

**Date:** 2026-03-07 12:12:10 +0100

Added `Multiuser.load!` at the end of `lib/multiuser.rb` so that the SkillSet loader's `require` triggers hook registration automatically.

### 2c3cf3e — fix: Add explicit requires for core classes in Multiuser SkillSet

**Date:** 2026-03-07 13:08:01 +0100

Root cause: `PgBackend < KairosMcp::Storage::Backend` at class definition time triggered `NameError` because `storage/backend.rb` had not been required. The error propagated past the `rescue LoadError` / `rescue PG::ConnectionBad` clauses in `Multiuser.load!`, silently preventing all 3 tools from registering.

Fix:
- `pg_backend.rb`: `require 'kairos_mcp/storage/backend'`
- `multiuser.rb`: explicit requires for 5 core classes used by hooks (`storage/backend`, `safety`, `tool_registry`, `protocol`, `auth/token_store`)
- `multiuser.rb`: added `rescue NameError` + `rescue StandardError` fallback clauses

### 453c259 — fix: Use kairos_meta_skills method instead of removed KAIROS_META_SKILLS constant

**Date:** 2026-03-07 13:22:16 +0100

Pre-existing regression in `test_local.rb`: `KAIROS_META_SKILLS` constant was renamed to `KAIROS_META_SKILLS_FALLBACK` in a prior refactor. Changed to use `KairosMcp::LayerRegistry.kairos_meta_skills` class method.

### f3e3277 — docs: Add Multiuser SkillSet to L1 knowledge and regenerate READMEs

**Date:** 2026-03-07 13:51:58 +0100

L1 knowledge updates (6 files):
- **New**: `multiuser_management.md` (EN, `readme_order: 4.8`)
- **New**: `multiuser_management_jp.md` (JP, `readme_order: 4.8`)
- **Updated**: `kairoschain_usage.md` — Multiuser Tools subsection
- **Updated**: `kairoschain_usage_jp.md` — Multiuser ツールサブセクション
- **Updated**: `kairoschain_design.md` — Multiuser SkillSet in Plugin Architecture
- **Updated**: `kairoschain_design_jp.md` — Multiuser SkillSet 記載

README regenerated via `ruby scripts/build_readme.rb` (both EN and JP, 10 L1 files each).

---

## Debugging Log

### Issue 1: Multiuser tools not registering (NameError)

**Symptom:** `multiuser_status()` via MCP returned `"Multiuser SkillSet is not loaded"` and `tool_guide(command: "catalog")` showed only 34 tools (no multiuser tools).

**Diagnosis:**
```
KAIROS_DATA_DIR=.kairos ruby -e "..." 2>&1
[ToolRegistry] Failed to load SkillSet tools: uninitialized constant KairosMcp::Storage
```

Backtrace confirmed `NameError` at `pg_backend.rb:10` during class definition (`class PgBackend < KairosMcp::Storage::Backend`).

**Root cause:** Ruby evaluates the superclass expression at class definition time. `KairosMcp::Storage::Backend` was not yet loaded because `require 'kairos_mcp/storage/backend'` was never called. The `NameError` was not caught by the existing `rescue LoadError` clause.

**Fix:** Commit 2c3cf3e — explicit requires + expanded rescue clauses.

### Issue 2: `skillset upgrade --apply` reports "up to date" after gem rebuild

**Symptom:** After fixing code and rebuilding the gem, `skillset upgrade --apply` reported no changes because the files in the test environment already matched (they had been directly copied for testing).

**Resolution:** Direct file copy to test `.kairos/` directory bypassed the gem template → install pipeline for faster iteration during debugging.

### Issue 3: `KAIROS_META_SKILLS` constant not found in test_local.rb

**Symptom:** `NameError: uninitialized constant KairosMcp::LayerRegistry::KAIROS_META_SKILLS` during regression test.

**Root cause:** Pre-existing issue — the constant was renamed to `KAIROS_META_SKILLS_FALLBACK` in a prior refactor but `test_local.rb` was not updated.

**Fix:** Commit 453c259 — use `kairos_meta_skills` class method.

---

## Local Test Results

All PostgreSQL-independent tests passed:

| Test | Result | Notes |
|------|--------|-------|
| `test_local.rb` (regression) | Pass | After KAIROS_META_SKILLS fix |
| `test_skillset_manager.rb` | Pass | SkillSet infrastructure |
| `multiuser_status` via MCP | Pass | Returns `pg_server_unavailable` (expected — no PostgreSQL running) |
| 6 Core Hook tests (register/unregister) | Pass | All hooks functional |
| `user_context` propagation (6 core tools) | Pass | Backward compatible (nil default) |
| `multiuser_status()` via MCP | Pass | Graceful degradation confirmed |

### multiuser_status Output (PostgreSQL not running)

```json
{
  "enabled": false,
  "error_type": "pg_server_unavailable",
  "message": "PostgreSQL server is not running or unreachable: ...",
  "diagnostics": {
    "pg_gem": "installed",
    "pg_server": "unreachable",
    "config_file": "present"
  },
  "help": "Start PostgreSQL: brew services start postgresql@16"
}
```

---

## File Change Statistics

**Total: 45 files changed, +2,219 / -70 lines** (excluding README diffs)

| Category | Files | Lines Added |
|----------|-------|-------------|
| Core hooks (Phase 0) | 10 | ~280 |
| Multiuser SkillSet (Phase 1) | 15 new | ~1,480 |
| Tool call site updates (Phase 1) | 11 | ~70 |
| CLI: skillset upgrade | 2 | ~104 |
| L1 knowledge + design/usage | 6 | ~400 |
| Bug fixes (test_local.rb) | 1 | ~2 |

---

## Remaining Work

### Phase 2: Integration + Testing (Pending)

- HttpServer `TokenStore.create` factory integration test
- Regression tests (STDIO + HTTP modes)
- Multi-tenant isolation tests (2 users, separate blockchains)
- RBAC default-deny enforcement tests
- Migration lifecycle tests
- Docker Compose with PostgreSQL 16

### Phase 3: Release (Partial)

- [x] L1 knowledge (EN/JP)
- [x] README regeneration via `build_readme.rb`
- [ ] CHANGELOG
- [ ] Version bump (v2.8.0)
- [ ] Owner bootstrapping documentation
- [ ] Known limitations documentation (Synoptis data not tenant-isolated, MMP identity shared)

---

## Plan v3.1 Blocker Resolution

| Blocker | Plan Reference | Resolution |
|---------|---------------|------------|
| **Blocker 1**: Safety policy name mismatch | `:multiuser_l0` → `:can_modify_l0` | Implemented in d77352a — all 4 policies use capability keys |
| **Blocker 2**: TokenStore boot order | `eager_load_skillsets` before `TokenStore.create` | Implemented in d77352a — `http_server.rb` reordered |
| **Blocker 3**: `user_context` propagation | 3 providers + 11 tool call sites | Implemented in d77352a — all backward compatible |

## Unplanned Issues Encountered

| Issue | Impact | Resolution |
|-------|--------|------------|
| `require` for superclass missing | Tools not registering (silent failure) | 2c3cf3e: explicit requires + expanded rescue |
| `Multiuser.load!` not auto-invoked | Module defined but hooks not registered | dde5d57: auto-call at require time |
| `all_skillsets` method name | `skillset upgrade` crash | f1bb2e6: correct method name |
| `KAIROS_META_SKILLS` constant renamed | `test_local.rb` regression failure | 453c259: use class method API |
| `.mcp.json` hardcoded absolute path | Machine-specific config in repo | Reverted — not committed |
