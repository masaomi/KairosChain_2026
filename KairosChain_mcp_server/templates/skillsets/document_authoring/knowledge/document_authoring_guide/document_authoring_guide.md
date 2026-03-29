---
tags: [document, authoring, grant, writing, agent, ooda]
version: "1.0"
---

# Document Authoring Guide

## Overview

The `document_authoring` SkillSet provides LLM-driven document section generation
with L1/L2 context injection. It integrates with the Agent SkillSet's OODA loop
via autoexec's `internal_execute` dispatcher — no Agent or autoexec changes required.

## Tools

### write_section

Generates a document section using an LLM, with optional context from L1 knowledge
and L2 session contexts.

```json
{
  "section_name": "research_significance",
  "instructions": "Explain why genomic data ownership matters for open science",
  "context_sources": ["knowledge://genomicschain_design"],
  "output_file": "grant_draft/02_significance.md",
  "max_words": 500,
  "language": "en"
}
```

### document_status

Lists existing draft files with word counts. Non-recursive directory scan.

```json
{
  "output_dir": "grant_draft/"
}
```

## Agent Integration

When used with the Agent SkillSet, the workflow is:

1. Create L1 knowledge with the document goal (e.g., grant requirements)
2. Start Agent session: `agent_start(goal_name: "grant_application_uzh")`
3. Agent ORIENT identifies required sections from the goal
4. Agent DECIDE generates task steps with `tool_name: "write_section"`
5. Human approves the plan at [proposed] checkpoint
6. Agent ACT executes write_section for each section via autoexec
7. Agent REFLECT evaluates completeness

## Context Sources

Use the platform URI scheme:

- `knowledge://genomicschain_design` — L1 knowledge
- `context://session_id/context_name` — L2 session context

## Output

Generated text is written directly to the specified file (no JSON wrapper).
Files are created under the workspace root with symlink-safe path validation.
