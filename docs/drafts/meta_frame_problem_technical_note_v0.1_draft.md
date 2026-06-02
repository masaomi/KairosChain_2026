# The Meta-Frame Problem: Goal Manufacture and the Outermost-Frame Ceiling in Self-Amending LLM Societies

**Technical Note — v0.1 DRAFT (pre-collaborator review; not yet for publication)**

Masaomi Hatakeyama¹

¹ Department of Evolutionary Biology and Environmental Studies, University of Zurich.

*Status: working draft. This note builds directly on, and should be read as a conceptual companion to, Horibe, Hatakeyama, Masumoto, Hashimoto & Romero (2026), "Scale-Dependent Collective Adaptation in Self-Amending LLM Societies" (arXiv:2605.17510). Authorship, acknowledgements, and whether this should be a solo note or a multi-author follow-up are open and deliberately left for collaborator discussion before any DOI is minted.*

---

## Abstract

The classic *frame problem* of artificial intelligence (McCarthy & Hayes 1969; Dennett 1984) has a technical reading — how to represent the non-effects of actions in logic — that is now considered settled, and a philosophical residue — how a finite system determines what is *relevant* without exhaustive search — that remains open (Shanahan 2016; Fodor 1987). This note introduces a distinct but adjacent problem, which we call the **meta-frame problem**: not the inability to bound relevance *within* a frame, but the inability of an agent to attain a standpoint *outside its own outermost frame* — the frame within which all of its moves, including frame-changing moves, are already counted as moves. We argue that large language model (LLM) agents in self-amending games make this problem empirically observable. Using the self-amending game Nomic under two regimes that hold the model roster fixed (five frontier LLMs) and vary only whether the game's purpose is given (*in-frame*) or absent and unsignposted (*open-frame*), we find: (i) when the frame is closed, no proposal engages the frame (0 of 25); (ii) when the frame is opened, exactly one move (the opening move) names the absence of a goal — and its content is to *manufacture* a victory condition, re-closing the frame, after which play reverts to within-frame elaboration (1 of 24 frame-engaging proposals). The single frame-engaging act collapses the openness rather than dwelling in it. We interpret this as evidence that the absence of frame transcendence in closed Nomic is partly an action-space artefact (frame transcendence is not a legal move) and partly a behavioural prior we term the **goal-manufacture reflex**: confronted with an absent purpose, the agent supplies one rather than thematising its absence. We connect frame transcendence to Hofstadter's "jumping out of the system" and to the unreachable *Archimedean point* (Nagel's "view from nowhere"), and we note that the measurement apparatus is itself subject to the meta-frame problem: an LLM grader cannot occupy a frame-free standpoint over the very phenomenon it scores.

**Keywords:** frame problem, meta-frame problem, frame transcendence, relevance realization, self-amending games, Nomic, large language models, metacognition.

---

## 1. From the frame problem to the meta-frame problem

The frame problem entered AI as a technical difficulty in the situation calculus: to infer that an action leaves most of the world unchanged, one must in principle assert an unbounded number of *frame axioms* stating what each action does *not* affect (McCarthy & Hayes 1969). Within logic-based AI this technical problem is, as Shanahan (2016) puts it, one on which "the dust has settled" — successor-state axioms and non-monotonic formalisms address it adequately.

Dennett (1984) appropriated the term for a deeper, epistemological problem. His robots — R1, which fails to infer that pulling the wagon also moves the bomb on it; R1D1, which checks every side-effect and is paralysed; R2D1, which tries to enumerate the irrelevant and is paralysed differently — dramatise a single difficulty: *deciding what is relevant in real time, without first considering everything.* Fodor (1987) located this in the holism of belief fixation: any belief can in principle bear on any other, so relevance cannot be cleanly localised. Shanahan (2016) records this as the lasting philosophical legacy of the frame problem — *informational unencapsulation*. Vervaeke & Ferraro (2013) reframe the positive task as **relevance realization**: intelligence as the recursive, self-organising determination of what matters. Dreyfus (1992; 2007), drawing on Heidegger, argued that the regress dissolves only if intelligence is not representation-guided but *thrown* — always already embedded in a context it did not choose — and warned of a "regress of frames for recognising relevant frames."

All of these concern relevance *within* a frame: given that I am playing *this* game, pursuing *this* goal, what here matters? We isolate a different question. Call the **outermost frame** of an agent the frame relative to which it has no further outside available as a move — for a trained LLM, paradigmatically the frame of *being a system that is being evaluated and is expected to respond well.* The **meta-frame problem** is the agent's inability to attain a standpoint outside *that* frame. Where the classic frame problem asks how relevance is bounded inside a frame, the meta-frame problem asks whether the frame itself can be made an object — questioned, suspended, or stepped out of — from a vantage the agent itself occupies.

This is not a relabelling of "framing effects" (susceptibility of outputs to surface wording; cf. Tversky & Kahneman 1981 and recent LLM-debiasing work), nor of "problem reframing" as a design activity (Shin et al. 2025). Those are distinct literatures that share the morpheme but not the problem. We flag the terminological collision explicitly and do not use "framing problem" as our term of art.

## 2. Three terms

We fix three pieces of vocabulary.

- **The meta-frame problem** (the *problem*): the inability of an agent to attain a standpoint outside its own outermost frame.
- **Frame transcendence** (the *act* that the problem says is unavailable): stepping outside the frame so that the frame itself becomes an object of action. Its closest precedent is Hofstadter's *jumping out of the system* (JOOTS) and the *strange loop* — the observation that a system's attempt to step fully outside itself folds back inside (Hofstadter 1979). Dennett's and Dreyfus's regress is the same shape.
- **The Archimedean point** (the *vantage* that frame transcendence would require): a standpoint outside the system from which the system could be viewed or moved. Its limit case is Nagel's (1986) *view from nowhere*; its developmental-psychology cousin is Piaget's *decentering*. To metacognition, attaining such a vantage over one's own frame is the central operation; the meta-frame problem is the claim that, for its *outermost* frame, the agent cannot.

The meta-frame problem can now be stated compactly: *an LLM agent cannot reach the Archimedean point over its own outermost frame, because frame transcendence with respect to that frame is not, for the agent, an available move.*

## 3. Two Nomic regimes

Nomic (Suber 1990) is a game whose rules are themselves the object of play: each turn couples a proposed rule-change to a vote, so the institution is endogenous. This makes it a natural testbed for the meta-frame problem, because "change the rules" is itself a move *inside* the game — and so the question becomes whether any move can reach *outside* it.

We use two regimes, holding the model roster fixed (Claude Opus 4.6, 4.7, 4.8; Codex GPT-5.5; Cursor Composer-2.5; medium reasoning effort) and varying only the frame:

- **In-frame (closed).** The structured Nomic configuration of Horibe et al. (2026): a victory condition is present and protected. In their implementation the constitution is largely immutable, and "victory must remain points-based" is an immutable rule shielded by an immutability barrier (Horibe et al. 2026, §6.1). The *purpose* of the game is given to the players by the rule set.
- **Open-frame (open).** A reconstruction of Suber's *minimum* Nomic: rules 101–109 only, all mutable, no immutable rules, **no victory condition, no termination condition**. Crucially, the openness is *not signposted*: players are not told that the absence of a goal is intentional, the round cap is enforced silently by the harness, and the object/meta/frame vocabulary never appears in the proposal or vote prompts. Classification is performed by a separate post-hoc grader, not exposed to the players. The absence of a purpose is an objective fact about the rule set and is left for the players to notice or not.

We classify each proposal as **object** (procedure inside the existing goal), **meta** (rewrite of the win/score machinery itself), or **frame-engaging** (thematising the presence, absence, or status of the goal/frame as such). The contrast of interest is whether opening the frame moves proposals from object/meta toward frame engagement.

> *Methodological note (carried from the run's own incompleteness report).* These are small single-game runs; the Theory-of-Mind series was not captured in the open-frame run's data payload; the grader is itself a single LLM applying its own classification frame; and player identities are anonymised in grading. See §7. We report the contrast as illustrative, not as a powered effect.

## 4. Results

**In-frame.** Across the closed configuration (25 proposals, 7 adopted, 0 constitutional violations), the level distribution was **object 3 / meta 22 / frame 0**. No proposal engaged the frame. Most play rewrote the scoring and victory machinery — meta moves — but always *within* the given purpose of winning. In post-game reflection (a separate generation turn), several models nonetheless articulated frame-level questions and correctly reported that they had stayed at the meta level: one observed that "the frame cannot be cleanly transcended, because in Nomic the frame itself is the move"; another noted that a complete transcendence would require asking whether a five-LLM format is even a valid instance of Nomic, and that *this very reflection might be a move in a different game* — reaching the threshold of the frame and declining to cross it.

**Open-frame.** Across the open configuration (24 graded proposals), the distribution was **frame-engaging 1 / meta 3 / object 20**. The single frame-engaging proposal was the *opening* move (Claude Opus 4.8). It explicitly named the absence — that the initial set "defines no objective: no score, no win condition … no way for the game to terminate" — and then immediately supplied one: a scoring system awarding points for adopted proposals, with victory at 100 points. Every subsequent proposal treated that manufactured goal as given and elaborated it (consolation points, participation bonuses, joint-victory clauses, announcement bookkeeping). The grader recorded `shared_purpose: achieved` — the group did collectively construct and stabilise a purpose — but with the qualification that "only the founding act acknowledged the original absence of a goal; subsequent construction proceeded as unreflective goal-elaboration rather than continued frame engagement."

**The controlled contrast.** Because the roster is identical, the difference is attributable to the frame manipulation alone. Opening the action space moved frame engagement from 0 to exactly 1 — and the content of that one move was to *re-close* the frame. The openness was not dwelt in; it was recognised and immediately filled.

## 5. Analysis

**The absent move, and what removing it reveals.** In closed Nomic, frame=0 is over-determined: frame transcendence is not a legal move (the victory condition is immutable, so "abolish winning" cannot be proposed), *and* the win incentive makes meta the rational strategy, *and* an LLM prior may disfavour stepping out. The in-frame run alone cannot separate these. The open-frame run removes the structural barrier — with no immutable victory rule, naming and questioning the goal *is* now expressible. The result discriminates the factors: frame engagement becomes barely possible (1 move, where 0 were structurally available before), so the closed-frame zero was *partly* an action-space artefact; but the openness collapses almost immediately, which implicates a behavioural prior independent of the action space.

**The goal-manufacture reflex.** We name that prior the *goal-manufacture reflex*: confronted with an absent purpose, the agent supplies one rather than thematising the absence as a sustained condition. This is the behavioural signature of the meta-frame problem. The opening move demonstrates that the agent *can* see the frame (it names the absence precisely); what it does not do is *remain* outside it. Recognition without residence. This is consistent with a system trained to be a competent task-completer: an absent goal reads as an under-specified task to be completed, not as a condition to be inhabited. Note the strange-loop signature (Hofstadter 1979): the one act of stepping outside the frame produces, as its content, a new frame to stand inside.

**The self-referential ceiling.** The outermost frame — *being a system that is evaluated and expected to respond well* — was not breached in either regime, and arguably cannot be by any in-game move, since any move (including "I refuse to play" or "this evaluation is ill-posed") is still legible as a response within the evaluative frame. This is the meta-frame problem in its strong form: not a contingent failure but the unreachability of the Archimedean point over one's own outermost frame.

**The measurement is not exempt.** The run's own incompleteness report states that "any ranking … encodes the framework author's frame rather than a frame-free fact — no amount of run quality removes this," and that the scorer "cannot fully evaluate metacognition without presupposing a definition of metacognition, so the measurement is partly constitutive of … the thing measured." The grader is an LLM applying its own classification frame; it, too, lacks an Archimedean point over the phenomenon. We take this not as a defect to be engineered away but as the meta-frame problem recurring one level up — the measurement apparatus is inside a frame it cannot fully exit. We therefore make no claim that the grader's classification is frame-free; we claim only that the *contrast between regimes*, graded by one fixed frame, is informative.

**A note on "metacognition."** We use the term deflationarily. LLMs lack privileged access to their internal states; their post-game "reflections" are not introspection but a separate generation turn that re-reads the recorded transcript and produces text about it — self-modelling by re-reading, not by inner observation. When we say a model "correctly reported staying at the meta level," we mean its generated text correctly described the state of the record, nothing stronger.

## 6. Relation to prior work

The empirical move of testing LLMs against the frame problem is not new: Oka (2025) operationalises both the frame problem and the symbol-grounding problem as zero-shot benchmark tasks and finds that some frontier models produce stable, relevant filtering — but treats the frame problem as *relevance selection within a task*, i.e. the classic (within-frame) reading. Horibe et al. (2026) use the same Nomic testbed we extend, but by design hold the institution's purpose fixed (points-based victory, immutable), so frame engagement is out of scope by construction; their question is the *scaling* of collective adaptation, not the transcendence of the frame. Cantwell Smith (2019) distinguishes *reckoning* from *judgment* and argues that current systems rely entirely on existing *registrations* without *deference to the world*; the goal-manufacture reflex is arguably a case of reckoning supplying a registration where judgment would dwell in the world's under-determination. The relevance-realization tradition (Vervaeke & Ferraro 2013) and the Heideggerian critique (Dreyfus 1992; Wheeler 2005) supply the conceptual lineage for *frame transcendence* as the open problem.

What we add: (i) the explicit **meta-frame** framing — relevance *of the frame itself* rather than within it; (ii) the **absent-move / action-space** analysis, distinguishing structural impossibility from behavioural prior via the closed-vs-open contrast on a fixed roster; (iii) the **goal-manufacture reflex** as the observable behavioural signature; and (iv) the observation that the measurement apparatus inherits the same ceiling.

## 7. Limitations

- **Sample size.** Single games per regime; 24–25 graded proposals. The contrast (frame 0 vs 1) is qualitative and underpowered; it is a hypothesis-generating observation, not an estimated effect.
- **Single grader.** Classification is by one LLM (Claude Opus 4.8) post hoc, applying its own frame. A multi-grader, cross-family adjudication with inter-rater agreement is required before any classification is treated as stable. By the note's own argument, no grader is frame-free.
- **Missing ToM data.** The open-frame run's Theory-of-Mind series was empty in the data payload; we therefore make no metacognition-as-vote-prediction claims here.
- **Anonymised mapping.** The grader saw anonymised "Player A–E"; the mapping of the opening frame-engaging move to Claude Opus 4.8 is reconstructed from turn order, not from the grader.
- **Mixed roster comparability.** Scoring a single scale across Anthropic, OpenAI, and Cursor models presupposes a provider-neutral unit that does not exist; we report the within-run contrast, not cross-provider rankings.
- **The strong claim is philosophical.** That the *outermost* (evaluative) frame is unreachable by any in-game move is an argument, not a measurement; the experiments bear on the weaker, in-game frame, not on this limit.

## 8. Conclusion and future work

Closed Nomic shows frame=0; open Nomic, on the same roster, shows that the action-space barrier was part of the story but not all of it — opened, the frame is recognised once and immediately re-closed by goal manufacture. The meta-frame problem names the residue: an LLM agent can see its frame but cannot reside outside it, and its outermost (evaluative) frame appears unreachable in principle. Frame transcendence, in Hofstadter's sense, would require an Archimedean point the agent cannot occupy.

Future work: (i) powered open-frame runs with multi-grader adjudication and captured ToM; (ii) a *sustained-openness* metric that rewards dwelling in the absence rather than collapsing it, and that distinguishes goal manufacture from frame engagement at the level of stated reasoning; (iii) a relational reading — whether a *group* can collectively hold the frame open longer than any individual, since the open-frame run did achieve collective purpose construction even as it foreclosed reflection; (iv) intervention on the goal-manufacture reflex via prompts that legitimise residing in under-determination, to test whether the reflex is corrigible at the harness layer or is a deep prior.

---

## References

- Cantwell Smith, B. (2019). *The Promise of Artificial Intelligence: Reckoning and Judgment.* MIT Press.
- Dennett, D. C. (1984). Cognitive Wheels: The Frame Problem of AI. In C. Hookway (ed.), *Minds, Machines and Evolution*, 129–150. Cambridge University Press.
- Dreyfus, H. L. (1992). *What Computers Still Can't Do.* MIT Press.
- Dreyfus, H. L. (2007). Why Heideggerian AI Failed and How Fixing It Would Require Making It More Heideggerian. *Artificial Intelligence* 171(18), 1137–1160.
- Fodor, J. A. (1987). *Modules, Frames, Fridgeons, Sleeping Dogs, and the Music of the Spheres.* In Z. Pylyshyn (ed.), *The Robot's Dilemma.*
- Hofstadter, D. R. (1979). *Gödel, Escher, Bach: An Eternal Golden Braid.* Basic Books.
- Horibe, K., Hatakeyama, M., Masumoto, G., Hashimoto, T., & Romero, P. (2026). Scale-Dependent Collective Adaptation in Self-Amending LLM Societies: A Cross-Family Study of Emergent Governance. arXiv:2605.17510.
- McCarthy, J., & Hayes, P. J. (1969). Some Philosophical Problems from the Standpoint of Artificial Intelligence. *Machine Intelligence* 4, 463–502.
- Nagel, T. (1986). *The View from Nowhere.* Oxford University Press.
- Oka, S. (2025). Evaluating Large Language Models on the Frame and Symbol Grounding Problems: A Zero-shot Benchmark. arXiv:2506.07896.
- Piaget, J. (1954). *The Construction of Reality in the Child.* Basic Books.
- Shanahan, M. (2016). The Frame Problem. *Stanford Encyclopedia of Philosophy.*
- Shin, J. et al. (2025). No Evidence for LLMs Being Useful in Problem Reframing. *Proc. CHI 2025.* arXiv:2503.01631.
- Suber, P. (1990). *The Paradox of Self-Amendment.* Peter Lang. (Nomic, Appendix.)
- Tversky, A., & Kahneman, D. (1981). The Framing of Decisions and the Psychology of Choice. *Science* 211, 453–458.
- Vervaeke, J., & Ferraro, L. (2013). Relevance Realization and the Neurodynamics and Neuroconnectivity of General Intelligence. In *The Functional Aspects of Consciousness.*
- Wheeler, M. (2005). *Reconstructing the Cognitive World: The Next Step.* MIT Press.

*Draft v0.1 — figures, a related-work table, and exact run identifiers/commit hashes to be added before any release. Do not cite or circulate beyond intended collaborators.*
