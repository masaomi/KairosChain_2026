---
name: project_manager
description: >
  Project and work-item management. Use when asking what needs attention or what is on your plate,
  at session start, when rescheduling or postponing work, when a deadline moves, when marking work
  done or blocked, when recording an irreversible project decision, or when reconciling the store
  with reality. 何が残っているか、予定の変更、締め切り、放置されている作業の確認。
---

# project_manager

A domain-neutral vessel for project and work-item management. Everything domain-specific enters as
**content** — titles, notes, provenance — never as schema.

Design: `docs/drafts/secretary_project_manager_design_v0.5_FROZEN.md`. Distributed with the gem
since 3.55.0; it is not in the auto-install set, so an instance installs it explicitly.

## Two ways to use this

**The secretary sub-agent** — for interpretation and for schedule work.

Delegate to `pm-secretary`. It runs in its own context and carries a disposition of its own, which
the tools here neither define nor read. Its grant is the digest, queries, and item edits:
`pm_record` and `pm_project` are withheld at the tool level, so it can neither record an
irreversible action nor change *or read* project records — it answers project-level questions from
items and says that is what it is doing — and it hands the withheld actions back to the operator.
Finer distinctions than that — which *commands* of `pm_item` it should avoid — are disciplines in
its prompt, not mechanism, because the grant has whole-tool granularity.

Prefer the sub-agent for "what needs attention?", at session start, and for schedule management.

**Direct tool use** — for a single lookup, or an edit already decided, or an operator-gated record.

## Disciplines that bind either path

- **Human gate.** Never call `pm_record` autonomously, and never change project-level state on the
  system's own initiative. The judgment that an action is irreversible belongs to the operator; the
  tool records the decision, it does not make it. Routine item updates need no gate.
- **Reporting performs no write.** A write that accompanies a report resets the dormancy marker
  while nothing real happened, and the digest then misreports the neglect it exists to reveal. This
  is stronger than "advances no marker": a `mechanical: true` write advances no marker and is still
  a write. Nothing enforces this mechanically.
- **The projected artifacts are generated.** `.claude/skills/project_manager/SKILL.md` and
  `.claude/agents/project_manager-secretary.md` are outputs. So is most of the instance copy under
  `.kairos/skillsets/project_manager/`, which `skillset upgrade` overwrites from the gem template
  whenever the template's bytes differ. Edit the gem template under
  `KairosChain_mcp_server/templates/skillsets/project_manager/plugin/` and re-project; a hand-edit
  to a projected file or to the instance copy is overwritten without warning.
- **`config/` is yours, and is the one exception.** `skillset upgrade` never overwrites a `config/`
  file that already **exists**, so `config/pm.yml` is safe to edit and stays edited. Two consequences
  follow from the word "exists". A change to the template's `config/pm.yml` does not reach any
  instance that already has the file — not only new installs, but any instance, forever. And a
  `config/` file the instance is *missing* is not exempt: it installs on the next upgrade, so
  deleting `config/pm.yml` restores the template's copy rather than leaving it absent.
- **Single authority.** `.kairos/pm/store.json` is the one authoritative record of project and task
  state. L2 contexts may be linked as provenance but never hold task state.
- **Meaningful touch.** Operator-meaningful edits advance an item's recency marker. `add`, `update`
  and `add_dep` accept `mechanical: true`; `resolve_dep` and `add_provenance` advance the marker
  unconditionally. A drop is an `update`, so it takes the flag like any other update. When seeding
  from a migration source, carry the source's own recency via `touched_at` rather than restamping it.
- **Dormancy is derived**, never stored: `now - touched_at > dormancy_days` (config `pm.yml`).
- **Layer discipline.** These tools never write L0 or L1.
- **World-event dependencies are operator-cleared.** The system never auto-resolves them.

## The session-start L2 comparison

`scripts/pm_l2_report.py` compares the memo against the L2 context store and writes one HTML page.
It reads three things — the context store, the memo's items, and the authored mapping — and writes
only that page. It never writes the memo, and that is checkable by reading the file: the single
`open(..., "w")` in it is the output path.

`plugin/hooks.json` declares it as a `SessionStart` hook. Delivery is by **projection**, not by
install, and the difference matters because install alone changes no host settings:

```
kairos-chain skillset install project_manager   files land; the host's settings are untouched
next start of the host                          the MCP handshake projects; the hook is written
```

Whether the hook then fires on that same start or on the following one depends on when the host
reads its settings relative to the MCP handshake. That ordering has not been measured. Running
`kairos-plugin-project` by hand after install settles it either way; nothing else is needed, and
`skillset upgrade --apply` is not a substitute — it projects only when it actually upgrades
something, and this SkillSet is not in the core set it upgrades.

Search terms come from the authored mapping first. When the mapping has no entry for an item, or
its entry matched nothing, terms are inferred from that item's own title and notes, so no item goes
unreported and L2 is never asked to change. Inference accepts only a token that is itself the name
of an existing L2 document, or a compound identifier reaching at most twenty documents. A bare
English word is refused however rare it looks. Measured 2026-08-17: accepting bare words returned
51 and 82 records for two items that have almost none, because a defect is described with words
like store, write, config and yaml, and those match hundreds of unrelated names as substrings.
Refusing them, the same two return 2 and 17. The cost is misses — across the 24 mapped items,
inference alone found 87 records where the mapping found 296 — and that trade is deliberate: a miss
shows up as a smaller count, a spurious record does not show up at all.

## Relation to instruction modes

The tools carry no disposition and depend on no particular instruction mode. This SkillSet does
*ship* one — `plugin/agents/secretary.md`, projected as a sub-agent — but nothing in the tools reads
it or requires it, and removing it leaves them fully functional. The disposition runs in the
sub-agent's own context and carries its own rules, so it behaves the same whatever mode the invoking
session runs, and the invoking session's mode is untouched.

Do not supply the secretarial disposition by setting `instructions_mode: secretary`.
`instructions_mode` is single-valued, so that would *replace* the active constitution rather than
compose with it. The sub-agent exists to avoid exactly that.

## Available Tools

<!-- AUTO_TOOLS -->
