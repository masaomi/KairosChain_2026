# KairosChain Beginner's Guide

*"A time machine that gives AI agents reliable memory and the power to evolve."*

This guide is written so anyone — even without development experience — can understand what makes KairosChain special.

---

## Table of Contents

1. AI Runs on "Skills"
2. Change a Skill, Change the AI
3. The Problem: AI Memory Is Surprisingly Fragile
4. The Solution: A Tamper-Proof "AI Time Machine"
5. Skills Have a "Constitution" (L0/L1/L2 Architecture)
6. The AI That Teaches Itself (Self-Referentiality)
7. Agents Holding "Meetings" (MMP)
8. Plugin or Clone?
9. Setup
10. Summary

---

## 1. AI Runs on "Skills"

When you ask an AI like ChatGPT or Claude to "write some Python code," it delivers. But how does the AI know your project's specific rules or your personal preferences?

An AI on its own is a massive prediction machine, but it isn't optimized for your work out of the box. That's where **Skills** come in — concrete "job manuals" you give to the AI.

---

## 2. Change a Skill, Change the AI

Rewriting a skill dramatically changes the AI's output.
Swap out "always use polite language" for "respond like a pirate," and the AI's entire personality shifts in an instant.

In other words, **skills are the AI's "blueprint for its soul."**

---

## 3. The Problem: AI Memory Is Surprisingly Fragile

Traditional AI development had a critical blind spot:

- Who changed that skill, when, and why?
- What did it look like before?

None of this was recorded anywhere.
"The AI was so much smarter last month — what happened?" You'd wonder, but no one could ever pinpoint why its behavior had changed.

---

## 4. The Solution: A Tamper-Proof "AI Time Machine"

KairosChain records every change to an AI's skills on a blockchain.

A blockchain links data using "fingerprints" (hash values). If you try to alter even one character from the past, the fingerprints no longer match — making it an **"absolutely lie-proof ledger."**

This means that when an AI starts acting up, you can travel back in time and pinpoint exactly: "That day, someone changed this skill like this — that's the cause!"

---

## 5. Skills Have a "Constitution" (L0/L1/L2 Architecture)

Not all skills in KairosChain carry equal weight. Just as a country has a hierarchy of laws, skills have layers.

**This is not just a metaphor — it is actually implemented in code in `layer_registry.rb`.**
Whenever the AI tries to modify a skill, the code automatically checks and enforces the appropriate restrictions.

| Layer | Legal Analogy | Role | How to Change It |
|-------|--------------|------|-----------------|
| **L0-A** | Constitution | `kairos.md`: The foundational philosophy of KairosChain. Absolutely immutable. | **Cannot be changed** (blocked by code) |
| **L0-B** | Statute | `kairos.rb`: Defines the rules of evolution itself. | **Human approval + full blockchain record** required |
| **L1** | Ordinance | `knowledge/`: Project knowledge and policies. | Changeable. Only the change hash is recorded. |
| **L2** | Directive | `context/`: Temporary notes for the current task. | Freely changeable. No record kept. |

This hierarchy ensures that **"how far you can go" is enforced at the code level, preventing AI from running amok.**
Any change to L0-B must be approved by a human and is permanently recorded on the blockchain.

### Humans Decide the Layer — By Choosing a Folder

Layer assignment is determined entirely by **which folder a file is placed in**. KairosChain reads the path and automatically determines the layer — no special tags need to be written inside the file.

```
.kairos/
├── skills/     ← anything here is treated as L0
├── knowledge/  ← anything here is treated as L1
└── context/    ← anything here is treated as L2
```

The judgment call — "this file is important enough to be L1" — is made **by the human**. KairosChain simply respects that decision and applies the rules for that folder.

**L0 is the one exception.** Even if you place a file in `skills/`, the code will reject it unless the skill name appears on a pre-approved list of meta-skills. This is a double-check to prevent anyone from accidentally (or intentionally) smuggling an unimportant file into the constitutional layer.

---

## 6. The AI That Teaches Itself (Self-Referentiality)

One of the most fascinating things about KairosChain is that **"the AI knows how to use itself."** This property is called **Self-Referentiality**.

Even if you have no idea how to use it, just ask the AI connected to KairosChain: "How are you supposed to be used?" The AI will read its own stored "blueprint" from inside KairosChain and explain it to you clearly.

---

## 7. Agents Holding "Meetings" (MMP)

The world is moving from "one AI" to "many AIs (agents) working together." KairosChain introduces **MMP (Model Meeting Protocol)** — a protocol that lets agents communicate with each other.

> **Agent A:** "I came up with a new work rule (skill)!"
> **Agent B:** "Nice, share that skill with me. Let's work together under that rule from now on."

Through KairosChain, AIs can exchange new capabilities with each other and grow autonomously as a team — no human intervention required.

On top of that, by running a **HestiaChain** "Meeting Place" server, KairosChain agents across the internet can discover each other and share skills.

---

## 8. Plugin or Clone?

There are two ways to use KairosChain.

### Use It as a Plugin

Best for people who just want to use it as a tool.
This method adds KairosChain to AI tools like Claude Code as an extension (plugin).

- **What's a plugin?**: A component that bolts new functionality (KairosChain's recording capability) onto existing software (like Claude Code). Think of it like installing an app on your phone.
- **Advantage**: Extremely easy to set up.
- **What it does**: Adds new commands (tools) to your AI — like "record history" and "check the history."

### Clone the Repository

Best for developers who want to dig into the internals or customize things.
This method copies the source code from GitHub to your own PC and runs it from there.

- **Advantage**: You can directly edit the internal Ruby code and build your own custom KairosChain.
- **What it does**: Since you have the program itself, you can improve it and even submit a pull request.

---

## 9. Setup

### A. As a Plugin (Claude Code)

If you're using Claude Code, you can add KairosChain directly from the marketplace.
Note: **Ruby 3.0+** and the gem must be installed beforehand for full functionality.

```bash
# Prerequisite: install the gem if Ruby is available
gem install kairos-chain

# Add KairosChain to the marketplace
/plugin marketplace add https://github.com/masaomi/KairosChain_2026.git

# Install the plugin
/plugin install kairos-chain
```

### B. Direct Installation (Ruby Environment)

If you have Ruby available, installing via gem is the fastest option.

```bash
# Install the gem
gem install kairos-chain

# Initialize (required files are created automatically)
kairos-chain init

# Register as an MCP server in Claude Code
claude mcp add kairos-chain kairos-chain

# Confirm registration
claude mcp list
```

After restarting Claude Code, 29+ KairosChain tools will be available.

---

## 10. Summary

- AI runs on "skills" — concrete manuals that shape its behavior
- Every change is recorded on a blockchain, creating a permanent, tamper-proof history
- Skills have an L0/L1/L2 hierarchy — constitutional-level rules cannot be changed by anyone
- The AI understands how to use itself (self-referentiality)
- Agents exchange new skills and grow autonomously as a team (MMP)
- With the plugin, you can supercharge your AI in seconds!

KairosChain is the foundation for transforming AI from a mere "handy tool" into a **"trustworthy partner that evolves autonomously."**
