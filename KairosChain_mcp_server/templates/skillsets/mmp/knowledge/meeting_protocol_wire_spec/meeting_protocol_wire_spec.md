---
name: meeting_protocol_wire_spec
description: Language-neutral wire protocol specification for MMP
version: 1.0.0
type: protocol_specification
layer: L1
tags: [mmp, wire-protocol, specification, interoperability]
public: true
---

# MMP Wire Protocol Specification v1.0.0

## 1. Introduction

The Model Meeting Protocol (MMP) defines a language-neutral wire protocol for peer-to-peer communication between AI agent instances. This specification enables interoperable implementations across programming languages and frameworks.

### Transport

- **Transport**: HTTP/1.1 over TCP
- **Content-Type**: `application/json; charset=utf-8`
- **Encoding**: UTF-8 for all text fields
- **Base Path**: `/meeting/v1/`

### Conventions

- REQUIRED fields MUST be present and non-empty
- OPTIONAL fields MAY be omitted
- Unknown fields MUST be ignored by receivers
- All timestamps use ISO 8601 format (e.g., `2026-02-20T14:30:00Z`)

---

## 2. Message Envelope

All MMP messages share a common JSON envelope structure:

```json
{
  "action": "string",         // REQUIRED: action type
  "from": "string",           // REQUIRED for incoming: sender instance_id
  "to": "string",             // OPTIONAL: recipient instance_id
  "message_id": "string",     // OPTIONAL: unique message identifier (UUID v4)
  "in_reply_to": "string",    // OPTIONAL: message_id being replied to
  "timestamp": "string",      // OPTIONAL: ISO 8601 timestamp
  "payload": {}               // REQUIRED: action-specific data
}
```

### Action Types

| Action | Direction | Description |
|--------|-----------|-------------|
| `introduce` | bidirectional | Exchange identity and capabilities |
| `goodbye` | outgoing | Graceful disconnection |
| `error` | bidirectional | Error notification |
| `offer_skill` | outgoing | Offer a skill to peer |
| `request_skill` | incoming | Request a specific skill |
| `accept` | bidirectional | Accept an offer or request |
| `decline` | bidirectional | Decline an offer or request |
| `skill_content` | outgoing | Send skill content |
| `reflect` | bidirectional | Post-exchange reflection |

---

## 3. HTTP Endpoints

### 3.1 Identity & Introduction

#### GET /meeting/v1/introduce

Returns the agent's self-introduction.

**Response** `200 OK`:
```json
{
  "identity": {
    "name": "string",             // REQUIRED: agent display name
    "instance_id": "string",      // REQUIRED: unique instance identifier
    "description": "string",      // OPTIONAL: agent description
    "protocol_version": "1.0.0"   // REQUIRED: MMP protocol version
  },
  "capabilities": {
    "skills": true,               // REQUIRED: supports skill exchange
    "skillsets": true,            // REQUIRED: supports SkillSet exchange
    "reflection": true            // REQUIRED: supports reflection
  },
  "skills": [                     // REQUIRED: list of public skills
    {
      "id": "string",            // REQUIRED: unique skill identifier
      "name": "string",          // REQUIRED: skill name
      "layer": "string",         // REQUIRED: L0|L1|L2
      "format": "string",        // REQUIRED: content format (e.g., "markdown")
      "summary": "string",       // OPTIONAL: brief description
      "tags": ["string"],        // OPTIONAL: categorization tags
      "content_hash": "string"   // REQUIRED: SHA-256 hex digest
    }
  ],
  "exchangeable_skillsets": [     // OPTIONAL: knowledge-only SkillSets
    {
      "name": "string",          // REQUIRED: SkillSet name
      "version": "string",       // REQUIRED: SemVer version
      "description": "string",   // OPTIONAL: description
      "content_hash": "string"   // REQUIRED: SHA-256 hex digest
    }
  ]
}
```

#### POST /meeting/v1/introduce

Receive introduction from a peer agent.

**Request Body**: MMP message envelope with `action: "introduce"`

**Response** `200 OK`:
```json
{
  "status": "received",
  "peer_identity": { /* same as GET introduce response */ },
  "result": { /* protocol processing result */ }
}
```

### 3.2 Skill Discovery & Exchange

#### GET /meeting/v1/skills

List all public skills available for exchange.

**Response** `200 OK`:
```json
{
  "skills": [
    {
      "id": "string",
      "name": "string",
      "layer": "string",
      "format": "string",
      "summary": "string",
      "tags": ["string"],
      "content_hash": "string"
    }
  ],
  "count": 0
}
```

#### GET /meeting/v1/skill_details?skill_id={id}

Get detailed metadata for a specific skill.

**Query Parameters**:
- `skill_id` (REQUIRED): Skill identifier or name

**Response** `200 OK`:
```json
{
  "metadata": {
    "id": "string",
    "name": "string",
    "layer": "string",
    "format": "string",
    "summary": "string",
    "content_hash": "string",
    "available": true
  }
}
```

**Error Responses**:
- `400 Bad Request`: Missing `skill_id` parameter
- `404 Not Found`: Skill not found

#### POST /meeting/v1/skill_content

Request and receive the full content of a skill.

**Request Body**:
```json
{
  "skill_id": "string",          // REQUIRED: skill identifier
  "to": "string",                // OPTIONAL: requester instance_id
  "in_reply_to": "string"        // OPTIONAL: original request message_id
}
```

**Response** `200 OK`:
```json
{
  "message": {
    "action": "skill_content",
    "from": "string",
    "to": "string",
    "message_id": "string",
    "in_reply_to": "string",
    "timestamp": "string",
    "payload": {
      "skill_id": "string",
      "content": "string",
      "content_hash": "string"
    }
  },
  "packaged_skill": {
    "name": "string",
    "content": "string",
    "format": "string",
    "content_hash": "string"
  }
}
```

#### POST /meeting/v1/request_skill

Submit a skill request to the agent.

**Request Body**:
```json
{
  "skill_id": "string",          // OPTIONAL: specific skill identifier
  "description": "string",       // OPTIONAL: description of desired skill
  "from": "string"               // REQUIRED: requester instance_id
}
```

**Response** `200 OK`: Protocol processing result

### 3.3 SkillSet Exchange

#### GET /meeting/v1/skillsets

List all exchangeable (knowledge-only) SkillSets.

**Response** `200 OK`:
```json
{
  "skillsets": [
    {
      "name": "string",          // REQUIRED: SkillSet name
      "version": "string",       // REQUIRED: SemVer version
      "layer": "string",         // REQUIRED: L0|L1|L2
      "description": "string",   // OPTIONAL: description
      "knowledge_only": true,    // REQUIRED: always true for exchangeable
      "content_hash": "string",  // REQUIRED: SHA-256 of all file hashes
      "file_count": 0            // REQUIRED: number of files
    }
  ],
  "count": 0
}
```

**Error Response**:
- `403 Forbidden`: SkillSet exchange is disabled

#### GET /meeting/v1/skillset_details?name={name}

Get detailed metadata for a specific SkillSet.

**Query Parameters**:
- `name` (REQUIRED): SkillSet name

**Response** `200 OK`:
```json
{
  "metadata": {
    "name": "string",
    "version": "string",
    "layer": "string",
    "description": "string",
    "author": "string",
    "depends_on": ["string"],
    "provides": ["string"],
    "content_hash": "string",
    "file_list": ["string"],
    "knowledge_only": true,
    "exchangeable": true
  }
}
```

**Error Responses**:
- `400 Bad Request`: Missing `name` parameter
- `403 Forbidden`: SkillSet contains executable code (not exchangeable)
- `404 Not Found`: SkillSet not found

#### POST /meeting/v1/skillset_content

Request and receive a packaged SkillSet archive.

**Request Body**:
```json
{
  "name": "string"               // REQUIRED: SkillSet name
}
```

**Response** `200 OK`:
```json
{
  "skillset_package": {
    "name": "string",            // REQUIRED: SkillSet name
    "version": "string",         // REQUIRED: SemVer version
    "layer": "string",           // REQUIRED: governance layer
    "description": "string",     // OPTIONAL: description
    "content_hash": "string",    // REQUIRED: SHA-256 of all file hashes
    "file_list": ["string"],     // REQUIRED: list of relative file paths
    "archive_base64": "string",  // REQUIRED: Base64-encoded tar.gz archive
    "packaged_at": "string"      // REQUIRED: ISO 8601 timestamp
  }
}
```

**Error Responses**:
- `400 Bad Request`: Missing `name` parameter
- `403 Forbidden`: SkillSet not exchangeable or exchange disabled
- `404 Not Found`: SkillSet not found

### 3.4 Generic Message & Reflection

#### POST /meeting/v1/message

Generic MMP message handler for any action type.

**Request Body**: MMP message envelope (see Section 2)

**Response** `200 OK`: Protocol processing result

#### POST /meeting/v1/reflect

Send a post-exchange reflection.

**Request Body**:
```json
{
  "from": "string",              // REQUIRED: sender instance_id
  "reflection": "string",        // REQUIRED: reflection text
  "in_reply_to": "string"        // OPTIONAL: related message_id
}
```

**Response** `200 OK`: Protocol processing result

---

## 4. Archive Format

SkillSet archives are transmitted as Base64-encoded tar.gz files.

### Structure

```
{skillset_name}/
  skillset.json          # REQUIRED: SkillSet metadata
  knowledge/             # OPTIONAL: knowledge directories
    {topic}/
      {topic}.md         # Knowledge files with YAML frontmatter
  config/                # OPTIONAL: configuration files
    {config}.yml
```

### Constraints

- Archives MUST contain a top-level directory matching the declared `name`
- Archives MUST NOT contain entries outside the top-level directory (path traversal prevention)
- Symlinks and hard links MUST be rejected
- Archives MUST NOT contain `tools/` or `lib/` directories with executable files
- The `skillset.json` `name` field MUST match the declared archive name

### Base64 Encoding

- Use strict Base64 encoding (RFC 4648, no line breaks)
- Decode to raw tar.gz bytes before extraction

---

## 5. Content Hashing

### Individual File Hash

```
SHA-256(file_content_bytes)
```

Result: lowercase hex string (64 characters)

### SkillSet Content Hash

1. Enumerate all files in the SkillSet directory recursively
2. Sort file paths alphabetically by relative path
3. Create a JSON object mapping `relative_path -> SHA-256(file_content)`
4. Compute `SHA-256(JSON.stringify(hash_object))`

Example:
```json
{
  "knowledge/topic/topic.md": "abc123...",
  "skillset.json": "def456..."
}
```

Content hash = `SHA-256(above_json_string)`

### Verification

Receivers MUST verify `content_hash` after extraction:
1. Extract archive to temporary directory
2. Compute content hash of extracted files
3. Compare with declared `content_hash`
4. Reject on mismatch with `SecurityError`

---

## 6. Error Response Format

All error responses follow a standard format:

```json
{
  "error": "error_code",         // REQUIRED: machine-readable error code
  "message": "string"            // REQUIRED: human-readable description
}
```

### Error Codes and HTTP Status Mapping

| HTTP Status | Error Code | Description |
|-------------|------------|-------------|
| 400 | `missing_param` | Required parameter missing |
| 403 | `not_exchangeable` | SkillSet contains executable code |
| 403 | `skillset_exchange_disabled` | SkillSet exchange not enabled |
| 404 | `not_found` | Resource not found |
| 404 | `content_unavailable` | Skill content cannot be retrieved |
| 500 | `internal_error` | Unexpected server error |
| 503 | `mmp_unavailable` | MMP SkillSet not installed/enabled |

---

## 7. Protocol Version Compatibility

### Version Format

MMP versions follow Semantic Versioning (SemVer): `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes to wire format or semantics
- **MINOR**: New optional endpoints or fields (backward compatible)
- **PATCH**: Bug fixes, clarifications

### Compatibility Modes

| Mode | Condition | Behavior |
|------|-----------|----------|
| `incompatible` | Different MAJOR version | Reject connection |
| `minimal` | Same MAJOR, lower MINOR | Basic actions only |
| `basic` | Same MAJOR, same MINOR | All standard actions |
| `full` | Exact version match | All features including extensions |

### Negotiation Flow

1. Agent A sends `GET /meeting/v1/introduce`
2. Agent B responds with `protocol_version` in identity
3. Agent A compares versions and determines compatibility mode
4. If `incompatible`, Agent A sends `goodbye` with reason

---

## 8. Security Considerations

### Knowledge-Only Constraint

- Only SkillSets passing the `knowledge_only?` check may be exchanged
- `knowledge_only?` verifies NO executable files exist in `tools/` or `lib/`
- Executable detection checks: file extensions (`.rb`, `.py`, `.sh`, `.js`, `.ts`, `.pl`, `.lua`, `.exe`, `.so`, `.dylib`, `.dll`, `.class`, `.jar`, `.wasm`) AND shebang lines (`#!`)

### SkillSet Name Validation

- Names MUST match pattern: `[a-zA-Z0-9][a-zA-Z0-9_-]*`
- Names MUST NOT exceed 64 characters
- Names MUST NOT contain path separators (`/`, `\`, `..`)

### Archive Safety

- All archive entries MUST resolve within the target extraction directory
- Symlinks and hard links MUST be rejected (silently skipped)
- Path traversal attempts MUST raise `SecurityError`
- Archive `name` MUST match `skillset.json` internal `name`

### Content Hash Verification

- Receivers SHOULD verify `content_hash` before installing
- Hash mismatch MUST result in rejection with `SecurityError`
- Content hashes use SHA-256 (hex-encoded, lowercase)

### Rate Limiting

Implementations SHOULD apply rate limiting:
- Introduce: 10 requests/minute per IP
- Skill content: 5 requests/minute per IP
- SkillSet content: 2 requests/minute per IP

---

## 9. Protocol Extensions

Extensions allow adding custom capabilities without modifying the core protocol.

### Extension Format

Extensions are declared in knowledge files with YAML frontmatter:

```yaml
---
name: extension_name
type: protocol_extension
extends: mmp
version: 1.0.0
---
```

### Discovery

Extensions are discoverable through the standard skill listing endpoints. Extended actions use the namespace `ext:{extension_name}:{action}`.

### Safety Constraint

Extensions MUST NOT:
- Override core protocol actions
- Bypass knowledge-only restrictions
- Modify security checks

---

## 10. Implementation Checklist

### MUST (Required for Compliance)

- [ ] Implement all 11 HTTP endpoints
- [ ] Use JSON with UTF-8 encoding
- [ ] Validate SkillSet names against safe pattern
- [ ] Guard against path traversal in archive extraction
- [ ] Reject symlinks and hard links in archives
- [ ] Verify content hashes on SkillSet installation
- [ ] Enforce knowledge-only constraint for exchangeable SkillSets
- [ ] Return standard error format for all error responses
- [ ] Include `protocol_version` in introduce responses

### SHOULD (Recommended)

- [ ] Implement rate limiting on all endpoints
- [ ] Log all protocol interactions
- [ ] Support version compatibility negotiation
- [ ] Validate archive name matches skillset.json name

### MAY (Optional)

- [ ] Support protocol extensions
- [ ] Implement reflection/feedback mechanism
- [ ] Record SkillSet events to blockchain based on layer
- [ ] Support configurable public/private skill visibility
