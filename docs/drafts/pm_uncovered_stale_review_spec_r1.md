# Review spec — project_manager `uncovered_stale` (implementation, R1–)

## TARGET FROZEN AS OF R6 (2026-08-05, operator direction)

The target set below is closed. R1 through R5 each widened it — R4 added `due`
parsing, R5 added `Store#query`, `SKILL.md` and `config/pm.yml` — and each
widening reset the finding count, which is why five rounds did not converge. No
further file joins the target for the remainder of this loop.

A finding against a file outside the frozen target is advisory and goes to the
queue, **even when it is the same defect class as something inside**. The
fix-the-class corollary is suspended at the target boundary for this reason: it
was the correct rule and it is also what kept the boundary moving.

Rounds from R6 are judged on one question: are the fixes made after the previous
round correct? A round that finds nothing new against the frozen target closes the
loop. If two consecutive rounds produce no deployment-grounded finding and no
internal contradiction against the frozen target, the loop is converged. If the
threshold is not reached but those two rounds are clean, the operator freezes on
exhaustion.


Pre-declared before dispatch, per `multi_llm_review_workflow` Step -1 and
`loop_validation` (spec before judgement, fail-closed). Frozen for this round.

## Target (P0-eligible)

Exactly these four files, at the working-tree state under review:

| Path | Change |
|---|---|
| `KairosChain_mcp_server/templates/skillsets/project_manager/lib/project_manager/digest.rb` | adds `uncovered_count`, `uncovered_stale`, private `stale` and `dormant_at_any_salience?`; rewrites the `healthy_count` expression to `uncovered.size` (same value, changed line); makes `days_since` return nil on an unparseable marker and `summarize` tolerate a missing `deps` key |
| `KairosChain_mcp_server/templates/skillsets/project_manager/plugin/agents/secretary.md` | rewrites § "Report what the buckets do not cover" |
| `KairosChain_mcp_server/templates/skillsets/project_manager/test/test_project_manager.rb` | replaces `test_healthy_count` with three tests |
| `KairosChain_mcp_server/templates/skillsets/project_manager/skillset.json` | version 0.2.0 → 0.3.0 |
| `KairosChain_mcp_server/templates/skillsets/project_manager/lib/project_manager/store.rb` | **added to target in R2**: `blocked?` tolerates a missing `deps` key |
| `KairosChain_mcp_server/templates/skillsets/project_manager/tools/pm_digest.rb` | **added to target in R2**: the tool description names the two new fields |

R2 note on the two additions. R1 declared `Store#blocked?` appendix while the pass
condition promised no exception on a missing `deps`. Two reviewers found the
contradiction: the summarize-side guard covers only the path this change added,
and a dormant high-salience item without `deps` still crashed the digest through
`blocked?`. Narrowing the promise to fit the target would have been weakening the
contract to pass it, so the one-line fix is in target instead. `pm_digest.rb` is
in target because its description is the surface a non-secretary caller reads.

## Appendix (advisory only, not P0-eligible)

Everything else, including: the pre-existing `dormant_buckets` high-salience
restriction (this change deliberately does not alter it), the `pm.yml` threshold
values and its nil/type handling, `l2_scan.py`, the `project_manager` design
documents, gem release mechanics, and the instance mirror under `.kairos/`.

**R4 moved `due` parsing out of this appendix and into the target.** R1 declared it
out of scope as pre-existing. Four separate reviewers then flagged it, and the
Step -1 corollary is explicit: fix the class, and fix every copy. The class here is
"a caller-supplied time string, written through `pm_item` with no validation,
reaches `Time.parse` and takes the whole digest down." R1 through R3 fixed the
`touched_at` copy and left the `due` copy standing one method away in the same
file. Guarding one and not its twin is the defect that corollary names, so `due` is
now in target. Its raw-string ordering is fixed in the same breath, because the
guard already parses the value.

R4 also added to target: `Store#blocked?` nil-deps (fixed in R2) and the
secretary's handling of an item whose `title` was deleted through `pm_item update`.

**R5 added the remaining copies of both classes, and moved the guards to one place
each.** The falsifier found a third unguarded `Time.parse` in `Store#query`'s
deadline filter — one bad `due` made every deadline query return an error — and
noted that `Store#dormant?` was still unguarded at its source, so the next caller
would re-acquire the defect. The guard now lives once, in
`lib/project_manager/parsed_time.rb` as `ProjectManager.parse_time`, and every
reader of a stored timestamp goes through it; the call-site rescues are gone. On
the prose side, R5's own general rule was found to be vacuous — it said "wherever
a rule *below*" while both rules it had to cover sit above it — so it is rewritten
to bind the whole file and to cover an unreadable marker and an empty `blocked_on`
as well as an absent title. `plugin/SKILL.md` and `config/pm.yml` join the target
because both assert things about this SkillSet that are no longer true.

## What the change claims

1. `uncovered_count` equals the number of open items in no bucket. Open excludes
   `done` and `dropped`.
2. `uncovered_stale` contains **every** uncovered item the store already calls
   dormant, minus the high-salience restriction the dormant buckets add. The
   predicate is `Store#dormant?` itself, not a reimplementation, so the threshold
   is strict: elapsed must exceed `dormancy_days` (14 by default), and an item
   sitting exactly on the boundary is in neither the buckets nor this list. Sorted
   oldest first, ties broken by id. Not a top-N.
3. `healthy_count` is retained with identical value to `uncovered_count`, marked
   deprecated in a comment. The only readers in the repository are this file, the
   test, and the secretary text that forbids reading it; the retired charter at
   `.kairos/skills/secretary.md` mentions it and is out of service.
4. Bucket membership is unchanged. `dormant_neglected` / `dormant_waiting` remain
   high-salience only; an item in any bucket never appears in `uncovered_stale`.
5. The secretary names every entry of `uncovered_stale` with id, title, and days,
   and attaches no next step or alternative to them.
6. A markerless (`touched_at` nil), malformed, or non-String marker yields neither
   an entry nor an exception. `Time.parse` answers a malformed String with
   `ArgumentError` and a non-String with `TypeError`, and `pm_item` writes a
   caller-supplied `touched_at` through without validation, so both are caught or
   the guard only half exists. The item stays in `uncovered_count`, so the number
   does not conceal it.
6b. Every dormancy question in `Digest` goes through the one guarded predicate,
   including the high-salience one in `dormant_buckets`. R1 guarded only the new
   path, which left a bad marker on a high-salience item able to take all four
   buckets down. `dormant_buckets` keeps its high-salience restriction unchanged;
   only the call it makes is now the guarded one.
7. The SkillSet version bump to 0.3.0 is a declaration, **not** a propagation
   requirement. `SkillsetManager#upgrade_check` triggers on
   `template_ver > installed_ver || changed_files.any?` and `upgrade_apply` copies
   `changed_files` regardless of `version_bump`, so a content change alone reaches
   installed instances. Files under `config/` are excluded from `diff_files` and
   are never overwritten either way.

## Pass condition (APPROVE requires all of)

- No behavioural change to bucket membership relative to the pre-change digest.
- `uncovered_stale` never omits an item strictly past the threshold, never
  includes one at or below it, and never includes one already in a bucket.
- Ordering is deterministic and stable across runs on identical input.
- No exception on items missing or carrying a malformed `touched_at`, or missing
  `title`, `salience`, `due`, or `deps`.
- The test file drives the real `Digest`; no assertion re-implements the logic.
  Verified by reverting the predicate: the two threshold/marker tests go red.
- The secretary text and the code agree on field names and on "all, not top-N".

## Freeze criterion (pre-committed)

Revise only on a new (a) deployment-grounded finding or an internal contradiction
(b). A request to also change bucket membership — that is, to make dormancy
salience-independent — is out of target: that option was considered and rejected
by the operator on 2026-08-04 in favour of this one, and belongs to the queue,
not to this round. Findings against the appendix are advisory.

## Threshold reachability

Roster is 5 slots, rule 3/5 APPROVE. Orchestrator is `claude-opus-5` under the
delegate strategy, so its slot is filled at collect by the persona team and the
full-roster rule governs. Both Codex slots are historically REJECT-default; the
maximum realistic APPROVE count is therefore 3 (persona, claude_cli_opus4.6,
cursor_composer2.5).

The rule is a ratio applied to the **successful** count, not to a fixed 5. With
all five slots returning, three approvals meet it exactly. If any one of the three
non-Codex slots fails, times out, or is set aside for model divergence, the ceiling
drops to two and the threshold becomes unreachable — so reachability here is
contingent on a full return, not established. A SKIPped Codex is the opposite
hazard: it lowers the denominator and can manufacture a false APPROVE while the
strongest deployment-grounded finder is absent. Either way, if the threshold is
not reached and no (a)/(b) findings remain, the closing path is operator freeze on
exhaustion, not further rounds.
