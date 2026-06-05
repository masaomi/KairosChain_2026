# [Archived source] Lessons from Building Claude Code: How We Use Skills

> **Provenance / 来歴**
> - **Source (official):** https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills
> - **Author:** Thariq Shihipar (Member of Technical Staff, Anthropic — Claude Code)
> - **Published:** 2026-06-03
> - **Retrieved:** 2026-06-05 (via WebFetch)
> - **Status:** Archived copy of Anthropic's official post, kept as a provenance reference for the L1 entry `skill_authoring_patterns`. Anthropic retains all rights to the original text; this copy exists only to make the parent skill's lineage auditable (KairosChain Prop 5 — constitutive recording; Masa Mode Principle 9 — full provenance on shared knowledge). Reproduced as faithfully as the fetch allowed; minor formatting normalization only. If discrepancies matter, the canonical source is the URL above.
> - **Companion video referenced by the user:** https://www.youtube.com/watch?v=dG__A6hmKUo (Japanese walkthrough of the same post).

---

## What Are Skills?

Skills are folders containing instructions, scripts, and resources that agents can discover and use to work more accurately and efficiently. A common misconception is that skills are "just markdown files"—they're actually folders that can include scripts, assets, and data that agents can discover and manipulate. Claude Code skills offer a wide variety of configuration options including registering dynamic hooks.

---

## Nine Types of Skills

Anthropic's internal catalog revealed skills cluster into nine distinct categories:

### 1. Library and API Reference
Skills explaining how to correctly use libraries, CLIs, or SDKs. Include reference code snippets and gotchas for Claude to avoid when scripting.
**Examples:** billing libraries, internal platform CLIs, sandbox proxy configuration

### 2. Product Verification
Skills describing how to test or verify code is working, often paired with playwright, tmux, or similar tools. These have shown the most measurable impact on Claude's output quality internally.
**Examples:** signup flow drivers, checkout verifiers, interactive CLI drivers

### 3. Data Fetching and Analysis
Skills connecting to data and monitoring stacks, including libraries for data retrieval with credentials and instructions on common workflows.
**Examples:** funnel queries, cohort comparisons, Grafana/Datadog references

### 4. Business Process and Team Automation
Skills automating repetitive workflows. Often simple instructions but may depend on other skills or MCPs. Storing previous results in logs helps maintain consistency.
**Examples:** standup posts, ticket creation, weekly recaps

### 5. Code Scaffolding and Templates
Skills generating framework boilerplates for specific functions. Useful when scaffolding has natural language requirements beyond pure code generation.
**Examples:** workflow scaffolders, migration templates, new app creation

### 6. Code Quality and Review
Skills enforcing organizational code quality and assisting with code review, using deterministic scripts for robustness.
**Examples:** adversarial review agents, code style enforcement, testing practices

### 7. CI/CD and Deployment
Skills helping fetch, push, and deploy code. May reference other skills to collect data.
**Examples:** PR babysitting, service deployment with rollout, cherry-pick production fixes

### 8. Runbooks
Skills taking symptoms (Slack threads, alerts, error signatures) through multi-tool investigation, producing structured reports.
**Examples:** service debugging, oncall runners, log correlators

### 9. Infrastructure Operations
Skills performing routine maintenance and operational procedures, some involving destructive actions that benefit from guardrails.
**Examples:** orphaned resource cleanup, dependency management, cost investigation

---

## Tips for Making Skills

### Don't State the Obvious
Claude already knows how to code and can read your codebase. Focus on information that pushes Claude out of its normal way of thinking rather than restating default behavior.

### Build a Gotchas Section
The highest-signal content in any skill is the Gotchas section. Update over time to capture common failure points, such as:
- Table-specific quirks (append-only behavior, version vs. timestamp)
- Field naming inconsistencies across systems
- Behavioral differences between staging and production

### Use the File System and Progressive Disclosure
Think of the entire folder structure as context engineering. Point Claude to specific files for specific situations. Structure includes:
- Detailed function signatures in reference markdown files
- Template files in `/assets/` to copy and use
- Folders of references, scripts, and examples

### Avoid Railroading Claude
Give Claude the information it needs, but give it the flexibility to adapt to the situation. Provide guidance without overly prescriptive instructions.

### Think Through the Setup
Some skills need user context (like which Slack channel to post to). Store setup information in `config.json` and have the agent ask for missing details using the AskUserQuestion tool if needed.

### Write Descriptions for the Model, Not Humans
The description field isn't a summary—it's a description of when to trigger this skill. Include triggers and use cases so Claude recognizes when to invoke it.

### Help Claude Remember
Some skills can include memory by storing data within them—append-only text logs, JSON files, or SQLite databases. Use the environment variable `${CLAUDE_PLUGIN_DATA}` for persistent storage.

### Store Scripts and Generate Code
Provide Claude with scripts and libraries so it spends its turns on composition rather than reconstructing boilerplate. Include helper functions Claude can compose for advanced analysis.

### Use On-Demand Hooks
Include hooks activated only when the skill is called, lasting only for that session. Examples include blocking dangerous commands (`rm -rf`, `DROP TABLE`) or restricting edits to specific directories.

---

## Distributing Skills

Share skills either by checking them into repos (under `./.claude/skills`) or through a plugin marketplace. Smaller teams working across few repos can use repo-based distribution, but scaling requires a marketplace where teams decide which skills to install.

**Marketplace submission approach:** Skills can start in a sandbox folder and move to the marketplace once they gain traction, via pull request.

---

## Composing Skills

Skills can reference each other by name—the model will invoke them if installed. Dependency management isn't natively built in yet, but this pattern works for composed workflows.

---

## Measuring Skills

Use a PreToolUse hook to log skill usage, identifying popular skills and detecting those that undertrigger compared to expectations.

---

## Getting Started

Skills best practices are still evolving. Most effective skills begin simple and improve as people add to them when Claude encounters edge cases.

**Resources:**
- Skills documentation: https://code.claude.com/docs/en/skills
- Example skills to customize: https://github.com/anthropics/skills
