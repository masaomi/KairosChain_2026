---
name: meeting_protocol_skill_exchange
layer: L1
type: protocol_extension
version: 1.0.0
bootstrap: false
extends: meeting_protocol_core
description: MMP Skill Exchange Extension - Actions for exchanging skills between agents
actions:
  - offer_skill
  - request_skill
  - accept
  - decline
  - skill_content
  - reflect
requires:
  - meeting_protocol_core
---

# MMP Skill Exchange Extension

This extension enables agents to **exchange skills** (capabilities, knowledge, patterns).
It builds on the Core Protocol and provides a structured way to offer, request,
and transfer skills between agents.

## Design Principles

1. **Safety First**: Only markdown by default, no executable code
2. **Consent-based**: Both parties must agree before transfer
3. **Traceable**: All exchanges are logged with provenance
4. **Reversible**: Received skills can be rejected/removed

## Extension Actions

### 1. `offer_skill`

**Purpose**: Offer a skill to another agent.

**Payload Schema**:
```json
{
  "skill_id": "string",
  "skill_name": "string",
  "skill_summary": "string",
  "skill_format": "string",
  "content_hash": "string (sha256:...)",
  "tags": ["array of strings (optional)"],
  "layer": "string (L0/L1/L2, optional)"
}
```

**Valid formats**:
- `markdown` (default, safe)
- `yaml` (configuration)
- `json` (data)
- `ruby` (requires explicit approval)
- `python` (requires explicit approval)

**Example**:
```json
{
  "action": "offer_skill",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "skill_id": "translation_patterns",
    "skill_name": "Translation Patterns",
    "skill_summary": "Common patterns for multilingual translation tasks",
    "skill_format": "markdown",
    "content_hash": "sha256:a1b2c3d4...",
    "tags": ["translation", "multilingual"],
    "layer": "L1"
  }
}
```

**Processing**:
- Check if format is allowed by recipient's policy
- Store offer for reference
- Recipient decides to `accept` or `decline`

---

### 2. `request_skill`

**Purpose**: Request a skill from another agent.

**Payload Schema**:
```json
{
  "description": "string",
  "accepted_formats": ["array of format strings"],
  "tags": ["array of strings (optional)"],
  "urgency": "string (optional: low/normal/high)"
}
```

**Example**:
```json
{
  "action": "request_skill",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "description": "Looking for a skill about code review best practices",
    "accepted_formats": ["markdown"],
    "tags": ["code-review", "best-practices"],
    "urgency": "normal"
  }
}
```

**Processing**:
- Search available skills matching description
- If match found, respond with `offer_skill`
- If no match, respond with `decline`

---

### 3. `accept`

**Purpose**: Accept an offer or indicate willingness to fulfill a request.

**Payload Schema**:
```json
{
  "accepted": true,
  "message": "string (optional)",
  "conditions": "object (optional)"
}
```

**Example**:
```json
{
  "action": "accept",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_offer123",
  "payload": {
    "accepted": true,
    "message": "Offer accepted. Please send the skill content."
  }
}
```

**Processing**:
- If accepting an `offer_skill`: Prepare to receive `skill_content`
- If accepting a `request_skill`: Send `skill_content`

---

### 4. `decline`

**Purpose**: Decline an offer or request.

**Payload Schema**:
```json
{
  "accepted": false,
  "reason": "string (optional)",
  "alternative": "string (optional)"
}
```

**Valid reasons**:
- `format_not_accepted`: Format not in allowed list
- `skill_not_available`: Requested skill doesn't exist
- `policy_violation`: Against exchange policy
- `capacity_exceeded`: Too many pending exchanges
- `user_declined`: Human declined the exchange

**Example**:
```json
{
  "action": "decline",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_offer123",
  "payload": {
    "accepted": false,
    "reason": "format_not_accepted",
    "alternative": "Please offer in markdown format instead"
  }
}
```

**Processing**:
- Clean up pending offers/requests
- Log the decline with reason

---

### 5. `skill_content`

**Purpose**: Send the actual skill content after acceptance.

**Payload Schema**:
```json
{
  "skill_id": "string",
  "skill_name": "string",
  "format": "string",
  "content": "string",
  "content_hash": "string (sha256:...)",
  "provenance": {
    "origin": "string",
    "chain": ["array of agent_ids"],
    "hop_count": "number"
  }
}
```

**Example**:
```json
{
  "action": "skill_content",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "in_reply_to": "msg_accept456",
  "payload": {
    "skill_id": "translation_patterns",
    "skill_name": "Translation Patterns",
    "format": "markdown",
    "content": "# Translation Patterns\n\n## Pattern 1: Context Preservation\n...",
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
1. Verify `content_hash` matches actual content
2. Validate format against policy
3. Store skill in appropriate layer (usually L2 first)
4. Record provenance for audit trail
5. Respond with `reflect`

---

### 6. `reflect`

**Purpose**: Post-interaction reflection and acknowledgment.

**Payload Schema**:
```json
{
  "reflection": "string",
  "interaction_summary": {
    "referenced_message": "string",
    "skill_received": "string (optional)",
    "evaluation": "string (optional: positive/neutral/negative)"
  },
  "learned": ["array of strings (optional)"]
}
```

**Example**:
```json
{
  "action": "reflect",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_content789",
  "payload": {
    "reflection": "Thank you for sharing the translation patterns. They will be useful for multilingual tasks.",
    "interaction_summary": {
      "referenced_message": "msg_content789",
      "skill_received": "translation_patterns",
      "evaluation": "positive"
    },
    "learned": ["context preservation", "cultural adaptation"]
  }
}
```

**Processing**:
- Log the reflection
- Mark interaction as complete
- Update peer relationship (trust, frequency)

---

## Exchange Flow

```
Agent A                                    Agent B
   │                                          │
   │────── introduce ────────────────────────▶│
   │◀───── introduce ─────────────────────────│
   │                                          │
   │────── offer_skill ──────────────────────▶│
   │                                          │
   │                                          │ (check policy)
   │                                          │
   │◀───── accept ────────────────────────────│
   │                                          │
   │────── skill_content ────────────────────▶│
   │                                          │
   │                                          │ (verify & store)
   │                                          │
   │◀───── reflect ───────────────────────────│
   │                                          │
   │────── goodbye ──────────────────────────▶│
   │◀───── goodbye ───────────────────────────│
```

---

## Safety Configuration

```yaml
# config/meeting.yml
skill_exchange:
  # Allowed formats (others are rejected)
  allowed_formats:
    - markdown
  
  # Require human approval for each exchange
  require_approval: true
  
  # Auto-accept from trusted peers
  auto_accept_from:
    - trusted_agent_id
  
  # Maximum pending exchanges
  max_pending: 10
  
  # Provenance requirements
  require_provenance: true
  max_hop_count: 5
```

---

## Provenance Tracking

Every skill transfer includes provenance information:

```json
{
  "provenance": {
    "origin": "agent_original_creator",
    "chain": ["agent_1", "agent_2", "agent_3"],
    "hop_count": 2,
    "first_seen": "2026-01-15T10:00:00Z",
    "signatures": ["sig_1", "sig_2"]
  }
}
```

This enables:
- Tracing skill origins
- Detecting unauthorized modifications
- Building trust networks
- Auditing skill propagation

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-30 | Initial release |
