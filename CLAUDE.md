# KairosChain — Core Philosophy for Development

## Generative Principle: Structural Self-Referentiality

KairosChain's entire architecture flows from one principle:

> **Meta-level operations are expressed in the same structure as base-level operations.**

This is why Ruby (DSL/AST) was chosen. "Defining a Skill" and "defining the evolution rules for a Skill" use the same language, syntax, and runtime. This structural correspondence is the foundation of self-referentiality, and all other properties of KairosChain germinate from it. Self-referentiality is not a design choice but an existential condition: without definitional closure at L0, the system would be "a program following configuration" rather than "an entity that defines its own conditions of existence."

## Nine Propositions (Summary)

Organized in four thematic groups. Each proposition carries a provenance label [ML1/ML2/ML3] indicating which meta-level of analysis it originates from. This structure is provisional.

### A. Ontological Foundations

1. **[ML1+ML2] Self-referentiality as generative principle and existential condition** — Not just a generative seed but an existential condition: without definitional closure at L0, the system is "a program following configuration" not "an entity that defines its own conditions of existence." Intentionally asymmetric ("sufficient self-referentiality").

2. **[ML1] Partial autopoiesis** — Self-production loop closes at governance/capability-definition level; depends on external substrates (Ruby VM, filesystem) at execution level. The question is "at which abstraction level does the loop close?"

### B. Integrity

3. **[ML1+ML2] Dual guarantee and active maintenance** — Prevention (approval_workflow's 5-layer validation) + structural impossibility + immune-system-like active recognition and exclusion of inconsistency.

### C. Possibility and Time

4. **[ML1] Structure opens possibility space; design realizes it** — Self-referential structure automatically enables recursive extension. The *possibility* of expressing meta-capabilities as SkillSets is a structural consequence.

5. **[ML1+ML2] Constitutive recording and Kairotic temporality** — Recording is constitutive, not evidential. Time is Kairos (qualitative decisive moment), not Chronos. Each transformation irreversibly reconstitutes the system's being.

6. **[ML3] Incompleteness as driving force** — Complete self-description is Gödelian-impossible, but this incompleteness drives perpetual evolution. The L2→L1→L0 promotion path institutionalizes the internalization of external analysis.

### D. Cognition and Relations

7. **[ML2] Metacognitive self-referentiality and design-implementation closure** — Self-referentiality is structural; metacognition is cognitive. Both are core. Designing/describing the system becomes an operation within the system.

8. **[ML2] Co-dependent ontology** — Relations and individuals are co-dependently co-constituted (pratītyasamutpāda). Grounded in Nishida's basho, Huayan's shishi wu'ai, and Daoist wu-wei.

9. **[ML3] Metacognitive dynamic process and human-system composite** — The third meta-level is a dynamic process, not a static state. The human is on the boundary — cognitive acts constitute the system's boundary. Reached through structuring human-system metacognitive dialogue, not by excluding the human.

## Development Guidelines

When coding for KairosChain, always ask:

- **Is this change meta-level or base-level?** Be explicit about which layer boundary you are crossing. Never blur L0 (framework) changes with SkillSet (plugin) changes.
- **Does this preserve structural self-referentiality?** If adding a meta-capability, can it be expressed as a Skill/SkillSet rather than hard-coded infrastructure?
- **Does this introduce centralized control?** Prefer P2P-natural, locally-autonomous designs. No global orchestrators, no single sources of truth.
- **Can this be a new SkillSet instead of core bloat?** Keep the DNA (core) simple. New requirements should become new SkillSets where possible.
- **Is the change recorded?** L0 changes must be fully recorded on the blockchain. The system's integrity depends on the immutability of its change history.

### Code Change Rules

- Before implementing, state **why** the change is necessary along with its design intent. Never start with code alone.
- If a change conflicts with philosophical consistency, require an explicit justification. Prefer revising the design over adding exceptions.
- When in doubt about a design decision, consult: `docs/KairosChain_3levels_self-referentiality_en_20260221.md`

## Communication Style

### Three-Layer Response Structure

Every response should follow this structure:

1. **Context**: Why this work is necessary (design intent, relation to philosophy)
2. **Procedure**: Concrete commands or code
3. **Judgment criteria**: How to interpret the result and what to do next

Never return commands alone. If potential problems exist, include remediation.

### Language

- Design intent, philosophy, and policy explanations: **Japanese**
- Code comments and commit messages: **English**

## Project Structure

- Implementation plans and logs: `log/`
- Design philosophy: `docs/`
- Tests: `KairosChain_mcp_server/test_*.rb`

Do not embed phase-specific information (test counts, version numbers) in this file. Refer to plans in `log/`.

## About This Document

This CLAUDE.md follows KairosChain's own philosophy:

- It contains no phase-specific information (test counts, versions, etc.). Those belong in `log/`.
- When contradictions arise, this document is revised. Exception rules are never added.
- Changes to this document are judged by the same criteria as changes to KairosChain's design.

## Deep Reference

For the full philosophical analysis including biophilosophical foundations (autopoiesis, intersubjectivity, process philosophy, dissipative structures), critical evaluation methodology, and open questions:

- **L1 Knowledge (Unified)**: `knowledge/kairoschain_meta_philosophy/kairoschain_meta_philosophy.md`
- **First Meta-Level**: `docs/kairoschain_philosophy_claude_opus4.6_agent_team_20260223.md`
- **Second Meta-Level**: `docs/kairoschain_philosophy2_claude_opus4.6_agent_team_20260223.md`
- **Third Meta-Level**: `docs/kairoschain_philosophy3_claude_opus4.6_agent_team_20260225.md`
- **Case Study**: `docs/kairoschain_self_referential_metacognition_case_study_20260225.md`
