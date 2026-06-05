# KairosChain SkillSet — category map against Anthropic's nine types

> Companion to the parent entry `skill_authoring_patterns` §A.
> Maps the 20 deployed SkillSets (+3 template-only) onto Anthropic's nine
> base-level categories, then onto the §C extension (norm / meta) the source omits.
> Snapshot: 2026-06-05. SkillSets evolve — re-run `skills_list` / inspect
> `.kairos/skillsets/` to refresh.

## Anthropic nine (base-level / 道具スキル)

| # | Anthropic category | KairosChain SkillSet(s) |
|---|--------------------|--------------------------|
| 1 | Library and API reference | `llm_client` (LLM call adapters), `mcp_client` (remote MCP), `external_tools` |
| 2 | Product verification | `introspection` (check / health / safety), `synoptis` (attestation verify) |
| 3 | Data fetching and analysis | — *(near-empty: KairosChain is not a data-ops platform; see gap note)* |
| 4 | Business process / team automation | `autoexec` (plan / run), `service_grant` (payment / access workflow) |
| 5 | Code scaffolding and templates | `skillset_creator`, `knowledge_creator`, `document_authoring` |
| 6 | Code quality and review | `multi_llm_review` |
| 7 | CI/CD and deployment | `plugin_projector` (→ `.claude` plugin), `kairos_hook_projector` (hooks), `skillset_exchange` (Meeting Place distribution) |
| 8 | Runbooks | `agent` (OODA investigation loop — partial fit) |
| 9 | Infrastructure operations | `multiuser`, `daemon_runtime`, `autonomos` (self-fix ops) |

## §C extension — categories Anthropic structurally omits

| Category | KairosChain instance(s) | Note |
|----------|-------------------------|------|
| 規範スキル / instance constitution | **masa mode** (`.kairos/skills/masa.md`) | Not a SkillSet — lives in the harness instruction-mode layer. Defines *how this instance acts*. |
| メタスキル (skill-evolution rules) | `skillset_creator`, `knowledge_creator`, `skills_evolve`/`skills_promote` (L0 tools), `dream` (meta-cognitive proposal), `autonomos` (self-modification cycle); L1 guide `agent_skill_evolution_guide` | Skills that define/evolve other skills. Structural self-referentiality (Prop 1) makes these expressible *as skills*. |

## Findings (why the mapping is interesting)

1. **Category 3 is nearly empty.** KairosChain has no data-analytics SkillSets — it is a self-referential governance substrate, not a BI/monitoring tool. A genuine taxonomy gap, not a defect.
2. **Several SkillSets don't fit any Anthropic category.** `hestia` + `mmp` (P2P Meeting Place / federation), `synoptis` (attestation / trust anchoring), `dream` (meta-cognition). Anthropic's tool-centric taxonomy has no slot for P2P-federation or meta-cognition — direct evidence for §C.
3. **Dual classification is common.** `skillset_creator` is both cat 5 (scaffolding) and §C-meta (it creates skills); `autonomos` is both cat 9 (ops) and §C-meta (self-modification). Anthropic's flat taxonomy cannot express the base/meta dual nature; KairosChain's layer model can.
4. **The one norm "skill" (masa mode) is not a SkillSet at all** — it is a harness instruction mode. This is exactly the placement difference §C names: KairosChain puts the norm in the harness, Anthropic puts it in the model/core.
