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

`scripts/pm_l2_report.py` compares the memo against the L2 context store and writes one HTML page,
to `<data dir>/reports/pm_l2_report.html`. `plugin/hooks.json` declares it as a `SessionStart` hook.

**Read-only by having no aim, not by checking one.** There is no output-path argument, so nothing
can point a write at the memo, the mapping, an L2 context, or `config/pm.yml`. An earlier version
took `-o` and guarded it by comparing resolved paths; that guard failed three ways — a case-only
difference on a case-insensitive filesystem, a hardlink, and any read input it did not know about —
and each failure destroyed the memo while the run printed that nothing had been written to it.
Deleting the argument closed all three. `sys.dont_write_bytecode` is set around the derivation
import for the same reason a second guard was not added: a `.pyc` inside the SkillSet sits inside
`Skillset#all_file_hashes` and therefore inside `content_hash`, the value recorded on chain.

**Paths come from this file's own location**, three levels up from `scripts/`, not from the name
`.kairos`. `l2_scan` derives its own by appending that literal, which reported a populated instance
as empty on every session whenever the data dir had been relocated, so its four path constants are
re-pointed after import.

**Nothing is trusted to have a type.** `pm_item` writes `due` and `touched_at` through with no check
beyond a JSON type, and this SkillSet's own Ruby suite writes the integer `20260701` to both. Dates
are parsed in exactly one function, which both ends of every interval go through: `l2_scan`
validates that a declared date *looks* like a date, never that it exists, so one context declaring
`2026-02-30` used to take the whole unattended run down.

Delivery is by **projection**, not by install, because install alone changes no host settings:

```
kairos-chain skillset install project_manager   files land; the host's settings are untouched
next start of the host                          the MCP handshake projects; the hook is written
```

Whether the hook then fires on that same start or the following one depends on when the host reads
its settings relative to the handshake; observed firing on the following one. `kairos-plugin-project`
run by hand settles it, and `skillset upgrade --apply` is not a substitute — it projects only when
it actually upgrades something, and this SkillSet is not in the core set it upgrades.

### Where search terms come from

The authored mapping first. When it has no entry for an item, or its entry matched nothing, terms
are inferred from that item's own title and notes, so no item goes unreported and L2 is never asked
to be relabelled. Inference cannot replace the mapping and does not try: 43 of 53 hand-authored
terms appear nowhere in any item's title or notes, having been written from knowledge of the work.

What it can do is refuse to flood, and it took three measurements to get that right, each from a
reviewer running the code:

| what was accepted | what happened | rule now |
|---|---|---|
| bare English words | 51 and 82 records for two items that have nearly none, because a defect is described with words like store, write, config and yaml | only a document name or a compound identifier containing an underscore |
| an uncapped document-name tier | a context titled `Review` made `review` a term reaching 351 records; titled `Context`, all 1178 | both tiers capped at twenty documents per term |
| a cap per term but not per row | twelve terms each under the cap unioned to 124 of 1179 documents; an ordinary note reached 23 | the row's whole union is capped too, and inference is **refused** rather than truncated |

Refused and not truncated, because truncation is silent and moves `last_activity` and the headline
figures with it. A refused row says its terms were too broad and how many they reached, and the page
shows the terms — a row claiming no term could be built while not showing what it tried is a claim
the operator cannot check where it is wrong.

**An authored `exclude` stops at the authored terms.** Carrying it into inference was itself a fix
in an earlier round, and it traded one wrong answer for another: an exclude term is a substring of
document names, and an inferred term is usually the item's own record name, so carrying it
suppressed the item's own primary record. The row says so rather than dropping it silently.

The cost of all this is misses — across the 24 mapped items, inference alone found 87 records where
the mapping found 296 — and the trade is deliberate: a miss shows up as a smaller count, a spurious
record does not show up at all.

### Five reasons, not one

A row with no comparison names which side is missing: no usable terms, terms too broad, records
carrying no date, an L2 date that cannot be parsed, or a memo marker that cannot be parsed. The last
two are separate sentences because they blame different files. Collapsing them produced a false
statement twice — first an item with seventeen datable records reported as having none, then a memo
blamed for a date that L2 had written wrong — and each time the item also left the denominator, so
the headline figures shrank without saying so.

### Tests

`test/test_pm_l2_report.py`. The bar is mutation, not redness against an older commit: breaking a
guard by one line must make the suite red. An audit of an earlier version applied 65 one-line
mutations and 36 survived, so guards are now exercised through `main()` in a subprocess, fixtures
are checked not to satisfy their own assertion, aggregation is tested with several items, and
messages and exit codes are asserted by content. Of the 30 mutations that map to a reported finding,
29 are killed; the survivor is equivalent (deleting the absent-derivation branch leaves the generic
handler producing the same message, exit code and absence of a traceback).

Nothing runs this suite automatically — `rake test` collects Ruby files only.

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
