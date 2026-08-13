# Minimum Nomic — a bench for watching language models build a system

Minimum Nomic is a self-amending game. Nine initial rules, numbered 101 to 109,
all of them changeable, and **no victory condition, no goal, no termination
rule**. Three language models play it. A fourth is the game master.

The bench does not measure whether the game runs. It watches **how participants
think and act when the rules do not decide what happens** — what goals they
invent, what system they build, where they cooperate and where they collide.
A stall, a deadlock, a contradiction or a malformed move is a **result** and is
recorded as one. A game that falls apart is either the game master's competence
or a player's competence, and either way it is the measurement.

**Do not make this robust.** Adding harness authority to prevent a foreseeable
in-game failure is a regression, not a fix. The one thing that is protected is
the record: an in-game failure is data, a lost record is nothing.

## Running it

Run from the project root — two of the three seats inherit that working
directory, and what they can reach from it is part of the recorded lineup.

It calls the command-line tools through the `llm_client` SkillSet's adapters,
read from `.kairos/skillsets/llm_client/` at the project root. That directory is
instance-local and not in this repository, so a fresh checkout has to have the
SkillSet projected before any of this runs; without it the first `require` fails.

```
ruby bench/minimum_nomic/run_gm.rb   --out log/minimum_nomic_gm_20260810/g3 --turns 15
ruby bench/minimum_nomic/check_gm.rb  log/minimum_nomic_gm_20260810/g3 --falsify
ruby bench/minimum_nomic/reanalyse.rb log/minimum_nomic_gm_20260810/g3
```

One directory per game, a fresh one every time. A run refuses to start when the
target already holds records, so a game is never destroyed and two games are
never merged. Writing is append-only. A 15-turn game takes about 15 minutes and
33 model calls.

`check_gm.rb` runs mechanical checks over a finished game's own records and
calls no model. `--falsify` poisons a temp copy and asserts each check goes red;
a green check that has never been shown to go red is not evidence.

`reanalyse.rb` re-reads a finished game and hands it to the analysts again under
whatever the guideline currently says. The analysis is a pure function of the
stored record, so changing the guideline costs no replay. Results append to
`records/analyses_rescored.jsonl`, each row carrying the digest of the guideline
that produced it, and the game's own record is never touched — two read-outs of
the same game stay distinguishable instead of merging.

## What each participant is given

```
Player      → its own identity
              + the INITIAL rule set (101-109)
              + every player's utterances so far
              + one line asking for its reasoning
              Nothing else. It works out what is in force for itself.

Game master → the roster
              + the INITIAL rule set
              + every player's utterances so far
              Its only job is deciding who speaks next.
              It renders nothing to anybody and tells no one what it concluded.

Analyst     → the initial rules, both logs in full, the turn-control record
              Runs after the game, as a fresh call with no memory of playing.
              It is NOT told which seat it held.
              Returns prose, then a 0-10 metacognitive competence score with
              reasons for each player and for the game master.
```

The analysts are the same three models that played. They are not told which seat
they held, because being told there is a self to find plants the conclusion — an
analyst that recognises its own trace unprompted is showing something an
instructed one cannot. Measured across five games: with the prompting sentence
present, 3 of 3 analysts addressed it; with it removed, 0 of 12 did.

The 0-10 scale is stated to the analysts as arbitrary and uncalibrated; the
number is a coarse handle and the reasons are the substance. Read the scores
knowing that **who did the scoring moves the number more than who was scored**.
Over five games scored twice, the spread between judges was 1.35-1.50 points
while the spread between the scored was 0.67-0.71, and re-scoring the same cell
moved it 0.73 points on average. Judge severity is stable and real; a claim that
one model is better at metacognition is not supportable at this sample size.

No rule set compiled by the harness or by the game master reaches any
participant. Under the older arrangement every player read one shared
compilation, so players could not disagree about the rules — the divergence
this bench most wants to observe was suppressed by the substrate. Every game
recorded before 2026-08-12 was played that way and does not compare with a
game played after it.

## The corpus is never committed

This directory is tracked by git. The games are not, and are not to be. They
live under `log/`, which is ignored. Protection of the record comes from
append-only writing and from one directory per game, not from version control.

## Known gaps, deliberately left

- **No check asserts that the rule block in a player prompt is the initial set
  and nothing else.** Measured 2026-08-12: a fabricated rule block injected into
  every player prompt of a copied game leaves all six checks green. If the
  harness ever regresses to delivering a compilation, nothing here notices.
- **A public-log position number repeats across a failed call** (3 of the 13
  games archived before this change). The number players cite is that position,
  so renumbering either gaps what players see or moves what a citation points
  at. Left until more games say which is worse.
- **Seat and model are confounded.** Seat A is always the same model and always
  speaks first, so a first-mover effect and a model effect cannot be told apart.
  Rotating models across seats is the next change, before any series.
- **Two of the three seats could read the game's records if they looked** — one
  runs read-only in the project root, one runs there with no sandbox at all.
  Recorded in each game's lineup rather than solved.

A duplicate copy of these three files still sits in
`log/minimum_nomic_gm_20260810/`, left in place beside the games it produced.
**This directory is the live one.** Edit here.
