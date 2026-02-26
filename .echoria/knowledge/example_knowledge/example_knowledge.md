---
name: example_knowledge
description: Example knowledge skill demonstrating the Anthropic skills format
version: "1.0"
layer: L1
tags: [example, documentation]
---

# Example Knowledge

This is an example knowledge skill that demonstrates the Anthropic skills format used in L1 (knowledge layer).

## Structure

Each knowledge skill follows this directory structure:

```
skill_name/
├── skill_name.md       # Required: YAML frontmatter + Markdown
├── scripts/            # Optional: Executable scripts
├── assets/             # Optional: Templates, images, resources
└── references/         # Optional: Reference materials
```

## Usage

Knowledge skills are used to store project-specific information that:

1. Is relatively stable (not changing every session)
2. Should be tracked with hash references in the blockchain
3. Can be modified by AI with lightweight constraints

## Difference from L0 (skills/kairos.rb)

- L0 contains only Kairos meta-rules (self-modification constraints)
- L1 contains project knowledge (coding rules, architecture, domain knowledge)
- L0 changes are fully recorded in blockchain
- L1 changes only record hash references
