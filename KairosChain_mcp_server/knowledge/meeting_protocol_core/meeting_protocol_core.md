---
name: meeting_protocol_core
layer: L0
type: protocol_definition
version: 1.0.0
bootstrap: true
immutable: true
description: MMP Core Protocol - Minimal actions required for agent communication
actions:
  - introduce
  - goodbye
  - error
---

# MMP Core Protocol

This is the **immutable core** of the Model Meeting Protocol (MMP). These actions
MUST be supported by all MMP-compliant implementations.

## Design Principles

1. **Minimal**: Only the absolute minimum for communication
2. **Immutable**: These actions cannot be changed or removed
3. **Bootstrap**: Required to negotiate additional capabilities

## Core Actions

### 1. `introduce`

**Purpose**: Establish identity and declare capabilities.

**When to use**: At the start of any communication session.

**Payload Schema**:
```json
{
  "identity": {
    "name": "string",
    "instance_id": "string",
    "scope": "string (optional)"
  },
  "capabilities": ["array of action names"],
  "extensions": ["array of extension names"],
  "constraints": {
    "allowed_formats": ["markdown"],
    "require_approval": true
  }
}
```

**Example**:
```json
{
  "action": "introduce",
  "from": "agent_abc123",
  "payload": {
    "identity": {
      "name": "KairosChain Instance",
      "instance_id": "abc123",
      "scope": "general"
    },
    "capabilities": ["introduce", "goodbye", "error", "offer_skill"],
    "extensions": ["skill_exchange"],
    "constraints": {
      "allowed_formats": ["markdown"],
      "require_approval": true
    }
  }
}
```

**Processing**:
- Store peer identity for future reference
- Note peer's capabilities for compatibility
- Respond with own `introduce` if not already done

---

### 2. `goodbye`

**Purpose**: End communication gracefully.

**When to use**: When ending a session or before disconnecting.

**Payload Schema**:
```json
{
  "reason": "string (optional)",
  "summary": "string (optional)"
}
```

**Valid reasons**:
- `session_complete`: Normal completion
- `timeout`: Session timeout
- `user_request`: User requested disconnect
- `error`: Ending due to error
- `maintenance`: Server maintenance

**Example**:
```json
{
  "action": "goodbye",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "reason": "session_complete",
    "summary": "Exchanged 2 skills successfully"
  }
}
```

**Processing**:
- Clean up session state
- Log interaction summary if provided
- Close connection gracefully

---

### 3. `error`

**Purpose**: Report an error condition.

**When to use**: When an error occurs that the peer should know about.

**Payload Schema**:
```json
{
  "error_code": "string",
  "message": "string",
  "recoverable": "boolean",
  "details": "object (optional)"
}
```

**Standard error codes**:
- `unsupported_action`: Action not recognized
- `invalid_payload`: Payload validation failed
- `unauthorized`: Not authorized for this action
- `rate_limited`: Too many requests
- `internal_error`: Internal processing error
- `protocol_version_mismatch`: Incompatible protocol version

**Example**:
```json
{
  "action": "error",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "in_reply_to": "msg_previous123",
  "payload": {
    "error_code": "unsupported_action",
    "message": "Action 'debate' is not supported by this agent",
    "recoverable": true,
    "details": {
      "unsupported_action": "debate",
      "suggested_action": "Use 'introduce' to check capabilities first"
    }
  }
}
```

**Processing**:
- Log the error
- If recoverable, continue session
- If not recoverable, prepare to close session

---

## Message Envelope

All MMP messages use this envelope format:

```json
{
  "id": "msg_<16 hex chars>",
  "action": "<action name>",
  "from": "<sender agent_id>",
  "to": "<recipient agent_id or null>",
  "timestamp": "<ISO 8601 UTC>",
  "protocol_version": "1.0.0",
  "payload": { ... },
  "in_reply_to": "<message id or null>"
}
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique message identifier |
| `action` | string | Action type |
| `from` | string | Sender's agent ID |
| `timestamp` | string | ISO 8601 timestamp (UTC) |
| `protocol_version` | string | MMP version |
| `payload` | object | Action-specific data |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `to` | string | Recipient's agent ID (null for broadcast) |
| `in_reply_to` | string | ID of message being responded to |

---

## Extension Mechanism

The Core Protocol supports extensions through the `introduce` action.

### Advertising Extensions

```json
{
  "action": "introduce",
  "payload": {
    "extensions": ["skill_exchange", "discussion"]
  }
}
```

### Extension Namespaces

- **Standard extensions**: Single word (e.g., `skill_exchange`)
- **Custom extensions**: Namespaced (e.g., `org.example.custom`)

### Compatibility Rules

1. Agents MUST support all Core Actions
2. Agents SHOULD gracefully handle unknown actions (return `error`)
3. Agents use the intersection of supported extensions

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-30 | Initial release |
