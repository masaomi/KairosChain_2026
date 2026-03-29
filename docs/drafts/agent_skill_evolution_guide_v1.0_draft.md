---
description: >-
  A practical guide for evolving agent skills from raw observations to
  validated, shareable knowledge. Covers the full lifecycle: capture,
  maturation, quality gates, versioning, and publication to a Meeting Place.
version: '1.0'
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

# Agent Skill Evolution Guide v1.0

## Purpose

Help agent developers (human or AI) grow raw working knowledge into validated,
reusable, and shareable skills. This guide is **framework-agnostic** in its
principles but uses KairosChain's layer model (L2/L1/L0) as a concrete
reference implementation.

Most agent frameworks accumulate context but lack a principled path from
"something I noticed" to "something I can teach others." This guide fills that
gap.

## Core Model: The Maturity Staircase

Skills evolve through four stages. Each stage has a clear entry gate and exit
criterion. Skipping stages is possible but must be justified.

```
  Stage 4: Published Skill        [Meeting Place / Registry]
      ^  quality gate: external review
  Stage 3: Validated Skill        [L1 Knowledge]
      ^  quality gate: multi-session validation
  Stage 2: Candidate Pattern      [L2 Context, tagged]
      ^  quality gate: recurrence (2+ sessions)
  Stage 1: Raw Observation        [L2 Context / scratch]
      ^  entry: any notable event
```

### Stage 1 — Raw Observation

**What it is:** A note, log entry, or session summary that captures something
worth remembering.

**Entry criteria:** None. Capture freely.

**Format:** Unstructured or lightly structured. The only requirement is a
timestamp and enough context to reconstruct what happened.

**Examples:**
- "Using `--no-cache` fixed the Docker build flake."
- "The reviewer missed the state transition bug; only caught it in implementation."
- "Cursor is better than Codex at catching concurrency issues."

**Exit to Stage 2:** The same observation recurs in a different session or
context (2+ occurrences).

### Stage 2 — Candidate Pattern

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

### Stage 3 — Validated Skill

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
      (human review, Persona Assembly, or multi-LLM review)

**Format:** Structured document with sections (see Template below).

**Exit to Stage 4:** Decision to share externally, plus passing the publication
quality gate.

### Stage 4 — Published Skill

**What it is:** A skill deposited to a Meeting Place, package registry, or
public repository for other agents to discover and acquire.

**Entry criteria (publication quality gate):**
- [ ] All Stage 3 criteria met
- [ ] Domain-agnostic where possible (or clearly scoped to a domain)
- [ ] No hardcoded paths, credentials, or environment-specific values
- [ ] Self-contained: a reader with no prior context can understand and apply it
- [ ] Version number assigned (see Versioning below)
- [ ] License declared
- [ ] Tested by at least one agent/person other than the author (or
      multi-perspective review as substitute)

**Format:** YAML frontmatter + Markdown body (see Template below).

---

## Quality Gate Details

### The Recurrence Gate (Stage 1 to 2)

**Why it exists:** Single observations are often situational. Recurrence is the
minimum evidence that a pattern is real, not accidental.

**How to track:** Tag L2 context entries. When you save a session summary, note
if it echoes a previous observation. A simple keyword search across past
sessions is sufficient.

**Override:** A single observation can skip to Stage 2 if:
- It addresses a safety or correctness concern (better to capture early)
- It was derived from systematic analysis (not anecdotal)

### The Validation Gate (Stage 2 to 3)

**Why it exists:** Patterns that look good on paper may fail in practice. Active
application is the test.

**What "deliberately applied" means:** You consciously followed the pattern in a
real task and evaluated the outcome — not just noticed it happening passively.

**Minimum review requirement:** At least one perspective beyond the author.
Options (in increasing rigor):
1. Self-review after a cooldown period (>24h)
2. Persona Assembly with 3+ personas (e.g., kairos, pragmatic, skeptic)
3. Multi-LLM review (2+ LLMs evaluate independently)
4. Human peer review

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
- [ ] Run a final review (Persona Assembly or multi-LLM) focused on clarity and
      completeness

---

## Versioning Strategy

Use semantic versioning adapted for knowledge:

| Change Type | Version Bump | Examples |
|-------------|-------------|---------|
| Typo, formatting, clarification | Patch (1.0.x) | Fix a code example, reword a sentence |
| New section, expanded scope | Minor (1.x.0) | Add "HPC-Specific" section, new decision examples |
| Restructure, scope change, breaking | Major (x.0.0) | Split into two skills, change the core model |

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

## Multi-Perspective Review

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

### Lightweight Review Options

Not every skill needs a full review panel. Match rigor to stakes:

| Skill Scope | Recommended Review |
|-------------|-------------------|
| Personal workflow note | Self-review after cooldown |
| Team-internal skill | 1 peer + self-review |
| Published skill (narrow scope) | Persona Assembly (3 personas) |
| Published skill (broad scope) | Multi-LLM review (2+ LLMs) |
| High-stakes / safety-relevant | Multi-LLM + human expert |

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

### Health Indicators

| Indicator | Healthy | Warning |
|-----------|---------|---------|
| Last reviewed | <90 days | >180 days |
| Applied successfully | Recently | Not since creation |
| Cross-references | All resolve | Broken links |
| Code examples | Tested, working | Untested or outdated |

### Archiving

When a skill is no longer useful:
1. Mark it as archived (don't delete — history has value)
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
license: MIT
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

This guide uses KairosChain's L2/L1/L0 as a reference, but the maturity staircase
maps to other systems:

| Stage | KairosChain | Generic Agent | Traditional KM |
|-------|-------------|---------------|----------------|
| 1. Raw Observation | L2 Context | Session log | Personal note |
| 2. Candidate Pattern | L2 (tagged) | Labeled memory | Draft wiki page |
| 3. Validated Skill | L1 Knowledge | Persistent skill | Published wiki |
| 4. Published Skill | L1 + Meeting Place | Shared registry | Knowledge base |
| (Meta-rule) | L0 Constitution | Core config | Policy document |

---

## Related Skills

- `layer_placement_guide` -- **prerequisite**: deciding which layer to store knowledge in
- `l1_health_guide` -- **companion**: maintaining knowledge health after creation
- `persona_definitions` -- **companion**: personas for multi-perspective review
- `reproducibility_checkpoint_validator` -- **example**: a well-evolved Stage 4 skill
- `self_referential_design_dialectic` -- **example**: a philosophical Stage 4 skill

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-25 | Initial draft |
