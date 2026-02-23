# Changelog

All notable changes to the `kairos-chain` gem will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

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

[2.0.0]: https://github.com/masaomi/KairosChain_2026/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/masaomi/KairosChain_2026/compare/v1.0.0...v1.2.0
[1.0.0]: https://github.com/masaomi/KairosChain_2026/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/masaomi/KairosChain_2026/compare/v0.1.0...v0.9.0
[0.1.0]: https://github.com/masaomi/KairosChain_2026/releases/tag/v0.1.0
