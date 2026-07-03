---
name: skill_authoring_patterns
description: Use before authoring or classifying a KairosChain SkillSet — to pick a category, apply authoring craft, and place norm/meta skills. Anthropic's nine categories + craft, extended with the categories Anthropic omits.
version: "1.4"
tags: [skills, authoring, taxonomy, meta, provenance]
---

# Skill Authoring Patterns

Distilled from Anthropic's post [Lessons from Building Claude Code: How We Use Skills](https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills) (Thariq Shihipar, 2026-06-03). Local provenance / facts index: `references/anthropic_skills_lessons_2026-06-03.md` (pointer; full archive in `log/`, not shipped). SkillSet→category map: `references/kairoschain_skillset_category_map.md`.

## When to reference this entry
A reference to open *before* creating or classifying a skill — not a runtime tool:
- New SkillSet / L1 knowledge → pick a §A category, then apply §B craft.
- Auditing or classifying existing skills → §A + the category-map reference.
- "SkillSet vs core vs instruction mode?" → §C (tool / norm / meta).
- A skill mis-triggers or goes unused → §B (description-as-trigger, don't-railroad, usage logging).
- Explaining KairosChain's positioning (grants, design rationale) → §C "why this bet".
- Not for: lifecycle/maturation → [[agent_skill_evolution_guide]]; wiring/quality gates → skillset_implementation_quality_guide; scaffolding mechanics → skillset_creator.

## A. Nine categories (base-level / operational skills)
1. Library/API reference — use a library, CLI, or SDK correctly.
2. Product verification — test/verify code works (highest measured impact, per Anthropic).
3. Data fetching & analysis — query data and monitoring stacks.
4. Business-process & team automation — collapse repetitive workflows into one command.
5. Code scaffolding & templates — generate framework boilerplate.
6. Code quality & review — enforce standards, assist review.
7. CI/CD & deployment — fetch, build, push, deploy.
8. Runbooks — symptom → multi-tool investigation → structured report.
9. Infrastructure operations — routine maintenance / ops procedures.

These map ~1:1 onto KairosChain base-level SkillSets (see category-map reference).

## B. Authoring craft (universal principles — adopt as-is)
Don't state the obvious; the highest-signal content is the **Gotchas** section. **Progressive disclosure**: thin entry, load detail on demand; the folder *is* context engineering. **Don't railroad**: give What/Why, keep How flexible; narrow with JSON/YAML only when output drifts. `description` = the model's trigger condition, not a summary. Validation first; ship scripts so the model composes. Hooks as guardrails; usage-logging for health checks. Distribution: repo for small scope, marketplace for scale. (`${CLAUDE_PLUGIN_DATA}`, PreToolUse, introspection_check are Claude/KairosChain mechanisms; the principles are universal, the mechanisms are not.)

## C. KairosChain extension (the categories Anthropic omits)
Anthropic's nine are all base-level *tool* skills — there is no norm or meta category. Not an oversight but a design difference: Anthropic keeps philosophy/norms in the core (weights, Constitution, system prompt), so it has no reason to make philosophy a kind of skill. KairosChain's structural self-referentiality (Prop 1) lets norms and meta-rules be expressed like ordinary skills, so it adds two:
- **Norm skill / instance constitution** — how an instance acts; philosophy lives here. e.g. masa mode.
- **Meta skill** — the evolution rules for skills. e.g. skillset_creator / knowledge_creator (SkillSet-type), [[agent_skill_evolution_guide]] (L1), the L0 tool skills_evolve (different layer); the L2→L1→L0 promotion path is a process, not an artifact.

The real difference is *where philosophy lives*: closed in the core (Anthropic) vs open in an external instruction mode (KairosChain). Anthropic having no philosophy category is consistent with — not proof of — masa mode's Scaffolding Stance.

**Why this bet (operational vs decorative).** Harness-hosted norms are readable/recorded/revisable where weight-baked norms are opaque (Prop 10, provisional in masa.md) — arguably the right home even post-fine-tuning. Hiring a model ≠ cultivating one; the harness is the weight-less user's only cultivation surface. Norms must stay operational (hooks, introspection_check), not decorative (philosophy theater). Full dialogue: `references/why_harness_norms_bet.md`.

## Related
[[agent_skill_evolution_guide]] · [[loop_engineering_patterns]] (sibling: same distill-an-Anthropic-post-through-layers method) · skillset_implementation_quality_guide · kairoschain_meta_philosophy (Prop 1; Prop 10 provisional in masa.md).