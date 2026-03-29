---
name: dream_trigger_policy
version: "0.2.1"
tags:
  - dream
  - trigger
  - heuristics
  - consolidation
  - archival
---

# Dream Trigger Policy

## Overview

This knowledge defines the heuristics that determine when Dream SkillSet operations
should be triggered. Dream is a memory consolidation system that scans L2 contexts
for recurring patterns, manages soft-archival of stale contexts, and packages
promotion proposals for L2-to-L1 elevation.

## Trigger Heuristics

### 1. Promotion Candidate Detection (Tag Co-occurrence)

**Signal**: A tag appears in `min_recurrence` or more distinct sessions.

- Default threshold: 3 sessions
- Only live contexts are considered (soft-archived stubs are excluded)
- Tags are extracted from YAML frontmatter of context `.md` files
- Co-occurrence is counted per-session, not per-context (a tag appearing 5 times
  in one session counts as 1 occurrence)

**Action**: Include in `promotion_candidates` list for LLM evaluation.

### 2. Consolidation Candidate Detection (Name Overlap)

**Signal**: Two or more contexts share high name-token overlap (Jaccard similarity).

- Default threshold: Jaccard >= 0.5
- Comparison uses underscore-separated tokens from context names
- Example: `deployment_notes` and `deployment_config_notes` share tokens
  `deployment` and `notes`, yielding Jaccard = 2/3 = 0.67

**Action**: Include in `consolidation_candidates` list for LLM evaluation.

### 3. L2 Staleness Detection (Archive Candidates)

**Signal**: A context's file modification time (mtime) exceeds the staleness threshold.

- Default threshold: 90 days
- Uses `File.mtime` on the context `.md` file
- Only live contexts are candidates (already-archived stubs are excluded)
- "Semantic reference" tracking is a future enhancement (v2.2+)

**Action**: Include in `archive_candidates` list. Archive requires explicit
`dry_run: false` to execute.

### 4. L1 Staleness Detection

**Signal**: An L1 knowledge skill's name does not appear in any recent L2 context tags.

- Compares L1 knowledge names against the union of all L2 tags
- L1 skills that are never referenced in L2 may indicate orphaned knowledge

**Action**: Include in `health_summary.stale_l1` for informational purposes.
No automatic action is taken on L1 knowledge.

### 5. Bisociation Detection (Experimental)

**Signal**: Two tags that rarely co-occur in the same session but each appear
frequently across separate sessions.

- Measured by Pointwise Mutual Information (PMI)
- Off by default (`bisociation.enabled: false`)
- Guarded by `min_pair_count >= 2` and `min_tag_types >= 15`
- Brittle on small corpora; intended for mature knowledge bases

**Action**: Advisory only. LLM evaluates substance; no auto-promotion.

## When to Run dream_scan

Recommended triggers:

1. **Session boundary**: At the end of a work session, scan for new patterns
2. **Periodic**: Weekly or bi-weekly for knowledge health monitoring
3. **Before major work**: Scan to surface relevant prior knowledge
4. **Autonomos integration**: As part of the autonomos reflect cycle

## Interpretation Guidelines

- Promotion candidates are suggestions, not mandates. The LLM should evaluate
  whether the recurring pattern represents genuine reusable knowledge.
- Archive candidates should be reviewed before archiving. The 90-day threshold
  is a heuristic; some contexts may be intentionally long-lived.
- Consolidation candidates may represent genuinely distinct concepts that happen
  to share naming. Always verify semantic overlap before merging.
