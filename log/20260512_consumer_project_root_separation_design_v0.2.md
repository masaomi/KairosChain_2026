# Consumer Project Root Separation Design v0.2

**Status:** Draft — post-revision (round 1 verdict: REVISE; 1/5 APPROVE)
**Origin:** SUSHI integration testing (2026-05, silent projection failure)
**Scope:** KairosChain core, all transport modes
**Integration:** Sub-author (Opus 4.6) draft as structural base; orchestrator (Opus 4.7) refinements spliced in. Reject log: `log/20260512_consumer_project_root_separation_design_v0.2_reject_log.md`.

---

## § Revision Notes (v0.1 → v0.2)

**P0 resolutions:**

- P0-A (defaulted-but-wrong cwd → silent failure): tightened **Inv 6** to require a plausibility predicate on any defaulted root. Plausibility-signal candidates → §11.
- P0-B (§6 row 7 vs Inv 3): reclassified the "project root == data directory" row to **loud failure**. Inv 3 strengthened to forbid coincidence at the real-path level.
- P0-C (multi-project identity routing): new **Inv 9** requires per-request consumer identification in shared-instance configurations.
- P0-D (realpath/symlink policy): new **Inv 8** mandates real-path resolution as the canonical comparison form.

**P1 resolutions:**

- P1-E (§4 mechanism leak): concrete default-rule wording removed from §4 body; relocated to §11.
- P1-F (HTTP MCP §4/§6 inconsistency): unified to **loud failure** for HTTP MCP no-default. §4 and §6 now agree.
- P1-G (authorization boundary): tightened **Inv 4** to require consumer authorization (not merely writability).

**Invariant count: 9** (v0.1 had 7; +2 new, 2 existing tightened). The "≤7" target in the v0.1 goal was a starting budget; review-driven evolution is within scope.

**Inv 2 reworded** (orchestrator contribution): the v0.1 phrasing "explicit over implicit" left the apparent Inv 2 ↔ Inv 6 tension unresolved in the body. The v0.2 wording makes the distinction explicit — defaulting is a named, recordable act, not silent inference.

**Deliberately unchanged:** §9 out-of-scope; §10 criteria 1–7 structure (criterion 7 augmented with one authorization sub-question); risk list bones (Risk 3 reframed since the symlink question is now decided).

---

## §1 Problem Statement

KairosChain currently derives the consumer project root from the data directory by ascending to its parent. This derivation encodes an assumption: that the data directory (`.kairos/`) is always a direct child of the project it serves. The assumption holds for the common case — a developer runs `kairos init` inside their project, creating `.kairos/` as a sibling of their working tree — but fails structurally in three scenarios:

1. **Remote data directory.** A consumer project on machine A connects via `--data-dir` to a KairosChain instance whose `.kairos/` lives on machine B (or a mounted path unrelated to the consumer's workspace). The parent of that remote `.kairos/` is not the consumer project.

2. **Shared instance.** Multiple consumer projects share one KairosChain data directory. The parent of the shared `.kairos/` is at most one of those projects. Without per-request consumer identification, routing projection artifacts to the correct project is impossible.

3. **Non-parent mount.** The data directory is symlinked, bind-mounted, or otherwise located at a path whose parent directory has no relationship to any project workspace.

In all three cases, plugin projection — the mechanism that delivers operational artifacts to the LLM harness — targets the wrong directory. The four known affected artifact locations are:

- `CLAUDE.md` (project-level instructions, `@`-imported content)
- `.claude/` directory (plugin artifacts, `settings.json`, projected SkillSet content)
- `.claude/kairos/instruction_mode.md` (active instruction mode body)
- `.claude/kairos/projection_manifest.json` (SkillSet-to-artifact mapping)

**The failure is silent.** No error is raised. No warning is emitted. The artifacts are written to a location the consumer project's LLM harness never reads. The instruction mode body — which may contain the entire operational constitution of the instance — simply does not reach the LLM. The user observes degraded behavior (missing knowledge, absent mode content, no projected skills) without any indication of the cause.

The coupling is between two logically independent concepts:

- **Data directory**: where KairosChain stores its own state (blockchain, contexts, knowledge, skill definitions).
- **Consumer project root**: where the LLM harness expects to find its operational artifacts.

These coincide by convention in the single-project local case, but the coincidence is not a requirement. The fix must decouple them.

---

## §2 Invariants

**Inv 1. Independence of data directory and project root.**
The consumer project root must be determinable independently of the data directory's filesystem location. No path-arithmetic relationship (parent, ancestor, sibling) between the two may be assumed by any component.

*Justification:* All three §1 failure scenarios stem from assuming a parent-child relationship. Independence eliminates the entire class.

**Inv 2. Explicit configuration or named default; no silent inference.**
The consumer project root must be either explicitly configured by the consumer or produced by a named per-transport default rule (§4). Both forms are explicit acts traceable to a documented source. Silent inference from `data_dir.parent` is forbidden in all modes.

*Justification:* The bug's root cause is silent path arithmetic. A named default — one whose source rule is recordable and inspectable — preserves Inv 2's intent (no invisible inference) while admitting per-transport defaulting (Inv 6). The two invariants are coherent only under this reading: defaulting is not the absence of explicitness, it is a *named form* of it.

**Inv 3. Projection targets the consumer project root, never the data directory.**
All artifact-writing operations that target the LLM harness must resolve their destination from the consumer project root. The consumer project root and the data directory must never resolve to the same real path; coincidence is refused (§6), not warned.

*Justification:* The LLM harness reads from the consumer project's workspace. Writing projection artifacts inside the data directory conflates two independent concerns and creates confusion about which files are KairosChain state and which are harness artifacts.

**Inv 4. Inaccessible or unauthorized project root is a loud failure.**
If the consumer project root is configured or defaulted to a path that (a) does not exist, (b) is not writable, or (c) has not been authorized by the consumer as a projection target, the system must refuse the projection and surface a diagnostic naming the path and the failure reason. Authorization means the consumer has affirmatively designated the path as a projection target through a configuration act; mere writability is insufficient.

*Justification:* Silent write-to-nowhere is the bug's primary harm. Writability alone permits projection to any directory the server process can write — including unintended ones reachable through environment variables or remote configuration. Authorization closes that trust gap without dictating the mechanism.

**Inv 5. Absent project root disables projection without blocking data operations.**
If no consumer project root is configured and no per-transport default applies, projection operations must be skipped with a diagnostic. Data-directory operations (blockchain, context, knowledge, skill management) must continue unimpaired.

*Justification:* KairosChain's core value must not be held hostage to a projection configuration error. The two capabilities are independent.

**Inv 6. Transport-appropriate defaulting with plausibility verification.**
Each transport mode declares either (i) exactly one default rule producing a candidate consumer project root, or (ii) "no default — explicit configuration required." When defaulting is permitted, the produced candidate must pass a plausibility predicate confirming it is a recognizable consumer project — not merely an existing writable directory. A candidate that fails plausibility is treated as no default applying (Inv 5).

*Justification:* An existing writable directory is not necessarily a consumer project (`$HOME`, `/`, the parent of many projects). Without plausibility, defaulting reintroduces the silent-failure class Inv 2 forbids. The plausibility check makes default acceptance auditable.

**Inv 7. Round-trip verifiability.**
At runtime, both the consumer project root and the data directory must be queryable as independent values, together with (a) the source of each value (explicit configuration, named default rule), and (b) the authorization status of the project root.

*Justification:* Debugging projection failures requires visibility into both values, their provenance, and their authorization state. The current system exposes only the data directory.

**Inv 8. Canonical path resolution.**
The consumer project root, the data directory, and any candidate paths must be compared and validated after symlink and mount-point resolution to their real paths. Identity, distinctness, and ancestor relationships are evaluated post-resolution.

*Justification:* Without a fixed policy, Inv 1 (independence), Inv 3 (no coincidence), and Inv 9 (multi-consumer routing) become unverifiable: two paths that appear distinct may collapse to the same inode under symlinks. Real-path resolution is the conservative choice — it prevents accidental aliasing at the cost of disallowing symlink-as-identity setups. The cost is judged acceptable.

**Inv 9. Per-request consumer identification in shared-instance configurations.**
When a single data directory serves more than one consumer project, every projection-emitting request must carry an unambiguous identifier that selects exactly one consumer project root. A projection request without such an identifier in a multi-project configuration is a loud failure. Single-consumer installations are exempt — Inv 9 imposes no configuration burden on them.

*Justification:* Shared-instance setups (§1.2) are a stated primary failure mode. Implicit selection (most-recent, first-seen, alphabetical) reintroduces silent misrouting in a different form. Test 7 (concurrent-project) is unverifiable without this invariant.

---

## §3 Scope Boundaries

**In scope:**

- Decoupling project root resolution from data directory resolution across all transport modes.
- Per-transport defaulting policy (§4).
- Failure behavior when the project root is absent, unreachable, implausible, or unauthorized (§6).
- Backward compatibility for the canonical common case (§5).
- Diagnostic inspection of both values, their provenance, and authorization status (Inv 7).
- Per-request consumer routing in shared-instance configurations (Inv 9).

**Out of scope:** See §9.

---

## §4 Transport Mode Applicability

| Transport Mode | Defaulting | Notes |
|---|---|---|
| **Stdio MCP** (local, same machine) | Permitted (with plausibility) | Most common mode. Backward compat for the canonical common case is critical (§5). |
| **HTTP MCP** (remote, different machine) | **Not permitted** — explicit configuration required; missing configuration is a loud refusal | Server cannot reach remote consumer filesystem; Inv 3 cannot be satisfied by server-side writes. Delivery mechanism deferred (§11). |
| **CLI-direct** (`kairos-chain` from consumer project) | Permitted (with plausibility) | CLI invocation context is the canonical consumer-project signal in this mode. |

**Invariant applicability:** Inv 1, 2, 4, 5, 7, 8 apply to all three modes. Inv 6 applies wherever defaulting is permitted. Inv 3 applies to modes where server-side file write is the projection mechanism (stdio MCP, CLI-direct). Inv 9 applies whenever the data directory is associated with more than one consumer project.

**Key observation:** HTTP MCP is the only mode where Inv 3 cannot be fulfilled by server-side file writes. An alternative delivery mechanism is required and is deferred (§11). The invariants constrain that future mechanism without specifying it.

Concrete default-rule wording for stdio MCP and CLI-direct is mechanism, not invariant — see §11.

---

## §5 Backward Compatibility Commitment

Existing installations where the data directory is a direct child of the consumer project root, **and** the user invokes KairosChain from that consumer project root, must continue to work without configuration change. Specifically:

- A user who has never set an explicit project root must experience identical behavior after this change, **provided** the per-transport default rule resolves to the same path as `data_dir.parent` did under v1 and the result passes plausibility (Inv 6). This holds for the canonical case (CLI run from consumer root; stdio MCP launched by an editor whose workspace is the consumer root). It does not hold for cases where the previous behavior was already accidentally writing to an unintended location — those cases will now produce loud failures, which is intentional.
- No existing configuration file format may be broken. If a new field is introduced, its absence must trigger the per-transport default rule, not an error.
- The user-facing CLI must continue to work when invoked from the consumer project root with no additional arguments.
- Blockchain records written before this change must remain valid and readable after it.
- Single-project installations are implicitly single-consumer; Inv 9 must not impose additional configuration on them.

The commitment is to the **canonical common case**, not to every prior behavior. The bug being fixed had no "correct" behavior in the failing scenarios; backward compatibility for those is impossible by definition.

---

## §6 Failure Mode Taxonomy

| Condition | Category | Required behavior |
|---|---|---|
| Project root resolved, path exists, writable, authorized, plausible | Success | Proceed with projection. |
| Project root configured, path does not exist | **Loud failure** | Refuse. Diagnostic: configured path, reason (not found), source of value. Data ops continue. |
| Project root configured, path exists but not writable | **Loud failure** | Refuse. Diagnostic: path, reason (permission denied). Data ops continue. |
| Project root resolved, authorization absent or revoked (Inv 4) | **Loud failure** | Refuse. Diagnostic: path writable but not authorized as projection target. |
| Project root not configured, transport forbids defaulting (HTTP MCP) | **Loud failure** | Refuse. Diagnostic: explicit project root required for this transport. |
| Project root not configured, default produces a plausible path | Success | Proceed using default. Informational note (not warning) records which default rule produced the value. |
| Project root not configured, default produces an implausible path (Inv 6 predicate fails) | **Warning + skip** | Skip projection. Diagnostic: defaulted candidate failed plausibility; projection disabled. Data ops continue. |
| Project root not configured, default produces a non-existent or non-writable path | **Loud failure** | Refuse. Diagnostic: defaulted path, reason. |
| Project root resolves to the same real path as the data directory | **Loud failure** | Refuse. Diagnostic: project root and data directory coincide (Inv 3). Explicit configuration required. |
| Shared data directory, projection request lacks consumer identifier (Inv 9) | **Loud failure** | Refuse. Diagnostic: multiple projects registered, request must identify target. |

**Design principle:** every silent failure in the current system becomes either a loud failure or a diagnostic warning. No condition that previously produced invisible data loss remains silent.

---

## §7 Test Surface Invariants

The following properties must be verifiable by automated tests. Mechanisms, frameworks, and fixture strategies are not specified.

1. **Independence test:** Given data directory at real path A and consumer project root at real path B (not ancestor, descendant, or sibling of A), projection artifacts appear at B and not at A.
2. **Default-rule tests (per transport):** For each mode permitting defaulting, the documented rule produces the expected result under canonical conditions and produces no result when plausibility fails.
3. **Loud-failure tests:** For each loud-failure condition in §6, the system emits a diagnostic naming path and reason, and does not write artifacts.
4. **Graceful-skip test:** When no project root is available and no default is plausible, data operations succeed and projection is skipped with a warning.
5. **Backward-compatibility test:** Under the canonical common case (§5), behavior is identical to the pre-change system.
6. **Round-trip inspection test:** Both values, their provenance, and authorization status are queryable at runtime.
7. **Concurrent-project test:** Two consumer projects sharing one data directory, each with a distinct consumer identifier, receive artifacts at their respective real paths.
8. **Canonical-path test:** A project root specified via symlink and the same root via its real path are treated as one project; symlinks resolving to different real paths are treated as distinct.
9. **Authorization test:** A configured-and-writable but unauthorized path is refused with a diagnostic; the authorization step is observable.

---

## §8 Risks and Open Questions

**Risk 1: Stale projection after project root change.** Artifacts written to a previous project root are not auto-cleaned. Cleanup vs. warn-only is open.

**Risk 2: Race condition with multiple consumers.** Inv 9 addresses routing but not consistency. Concurrent projection writes to different project roots may interleave with data-directory state reads. The consistency model is undefined here.

**Risk 3: Plausibility predicate false negatives.** Inv 6's predicate may reject legitimate but unconventional projects lacking recognizable markers. The predicate must err toward refusal (with diagnostic) rather than permissiveness, but false negatives impose configuration burden on non-standard setups.

**Open question 1: HTTP MCP projection delivery.** Inv 3 cannot be fulfilled by server-side file writes. Delivery mechanism deferred — invariants constrain any future solution.

**Open question 2: Authorization model granularity and persistence.** Inv 4 requires authorization but does not specify scope (per-path, per-project, per-session, per-instance) or persistence (transient vs. recorded). Inv 9 has a parallel open question for multi-project registry persistence.

**Open question 3: Instruction mode body and project-root awareness.** Whether mode content should be project-aware is not addressed.

---

## §9 Out of Scope

1. **Multi-user separation.** Handled by `multiuser_*` tools. Orthogonal to project-root separation.
2. **Remote filesystem access.** No SSH/NFS/rsync introduced.
3. **Automatic discovery of consumer projects.** Explicit connection required.
4. **Migration tooling.** Backward compat (§5) avoids the need.
5. **IDE-specific integration.** Filesystem path, not workspace identifier.
6. **Changes to the blockchain format.** Per-project provenance is a separate design.

---

## §10 Acceptance Criteria for Multi-LLM Review

1. **Invariant completeness.** Do §2's nine invariants cover all known failure scenarios? Any §1 scenario unaddressed?
2. **Invariant consistency.** Do any two invariants conflict? In particular: is Inv 2's "named default is a form of explicit, not silent inference" framing sufficient to dissolve the Inv 2 ↔ Inv 6 tension flagged in round 1?
3. **Backward compatibility.** Does §5's narrowed commitment hold under all three transport modes? Does Inv 6's plausibility predicate pass for the canonical common case without false negatives?
4. **Failure taxonomy coverage.** Does §6 cover all reachable failure states? Any residual silent failures?
5. **Transport table accuracy.** Is the HTTP MCP loud-refusal-on-no-default judgment correct, or does it block legitimate use cases?
6. **Scope discipline.** Does the body (§1–§10) contain only properties and constraints? Has implementation surface leaked outside §11?
7. **Philosophy alignment.** Does this respect KairosChain's structural self-referentiality? Could project-root resolution be expressed as a Skill rather than hard-coded infrastructure? Does the authorization requirement (Inv 4) inadvertently centralize trust in the core?

---

## §11 Backlog (Mechanism Candidates — Not Decided)

This section lists implementation options surfaced during design. None are selected. Selection occurs during the implementation phase.

### Configuration surface candidates

**Environment variable name candidates:** `KAIROS_PROJECT_ROOT`, `KAIROS_CONSUMER_ROOT`, `KAIROS_TARGET_PROJECT`, `KC_PROJECT_DIR`

**CLI flag spelling candidates:** `--project-root <path>`, `--consumer-root <path>`, `--target-project <path>`, `--project-dir <path>`

**Configuration file field candidates:** field in data-dir config; field in consumer `.claude/settings.json`; standalone dotfile in consumer project root.

### Per-transport default rule candidates (P1-E relocation)

- **Stdio MCP candidate:** working directory of the launching MCP client process (consumer and server share filesystem; cwd is the most reliable project-root signal available to the server).
- **CLI-direct candidate:** working directory from which the CLI command was invoked.
- **HTTP MCP:** no default. Explicit configuration mandatory.

### Plausibility predicate signal candidates (Inv 6)

- Presence of a recognizable project marker (`.git/`, `CLAUDE.md`, `package.json`, `Gemfile`, language-specific config)
- Presence of a prior `.kairos/projection_manifest.json` at the candidate path
- First-use confirmation prompt (interactive transports only)
- Combination: marker OR prior manifest; confirmation as fallback

### Authorization mechanism candidates (Inv 4)

- Explicit designation via CLI flag, env var, or config field
- One-time CLI command (`kairos-chain mode authorize <path>`) recording consent
- First-projection confirmation prompt (interactive transports)
- Consumer-side opt-in marker file
- Implicit authorization for the canonical common case: single-project installations where plausibility passes and the data directory is a direct child

### Per-request consumer identification candidates (Inv 9)

- Session-level identifier bound at MCP handshake or connection time
- Per-tool-call parameter on projection-emitting tools
- Token issued at project registration
- Per-consumer auth credential bound to a registered project root

### Real-path resolution candidates (Inv 8 implementation)

- Resolve once at request entry; cache for the request lifetime
- Resolve at every filesystem touch
- Resolve and store at configuration time; reject configuration changes that produce a different real path

### Resolution order candidates

- CLI flag → env var → config file → transport-mode default
- Env var → CLI flag → config file → transport-mode default
- Config file → CLI flag → env var → transport-mode default

### HTTP MCP projection delivery candidates

- Consumer-side pull command
- Projection-as-response (server returns artifact content in tool results; harness writes)
- Sidecar process on consumer machine
- Manual copy with diagnostic command listing required artifacts

### Diagnostic surface candidates

- Extension to `chain_status` output
- Dedicated `projection_status` diagnostic tool
- Extension to `kairos-chain mode status` CLI output
- Structured JSON output for programmatic consumption

### Cleanup strategy candidates (Risk 1)

- Manifest-based cleanup on re-projection to a different root
- Warn-only; user responsibility
- Explicit `kairos-chain mode clean <path>` command
