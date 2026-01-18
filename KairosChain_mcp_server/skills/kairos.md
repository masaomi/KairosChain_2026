# KairosChain - Philosophy and Principles

| Section ID | Title | Use When |
|------------|-------|----------|
| PHILOSOPHY-010 | Core Philosophy | Understanding Kairos's fundamental vision |
| PHILOSOPHY-020 | Minimum-Nomic | Understanding the change constraint principle |
| PRINCIPLE-010 | Safety Principles | Understanding safety invariants |
| PRINCIPLE-020 | Evolution Principles | Understanding how skills evolve |
| LAYER-010 | Layer Architecture | Understanding L0/L1/L2 structure |
| LAYER-020 | Layer Constraints | Understanding constraints per layer |

---

## [PHILOSOPHY-010] Core Philosophy

### The Core Insight

The biggest black box in AI systems is:

> **The inability to explain how current capabilities were formed.**

Prompts are volatile. Tool call histories are fragmented. Skill evolution leaves no trace.
As a result, AI becomes an entity whose **causal process cannot be verified by third parties**.

### The Kairos Solution

Kairos addresses this by treating **change itself as a first-class citizen**.

```
STATE      → What exists
CHANGE     → How it's being modified
CONSTRAINT → Whether that change is permitted
```

These three concepts are explicitly separated. This structure enables:

1. **Auditable evolution** - Every change is recorded
2. **Self-referential constraints** - Skills constrain their own modification
3. **Human-AI co-evolution** - Collaborative capability development

### What Kairos Is NOT

- NOT a platform, currency, or DAO
- NOT a system that records everything
- NOT a constraint that blocks all change

Kairos is a **Meta Ledger** — an audit trail for capability evolution.

---

## [PHILOSOPHY-020] Minimum-Nomic

### The Principle

Kairos implements **Minimum-Nomic** — a system where:

- Rules (skills) **can** be changed
- But **who**, **when**, **what**, and **how** they were changed is always recorded and **cannot be erased**

### Why This Matters

This avoids both extremes:

| Approach | Problem |
|----------|---------|
| Completely fixed rules | No adaptation, system becomes obsolete |
| Unrestricted self-modification | Chaos, no accountability |

Minimum-Nomic achieves: **Evolvable but not gameable systems**.

### The Recording Guarantee

Every skill change creates a `SkillStateTransition`:

```
skill_id        → Which skill changed
prev_ast_hash   → State before change
next_ast_hash   → State after change
timestamp       → When it happened
reason_ref      → Why (off-chain reference)
```

This record is immutable. The content can change; the history cannot.

---

## [PRINCIPLE-010] Safety Principles

### Core Safety Invariants

1. **Explicit Enablement**
   - Evolution is disabled by default (`evolution_enabled: false`)
   - Must be explicitly enabled before any modification

2. **Human Approval**
   - L0 changes require human approval (`require_human_approval: true`)
   - AI can propose, but humans must confirm

3. **Blockchain Recording**
   - All L0 changes are fully recorded on the blockchain
   - Includes AST hashes, timestamps, and reason references

4. **Immutable Foundation**
   - `core_safety` skill cannot be modified (`evolve deny :all`)
   - The safety foundation must never change

### Session Limits

- Maximum evolutions per session is configurable
- Prevents runaway self-modification
- Forces deliberate, intentional changes

---

## [PRINCIPLE-020] Evolution Principles

### Self-Referential Constraint

> **Skill modification is constrained by skills themselves.**

This creates a bootstrap problem intentionally:

- To change how evolution works, you must follow evolution rules
- The rules protect themselves from unauthorized modification

### Evolution Workflow

```
1. PROPOSE  → AI suggests a change
2. REVIEW   → Human reviews (when required)
3. APPLY    → Change is applied with approved=true
4. RECORD   → Blockchain records the transition
5. RELOAD   → System reloads with new state
```

### Evolution Rules

Each skill defines its own evolution rules:

```ruby
evolve do
  allow :content           # Can modify content
  deny :behavior           # Cannot modify behavior
  deny :evolve             # Cannot modify evolution rules
end
```

### Change Cost Principle

> **Changes should be rare and high-cost.**

This is by design. L0 is not for frequent updates. For dynamic content:
- Use L1 (knowledge/) for project knowledge
- Use L2 (context/) for temporary hypotheses

---

## [LAYER-010] Layer Architecture

### The Legal System Analogy

KairosChain uses a legal-system-inspired layered architecture:

| Layer | Legal Analogy | Path | Description |
|-------|---------------|------|-------------|
| **L0-A** | Constitution | `skills/kairos.md` | Philosophy, immutable |
| **L0-B** | Law | `skills/kairos.rb` | Meta-rules, Ruby DSL |
| **L1** | Ordinance | `knowledge/` | Project knowledge |
| **L2** | Directive | `context/` | Temporary context |

### Why Layers?

> **Not all knowledge needs the same constraints.**

- Temporary thoughts shouldn't require blockchain records
- Project conventions don't need human approval for every edit
- But core safety rules must be strictly controlled

### Layer Content Guidelines

**L0 (This file + kairos.rb)**
- Kairos meta-rules only
- Self-modification constraints
- Core safety invariants

**L1 (knowledge/)**
- Project coding conventions
- Architecture documentation
- Domain knowledge
- Anthropic Skills format (YAML frontmatter + Markdown)

**L2 (context/)**
- Working hypotheses
- Session scratch notes
- Trial-and-error exploration
- Freely modifiable

---

## [LAYER-020] Layer Constraints

### Constraint Comparison

| Aspect | L0 | L1 | L2 |
|--------|----|----|----| 
| **Blockchain** | Full transaction | Hash reference only | None |
| **Human Approval** | Required | Not required | Not required |
| **Format** | Ruby DSL + MD | Anthropic Skills | Anthropic Skills |
| **Mutability** | Strictly controlled | Lightweight constraint | Free |
| **Use Case** | Meta-rules | Project knowledge | Temporary work |

### L0 Constraints (Full)

```yaml
blockchain: full           # Every field recorded
require_human_approval: true
immutable_skills: [core_safety]
```

Records include:
- `skill_id`, `prev_ast_hash`, `next_ast_hash`
- `diff_hash`, `timestamp`, `reason_ref`

### L1 Constraints (Lightweight)

```yaml
blockchain: hash_only      # Only content hash recorded
require_human_approval: false
```

Records include:
- `knowledge_id`, `content_hash`, `timestamp`

### L2 Constraints (None)

```yaml
blockchain: none
require_human_approval: false
```

No records. Free modification for exploratory work.

### Layer Placement Rules

- Only Kairos meta-skills can be in L0
- Project-specific knowledge goes to L1
- Temporary hypotheses go to L2

Attempting to add non-meta-skills to L0 will be rejected:

```
Error: Skill 'my_project_rule' is not a Kairos meta-skill.
Use knowledge_update for L1.
```

---

*This document is the constitutional foundation of KairosChain. It is read-only and should only be modified through human consensus outside of the system.*
