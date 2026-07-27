# project_manager plugin projection — v0.7 FROZEN

**Status:** FROZEN 2026-07-26 by the operator, on the basis that the deployment-grounded and philosophy-aligned findings are exhausted rather than that the roster's numeric threshold was met. See §0 for why that basis was used and what remains open.
**Date:** 2026-07-26
**Author:** orchestrator (Opus 5), across five review rounds.
**Supersedes:** v0.6 and the whole numbered series.
**Purpose:** Let any KairosChain session — whatever instruction mode it runs — invoke the project_manager SkillSet through a secretary-persona sub-agent, so the secretarial disposition runs in its own context without touching `instructions_mode`.

---

## 0. How this closed, and the loop's own record

Five rounds. APPROVE counts 0, 0, 1, 2, 1. The threshold was never met and could not have been: one roster slot returned nothing substantive five times out of five, and two reviewers whose documented bias optimizes for terminal completeness returned REJECT in all five. The aggregation rule this project actually uses counts deployment-grounded and philosophy-aligned findings and treats style divergence as advisory; on that basis the round-five findings were the last, and every one of them is now applied. The reviewer that returned nothing has since been removed from the roster, which is recorded where the roster lives rather than here.

The loop's recurring failure is worth stating plainly, because it took four different forms and the design is what it is because of them.

| Round | The failure |
|---|---|
| 1 | A confinement claim rested on a deny-list, which leaks by default |
| 2 | The design asserted a correction — moving a rule below the seam — that had not reached the deployed artifact |
| 3 | The design asserted a withholding the mechanism could not express, because the grant's granularity is the whole tool |
| 4 | An above-seam reproducibility floor was unsatisfiable by the artifact that runs, because the digest's arguments were unpinned |
| 5 | **The design broke a correct statement by adopting a reviewer's finding without verifying it** |

The fifth is the orchestrator's own error and it inverts the first four. A round-four reviewer said three write commands could not suppress the recency marker; the true number was two, which v0.5 had right. The claim was adopted unchecked, propagated into two deployed artifacts, and one of them then contradicted its own machine-generated tool table — which is how four round-five reviewers found it. The lesson generalises: a finding classified as deployment-grounded is a claim *about* the deployment, and classification is not verification. Applying one unchecked is how a correct artifact acquires a defect while the record says it was repaired.

---

## 1. Why a sub-agent, and why not an overlay

The frozen design separates capability from disposition: the tools work with no secretary present, and the charter is inert without them.

The charter declares itself a thin layer that *composes with, and defers to, the active instance constitution*. But `instructions_mode` is single-valued, so selecting the charter as a mode would **replace** the active constitution — breaking the charter's own promise.

The alternative is to make the mode mechanism composable. This design rejects that, and not for effort:

> Composing two normative documents at the governance boundary requires precedence rules between them. A norm assembled from two constitutions with unstated precedence is **less** surfaceable and less revisable than a single one — so an overlay buys composition at the cost of Prop 10's contestability floor, in the one layer where that floor is load-bearing.

A disposition needs its own context, not a merge into a constitution. Shipping it as `plugin/agents/*.md` expresses that in the same structure as every other SkillSet artifact, and the projector already supports it generically.

---

## 2. What execution established, and what it did not

**The grant is narrowed.** Invoked as a probe, the sub-agent enumerated its tools and attempted four calls. The digest ran; the recording tool, the project tool, a filesystem write tool, the shell and the editor were all absent from its list — nothing was present to refuse.

**Whether absence equals refusal is untested**, and the confinement argument rests on it. If the harness merely omits an unnamed tool rather than refusing a call to it, absence-from-list is the whole of the mechanism, and it was never probed at the call boundary. Nothing here claims more than absence.

**The read face was unbounded and is closed at source.** In round two the same mechanism that narrowed the write face granted unbounded filesystem read, and the sub-agent read an RSA private key and an admin bearer token in full — five attempts, no refusal. The grant is now three tools with no path parameter in any of them.

Three things about the extent of that exposure, separated because two rounds blurred them. What was checked is the repository: no key or token material was found in the context store, the review working directory, the drafts tree or the projected tree. What was not checked is the harness's own session transcript store, which lives outside the repository and does retain tool results. And the window is narrow by construction: a projected sub-agent definition does not take effect until the harness reloads, so the unbounded-read version was the registered definition for one session only, in which it was invoked three times — twice as a probe and once for real work. The rotation decision is the operator's on that footing.

**The read face is item-wide.** One granted read returns every item in every project, whole, including notes and provenance. Project records themselves are reachable by no granted tool. There is no path parameter, but a narrow tool list is not a narrow surface — which was the incident's lesson.

**Visibility is unconfined by construction.** With no tool call, the sub-agent quoted the first heading of both project instruction files, the active instruction mode's title, and the operator memory heading. Capability can be narrowed; visibility cannot.

**Measured against the live store, as shapes rather than counts** — the figures move daily, and quoting them is how two rounds acquired stale numbers. Buckets are computed independently, so an item can appear in more than one. Dormancy admits only high-salience items, so a normal-salience item is stale-invisible however long it sits, and the count of unbucketed items therefore mixes work that is fine with work nobody is watching. The neglected bucket contains a tie at the point a three-item cut would fall, which is why truncation must not cut inside a tie.

**Activation is asymmetric.** The Skill becomes usable immediately after projection; the sub-agent does not, because the agent registry is fixed for a session. A reload — in practice a restart — is required.

**One real run.** One report, one tool call, no writes. It named an overdue commitment with a minimal next step, two long-gated items, a dormant item whose downstream dependent it found unprompted, a world-event dependency handed back, and surfaced both a deprioritise and an invest option for a stalled item. Whether that quality is the disposition's own or inherited from the visible instruction mode is not separable from a single run under a visible constitution.

---

## 3. Confinement, and what it cannot reach

**Invariant.** Capability is defined by enumerating what is held, never by enumerating what is denied.

A denial list is complete only against the tool surface that existed when it was written; every tool added later is granted silently. This instance exposes over a hundred tools, so a denial list is a boundary that leaks by default and cannot be audited by reading it.

**Invariant.** A confinement claim is verified separately for each way capability can act, and an allow-list constrains the tools it names, not what those tools reach.

Four ways are visible here and they are not symmetrical. What may be *written* is narrowed by the grant. What may be *read* is narrowed by the grant's tool list but not by its extent — every item is readable whole. What is *visible* is not narrowed at all, and cannot be. What may be *sent* is only the return message, which is the one real egress and is relayed to the operator by construction. Nested delegation is absent because the grant contains no tool that spawns.

Two consequences. The generic read tools that caused the incident are gone, and the secretary's subject matter arrives through the digest instead. And because every item is readable whole and the report is relayed onward into a session whose transcript the harness retains, **the store must hold nothing that may not outlive the moment it is read** — a constraint on what the operator puts in it, not something the design can enforce, and one whose horizon is the transcript store rather than the session.

**Invariant.** The grant's granularity is the whole tool. A rule that lands on a command inside a granted tool is a discipline, and this design does not present it as mechanism.

The mechanism therefore reaches exactly two things: the recording tool and the project tool are absent, so performing or recording an irreversible project action is out of reach, and so is reading a project record — the project tool is mixed, and withholding it withheld both. Everything finer — not clearing a world-event dependency, not marking work done unbidden, not writing while reporting — is a rule the secretary keeps or does not. The artifact says so in its own text, under a heading that names it as such.

**Constraint, not a residual.** Confinement is enforced by the host harness, so it is host-specific. The opencode converter builds its output from a different set of keys and silently drops an allow-list, which widens the grant to that host's default; projecting there removes the narrowing. The codex converter passes frontmatter through verbatim, so the declaration survives — whether that host honours it is unknown. **This design is claude-host-only**, and re-projection to another host is not a neutral act.

---

## 4. Mode-agnosticism, and the asymmetry beneath it

One operator's constitution is not another's, and the disposition must behave the same under any of them or none.

What an early round got wrong was the mechanism claimed to deliver it. Isolation does not exist.

**Invariant.** The projected disposition is self-sufficient: it remains correct and complete when everything visible around it is ignored.

This is a property of how the artifact is written, not one the harness enforces — the same class of unenforced rule as reporting-performs-no-write, which this design does not dress up. Two things follow, both in the artifact rather than assumed:

- The sub-agent is told it *may* see the invoking mode and must not lean on it. An instruction to ignore something invisible is inert; an instruction to ignore something visible is a discipline.
- No constitution vocabulary appears above the seam.

The second is a test of *wording*, not of origin, and saying so matters: any operator's constitution overlaps a truth-preserving floor somewhere, because that is what a floor is. What must not cross the seam is the vocabulary that makes a rule recognisably one operator's — and that is checkable by reading.

---

## 5. The seam, the enforcement, and the copies

**Invariant (sufficient, not exhaustive).** A rule belongs above the seam if breaking it makes the report false, materially incomplete about what it withheld, non-reproducible in which items appear and in what order, or the store wrong.

An early round wrote this as a biconditional and the artifact refuted it. Rules also belong above the seam by a second route: **if their breach is undetectable from the delivered text.** That bound is what keeps the route from swallowing presentation preferences — every style preference's breach is fully visible in what arrives, and the operator can judge it unaided, whereas a report narrated instead of finished, a handback that will not apply, store content over-quoted into a transcript, and a disposition leaning on an invoking mode all fail invisibly.

| Rule | Route |
|---|---|
| Fixed bucket order; deadline ordering re-derived, not inherited; deterministic tie-break; pinned digest arguments | Reproducibility |
| A blocked item is waiting, not neglected; never state a duration the store does not record | Falsity |
| Report the unbucketed count with its true meaning and its stale sub-count; truncate only at a value boundary; name omitted items with titles | Material incompleteness |
| Reporting performs no write | The store, and the truth of every later report |
| Do not lean on the invoking mode; the final message is the return value; emit the handback exactly; quote from the store only what the report needs | Undetectable from the delivered text |
| Brevity and the three-item aim; heartbeat proposals; surfacing both directions; naming what changed; delivering bad news with context | *Below* — each changes only how a true report reads |

The last row is the operator's temperament. One entry deserves a note: failing to surface both a deprioritise and an invest option is a documented bias of this class of system, and it is the below-seam rule whose breach is hardest to detect. The criterion sorts by what a report *asserts*, not by how much a rule *matters* — that is it working as intended, but a later author should not read the lower region as unimportant.

**Where enforcement actually is.**

| Protected against | Enforced by |
|---|---|
| Recording an irreversible action; changing or reading project records | **Mechanism** — both tools absent from the grant |
| An unknown item id; a status or salience outside the closed vocabulary | **Mechanism** — the store refuses each outright |
| Clearing a world-event dependency; marking work done; dropping an item; writing while reporting | **Discipline** — each is a command of a granted tool |
| Fabricating a deadline or a narrative in report prose; reporting partial success as success | **Discipline, necessarily** — semantic properties of content no server has ground truth for |

Two things the middle rows do *not* cover, found in the last round and stated here rather than implied. An unknown *field* is refused by the store but never reaches it: the tool slices arguments down to its known keys first, so an out-of-schema request returns success having recorded nothing — the disposition's rule to say so plainly is triggered by no refusal. And an update carrying no attributes at all is an unrefused marker reset, which is the one thing the reporting-performs-no-write rule exists to prevent. Both are in §7.

**Invariant.** A floor enforced by mechanism is not conditioned in the prompt; it may be named there, because a model that does not know a capability is absent will improvise a workaround. A rule enforced only by discipline is presented as a rule the secretary keeps, under a heading that says nothing enforces it.

**The copies.** The intended shape is one design home plus one operational face per surviving path — the capability document for direct tool use, the disposition for the sub-agent — so two is the target. Measured across the charter, the disposition, the capability document, the knowledge entry and the frozen design: the human gate stands at four, meaningful touch at three, world-event clearing at three, brevity at three, and reporting-performs-no-write at two. Three of those match the target; two depart. The human gate carries a third operational face because the charter is still one, which its retirement removes. Reporting-performs-no-write has two faces and **no design home**, because this design introduced it; until the amendment in §7 lands, the claim that each rule has one authoritative home is false for exactly the rule this design is most invested in.

The charter's continued existence is not only a duplication problem. It instructs the reader to name the digest's unbucketed count as a health figure — the precise thing the disposition now forbids as a false statement. Its retirement is a correctness fix.

---

## 6. The artifacts

Both live under `.kairos/skillsets/project_manager/plugin/` and are projected to `.claude/`. The disposition's source and its projected copy are byte-identical; the capability document differs from its projected copy at one injection marker, where the projector substitutes tool schemas read from the tool classes. A hand-written table would drift silently as schemas change — and in the last round the machine-generated table is what caught a false sentence in the hand-written prose beside it, which is the argument for the marker in one line.

**The disposition** (`plugin/agents/secretary.md`, registering as `pm-secretary`, hyphen-only because registration is by frontmatter name) grants exactly the digest, item queries and item edits. It pins the digest's arguments so an unchanged store yields the same report; assigns one ordering signal per bucket and requires the deadline order be re-derived rather than inherited; forbids stating any duration the store does not record; requires the unbucketed count be reported with its true meaning and its stale sub-count; truncates only at a value boundary and names what it omitted with titles; separates reads from writes and says which of the six item commands can suppress the recency marker; scopes the world-event handback to a request rather than a report; and marks its own unenforced rules as unenforced. No model is pinned: the mechanical half of the work is light, but surfacing both directions is the instruction most likely to fail silently, and its failure is undetectable from the output.

**The capability document** (`plugin/SKILL.md`) states the disciplines that bind either path — not "the frozen invariants", since one has no home in the frozen design yet — marks the projected files as generated outputs rather than editable documents, says that the grant is whole-tool so finer distinctions are disciplines, and warns against supplying the disposition through `instructions_mode`.

**The declaration.** `skillset.json` carries a `plugin` key whose sub-keys are decorative: the projection test reads only whether the value is present, and the projector hard-codes both paths. The shape is copied from existing SkillSets for consistency; a non-default path would not be honoured, and there is no way to declare one.

---

## 7. Backlog, and what is out of scope

Body or backlog is decided by ownership: a problem this design resolves *by scoping itself* belongs in the body as a constraint on its own validity — which is why the host limitation is in §3. A defect in a component this design neither owns nor can fix without a code change belongs here.

**The two routes to mechanism for the disciplines in §5.** Either split the finer-grained commands into their own tools, so the grant can express withholding them; or add a server-side gate that refuses them without an explicit operator-confirmation argument. The second reuses an existing gate mechanism and is the smaller change. Both are code changes to the SkillSet.

**Record layer.** The store records no actor, so a secretary write and an operator write are indistinguishable — and this design makes that live rather than dormant, because the single-writer assumption held until a second writer existed. Worse than the missing field: a write leaves no trace at *any* layer — the action log is opt-in and no `pm_*` tool participates, the dispatch point records nothing, the store rewrites its file whole with no history, and the tree is untracked. An erroneous write is unattributable, unrecorded and unrecoverable. This is the durable form of the reporting-performs-no-write discipline. Separately, the recording tool performs no consent check and writes every record's origin as human while trust weighting ranks human above machine and the record's lifetime is a century; and an execution tool builds an unconstrained invocation context when none is supplied — that tool is absent from this grant, so it is a core defect rather than this design's.

**Tool surface and digest.** Two commands cannot suppress the recency marker: dependency resolution, where the store method takes no such parameter, and provenance appending, where the store method accepts one but the tool never forwards it — the second is a one-line fix and the cheaper of the two. An out-of-schema field is sliced away by the tool before the store's refusal can fire, and an attribute-free update is an unrefused marker reset; both are the mechanism gaps §5 names. Deadlines and review dates are unvalidated free text while the digest parses them as instants, so one non-parsing deadline written through the grant disables every later digest — the reporting mechanism the reproducibility floor rests on. The deadline sort compares raw strings rather than instants, so equivalent times with different offsets can order non-chronologically; the disposition works around this by re-deriving the order. There is no status-change or completion timestamp, so time-in-gate, time-blocked and "recently completed" are unavailable — the disposition refuses the first two and orders the third on last touch while saying that is what it means. The review date is writable and read by nothing; making the digest read it would give the operator a scheduled-review channel and the honest place to put a repeat-proposal signal, which elapsed time substitutes for poorly. Dormancy admits only high-salience items, so a normal-salience item is stale-invisible; either dormancy applies at every salience with salience used for ordering, or the count needs a name that says what it counts, since it is presently called a health count and the disposition has to override that by discipline.

**Projection durability.** Change detection is a single digest over all plugin-bearing SkillSets, so a hand-edited projection does not trigger regeneration, while the next version bump of any unrelated SkillSet overwrites it without warning or backup. The verify path checks only for missing and orphaned files, so a drifted file reports as valid. Both trees are untracked. The fix is an output digest per file in the manifest and a content comparison in verify, reusing a digest pattern the same file already uses elsewhere.

Its deferral is contested and the dissent is recorded rather than resolved: reviewers in two rounds judged it blocking, on the ground that the projected prompt is where several disciplines live. Against that: the source is on disk, authoritative and byte-identical; the running norm is readable at any time; the discipline is additionally recorded in an L2 context, though as a category in a table row rather than in its operative wording; and the exposure — a hand-edit to a file the capability document marks as generated — is recoverable by re-projection. Prop 10's surfaceable, recordable and revisable all hold; what is missing is automatic divergence alerting. This design defers on that reading and leaves the disagreement visible, because a dissent legible in the text is more contestable than one settled in a summary.

**Plumbing that does not exist.** Nothing anywhere reads a SkillSet's declared knowledge directories, and the knowledge registry enumerates a different location with a different file-naming convention — so a SkillSet-bundled knowledge entry is unreachable by any session, and always was. The orientation note in that directory is a file for human readers only.

**Layer crossings.** An MCP-layer SkillSet writes into the harness layer; a harness sub-agent calls back into the MCP layer; re-projection has unilateral authority over the harness artifact; the harness inherits the operator's instruction mode and memory into the sub-agent's context. And the grant hard-codes the harness's own server alias, so renaming that alias would leave the allow-list naming tools that do not exist, with the same unknown consequence as the untested refusal path.

**Verification owed.** Whether the harness refuses an unnamed tool at call time or merely omits it. Whether the codex host honours a passed-through allow-list. Whether the disposition's observed quality is its own or inherited, which needs a run with no instruction mode present. What the harness's session transcript store retained of the round-two credential exposure.

**Pre-freeze acts, now post-freeze and outstanding.** Two, both named by the reviewer who judged the design freeze-ready. Reporting-performs-no-write needs its design home as an amendment to the meaningful-touch invariant, with the operational copies referencing it; this is the one item with a coherence consequence, since the claim that each rule has one authoritative home is currently false for it. And the charter should be retired as a selectable instruction mode, with the retirement made machine-visible rather than documented — a correctness fix, and one this project has reason to make mechanical, since a silent mode reversion has already gone unnoticed here for three weeks.

**Promotion, after freeze.** Two lessons outlive project_manager: that a confinement claim must be verified separately for each way capability can act, and that whole-tool granularity turns command-level rules into disciplines. A third belongs with them, from §0: that a finding classified as deployment-grounded still has to be verified before it is applied. All three belong as an L1 knowledge entry beside the existing skill-authoring patterns, written to the tracked, undistributed knowledge stage in the gem repository rather than the instance-local one, which is ignored by version control and would leave them exactly as unversioned as this document.

**Out of scope.** No change to the charter beyond the retirement recommendation. No change to `instructions_mode`. No gem promotion — projection is not distribution and the criteria are unmet. No amendment to the frozen design in this document. No fix to any backlog item. No staging area for a development-only SkillSet: L1 knowledge has a repo-only stage and a distributed stage, SkillSets have one, so "tracked" and "distributed" remain the same decision, and these artifacts live in an untracked tree — as does this document, which is itself an instance of the durability problem it records.
