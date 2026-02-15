---
name: layer_placement_guide
description: Guidelines for deciding which layer (L0/L1/L2) to store knowledge in KairosChain
version: "1.0"
layer: L1
tags: [meta, guide, layers, decision-making]
---

# Layer Placement Guide

This guide helps you decide which layer to store knowledge in KairosChain. The layer system exists because **not all knowledge needs the same constraints**.

## Quick Decision Tree

Ask these questions in order:

```
1. Does this modify Kairos's own rules or constraints?
   → YES: L0 (requires human approval)
   → NO: Continue to question 2

2. Is this temporary or session-specific?
   → YES: L2 (freely modifiable, no recording)
   → NO: Continue to question 3

3. Will this be reused across multiple sessions?
   → YES: L1 (hash reference recorded)
   → NO: L2
```

## Layer Characteristics

| Aspect | L0 (Constitution) | L1 (Knowledge) | L2 (Context) |
|--------|-------------------|----------------|--------------|
| **Purpose** | Kairos meta-rules | Project knowledge | Temporary work |
| **Blockchain** | Full transaction | Hash reference | None |
| **Human Approval** | Required | Not required | Not required |
| **Modification Cost** | High (intentionally) | Medium | Low |
| **Typical Lifespan** | Permanent | Long-term | Session/days |

## What Belongs Where

### L0 - Constitutional Layer

**Store here:**
- Safety constraints and invariants
- Evolution rules (how skills can be modified)
- Core philosophy and principles
- Meta-rules that govern KairosChain itself

**Do NOT store here:**
- Project-specific coding conventions
- Domain knowledge
- Anything that doesn't relate to Kairos's self-governance

**Example content:**
- `core_safety` skill (immutable)
- Evolution workflow definitions
- Layer constraint specifications

### L1 - Knowledge Layer

**Store here:**
- Project coding conventions and standards
- Architecture documentation
- Domain knowledge and patterns
- Reusable workflows and processes
- Guidelines (like this document)

**Key indicators for L1:**
- Referenced across multiple sessions
- Relatively stable (doesn't change daily)
- Valuable enough to track with hash references
- Project-specific but enduring

**Example content:**
- API design guidelines
- Error handling patterns
- Testing conventions
- This layer placement guide itself

### L2 - Context Layer

**Store here:**
- Working hypotheses and experiments
- Session scratch notes
- Trial-and-error exploration
- Temporary debugging context
- Ideas not yet validated

**Key indicators for L2:**
- May be discarded after the session
- Still being validated or explored
- Too volatile for L1 constraints
- Personal notes or reminders

**Example content:**
- "Current debugging hypothesis: the bug is in auth module"
- "Ideas to explore: caching strategies"
- "Today's refactoring plan"

## The Promotion Pattern

Knowledge can (and should) move between layers as it matures:

```
L2 (Hypothesis) → L1 (Validated Knowledge) → L0 (Meta-rule)
```

### L2 → L1 Promotion Criteria

Consider promoting when:
- Same content referenced 3+ times across sessions
- The hypothesis has been validated through use
- Others would benefit from this knowledge
- It has stabilized and won't change frequently

### L1 → L0 Promotion Criteria

This is rare and requires careful consideration:
- The knowledge governs how KairosChain itself behaves
- It defines constraints on skill modification
- It represents a mature, validated meta-pattern
- Human consensus has been reached

## Common Pitfalls

### "Everything is Important" Trap

**Problem:** Storing everything in L0 because it feels important.

**Why it's wrong:** L0 is not for "important" things—it's for "Kairos meta-rules" only. Important project knowledge belongs in L1.

**Solution:** Ask: "Does this modify how Kairos works?" If not, it's L1 or L2.

### "Just in Case" Trap

**Problem:** Storing temporary notes in L1 "just in case" they're useful later.

**Why it's wrong:** L1 changes are recorded (hash references). This creates noise in the audit trail.

**Solution:** Start with L2. Promote to L1 only when value is proven.

### "Too Abstract to Place" Trap

**Problem:** Vision/philosophy feels too abstract, so you default to L1.

**Why it's wrong:** Abstraction level ≠ Layer level. Layers are about **governance constraints**, not abstraction.

**Solution:** 
- If it governs Kairos → L0
- If it's project philosophy → L1
- If it's an evolving idea → L2

## Decision Examples

| Content | Recommended Layer | Reasoning |
|---------|-------------------|-----------|
| "AI must get human approval for L0 changes" | L0 | Kairos meta-rule |
| "Our API uses REST with JSON responses" | L1 | Project convention, reusable |
| "Maybe we should use GraphQL instead?" | L2 | Hypothesis, not validated |
| "Functions should be <50 lines" | L1 | Coding standard, stable |
| "Today I'm debugging the auth flow" | L2 | Session-specific |
| "How to decide layer placement" | L1 | Meta-guide, but not Kairos rule |
| "L0 changes require blockchain recording" | L0 | Kairos meta-rule |

## When in Doubt

**Default to L2, then promote.**

This approach:
1. Avoids premature commitment
2. Lets value prove itself through use
3. Keeps L0/L1 clean and meaningful
4. Follows the "start cheap, invest when validated" principle

---

*This guide itself is stored in L1 because it's a reusable meta-guide about KairosChain usage, but it doesn't govern Kairos's own rules (which would require L0).*
