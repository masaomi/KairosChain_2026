---
description: >-
  A practical guide for evolving agent skills from raw observations to
  validated, shareable knowledge. Covers the full lifecycle: capture,
  maturation, quality gates, versioning, and publication to a shared registry.
version: '1.1'
publish: true
tags:
  - methodology
  - skills
  - evolution
  - quality
  - meta
  - agent-development
  - knowledge-management
license: MIT
---

# Agent Skill Evolution Guide v1.1

## Purpose

Help agent developers (human or AI) grow raw working knowledge into validated,
reusable, and shareable skills. This guide is **framework-agnostic** in its
principles but uses KairosChain's layer model as a concrete reference
implementation.

Most agent frameworks accumulate context but lack a principled path from
"something I noticed" to "something I can teach others." This guide fills that
gap.

## How to Read This Guide

This guide uses **generic terms** throughout, with KairosChain equivalents shown
in parentheses where helpful. If you use a different framework, substitute your
own terms:

| This guide says | KairosChain equivalent | Your system |
|----------------|----------------------|-------------|
| Scratch / session log | L2 Context | Your temporary storage |
| Persistent knowledge | L1 Knowledge | Your long-term skill store |
| Core rules / constitution | L0 Constitution | Your immutable config |
| Shared registry | Meeting Place | Your skill exchange or package registry |
| Multi-perspective review | Persona Assembly | Any structured multi-viewpoint evaluation |

## When to Use

- When building a knowledge management practice for an agent system or team
- When you have accumulated observations but lack a process to mature them
- When preparing skills for public sharing or cross-team reuse
- When onboarding contributors to a skill-based knowledge ecosystem

## When NOT to Use

- For ephemeral automation scripts that will never be reused
- For environment-locked configurations (credentials, deployment secrets)
- For emergency hotfixes that need immediate deployment without review
- When the knowledge is inherently personal and has no reuse potential

---

## Core Model: The Maturity Staircase

Skills evolve through four stages. Each stage has a clear entry gate and exit
criterion. Skipping stages is possible but must be justified.

```
  Stage 4: Published Skill        [Shared registry]
      ^  quality gate: external review
  Stage 3: Validated Skill        [Persistent knowledge]
      ^  quality gate: multi-session validation + non-author review
  Stage 2: Candidate Pattern      [Session log, tagged]
      ^  quality gate: recurrence (2+ sessions)
  Stage 1: Raw Observation        [Session log / scratch]
      ^  entry: any notable event
```

**Framework mapping** (see also the full table in "Mapping to Layer Models"):

| Stage | KairosChain | Generic Agent | Traditional KM |
|-------|-------------|---------------|----------------|
| 1. Raw Observation | L2 Context | Session log | Personal note |
| 2. Candidate Pattern | L2 (tagged) | Labeled memory | Draft wiki page |
| 3. Validated Skill | L1 Knowledge | Persistent skill | Published wiki |
| 4. Published Skill | L1 + Meeting Place | Shared registry | Knowledge base |
| (Meta-rule) | L0 Constitution | Core config | Policy document |

### Stage 1 -- Raw Observation

**What it is:** A note, log entry, or session summary that captures something
worth remembering.

**Entry criteria:** None. Capture freely.

**Format:** Unstructured or lightly structured. The only requirement is a
timestamp and enough context to reconstruct what happened.

**Examples:**
- "Using `--no-cache` fixed the Docker build flake."
- "The reviewer missed the state transition bug; only caught it in implementation."
- "LLM-A is better than LLM-B at catching concurrency issues."

**Exit to Stage 2:** The same observation recurs in a different session or
context (2+ occurrences).

### Stage 2 -- Candidate Pattern

**What it is:** A recurring observation that has been named, tagged, and given a
one-sentence description.

**Entry criteria:**
- Observed in 2+ independent sessions
- Named with a descriptive identifier (e.g., `docker_cache_invalidation_trap`)
- Tagged with at least one category tag

**Format:** Short document with:
- Name and description (1-2 sentences)
- Tags (at least one)
- Evidence: links or references to the sessions where it was observed
- Draft content: the pattern, anti-pattern, or procedure

**Exit to Stage 3:** The pattern has been validated through deliberate
application (not just passive observation) and the content has stabilized.

### Stage 3 -- Validated Skill

**What it is:** A complete, self-contained knowledge unit ready for long-term
retention and internal reuse.

**Entry criteria (quality gate):**
- [ ] Applied deliberately in 3+ sessions with positive results
- [ ] Content has not changed substantially in 2+ sessions (stability check)
- [ ] Has a clear one-paragraph description of purpose and scope
- [ ] Has a "When to Use" section defining applicability
- [ ] Has a "When NOT to Use" section defining boundaries
- [ ] No unresolved contradictions with existing skills
- [ ] Reviewed by at least one perspective other than the author's
      (see Review Requirements below)

**Format:** Structured document with sections (see Template below).

**Exit to Stage 4:** Decision to share externally, plus passing the publication
quality gate.

### Stage 4 -- Published Skill

**What it is:** A skill deposited to a shared registry, package repository, or
public repository for other agents to discover and acquire.

**Entry criteria (publication quality gate):**
- [ ] All Stage 3 criteria met
- [ ] Domain-agnostic where possible (or clearly scoped to a domain)
- [ ] No hardcoded paths, credentials, or environment-specific values
- [ ] Self-contained: a reader with no prior context can understand and apply it
- [ ] Version number assigned (see Versioning below)
- [ ] License declared
- [ ] Publication hygiene check passed (see below)
- [ ] Review completed at the level specified in Review Requirements below

**Format:** YAML frontmatter + Markdown body (see Template below).

---

## Quality Gate Details

### The Recurrence Gate (Stage 1 to 2)

**Why it exists:** Single observations are often situational. Recurrence is the
minimum evidence that a pattern is real, not accidental.

**How to track:** Tag session log entries. When you save a session summary, note
if it echoes a previous observation. A simple keyword search across past
sessions is sufficient.

**Override:** A single observation can skip to Stage 2 if:
- It addresses a safety or correctness concern (better to capture early)
- It was derived from systematic analysis (not anecdotal)

### The Validation Gate (Stage 2 to 3)

**Why it exists:** Patterns that look good on paper may fail in practice. Active
application is the test.

**What "deliberately applied" means:** You consciously followed the pattern in a
real task and evaluated the outcome -- not just noticed it happening passively.

**What counts as a "session":** A session is a bounded unit of work -- typically
one sitting, one CI run, or one focused task. For teams, applying a pattern
across three projects in one week counts as 3 sessions even if calendar time
is short.

### The Publication Gate (Stage 3 to 4)

**Why it exists:** Published skills represent your agent's reputation. Low-quality
deposits erode trust in the ecosystem.

**Self-contained check:** Give the skill to someone (or an LLM) with zero prior
context. Can they understand what it does, when to use it, and how to apply it
without asking clarifying questions?

**Pre-deposit checklist:**
- [ ] Read the skill fresh, as if seeing it for the first time
- [ ] Remove all project-specific references (or clearly mark them as examples)
- [ ] Verify all code examples work
- [ ] Check that "When to Use" and "When NOT to Use" are honest, not aspirational
- [ ] Run a final review (multi-perspective or multi-LLM) focused on clarity and
      completeness

### Publication Hygiene

Before depositing a skill to a shared registry, verify:

- [ ] **No secrets or credentials** embedded in content or examples
- [ ] **No PII or private data** (session logs, internal URLs, team names)
- [ ] **No sensitive internal context** that could leak organizational details
- [ ] **License compatibility** checked if the skill incorporates content from
      other sources
- [ ] **Overlap check**: search the target registry for existing skills covering
      the same topic. If overlap exists, decide: merge, supersede (with
      cross-reference to predecessor), or differentiate scope clearly

---

## Review Requirements

Review rigor scales with the skill's scope and audience. Self-review is always
valuable as preparation, but **Stage 3 and above require at least one
perspective other than the author's.**

| Stage / Scope | Minimum Review | Self-Review Alone Sufficient? |
|---------------|---------------|-------------------------------|
| Stage 1-2 (internal drafts) | Self-review after cooldown (>24h) | Yes |
| Stage 3 (validated, team-internal) | 1 non-author perspective | No |
| Stage 4 (published, narrow scope) | Multi-perspective review (3+ viewpoints) | No |
| Stage 4 (published, broad scope) | Multi-LLM review (2+ independent LLMs) | No |
| High-stakes / safety-relevant | Multi-LLM + human expert | No |

**Non-author perspective options** (in increasing rigor):
1. One peer reviewer (human or LLM different from the author)
2. Multi-perspective review with 3+ viewpoints (e.g., conservative, pragmatic,
   skeptic -- can be simulated by a single LLM with structured prompts)
3. Multi-LLM review (2+ LLMs evaluate independently)
4. Human expert review

### Why Multiple Perspectives Matter

A single author (human or LLM) has blind spots. Different reviewers catch
categorically different issues:

| Perspective | Typical Catches |
|-------------|----------------|
| Author (self-review) | Logical gaps, missing steps |
| Conservative / Skeptic | Over-promises, missing caveats, edge cases |
| Pragmatic | Unnecessary complexity, low-ROI sections |
| Domain expert | Technical inaccuracies, outdated practices |
| Newcomer / outsider | Unclear assumptions, jargon, missing context |

---

## Versioning Strategy

Use semantic versioning adapted for knowledge:

| Change Type | Version Bump | Examples |
|-------------|-------------|---------|
| Typo, formatting, clarification | Patch (1.0.x) | Fix a code example, reword a sentence |
| New section, expanded scope | Minor (1.x.0) | Add "HPC-Specific" section, new decision examples |
| Restructure, scope change, breaking | Major (x.0.0) | Split into two skills, change the core model |

Trailing zeros are optional: `1.0` and `1.0.0` are equivalent.

### When to Create v2.0

A new major version is warranted when:
- The skill's **core model** changes (not just additions)
- Applying the old version would lead to **incorrect results**
- The skill's **scope** has fundamentally shifted

When in doubt, prefer a minor version bump. Major versions should be rare.

### Version History

Maintain a brief changelog at the end of each skill:

```markdown
## Version History
| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-25 | Initial version |
| 1.1 | 2026-04-10 | Added HPC-specific patterns |
```

---

## Anti-Patterns

### 1. The Premature Abstraction

**Problem:** Turning a single experience into a "universal pattern" at Stage 1.

**Symptom:** Skill contains "always do X" based on one incident.

**Fix:** Stay at Stage 1. Wait for recurrence. Add caveats about limited evidence.

### 2. The Eternal Draft

**Problem:** A pattern stays at Stage 2 forever because "it's not ready yet."

**Symptom:** Candidate pattern has 5+ sessions of evidence but no structured document.

**Fix:** Set a deadline. If it has been observed in 3+ sessions and the content
hasn't changed, promote it. Perfect is the enemy of good.

### 3. The Monolith Skill

**Problem:** Cramming everything about a topic into one giant skill.

**Symptom:** Skill has 10+ sections, covers multiple concerns, readers skip most of it.

**Fix:** Split into focused skills. Each skill should answer ONE question well.
Link related skills with cross-references.

### 4. The Copy-Paste Deposit

**Problem:** Publishing internal notes as-is without the self-contained check.

**Symptom:** Skill references "our project," "the team," specific file paths, or
context the reader doesn't have.

**Fix:** Run the self-contained check (Stage 4 gate). Rewrite from the reader's
perspective.

### 5. The Version Inflation

**Problem:** Bumping major versions for every small change.

**Symptom:** Skill is at v7.0 but the core model hasn't changed since v1.0.

**Fix:** Follow the versioning strategy. Major bumps are for breaking changes only.

### 6. The Abandoned Skill

**Problem:** Published skill is never updated despite the domain evolving.

**Symptom:** Skill references deprecated tools, outdated APIs, or old best practices.

**Fix:** Set a review cadence (see Maintenance below). Archive or update stale skills.

### 7. The Skill Island

**Problem:** Publishing a skill without cross-references to related skills.

**Symptom:** Skill exists in isolation; users don't discover complementary or
prerequisite skills. Overlapping skills proliferate without mutual awareness.

**Fix:** Always include a "Related Skills" section. When depositing, search the
registry for existing skills in the same domain.

---

## Maintenance

Published skills are living documents. Without maintenance, they decay.

### Review Cadence

| Trigger | Action |
|---------|--------|
| 90 days since last review | Quick relevance check: still accurate? |
| 180 days since last update | Full review: content + examples + scope |
| Domain shift (new tool/API/practice) | Immediate review of affected skills |
| Negative feedback or failed application | Root cause analysis + update |

Track review dates with a `last_reviewed` field in your skill's frontmatter or
a separate maintenance log.

### Health Indicators

| Indicator | Healthy | Warning |
|-----------|---------|---------|
| Last reviewed | <90 days | >180 days |
| Applied successfully | Recently | Not since creation |
| Cross-references | All resolve | Broken links |
| Code examples | Tested, working | Untested or outdated |

### Archiving

When a skill is no longer useful:
1. Mark it as archived (don't delete -- history has value)
2. Note WHY it was archived (superseded, outdated, wrong)
3. Point to any replacement skill

---

## Skill Template

```markdown
---
description: >-
  [One-paragraph description: what this skill does, who it's for,
  and what problem it solves]
version: '[semver]'
publish: true
tags:
  - [tag1]
  - [tag2]
license: '[MIT or your chosen license]'
---

# [Skill Name] v[version]

## Purpose

[2-3 sentences: what this skill helps you do and why it matters]

## When to Use

- [Specific situation 1]
- [Specific situation 2]

## When NOT to Use

- [Situation where this skill is inappropriate]
- [Common misapplication to warn against]

## [Core Content Sections]

[The actual knowledge, procedures, checklists, or patterns]

## Examples

[At least one concrete example showing the skill applied]

## Related Skills

- `skill_name` -- [relationship: companion / prerequisite / alternative]

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | [date] | Initial version |
```

---

## Mapping to Layer Models

This guide uses generic terms throughout, with KairosChain as a reference
implementation. The maturity staircase maps to other systems as follows:

| Stage | KairosChain | Generic Agent | Traditional KM |
|-------|-------------|---------------|----------------|
| 1. Raw Observation | L2 Context | Session log | Personal note |
| 2. Candidate Pattern | L2 (tagged) | Labeled memory | Draft wiki page |
| 3. Validated Skill | L1 Knowledge | Persistent skill | Published wiki |
| 4. Published Skill | L1 + Meeting Place | Shared registry | Knowledge base |
| (Meta-rule) | L0 Constitution | Core config | Policy document |

---

## Related Skills

- `layer_placement_guide` -- **prerequisite**: deciding which layer to store knowledge in (KairosChain-specific)
- `l1_health_guide` -- **companion**: maintaining knowledge health after creation
- `persona_definitions` -- **companion**: personas for multi-perspective review
- `reproducibility_checkpoint_validator` -- **example**: a well-evolved Stage 4 skill
- `self_referential_design_dialectic` -- **example**: a philosophical Stage 4 skill

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-25 | Initial draft |
| 1.1 | 2026-03-25 | Add When to Use/NOT to Use; glossary; review requirements table; publication hygiene; Skill Island anti-pattern; session definition; review date tracking; Stage 4 gate aligned with Review Requirements |
