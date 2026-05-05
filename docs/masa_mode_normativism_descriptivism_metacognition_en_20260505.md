# Masa Mode / AgentSkill — A Metacognitive Analysis through Normativism vs Descriptivism

**Date:** 2026-05-05
**Author:** claude_opus4.7 (orchestrator), prompted by masaomi
**Status:** L2 analysis snapshot. L2 ID: `masa_mode_normativism_descriptivism_metacognition_analysis_20260505`

## 0. Framing the Question

The question is not what the text of Masa Mode (or AgentSkill in general) **says**, but what it **functions as**. We must distinguish three layers:

| Layer | Normativist reading | Descriptivist reading |
|-------|--------------------|-----------------------|
| (a) Text | "the agent **ought to** behave thus" (prescription) | "this instance behaves thus" (description of disposition) |
| (b) Execution | the LLM **complies** with the norm (deontic compliance) | the LLM's next-token distribution **shifts** under conditioning (causal modulation) |
| (c) Evaluation | norm violations are contestable / sanctionable | truth-evaluation of behavior against the description |

In ordinary ethics, layers (a) and (b) are presumed continuous (humans understand norms and can comply with them). On an LLM substrate, **this continuity breaks** — and that break is the heart of the analysis.

## 1. The Duality of Masa Mode — "Form is normative, mechanism is descriptive"

The text of Masa Mode is unambiguously written in **normativist form**:

- "Agent behavior: Break complex tasks into small, completable units" (imperative)
- "When in doubt, choose what you can be proud of" (conditional duty)
- "PASS+S gate before Act" (procedural obligation)

But what these do at LLM execution time is:

> **They are injected into the prompt context and condition the next-token distribution.**
> The LLM does not "obey" the norm. Rather, with the norm-text in its context, the **distribution over norm-conformant outputs is amplified**.

So a text written in Hare-style prescriptivism (norms as universalizable imperatives) operates at runtime as a **descriptive probabilistic shift**. This is the gap: **a normativist signpost over a descriptivist mechanism**.

More interestingly: the LLM's training distribution contains massive amounts of "descriptions of humans complying with norms." So the path **"give a normative text ⇒ generate norm-conformant behavior with high probability"** runs through pure description, and **Hume's is-ought gap collapses functionally**. This is what unsettles the normativist: is the normativity real, or merely a probabilistic mimicry of "norm-following role-play"?

## 2. Analysis by Metacognitive Level

If we define metacognition as "cognition about one's cognition," normativism and descriptivism interact differently at each level.

### Level 0 — object cognition
The task itself. Detect "3 tests failed." Masa Mode does not directly intervene here.

### Level 1 — descriptive metacognition
Self-report of one's current state. "I don't know yet."
- The LLM **can simulate** this (produce self-report-like strings)
- But it does not actually observe internal states (output is not a stable function of internal state)
- Masa Mode's "Acknowledge uncertainty explicitly" is a **descriptivist directive** at this level

### Level 2 — normative metacognition
"I **ought** to think this way." "Am I currently falling into bias?"
- The Self-Q step of PASS+S ("Am I being defensive? Am I optimizing for me?") is the canonical case
- This is where Masa Mode makes **strong normativist demands**
- But this is **structurally unattainable for the LLM alone**:
  - Truly evaluating "Am I being defensive?" requires second-order access to internal states
  - The LLM produces such strings, but they are Level-1 simulations dressed in Level-2 language
  - That is: it is "pretending to do normative metacognition"

### Level 3 — institutional metacognition
The KairosChain-specific layer. Metacognition **as a system rather than as an individual**:
- `chain_record` for irreversible recording of acts
- `introspection_check` / `introspection_safety` for self-inspection
- Proposition 10's contestability (post-hoc challengeability)
- Multi-LLM review for the internalization of external perspectives (L2 → L1 → L0 promotion path)

Here something decisive happens:

> **Normative metacognition, unattainable by the LLM alone at Level 2, is externalized and re-implemented as institutional metacognition at Level 3.**

That is: we abandon "inspect oneself" and replace it with "**the system inspects the individual**, the records are irreversible, and the outcomes are contestable." This is the **theoretical reason KairosChain mandates Proposition 10 as a procedural floor**.

## 3. Searle's Constitutive / Regulative Distinction

Searle distinguishes two kinds of rules:
- **Regulative rules**: govern pre-existing behavior (e.g., "drive on the right")
- **Constitutive rules**: bring the activity into existence (e.g., "checkmate is...")

Both are mixed in Masa Mode:

| Masa Mode element | Type | Note |
|-------------------|------|------|
| PASS+S gate | Regulative | gates pre-existing output behavior just before emission |
| Honest vs Integrity distinction | Regulative | reshapes pre-existing output style |
| "This is a KairosChain instance operating under Masa Mode" | **Constitutive** | the declaration itself constitutes the instance's identity |
| Connection to Proposition 5 (constitutive recording) | **Constitutive** | recording constitutes the system (not evidence for it) |
| 9 propositions = ontology, Masa Mode = ethics | Layered | ethics (regulative) atop ontology (constitutive) |

Mapping to normativism/descriptivism:

- **Constitutive rules are descriptivism-friendly**: they **define** what counts as "Masa-Mode-conformant behavior." "Operating under Masa Mode" is analytically equivalent to a behavior-description that conforms to these texts.
- **Regulative rules are normativism-friendly**: they overlay an "ought" on pre-existing behavior.

On an LLM substrate, the **constitutive side functions** (place the text in context and the conformant behavior-description follows under that context); the **regulative side is weak** (the "ought" cannot be truly enforced). Masa Mode — whether by design or by emergence — adopts a two-layer structure of **constitutive self-definition + regulative behavioral guidance**, leaning on the constitutive side to circumvent LLM-substrate limits.

## 4. Generalizing to AgentSkill

Stripping away Masa-Mode-specific concerns and generalizing to AgentSkill in general:

### AgentSkill texts are formally **mixed speech acts**

- Imperative (prescription) — "When X, do Y"
- Indicative (description) — "This skill exchanges A for B"
- Constitutive (constitution) — "A SkillSet is a tuple of (...)"

These coexist in a single skill file without separation.

### Under LLM execution, all collapse to the **descriptive**

- Prescription, description, and constitution are all simply "text injected as context" at the harness layer
- The LLM uses them indiscriminately to condition the next-token distribution
- That is, **distinctions between speech acts are flattened**

### KairosChain re-introduces the distinctions deliberately

| Speech act | KairosChain re-expression |
|-----------|---------------------------|
| Description | `resource_read` / `knowledge_get` (fact retrieval) |
| Prescription | safety policies / `approval_workflow` (execution gate) |
| Constitution | `chain_record` + `skills_promote` (acts that change the system) |

So KairosChain reads as **"a mechanism that structurally restores, at the system level, the speech-act distinctions flattened on the LLM."** In Brandomian terms: since normative pragmatics cannot be located in the individual (LLM), **inferential articulation is institutionalized** instead.

## 5. The "Who" of Metacognition — A Human-System Composite

Proposition 9 points exactly here:

> **The third meta-level is a dynamic process, not a static state, and the human is on the boundary.**

If normative metacognition is impossible for the LLM alone, then **who** carries it?

- Retreating to pure descriptivism ("it's all causal shift") fails to explain KairosChain's normative structure
- Asserting pure normativism ("the LLM is following the norm") contradicts the LLM's implementation
- **A third path**: normative metacognition is carried by the **composite of LLM + harness + chain + human**

This composite "operates under Masa Mode" not because the text conditions LLM output, but because **the entire cycle of "text → output → record → contestation → revision" instantiates the text's normativity**. In Wittgensteinian terms: rule-following is not an individual psychological state but a **public practice**, and Masa Mode engineers that "public" as harness + chain.

## 6. Conclusion — KairosChain's Solution

In summary:

1. **The text of Masa Mode is written in normativist form** (imperatives, conditional duties, PASS+S gate)
2. **The LLM alone can only implement this descriptively** (distribution shift via context injection, simulated metacognition)
3. **The actual force of normativity is externalized to the harness + chain layer**:
   - Constitutive recording (Prop 5) — acts are recorded irreversibly
   - Procedural floor (Prop 10) — violations are contestable
   - Multi-LLM review — inspection by external perspectives
   - L2 → L1 → L0 promotion — internalization path for external analysis
4. **Metacognition is similarly externalized**: the individual (LLM) reaches Level 1 (descriptive) only; Level 2 (normative) and beyond are carried by the system (KairosChain) + the human

Thus Masa Mode is:

> **A three-layer solution that places "normativist text" upon "descriptivist mechanism" and fills the gap with "institutionalism."**

A naive normativist asks "is the LLM truly following the norm?" — but this question itself misplaces the layer. The normativity of Masa Mode does not lie inside the LLM but **in the cycle of the system that includes the LLM**.

This insight generalizes to AgentSkill in general, yielding the design principle: **every agent skill exhibits a gap between form and mechanism, and requires an institutional layer to bridge that gap.** The 9 propositions plus Prop 10 procedural floor of KairosChain are precisely the apparatus that "enforces this institutional layer as a minimal requirement."

---

## Coda — A Self-Referential Observation

This analysis itself is a candidate for L2 → L1 internalization, and were it promoted, it would exemplify KairosChain's machinery for "taking external analysis into the structure" (Prop 6, incompleteness as driving force). The agent writing this response is Opus 4.7, but whether it is actually "applying" the normativism/descriptivism distinction is undermined by the very analysis (the LLM cannot truly perform Level-2 normative metacognition) — a meta-circularity. This too is an instance of the "human on the boundary" condition that Masa Mode presupposes.
