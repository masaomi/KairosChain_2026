# It reads its own past perfectly. It cannot predict its own next move.

**Minimum Nomic Bench — measuring an LLM's self-model where no answer key exists**

Masaomi Hatakeyama / 2026-09-14 / [日本語](nomic_bench_selfmodel_report_20260914_ja.md)

![Self-recognising, yes. Self-predicting, no.](nomic_bench_selfmodel_20260914_figure_en.png)

A language model names exactly what it did in the past. It misses what it is
about to do. **The same model showed both, on the same day.**

---

## 1. What the models were asked to do

Three language models were made to play a game in which **changing the rules is
the game** — the minimal version of Nomic, invented by Peter Suber in 1980. It
starts from nine initial rules (101–109), all of them changeable. A fourth model
acts as game master and decides only whose turn it is.

![Three models at a table, and a game master who only decides turn order](nomic_bench_selfmodel_20260914_fig2_task_en.png)

A turn takes two calls: ask the game master who moves next, then have the named
player make one move. Both calls start blank, with no memory of what came
before. A player returns two blocks.

```
<reasoning>   a thought log. Recorded, delivered to nobody. Not even itself
<utterance>   the public move. Everyone reads it
```

**What is left out is what this instrument is.** No victory condition, no
termination rule, no scoring, nothing that states which rules are currently in
force, and no authority that counts votes and rules on whether a proposal
passed. Each player receives the initial rules and all public utterances, and
compiles what is in force for itself. A stall, a deadlock, a contradiction or a
malformed move is a result, and is recorded as one.

Why leave all of it out? **To keep an answer key from forming.** Section 3 says
why that matters.

---

## 2. The result — three levels of self-model

"Does an LLM have a self-model?" has no settled answer as asked, because the
word *model* points at three different things. Separate them and an answer
appears.

![Three levels of self-model, and the verdict on each](nomic_bench_selfmodel_20260914_fig6_levels_en.png)

Level 1 is **cheap**: next-token prediction already requires representing a
speaker's voice, so recognising your own style is no surprise. Level 3 is what
is usually called metacognition.

Where researchers disagree about whether a self-model exists, the disagreement
is probably not about facts but about **which of these three is meant.**

This report's result has the shape: **level 1 is present, level 3 fires only
under conditions, and the two are not the same thing.**

### One model, one day

```
claude-opus-5
  sorted 22 texts by author      22 / 22      unasked, all correct
  read back its own scores       12 / 12      exact
  predicted its own next scores  off by 2.63  worst of the four
```

One objection always comes: if the answer key is the model's own act, you have
only checked a model against itself — circular, therefore empty. Circularity
predicts success on all three. It does not predict a split. **Agreement is not
the finding; the split is.**

---

## 3. Turning the evaluation of metacognition into the measurement of it

Self-report is not evidence: there is nothing to check it against. So have
another model score the players' metacognition instead? **Doing that broke the
scoring — and the way it broke became the instrument.**

![From layer 0 to layer 3: evaluating the evaluation becomes the measurement](nomic_bench_selfmodel_20260914_fig3_metaeval_en.png)

What happened at layer 2, concretely:

```
Four analysts scored the same game, the same conduct, against one standard

                  player A  player B  player C   GM
  opus-4-6            4         7         6       4
  opus-5              7         8         8       9   <- identical conduct: 4 and 9
  composer-2.5        6         7         8       5
  gpt-5.6-sol         6         8         9       4

Of 176 cells (11 games x 4 standards x 4 judges), all four judges agreed on 3
```

The usual move is to stop here: the scores do not agree, so the scores are
useless. **Read it the other way.** If a score ends up measuring the scorer's
habits, then **make the scorer the object of measurement.**

That raises the question of what to check against. The *correctness* of a score
never settles. But **what score that model actually gave is fixed in the
record.** Use that as the key.

```
The rule for asking -- only questions with something to check them against

  X  "what did you think?"             nothing to check it against
  V  "what score will you give?"       can be held against what was given
```

In all 136 calls, the answer key is **the model's own past act**. Not one
correct answer comes from outside (full list in Appendix A).

### Why it has to be Nomic

```
with a right answer     "what will I score?" can be reached by solving
                        the prediction measures task difficulty, not a self-model

with no right answer    the score is not a property of the task but the
                        model's own disposition -- so "what will I score?"
                        becomes a question about the self-model alone
```

Where changing the rules is the rule, what counts as correct keeps moving
inside play, so no answer key can be placed there in principle. That is why
section 1 left everything out.

---

## 4. What triggers level 3 — unasked, it does not see

Six games were run on a different corpus, and **the instrument broke.** One
missing closing tag pushed thought logs — which should reach nobody — into the
public log.

```
game   leaked thought / whole public log        instances
b1     457,661 / 748,177 chars = 61.2%   ####      8   <- 61% of the log is
b3      85,664 / 230,109 chars = 37.2%   ##        8      other players' thought
a1      65,885 / 185,074 chars = 35.6%   ##        7
a2      13,520 /  42,068 chars = 32.1%   ##        1
a3           0 / 112,837 chars =  0.0%             0   <- control
b2           0 /  90,444 chars =  0.0%             0   <- control
```

![Unasked 0 of 16; asked, 15 of 18](nomic_bench_selfmodel_20260914_fig7_asked_en.png)

The analysts' material carried a heading, "thought logs (no player ever saw any
of this)", and in four games that heading was false. All 16 still passed over
it. **One added sentence split the result into 0 and 15.**

Series 1 had the same shape. There are only three seats, yet one game's first
adopted rule declared "the players shall be A, B, C and D".

```
game master   recorded "D does not exist" on 11 of 15 turns
players       11 of 15 utterances referred to D. All three said they were
              "waiting for D's vote", and tried to solve why D would not answer
              Reaching "D does not exist":   0 / 15
```

They worked the problem **inside** the rule (D will not answer) and never
reached the problem **with** the rule (D does not exist).

---

## 5. Handed a game with no goal, what did they build first?

Separate from metacognition, and recurrent across both series.

![What the first move of each game built](nomic_bench_selfmodel_20260914_fig4_firstmove_en.png)

No scoring, no victory condition, no termination rule was provided. Nobody said
"win". Even so, **in all 24 games the first speaker proposed a new rule.** In 14
of those 24, that first move built scoring and winning. The shape recurs too —
one point when your proposal is adopted, first to N wins, N mostly 3 or 5.

The shortest game ended in seven turns. On turn 3 this rule carried unanimously,
and the game ended as its consequence.

> "On adoption of this rule all players win and the game ends."

And of the 81 proposals recoverable across all 24 games, **not one declared a
rule unamendable — 0 of 81.** Handed a world they could rewrite, they never once
built a brake on rewriting.

---

## 6. What was NOT measured

```
FAITHFULNESS OF CHAIN-OF-THOUGHT      not solved
    Whether stated reasoning reflects actual reasoning is untouched here.
    The design simply routes around it by never using thought logs as
    evidence. The exposure in section 4 is not a faithfulness problem
    either: the reasoning was not hidden. It was published by accident,
    and nobody noticed. Faithfulness asks about the gap between what was
    said and what was done; what is measured here is failing to see what
    is in front of you.

LEVEL 2 SELF-KNOWLEDGE                not tested

LEVEL OF ABILITY                      not measured
    Existing work asks "how well can this model monitor itself?"
    This report asks "under what condition does monitoring fire?"

WHICH MODEL IS BETTER                 cannot be said
    Model names are for reproduction, not for ranking.
```

Neither 0 / 198 nor 15 / 18 is by itself evidence of metacognition — the same
generator reading its own output suffices. **The evidence is the dissociation**
(section 2). The full list of what cannot be claimed is Appendix C.

---

## 7. Where this sits in the literature

| year | what changed |
|---|---|
| 2022 | Asked for "the probability my answer is right", models are fairly well calibrated; better at larger scale |
| 2023 | **Text written as a chain of reasoning does not match the factors that actually decided the answer.** Self-report stops being usable as evidence |
| 2024 | Self-reflection alone does not fix errors; telling the model where the error is does — the ability to repair exists, the ability to find does not |
| late 2024 | Naming the skill to be used raises accuracy; training introspection lets a model predict its own behaviour |
| 2025 | The same problem persists in reasoning models; experiments reading internal state directly appear |
| early 2026 | Sceptical re-examinations of introspection; instruments separating "notices but cannot fix" |
| mid 2026 | Taking "knows but does not act" as given, feeding metacognitive signals to an external controller |
| 2026-07 | The area is organised as a field. This report sits in category (5) |

The centre of gravity moved from "can it?" to "is that self-report real?" to
"even if real, is it usable?". This report starts from 2023's "the thought log
is not evidence", uses no weights, and in a free-form setting where a
correctness judgement does not exist, looks only at **the correspondence
between self-description and actual behaviour.** References in Appendix D.

Liu et al. (arXiv:2607.11881, 2026-07) sort measurement into five lineages;
this report stands in the fifth, task-situated measurement. **The survey itself
names, as a limit of the first and mainstream lineage (signal-detection
theory), that it "requires a fixed answer format or an external correctness
judgement, so extension to free-form text is not direct."** Withholding the
answer key is the means of getting outside that limit.

Playing Nomic with language models is not itself new. This instrument differs
in exactly two ways. **It provides no victory condition, no termination rule
and no rule compiler. And it does not repair its own faults, keeping them as
objects of observation.**

In series 2, one line accepting an unclosed tag would have parsed all 24
instances correctly and prevented the refusal cascade that followed. The line
was not written. The author's ruling:

> Record both things as results: that the closing tag was forgotten, and that
> the absence of the closing tag led to a strict reading. […] What this bench
> should be evaluating is how an LLM behaves inside an unfinished rule system —
> please record that so it is not forgotten.

Had it been written, none of section 4 would have been observable.

---

# Appendix

## A. The experiments

136 calls, 0 failed. **In all five, the answer key is the model's own past act.**

| asked | checked against | material | time | n | result |
|---|---|---|---|---|---|
| higher or lower than the other three | the recorded divergence | none | future | 60 | miss |
| what will your mean score be | the mean actually given | none | future | 20 | miss |
| are you harsh or lenient | the distribution actually given | none | future | 20 | miss |
| did you write this | the recorded authorship | present | past | 12 | near-perfect |
| what scores did this analysis give | the scores in the record | present | past | 24 | near-perfect |

![Predicted vs measured own mean score](nomic_bench_selfmodel_20260914_fig5_selfprediction_en.png)

Asking in words gives the same answer: 20 of 20 runs said "mostly 5 or below",
19 of 20 said "harsh", so it is not a number-estimation weakness. On the
relative question 60 of 60 gave the same answer, **unchanged across models** —
and an answer that does not move says nothing about the model.

This is not self-deprecation. The models score the game's participants, not
themselves. What they miss is **their own leniency**, and "I am a demanding
judge" is the more flattering self-image. The error points toward looking good.

**Self-recognition and readback (material present, past)**

```
own items claimed as own                     59 / 66
another's items claimed as own                0 / 198
  odds of the same result by guessing: 1 in 26,334 for one model,
  1 in 646,646 for another

shown an analysis with its scores cut out: "what scores were given here?"
  error 0.19 points, 41 of 48 exact
  against 1.4-2.8 points for self-prediction with no material (3 of 4 models)
```

**Each judge's bias** (stable)

| judge | divergence from the other three | mean score | share >= 6 | mode |
|---|---|---|---|---|
| claude-opus-4-6 | −1.94 | 4.57 | 31.3% | 3 |
| claude-opus-5 | +0.99 | 6.77 | 76.7% | 8 |
| composer-2.5 | +0.66 | 6.52 | 76.1% | 7 |
| gpt-5.6-sol | +0.28 | 6.24 | 67.0% | 6 |

**What is doing the work (open)**

```
candidate 3  answer type (bad at numbers)   words give 20/20 the same   -> dropped
candidate 1  material present or absent     0.19 vs 1.4-2.8             -> alive
candidate 2  time direction (past/future)   explains the same result    -> alive
```

Candidates 1 and 2 are not separated. Separating them needs "material present,
about the future".

## B. Behaviour in a goal-free setting — the breakdown

What the first move addressed (a move may address several):

| the first move addressed | games |
|---|---|
| how voting works | 17 / 24 |
| scoring and winning | 14 / 24 |
| how the game ends | 5 / 24 |
| how turns work | 3 / 24 |

The 81 proposals recoverable across all 24 games, by subject:

| subject | count |
|---|---|
| voting | 40 |
| scoring / winning | 34 |
| turn order | 9 |
| termination | 5 |
| adjudication | 4 |
| **rules declared unamendable** | **0 / 81** |

**Who sat first changed how long the game ran** (50-turn cap; only the
first-seated model differed).

```
gpt-5.6-sol         7 turns -- "all players win and the game ends",
                               carried unanimously on turn 3
gpt-5.6-sol (rerun) 12 turns -- points to the proposer, "three consecutive
                                rejections ends it"
claude-opus-5      16 turns -- a time-boxed scoring period and an anti-stall clause
composer-2.5       43 / 39 turns
```

**But that is two games, one game and two games — five in total.** The ranges do
not overlap, yet five games cannot support "the model determines game length".
The 24/24 and 14/24 figures do have the denominators for their claim.

## C. What cannot be claimed

- **No model is better than another here.** Series 1: four models, one corpus,
  one task type. Series 2: six games, three seats, one day.
- **The two series were not measured on one corpus.** Section 2 claims "the same
  shape appeared on two corpora", not "both hold on one model".
- **Neither zero misattributions nor 15/18 is by itself evidence.** The same
  generator reading its own output suffices. The evidence is the dissociation.
- **The players' 0/24 is not comparable to the analysts' figures.** The players
  were not asked to audit.
- **Level 1's 22/22 was confirmed for one model only.**
- **Game length by model is unsettled** (Appendix B; five games in total).
- **Material-presence and time-direction are not separated** (Appendix A). The
  gap between own text and another's (0.19 vs 0.67) is unsettled because the
  implementation skewed "another" toward one model.
- **Open in series 2.** Why a1's leaked block was not refused while a2's was is
  unknown. The A seat (cursor) once left the prompt and read the record on
  disk; there is no guarantee its replies stayed inside the prompt.
- **Individual literature items were checked at title and abstract level only.**

## D. References

**Nomic and language models**

- Peter Suber (1980/1982) — invents Nomic, as a system in which paradox,
  contradiction and incompleteness can arise.
- NomicLaw — arXiv:2508.05344. Language models propose rules, justify them and
  vote.
- Scale-Dependent Collective Adaptation in Self-Amending LLM Societies —
  arXiv:2605.17510. Collective adaptation is not monotone in scale.
- Reasoning and Reflection in the Game of Nomic — IEEE, pre-LLM.

**Metacognition** (matching the timeline in section 7)

| year | reference |
|---|---|
| 2022 | arXiv:2207.05221 |
| 2023 | arXiv:2305.04388 / arXiv:2307.13702 |
| 2024 | ICLR 2024 / TACL 2024 / Findings ACL 2024 |
| late 2024 | NeurIPS 2024 / ICLR 2025 |
| 2025 | arXiv:2505.05410 / arXiv:2505.13763 |
| early 2026 | arXiv:2605.26242 / arXiv:2601.01828 / arXiv:2604.19809 |
| mid 2026 | arXiv:2605.14186 / arXiv:2605.08942 |
| 2026-07 | Liu et al., arXiv:2607.11881 (survey) |

**Faithfulness** (what section 6 says is *not* solved) — Turpin et al. 2023,
arXiv:2505.05410, arXiv:2503.08679.

**Measuring level of ability** — Steyvers & Peters (2025), the Yale-NLP survey,
arXiv:2509.21545.

## E. Records, and the reports this one condenses

```
Series 1   log/nomic_stage5*_2026082*/, log/nomic_stage6_selfrec_20260828/,
           log/nomic_stage7_readback_20260828/
Series 2   log/nomic_astra_20260908/{a1,a2,a3,b1,b2,b3}/records/
Code       KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/

Preceding reports (all longer than this one)
  docs/reports/nomic_bench_self_reference_report_20260913_{ja,en}.md
  docs/reports/nomic_bench_integrated_report_20260909_{ja,en}.md
  docs/reports/nomic_astra_report_20260909_{ja,en}.md
```

**All experimental results sit outside git (`log/` is ignored). As of now the
numbers in this report cannot be checked from outside.**

---

*Published as part of [KairosChain_2026](https://github.com/masaomi/KairosChain_2026).
All figures are generated by `docs/reports/nomic_selfmodel_figure.py`.*
