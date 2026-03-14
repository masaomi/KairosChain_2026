# Changelog

All notable changes to the `kairos-chain` gem will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

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
