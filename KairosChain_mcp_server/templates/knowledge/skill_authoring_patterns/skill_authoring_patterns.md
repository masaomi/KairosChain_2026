---
name: skill_authoring_patterns
description: Use when authoring or classifying KairosChain SkillSets. Anthropic's nine skill categories plus authoring craft, re-read through KairosChain layers and extended with the norm/meta-skill categories Anthropic structurally omits. Source pointer (not full text) in references/.
version: "1.3"
tags: [skills, authoring, taxonomy, meta, provenance]
---

# Skill Authoring Patterns

Distilled from Anthropic's official post "Lessons from Building Claude Code: How We Use Skills" (Thariq Shihipar, 2026-06-03). Source pointer (URL, not redistributed full text): `references/anthropic_skills_lessons_2026-06-03.md`; full archive kept out-of-distribution in `log/`. SkillSet→category map: `references/kairoschain_skillset_category_map.md`. This entry re-reads the source through KairosChain layers and adds what is missing.

## A. Nine categories (base-level / 実用 SkillSets)
Library/API ref · Product verification (highest measured impact, per Anthropic) · Data fetch/analysis · Business-process automation · Scaffolding/templates · Code quality/review · CI/CD & deploy · Runbooks · Infra ops. All map ~1:1 onto KairosChain base-level SkillSets (see category map reference).

## B. Authoring craft (universal principles — adopt as-is)
Don't state the obvious; the highest-signal content is the **Gotchas** section. **Progressive disclosure**: thin entry, load detail on demand; the folder *is* context engineering. **Don't railroad**: give What/Why, keep How flexible; narrow with JSON/YAML only when output drifts. `description` = the model's trigger condition, not a human summary. Validation first; ship scripts so the model composes. Memory, hooks, usage-logging for health checks. Distribution: repo for small scope, marketplace for scale. (Mechanisms like `${CLAUDE_PLUGIN_DATA}`, PreToolUse hooks, introspection_check are Claude/KairosChain-specific; the *principles* are universal, the *mechanisms* are not.)

## C. KairosChain extension (the categories Anthropic omits)
9 分類はすべて base-level の道具スキルで、規範スキル・メタスキルが無い。見落としではなく設計差: Anthropic は哲学・規範を core (モデル / Constitution / システム層) に置くため、哲学をスキルの型にする動機が無い。KairosChain は構造的自己言及性 (命題1) で規範もメタ規則も同じ構造で書けるため、2 分類を足す:
- **規範スキル / instance constitution** — how an instance acts. 例: masa mode。
- **メタスキル** — スキルの進化規則を定義するもの。例: skillset_creator・knowledge_creator (SkillSet 型), [[agent_skill_evolution_guide]] (L1 guide), L0 core tool の skills_evolve (※層が異なる)。L2→L1→L0 昇格路は成果物でなくプロセス。
哲学を core に閉じる (Anthropic) か外付け instruction mode に開く (KairosChain) かの差。Anthropic に哲学分類が無いことは、masa mode Scaffolding Stance の分岐と整合的（外部証拠とまでは主張しない）。

**Why this bet (operational vs decorative).** Harness-hosted norms are readable / recorded / revisable where weight-baked norms are opaque (Prop 10 — provisional, masa.md) — arguably the right home even post-fine-tuning, not a mere workaround for not owning the weights. The frame is 採用 (hiring a model) vs 育成 (cultivating behavior): the harness is the weight-less user's only cultivation surface. Success hinges on keeping norms **operational** (hooks, introspection_check) not **decorative** (philosophy theater). Full dialogue: `references/why_harness_norms_bet.md`.

## Related
[[agent_skill_evolution_guide]] (how to grow a skill) · skillset_implementation_quality_guide · kairoschain_meta_philosophy (Prop 1; Prop 10 provisional in masa.md).