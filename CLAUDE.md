# KairosChain — Core Philosophy for Development

## Generative Principle: Structural Self-Referentiality

KairosChain's entire architecture flows from one principle:

> **Meta-level operations are expressed in the same structure as base-level operations.**

This is why Ruby (DSL/AST) was chosen. "Defining a Skill" and "defining the evolution rules for a Skill" use the same language, syntax, and runtime. This structural isomorphism is the foundation of self-referentiality, and all other properties of KairosChain germinate from it.

## Five Propositions (Summary)

1. **Self-referentiality as generative seed** — Not an axiom deriving everything, but a pattern whose recursive application at different levels produces different properties. Intentionally asymmetric: strongest at L0 governance core, pragmatically open at infrastructure level ("sufficient self-referentiality").

2. **Dual integrity guarantee** — Prevention (approval_workflow's 5-layer validation) + structural impossibility (a contradictory self-referential system cannot operate). The latter holds within legitimate operation paths only.

3. **Structure opens possibility space; design realizes it** — Self-referential structure automatically enables recursive extension. Individual SkillSets (MMP, HestiaChain) are engineered, but the *possibility* of expressing meta-capabilities as SkillSets is a structural consequence, not a design decision.

4. **Circular integration of process and result** — Operation, evolution, and recording are functionally separated but ontologically unified through the same Skill structure. Time is Kairos (qualitative moment), not Chronos (quantitative flow).

5. **Partial autopoiesis** — Self-production loop closes at the governance/capability-definition level; depends on external substrates (Ruby VM, filesystem) at the execution level. The question is "at which abstraction level does the loop close?" — not "is it complete?"

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

- **L1 Knowledge**: `knowledge/kairoschain_philosophy/kairoschain_meta_philosophy.md`
- **Full Document**: `docs/kairoschain_philosophy_claude_opus4.6_agent_team_20260223.md`
