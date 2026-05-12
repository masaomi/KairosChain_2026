# Consumer Project Root Separation Design v0.1

**Status:** Draft — pre-review
**Origin:** SUSHI integration testing (2026-05, silent projection failure)
**Scope:** KairosChain core, all transport modes

---

## §1 Problem Statement

KairosChain currently derives the consumer project root from the data directory by ascending to its parent. This derivation encodes an assumption: that the data directory (`.kairos/`) is always a direct child of the project it serves. The assumption holds for the common case — a developer runs `kairos init` inside their project, creating `.kairos/` as a sibling of their working tree — but fails structurally in three scenarios:

1. **Remote data directory.** A consumer project on machine A connects via `--data-dir` to a KairosChain instance whose `.kairos/` lives on machine B (or a mounted path unrelated to the consumer's workspace). The parent of that remote `.kairos/` is not the consumer project.

2. **Shared instance.** Multiple consumer projects share one KairosChain data directory (e.g., a lab-wide instance serving several bioinformatics repositories). The parent of the shared `.kairos/` is at most one of those projects — the others receive nothing.

3. **Non-parent mount.** The data directory is symlinked, bind-mounted, or otherwise located at a path whose parent directory has no relationship to any project workspace.

In all three cases, plugin projection — the mechanism that delivers operational artifacts to the LLM harness — targets the wrong directory. The four known affected artifact locations are:

- `CLAUDE.md` (project-level instructions, `@`-imported content)
- `.claude/` directory (plugin artifacts, `settings.json`, projected SkillSet content)
- `.claude/kairos/instruction_mode.md` (active instruction mode body)
- `.claude/kairos/projection_manifest.json` (SkillSet-to-artifact mapping)

All four are written to a path computed as `data_dir.parent`, which is correct only when the data directory is a direct child of the consumer project root.

**The failure is silent.** No error is raised. No warning is emitted. The artifacts are written to a location the consumer project's LLM harness never reads. The instruction mode body — which may contain the entire operational constitution of the instance — simply does not reach the LLM. The user observes degraded behavior (missing knowledge, absent mode content, no projected skills) without any indication of the cause.

The coupling is between two concepts that are logically independent:

- **Data directory**: where KairosChain stores its own state (blockchain, contexts, knowledge, skill definitions).
- **Consumer project root**: where the LLM harness expects to find its operational artifacts.

These two locations coincide by convention in the single-project local case, but the coincidence is not a requirement. The fix must decouple them.

---

## §2 Invariants

**Inv 1. Independence of data directory and project root.**
The consumer project root must be determinable independently of the data directory's filesystem location. No path-arithmetic relationship (parent, ancestor, sibling) between the two may be assumed by any component.

*Justification:* The three failure scenarios above all stem from assuming a parent-child relationship. Independence eliminates the entire class.

**Inv 2. Explicit over implicit.**
The consumer project root must be explicitly provided or explicitly defaulted. It must never be silently inferred from the data directory path.

*Justification:* Silent inference is the root cause of the current silent failure. An explicit value — even if that value is a default — creates a surface for validation and error reporting.

**Inv 3. Projection targets the consumer project root, not the data directory.**
All artifact-writing operations that target the LLM harness must resolve their destination from the consumer project root, never from the data directory.

*Justification:* The LLM harness reads from the consumer project's workspace. Artifacts written elsewhere are invisible to it regardless of their content.

**Inv 4. Inaccessible project root is a loud failure.**
If the consumer project root is configured but the path does not exist, is not writable, or is not reachable over the active transport, the system must refuse the projection operation and surface a diagnostic message. Silent write-to-nowhere is not permitted.

*Justification:* The current bug's severity is primarily due to its silence. A loud failure converts a debugging mystery into a clear operational signal.

**Inv 5. Absent project root disables projection without blocking data operations.**
If no consumer project root is configured and none can be defaulted, projection operations must be skipped with a warning. Data-directory operations (blockchain, context, knowledge, skill management) must continue unimpaired.

*Justification:* KairosChain's core value (knowledge management, blockchain recording) must not be held hostage to a projection configuration error. The two capabilities are independent.

**Inv 6. Transport-appropriate defaulting.**
The default value of the consumer project root, when not explicitly provided, must be determined by the active transport mode. Each transport mode has exactly one default rule, documented in §4. No transport mode may fall through to a path-arithmetic fallback.

*Justification:* Different transport modes have different visibility into the consumer's filesystem. A single default rule cannot serve all three without reintroducing silent failures in at least one mode.

**Inv 7. Round-trip verifiability.**
Given a running KairosChain instance, it must be possible to query the currently resolved consumer project root and compare it to the data directory. The two values must be independently inspectable.

*Justification:* Debugging projection failures requires visibility into both values. The current system exposes only the data directory; the project root is computed transiently and discarded.

---

## §3 Scope Boundaries

**In scope:**

- Decoupling project root resolution from data directory resolution across all three transport modes.
- Defining the defaulting rule for each transport mode.
- Defining the failure behavior when the project root is absent, unreachable, or misconfigured.
- Ensuring backward compatibility for existing single-project local installations (§5).
- Exposing both values for diagnostic inspection (Inv 7).

**Out of scope:**

- See §9 for the explicit out-of-scope list.

---

## §4 Transport Mode Applicability

| Transport Mode | Inv 1 (independence) | Inv 2 (explicit) | Inv 3 (projection target) | Inv 4 (loud failure) | Inv 5 (graceful skip) | Inv 6 (default rule) | Inv 7 (inspectable) | Notes |
|---|---|---|---|---|---|---|---|---|
| **Stdio MCP** (local, same machine) | Required | Required | Required | Required | Required | Default: the working directory of the Claude Code process that launched the MCP server. Consumer and server share a filesystem; cwd is the most reliable project-root signal. | Required | Most common mode today. Backward compat critical. |
| **HTTP MCP** (remote, different machine) | Required | Required | **Not applicable** — projection writes to a remote consumer's filesystem, which the server cannot reach directly. | Required (must refuse projection, not silently skip) | Required — data operations proceed; projection requires consumer-side pull or alternative delivery. | Default: none. No cwd is shared across machines. Explicit configuration mandatory. | Required | Projection in HTTP mode is a design question deferred to §11. The invariant structure must not assume local filesystem access. |
| **CLI-direct** (`kairos-chain` invoked from consumer project) | Required | Required | Required | Required | Required | Default: the working directory from which the CLI command was invoked. The CLI user's cwd is the consumer project by definition. | Required | `kairos-chain mode project` already operates this way implicitly; the fix makes it explicit. |

**Key observation from the table:** HTTP MCP is the only mode where Inv 3 (projection targeting) cannot be fulfilled by server-side file writes. This mode requires either consumer-side tooling or an alternative artifact delivery channel. The design must accommodate this without violating Inv 1 (independence) — the solution is not to make HTTP MCP "special" but to recognize that projection-as-file-write is one possible delivery mechanism, and HTTP MCP needs a different one.

---

## §5 Backward Compatibility Commitment

Existing installations where the data directory is a direct child of the consumer project root must continue to work without any configuration change. Specifically:

- A user who has never set an explicit project root must experience identical behavior after this change. The default rule for stdio MCP (cwd of launching process) and CLI-direct (cwd of invocation) must produce the same result as the current parent-of-data-dir derivation in the common case.
- No existing configuration file format may be broken. If a new field is introduced, its absence must trigger the default rule, not an error.
- The `kairos-chain mode project` command must continue to work when invoked from the consumer project root with no additional arguments. Its behavior may be extended (e.g., accepting an explicit target path) but not altered for the zero-argument case.
- Blockchain records written before this change must remain valid and readable after it.

---

## §6 Failure Mode Taxonomy

| Condition | Category | Required behavior |
|---|---|---|
| Project root configured, path exists, writable | Success | Proceed with projection. |
| Project root configured, path does not exist | **Loud failure** | Refuse projection. Emit diagnostic: configured path, reason (not found). Data operations continue (Inv 5). |
| Project root configured, path exists but not writable | **Loud failure** | Refuse projection. Emit diagnostic: configured path, reason (permission denied). Data operations continue. |
| Project root not configured, default rule produces a valid path | Success | Proceed with projection using default. Emit an informational note (not a warning) indicating the default was used, to aid debugging. |
| Project root not configured, default rule produces no path (HTTP MCP) | **Warning + skip** | Skip projection. Emit warning: no project root configured, projection disabled for this session. Data operations continue. |
| Project root not configured, default rule produces an invalid path | **Loud failure** | Refuse projection. Emit diagnostic: defaulted path, reason (not found or not writable). Data operations continue. |
| Project root resolves to the same path as data directory | **Warning** | Emit warning: project root and data directory are the same path; projection artifacts will be written inside the data directory. Proceed — this is not necessarily wrong (e.g., a project that *is* a KairosChain instance) but it is unusual enough to warrant a signal. |

**Design principle:** every current silent failure must become either a loud failure or a warning. No condition that previously produced invisible data loss may remain silent.

---

## §7 Test Surface Invariants

The following properties must be verifiable by automated tests. The test mechanisms, framework choices, and fixture strategies are not specified here.

1. **Independence test:** Given a data directory at path A and a consumer project root at path B where B is not an ancestor, descendant, or sibling of A, projection artifacts appear at B and not at A.

2. **Default-rule tests (per transport mode):** For each of the three transport modes, given no explicit project root configuration, the resolved project root matches the documented default rule for that mode.

3. **Loud-failure tests:** For each loud-failure condition in §6, the system emits a diagnostic message and does not write artifacts to any path.

4. **Graceful-skip test:** When no project root is available (HTTP MCP, no explicit config), data operations succeed and projection operations are skipped with a warning.

5. **Backward-compatibility test:** Given a data directory that is a direct child of a project root, with no explicit project root configuration, behavior is identical to the pre-change system.

6. **Round-trip inspection test:** The currently resolved project root and data directory are both queryable and return correct values under each transport mode.

7. **Concurrent-project test:** Two distinct consumer projects configured against the same data directory receive projection artifacts in their respective roots, not in each other's or in the data directory's parent.

---

## §8 Risks and Open Questions

**Risk 1: Stale projection after project root change.**
If a user changes the project root configuration mid-session (or between sessions), artifacts written to the previous project root are not cleaned up. This could leave orphaned or outdated artifacts in the old location. Whether the system should attempt cleanup or merely warn is an open question.

**Risk 2: Race condition with multiple consumers.**
When multiple consumer projects share one KairosChain instance and trigger projection simultaneously, artifact writes to different project roots may interleave with data-directory state reads. The consistency model for multi-consumer projection is not defined by this design.

**Risk 3: Symlink and mount-point resolution.**
Should the project root be resolved to its real path (resolving symlinks) or used as-is? Resolving symlinks may break setups where the symlink *is* the intended project identity. Not resolving may cause the same physical directory to appear as two different project roots.

**Open question 1: HTTP MCP projection delivery.**
Inv 3 cannot be fulfilled by server-side file writes in HTTP MCP mode. What mechanism delivers projection artifacts to the remote consumer? This design intentionally leaves this unresolved — the invariants constrain any future solution, but the solution itself is deferred.

**Open question 2: Multi-project identity.**
When one KairosChain instance serves multiple consumer projects, should each project have a distinct projection configuration, or should the instance maintain a registry of known consumers? The current design supports per-invocation project root specification but does not address persistent multi-project relationships.

**Open question 3: Instruction mode body and project-root awareness.**
The instruction mode body (e.g., Masa Mode) currently does not reference the consumer project root. If instruction mode content is project-specific, the mode system may need awareness of which project root triggered the projection. This interaction is not addressed here.

---

## §9 Out of Scope

1. **Multi-user separation.** The `multiuser_*` tool family handles user isolation within a single instance. This design addresses project-root separation, not user separation. The two concerns are orthogonal.

2. **Remote filesystem access.** This design does not introduce any remote filesystem protocol (SSH, NFS, rsync). HTTP MCP projection delivery is deferred (§8, Open question 1).

3. **Automatic discovery of consumer projects.** The system does not scan the filesystem to find projects that might want to connect. Consumer projects must explicitly connect via one of the three transport modes.

4. **Migration tooling.** No automated migration of existing `.kairos/` directories or projection artifacts is in scope. Backward compatibility (§5) ensures existing setups continue to work without migration.

5. **IDE-specific integration.** VS Code, JetBrains, and other IDE workspace concepts are not addressed. The consumer project root is a filesystem path, not an IDE workspace identifier.

6. **Changes to the blockchain format.** The blockchain records what happened; the project root is operational configuration, not a blockchain concern. If future work requires recording per-project provenance, that is a separate design.

---

## §10 Acceptance Criteria for Multi-LLM Review

Reviewers should evaluate this design against the following criteria:

1. **Invariant completeness.** Do the seven invariants in §2 cover all known failure scenarios? Is any scenario in §1 left unaddressed by the invariants?

2. **Invariant consistency.** Do any two invariants conflict? In particular, does Inv 6 (transport-appropriate defaulting) create tension with Inv 2 (explicit over implicit)?

3. **Backward compatibility.** Does §5's commitment hold under all three transport modes? Are there edge cases where the default rule produces a different result than the current parent-of-data-dir derivation?

4. **Failure taxonomy coverage.** Does §6 cover all reachable failure states? Are there conditions that would still produce silent failures?

5. **Transport mode table accuracy.** Does §4 correctly characterize each transport mode's capabilities and constraints? Is the HTTP MCP "not applicable" judgment for Inv 3 correct, or is there a server-side projection mechanism that was overlooked?

6. **Scope discipline.** Does the body (§1–§10) contain only properties and constraints, or has implementation detail leaked in? (§11 is the appropriate location for mechanism candidates.)

7. **Philosophy alignment.** Does this design respect KairosChain's structural self-referentiality? Specifically: could the project-root resolution itself be expressed as a Skill rather than hard-coded infrastructure? Reviewers should flag if this design inadvertently centralizes control that could remain distributed.

---

## §11 Backlog (Mechanism Candidates — Not Decided)

This section lists implementation options surfaced during design. None are selected. Selection occurs during the implementation phase after multi-LLM review of the invariants above.

### Configuration surface candidates

**Environment variable name candidates:**
- `KAIROS_PROJECT_ROOT`
- `KAIROS_CONSUMER_ROOT`
- `KAIROS_TARGET_PROJECT`
- `KC_PROJECT_DIR`

**CLI flag spelling candidates:**
- `--project-root <path>`
- `--consumer-root <path>`
- `--target-project <path>`
- `--project-dir <path>`

**Configuration file field candidates:**
- A field in the KairosChain data directory's configuration file
- A field in the consumer project's `.claude/settings.json`
- A standalone dotfile in the consumer project root

### Resolution order candidates

The order in which explicit configuration, environment variables, CLI flags, and defaults are checked. Options include:

- CLI flag → env var → config file → transport-mode default
- Env var → CLI flag → config file → transport-mode default
- Config file → CLI flag → env var → transport-mode default

### Internal method/class candidates

- A dedicated resolver object vs. inline resolution in existing startup code
- A project-root accessor on the existing configuration object vs. a new first-class concept
- Hook into existing `plugin_project` tool vs. new projection-aware tool

### HTTP MCP projection delivery candidates

- Consumer-side pull: a CLI command the consumer runs to fetch and write artifacts locally
- Projection-as-response: the MCP server returns artifact content in tool responses; the harness writes them
- Sidecar process: a lightweight agent on the consumer machine that watches for projection updates
- Manual: the user copies artifacts; the system provides a diagnostic command showing what should be where

### Diagnostic surface candidates

- Extension to `chain_status` output
- A new `projection_status` diagnostic tool
- Extension to `kairos-chain mode status` CLI output
- Structured JSON output for programmatic consumption

### Cleanup strategy candidates (for Risk 1, stale projection)

- Write a manifest of projected artifacts; clean up on re-projection to a new root
- Warn but do not clean up; leave it to the user
- Provide a `kairos-chain mode clean <path>` command