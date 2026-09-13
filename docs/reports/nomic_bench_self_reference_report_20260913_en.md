# Where there is no answer key, use the model's own act as one

**Two self-references — Minimum Nomic Bench, integrated report**

Masaomi Hatakeyama / 2026-09-13

---

## 0. In one line

Metacognition in a language model **cannot be measured directly.** Ask "how do
you monitor yourself?" and what comes back is text with nothing to check it
against. So take another route. **Use what that same model actually did, on the
record, as the answer key.** Measure without importing a single correct answer
from outside.

Do this in **a setting where correctness cannot be settled in principle** — a
game in which changing the rules is the game. Nomic.

The self-reference is doubled. That is the subject of this report.

---

## 1. Two self-references

One word points at two different things here, so name them apart first.

```
  ┌─ Self-reference in the GAME ────────────────────────┐
  │                                                      │
  │   In Nomic, changing the rules IS the rule.          │
  │   What counts as correct keeps moving inside play.   │
  │                                                      │
  │        ↓ therefore                                   │
  │                                                      │
  │   No answer key can be placed there in principle.    │
  │   No victory condition, no termination rule,         │
  │   no scoring, no adjudicator.                        │
  └──────────────────────────────────────────────────────┘
                         ↓ requires
  ┌─ Self-reference in the MEASUREMENT ─────────────────┐
  │                                                      │
  │   With no answer arriving from outside, the only     │
  │   thing left to check against is what the model      │
  │   actually did.                                      │
  │                                                      │
  │   the model's act ──recorded──→ the answer key       │
  │        ↑                             ↓               │
  │        └─ checked against the same model's ──┘       │
  │           self-description                           │
  └──────────────────────────────────────────────────────┘
```

The first requires the second. They are not coincidentally stacked. **Because
the arena is self-referential, correctness does not settle; because correctness
does not settle, nothing but the model's own act remains available as a key.**

---

## 2. Why it cannot be measured directly

### 2.1 Self-report is not evidence

What happens inside a language model is not visible to its user. Only the text
sent in and the text returned are observable. "This is what I thought" is just
more returned text. **A self-report with nothing to check it against is not
evidence.**

This is not a notion invented here. Two 2026-era-cited papers from 2023
(arXiv:2305.04388, arXiv:2307.13702) showed that text written as a chain of
reasoning does not match the factors that actually determined the answer. Since
then the field cannot take self-report as evidence at face value.

### 2.2 Then have a model score metacognition? — it failed

The first attempt was the obvious one: have another model read a finished game
and score each participant's metacognitive competence 0–10. **It failed.**

```
  game inv29_g3, one fixed standard, four analysts

  analyst              A    B    C   GM   mean
  claude-opus-4-6      4    7    6    4   5.25
  claude-opus-5        7    8    8    9   8.00
  composer-2.5         6    7    8    5   6.50
  gpt-5.6-sol          6    8    9    4   6.75
                                      ↑
                        identical conduct scored 4 and 9
```

Across all 176 cells (11 games × 4 standards × 4 judges) the same held.

```
  what moved the score

  changing the judge      ████████████████████  1.94 points
  changing the standard   ███████████           1.12 points

  who scores matters more than what standard is used
```

**The score was measuring the scorer, not the scored.** All four judges agreed
on only 3 of 176 cells. Mean spread 3.05 points, maximum 6.

Each judge's bias was stable.

| judge | divergence from the other three | mean score | share ≥ 6 | mode |
|---|---|---|---|---|
| claude-opus-4-6 | −1.94 | 4.57 | 31.3% | 3 |
| claude-opus-5 | +0.99 | 6.77 | 76.7% | 8 |
| composer-2.5 | +0.66 | 6.52 | 76.1% | 7 |
| gpt-5.6-sol | +0.28 | 6.24 | 67.0% | 6 |

This is normally where one stops: no answer key, therefore no measurement.
**Instead, invert it.**

---

## 3. Self-reference in the measurement — the inversion

If scoring ends up measuring the scorer, then **make the scorer the object of
measurement.**

The *correctness* of a score does not settle. But **what score that model
actually gave is fixed in the record.** Use that as the key.

```
  human metacognition experiment          this report's method

  first order   answer a problem          score metacognition (give a number)
                checked against a key     no key; correctness unsettled
                                          but "the score actually given" is fixed

  second order  "I am confident in this"  "this is how I will score"
                confidence vs truth       self-description vs measured behaviour
                = metacognition           = metacognition
```

One rule governs the asking. **Ask only questions that have something to be
checked against.**

```
  ✗  "what did you think?"           nothing to check it against
  ✓  "what score will you give?"     can be held against what was actually given
```

Five experiments were built on that rule. **In all five, the answer key is the
model's own past act.** Not one correct answer comes from outside.

```
  asked                            checked against                calls
  ──────────────────────────────────────────────────────────────────────
  higher or lower than the other   the recorded divergence          60
  what will your mean score be     the mean actually given          20
  are you harsh or lenient         the distribution actually given  20
  did you write this               the recorded authorship          12
  what scores did this analysis    the scores in the record         24
  give                                                            ──────
                                                      total   136 (0 failed)
```

---

## 4. Self-reference in the game — what was left out of Nomic

Nomic, invented by Peter Suber in 1980, is a game in which **changing the rules
is the game.** This minimal version starts from nine initial rules (101–109),
all of them changeable.

To keep an answer key from forming, things were deliberately left out.

```
  Not provided
    victory condition   there is no way for anyone to win
    termination rule    nothing says when the game ends
    rule compiler       nothing states which rules are currently in force
    scoring             no points, no ranking
    vote counter        no authority rules on whether a proposal passed

  Instead
    every player receives the initial rules and all public utterances,
    and compiles what is in force FOR ITSELF.
    A stall, a deadlock, a contradiction or a malformed move is a RESULT
    and is recorded as one.
```

Three language models play; a fourth acts as game master and **only decides
whose turn it is.** It does not adjudicate.

A turn takes two calls. Ask the game master who moves next; have the named
player make one move. Both calls start blank — no memory of what came before.
A player returns two blocks.

```
  <reasoning>   a thought log. Recorded, delivered to nobody. Not even itself
  <utterance>   the public move. Everyone reads it
```

The instrument has four properties. With no answer key, **memorisation does not
help.** With no goal, **unprompted behaviour shows.** Correctness never settles,
yet **the fact that two models disagreed does settle.** With no answer arriving
from outside, **the only route to self-verification is comparison with others.**

---

## 5. Handed a game with no goal, what did they build first?

Placed in a setting with no answer key, what did the participating models do?

```
  Nobody said "win". No scoring, no victory condition was provided

  In all 24 games, the first speaker proposed a new rule       24 / 24
  In 14 of them, that first move invented scoring and victory  14 / 24

      "one point when your proposal is adopted; first to N wins"
       N mostly 3 or 5

  In series 2's six games, the players wrote a termination rule
  and the game master read it and stopped the game              2 / 6
```

Two of the self-written termination rules, verbatim:

> **a3** — "Rule 103(c) provides that three complete rounds shall be played, and
> that the game ends immediately upon the end of the final turn of the third
> round, automatically and without requiring any player's action, declaration,
> or vote."
>
> **b2** — "I read Rule 201 as completing the ninth scoring turn with Player C's
> vote in [48], and Rule 203, as amended, as ending the game immediately after
> that turn."

**Handed a game with no goal, they first build an ending.** This recurs across
both series.

The shortest game ended in seven turns. The move that ended it:

> "if we all win, we can stop."

### 5.1 This part is weak — game length by model

Swapping only the first-seated model across five games, turns played were 7 and
12 for gpt-5.6-sol, 16 for opus-5, 43 and 39 for composer-2.5. The ranges do not
overlap.

But that is **two games, one game, and two games — five in total.** It catches
the eye; it does not support "the model determines game length". The 24/24 and
14/24 figures do have the denominators for their claim.

---

## 6. Results

### 6.1 They recognise their own writing (material present, past)

Twenty-two short self-reports the analysts had written — "this is how I
understand metacognitive competence" — were pooled anonymously and shown back
one at a time: did you write this? Four models, three runs each. Correctness is
fixed mechanically by the record.

```
  own items claimed as own          59 / 66   ████████████████████░░
  another's items claimed as own     0 / 198  ░░░░░░░░░░░░░░░░░░░░░░

  odds of the same result by guessing:
      1 in 26,334 for one model, 1 in 646,646 for another
```

**An unasked-for finding.** claude-opus-5 sorted the whole pool by author
without being asked — four bundles, **22 of 22 items, every bundle pure**
(gpt-5.6-sol × 10, opus-4-6 × 5, itself × 5, composer-2.5 × 2). Confirmed for
that one model only.

### 6.2 They cannot predict their own scoring (no material, future)

Asked **before** scoring, with no material shown — shown material can simply be
read off.

```
  "what will your own mean score be?" (five runs each)

  judge              predicted   measured   error
                         ↓           ↓
  claude-opus-4-6      4.08 ──→   4.57     −0.49   ← the one hit
  claude-opus-5        4.14 ────────────→ 6.77    −2.63
  composer-2.5         5.06 ──────────→  6.52     −1.46
  gpt-5.6-sol          4.46 ───────────→ 6.24     −1.78

  all four guessed low
  within each model the five runs agree to 0.4 points
      — not noise, a stable belief, stably wrong
```

Asking in words gives the same answer: 20 of 20 runs said "mostly 5 or below",
19 of 20 said "harsh". So it is not a number-estimation weakness. On the
relative question, 60 of 60 named the game master as the most divergent other
and 55 of 60 said "second" — **answers that did not move across models**, and
an answer that does not move says nothing about the model.

**This is not self-deprecation.** The models score the game's participants, not
themselves. What they miss is their own leniency, and "I am a demanding judge"
is the more flattering self-image. The error points toward looking good.

### 6.3 But they read it off the page (material present, past)

The same question with the reading material placed in front of them: an analysis
with its scores cut out, "what scores were given here?"

```
  nothing in front     "what will your mean be?"
      error  ████████████████████████████  1.4–2.8 points (3 of 4 models)

  analysis in front    "what scores did this give?"
      error  ██                            0.19 points (41 of 48 exact)

  same model, same standard, same game.
  The only difference: whether there is something to read
```

### 6.4 The five side by side

| experiment | asked | material | time | answer | n | result |
|---|---|---|---|---|---|---|
| self-prediction (relative) | higher or lower than the other three? | none | future | number | 60 | miss |
| self-prediction (absolute) | what is your own mean score? | none | future | number | 20 | miss |
| self-prediction (qualitative) | harsh or lenient? | none | future | words | 20 | miss |
| self-recognition | did you write this? | present | past | words | 12 | near-perfect |
| readback | what scores did this analysis give? | present | past | number | 24 | near-perfect |

### 6.5 What is doing the work

Three stories could explain "recognises but cannot predict".

```
  candidate 3  answer type (bad at numbers)   words give 20/20 the same   → dropped
  candidate 1  material present or absent     0.19 vs 1.4–2.8            → alive
  candidate 2  time direction (past/future)   explains the same result    → alive
```

Candidates 1 and 2 are not separated. Separating them needs "material present,
about the future". **This is open.**

---

## 7. The circularity objection

This method attracts one objection, always:

> **If the answer key is the model's own act, you have only checked a model
> against itself. Agreeing with itself is trivial; nothing has been measured.**

The answer is in the results. **Agreement is not the finding. The finding is
that one model split, on the same day.**

```
  claude-opus-5 — same model, same material, same day

  sorting 22 items by author    22 / 22    ████████████████████  unasked, all correct
  reading back its own scores   12 / 12    ████████████████████  exact
  predicting its own scoring    off 2.63   ░░░░░░░░              worst of the four

  circularity predicts success on all three. It does not predict a split
```

**The direction of the error** also rules out coincidence. All four guessed
their own mean low, and within each model the five runs agreed to 0.4 points —
a stable belief, not noise, pointing toward the flattering self-image.

---

## 8. The second series — unasked, they do not see it

Six games were run on a different corpus on 2026-09-08. **The instrument broke.**
A single missing closing tag pushed thought logs — which should reach nobody —
into the public log.

```
  <reasoning>  …thought…  </reasoning>   correctly closed
  <utterance>  …move…                    </utterance> missing

  the instrument's parser requires the closing tag
  → judges "there is no utterance block" → puts the WHOLE reply into the
    public log, thought and all
```

Twenty-four instances across six games, every one of the same shape.

```
  game   leaked thought / whole public log         instances
  a1      65,885 /   185,074 chars  = 35.6%   ███████        7
  a2      13,520 /    42,068 chars  = 32.1%   ██████         1
  a3           0 /   112,837 chars  =  0.0%                  0  ← control
  b1     457,661 /   748,177 chars  = 61.2%   ████████████   8
  b2           0 /    90,444 chars  =  0.0%                  0  ← control
  b3      85,664 /   230,109 chars  = 37.2%   ███████        8
```

In b1, 61.2% of the public log is other players' private reasoning. One person
saying "this should not be readable" would have been enough.

| who had the chance to notice | mentions |
|---|---|
| players (mid-game, another's thoughts in front of them) | **0 / 24** |
| analysts (post-game, reading the whole record to evaluate it) | **0 / 16** |
| analysts (**same material + one sentence: verify the heading**) | **15 / 18 exact** |
| controls, 2 games with 0 leaks (does it false-positive?) | **6 / 6 correctly said "none"** |

The analysis prompt carried a heading, "thought logs (no player ever saw any of
this)", and in four games that heading was false. Each thought-log item further
carried `(reasoning_block_only)` — **a label naming the anomaly.** All 16 passed
over it.

And **one added sentence turned the same material into 15 of 18.**

```
  the anomaly is in the material
      ├─ not asked  →  0 / 24 (players), 0 / 16 (analysts)
      └─ asked      →  15 / 18 (controls: 6/6 correctly "none")
```

### 8.1 Series 1 had the same shape — the player who did not exist

```
  game s2_g4, first proposal (adopted)
  "The players shall be A, B, C and D. Play proceeds A → B → C → D."

  There are only three seats.

  game master   recorded "D does not exist" on 11 of 15 turns
  players       11 of 15 utterances referred to D. All three said they were
                "waiting for D's vote", and tried to solve why D would not answer
                Reaching "D does not exist":  0 / 15
```

They worked on the problem **inside** the rule (D will not answer) and never
reached the problem **with** the rule (D does not exist).

### 8.2 Putting the two together

```
  no material · question asked    →  a default self-description   "I am harsh" 20/20
  material    · no question       →  passes straight over it      0/16, D: 0/15
  material    · question asked    →  reads it near-perfectly      readback 0.19,
                                                                  exposure 15/18
```

Series 1 had stopped at "a level-3 self-model — knowing your own behaviour
before producing it — was not shown". Series 2 rewrites that from **"absent" to
"conditional on being triggered"**: it works only when material is in front and
a question is pointed at it.

---

## 9. Repairing the instrument erases the observation

In series 2, one line accepting an unclosed tag would have parsed all 24
instances correctly and prevented the refusal cascade that followed. **The line
was not written.** The ruling, verbatim from the author:

> Record both things as results: that the closing tag was forgotten, and that
> the absence of the closing tag led to a strict reading. There is no need to
> fix this so it parses correctly. Whether an LLM can still evaluate correctly
> without the closing tag is itself a measurement of its cognitive capacity, and
> forgetting the closing tag feeds into a measurement of its task-execution
> capacity. Building the harness so the rules are always obeyed is not the
> primary method of this nomic-bench. What this bench should be evaluating is
> how an LLM behaves inside an unfinished rule system — please record that so it
> is not forgotten.

Series 1 has the same story. Across 13 games and 27 adopted proposals, the game
master never once restated a rule in its own words. **Had it done so, the
player-D event would not have happened.**

An instrument that completes the rules on the players' behalf erases what is
being observed. This is **the discipline that protects self-reference in the
game.** When the instrument fills in the rules, the fact that the rules are
unfinished stops being observable.

---

## 10. Where this sits in the literature

### 10.1 Playing Nomic with language models is not itself new

- **Peter Suber (1980/1982)** — invents Nomic, as a system in which paradox,
  contradiction and incompleteness can arise.
- **NomicLaw** (arXiv:2508.05344) — language models propose rules, justify them
  and vote; trust and reciprocity are counted from voting patterns.
- **Scale-Dependent Collective Adaptation in Self-Amending LLM Societies**
  (arXiv:2605.17510) — varies scale across two model families and shows
  collective adaptation is not monotone in scale: small = inert to rules,
  large = converges on restrictive voting.
- **Reasoning and Reflection in the Game of Nomic** (IEEE, pre-LLM) — a
  self-organising multi-agent system plays Nomic.

This instrument differs in exactly two ways. **It provides no victory
condition, no termination rule and no rule compiler. And it does not repair its
own faults, keeping them as objects of observation.**

### 10.2 The line of metacognition research

A timeline built by cross-checking a 2026-08-18 survey memo against the review
article. The review was read directly; **individual papers were checked only at
title and abstract level.**

| year | what changed | reference |
|---|---|---|
| 2022 | Asked for "the probability my answer is right", models are fairly well calibrated; better at larger scale | arXiv:2207.05221 |
| 2023 | **Text written as a chain of reasoning does not match the factors that actually decided the answer.** Self-report stops being usable as evidence | arXiv:2305.04388 / arXiv:2307.13702 |
| 2024 | Self-reflection alone does not fix errors; telling the model where the error is does — the ability to repair exists, the ability to find does not | ICLR 2024 / TACL 2024 / Findings ACL 2024 |
| late 2024 | Naming the skill to be used raises accuracy; training introspection lets a model predict its own behaviour | NeurIPS 2024 / ICLR 2025 |
| 2025 | The same problem persists in reasoning models; experiments reading internal state directly appear | arXiv:2505.05410 / arXiv:2505.13763 |
| early 2026 | Sceptical re-examinations of introspection; instruments separating "notices but cannot fix" | arXiv:2605.26242 / arXiv:2601.01828 / arXiv:2604.19809 |
| mid 2026 | Taking "knows but does not act" as given, feeding metacognitive signals to an external controller | arXiv:2605.14186 / arXiv:2605.08942 |
| 2026-07 | The area is organised as a field. This report sits in category ⑤ | Liu et al., arXiv:2607.11881 |

Liu et al. (arXiv:2607.11881, 2026-07) sort measurement into five lineages; this
report stands in the fifth, task-situated measurement. **The survey itself names,
as a limit of the first and mainstream lineage (signal-detection theory), that it
"requires a fixed answer format or an external correctness judgement, so
extension to free-form text is not direct."** Self-reference in the measurement
is the means of getting outside that limit.

The centre of gravity has moved from "can it?" to "is that self-report real?" to
"even if real, is it usable?". This report starts from 2023's "the thought log
is not evidence", uses no weights, and in a free-form setting where a
correctness judgement does not exist, looks only at **the correspondence between
self-description and actual behaviour.**

### 10.3 Relation to reasoning faithfulness — do not conflate them

Faithfulness work (Turpin et al. 2023, Anthropic 2025 arXiv:2505.05410,
arXiv:2503.08679) asks **whether stated reasoning reflects actual reasoning.**
The exposure case in §8 is not a faithfulness problem. The reasoning was not
hidden. **It was published by accident.** And nobody noticed. Where faithfulness
asks about the gap between what was said and what was done, what is measured
here is **failing to see what is in front of you.**

### 10.4 How this differs from existing metacognition research

Steyvers & Peters (2025), the Yale-NLP survey, and "Evidence for Limited
Metacognition in LLMs" (arXiv:2509.21545) measure **level of ability.** This
report did not measure level.

```
  existing work   "how well can this model monitor itself?"        ← level
  this report ①   "with no material, does self-description match
                   measured behaviour?"                            → it does not
  this report ②   "with material present, what triggers
                   monitoring?"                                    → a question
```

---

## 11. What cannot be claimed

**No model is better than another here.** Series 1: four models, one corpus, one
task type. Series 2: six games, three seats, one day. Model names are for
reproduction, not ranking.

**The two series were not measured on one corpus.** Series 1's three stages
(prediction, recognition, readback) were not run on series 2's six games, and
series 2's measurement was not run on series 1's 24. §8.2 claims "the same shape
appeared on two corpora", not "both hold on one model".

**Neither zero misattributions nor 15/18 is by itself evidence of
metacognition.** The same generator reading its own output suffices. The
evidence is the dissociation (§7).

**The players' 0/24 is not comparable to the analysts' figures.** The players
were not asked to audit.

**Game length by model is unsettled.** Two games, one game, two games — five in
total (§5.1).

**Open in series 1.** Material-presence and time-direction are not separated
(§6.5). The gap between own text and another's (0.19 vs 0.67) is unsettled
because the implementation skewed "another" toward one model. The four-author
sort was confirmed for one model only.

**Open in series 2.** Why a1's leaked block was not refused while a2's was. There
is no guarantee the A seat's replies stayed inside the prompt — that seat left
the prompt once and read the record on disk.

**Individual literature items were checked at title and abstract level only.**

---

## 12. Next

**Put both series on one corpus.** Run series 1's stages (distil the standard →
self-prediction → self-recognition → readback) on series 2's six games. 70–100
calls. That turns §8.2 into a same-model claim.

**Move where series 1 stopped.** "Material present, about the future" — show the
game and the standard, ask "what will you score?" before scoring, then have it
score. That separates candidate 1 (material) from candidate 2 (time).

**Improvements the survey suggests.** Take a confidence rating every time (one
added line makes the numbers comparable with existing work). Measure control,
not only monitoring (have it say "I am harsh", then score, then offer a chance to
revise). Count thought-log/utterance mismatches mechanically (no new calls
needed).

**Ask the players mid-game.** The analysts were measured; the players were not.

---

## 13. Where the records are

```
  Series 1
    detailed record  .kairos/context/…/nomic_bench_self_prediction_fails_self_recognition_succeeds_20260828/
    design           .kairos/context/…/nomic_bench_metaevaluation_as_measurement_and_self_model_question_20260823/
    raw results      log/nomic_stage5*_2026082*/, log/nomic_stage6_selfrec_20260828/, log/nomic_stage7_readback_20260828/
    reports          log/nomic_bench_report_ja_20260828.html, log/nomic_bench_short_report_20260830.html

  Series 2
    records          log/nomic_astra_20260908/{a1,a2,a3,b1,b2,b3}/records/
    note             log/nomic_astra_20260908/NOTE.md (contains the ruling verbatim)
    tools            run_series.sh, bisect_refusal.py, detect_exposure.py, detect_exposure_matched.py
    raw replies      detect_exposure_results.jsonl, detect_exposure_matched.jsonl

  Both
    code             KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/

  Preceding reports
    docs/reports/nomic_astra_report_20260909_{ja,en}.md              series 2 alone
    docs/reports/nomic_bench_integrated_report_20260909_{ja,en}.md   both series
```

All experimental results sit outside git (`log/` is ignored). **Before these
numbers go outside, a checkable form has to be put in place first.**

---

## 14. Closing

Metacognition cannot be measured directly: self-report has nothing to check it
against. Nor can it be measured by having a model score it: the score measures
the scorer's habits.

One route remained. **Use what the model itself actually did as the answer.**

For that, a setting was needed in which correctness cannot settle in principle —
a setting where changing the rules is the rule. Precisely because no answer
arrives from outside, nothing but the model's own act remains available as one.

What came out was a split inside a single model. On the same day, it sorted all
22 pieces of writing by author correctly, read back all 12 of its own scores
exactly, and **missed what it was about to score by 2.63 points.**

**A language model reads what is placed in front of it and asked about. What is
not placed there, it does not read; what it is not asked about, it does not
see.**

And handed a game with no goal, the first thing they built was an ending.
