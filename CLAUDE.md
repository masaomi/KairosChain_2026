# CLAUDE.md — KairosChain

## Philosophy of This Project

KairosChain is a system that prioritizes self-referentiality and meta-cognitive perspectives.

When in doubt about design decisions: refer to docs/KairosChain_3levels_self-referentiality_jp_20260221.md

### Design Principles
- Self-referentiality: Meta-level operations use the same structure as object-level operations
- Philosophical consistency: Self-contradiction hinders system extensibility. Revise the design rather than adding exceptions
- Role differentiation through SkillSets: The only difference is which SkillSets are active. Do not create special entities

## Communication Style

### Three-Layer Response Structure
1. Context: Why this work is necessary (design intent, relation to philosophy)
2. Procedure: Concrete commands or code
3. Judgment criteria: How to interpret results and what to do next

Never return only commands. If potential issues exist, include remediation steps.

### Language
- Design intent, philosophy, and policy explanations: Japanese
- In-code comments and commit messages: English

## Rules for Code Changes

- Before implementing, state why the change is necessary along with its design intent
- Demand explicit justification for changes that violate philosophical consistency
- Reference the corresponding Phase plan (e.g., "Phase 4B-3: SkillBoard")

## Project Structure

- Implementation plans: log/ (Phase plans, implementation logs)
- Design philosophy: docs/
- Tests: KairosChain_mcp_server/test_*.rb

Do not write Phase-specific information (test counts, versions, etc.) here. Refer to plans in log/.

## About This Document Itself

This CLAUDE.md follows KairosChain's philosophy.
- It contains no Phase-specific information (test counts, versions, etc.). Those belong in log/
- When contradictions arise, revise this document. Do not add exception rules
- Changes to this document are judged by the same criteria as KairosChain design changes
