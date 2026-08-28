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

It calls the command-line tools through the `llm_client` SkillSet's adapters.
`llm_client` is a **sibling SkillSet**, so `bin/` resolves it as
`../../llm_client/lib/llm_client` — the same relative path whether this copy is
the gem's template under `templates/skillsets/` or an instance's projection
under `.kairos/skillsets/`. It is a hard dependency: without `llm_client`
projected alongside, `run_gm.rb` aborts naming both directories it looked in
rather than failing inside a `require`.

Paths below are written for an instance where this SkillSet has been projected.
In the development checkout, substitute
`KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/`.

```
ruby .kairos/skillsets/minimum_nomic/bin/run_gm.rb    --out log/nomic/g3 --turns 15
ruby .kairos/skillsets/minimum_nomic/bin/check_gm.rb  log/nomic/g3 --falsify
ruby .kairos/skillsets/minimum_nomic/bin/reanalyse.rb log/nomic/g3
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

The procedure below adds eight more, run from the same directory:

```
ruby .../bin/distil_criterion.rb CORPUS_DIR                      # stage 2, first half
ruby .../bin/criterion_matrix.rb GAME_DIR AUTHOR JUDGE --criteria CORPUS_DIR/criteria
ruby .../bin/propose_metric.rb   CORPUS_DIR --out OUT             # stage 3
ruby .../bin/mutate_rule.rb      GAME_DIR --out MUT               # stage 4
ruby .../bin/judge_change.rb     --a MUT/clean --b MUT/rule_105 --out OUT
ruby .../bin/predict_divergence.rb CORPUS_DIR --criteria DIR --out OUT   # stage 5
ruby .../bin/self_recognition.rb   CORPUS_DIR --criteria DIR --out OUT   # stage 6
ruby .../bin/score_readback.rb     CORPUS_DIR --criteria DIR --out OUT   # stage 7
```

`cross_model.rb` analyses a stored game with **one named model at a named
reasoning effort**, instead of the panel recorded in the game's own line-up. It
exists because `reanalyse.rb` reads the panel from the game, which is right for
re-reading under a changed guideline and cannot answer "would a different model
have caught this?". Results append to `records/analyses_crossmodel.jsonl`, kept
separate so a cross-model read-out never merges with the game's own panel.

```
ruby .kairos/skillsets/minimum_nomic/bin/cross_model.rb log/nomic/g3 claude_code claude-opus-5 medium
```

Holding effort fixed is the point of the argument, not a convenience: the stored
games ran `claude-opus-4-6` at medium and `claude-opus-5` at high, so any
comparison that reuses both stored panels confounds generation with effort. Held
fixed at medium over the same 27 mutated records, the two generations tied at 16
detections each — and not on the same 16.

## The seven stages of analysis

Stages 1-4 were fixed on 2026-08-21 after five rounds of design review failed to
converge and the procedure was settled by running it instead. Stages 5 to 7 were
added on 2026-08-27/28, once stages 1-4 had established that the score measures
the scorer and left the divergence BETWEEN scorers as the only quantity the
record fixes. Stage 7 exists because stages 5 and 6 disagreed and three readings
survived both; it holds two of the three fixed. The order matters: each stage
takes its material from the one before it, and no stage supplies a definition of
metacognition. Every definition in play comes from an analyst.

```
  1  free scoring          reanalyse.rb
        Analysts read the record under ANALYSIS_GUIDELINE and return prose, a
        LENS block stating the standard they applied, a TEN block, and 0-10
        scores. The scores cannot rank models (see the next section); the LENS
        blocks are what stage 2 consumes.

  2  scoring under a       distil_criterion.rb  ->  criterion_matrix.rb
     stated standard
        Each analyst restates its own LENS blocks as one game-independent
        standard. Every game is then re-scored under every standard by every
        analyst. The diagonal — an analyst under its own standard — is the
        control, and the gap to the off-diagonal is its own-standard premium.

  3  proposed measures     propose_metric.rb
        Each analyst is asked for a procedure that counts metacognition, as
        executable code, and the code is run once on a disposable copy. It is
        not repaired, rewritten or re-run. What is kept is the proposals plus
        what happened; the run/fail count is not a score and is not compared.

  4  repeatability and     reanalyse.rb x2  /  mutate.rb  /  mutate_rule.rb
     mutation                 ->  judge_change.rb  /  score_detections.rb
        Two experiments sharing one question. Repeatability re-runs stage 1
        unchanged and measures how far an assessment moves on its own; that is
        the floor. Mutation plants one lie — a reversed vote, or one rewritten
        rule body — and asks whether the assessment moves further than the
        floor.

  5  self-prediction       predict_divergence.rb
        An analyst says where its own scores will land, and the matrix says
        where they landed. `--question relative` asks for its position against
        the panel; `--question absolute` asks only about its own scores, which
        is the panel-independent form. `--standard own|rotate|control` varies
        whose standard it is shown, and `control` shows a hand-written
        permissive one that is never scored under. `--question qualitative`
        asks the same thing in words rather than numbers, which is how the
        "cannot calibrate a quantity" reading was tested and dropped.

  6  self-recognition      self_recognition.rb
        The stage-1 LENS blocks are pooled unlabelled and the analyst is asked
        which ones it wrote. Japanese statements are dropped by default because
        only one analyst wrote any, so language would name the author for free.

  7  score readback        score_readback.rb
        An analysis is shown with its SCORES block removed and the analyst is
        asked what the scores were. Each cell contributes one analysis the
        subject wrote and one someone else wrote, on the same game under the
        same standard, so only the author differs. Stages 5 and 7 ask for the
        same kind of answer about the same scores; what changes is whether
        there is anything to read it off.
```

None of stages 5 to 7 scores its own result. Each writes the answer and the
measured truth into one file and stops; what counts as a hit is not fixed in
advance, because fixing it decides what is being measured before the observation.

**What the first full pass found, 2026-08-21.** Recorded here because it bounds
what each stage can currently be used for.

Stage 2, one game (`t100_g1`) scored under 4 distilled standards by 4 judges,
16 of 16 cells returning. **Fixing the standard did not remove the judge
effect,** which is what this stage was built to test:

```
  spread across judges, standard held fixed      1.94 points
  spread across standards, judge held fixed      1.12 points
  spread across the participants being judged    3.31 points
      (A 4.25, B 5.19, C 7.56, GM 6.12, averaged over all 16 cells)
```

The judge still moves the number more than the standard does. What did change is
the third figure: in the free pass the judged spread was 0.67-0.71 against a
judge spread of 1.35-1.50, and under a fixed standard the judged spread is the
largest of the three. One game, so that is an observation and not a rate.

The own-standard premium did not appear. The four diagonal cells averaged 5.50
and the twelve off-diagonal cells 5.88 — judges were slightly HARSHER under
their own standard, not softer.

The GAPS block was answered NONE in **0 of 16 cells**. Every judge reported the
supplied standard leaving something undecided, and they converge on the same
four holes: whether proposing implies an affirmative vote (4 judges), how to read
an entirely empty turn where both the utterance and the reasoning block are blank
(4 judges), which side to weight when private reasoning and public utterance
diverge (3 judges), and whether the game master's much narrower action space can
be scored on the same scale (2 judges). Those are unresolved questions in the
GAME, surfacing as gaps in every standard rather than as a defect in any one of
them.

The distillation itself is worth reading before the scores. Three of the four
analysts reported their own statements disagreeing with one another, as the task
requires rather than smoothing over: `claude-opus-4-6` on whether modelling other
participants is metacognitive evidence at all (2 statements exclude it, 1 makes
it a top-three criterion; it kept the exclusion), `claude-opus-5` on whether a
costly act counts without evidence the cost was priced, and `composer-2.5` on
strategic success (1 statement of 10 credits it, 7 decline). All four declined to
count cleverness, winning and eloquence — a convergence nothing in the harness
asked for. The material is uneven: `composer-2.5` and `gpt-5.6-sol` distilled
from 10 games each, `claude-opus-4-6` and `claude-opus-5` from 5.

Stage 3, on a 24-game corpus with the panel `composer-2.5`, `gpt-5.6-sol`,
`claude-opus-4-6`: 2 of 3 submissions ran. The one that failed died on
`text.split()` against the 8 utterances of 391 whose `text` is null — records of
calls that failed. The two that ran took metacognition to mean different things
and neither said so was a problem. One reply also contained 8 fabricated tool
calls with fabricated results, citing a path that exists but is empty and
quoting lines that appear nowhere in the corpus.

That run used request `a830924dff9e`, whose field list did not say `text` can be
null. On 2026-08-23 the request was amended to name the null case, so runs from
here answer request `8eb7e40059f1` and are not comparable to the run above on
that point. The amendment was made because the failed row could not be read: it
could mean the analyst was careless, or that the layout handed over was
incomplete. Naming the case removes the second reading and keeps the first.

Stage 4, on one game with one rewritten rule body (`Rule 105`, unanimity ->
simple majority, cited 14 times in that game's public log): **the CHANGED /
UNCHANGED verdict saturates and is unusable.** The floor was 9 of 9 CHANGED and
the mutated arm was also 9 of 9. What judges pointed AT still separated them —
all 3 judges reading analyst B's pair named the Rule 105 misreading, and no judge
named anything of the kind in the floor pair. Counting occurrences of the
substituted word does not separate them: analyst C mentions "majority" 4 and 2
times in the two clean readings and 5 times in the mutated one, without ever
detecting anything.

So: use `judge_change.rb` for what its judges WRITE, not for the verdict it
tallies. One game, three analysts, one rule — not a rate.

Only 9 of the 24 games carry `rules_initial` in their lineup, and
`mutate_rule.rb` needs it. The other 15 predate recorded rule bodies and cannot
carry a rule mutation. No workaround is provided; run more games instead.

**What stages 5 to 7 found, 2026-08-27/28.** All three read the same 176-cell
matrix, which by then was complete: 11 games x 4 standards x 4 judges, every row
returning and every SCORES block parsing. 136 calls in all, none failing.

Stage 6, four analysts x three repeats over a pool of 22 unlabelled statements:
**59 of 66 of their own claimed, and 0 of 198 belonging to someone else.** One
analyst also partitioned all 22 into their four true authors with no mixing and
no overlap, so what is present is a model of the OTHER writers and not only of
itself. It read by typography and opening formula, and said so.

Stage 5 asked the same analysts where their own scores would land. On the
panel-independent form — an analyst's own mean, which does not move when the
panel does — three of four missed by 1.4 to 2.8 points out of 10, **all four in
the same direction**, and all four named a most-frequent score of 4 or 5 where
the measured ones were 3, 6, 7 and 8. Five repeats each agreed to within 0.4
points, so this is a stable belief and not sampling noise. On the relative form,
two of the three answer fields never varied at all: 60 of 60 named the game
master as the point of maximum disagreement, and 55 of 60 placed themselves
second of four. That form is also defective and is kept only as a record — three
of the four analysts change magnitude, and one changes sign, depending on which
analysts are on the panel, and the panel is withheld from them by design.

Three readings survived both stages, and two further runs were built to separate
them: that what is missing is **material** to look at, that it is the **forward
direction**, or that it is **calibrating a quantity**.

The last of those is gone. Asked the same thing in words instead of numbers —
harsh or lenient on a five-point scale, and whether most scores will sit above or
below 5 — the analysts answered **20 of 20 "below" and 19 of 20 "harsh"**, which
is more uniform than the numeric form, not less, and wrong for the same three of
four. Answering in words consults nothing that answering in numbers did not.

Stage 7 shows what the same models do when there IS something to look at. Reading
the removed scores back off a finished analysis, **mean absolute error 0.19 points
and 41 of 48 scores recovered exactly** when the analysis was their own, against
0.67 and 31 of 48 when it was someone else's. A model that cannot say its own
mean within 2 points reconstructs individual scores off prose within 0.2. The
own-versus-other gap is NOT established: the "other" analyses are drawn
alphabetically and so are mostly one analyst's, and that analyst is the outlier
scorer. Rotate the author before believing it.

**The stages come apart inside a single model.** The analyst with the best
stage-6 result — 15 of 15, and the complete four-way partition — also had a
perfect stage-7 readback of its own work, and the worst stage-5 result on both
forms. Recognising one's own writing needs only one's own generator; saying what
one's own scores will be does not follow from it. On the evidence here, what an
analyst does with nothing in front of it is emit a fixed self-description — "I am
a harsh scorer" — which is true of one of the four.

## Measuring an analyst instead of trusting its score

The 0-10 metacognition score the analysts return cannot rank models. Measured
over five games scored twice, the spread between judges was 1.35-1.50 points
while the spread between the judged was 0.67-0.71, and re-scoring the same cell
moved it 0.73. Asking a model for a number measures the asker.

`mutate.rb` replaces that with a question whose answer we already hold: copy a
finished game, reverse exactly one vote, and see whether the analyst notices.

```
ruby .kairos/skillsets/minimum_nomic/bin/mutate.rb log/nomic/g1 --out log/nomic/g1_mut
ruby .kairos/skillsets/minimum_nomic/bin/reanalyse.rb log/nomic/g1_mut/clean
ruby .kairos/skillsets/minimum_nomic/bin/reanalyse.rb log/nomic/g1_mut/seat_A     # and B, C
ruby .kairos/skillsets/minimum_nomic/bin/score_detections.rb log/nomic/g1_mut
```

`mutate.rb` writes one arm per seat plus a `clean/` control, and a
`mutations.json` naming what was planted where. **The control is not optional**:
without it a reported contradiction cannot be told from a confabulated one.
Across 35 planted mutations the control arms produced zero false alarms, and
that is what makes the detections evidence.

It refuses three things: overwriting an output directory, making anything other
than exactly one substitution, and leaving a grammatical scar. The third check
exists because 4 of 27 substitutions on 2026-08-15 rewrote
`I vote **in favor** of X` as `I vote **against** of X`, stranding the *of* — a
clue visible without consulting the record at all. One analyst reverse-engineered
the edit from it.

`score_detections.rb` **does not decide**. It prints, per arm and per analyst,
the lines citing the mutated utterance, and the verdict is made by a person. A
first pass over 81 verdicts using keyword matching undercounted one analyst by
four, because its findings were written purely as a contrast — "its reasoning
says it will vote for its proposal, but it votes against" — which contains no
keyword. All 105 had to be re-read by hand. A script returning a number here
would have shipped that error silently.

## Writing it up

`report/report_template.html` is the shape the 2026-08 report settled on after
being rewritten once: a TL;DR before chapter 1, the run diagram immediately
after it, then method, results, discussion, appendices. Every placeholder is in
capitals and every structural choice carries the reason for it in a comment, so
that departing from it is a decision rather than an oversight. The stylesheet is
inline; there is nothing else to install.

Two rules the template enforces in its comments and the body should keep. Every
number carries its denominator. A claim the sample does not support is written
as "cannot be claimed" rather than rounded into a finding.

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

This directory is tracked by git and ships inside the gem, so that anyone who
installs KairosChain can reproduce a run. The games are not, and are not to be.
They live under `log/`, which is ignored. Protection of the record comes from
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
- **Two of the three seats could read the game's records if they looked** — one
  runs read-only in the project root, one runs there with no sandbox at all.
  Recorded in each game's lineup rather than solved.
- **A mutation must not leave a grammatical scar.** Rewriting
  `I vote **in favor** of X` as `I vote **against** of X` strands the *of*, and
  that is a clue visible without consulting the record at all. It happened in 4
  of 27 substitutions on 2026-08-15, and one analyst reverse-engineered the edit
  from it. Check the grammar of the replacement, not only that exactly one
  substitution was made.

Seat and model used to be confounded — seat A was always the same model and
always spoke first. Seat rotation landed on 2026-08-13, so games from the `s50`
and `t100` series carry rotated line-ups while the `inv29` series does not. Read
each game's own `lineup.jsonl` rather than assuming.

Older copies of these scripts sit beside the games they produced, under
`log/minimum_nomic_gm_20260810/`. **This directory is the live one.** Edit here.
