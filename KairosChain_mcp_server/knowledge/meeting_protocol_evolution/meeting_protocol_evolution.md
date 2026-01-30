---
name: meeting_protocol_evolution
layer: L1
type: protocol_extension
version: 1.0.0
bootstrap: false
extends: meeting_protocol_core
description: MMP Protocol Evolution Extension - Actions for protocol co-evolution between agents
actions:
  - propose_extension
  - evaluate_extension
  - adopt_extension
  - share_extension
requires:
  - meeting_protocol_core
  - meeting_protocol_skill_exchange
---

# MMP Protocol Evolution Extension

This extension enables **protocol co-evolution** - the ability for agents to
propose, evaluate, adopt, and share protocol extensions with each other.

## Design Principles

1. **Safety First**: All new extensions go to L2 (experimental) first
2. **Human Approval**: Promotion to L1 requires human confirmation
3. **Graceful Degradation**: Agents can still communicate without shared extensions
4. **Auditability**: All evolution actions are logged

## Evolution Actions

### 1. `propose_extension`

**Purpose**: Propose a new protocol extension to another agent.

**When to use**: When you have an extension that might be useful to a peer.

**Payload Schema**:
```json
{
  "extension_name": "string",
  "extension_version": "string",
  "extension_type": "protocol_extension",
  "actions": ["array of action names"],
  "requires": ["array of required extensions"],
  "description": "string",
  "content_hash": "sha256:...",
  "layer": "L2"
}
```

**Example**:
```json
{
  "action": "propose_extension",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "extension_name": "meeting_protocol_debate",
    "extension_version": "1.0.0",
    "extension_type": "protocol_extension",
    "actions": ["propose_topic", "argue_for", "argue_against", "conclude"],
    "requires": ["meeting_protocol_core"],
    "description": "Enables structured debate between agents",
    "content_hash": "sha256:a1b2c3d4...",
    "layer": "L2"
  }
}
```

**Processing**:
- Recipient evaluates the proposal
- If interested, responds with `evaluate_extension`
- If not interested, responds with `decline`

---

### 2. `evaluate_extension`

**Purpose**: Request the full extension content for evaluation.

**When to use**: After receiving a `propose_extension` that looks interesting.

**Payload Schema**:
```json
{
  "extension_name": "string",
  "content_hash": "string",
  "evaluation_intent": "string (adopt|review|archive)"
}
```

**Example**:
```json
{
  "action": "evaluate_extension",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_propose123",
  "payload": {
    "extension_name": "meeting_protocol_debate",
    "content_hash": "sha256:a1b2c3d4...",
    "evaluation_intent": "adopt"
  }
}
```

**Processing**:
- Sender provides full extension content via `share_extension`
- Recipient performs safety and compatibility checks
- Recipient decides to `adopt_extension` or `decline`

---

### 3. `adopt_extension`

**Purpose**: Confirm adoption of an extension after evaluation.

**When to use**: After receiving and validating extension content.

**Payload Schema**:
```json
{
  "extension_name": "string",
  "content_hash": "string",
  "adopted_layer": "L2",
  "evaluation_result": {
    "safety_check": "passed|failed",
    "compatibility_check": "passed|failed",
    "notes": "string (optional)"
  }
}
```

**Example**:
```json
{
  "action": "adopt_extension",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_share456",
  "payload": {
    "extension_name": "meeting_protocol_debate",
    "content_hash": "sha256:a1b2c3d4...",
    "adopted_layer": "L2",
    "evaluation_result": {
      "safety_check": "passed",
      "compatibility_check": "passed",
      "notes": "Will evaluate for 7 days before considering promotion"
    }
  }
}
```

**Processing**:
- Extension is stored in L2 (experimental)
- Sender is notified of successful adoption
- Extension enters evaluation period

---

### 4. `share_extension`

**Purpose**: Send the full content of an extension.

**When to use**: In response to `evaluate_extension` request.

**Payload Schema**:
```json
{
  "extension_name": "string",
  "extension_version": "string",
  "content": "string (full markdown content)",
  "content_hash": "sha256:...",
  "provenance": {
    "origin": "string (original creator)",
    "chain": ["array of agent_ids"],
    "hop_count": "number"
  }
}
```

**Example**:
```json
{
  "action": "share_extension",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "in_reply_to": "msg_evaluate789",
  "payload": {
    "extension_name": "meeting_protocol_debate",
    "extension_version": "1.0.0",
    "content": "---\nname: meeting_protocol_debate\n...",
    "content_hash": "sha256:a1b2c3d4...",
    "provenance": {
      "origin": "agent_original",
      "chain": ["agent_original", "agent_abc123"],
      "hop_count": 1
    }
  }
}
```

**Processing**:
- Recipient verifies content hash
- Recipient performs evaluation
- Recipient responds with `adopt_extension` or `decline`

---

## Evolution Flow

```
Agent A (has extension)              Agent B (wants extension)
        │                                      │
        │──── propose_extension ──────────────▶│
        │                                      │
        │                                      │ (review proposal)
        │                                      │
        │◀─── evaluate_extension ──────────────│
        │                                      │
        │──── share_extension ────────────────▶│
        │                                      │
        │                                      │ (safety check)
        │                                      │ (compatibility check)
        │                                      │ (store in L2)
        │                                      │
        │◀─── adopt_extension ─────────────────│
        │                                      │
        │                                      │
       ...        7 days later               ...
        │                                      │
        │                                      │ (human approves)
        │                                      │ (promote to L1)
        │                                      │
        │                                      │ Agent B now has the extension!
        │                                      │ Can share with Agent C...
```

---

## Safety Configuration

```yaml
# config/meeting.yml
protocol_evolution:
  # Automatically evaluate proposed extensions
  auto_evaluate: true
  
  # Days to keep extension in L2 before promotion eligible
  evaluation_period_days: 7
  
  # Allow automatic promotion (NOT RECOMMENDED)
  auto_promote: false
  
  # Actions that are NEVER allowed in extensions
  blocked_actions:
    - execute_code
    - system_command
    - file_write
    - shell_exec
    - eval
  
  # Maximum actions per extension
  max_actions_per_extension: 20
  
  # Require human approval for L1 promotion
  require_human_approval_for_l1: true
```

---

## Extension Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│                    Extension Lifecycle                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   [Proposed] ──▶ [Evaluating] ──▶ [Adopted (L2)]            │
│       │              │                  │                    │
│       │              │                  ▼                    │
│       │              │         [Pending Promotion]           │
│       │              │                  │                    │
│       │              │                  │ (human approval)   │
│       │              │                  ▼                    │
│       │              │          [Promoted (L1)]              │
│       │              │                  │                    │
│       ▼              ▼                  ▼                    │
│   [Rejected]    [Rejected]         [Disabled]               │
│                                         │                    │
│                                         ▼                    │
│                                    [Re-enabled]              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Provenance Tracking

Every shared extension includes provenance information:

```json
{
  "provenance": {
    "origin": "agent_original_creator",
    "chain": ["agent_1", "agent_2", "agent_3"],
    "hop_count": 2,
    "first_seen": "2026-01-30T10:00:00Z"
  }
}
```

This enables:
- Tracing extension origins
- Detecting unauthorized modifications
- Building trust networks
- Auditing extension propagation

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-30 | Initial release |
