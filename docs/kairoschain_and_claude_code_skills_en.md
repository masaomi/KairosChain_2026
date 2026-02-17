# KairosChain and Claude Code Skills: Philosophical Positions and Read Compatibility

**Date**: 2026-02-16  
**Author**: Masaomi Hatakeyama

---

## 1. Two Different Philosophies

### Claude Code Skills: Execution-Oriented Knowledge

Claude Code's Skills system is designed around **immediate utility**. Skills, Commands, Agents, and Hooks are all tools for getting things done:

| Component | Purpose | Format |
|-----------|---------|--------|
| **Skills** (SKILL.md) | Knowledge Claude auto-references | Markdown |
| **Commands** | User-invoked prompts (`/name`) | Markdown |
| **Agents** | Specialized sub-agent personas | Markdown |
| **Hooks** | Event-driven automation | JSON + shell scripts |

Key characteristics:
- **Flat structure**: All skills are equal; no hierarchy or layers
- **No change tracking**: Modifications leave no audit trail
- **No constraints**: Any skill can be freely modified at any time
- **Immediate context**: Skills are loaded when relevant and discarded after use

Claude Code Skills answer: **"What knowledge does the AI need right now?"**

### KairosChain: Evolution-Oriented Meta-Ledger

KairosChain is designed around **auditable capability evolution**. It treats change itself as a first-class citizen:

| Layer | Legal Analogy | Change Constraint | Recording |
|-------|---------------|-------------------|-----------|
| **L0** (Constitution/Law) | Constitution | Human approval required | Full blockchain |
| **L1** (Ordinance) | Ordinance | Free (AI-modifiable) | Hash reference |
| **L2** (Directive) | Memo | Free | None per-operation |

Key characteristics:
- **Layered hierarchy**: Knowledge has different levels of protection
- **Change tracking**: Every L0/L1 modification is recorded on a private blockchain
- **Self-referential constraints**: L0 skills define rules about their own modification
- **Lifecycle management**: Staleness detection, archival, promotion between layers

KairosChain answers: **"How was this intelligence formed, and can we verify it?"**

### The Essential Difference

```
Claude Code Skills:  "Convenient knowledge documents"
KairosChain:         "An auditable ledger of knowledge evolution"
```

These are **orthogonal concerns**, not competing approaches. Claude Code manages what knowledge is used; KairosChain manages how knowledge changes over time.

---

## 2. Why KairosChain Should NOT Replicate Commands, Agents, or Hooks

### Separation of Concerns

| Responsibility | Owner |
|----------------|-------|
| What to execute (Commands, Agents, Hooks) | Claude Code |
| How knowledge evolves (layers, constraints, audit) | KairosChain |

KairosChain functions as a **meta-layer** above Claude Code's execution components. It manages the knowledge that Commands, Agents, and Hooks reference — not the execution logic itself.

An analogy:

- Claude Code Commands/Agents/Hooks = **Judges and police who apply the law**
- KairosChain = **The legislature that drafts, amends, and records laws**

The legislature does not need to perform policing or adjudication.

### Hooks Are Not Knowledge

Commands and Agents are Markdown-based and could theoretically be stored as L1 knowledge. However, Hooks are fundamentally different — they are JSON configurations that trigger shell commands on OS-level events. This is an execution concern, not a knowledge concern, and falls outside KairosChain's scope.

### Minimum-Nomic Principle

KairosChain follows the Minimum-Nomic principle: rules can change, but the minimum necessary constraints are enforced. Adding execution-layer concerns (Commands, Agents, Hooks) to KairosChain would violate this principle by expanding constraints beyond knowledge management into execution management.

---

## 3. Read Compatibility: L1 Knowledge as Claude Code Skills

While KairosChain should not replicate Claude Code's execution components, there is significant value in making L1 knowledge **readable as Claude Code Skills**. This is a one-directional compatibility:

```
KairosChain L1 knowledge  ──read──▶  Claude Code Skills
                           (OK: no audit bypass)

Claude Code  ──write──▶  KairosChain L1 knowledge
                           (NOT OK: bypasses blockchain recording)
```

### Why Read Compatibility Is Valuable

1. **Knowledge sharing without KairosChain installation**: Teams or individuals who don't use KairosChain can still benefit from well-curated L1 knowledge as standard Claude Code Skills.

2. **GitHub-based knowledge distribution**: Mature L1 knowledge can be shared via GitHub repositories. Other users `git clone` the repository and reference the knowledge as Claude Code Skills, without needing Ruby or the KairosChain MCP server.

3. **Gradual adoption**: New users can start with L1 knowledge as plain Skills, and later adopt KairosChain to gain change tracking and lifecycle management.

4. **Plugin ecosystem participation**: KairosChain's knowledge assets become discoverable through the Claude Code plugin marketplace.

### How It Works

KairosChain L1 knowledge already uses YAML frontmatter + Markdown format, which is compatible with Claude Code Skills. The key differences are:

| Field | KairosChain L1 | Claude Code Skills | Compatibility |
|-------|----------------|-------------------|---------------|
| `name` | `snake_case` | `kebab-case` | Naming convention differs |
| `description` | Present | Present | **Compatible** |
| `version` | Present | Not used | Ignored by Claude Code |
| `layer` | Present | Not used | Ignored by Claude Code |
| `tags` | Present | Not used | Ignored by Claude Code |

Claude Code ignores unknown frontmatter fields, so **KairosChain L1 files can be read as-is** by Claude Code. The only adjustment needed is directory structure:

```
KairosChain L1:           knowledge/my_knowledge/my_knowledge.md
Claude Code Skills:       skills/my-knowledge/SKILL.md
```

### Implementation Approaches

#### Approach A: Symlink or Copy (Manual)

Users who want to use L1 knowledge as Claude Code Skills can create symlinks:

```bash
# Symlink L1 knowledge into Claude Code Skills directory
ln -s /path/to/knowledge/my_knowledge/ ~/.claude/skills/my-knowledge
```

#### Approach B: Plugin Distribution

Include L1 knowledge in the plugin's `skills/` directory. The current KairosChain plugin already does this with `skills/kairos-chain/SKILL.md`.

#### Approach C: Export Tool (Future)

A potential `knowledge_export` MCP tool could export selected L1 knowledge to Claude Code Skills format, adjusting naming conventions and directory structure automatically.

### The Critical Rule: Write Goes Through KairosChain

Read compatibility does NOT mean write compatibility. All modifications to L1 knowledge must go through KairosChain's `knowledge_update` tool to ensure:

- Hash reference is recorded on the blockchain
- Change history is maintained
- Lifecycle management (staleness detection, archival) continues to function

If a user directly edits the `.md` file outside KairosChain, the blockchain record becomes inconsistent. This is by design — KairosChain's value lies in the audit trail.

---

## 4. Use Case: Sharing Mature L1 Knowledge via GitHub

A practical workflow for sharing established L1 knowledge:

```
Step 1: Knowledge matures through L2 → L1 promotion in KairosChain
        (recorded on blockchain with full audit trail)

Step 2: Stable L1 knowledge is committed to a public GitHub repository
        (e.g., "my-coding-conventions" or "genomics-analysis-patterns")

Step 3: Other users consume the knowledge in two ways:

        Option A (with KairosChain):
        - Clone/subtree the repository
        - Knowledge is tracked as L1 with full audit

        Option B (without KairosChain):
        - Clone the repository
        - Reference the .md files as Claude Code Skills
        - No audit trail, but knowledge is immediately usable
```

This approach aligns perfectly with KairosChain's philosophy:

- **Evolvable**: Knowledge evolves through the layered system
- **Auditable**: The evolution process is recorded
- **Shareable**: The result is shareable in a universally readable format
- **Non-coercive**: Recipients choose their own level of governance

---

## 5. Summary

| Aspect | Position |
|--------|----------|
| Should KairosChain replicate Commands, Agents, Hooks? | **No** — these are execution concerns, not knowledge concerns |
| Should L1 knowledge be readable as Claude Code Skills? | **Yes** — read-only compatibility enables knowledge sharing without forcing KairosChain adoption |
| Should Claude Code be able to write to L1 directly? | **No** — writes must go through KairosChain to maintain audit trail |
| Is this consistent with KairosChain's philosophy? | **Yes** — it follows the principle that knowledge should be auditable in its evolution but freely accessible in its consumption |

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*
>
> Read compatibility ensures that once we know how intelligence was formed, we can share it freely.
