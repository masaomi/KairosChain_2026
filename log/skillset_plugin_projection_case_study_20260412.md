# SkillSet Plugin Projection: A Case Study in Self-Referential System Design

**Authors**: Masaomi Hatakeyama, Claude Opus 4.6
**Date**: 2026-04-12
**Affiliation**: University of Zurich, Functional Genomics Center Zurich
**Status**: Draft (pre-Zenodo)

---

## Abstract

We present SkillSet Plugin Projection, a mechanism by which KairosChain — a self-amendment MCP server framework — projects its internal SkillSet definitions into Claude Code plugin artifacts. The projection creates a dual-mode bridge: SkillSets simultaneously serve as MCP tools (core functionality) and as Claude Code native skills, agents, and hooks (UX layer). A self-referential SkillSet (`plugin_projector`) projects its own description, demonstrating recursive self-projection bounded by structural incompleteness. We document the design process, including a compiler-style bootstrap for the chicken-and-egg problem, Phase 0 experimental validation, and a 3-LLM implementation review (Claude Opus 4.6 + Codex GPT-5.4 + Cursor Composer-2). The case study is analyzed through dual vocabulary: system engineering concepts alongside KairosChain's nine philosophical propositions.

---

## 1. Introduction

### 1.1 The Problem

Modern AI agent frameworks operate through the Model Context Protocol (MCP), providing tools that LLM clients can invoke. However, LLM client environments (Claude Code, Cursor, Codex) offer native capabilities — skills, sub-agents, lifecycle hooks — that MCP alone cannot provide. The gap between "what the MCP server offers" and "what the client environment can do" creates a UX limitation: users must manually configure client-side features to complement MCP tools.

### 1.2 The Approach

KairosChain addresses this gap by treating plugin artifacts as projections of its internal SkillSet definitions. Rather than maintaining separate MCP tools and client-side configurations, a single SkillSet definition produces both:

- **MCP tools** (`tools/*.rb`) — core functionality via MCP protocol
- **Plugin artifacts** (`plugin/SKILL.md`, `plugin/agents/*.md`, `plugin/hooks.json`) — Claude Code native UX

The `PluginProjector` class reads enabled SkillSets and writes their plugin artifacts to the appropriate client-side locations, with dual-mode support for project-level (`.claude/`) and plugin-level (root) configurations.

### 1.3 Contributions

1. A dual-mode projection architecture that bridges MCP servers and Claude Code plugins
2. A compiler-style bootstrap mechanism for the initialization ordering problem
3. A self-referential SkillSet that projects its own interface
4. A 3-LLM review methodology applied to both design and implementation
5. Experimental validation (Phase 0) that informed design revisions

---

## 2. Architecture

### 2.1 Dual Vocabulary

| System Engineering Term | Philosophical Term (KairosChain) | Description |
|------------------------|----------------------------------|-------------|
| Projection | Partial identity (命題1) | Same source, two representations |
| Bootstrap | Temporal unfolding of self-referentiality | Seed → project → recognize |
| Digest-based no-op | Constitutive recording (命題5) | Change detection via content hash |
| Stale cleanup | Autopoietic boundary maintenance (命題2) | Removing artifacts that no longer have sources |
| `_projected_by` tag | Provenance recording | Distinguishing projected from user-authored hooks |
| Dual-mode (project/plugin) | Structure opens possibility (命題4) | Single mechanism, multiple output targets |
| settings.json merge | Asymmetric structural coupling (命題8) | Guest integration into host's configuration space |
| Ruby introspection | Metacognitive self-referentiality (命題7) | System describing its own capabilities at runtime |

### 2.2 The Three Execution Paths

```
Path A: MCP (existing, unchanged)
  Claude Code → MCP protocol → KairosChain → SkillSet tools

Path B: Claude Code Native (new, complementary)
  Claude Code → .claude/skills/{name}/SKILL.md → workflow guide
              → .claude/settings.json hooks → lifecycle automation
              → .claude/agents/{name}.md → specialized sub-agents

Path C: Knowledge Meta Skill (new, indirect reference)
  Claude Code → .claude/skills/kairos-knowledge/SKILL.md → L1 knowledge catalog
              → MCP knowledge_get → on-demand content access
```

Path A provides core functionality. Path B provides Claude Code native features that MCP cannot offer (agents, hooks, skill discovery). Path C bridges the L1 knowledge layer into Claude Code's skill visibility. B and C complement A but do not replace it.

### 2.3 What MCP Already Provides vs. What Plugin Adds

| Capability | MCP (existing) | Plugin (new) |
|------------|---------------|-------------|
| Tool execution | Yes | — |
| Tool usage guidance | Yes (instructions, tool_guide) | Yes (SKILL.md, complementary) |
| L1 knowledge access | Yes (knowledge_get/list) | Yes (kairos-knowledge meta skill, catalog only) |
| Custom sub-agents | No | Yes (agents/*.md) |
| Lifecycle automation | No | Yes (hooks in settings.json) |
| User discoverability | No (must know tool names) | Yes (/help, /skill-name) |
| One-step distribution | No (.mcp.json manual setup) | Yes (--plugin-dir) |

The plugin's essential value is not "teaching Claude how to use tools" (MCP already does this) but integrating with Claude Code native features that MCP cannot provide.

---

## 3. Bootstrap: Solving the Chicken-and-Egg Problem

### 3.1 The Problem

Claude Code reads skills and hooks at session start, then starts MCP servers. The PluginProjector runs during MCP `handle_initialize`. Therefore, projected skills are not available during the session that triggers their initial projection.

### 3.2 The Compiler Analogy

```
GCC Bootstrap:
  Stage 0: Build minimal GCC with existing compiler
  Stage 1: Build full GCC with Stage 0
  Stage 2: Rebuild GCC with Stage 1 (verification)

KairosChain Bootstrap:
  Stage 0: Seed (plugin.json + .mcp.json + seed SKILL.md) — committed to repository
  Stage 1: MCP initialize → PluginProjector.project! — writes skills/, agents/, hooks
  Stage 2: /reload-plugins → Claude Code recognizes new artifacts
```

### 3.3 Session Timeline

```
[Session 1 — First Use]
  1. Claude Code starts → reads seed SKILL.md (minimal guide)
  2. MCP server starts → handle_initialize → PluginProjector projects all artifacts
  3. User invokes MCP tool → PostToolUse hook (if configured) → no-op (already projected)
  4. User runs /reload-plugins → per-SkillSet skills now visible
  5. Full plugin functionality available

[Session 2+ — Subsequent Use]
  1. Claude Code starts → reads previously projected skills (full set on disk)
  2. MCP server starts → handle_initialize → project_if_changed! → no-op (digest match)
  3. Full plugin functionality available immediately
```

### 3.4 Phase 0 Validation

The bootstrap design was validated experimentally before implementation:

| Test | Result | Impact on Design |
|------|--------|-----------------|
| Multiple `.claude/skills/` coexist | PASS | Per-SkillSet projection confirmed viable |
| Extra frontmatter fields ignored | PASS | `_projected_by` provenance safe |
| Hooks in settings.json (not hooks.json) | PASS | Project mode writes to settings.json |
| PostToolUse stdout → Claude | **FAIL** | Redesigned to use `additionalContext` JSON |
| /reload-plugins picks up new skills | PASS | Bootstrap Stage 2 confirmed |
| Hooks auto-reload on settings change | PASS | Hooks effective without /reload-plugins |

The Phase 0 failure (stdout not reaching Claude) led to a significant design revision: hook output uses `additionalContext` JSON instead of stdout, and the design explicitly documents this as a Claude Code harness dependency (Non-Claim #6).

---

## 4. Self-Referential Loop

### 4.1 Structure

The `plugin_projector` SkillSet is itself a SkillSet with a `plugin/` directory:

```
plugin_projector/
├── tools/plugin_project.rb     → MCP tool: "execute projection"
├── plugin/SKILL.md             → "how to use projection" + <!-- AUTO_TOOLS -->
└── plugin/hooks.json           → "monitor skill changes"
```

When `PluginProjector.project!` runs, it processes all enabled SkillSets including `plugin_projector` itself:

1. Reads `plugin_projector/plugin/SKILL.md`
2. Introspects `PluginProject` tool class via Ruby reflection
3. Generates tool documentation from `input_schema`
4. Writes to `.claude/skills/plugin_projector/SKILL.md`
5. Merges `plugin_projector/plugin/hooks.json` into `.claude/settings.json`

The projected hooks monitor `skills_promote`, `skills_evolve`, etc. When these tools fire, the hooks trigger re-projection, which updates the hooks themselves — closing the self-referential loop.

### 4.2 Philosophical Analysis

**Proposition 1 (Self-Referentiality)**: The governance of plugin artifacts is identical to the governance of SkillSets. The same blockchain recording, attestation, and exchange mechanisms apply. This is genuine structural self-referentiality: the subject governing plugins IS the subject being projected as plugins.

**Precision note**: The self-projection is recursive file generation, not Godelian self-reference. The true Godelian moment is the unpredictability of projection outcomes when multiple SkillSets contribute hooks simultaneously — the projector cannot fully predict the merged `settings.json` because other SkillSets' hooks interact with its own.

**Proposition 2 (Partial Autopoiesis)**: The bootstrap loop (seed → project → hooks → re-project) achieves partial autopoietic closure. The closure is partial because:
- Stage 2 depends on Claude Code's `/reload-plugins` (harness dependency)
- The projection writes to Claude Code's configuration space as a guest, not a host
- The system cannot modify its own execution substrate (Ruby VM, filesystem)

**Proposition 4 (Structure Opens Possibility)**: The SkillSet format extension (`plugin/` directory) opens the possibility space of "Claude Code native integration." The dual-mode architecture (project/plugin) further expands this space to multiple deployment targets.

**Proposition 6 (Incompleteness as Driving Force)**: The projection is lossy — `tools/*.rb` execution code is not projected, only metadata descriptions. The projection is also irreversible — one cannot reconstruct the SkillSet from its projected artifacts. This triple incompleteness (lossy, unpredictable, irreversible) drives perpetual evolution: each projection is a new interpretation of the current system state.

**Proposition 8 (Co-Dependent Origination)**: The KairosChain-Claude Code relationship is asymmetric structural coupling. KairosChain adapts to Claude Code's specifications (settings.json format, skill discovery paths, hooks semantics), but Claude Code does not adapt to KairosChain. This is closer to commensalism than mutual co-dependence. The coupling deepens through settings.json — a shared text that both systems read and write.

### 4.3 Non-Claims

1. Complete autopoietic closure is not achieved — the system depends on external harness
2. Hooks execution is not structurally guaranteed — Claude Code harness jurisdiction
3. Projection is a snapshot, not real-time synchronization
4. "Plugin IS MCP Server" is partial identity — MCP is core, Plugin is UX layer
5. Client execution governance is not provided — sandbox, cache, reload are harness concerns
6. Bootstrap Stage 2 depends on `/reload-plugins` — automatic invocation is not guaranteed
7. First session has limited per-SkillSet skills — only seed guide is immediately available
8. Self-hosting is not achieved — bootstrap is human-seeded + harness-dependent
9. Projection is lossy (irreversible) — plugin artifacts cannot reconstruct the SkillSet
10. Projection contains partial information only — implementation code is not projected
11. Knowledge meta skill contains catalog only — content is accessed via MCP on demand
12. settings.json merge is a Claude Code specification dependency — may become obsolete if `.claude/hooks/` is supported in the future

---

## 5. 3-LLM Review Methodology

### 5.1 Process

The implementation underwent multi-LLM review at each phase:

| Phase | Review Type | LLMs | Key Findings |
|-------|------------|------|-------------|
| Design v2.2 | Persona Assembly (6 personas) | Claude Opus 4.6 | 5 P1: digest unification, introspection fallback, user hooks preservation |
| Design v2.2r1 | Persona Assembly | Claude Opus 4.6 | 5 P1: atomic write, JSON parse error, additionalContext test |
| Phase 2 | Focused Persona Assembly | Claude Opus 4.6 | 3 P1: agent-monitor workflow, Bash disallowed, scaffold update |
| Phase 3 | Focused Persona Assembly | Claude Opus 4.6 | 2 P1: knowledge duplication, seed fallback content |
| Phase 4 | Implementation review | Claude + Codex + Cursor | 7 P0/P1: CLI typo, path traversal, cleanup safety, hook injection |

### 5.2 Convergence Pattern

All three LLMs in Phase 4 independently identified the same top issues:

| Issue | Claude | Codex | Cursor |
|-------|--------|-------|--------|
| CLI `SkillsetManager` typo | P0 | P1 | P0 |
| `cleanup_stale!` path safety | P1 | P0 | P0 |
| `ss.name` path traversal | P1 | P0 | P0 |
| CLI knowledge duplication | P0 | P1 | P1 |

3/3 convergence on the same issues provides high confidence that these are genuine problems, not false positives.

### 5.3 LLM Characteristics Observed

- **Claude Opus 4.6**: Strongest on philosophical alignment and self-referentiality analysis. Identified the Godelian precision issue.
- **Codex GPT-5.4**: Deepest security analysis. Identified hook command injection and knowledge digest incompleteness.
- **Cursor Composer-2**: Most thorough on mode detection inconsistency and cross-platform concerns.

### 5.4 Design-Implementation Bug Categories

Design reviews (Phase 2-3) found architectural issues: agent workflow underspecification, hooks trigger scope, scaffold consistency. Implementation reviews (Phase 4) found code-level bugs: class name typos, path safety, race conditions. These categories are complementary — design review alone would not have caught the CLI NameError, and implementation review alone would not have caught the agent-monitor underspecification.

---

## 6. Implementation Summary

### 6.1 Metrics

| Metric | Value |
|--------|-------|
| New code (plugin_projector.rb) | ~430 lines |
| Modified files | 10 |
| New SkillSet templates | 4 (agent, exchange, creator, plugin_projector) |
| Test count | 30 (Phase 1) + 18 (Phase 2) + 13 (Phase 3) = 61 |
| Test failures | 0 |
| Review rounds | 6 (design) + 1 (implementation) = 7 |
| P0/P1 findings (total) | 22 |
| P0/P1 resolved | 22 |

### 6.2 Key Implementation Decisions

| Decision | Rationale |
|----------|-----------|
| Atomic write (Tempfile + rename) | settings.json auto-reload can read partial JSON |
| `_projected_by` tag for hook ownership | Minimal intrusion into user settings |
| `SAFE_NAME_PATTERN` validation | Prevent path traversal from malicious SkillSet names |
| `safe_path?` boundary check | Defense-in-depth for cleanup_stale! |
| Digest includes description/tags | Detect knowledge metadata changes (Codex finding) |
| `ALLOWED_HOOK_COMMANDS` warning | Alert on non-standard commands without blocking |

---

## 7. Conclusion

SkillSet Plugin Projection demonstrates that an MCP server framework can extend itself into a client plugin ecosystem through self-referential projection. The mechanism is bounded by structural incompleteness (lossy projection, harness dependency, asymmetric coupling) but achieves genuine recursive self-projection: the PluginProjector SkillSet projects its own interface description.

The experimental validation approach (Phase 0) proved essential — discovering that Claude Code's hooks use settings.json (not a separate hooks.json) and that PostToolUse stdout does not reach the model led to significant design revisions that would not have been caught by theoretical analysis alone.

The 3-LLM review methodology provides complementary perspectives: design reviews catch architectural gaps, implementation reviews catch code-level bugs, and convergence across LLMs provides confidence in findings.

---

## References

- KairosChain Nine Propositions: `CLAUDE.md`
- KairosChain Philosophy (3 levels): `docs/KairosChain_3levels_self-referentiality_en_20260221.md`
- Design Document: `log/skillset_plugin_projection_design_v2.2_20260404.md`
- Phase 4 Reviews: `log/skillset_plugin_projection_phase4_implementation_review_20260412.md`, `log/phase4_review_codex_gpt5.4_20260412.md`, `log/phase4_review_cursor_composer2_20260412.md`
- Claude Code Plugin Specification: https://code.claude.com/docs/en/plugins
