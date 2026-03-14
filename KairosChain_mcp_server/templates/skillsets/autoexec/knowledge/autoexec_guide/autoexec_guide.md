---
title: AutoExec SkillSet Guide
tags: [autoexec, task-planning, semi-autonomous, execution]
version: 0.1.0
---

# AutoExec SkillSet Guide

## Overview

AutoExec enables semi-autonomous task planning and execution with constitutive
chain recording. It decomposes tasks into structured DSL plans, classifies risk,
and executes with graduated approval.

## Quick Start

### 1. Create a Plan

Provide a JSON task decomposition to `autoexec_plan`:

```json
{
  "task_id": "add_mcp_tool",
  "meta": { "description": "Add token_balance MCP tool", "risk_default": "medium" },
  "steps": [
    { "step_id": "analyze", "action": "read existing tool patterns", "risk": "low" },
    { "step_id": "implement", "action": "create tool file", "risk": "medium", "depends_on": ["analyze"] },
    { "step_id": "test", "action": "write and run tests", "risk": "medium", "depends_on": ["implement"] }
  ]
}
```

### 2. Review and Dry Run

Use the returned `plan_hash` to dry-run:

```
autoexec_run(task_id: "add_mcp_tool", mode: "dry_run", approved_hash: "<hash>")
```

### 3. Execute

After reviewing the dry run, switch to execute mode:

```
autoexec_run(task_id: "add_mcp_tool", mode: "execute", approved_hash: "<hash>")
```

## Safety Model

- **Dry-run default**: All plans start in dry_run mode
- **Hash-locked plans**: Plans are SHA-256 hashed at creation; execution verifies the hash
- **L0 deny-list**: Operations like L0 evolution and chain modification are always blocked
- **Protected files**: Writes to config files force :high risk classification
- **Human cognition markers**: Steps with `requires_human_cognition: true` halt execution

## Risk Classification

| Level | Auto-execute | Examples |
|-------|-------------|---------|
| Low | Yes | read, search, analyze, list |
| Medium | With approval | edit, create, test, build |
| High | Individual approval | delete, push, deploy |
