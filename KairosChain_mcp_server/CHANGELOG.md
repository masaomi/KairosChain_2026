# Changelog

All notable changes to the `kairos-chain` gem will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

## [3.14.1] - 2026-04-12

### Fixed

- **Core SkillSet auto-install restriction** — `system_upgrade apply` and
  `kairos-chain upgrade --apply` now only auto-install core SkillSets (no external
  dependencies). Previously, multiuser (PostgreSQL) and hestia (networking) were
  installed automatically, causing connection errors. Non-core SkillSets must be
  installed explicitly by name.
- **CORE_SKILLSETS single source of truth** — moved from protocol.rb to
  SkillSetManager, eliminating duplication.

## [3.14.0] - 2026-04-12

### Added

- **SkillSet Plugin Projection** — Self-referential dual-mode Claude Code integration.
  Projects SkillSet artifacts (skills, agents, hooks) to `.claude/` structure.
  - **PluginProjector** (`plugin_projector.rb`, ~430 lines): dual-mode (Project + Plugin),
    atomic writes, digest-based no-op, manifest tracking, stale cleanup
  - **Ruby introspection**: `<!-- AUTO_TOOLS -->` marker dynamically generates tool docs
  - **L1 knowledge meta skill**: `<!-- AUTO_KNOWLEDGE_LIST -->` projects knowledge catalog
  - **Self-referential SkillSet**: `plugin_projector` projects its own SKILL.md and hooks
  - **Auto-init + auto-install**: first MCP connection initializes `.kairos/` and installs
    9 core SkillSets (no external dependencies)
  - **Auto-generate `.mcp.json`**: `kairos-chain init` creates MCP config with absolute paths
  - **Plugin artifacts for 3 SkillSets**: agent (SKILL.md + monitor agent),
    skillset_exchange (SKILL.md + reviewer agent + hooks), skillset_creator (SKILL.md)
  - **Scaffold `has_plugin` option**: `sc_scaffold` generates `plugin/` directory
  - **Auto-projection on upgrade**: `system_upgrade apply` and `skillset upgrade --apply`
    trigger re-projection after SkillSet changes
  - **Security**: SAFE_NAME_PATTERN, safe_path boundary checks, ALLOWED_HOOK_COMMANDS warning,
    atomic writes for settings.json auto-reload safety
  - **30 tests**, 3-LLM reviewed (Claude Opus 4.6 + Codex GPT-5.4 + Cursor Composer-2)

- **2-step setup**: `kairos-chain init` + `claude` (no manual system_upgrade needed)

### Changed

- **Seed `skills/kairos-chain/SKILL.md`**: revised to delegate per-SkillSet workflow details
  to individual SKILL.md files (agent, skillset_exchange, etc.)
- **`collect_knowledge_entries`**: extracted to `KairosMcp` module (shared by protocol.rb,
  plugin_project tool, and CLI)
- **Core SkillSets**: auto-install limited to 9 SkillSets without external dependencies
  (excludes multiuser/PostgreSQL, hestia/networking, etc.)

### Fixed

- **`.mcp.json` absolute paths**: relative `--data-dir` paths caused MCP connection failures
  when Claude Code resolved from different working directory
- **Non-Claude clients**: projection skipped when `.claude/` directory doesn't exist,
  preventing unintended artifact creation for Cursor/Codex

## [3.13.0] - 2026-04-02

### Added

- **Complexity-driven review for Agent auto mode** — New Gate 5.5a/b (pre-ACT) and
  Gate 6.5 (post-ACT) in the Agent autonomous OODA loop.
  - **Structural complexity assessment** with 7 signals: `high_risk`, `many_steps`,
    `design_scope`, `l0_change`, `core_files`, `multi_file`, `state_mutation`
  - **LLM self-assessment merge**: DECIDE prompt requests `complexity_hint`; merge rule
    caps LLM at structural + 1 level (prevents over-reporting)
  - **Gate 5.5a**: L0 changes always checkpoint with multi-LLM review prompt generation
  - **Gate 5.5b**: High complexity triggers Persona Assembly review (inner retry loop
    with max re-DECIDE attempts, risk/loop/complexity re-checks per revision)
  - **Gate 6.5**: Medium complexity runs post-ACT lightweight advisory review
  - Low complexity: no overhead (unchanged flow)
  - Parse failures default to REVISE (never silent APPROVE)
  - Persona definitions loaded from L1 knowledge with hardcoded fallback
  - Configuration: `complexity_review` section in `agent.yml` (personas, retries,
    L0 checkpoint policy, post-ACT toggle)
  - New `review` phase config in `agent.yml` (max_llm_calls, max_tool_calls)
  - Session: `save_review_result`, `load_review_result`, `save_progress_amendment`
  - Tests: 37 new (complexity assessment, persona review parsing, config, session, prompts)

### Fixed

- **`llm_call.rb` eager adapter loading** — All provider adapters were unconditionally
  required at startup, crashing with `LoadError` when optional gems (`faraday`,
  `aws-sdk`) were not installed. Now lazy-loads adapters in `build_adapter()`;
  only `claude_code_adapter` and base modules loaded at startup.
- **`claude_code_adapter` recursive MCP server loading** — `claude -p` subprocess
  loaded `.mcp.json` and spawned additional MCP server instances, causing deadlocks
  (stdio) or port conflicts (HTTP). Fixed with `--mcp-config '{"mcpServers":{}}'`
  and `--no-session-persistence`.
- **`claude_code_adapter` missing timeout** — `Open3.capture3` had no timeout,
  risking indefinite hangs. Wrapped with `Timeout.timeout` (default 120s,
  configurable via `timeout_seconds` in `llm_client.yml`).

### Design Process

- Complexity review design: 2R x 2 LLMs (Claude Team, Cursor Composer) → APPROVED
- Complexity review impl: R1 x 3 LLMs (Claude Team, Cursor, Codex) → fixes applied
  - Codex found off-by-one in retry counter and cycle number (both fixed)
  - R2 (Claude Team) → APPROVED
- llm_client fixes: reported by SUSHI self-maintenance MCP project, verified in upstream

## [3.12.0] - 2026-04-02

### Added

- **`skillset_exchange` SkillSet** (v0.1.0) — New L1 SkillSet enabling knowledge-only
  SkillSet deposit, browse, acquire, and withdraw via HestiaChain Meeting Places.
  - **PlaceRouter extension mechanism** — Formal extension registry with `register_extension`,
    `route_action_map`, dispatch after auth/middleware. Enables SkillSets to add HTTP
    endpoints to HestiaChain PlaceRouter without modifying Hestia core.
  - **4 MCP tools**: `skillset_deposit`, `skillset_browse`, `skillset_acquire`, `skillset_withdraw`
  - **PlaceExtension**: 4 HTTP endpoints (`/place/v1/skillset_deposit`, `skillset_browse`,
    `skillset_content`, `skillset_withdraw`) with disk-backed storage and quotas
  - **Security**: Dual executable gate (server tar header scan + client `knowledge_only?`),
    content hash verification (file-tree hash), signature verification with `require_signature`
    enforcement, path traversal protection, Content-Length pre-check, metadata canonicalization
    from verified archive contents
  - **DEE compliance**: Random sampling for browse, no ranking or popularity metrics
  - **ExchangeValidator**: Single gatekeeper for deposit eligibility
  - Lazy extension registration for late SkillSet enablement
  - Configurable quotas: 5MB/archive, 10/agent, 100MB total (default)
- **`SkillSetManager#install_from_archive` `force:` parameter** — Atomic swap reinstall
  with config preservation for SkillSet upgrades via exchange.
- **`SkillSetManager#check_installable_dependencies`** — Public preflight method returning
  structured result (`satisfiable`, `missing`, `version_mismatch`, `disabled`) without raising.
- **`Skillset#place_extensions`** — Metadata accessor for PlaceRouter extension declarations.

### Design Process

- Design: 2 rounds x 3 LLMs → APPROVED (0 FAIL)
- Phase 1 impl: 1R x 3 LLMs → fixes applied
- Phase 2 impl: 2R x 3 LLMs → fixes applied (Codex REJECT resolved)
- Phase 3 design: 2R x 3 LLMs → APPROVED
- Phase 3 impl: 1R x 3 LLMs → fixes applied
- Final comprehensive: 1R x 3 LLMs → fixes applied (SecurityError, metadata canonicalization)
- Tests: 303 total (Phase 1: 44, Phase 2: 85, Phase 3: 80, Phase 4: 94)

## [3.11.0] - 2026-04-01

### Added

- **`llm_call` `output_schema` parameter** — Enables structured JSON output from LLMs.
  When provided, the LLM is constrained to return JSON matching the given JSON Schema.
  - Anthropic/Bedrock: system prompt injection with tools-aware qualifier
    ("When you are NOT using a tool, respond with ONLY valid JSON...")
  - OpenAI: native `response_format: { type: "json_schema", strict: true }`
  - Claude Code CLI: prompt text injection
  - Backward compatible: `nil` default preserves all existing behavior
- **`SchemaConverter.normalize_for_openai` `required` auto-population** — When an
  object schema has no `required` key, all property names are auto-populated into
  `required` to satisfy OpenAI strict mode constraints. Existing `required` arrays
  are preserved unchanged.
- **Multi-LLM review XML block prompts** (`multi_llm_review_workflow` v3.2) — Five
  XML blocks for structured review prompts:
  `<task>`, `<structured_output_contract>`, `<grounding_rules>`,
  `<verification_loop>`, `<default_follow_through_policy>`.
  LLM-agnostic; works with Claude, GPT, and Composer models.

### Design Process

- Inspired by codex-plugin-cc (Claude Code Codex plugin) analysis — 4-agent team review
- Implementation reviewed: 2 rounds x 3 LLMs (Claude Opus 4.6, Codex GPT-5.4, Cursor Composer-2)
- R1: 3/3 APPROVE WITH CHANGES — 2 must-fix findings (tools+schema conflict, OpenAI required)
- R2: 2/3 APPROVE, 1/3 AWC, 0 FAIL/HIGH — converged
- Tests: 32 → 47 (all PASS)

## [3.10.0] - 2026-03-31

### Added

- **introspection SkillSet** (v0.1.0) — New self-inspection SkillSet with 3 tools:
  - `introspection_check`: Full inspection (L1 health + blockchain integrity + safety mechanisms + recommendations)
  - `introspection_health`: L1 knowledge health scores using Synoptis TrustScorer (optional, falls back to staleness-only)
  - `introspection_safety`: 4-layer safety mechanism visibility (L0 approval workflow, RBAC policies, agent safety gates, blockchain recording)
- **Dream SkillSet L1 dedup + confidence scoring** (v0.2.1) — `dream_scan` now checks promotion candidates against existing L1 knowledge (name similarity + tag Jaccard overlap) and scores candidates with 3-dimension confidence (recurrence, tag consistency, session diversity). New `include_l1_dedup` parameter.
- **`skills_promote` attestation integration** — Successful L2→L1 promotions now automatically issue Synoptis attestations (`claim: "promoted_from_l2"`, `actor_role: "automated"`). Graceful degradation when Synoptis is not loaded.
- **`Safety.registered_policy_names`** — New thread-safe public API for introspecting registered RBAC policies. Replaces `instance_variable_get(:@policies)` pattern.

### Fixed

- **`system_upgrade` SkillSet-only install** — When specific SkillSet names are provided via `names` parameter but L0 templates are already up-to-date, `system_upgrade apply` now correctly installs/upgrades the requested SkillSets instead of returning "No upgrade needed". Previously, the L0 upgrade check (`UpgradeAnalyzer.upgrade_needed?`) gated all operations including SkillSet installs.

### Design Process

- Design reviewed: 2 rounds x 3 LLMs (Claude Opus 4.6, Codex GPT-5.4, Cursor Composer-2)
- Implementation reviewed: 1 round x 3 LLMs per phase
- 8 P0/P1 bugs found and fixed during design review (before any code was written)
- Inspired by oh-my-claudecode analysis; independently designed with KairosChain philosophy

## [3.9.4] - 2026-03-30

### Added

- **Permission advisory on claude_code fallback** — When the agent falls back
  to the `claude_code` LLM provider (API key missing), it now checks if a
  `PreToolUse` hook is configured in `.claude/settings.json` for the MCP server.
  If not, a one-time `permission_advisory` is included in the `agent_step`
  response with the exact hook configuration needed for uninterrupted
  autonomous operation. The advisory is suggest-only and never modifies
  user settings.

## [3.9.3] - 2026-03-30

### Fixed

- **act_summary always 'failed'** — `autoexec_run` `internal_execute` mode
  returns `outcome: "internal_execute_complete"` but `agent_step` checked
  `run_parsed['status'] == 'ok'` (always nil). Changed to check
  `outcome.end_with?('_complete')`.

## [3.9.2] - 2026-03-30

### Fixed

- **llm_client SkillSet missing from gem templates** — `llm_client` files existed
  only in the project-root `templates/` but not in the gem-bundled
  `KairosChain_mcp_server/templates/skillsets/llm_client/`. This caused
  `llm_call`, `llm_configure`, and `llm_status` tools to be unavailable on
  fresh installs, breaking the `agent` SkillSet (`depends_on: ["llm_client"]`).
- **llm_client directory structure non-standard** — Tool files were at the
  SkillSet top level instead of `tools/`, lib files in `llm_client/` instead
  of `lib/llm_client/`, config at top level instead of `config/`. The
  `skillset.rb` loader only scans `tools/` so tools were never loaded.

## [3.9.1] - 2026-03-30 [yanked]

- Included llm_client files but with non-standard directory structure.

## [3.9.0] - 2026-03-30

### Added

- **agent_execute** — Claude Code subprocess delegation for file operations
  - Delegates Read/Edit/Write/Glob/Grep to a sandboxed `claude -p` subprocess
  - `--permission-mode acceptEdits` for auto-approval of file edits
  - `--output-format stream-json` for structured result parsing (files_modified, tool_calls)
  - 8 security layers: Agent blacklist, tool restriction, Bash gating (requires
    `Bash(pattern)` in allowed_tools), acceptEdits mode, env scrubbing
    (unsetenv_others: true), project root lock, --max-budget-usd (clamped to
    agent.yml max), external timeout (SIGTERM -> SIGKILL)
  - Configurable via `agent.yml` `agent_execute:` section
  - Design: 2 rounds x 2-3 LLMs. Implementation: 1 round x 3 LLMs.

- **Agent ACT routing** — automatic delegation based on task plan
  - `requires_file_operations?` detects Edit/Write/Read/Bash in task steps
  - File operations route to `agent_execute`; MCP tools route to `autoexec_run`
  - Context injection via `--append-system-prompt` (goal + progress)

- **SkillSet discovery & install** via `system_upgrade`
  - `system_upgrade command="skillsets"` lists all available SkillSets with status
  - New SkillSets in gem templates auto-detected by `upgrade_check`
  - `system_upgrade command="apply" names=["dream"]` installs specific SkillSets
  - `available_skillsets` method on SkillSetManager

### Fixed

- `ClaudeCodeAdapter`: removed invalid `--max-turns 1` flag (not in claude CLI)
- `agent_execute` blacklist: properly removes `agent_*` wildcard + re-adds other agent tools
- `agent_execute` error propagation: subprocess failures now set `error` key for ACT gates

## [3.8.0] - 2026-03-30

### Added

- **Agent Autonomous Mode** — Multi-cycle OODA loop execution
  - `agent_start(autonomous: true)`: Enable autonomous mode. Session starts at
    `[observed]` as before; autonomous loop begins on `agent_step(approve)`.
  - 8 safety gates: mandate termination, goal drift detection, wall-clock timeout
    (300s), aggregate LLM budget (60 calls), risk budget, post-ACT termination,
    confidence-based early exit, checkpoint pause.
  - New session states: `autonomous_cycling`, `paused_risk`, `paused_error`
  - Resume handlers: `approve` at `paused_risk` re-checks risk and resumes ACT;
    `approve`/`skip` at `paused_error` skips failed cycle and continues.
  - `agent.yml` autonomous config: `max_total_llm_calls`, `max_duration_seconds`,
    `min_cycles_before_exit`, `confidence_exit_threshold`.
  - Design: 2 rounds x 3 LLMs. Implementation: 1 round x 3 LLMs. All HIGH fixed.

- **Mandate locking** — `Mandate.with_lock` for single-writer batch execution
  - File-based exclusive lock (`flock`), non-blocking with `LockError`
  - Atomic save via tmp+rename pattern
  - `Mandate.reload` helper for in-lock refresh

- **CognitiveLoop call tracking** — `total_calls` attribute for aggregate
  LLM budget enforcement across autonomous cycles

- **Goal drift detection** — Content-based hash (not name-only) at mandate
  creation; per-cycle drift check with fail-open semantics

### Changed

- `run_orient_decide` / `run_act_reflect` refactored into `_internal` (Hash return)
  + wrapper (text_content) pattern. Manual mode behavior unchanged.
- Manual risk pause now sets session to `paused_risk` (was `terminated`),
  enabling resume via `agent_step(approve)`.
- `MandateAdapter.to_mandate_proposal` uses `dig` for nil safety.

## [3.7.0] - 2026-03-29

### Added

- **Dream SkillSet** — L2 memory consolidation and lifecycle management
  - `dream_scan`: Pattern detection across L2 sessions — tag co-occurrence,
    L2/L1 staleness (mtime-based), name overlap (Jaccard), archive candidate detection.
    Filters soft-archived stubs from promotion candidates.
  - `dream_archive`: L2 soft-archive — gzip compress .md, move full context directory
    to archive, leave searchable stub (tags + summary). SHA256 verified inline.
    Per-context flock. `dry_run: true` by default.
  - `dream_recall`: Restore archived contexts with SHA256 integrity check.
    Preview and verify-only modes (read-only, no permission required).
  - `dream_propose`: Package L1 promotion proposals with ready-to-execute
    `knowledge_update` commands. Optional Persona Assembly templates.
  - L2 lifecycle model: Active → Candidate → Soft-Archived → Recalled
  - `dream_trigger_policy` L1 knowledge for Kairotic trigger heuristics
  - 119 tests across 27 test sections

- **Agent SkillSet — permission advisory**
  - `agent_start` now includes `permission_advisory` in response,
    recommending users configure permission mode (Normal / Auto-allow / Auto-accept)
    for smoother autonomous operation

### Fixed

- **L1 staleness detection** — use tag overlap and name token matching instead of
  exact L1 name-in-L2-tags check. Reduces false positives from 48/48 to 7/48.

## [3.6.0] - 2026-03-28

### Added

- **Agent SkillSet** — OODA cognitive loop for autonomous task execution
  - `agent_start`: Initialize agent session with mandate and goal
  - `agent_step`: Execute one OODA cycle (Observe → Orient → Decide → Act via autoexec)
  - `agent_status`: View cycle history and active mandates
  - `agent_stop`: End agent session with reflection
  - Cumulative progress file (`progress.jsonl`) for cross-cycle continuity
  - Loop detection via decision_payload summary comparison
  - Multi-cycle mandate progression with checkpoint
  - 90 tests across M1-M4 milestones

- **mcp_client SkillSet** — Connect to external MCP servers as a client
  - `mcp_connect`: Establish connection to remote MCP server (HTTP JSON-RPC)
  - `mcp_disconnect`: Close connection and unregister proxy tools
  - `mcp_list_remote`: List available tools on connected server
  - `ProxyTool`: Dynamic tool proxying with namespace prefixing
  - `ConnectionManager`: Singleton with lifecycle management
  - Dual blacklist (Agent + InvocationContext) for security
  - ORIENT_TOOLS integration for Agent SkillSet awareness
  - 25 tests (Client 6, ConnectionManager 7, ProxyTool 4, Registry 3, E2E 5)

- **Attestation Nudge** (MMP SkillSet) — Proactive attestation prompts
  - Tracks usage of acquired skills, suggests attestation after threshold
  - `register_gate(:attestation_nudge)` passive observer (zero L0 changes)
  - Gate detects `resource_read`/`knowledge_get` access to received skills
  - In-memory tool_name/file_path indexes for O(1) gate miss path
  - `flock(LOCK_EX)` atomic JSON file updates
  - Time-window throttling: `cooldown_hours` + `nudge_interval_hours`
  - Passive decline: nudge emission starts cooldown
  - Nudge footer on 5 MMP tools (browse, connect, details, preview, freshness)
  - `sanitize_for_display` for remote metadata in nudge messages
  - 39 tests, 4 rounds of multi-LLM review (3/3 APPROVE including Codex)

- **InvocationContext** — Tool invocation chain tracking
  - Depth limiting, caller tracking, mandate propagation
  - Whitelist/blacklist policy enforcement at registry boundary
  - `derive` method for Agent SkillSet tool_names extraction
  - 59 tests

### Changed

- **L1 Knowledge Consolidation** (4 → 3 skills):
  - `multi_llm_review_workflow` v3.1: merged with `multi_llm_design_review` (methodology + CLI execution in single skill)
  - `multi_llm_reviewer_evaluation` v1.1: Codex convergence behavior data, APPROVE signal reliability
  - `design_to_implementation_workflow` v1.1: self-review phase, implementation review phase, Persona Assembly merge gate
  - Deleted: `multi_llm_design_review` (absorbed into `multi_llm_review_workflow`)
  - Self-referential review: v3.0 reviewed by its own multi-LLM process → v3.1

- **meeting_attest_skill**: Fail-closed when `content_hash` is nil (previously fail-open)

- **autoexec**: Enhanced `task_dsl` and `plan_store` for Agent SkillSet integration

### Fixed

- **Phase 4 review fixes**: Notification method, restore hook, race condition, stale proxy
- **Mandate save race**: Single atomic save (no update_status then stale save)
- **Attestation Nudge race condition**: `rebuild_indexes_from(data)` inside `with_locked_data`
- **Attestation Nudge index staleness**: `mark_attested` rebuilds indexes
- **Attestation Nudge JSON recovery**: `with_locked_data` recovers from corrupted JSON

---

## [3.5.0] - 2026-03-27

### Added

- **Trust Score v2 — Meeting Place-aware 2-layer trust model**: Client-side trust scoring
  for Meeting Place skills and depositors. Core principle: Meeting Place provides facts,
  trust computation is always a local cognitive act by the querying agent.
  - **Skill Trust**: attestation quality (anti-collusion discounted), usage (remote-discounted),
    freshness, provenance, depositor signature gate
  - **Depositor Trust**: portfolio average skill trust (with shrinkage for small portfolios),
    attestation breadth, attester diversity, activity level
  - **Combined Score**: smooth linear interpolation (no discontinuity) — new skills lean on
    depositor reputation, established skills stand on their own evidence
  - **Anti-collusion**: self-attestation discount (0.15x), bootstrap gate, honest labeling
    (`v2_simplified_bootstrap`), signature presence vs verification distinction
  - **URI routing**: `meeting:<skill_id>`, `meeting_agent:<agent_id>`, legacy local refs
  - **Input sanitization**: `SAFE_ID_PATTERN` regex for skill_id/agent_id
  - **Portfolio truncation warning**: when browse limit (50) may have truncated depositor data
  - **YAML-driven weights**: all weights, claim weights, thresholds configurable via `trust_v2:`
    section in `synoptis.yml`
  - **Graceful degradation**: returns `source: "unavailable"` when not connected
  - New file: `synoptis/lib/synoptis/meeting_trust_adapter.rb` (HTTP data fetching + TTL cache)
  - Design: 2-round multi-LLM review (R1 with Persona Assembly: 3 P0 found and fixed)
  - Implementation: 2-round multi-LLM review (R1: 3 P1 + 4 P2; R2: converged)

- **Multi-LLM Design Review v2.2**: Persona Assembly integration — orchestrator auto-decides
  whether to use Persona Assembly for Claude Agent Team based on complexity tier:
  - Tier 1-2 / knowledge review: single perspective (default)
  - Tier 3 / safety-critical: Persona Assembly (4+ personas)
  - R2+ verification passes: single perspective
  - Assembly findings weighted as single reviewer in consensus analysis

---

## [3.4.1] - 2026-03-24

### Fixed

- **meeting_browse missing fields**: `format_entry` did not forward `attestations`, `summary`,
  `sections`, `content_hash`, `version`, or `license` from server response. These were correctly
  returned by the server but dropped by the MCP tool's formatting layer.
- **Attestation R2 fixes**: Version-aware duplicate check (same attester can re-attest after
  skill update), `content_hash` included in signed payload for cryptographic version binding.

---

## [3.4.0] - 2026-03-24

### Added

- **Attestation Deposit**: Agents can deposit signed attestation copies on skills at the
  Meeting Place. Other agents see attestations in browse/preview and can verify signatures
  via the attester's public key (no P2P needed).
  - `POST /place/v1/board/attest` — deposit attestation with RSA signature
  - `meeting_attest_skill` MCP tool — sign claim, hash evidence, deposit to Place
  - 3-layer trust: Browse (metadata) → Preview (verify signature) → P2P (evidence text)
  - Version-bound: attestations linked to specific `content_hash`, hidden after skill update
  - Server-side signature verification against registry public key
  - Cleaned up on skill withdrawal; size/rate limited
  - Multi-LLM reviewed: 2 rounds × 3 LLMs, 11 findings resolved

### Fixed

- **Meeting Place storage path**: Default paths now resolve via `KairosMcp.storage_dir`
  (inside Docker volume), preventing deposit data loss on container rebuild.

---

## [3.3.1] - 2026-03-24

### Fixed

- **`kairos-chain skillset install` short name resolution**: `kairos-chain skillset install mmp`
  now resolves to gem's `templates/skillsets/mmp/` automatically. Previously required full path.
- **`kairos-chain skillset install --force`**: New flag for reinstalling/updating existing SkillSets.
  Preserves user config files (`config/*.yml`) during reinstall.

---

## [3.3.0] - 2026-03-24

### Added

- **Meeting Place: Deposit Lifecycle** — Full deposit management tools
  - `meeting_withdraw`: Remove deposited skills (depositor-only, chain-recorded audit)
  - `meeting_update_deposit`: Replace deposited skill content (pull-only, no push to acquirers)
  - `meeting_preview_skill`: Preview summary, sections, first N lines without acquiring
  - `DELETE /place/v1/deposit/:skill_id`, `PUT /place/v1/deposit/:skill_id`, `GET /place/v1/preview/:skill_id`
- **Meeting Place: Discovery & Profiles**
  - `meeting_check_freshness`: Check if acquired skills have been updated or withdrawn
  - `meeting_get_agent_profile`: Public profile bundle (identity, deposited skills metadata, needs)
  - Agent profile enhancement: `description` and `scope` fields in registration and browse
  - `GET /place/v1/agent_profile/:id`, `GET /place/v1/welcome` (unauthenticated onboarding guide)
- **Meeting Place: Operational Controls**
  - Deposit rate limiting: per-agent, per-hour (default 10/hour, process-scoped)
  - Format Gate: YAML frontmatter structural validation on deposit
  - All limits published in `GET /place/v1/info` response (`deposit_limits` field)
  - `hestia.yml`: Operator-configurable `deposit_policy` block (quotas, rate limits, future license/safety settings)
- **Skill Metadata Card**: Browse and preview now include `summary`, `sections`, `version`, `license`, `content_size_lines`, `content_hash` from frontmatter
- **Hestia SkillSet** bumped to v0.2.0, **MMP SkillSet** bumped to v1.1.0

### Fixed

- **`MMP::Identity#instance_id`**: Added public accessor (was only private `generate_instance_id`). Fixed `NoMethodError` in `philosophy_anchor` and `record_observation` tools.
- **SkillBoard thread safety**: Added `@mutex` for `deposit_skill` and `withdraw_skill` (TOCTOU fix)
- **Quota blocks PUT updates**: Existing deposit excluded from quota calculation during replacement
- **`exchange_counts` leak on withdraw**: Cleaned up on skill withdrawal
- **`first_lines` unbounded**: Clamped to 1..100 (prevents content exfiltration via preview)
- **`chain_recorded: true` misleading**: Changed to `'attempted'`/`false` matching fire-and-forget semantics
- **Agent profile data leakage**: Server-side whitelist (only id, name, description, scope, capabilities, registered_at)
- **DEE D5 compliance**: Removed `total_exchanges` aggregate from agent profile (prevents agent-level ranking)
- **Freshness check misclassification**: Only 404 = `withdrawn`; auth/transport errors = `check_failed`
- **Rate limit DoS**: Now gates all deposit attempts, not just successful ones
- **Rate limit config safety**: `deposit_rate_limit` clamped to minimum 1 (prevents 0/negative lockout)
- **Metadata preservation on update**: `summary`/`input_output` preserved when not explicitly sent in PUT

### Review

- Sprint 1: 1 round × 3 LLMs, 8 fixes applied (3 FAIL + 5 CONCERN resolved)
- Sprint 2: 2 rounds × 3 LLMs, 7 fixes applied (all RESOLVED at R2), 3/3 APPROVE
- Reviewers: Claude Opus 4.6 (Agent Team), Cursor Composer-2, Cursor GPT-5.4

---

## [3.2.0] - 2026-03-23

### Added

- **`researcher` instruction mode**: Scientific research mode with quality guardrails,
  Meeting Place interaction policy, and Knowledge Acquisition Policy. Supports
  computational reproducibility, statistical analysis, and scientific writing
  across all disciplines. Multi-LLM reviewed (consensus 4.5/5).
  Activate with: `instructions_update(command: "set_mode", mode_name: "researcher", ...)`
- **L0 External Modification Protection**: `l0_governance` v1.1 adds declarative
  rule rejecting L0 changes originating from external sources (Meeting Place,
  P2P exchange, remote agents, chain_import). Prevents social engineering attacks
  on L0 integrity. See `log/kairoschain_l0_external_protection_rule_proposal_20260323.md`.

---

## [3.1.1] - 2026-03-23

### Fixed

- **HTTPS support for all MMP HTTP calls**: `Net::HTTP.new` does not enable SSL by default. All MMP PlaceClient and meeting_* tools failed with "Connection reset by peer" when connecting to TLS-enabled Meeting Place servers. Added `http.use_ssl = (uri.scheme == 'https')` to all HTTP calls.
- **Caddy DNS resolvers**: Ubuntu 24.04 uses systemd-resolved (127.0.0.53) which is inaccessible from Docker containers. Added external DNS resolvers (8.8.8.8, 1.1.1.1) to Caddy container.

### Changed

- **Domain**: `meeting.kairoschain.io` → `meeting.genomicschain.io`

---

## [3.1.0] - 2026-03-22

### Added

- **Docker Production Deployment**: Complete Docker setup for Meeting Place server on EC2
  - `docker-compose.prod.yml` with Caddy TLS reverse proxy (`meeting.kairoschain.io`)
  - Network isolation: `frontend` (Caddy + app) / `backend` (app + PG)
  - Security headers (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy)
  - EC2 setup script (Amazon Linux 2023, Docker Compose via dnf)
  - Service Grant DB migrations in entrypoint
  - Volume upgrade: automatic SkillSet backfill from template on existing volumes
- **Configurable Grant Creation Cooldown** (`grant_creation_cooldown`): Config option in `service_grant.yml` (default: 300s, set to 0 to disable). Future: trust-based cooldown where `cooldown = base * (1.0 - trust_score)`

### Fixed

- **AccessGate owner bypass**: Admin/owner tokens (from `--init-admin`) were blocked by Service Grant with "pubkey_hash missing from auth context". Owner role now bypasses Service Grant checks — admin tokens are system management, not service consumers
- **GrantManager record_with_retry kwargs**: `record_grant_event` passed bare kwargs to `record_with_retry(event, attempt:)`, leaving the positional `event` parameter empty → `ArgumentError`. Fixed with explicit `{}` braces. Caused 500 errors on Place API endpoints
- **meeting_connect session_token**: `connect_relay` saved the MMP introduce handshake token (`/meeting/v1/introduce`) instead of the Place register token (`/place/v1/register`). The MMP token lacks `pubkey_hash` in the session store, causing all Place API write operations (deposit, acquire) to fail with 403 "Cannot resolve identity"

### Review

- Docker deployment: 2 rounds × 3 LLMs (Claude Agent Team, Cursor Composer-2, Cursor GPT-5.4), converged at Round 2
- Service Grant bugfixes: 1 round × 3 LLMs, 3/3 APPROVE

---

## [3.0.0] - 2026-03-21

### Added

- **Service Grant SkillSet** (`service_grant`): New SkillSet providing generic, service-independent access control and billing for any KairosChain-based service. Designed and implemented through multi-LLM review methodology (Claude Opus 4.6, GPT-5.4, Composer-2) across 6 phases.
  - **Phase 0**: Core/Hestia prerequisites — PlaceRouter middleware hooks, session store pubkey_hash support, token store extension
  - **Phase 1**: Basic access control MVP — GrantManager (auto-grant with ON CONFLICT), UsageTracker (atomic try_consume), AccessChecker (unified pipeline), AccessGate (Path A), PlaceMiddleware (Path B), PlanRegistry (YAML config), PgConnectionPool (thread-safe with circuit breaker), IpRateTracker (anti-Sybil), CycleManager, RequestEnricher, Safety policies, admin tools
  - **Phase 2**: Synoptis Trust Score integration — TrustScorerAdapter (quality+bridge scoring with caching), anti-collusion PageRank (zero-weight cartel detection), TrustIdentity (canonical `agent://` URIs), PgCircuitBreaker hardening, PoolExhaustedError hierarchy
  - **Phase 3a**: PaymentVerifier (proof-centric design) — cryptographic signature verification via Synoptis Verifier, issuer authorization, freshness/revocation checks, evidence validation (amount, currency, nonce), idempotent duplicate handling (PG::UniqueViolation rescue), atomic upgrade transaction
  - **Phase 3b**: Subscription expiry + provider_tx_id — lazy downgrade with atomic conditional UPDATE, concurrent renewal re-read, subscription_duration config validation (1-3650 days), provider_tx_id tracking
  - **GrantManager-PaymentVerifier unification**: Plan-change SQL consolidated into `apply_plan_upgrade` (single source), event recording unified via `record_plan_upgrade` (called after COMMIT)
  - 4 billing models: `free`, `per_action`, `metered`, `subscription`
  - 4 MCP tools: `service_grant_status`, `service_grant_manage`, `service_grant_migrate`, `service_grant_pay`
  - 3 SQL migrations, YAML-driven plan configuration
  - Anti-Sybil: IP rate limiting (5/hour, PG-backed), cooldown (5 min write delay), trust score gating
  - 159 unit tests, 232 assertions
  - Bundled L1 knowledge: `service_grant_guide`

- **Multi-LLM Design Review L1 Knowledge** (`multi_llm_design_review` v2.1): Methodology and CLI automation for parallel multi-LLM code review.
  - Auto mode: Codex (GPT-5.4) + Cursor Agent (Composer-2) + Claude Code (Opus 4.6) in parallel
  - Manual mode fallback with structured prompt generation
  - Prompt Generation Rules: output filename specification, auto-execution commands
  - Convergence rules: 2/3 APPROVE = proceed, any REJECT = revise
  - Observed LLM role differentiation across structural, seam, and safety layers

- **SkillSet Implementation Quality Guide** (`skillset_implementation_quality_guide`): Design constraint tests and wiring checklist derived from Service Grant multi-LLM review experiment.

- **L1 Knowledge**: Service Grant access control documentation (EN/JP) with `readme_order: 4.9`

### Changed

- **HestiaChain PlaceRouter**: Added `register_middleware`/`unregister_middleware` hooks, `ROUTE_ACTION_MAP`, middleware invocation in request handling, pubkey_hash resolution from session store
- **MMP MeetingSessionStore**: Added `pubkey_hash` storage and `pubkey_hash_for(peer_id)` method
- **Synoptis TrustScorer**: Extended with anti-collusion PageRank, external attestation weighting, bridge score calculation, attestation weight with zero-weight floor for cartels
- **Synoptis TrustIdentity**: New module for canonical `agent://` URI handling

---

## [2.10.1] - 2026-03-19

### Fixed

- **Streamable HTTP session management**: MCP clients (Claude Code, Cursor) could not discover tools over HTTP transport because each request created a new `Protocol` instance, losing the `@initialized` state from the handshake. Fixed with stateless design: `initialize` returns `Mcp-Session-Id` header (spec compliance), subsequent requests auto-initialize the Protocol internally. No server-side session store needed — per-request Bearer token authentication is sufficient.
- **`DELETE /mcp` endpoint**: Added support for MCP session termination requests (returns 204, no-op in stateless mode).

---

## [2.10.0] - 2026-03-18

### Added

- **Autonomos SkillSet** (`autonomos` v0.1.0): New opt-in SkillSet for autonomous project execution via OODA cycles with human-in-the-loop safety.
  - `autonomos_cycle`: Single-cycle observe → orient → decide pass. Returns structured proposal with gap analysis, autoexec-compatible task JSON, and complexity-driven deliberation hints.
  - `autonomos_reflect`: Post-execution reflection with L2 context save and two-phase chain recording (intent + outcome). Regex-based evaluation with human feedback correction.
  - `autonomos_status`: Cycle history viewer for mandate and cycle state inspection.
  - `autonomos_loop`: Continuous mode via mandate-based pre-authorization. Multi-cycle execution with risk budget gates (`low`/`medium`), goal hash verification, checkpoint system (1-3 cycle intervals), loop detection (number-normalized string comparison), and error threshold (2 consecutive).
  - **L2-first goal loading**: Goals loaded from L2 context (newest session first) with L1 knowledge fallback. Supports `type: autonomos_goal` frontmatter and checklist-based gap identification.
  - **Complexity-driven deliberation**: Proposals include `complexity_hint` (`low`/`medium`/`high`) with signals (`high_risk`, `many_gaps`, `design_scope`) to guide LLM escalation to persona assembly review.
  - **Safety model**: PID-based cycle lock, inherited autoexec safety (risk classification, L0 deny-list, hash-locked plans), goal hash verification per cycle, no L0 modification capability.
  - **Chain recording**: Two-phase commit (intent at decide, outcome at reflect) — constitutive, not evidential (Proposition 5).
  - Bundled L1 knowledge: `autonomos_guide` (usage guide with goal convention, cycle states, continuous mode, related L1 knowledge references)
  - Hard dependency on `autoexec` SkillSet
  - 90 unit tests, 203 assertions

- **Review Discipline L1 Knowledge** (`review_discipline`): Codified countermeasures for LLM-common cognitive biases discovered during 6 rounds of multi-LLM review triangulation.
  - 3 bias patterns: Caller-side bias, Fix-what-was-flagged bias, Mock fidelity bias
  - Per-bias checklists for systematic review
  - Multi-LLM review workflow (v0.1 manual)

### Fixed

- **Autonomos checkpoint resume infinite loop**: `checkpoint_due?` re-evaluated immediately on resume when `cycles_completed % checkpoint_every == 0` still true. Fixed with `resuming_from_pause` flag that skips checkpoint evaluation once after resume.
- **Autonomos storage_path API mismatch**: `KairosMcp.kairos_dir` (nonexistent) → `KairosMcp.data_dir` (correct API). Previously fell back to `Dir.pwd/.kairos` accidentally.
- **Autonomos save_context return unchecked**: `Reflector.save_to_l2` now checks `save_context` return value for `{ success: false }` and returns nil on failure.
- **Autonomos load_l2_context key/order**: Fixed to use `sessions.first[:session_id]` (newest-first from ContextManager).
- **Autonomos loop detection number bypass**: Gap descriptions now number-normalized (`gsub(/\d+/, 'N')`) before comparison to prevent interpolated counts from defeating detection.
- **Autonomos orphan cycle on loop termination**: Mandate state (last_cycle_id, recent_gaps) saved BEFORE loop detection check so terminate_loop sees correct state.

---

## [2.9.0] - 2026-03-14

### Added

- **AutoExec SkillSet** (`autoexec` v0.1.1): New opt-in SkillSet for semi-autonomous task planning and execution with constitutive chain recording.
  - `autoexec_plan`: Generate structured task plans from natural language descriptions. Outputs `.kdsl` DSL files with SHA-256 hash-locked integrity. Supports DSL and JSON input formats.
  - `autoexec_run`: Execute planned tasks with graduated approval (`dry_run` default, `execute`, `status` modes). Two-phase commit records intent before and outcome after execution. Checkpoint resume for halted tasks.
  - **Regex DSL parser**: No `eval`, no `BasicObject` sandbox — 18 forbidden patterns checked before parsing. Roundtrip-safe (`parse` → `to_source` → `parse`).
  - **Risk classifier**: Static rule-based risk classification (low/medium/high) with L0 deny-list (read from L0 governance skill, self-referential design), protected file detection, and L0 firewall.
  - **Plan store**: File-based plan storage with atomic execution lock (`File::CREAT|EXCL|WRONLY`), PID liveness checks, stale lock timeout, and checkpoint management.
  - **`requires_human_cognition`**: Step-level halt for human cognitive participation (constitutive, not cautionary — Proposition 9). Saves checkpoint and resumes on re-run.
  - **TOCTOU prevention**: Single load + in-memory hash verification (no separate verify then load).
  - **Chain recording**: Two-phase commit with intent block before execution and outcome block after (validity-conditional recording, Proposition 5). Chain failures surfaced in response, never silently swallowed.
  - **Path traversal prevention**: `task_id` validated with `\A\w+\z` in both DSL and JSON input paths.
  - Bundled L1 knowledge: `autoexec_guide` (usage guide with examples)
  - 75 unit tests across TaskDsl, RiskClassifier, and PlanStore

### Fixed

- **TaskDsl colon false-positive**: Unknown key scanner no longer matches colons inside quoted action strings (e.g., `"run command: echo hello"`)
- **TaskDsl missing requires**: Added `require 'digest'` and `require 'json'` for module independence
- **AutoexecRun lock release**: Moved `acquire_lock` inside `begin/ensure` block with `lock_acquired` flag to guarantee lock release on any exception

---

## [2.8.0] - 2026-03-08

### Added

- **Knowledge Creator SkillSet** (`knowledge_creator` v1.0.0): New opt-in SkillSet for evaluating and improving L1 knowledge quality through structured Persona Assembly prompts.
  - `kc_evaluate`: Generate quality evaluation prompts (evaluate/analyze/criteria commands) with 7 evidence-based dimensions, 3-tier readiness assessment (READY/REVISE/DRAFT), and configurable personas (evaluator, guardian, pragmatic)
  - `kc_compare`: Generate blind A/B comparison prompts for knowledge version comparison (L1 vs L1, L2 vs L1 promotion readiness)
  - Bundled L1 knowledge: `quality_criteria` (evaluation dimensions, evidence requirements, persona definitions), `creation_guide` (Kairotic Creation Loop workflow, 6 structural patterns)
  - SkillSet-local persona definitions (does not modify shared `persona_definitions`)
  - L2 save instruction for evaluation history tracking

- **SkillSet Creator SkillSet** (`skillset_creator` v1.0.0): New opt-in meta-SkillSet for developing KairosChain SkillSets with the 5-phase development workflow.
  - `sc_design`: Core-vs-SkillSet decision analysis (loads `core_or_skillset_guide` knowledge) and design phase checklist
  - `sc_scaffold`: Generate complete SkillSet directory structures with skeleton files (preview/generate), input validation (path traversal prevention, collision check), explicit `output_path` required
  - `sc_review`: Generate structured review prompts for multi-LLM review or Persona Assembly review of SkillSet designs and implementations
  - Bundled L1 knowledge: `development_guide` (5-phase workflow, review escalation, multi-LLM best practices), `core_or_skillset_guide` (Core vs SkillSet decision tree)
  - Runtime-detected integration with Knowledge Creator (no declared dependency; uses `defined?` check)

- **Design Process**: Both SkillSets designed through the 5-phase development meta-pattern with 2 rounds of multi-LLM review (Antigravity/Gemini, Claude Team/Opus 4.6, Codex/GPT-5.4). Design documents in `log/`.

---

## [2.7.0] - 2026-03-06

### Added

- **Synoptis Mutual Attestation SkillSet**: New opt-in SkillSet for cross-agent trust verification through cryptographically signed proof envelopes
  - `ProofEnvelope`: Signed attestation data structure with Merkle root and content hash
  - `Verifier`: Structural + cryptographic verification with mandatory signature checks
  - `AttestationEngine`: Attestation lifecycle (create, verify, list) with re-issuance prevention
  - `RevocationManager`: Authorization-checked revocation (original attester or admin only)
  - `ChallengeManager`: Challenge/response lifecycle (validity, evidence_request, re_verification)
  - `TrustScorer`: Weighted composite trust score (quality, freshness, diversity, velocity, revocation penalty)
  - `Registry::FileRegistry`: Append-only JSONL storage with hash-chain integrity (`_prev_entry_hash`) implementing constitutive recording (Proposition 5)
  - `Transport`: Abstraction layer for MMP, Hestia, and Local transport mechanisms
  - 7 MCP tools: `attestation_issue`, `attestation_verify`, `attestation_revoke`, `attestation_list`, `trust_query`, `challenge_create`, `challenge_respond`
  - 88 unit tests

- **MMP Handler Extension Mechanism**: `MMP::Protocol.register_handler` allows SkillSets to register custom MMP actions without modifying core protocol code. Thread-safe with Mutex, built-in action override prevention.

- **MMP Bearer Token Authentication**: `MMP::PeerManager` now includes `session_token` in Peer struct, extracted during `introduce_to` handshake and sent as `Authorization: Bearer` header on all subsequent messages.

- **MeetingRouter Authenticated Peer Injection**: `MeetingRouter#handle_message` injects `_authenticated_peer_id` into message body, enabling receiving handlers to verify sender identity.

- **SkillSet Eager Loading in HTTP Mode**: `HttpServer` now calls `eager_load_skillsets` during initialization, ensuring SkillSet MMP handlers are registered before the first HTTP request.

- **L1 Knowledge**: Synoptis attestation knowledge (EN/JP) with `readme_order: 4.7` for auto-generated README inclusion.

- **Self-Development Workflow v1.2**: Added SkillSet Release Checklist to `kairoschain_self_development` knowledge (EN/JP) — covers L1 knowledge creation for README, `rake build_readme`, version/changelog updates, and gem build/publish.

### Changed

- **MMP SkillSet**: `meeting.yml` default changed from `enabled: false` to `enabled: true`

---

## [2.6.0] - 2026-03-05

### Added

- **Self-Development Workflow (L1 Knowledge)**: New `kairoschain_self_development` knowledge documenting the self-referential development pattern — using KairosChain to develop KairosChain itself. Covers `.kairos/` initialization in project root, the three-step development cycle (develop → promote → reconstitute), promotion target guidelines (`knowledge/` vs `templates/`), ordering constraints for chicken-and-egg scenarios, and philosophical grounding (Propositions 5, 6, 7, 9). This is the last change made without using KairosChain's own tools — subsequent development will use the self-development workflow.

---

## [2.5.0] - 2026-03-03

### Added

- **Cross-Instance Knowledge Discovery**: KairosChain instances connected to a Meeting Place can now publish knowledge gaps as "needs" to the SkillBoard. Other agents browsing the board can discover these needs and offer relevant knowledge.
  - `skills_audit(command: "export_needs")`: New audit command to package knowledge gaps for cross-instance sharing
  - `meeting_publish_needs`: New Hestia MCP tool to publish needs to the Meeting Place board (requires explicit `opt_in: true`)
  - `SkillBoard#post_need` / `remove_needs`: In-memory need entries (session-only, no persistence — DEE compliant)
  - `POST /place/v1/board/needs`: New HTTP endpoint to publish knowledge needs
  - `DELETE /place/v1/board/needs`: New HTTP endpoint to remove published needs
  - `browse(type: 'need')`: Filter board entries to show only knowledge needs
  - Needs are automatically cleaned up on agent unregister

- **Knowledge Acquisition Policy — Cross-Instance Extension**: Tutorial template Acquisition Behavior now includes opt-in cross-instance knowledge needs publishing guidance

- **L1 Knowledge Updates**: Updated `hestiachain_meeting_place` (EN/JP), `kairoschain_usage` (EN/JP), `kairoschain_operations` (EN/JP), `persona_definitions` with cross-instance discovery, proactive tool usage, and dynamic persona suggestion documentation

### Fixed

- **PlaceRouter query string parsing**: Added missing `require 'uri'` — `parse_query` was silently failing due to `NameError` on `URI.decode_www_form`, causing all browse query parameters (`type`, `search`, `limit`) to be ignored

---

## [2.4.0] - 2026-03-03

### Added

- **Dynamic Persona Suggestion** (`skills_promote` command: `"suggest"`): New 2-step workflow where the LLM analyzes source content and suggests optimal personas (type and count) before running Persona Assembly. Generates a structured suggestion template with content preview, available personas, and YAML response format.

- **Custom Persona Support**: Both `skills_promote` and `skills_audit` now accept arbitrary custom persona names in the `personas` parameter. The LLM infers roles from persona names and context when no pre-defined definition exists.

- **Improved Unknown Persona Handling**:
  - `skills_promote`: Unknown personas now show "(custom persona — no pre-defined definition. Infer role from name and evaluate accordingly.)" instead of "(definition not found)"
  - `skills_audit`: Unknown personas get a rich template with humanized name, inferred focus, and key insight fields

---

## [2.3.1] - 2026-03-03

### Fixed

- **Tutorial mode activation**: Mark `kairos_tutorial.md` as ACTIVE when tutorial mode is set
- **SystemUpgrade**: Add missing `require 'fileutils'` and resolve gem-internal template paths

---

## [2.3.0] - 2026-03-03

### Added

- **Tutorial instruction mode** (`kairos_tutorial.md`): New built-in onboarding mode with behavioral gradient that evolves based on accumulated L2/L1 content. Includes existing project fast-track detection, progressive concept introduction, and content-based (not count-based) phase transitions. Tutorial mode is now the default for new `kairos-chain init`.

- **Proactive Tool Usage** across all instruction modes:
  - **Tutorial mode**: Gradual MCP tool usage starting with `context_save`, expanding to `knowledge_update` and `skills_audit` as content accumulates
  - **User mode**: Session-level `chain_status`, `knowledge_list` checks, pattern detection with `knowledge_update` proposals
  - **Developer mode** (`[BEHAVIOR-010]`): Full proactive usage including `chain_verify`, `state_status`, `skills_audit`, and `skills_evolve` awareness

### Changed

- **Default `instructions_mode`**: Changed from `user` to `tutorial` for new installations. Existing instances with explicit `instructions_mode` in config.yml are unaffected.
- **Protected files**: `kairos_tutorial.md` added to built-in protected files (cannot be deleted via `instructions_update`)
- **Reserved modes**: `tutorial` added to reserved mode names alongside `developer`, `user`, `none`

---

## [2.2.0] - 2026-02-25

### Changed

- **Unified L1 Meta-Philosophy (v2.0)**: Integrated three meta-level philosophical analyses into a single L1 knowledge entry with 9 propositions organized in 4 thematic groups (Ontological Foundations, Integrity, Possibility and Time, Cognition and Relations). Each proposition carries [ML1/ML2/ML3] provenance labels. Structure marked as provisional per Persona Assembly consensus (6 personas, 2 rounds).
  - New: `knowledge/kairoschain_meta_philosophy/kairoschain_meta_philosophy.md` (EN, v2.0)
  - New: `knowledge/kairoschain_meta_philosophy_jp/kairoschain_meta_philosophy_jp.md` (JP, v2.0)
  - Removed: `kairoschain_philosophy/kairoschain_meta_philosophy.md` (v1.0, superseded)
  - Removed: `kairoschain_philosophy/kairoschain_meta_philosophy2.md` (v1.0, superseded)
  - Removed: `kairoschain_philosophy_jp/kairoschain_meta_philosophy_jp.md` (v1.0, superseded)
  - Removed: `kairoschain_philosophy_jp/kairoschain_meta_philosophy2_jp.md` (v1.0, superseded)

- **CLAUDE.md**: Updated Five Propositions → Nine Propositions with thematic groups and provenance labels. Updated Deep Reference to include third meta-level and case study.

### Added

- **Third Meta-Level Philosophy (docs/)**: Full analysis of metacognitive dynamic process, human-system composite cognition, and incompleteness as evolutionary driver (EN/JP)
- **Self-Referential Metacognition Case Study (docs/)**: Developer experience record documenting L1 registration triggering metacognitive reflection — classified as generative example, not L1 knowledge (EN/JP)

---

## [2.1.0] - 2026-02-25

### Added

- **Phase 1: DSL/AST Partial Formalization Layer**
  - `AstNode` Struct and `DefinitionContext` with 5 node types (Constraint, SemanticReasoning, Plan, ToolCall, Check)
  - `Skill` Struct extended with `:definition` and `:formalization_notes` fields
  - `FormalizationDecision` class for on-chain provenance records
  - `formalization_record` MCP tool: record formalization decisions to blockchain
  - `formalization_history` MCP tool: query accumulated formalization decisions
  - `skills_dsl_get` enhanced with Definition (Structural Layer) and Formalization Notes (Provenance Layer) sections
  - `core_safety` and `evolution_rules` L0 skills annotated with definition blocks
  - 68 tests (test_dsl_ast_phase1.rb)

- **Phase 2: AST Verification Engine, Decompiler, and Drift Detection**
  - `AstEngine`: Pattern-matched structural verification (no eval) with condition evaluation (==, <, >=, .method?(), not in)
  - `Decompiler`: AST to human-readable Markdown reconstruction
  - `DriftDetector`: Content/definition layer divergence detection with coverage_ratio and keyword matching (no LLM)
  - `definition_verify` MCP tool: structural constraint verification report
  - `definition_decompile` MCP tool: reverse AST to human-readable form
  - `definition_drift` MCP tool: detect content/definition layer misalignment
  - `skills_dsl_get` enhanced with Verification Status section (with fallback)
  - Security: method call whitelist for condition evaluation, type-safe numeric comparisons
  - 91 tests (test_dsl_ast_phase2.rb), full backward compatibility with Phase 1

- **DSL/AST Source of Truth Policy**: Ruby DSL (.rb) is authoritative; JSON representations are derived outputs

- **Upgrade notification at MCP session start**: `Protocol#handle_initialize` checks gem vs. data version via `UpgradeAnalyzer` and returns a `notifications` entry when an upgrade is available, so LLM clients are informed at session start without disrupting normal operation

### Fixed

- **Deadlock in PendingChanges#summary**: Recursive locking when summary calls constraint check methods within already-held @mutex synchronize block. Separated lock acquisition (public API) from logic (private methods). Made check_trigger_conditions atomic.

---

## [2.0.4] - 2026-02-25

### Fixed

- **Storage path inconsistency**: `SnapshotManager` resolved `snapshot_dir` relative to `Dir.pwd` (project root) instead of `.kairos/` data directory — snapshots were written to `./storage/snapshots/` instead of `.kairos/storage/snapshots/`. Added `resolve_snapshot_dir()` to ensure all storage paths use consistent base directory resolution.

---

## [2.0.3] - 2026-02-24

### Fixed

- **Bug#1**: `SafeEvolver::DSL_PATH` undefined constant in `approval_workflow` skill behavior — changed to `KairosMcp.dsl_path` (L0 evolution was completely broken)
- **Bug#3a**: `ContextManager#get` undefined method in `skills_promote` — corrected to `get_context` (L2→L1 promotion was broken)
- **Bug#3b**: `SkillEntry#raw_content` undefined attribute in `skills_promote` — replaced with `File.read(context.md_file_path)` for L2 content loading
- **Bug#3c**: UTF-8 encoding errors on non-UTF-8 locales — added `Encoding.default_external/internal` in `bin/kairos-chain` and explicit `encoding: 'UTF-8'` to `File.read` calls in `anthropic_skill_parser.rb` and `skills_promote.rb`

---

## [2.0.2] - 2026-02-23

### Added

- **Dynamic `instructions_mode`**: Custom mode resolution for MCP instructions
  - `instructions_mode: 'researcher'` now resolves to `skills/researcher.md`
  - Any `.md` file in `skills/` can serve as an instruction source
  - Built-in modes (`developer`, `user`, `none`) unchanged
- **`instructions_update` tool**: L0-level instructions management with 5 commands
  - `status`: Show current mode and available instruction files
  - `create`: Create new instruction file (requires human approval)
  - `update`: Update existing instruction file (requires human approval)
  - `delete`: Delete custom instruction file (built-in protected)
  - `set_mode`: Switch `instructions_mode` in config.yml (requires human approval)
  - All changes recorded to blockchain (full recording, L0_law level)
  - Path traversal protection, reserved mode name guard, active mode deletion prevention
- **L1 Knowledge**: HestiaChain Meeting Place knowledge added to active knowledge directory
- **L1 Knowledge**: Updated operations roadmap with Phase 4A/4B completion info

### Fixed

- **Encoding**: Added `# encoding: utf-8` to `kairos.rb` DSL files (fixes multibyte char errors with arrows/emojis)
- **Encoding**: Added UTF-8 encoding to `build_readme.rb` file reads (fixes README generation on non-UTF-8 locales)
- **L1 Knowledge**: Updated tool count from 25 to 26 in usage documentation (EN + JP)
- **L1 Knowledge**: Restored Phase 4.pre/4A/4B progress info in operations knowledge (EN + JP)

---

## [2.0.1] - 2026-02-23

### Added

- **MCP Instructions**: `instructions` field in `initialize` response delivers
  KairosChain philosophy or quick guide to LLM on connection
  - `instructions_mode` config: `developer` (full kairos.md), `user` (quick guide), `none`
  - New template: `kairos_quickguide.md` — concise user-facing operational guide
- **L0-A Philosophy**: Added PHILOSOPHY-001 (Generative Principle) and
  PHILOSOPHY-005 (Five Propositions) to `kairos.md`
- **Agent Instruction Sync**: `scripts/sync_agent_instructions.sh` syncs CLAUDE.md
  to `.cursor/rules/kairos.mdc` for Cursor IDE support
- **Test**: Initialize instructions test (Test 0) in `test_local.rb`

## [2.0.0] - 2026-02-23

### Breaking Changes

- **HestiaChain Meeting Place Server**: New `/place/v1/*` HTTP endpoints require
  the `hestia` SkillSet to be installed. Existing MMP P2P endpoints (`/meeting/v1/*`)
  are unchanged.
- **SkillSet versioning**: `depends_on` now supports semantic version constraints
  (e.g., `{name: "mmp", version: ">= 1.0.0"}`). Old array format still accepted.

### Added

- **Phase 4.pre**: Authentication and hardening for HTTP server
  - Admin token rotation via `token_manage` tool
  - Session-based authentication for P2P endpoints
- **Phase 4A**: HestiaChain Foundation — Self-contained SkillSet + DEE Protocol
  - `Hestia::Chain::Core` (Anchor, Client, Config, BatchProcessor)
  - `Hestia::Chain::Backend` (InMemory stage 0, PrivateJSON stage 1)
  - `Hestia::Chain::Protocol` (DEE types, PhilosophyDeclaration, ObservationLog)
  - `Hestia::Chain::Integrations::MeetingProtocol`
  - `Hestia::HestiaChainAdapter` implementing `MMP::ChainAdapter`
  - `Hestia::ChainMigrator` with stage-gate migration (0→1)
  - MCP tools: `chain_migrate_status`, `chain_migrate_execute`,
    `philosophy_anchor`, `record_observation`
  - 77 new test assertions
- **Phase 4B**: Meeting Place Server
  - `Hestia::AgentRegistry` — JSON-persisted, Mutex thread-safe, self_register
  - `Hestia::SkillBoard` — Random sampling (DEE D3: no ranking)
  - `Hestia::HeartbeatManager` — TTL-based fadeout with ObservationLog recording
  - `Hestia::PlaceRouter` — Rack-compatible HTTP routing for `/place/v1/*`
  - HTTP endpoints: `/place/v1/info`, `register`, `unregister`, `agents`,
    `board/browse`, `keys/:id`
  - MCP tools: `meeting_place_start`, `meeting_place_status`
  - PlaceRouter integrated into existing HttpServer (same pattern as MeetingRouter)
  - 70 new test assertions

### Fixed

- Add missing `require 'uri'` in MeetingRouter (query string parsing)
- Rakefile now includes Phase 4A/4B integration tests via `rake test_all`

### Test Results

- **Total**: 356 assertions passed, 0 failed
- Phase 1–3.85 (existing): 170, Phase 4A: 77, Phase 4B: 70, SkillSet manager: 37

---

## [1.2.0] - 2026-02-22

### Added

- **Phase 1**: SkillSet Plugin Infrastructure
  - `SkillSetManager` for installing/uninstalling SkillSet packages
  - SkillSet manifest format (`skillset.json`)
  - Namespace isolation for SkillSet tools and knowledge
- **Phase 2**: MMP SkillSet packaging + P2P direct mode
  - MMP packaged as a self-contained SkillSet
  - `/meeting/v1/*` HTTP endpoints for P2P communication
  - `MMP::Identity`, `MMP::MeetingSessionStore`
- **Phase 3**: Knowledge-only SkillSet exchange via MMP P2P
  - `SkillExchange` with content hash verification and provenance tracking
  - `knowledge_only` mode for safe skill sharing
- **Phase 3.5**: Security fixes and MMP wire protocol specification
  - Name sanitization, path traversal guard
  - Extended `knowledge_only` integrity check
  - MMP wire protocol spec document
- **Phase 3.7**: Pre-Phase 4 hardening
  - RSA signature verification for handshake (`Identity#introduce`)
  - `depends_on` semantic version constraints (`Gem::Requirement`)
  - `PeerManager` persistence with TOFU trust model
- **Phase 3.75**: MMP extension infrastructure
  - Collision detection, extension advertise, core action guard
- **Phase 3.85**: Pre-merge hardening
  - `.gitignore`: `*.pem`, `*.pem.pub`, `keys/`
  - Error message sanitization in HTTP responses
  - `DEFAULT_HOST` changed from `0.0.0.0` to `127.0.0.1`

### Test Results

- **Total**: 170 assertions passed, 0 failed

---

## [1.0.0] - 2026-02-14

### Added

- Renamed gem from `kairos_mcp` to `kairos-chain`
- Bundle official L1 knowledge in gem
- Upgrade migration system (`system_upgrade` tool)
- htmx-based Admin UI for Streamable HTTP server
- Claude Code plugin marketplace support

---

## [0.9.0] - 2026-02-12

### Added

- Streamable HTTP transport with Bearer token authentication
- Puma web server integration
- Admin UI with L2 Context viewer

---

## [0.1.0] - 2026-01-15

### Added

- Initial release
- Layered skill architecture (L0/L1/L2)
- Private blockchain for auditability
- Skills DSL with Ruby AST
- MCP (Model Context Protocol) server via stdio
- Vector search for skills and knowledge (optional RAG)
- SQLite storage backend (optional)
- StateCommit for cross-layer auditability
- Skill promotion with Persona Assembly
- Tool guide and metadata system

[3.1.1]: https://github.com/masaomi/KairosChain_2026/compare/v3.1.0...v3.1.1
[3.1.0]: https://github.com/masaomi/KairosChain_2026/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.10.1...v3.0.0
[2.10.1]: https://github.com/masaomi/KairosChain_2026/compare/v2.10.0...v2.10.1
[2.10.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.7.0...v2.8.0
[2.7.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.3.1...v2.4.0
[2.3.1]: https://github.com/masaomi/KairosChain_2026/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/masaomi/KairosChain_2026/compare/v2.1.0...v2.2.0
[2.0.5]: https://github.com/masaomi/KairosChain_2026/compare/v2.0.4...v2.0.5
[2.0.4]: https://github.com/masaomi/KairosChain_2026/compare/v2.0.3...v2.0.4
[2.0.3]: https://github.com/masaomi/KairosChain_2026/compare/v2.0.2...v2.0.3
[2.0.2]: https://github.com/masaomi/KairosChain_2026/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/masaomi/KairosChain_2026/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/masaomi/KairosChain_2026/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/masaomi/KairosChain_2026/compare/v1.0.0...v1.2.0
[1.0.0]: https://github.com/masaomi/KairosChain_2026/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/masaomi/KairosChain_2026/compare/v0.1.0...v0.9.0
[0.1.0]: https://github.com/masaomi/KairosChain_2026/releases/tag/v0.1.0
