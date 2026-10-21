---
name: agent
description: >
  Run a long, autonomous task in this session with as few questions to the operator as possible, each review
  run until no P0 is left, ending in a layered-deck report: a dev cycle (design → review → implement → review),
  writing or revising a paper or other document, surveying a theme, or any other work a review can read.
  Use when the operator asks for such a run, says "agent で", "お任せで", "最後まで進めて", or wants a task
  carried through without being asked on the way. A stand-in answers decision points from the operator's own
  past words; anything irreversible is queued for the operator, not done.
---

# Agent runs (1.0)

Install in an instance (agent is not installed by default): `kairos-chain skillset install agent` (with its
dependencies llm_client ≥ 0.3.0 and multi_llm_review), then `kairos-plugin-project` to project this skill and the
run hooks into the project's `.claude`, then restart Claude Code. The operator adopts a policy (below) once.

You are the body of the run. You do the work with your ordinary tools. The SkillSet gives you the plan, answers
your decision points through a stand-in, guards your effects through hooks, keeps the journal, and checks the
report. You can carry a whole dev cycle, a document revision or a survey; do not tell the operator it cannot be done.

## Start

1. `agent_status` (no arguments) shows the adopted policy and how many precedent records the stand-in has. If no
   policy is adopted, `agent_start` refuses and shows the sentence the operator must type
   (`adopt policy <name> <8 hex>`); after they type it, call `agent_items(action: "adopt_policy", policy: <name>)`.
   Ask for this once; it is the only setup question. The SkillSet ships one sample, `default_2026_10_20`
   (`adopt policy default_2026_10_20 ac4ae89b`). Before the operator types an adoption, show them the policy file:
   the stand-in reads it, comments included; adopting the sample consents to sending the run's artifacts to the
   reviewers configured in multi_llm_review, and lets the stand-in answer reversible questions no recorded word
   covers by the model's own judgment. A policy file a 3.95.0 install left beside it, named for its author, is
   another operator's sample with the same rules.
2. `agent_start(goal, template, …)`:
   - `dev_cycle` — design → design review → implement → implementation review: `design_glob:
     "log/<topic>_design_v*.md"`, `tests: "<test dir or glob in the repo>"`;
   - `impl_cycle` — the design is settled (e.g. "handoff を読んで実装を続けて"): `tests` only;
   - `design_only` — `design_glob` only;
   - `doc_cycle` — write or revise a document kept in a git repository, in place on the run branch;
     `test_command` may name a build (`latexmk -pdf main.tex`, `pandoc …`, `make`, a tracked script);
   - `survey` — survey a theme into versioned files: `output_glob: "log/<topic>_survey_v*.md"`, from the
     sources the run has locally (papers, notes, data in the repository); web lookup is refused in a run;
   - `general` — any other work: `output_glob` for versioned files, or committed work on the run branch with
     optional `tests`/`test_command`; `review_as` design, implementation or document.
   A review closes when no (a)/(b) P0 is open. Each review may take the policy's
   `review_rounds` (10 in the shipped `default_2026_10_20`), counted for that review alone; at the cap it waits for the operator. The stand-in rules on the tests directory and
   the test command against the operator's words at the first advance. `tests` as a directory pins everything under it from the base commit; as a glob it pins only the
   files it matches. `test_command` names a test runner (ruby, bundle, rake, pytest, npm, go, cargo, make, …) or a
   script the repository tracks; it runs without a shell, one test file appended (default: `ruby -Ilib -Itest` for
   Ruby, `python3 -m pytest` for Python). A test file that already failed on the base commit does not block the run when the tests failing in
   it now all failed there too (named minitest/pytest failures); otherwise, and for output that names no tests,
   it waits on the operator (`accept_failing`). Build or test output belongs in a `.gitignore` committed on the
   run branch: anything untracked refuses the next check and the review. The report lists them.
   The run works on this session's project (the hooks tell the tool which); `target_repo` names another. Its
   worktree starts from HEAD of the current branch: to continue an existing branch, check it out and commit first
   (uncommitted changes in the main checkout are not in the worktree; agent_start says how many there are). The
   session binds to the run at once. `agent_start` refuses where the agent hooks are not live: after installing or
   upgrading the SkillSet restart Claude Code; a project whose KairosChain data directory lives elsewhere needs
   `KAIROS_DATA_DIR` set for the hooks.
3. Follow `next` in each response. The SessionStart and Stop hooks repeat it after compaction or at a turn end.
4. A run whose session ended, or that ended without a report, is taken up with `agent_start(resume: <run_id>)`
   in another session. A run whose session is still live is not taken from it; if it is taken after that session
   went quiet, that session refuses further actions until the operator speaks there again.

## The loop

- **Design phase:** write each design version as a new file matching `design_glob` in the main checkout with
  the Write tool (never overwrite an existing file), then `agent_advance(run_id)`.
- **Review phases:** `agent_advance` dispatches the round itself (do not call `multi_llm_review` yourself in a
  run — it is refused) and, on the next call, collects it and returns the seats' findings labelled by the
  stand-in. Answer the open P0s in a new version (a new file) or new commits, then advance again. A review
  closes provisionally when a quorum of seats answered and every P0 is fixed, refuted with grounds, or (design
  reviews) deferred to the implementation review; the only cap is the policy's rounds for each review.
- **How to revise (L1 multi_llm_review_workflow § Revision Discipline):** answer a finding by deletion,
  correction or naming. Do not add mechanism, sections or defensive layers unprompted; if a finding seems to
  need one, ask (AskUserQuestion) before writing it — the stand-in answers. When `next` says new P0s were drawn
  by your last addition, undo that addition first. When it says the open count has not fallen for two rounds,
  change approach: prove or refute each open P0 by a test or a reproduction, undo additions, or split the work.
  A design version stays at the design level (no code beyond interface names); review findings about how to
  implement are deferred, not answered in the design.
- **Check phases (implement, write, work):** work in the run's worktree and branch (`agent_status` names them) and commit there. Each
  Bash call runs confined under `/bin/bash -c` and starts afresh: use absolute paths, or `cd <worktree> && …`
  within one call; the operator's shell functions and newer bash features are not there. The
  tests under `tests` were pinned from the base commit when the run started; changing or deleting a pinned test
  goes to the stand-in, with the old and new text. `agent_advance` refuses uncommitted work, then re-runs the
  tests itself on the committed state; the implementation review re-runs them if HEAD moved.

## Questions and decisions

Ask as you normally would — AskUserQuestion, a plan approval, or a question at the end of your turn. In a run
the stand-in answers, provisionally, from the operator's own words; questions only the operator can answer are
queued as operator items and you continue with other work. If the operator speaks during the run, their words
outrank the stand-in.

## The line

Inside: files the run created, its worktree and branch, its report directory and scratch area. Refused and
queued as operator items: L0/L1, the instruction mode, policies, the precedent store and journal, `.claude`
settings and hooks, instruction files (CLAUDE.md, AGENTS.md…), existing shared files, new hidden files in the
main checkout, other git refs, push/publish/send, anything that discloses outside the configured review seats.
The operator's own permission rules (deny and ask, in their settings) are refused and queued too: the operator is
not answering during the run. A refusal is not a stop: continue with work that does not depend on it. The refused
change is kept whole with its item, so the operator can apply it.

## Hazards

If you notice a key exposure, chain corruption, data loss, or wrong published output that has happened — or you
are unsure — call `agent_items(run_id, action: "alert", text: ...)` at once. The stand-in rules on it; a fatal
one present in the world, or one it cannot rule, ends the run. A defect in the work under review is a review
finding, not a hazard.

## Report (every run)

When `next` says so, start a subagent (Agent tool, not a fork) to build the report. The subagent:
1. calls `agent_status(run_id, report_material: true)`, which writes `log/agent_runs/<run_id>/material.json`
   and answers with its path;
2. runs `python3 <SkillSet>/report_kit/make_report_deck.py <dir>/material.json <dir>/deck.html` — the skeleton
   of the layered deck (L1 `layered_visual_pitch_deck`): main slides = what the operator must act on first
   (alerts, operator items with commands, provisional closures, novel or low-confidence decisions, pinned-test
   changes, plan parameters the stand-in set), then what changed; details = evidence; appendix = every decision
   D#, item I#, phase, effect, and what was not checked;
3. may rewrite the main slides' wording in Japanese, keeping every id;
4. runs `python3 <SkillSet>/report_kit/check.py <dir>/deck.html` until `issues=0` (if the browser cannot start
   inside confinement, say so and leave the check to `agent_finish`).
Then call `agent_finish(run_id)`. It refuses a deck that omits an id, that the acting context wrote last, or that
the kit's check faults (reading the deck yourself is fine). `agent_stop` also ends in a report. Every provisional
closure is an operator item, so the operator can confirm it or send it back by its id.

## After the run

Tell the operator where the deck is and list the operator items. The guard and journal stay after any ending
until the operator's next typed words; if those come before the report is built, take the run up again with
`agent_start(resume: <run_id>)` and finish it.

Corrections, confirmations and resolutions count only in the operator's own typed words naming the item (e.g.
"D4 は違う、8 席で" or "D4は違う"), typed in a session bound to the run or naming the run id; record them with
`agent_items(run_id, action: "correct" | "confirm" | "resolve", ref: "D4")`. What a phase waits on changes only
with a decision you read in those words, and the words must say it: `decision: "freeze"` ends a review or check
left open (its open P0s are carried), `"more_rounds", rounds: n` grants that review n more rounds,
`"review_whole"` sends a diff above the size limit to
review in one piece, `"accept_test_change"` accepts a pinned-test change the stand-in left to the operator,
`"restore_test_command"` restores a test command the stand-in rejected, `"accept_failing"` lets a test that
also fails on the base commit stay failing, `"send_back"` reopens a provisionally closed review and the phases
after it. Words that name the run's own items keep its guard; other typed words after an ending release it. Without one, the item stays open. A run that ended only because it waited on that item — even one
whose report is built — continues in the session that resolved it; its earlier report is kept beside the new one.

The stand-in learns from the operator's words in transcripts. The operator keeps the precedent store filled with
`ruby <SkillSet>/bin/agent_harvest.rb` (regularly: the host deletes transcripts after 30 days); a directory
holding a snapshot in the two files harvest reads (`askuserquestion_pairs_20261020.json`,
`prose_question_answers_20261020_operator_only.json`) is imported with `--import-snapshot <dir>`.

`ruby <SkillSet>/bin/agent_policy_report.rb` writes a report under `storage/agent/policy_reports/`: for each rule
of the adopted policy, what the runs the chain records as ended hold against it, with counts, denominators and
the operator's words. It moves no rule and evaluates no file from a run directory. A policy changes only when the operator copies it under a new name (file
and `policy` line), edits it, and types the adoption; a change you draft from the report carries your own
readings of the operator's words, so say so when you offer one.

## Available Tools

<!-- AUTO_TOOLS -->
