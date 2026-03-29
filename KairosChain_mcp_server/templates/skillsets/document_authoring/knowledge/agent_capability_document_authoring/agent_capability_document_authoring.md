---
tags: [agent-capability, document-authoring]
version: "1.0"
---

# Agent Capability: Document Authoring

## When to use

The user asks to write, draft, or create structured documents such as:
- Grant applications (e.g., UZH fellowship, SNF, ERC)
- Research papers or manuscripts
- Technical reports
- Project proposals

Keywords: write, draft, create, application, grant, paper, report, proposal, document

## Tools

- `write_section`: Write a document section using LLM with L1/L2 context injection
- `document_status`: Check existing draft files and word counts

## Typical task pattern

```json
{
  "task_id": "write_grant_draft",
  "meta": { "description": "Write grant application sections", "risk_default": "low" },
  "steps": [
    {
      "step_id": "write_abstract",
      "action": "Write project abstract",
      "tool_name": "write_section",
      "tool_arguments": {
        "section_name": "abstract",
        "instructions": "Write a concise project abstract covering motivation, approach, and expected impact",
        "context_sources": ["knowledge://project_description"],
        "output_file": "grant_draft/01_abstract.md",
        "max_words": 250
      },
      "risk": "low", "depends_on": []
    },
    {
      "step_id": "check_status",
      "action": "Verify all sections written",
      "tool_name": "document_status",
      "tool_arguments": { "output_dir": "grant_draft/" },
      "risk": "low", "depends_on": ["write_abstract"]
    }
  ]
}
```

## Context sources

Use `knowledge://` URIs for project-level context and `context://` URIs for
session-specific context (e.g., previous grant feedback).
