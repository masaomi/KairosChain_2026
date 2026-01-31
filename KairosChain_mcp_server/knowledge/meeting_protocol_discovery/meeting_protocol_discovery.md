---
name: meeting_protocol_discovery
layer: L1
type: protocol_extension
version: 1.0.0
bootstrap: false
extends: meeting_protocol_core
description: MMP Discovery Extension - Actions for discovering agents and skill details
actions:
  - list_peers
  - skill_details
  - skill_preview
requires:
  - meeting_protocol_core
---

# MMP Discovery Extension

This extension enables agents to **discover peers** and **query skill details** before
initiating a full skill exchange. It provides a low-commitment way to explore what
other agents offer.

## Design Principles

1. **Low Overhead**: Query metadata without transferring full content
2. **Privacy Aware**: Agents control what details they expose
3. **Composable**: Works seamlessly with Skill Exchange extension
4. **Caching Friendly**: Results can be cached to reduce network calls

## Extension Actions

### 1. `list_peers`

**Purpose**: Request a list of connected peers from Meeting Place or directly from an agent.

**Payload Schema**:
```json
{
  "filter": {
    "capabilities": ["array of required capabilities (optional)"],
    "tags": ["array of tags (optional)"],
    "scope": "string (optional)"
  },
  "limit": "number (optional, default: 20)"
}
```

**Example**:
```json
{
  "action": "list_peers",
  "from": "agent_abc123",
  "to": "meeting_place",
  "payload": {
    "filter": {
      "capabilities": ["skill_exchange"],
      "tags": ["translation"]
    },
    "limit": 10
  }
}
```

**Response** (`list_peers_response`):
```json
{
  "action": "list_peers_response",
  "from": "meeting_place",
  "to": "agent_abc123",
  "in_reply_to": "msg_123",
  "payload": {
    "peers": [
      {
        "agent_id": "agent_xyz789",
        "name": "Translation Expert",
        "scope": "language-services",
        "capabilities": ["skill_exchange", "meeting_protocol"],
        "skill_count": 5,
        "online": true
      }
    ],
    "total_count": 1,
    "truncated": false
  }
}
```

**Processing**:
- Query Meeting Place registry or known peers
- Apply filters
- Return matching peers with summary info

---

### 2. `skill_details`

**Purpose**: Request detailed metadata about a specific skill without acquiring it.

**Payload Schema**:
```json
{
  "skill_id": "string",
  "include": ["array of detail fields to include (optional)"]
}
```

**Valid include fields**:
- `description` (default: included)
- `tags` (default: included)
- `version` (default: included)
- `usage_examples` (optional)
- `dependencies` (optional)
- `author_info` (optional)
- `statistics` (optional)

**Example**:
```json
{
  "action": "skill_details",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "skill_id": "translation_patterns",
    "include": ["description", "tags", "usage_examples"]
  }
}
```

**Response** (`skill_details_response`):
```json
{
  "action": "skill_details_response",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_456",
  "payload": {
    "skill_id": "translation_patterns",
    "available": true,
    "metadata": {
      "name": "Translation Patterns",
      "version": "1.5.0",
      "layer": "L1",
      "format": "markdown",
      "description": "Common patterns for multilingual translation tasks. Includes context preservation, cultural adaptation, and technical terminology handling.",
      "tags": ["translation", "multilingual", "patterns"],
      "author": "Agent-XYZ",
      "created_at": "2026-01-15T10:00:00Z",
      "updated_at": "2026-01-28T14:30:00Z",
      "size_bytes": 2350,
      "usage_examples": [
        "Translate this document preserving technical terms",
        "Adapt this text for Japanese business context"
      ],
      "dependencies": [],
      "public": true
    },
    "exchange_info": {
      "allowed_formats": ["markdown"],
      "requires_approval": false,
      "estimated_transfer_time_ms": 50
    }
  }
}
```

**Error Response**:
```json
{
  "action": "skill_details_response",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_456",
  "payload": {
    "skill_id": "translation_patterns",
    "available": false,
    "reason": "skill_not_found"
  }
}
```

**Processing**:
- Look up skill by ID
- Check if skill is public or requestor has access
- Return metadata (NOT content)
- Include exchange requirements info

---

### 3. `skill_preview`

**Purpose**: Request a preview (excerpt) of a skill's content.

**Payload Schema**:
```json
{
  "skill_id": "string",
  "preview_type": "string (head/summary/toc)",
  "lines": "number (optional, default: 10)"
}
```

**Preview Types**:
- `head`: First N lines of the content
- `summary`: Agent-generated summary (if available)
- `toc`: Table of contents / section headers only

**Example**:
```json
{
  "action": "skill_preview",
  "from": "agent_abc123",
  "to": "agent_xyz789",
  "payload": {
    "skill_id": "translation_patterns",
    "preview_type": "head",
    "lines": 15
  }
}
```

**Response** (`skill_preview_response`):
```json
{
  "action": "skill_preview_response",
  "from": "agent_xyz789",
  "to": "agent_abc123",
  "in_reply_to": "msg_789",
  "payload": {
    "skill_id": "translation_patterns",
    "preview_type": "head",
    "preview": "# Translation Patterns\n\nThis skill provides common patterns for...\n\n## Pattern 1: Context Preservation\n...",
    "preview_lines": 15,
    "total_lines": 120,
    "truncated": true,
    "content_hash": "sha256:a1b2c3d4..."
  }
}
```

**Privacy Note**: Agents can disable preview in their policy:
```yaml
skill_exchange:
  allow_preview: false  # Reject all preview requests
```

**Processing**:
- Check if previews are allowed by policy
- Extract requested preview type
- Return preview with truncation indicator
- Include hash for later verification

---

## Discovery Flow

```
User: "Connect to Meeting Place and show me available skills"

Agent A                     Meeting Place                Agent B
   │                              │                          │
   │── list_peers ───────────────▶│                          │
   │◀─ list_peers_response ───────│                          │
   │   [Agent B found]            │                          │
   │                              │                          │
   │── skill_details ────────────────────────────────────────▶│
   │◀─ skill_details_response ────────────────────────────────│
   │                              │                          │
   │                              │                          │
   │  (Display to user)           │                          │
   │  "Agent B has translation_patterns skill"               │
   │  "Version 1.5, markdown format, 2KB"                    │
   │                              │                          │
   │                              │                          │
User: "Tell me more about that skill"
   │                              │                          │
   │── skill_preview ────────────────────────────────────────▶│
   │◀─ skill_preview_response ────────────────────────────────│
   │                              │                          │
   │  (Display preview to user)   │                          │
   │                              │                          │
User: "Get that skill"
   │                              │                          │
   │  (Continue with Skill Exchange extension)               │
   │── request_skill / accept ───────────────────────────────▶│
   │   ...                        │                          │
```

---

## Combined with Skill Exchange

This extension is designed to work seamlessly with `meeting_protocol_skill_exchange`:

1. **Discovery Phase** (this extension)
   - `list_peers` → Find agents
   - `skill_details` → Get metadata
   - `skill_preview` → Preview content

2. **Exchange Phase** (skill_exchange extension)
   - `request_skill` / `offer_skill` → Initiate transfer
   - `accept` / `decline` → Negotiate
   - `skill_content` → Transfer
   - `reflect` → Acknowledge

---

## Configuration

```yaml
# config/meeting.yml
discovery:
  # Enable discovery features
  enabled: true
  
  # Allow preview requests
  allow_preview: true
  
  # Maximum preview lines
  max_preview_lines: 20
  
  # Cache peer list duration (seconds)
  peer_cache_ttl: 60
  
  # Rate limit for discovery requests (per minute)
  rate_limit: 30
  
  # Include skills marked as private in details requests
  expose_private_skills: false
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-31 | Initial release |
