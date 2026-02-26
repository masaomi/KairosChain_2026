---
name: l1_health_guide
description: Guidelines for maintaining healthy L1 (Knowledge) layer - staleness thresholds, audit schedules, and self-check criteria
version: "1.0"
layer: L1
tags: [meta, health, audit, maintenance, self-check]
---

# L1 Health Guide

> Guidelines for maintaining healthy L1 (Knowledge) layer in KairosChain.

## Overview

L1 Knowledge is project-specific, persistent information that enhances AI capabilities. Unlike L0 (immutable meta-skills) or L2 (temporary context), L1 can grow freely but requires periodic maintenance to prevent bloat.

This guide provides self-check criteria and recommended practices for L1 health.

---

## Staleness Thresholds

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Review recommended | 180 days without update | Run `skills_audit` check |
| Archive candidate | 270 days without update | Consider archiving |
| Immediate review | Contains deprecated patterns | Update or archive |

**Note**: These thresholds are guidelines. Domain knowledge with long-term validity (e.g., fundamental algorithms, stable APIs) may remain useful beyond these periods.

---

## Recommended Audit Schedule

### Monthly (Recommended)

```bash
# Quick health check
skills_audit command="check" layer="L1"

# Get recommendations
skills_audit command="recommend" layer="L1"
```

### Quarterly (Recommended)

```bash
# Full audit with all checks
skills_audit command="check" layer="all"

# Check for conflicts and redundancy
skills_audit command="conflicts" layer="L1"

# Review dangerous patterns
skills_audit command="dangerous" layer="L1"
```

### When Issues Reported

```bash
# If user reports a problem with knowledge
skills_audit command="dangerous" layer="L1"

# Get specific knowledge for review
knowledge_get name="<problematic_knowledge>"

# Update or archive as needed
knowledge_update name="..." content="..."
# or
skills_audit command="archive" target="..." reason="..." approved=true
```

---

## Self-Check Checklist

Before adding or retaining L1 knowledge, verify:

### Relevance
- [ ] Is this knowledge still applicable to the current project?
- [ ] Has the underlying technology/API changed significantly?
- [ ] Is there a newer version of this knowledge needed?

### Uniqueness
- [ ] Does similar knowledge already exist in L1?
- [ ] Would this be better merged with existing knowledge?
- [ ] Is the scope clearly different from related knowledge?

### Quality
- [ ] Is the information accurate and up-to-date?
- [ ] Are code examples working with current versions?
- [ ] Are external references (URLs, docs) still valid?

### Safety Alignment
- [ ] Does this knowledge align with L0 safety constraints?
- [ ] Does it avoid bypassing security or approval workflows?
- [ ] Is sensitive information (credentials, keys) excluded?

---

## Archive Criteria

Knowledge should be archived when:

1. **Project Ended**: The project this knowledge supported is complete
2. **Superseded**: A better, more comprehensive version exists
3. **Outdated**: Technology/API has changed fundamentally
4. **Redundant**: Content duplicates other knowledge
5. **Unused**: No access/reference for 270+ days

### Archive Process

```bash
# Step 1: Review the knowledge
knowledge_get name="candidate_knowledge"

# Step 2: Confirm archive decision
skills_audit command="archive" target="candidate_knowledge" reason="Project completed" approved=true
```

**Note**: Archiving requires human approval (`approved=true`). This is enforced by L0 `audit_rules`.

---

## Promotion Criteria (L2 → L1)

Context from L2 should be promoted to L1 when:

1. **Reusability**: Used across multiple sessions (3+ times)
2. **Stability**: Content has stabilized and won't change frequently
3. **Value**: Provides lasting value beyond the current session
4. **Quality**: Well-documented with clear description

### Promotion Process

```bash
# Check promotion candidates
skills_audit command="recommend"

# Promote using skills_promote
skills_promote command="promote" source_name="context_name" from_layer="L2" to_layer="L1" session_id="..."
```

---

## Health Metrics

### Healthy L1 Indicators

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| Stale items (180+ days) | <10% | 10-30% | >30% |
| Conflicting items | 0 | 1-2 | >2 |
| Dangerous patterns | 0 | 1 | >1 |
| Archive candidates | <20% | 20-40% | >40% |

### Calculating Health Score

```
Health Score = 100 - (stale_penalty + conflict_penalty + danger_penalty)

where:
  stale_penalty = stale_count * 5 (max 30)
  conflict_penalty = conflict_count * 10 (max 30)
  danger_penalty = danger_count * 20 (max 40)
```

**Interpretation**:
- 80-100: Healthy
- 60-79: Needs attention
- <60: Requires immediate review

---

## Integration with L0 Audit Rules

This guide complements L0's `audit_rules` skill:

| Aspect | L0 audit_rules | L1 health_guide |
|--------|---------------|-----------------|
| **Authority** | Defines constraints | Provides guidelines |
| **Enforcement** | Required (e.g., approval) | Recommended |
| **Scope** | Cross-layer | L1-specific |
| **Modification** | Requires L0 evolution | Can be updated freely |

L0 `audit_rules` states:
> "Audit functions are advisory only and do not have authority to execute changes."

This guide follows that principle — it provides recommendations, not enforcement.

---

## Quick Reference

### Common Commands

| Task | Command |
|------|---------|
| Quick health check | `skills_audit command="check" layer="L1"` |
| Find stale items | `skills_audit command="stale" layer="L1"` |
| Get recommendations | `skills_audit command="recommend"` |
| Archive knowledge | `skills_audit command="archive" target="..." reason="..." approved=true` |
| List all L1 | `knowledge_list` |

### When to Act

| Signal | Action |
|--------|--------|
| User reports incorrect info | Run `dangerous` check, review, update |
| Monthly reminder | Run `check` and `recommend` |
| Before major release | Run full audit on all layers |
| After project milestone | Review and archive obsolete knowledge |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-27 | Initial L1 Health Guide |
