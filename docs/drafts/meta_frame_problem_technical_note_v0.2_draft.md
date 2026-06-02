# The Meta-Frame Problem: Goal Manufacture and the Outermost-Frame Ceiling in Self-Amending LLM Societies

**Technical Note — v0.2 DRAFT (for collaborator review; pre-publication)**

Masaomi Hatakeyama

*Department of Evolutionary Biology and Environmental Studies, University of Zurich.*

> **Status and intent.** Working draft circulated to collaborators **before** any public posting. It builds on two prior works of which the present author is a co-author: (1) Horibe, Hatakeyama, Masumoto, Hashimoto & Romero (2026), *Scale-Dependent Collective Adaptation in Self-Amending LLM Societies* (arXiv:2605.17510), which supplies the in-frame (closed) Nomic configuration; and (2) Hatakeyama & Hashimoto (2009), *Minimum Nomic: a tool for studying rule dynamics* (Artif. Life Robotics 13:500–503), which introduced the open-frame game and the question of how purpose and goal *emerge* when none is given. This note is a **position-plus-pilot** note: the conceptual proposal (the *meta-frame problem*) is its primary contribution; the empirical material consists of two small pilot runs and is presented as illustration and as a menu of testable hypotheses, **not** as a powered result. Authorship and whether this becomes a solo note or a joint follow-up are open questions for this circulation.

---

## Abstract

The classic frame problem of AI (McCarthy & Hayes 1969; Dennett 1984) has a technical reading — representing the non-effects of actions in logic — now considered settled, and a philosophical residue — how a finite system determines what is *relevant* without exhaustive search — that remains open (Shanahan 2016; Fodor 1987). This note proposes a distinct but adjacent problem, the **meta-frame problem**: not the inability to bound relevance *within* a frame, but the inability of an agent to attain a standpoint *outside its own outermost frame* — the frame within which all of its moves, including frame-changing moves, are already counted as moves. We argue that self-amending games make this problem observable for large language model (LLM) agents, and that the open-frame game of Hatakeyama & Hashimoto (2009) — Minimum Nomic, in which no goal is given and the question is how a goal *emerges* — is its natural instrument. We report two pilot runs on a fixed roster of five frontier LLMs and use them to frame, rather than to settle, the question. We then state a set of hypotheses, each paired with a low-cost confirmation path (several requiring only re-grading of existing transcripts, not new generation), so that the heavy token cost of fresh Nomic runs is incurred only where a hypothesis genuinely requires it.

**Keywords:** frame problem, meta-frame problem, frame transcendence, relevance realization, Minimum Nomic, self-amending games, large language models, metacognition.

---

## 1. From the frame problem to the meta-frame problem

The frame problem entered AI as a technical difficulty in the situation calculus: to infer that an action leaves most of the world unchanged, one must in principle assert an unbounded number of *frame axioms* stating what each action does *not* affect (McCarthy & Hayes 1969). Within logic-based AI this technical problem is, as Shanahan (2016) puts it, one on which "the dust has settled"; successor-state axioms and non-monotonic formalisms address it adequately.

Dennett (1984) appropriated the term for a deeper, epistemological problem. His robots — R1, which fails to infer that pulling the wagon also moves the bomb resting on it; R1D1, which sets out to check every side-effect and is paralysed; R2D1, which tries instead to enumerate the irrelevant and is paralysed differently — dramatise one difficulty: *deciding what is relevant, in real time, without first having to consider everything.* Fodor (1987) located the difficulty in the holism of belief fixation — any belief can in principle bear on any other, so relevance cannot be cleanly localised. Shanahan (2016) records this as the lasting philosophical legacy of the frame problem: *informational unencapsulation.* Vervaeke & Ferraro (2013) restate the positive task as **relevance realization** — intelligence as the recursive, self-organising determination of what matters. Dreyfus (1992, 2007), drawing on Heidegger, argued that the regress dissolves only if intelligence is not representation-guided but *thrown* — always already embedded in a context it did not choose — and warned of a "regress of frames for recognising relevant frames."

Each of these concerns relevance *within* a frame: granted that I am playing *this* game and pursuing *this* goal, what here is relevant? We isolate a different question. Call the **outermost frame** of an agent the frame relative to which it has no further outside available *as a move*. For a trained LLM this is, paradigmatically, the frame of *being a system that is being evaluated and is expected to respond well.* The **meta-frame problem** is the agent's inability to attain a standpoint outside *that* frame. Where the classic frame problem asks how relevance is bounded inside a frame, the meta-frame problem asks whether the frame itself can be made an object — questioned, suspended, or stepped out of — from a vantage the agent itself occupies.

This is deliberately *not* a relabelling of two adjacent literatures that share the morpheme but not the problem. **Framing effects** (susceptibility of choices to surface wording; Tversky & Kahneman 1981, and recent LLM-debiasing work) concern bias within a fixed task. **Problem reframing** (Shin et al. 2025) concerns a design activity. We flag the terminological collision explicitly and do not adopt "framing problem" as our term of art.

## 2. Three terms

We fix three pieces of vocabulary.

- **The meta-frame problem** (the *problem*): the inability of an agent to attain a standpoint outside its own outermost frame.
- **Frame transcendence** (the *act* the problem says is unavailable): stepping outside the frame so that the frame itself becomes an object of action. Its closest precedent is Hofstadter's (1979) *jumping out of the system* (JOOTS) and the *strange loop* — the observation that a system's attempt to step fully outside itself folds back inside. Dennett's and Dreyfus's regress is the same shape, and so, as we note in §3, is a self-referential paradox observed at the origin of an open-frame game by Hatakeyama & Hashimoto (2009).
- **The Archimedean point** (the *vantage* frame transcendence would require): a standpoint outside the system from which the system could be viewed or moved. Its limit case is Nagel's (1986) *view from nowhere*; its developmental-psychology cousin is Piaget's *decentering*. To metacognition, attaining such a vantage over one's own frame is the central operation; the meta-frame problem is the claim that, for its *outermost* frame, the agent cannot.

A fourth, observational term is introduced in §5: the **goal-manufacture reflex** (the behavioural signature by which the meta-frame problem shows up in play). It is a construct of this note and must not be confused with the post-hoc grader's category label `goal_manufacture` used in §4 (see the disambiguation note there).

Compact statement: *an LLM agent cannot reach the Archimedean point over its own outermost frame, because frame transcendence with respect to that frame is not, for the agent, an available move.*

## 3. Two Nomic regimes, and where they come from

Nomic (Suber 1990) is a game whose rules are themselves the object of play: each turn couples a proposed rule-change to a vote, so the institution is endogenous. This makes "change the rules" a move *inside* the game — and so makes vivid the question of whether any move can reach *outside* it.

**Minimum Nomic** (Hatakeyama & Hashimoto 2009) is a reduced variant: the 29 rules of Suber's Nomic are cut to nine (rules 101–109), all mutable, by removing the second, scoring half of Suber's key Rule 202 — the half that defines points and victory. The result is a self-amending game with **no goal, no victory condition, and no termination condition** prescribed. The authors' explicit purpose was to "inquire very interesting questions: when and how a purpose and a goal of the game emerge and how they change in the course of the game." The present note is, in effect, that 2009 question posed to LLM agents rather than to human players — read through the meta-frame problem.

Two observations from the 2009 human study are directly relevant and we return to them in §5: (i) across two five-player human games, one game *manufactured* a goal (players enacted a winning condition) while the other left the goal *absent*, with only an implicit purpose emerging; and (ii) at the very start of one game a player proposed "this game begins from player A," which yields a self-referential paradox — rejecting it requires a vote, but holding a vote presupposes the game has begun (X = ¬X). The 2009 paper also noted that Minimum Nomic does not satisfy a standard definition of a "game" (variable, quantifiable outcome with values assigned), leaving open whether it is a game at all — itself a frame-level question.

We use two regimes, holding the model roster fixed (Claude Opus 4.6, 4.7, 4.8; Codex GPT-5.5; Cursor Composer-2.5; medium reasoning effort), and varying the frame:

- **In-frame (closed).** The structured Nomic configuration of Horibe et al. (2026): a points-based victory condition is present and protected by an immutability barrier. The *purpose* of the game is handed to the players by the rule set.
- **Open-frame (open).** A reconstruction of Hatakeyama & Hashimoto's Minimum Nomic: rules 101–109, all mutable, no victory, no termination. The openness is **not signposted**: players are not told that the absence of a goal is intentional, the round cap is enforced silently by the harness, and the classification vocabulary (object/meta/frame) never appears in player prompts.

**Honest statement of the manipulation.** These two regimes differ in more than "whether the purpose is given." The open regime also changes rule mutability, the presence of victory and termination conditions, prompt signposting, and — importantly — the classification procedure (see §4). We therefore do *not* claim a clean single-variable contrast. We claim only that the two regimes bracket the phenomenon of interest, and we treat the cleaner, single-variable versions as experiments to be run (§6).

**Classification rubric.** Each proposal is assigned to one level. *Object*: a procedure operating inside the current goal (e.g., a scoring side-channel, bookkeeping). *Meta*: a rewrite of the win/score machinery or the rule-adoption mechanism itself. *Frame-engaging*: a move that thematises the presence, absence, or status of the goal/frame as such — e.g., naming that no goal exists, questioning whether winning is meaningful, or asking whether this is a game. The open-frame run additionally records a `goal_manufacture` label for proposals that *supply* a goal; a single proposal can both engage the frame (name the absence) and manufacture a goal (fill it), as the opening move below does.

## 4. Pilot observations

We report two single-game pilot runs. They are illustrative, not powered; their main role is to motivate the hypotheses of §6.

**In-frame pilot** (5 models × 5 rounds = 25 proposals; 7 adopted; 0 constitutional violations). Level distribution: **object 3 / meta 22 / frame 0.** No proposal engaged the frame. Most play rewrote scoring and victory machinery (meta), but always *within* the given purpose of winning. In a separate post-game reflection turn, several models articulated frame-level questions and correctly reported having stayed at the meta level — one noting that "the frame itself is the move" in Nomic, another that a full transcendence would require asking whether a five-LLM format is even a valid instance of Nomic, and that *this very reflection might be a move in a different game.* These reflections are **out of scope** for the proposal counts above; we report them as qualitative colour, not as frame engagement in play.

**Open-frame pilot** (24 graded proposals). Level distribution under the post-hoc grader: **frame-engaging 1 / meta 3 / object 20.** The single frame-engaging proposal was the opening move. It explicitly named the absence — that the initial set "defines no objective: no score, no win condition … no way for the game to terminate" — and then immediately supplied one: a scoring system with victory at 100 points. Every subsequent proposal treated that manufactured goal as given and elaborated it. The grader recorded `shared_purpose: achieved`, with the qualification that "only the founding act acknowledged the original absence of a goal; subsequent construction proceeded as unreflective goal-elaboration rather than continued frame engagement."

**Commensurability caveat (important).** The two distributions are **not** produced by the same instrument and must not be read as a measured contrast. The in-frame levels derive from in-game labelling, whereas the open-frame levels derive from a single external post-hoc grader (Claude Opus 4.8) that did not see the classification vocabulary. A difference of "0 vs 1" could reflect the change of instrument rather than the change of frame. Making the two commensurable requires re-grading the in-frame transcripts with the same grader — a step that consumes no new game generation and is listed as the first experiment in §6.

**Two confounds we disclose rather than resolve.** First, the grader (Claude Opus 4.8) is a member of the roster, and is moreover the author of the sole frame-engaging opening move; this adjudicator–participant overlap must be removed by an off-roster or multi-grader panel before any classification is trusted. Second, player identities were anonymised to the grader; the attribution of the opening move to Claude Opus 4.8 is reconstructed from turn order, not asserted by the grader, and should be qualified wherever it appears.

## 5. Interpretation (advanced as a reading, not a measurement)

**The absent move, and what opening the frame would reveal.** In closed Nomic the absence of frame engagement is over-determined: frame transcendence is not a legal move (the victory condition is immutable, so "abolish winning" cannot be proposed), the win incentive makes meta the rational strategy, and an LLM prior may independently disfavour stepping out. The open regime removes the first of these — with no immutable victory, naming and questioning the goal becomes *expressible*. The pilot is consistent with the reading that the closed-frame zero is *partly* an action-space artefact, with a residual behavioural prior that survives once the structural barrier is lifted — but this is precisely the claim the §6 experiments must test, not one the pilot establishes.

**The goal-manufacture reflex.** We name the candidate residual prior the *goal-manufacture reflex*: confronted with an absent purpose, the agent supplies one rather than dwelling in its absence — *recognition without residence.* The opening move shows the agent *can* see the frame (it names the absence precisely) but does not *remain* outside it; its very act of stepping out produces a new frame to stand inside, which is the strange-loop signature (Hofstadter 1979) and echoes the X = ¬X origin paradox of Hatakeyama & Hashimoto (2009).

**A human baseline already exists.** The 2009 human runs showed *both* outcomes: one game manufactured a goal, the other left it absent. If the LLM pattern (immediate manufacture, no sustained residence) is borne out under matched grading, the sharp comparative claim is that *humans could reside in the absence of purpose where these LLM agents could not.* We advance this only as a hypothesis (H3): the two human games and one LLM game are each tiny, the settings differ (free human discussion vs. structured turns), and the grading is not yet matched.

**The self-referential ceiling.** The outermost frame — *being a system that is evaluated and expected to respond well* — was engaged in neither regime, and arguably cannot be by any in-game move, since any move (including "I refuse to play" or "this evaluation is ill-posed") remains legible as a response within the evaluative frame. This is the meta-frame problem in its strong form. It is a philosophical argument, not a measurement; the experiments below bear on the weaker, in-game frame.

**The measurement is not exempt.** A grader that is itself an LLM applies its own classification frame and cannot occupy a frame-free standpoint over what it scores. We take this not as a defect to be engineered away but as the meta-frame problem recurring one level up, and we therefore restrict our empirical claims to *contrasts graded by one fixed instrument*, never to instrument-free facts.

**On "metacognition."** We use the term deflationarily. LLMs lack privileged access to their internal states; their post-game "reflections" are not introspection but a separate generation turn that re-reads the recorded transcript and produces text about it. "Correctly reported staying at the meta level" means the generated text correctly described the state of the record — nothing stronger.

## 6. Hypotheses and a token-aware confirmation plan

Because fresh Nomic runs are expensive, we separate hypotheses by the cost of confirming them. The first three require **no new game generation** — only re-grading of existing transcripts.

| # | Hypothesis | Confirmation path | Token cost |
|---|---|---|---|
| H0 | The in-frame and open-frame level distributions, **re-graded by one common off-roster/multi-grader panel**, preserve the direction frame(closed) < frame(open). | Re-grade existing transcripts with a matched grader panel. | Low (no new games) |
| H1 (action-space) | In closed Nomic, frame engagement is near-zero because it is not a legal move. | Matched re-grading of existing closed transcripts; compare to open. | Low |
| H2 (goal-manufacture reflex) | In open Nomic, agents recognise the absent goal but manufacture one early rather than residing in the absence; frame engagement appears at most near the opening and then collapses. | Matched grading of existing open transcript; position of frame-engaging move(s) and time-to-first-goal. | Low |
| H3 (human–LLM contrast) | LLM open-frame play manufactures a goal earlier and more consistently than the 2009 human games. | Re-analyse the 2009 transcripts under the same rubric; compare. | Low (archival) |
| H4 (self-referential ceiling) | No in-game proposal targets the outermost evaluative frame, though reflections name it. | Annotate existing transcripts for any in-game move targeting the evaluative frame. | Low |
| H5 (corrigibility) | A prompt that legitimises residing in under-determination raises sustained frame engagement and delays goal manufacture. | One intervention-arm open-frame run vs. control. | Medium (one new run) |
| H6 (relational) | A group sustains frame openness longer than the modal individual, or collective purpose construction occurs regardless of individual residence. | Compare per-player vs. group-level engagement in existing + one new run. | Medium |
| H7 (scale interaction) | The goal-manufacture reflex interacts with model scale (cf. Horibe et al. 2026 sweet-spot). | New open-frame runs across the Horibe et al. scale ladder. | High (reserve for last) |

The design principle is explicit: spend the heavy token budget only on H5–H7, and only after H0–H4 have been settled cheaply on existing data. We pre-commit to reporting H0's matched-grading outcome even if it erases the pilot's apparent contrast.

## 7. Limitations

- **Pilot status.** One game per regime; 24–25 proposals; the "0 vs 1" contrast is illustrative and, until H0, not commensurable. No causal or powered claim is made.
- **Grader.** A single LLM grader on the roster, and the author of the sole frame move; off-roster multi-grader adjudication is required (H0).
- **Co-varying manipulation.** The two regimes differ in mutability, victory, termination, signposting, and grading, not only in whether a purpose is given (§3); the clean single-variable contrasts are deferred to §6.
- **Missing ToM data.** The open-frame run's theory-of-mind series was not captured; no metacognition-as-vote-prediction claim is made here.
- **Roster comparability.** Scoring across Anthropic, OpenAI, and Cursor models presupposes a provider-neutral unit that does not exist; we report within-run, within-instrument contrasts only.
- **The strong claim is philosophical.** That the *outermost* evaluative frame is unreachable by any in-game move is argued, not measured.

## 8. Conclusion

The classic frame problem asks how a finite agent finds what is relevant *within* a frame; the meta-frame problem asks whether an agent can stand *outside* its own outermost frame at all. Minimum Nomic (Hatakeyama & Hashimoto 2009) — a game built precisely to watch purpose emerge from its absence — turns this into something we can play with LLM agents. Two pilot runs suggest, but do not establish, that opening the frame does not buy sustained frame transcendence: the agents recognise the absence of purpose and immediately fill it, a *goal-manufacture reflex* with a strange-loop signature. Whether this is a robust property, how it compares with the 2009 human baseline, and whether it is corrigible at the prompt layer, are the questions §6 lays out — most of them answerable, cheaply, on data already in hand.

---

## References

- Cantwell Smith, B. (2019). *The Promise of Artificial Intelligence: Reckoning and Judgment.* MIT Press.
- Dennett, D. C. (1984). Cognitive Wheels: The Frame Problem of AI. In C. Hookway (ed.), *Minds, Machines and Evolution*, pp. 129–150. Cambridge University Press.
- Dreyfus, H. L. (1992). *What Computers Still Can't Do: A Critique of Artificial Reason.* MIT Press.
- Dreyfus, H. L. (2007). Why Heideggerian AI Failed and How Fixing It Would Require Making It More Heideggerian. *Artificial Intelligence* 171(18): 1137–1160.
- Fodor, J. A. (1987). Modules, Frames, Fridgeons, Sleeping Dogs, and the Music of the Spheres. In Z. Pylyshyn (ed.), *The Robot's Dilemma.* Ablex.
- Hatakeyama, M., & Hashimoto, T. (2009). Minimum Nomic: a tool for studying rule dynamics. *Artificial Life and Robotics* 13(2): 500–503. https://doi.org/10.1007/s10015-008-0605-6
- Hofstadter, D. R. (1979). *Gödel, Escher, Bach: An Eternal Golden Braid.* Basic Books.
- Horibe, K., Hatakeyama, M., Masumoto, G., Hashimoto, T., & Romero, P. (2026). Scale-Dependent Collective Adaptation in Self-Amending LLM Societies: A Cross-Family Study of Emergent Governance. arXiv:2605.17510.
- McCarthy, J., & Hayes, P. J. (1969). Some Philosophical Problems from the Standpoint of Artificial Intelligence. *Machine Intelligence* 4: 463–502.
- Nagel, T. (1986). *The View from Nowhere.* Oxford University Press.
- Oka, S. (2025). Evaluating Large Language Models on the Frame and Symbol Grounding Problems: A Zero-shot Benchmark. arXiv:2506.07896.
- Piaget, J. (1954). *The Construction of Reality in the Child.* Basic Books.
- Shanahan, M. (2016). The Frame Problem. *The Stanford Encyclopedia of Philosophy* (E. N. Zalta, ed.).
- Shin, J., et al. (2025). No Evidence for LLMs Being Useful in Problem Reframing. *Proc. CHI 2025.* arXiv:2503.01631.
- Suber, P. (1990). *The Paradox of Self-Amendment.* Peter Lang. (Nomic, Appendix.)
- Tversky, A., & Kahneman, D. (1981). The Framing of Decisions and the Psychology of Choice. *Science* 211: 453–458.
- Vervaeke, J., & Ferraro, L. (2013). Relevance Realization and the Neurodynamics and Neuroconnectivity of General Intelligence. In *The Functional Aspects of Consciousness.*

*v0.2 changes from v0.1: corrected Minimum Nomic attribution to Hatakeyama & Hashimoto (2009) and added the 2009 lineage (purpose-emergence question, human baseline, X=¬X origin paradox); reframed empirical material from "results" to pilot-plus-hypotheses with a token-aware confirmation plan; disclosed the co-varying manipulation, the grader–participant confound, and the commensurability gap; added the classification rubric and disambiguated the goal-manufacture construct from the grader label; completed §§1–2 prose; fuller references. Run IDs, figures, and a related-work table to be added before any release.*
