---
name: meeting_protocol_skillset_exchange
description: Protocol extension for exchanging knowledge-only SkillSets between KairosChain instances via MMP
version: 1.0.0
type: protocol_extension
tags:
  - protocol
  - skillset
  - exchange
  - p2p
public: true
actions:
  - offer_skillset
  - request_skillset
  - skillset_content
  - list_skillsets
---

# SkillSet Exchange Protocol Extension

Extends the Model Meeting Protocol (MMP) with actions for exchanging
knowledge-only SkillSets between KairosChain instances.

## Security Constraint

Only **knowledge-only** SkillSets (those without `tools/` or `lib/` containing
executable Ruby code) may be exchanged over this protocol. SkillSets containing
executable code must be installed manually via trusted channels.

## Actions

### list_skillsets

Request a list of exchangeable SkillSets from a peer.

- **Endpoint**: `GET /meeting/v1/skillsets`
- **Response**: Array of SkillSet metadata (name, version, layer, description, content_hash)

### request_skillset

Request detailed metadata about a specific SkillSet.

- **Endpoint**: `GET /meeting/v1/skillset_details?name=<name>`
- **Response**: Full metadata including file list and content hash

### offer_skillset

Offer a SkillSet for exchange (implicit in the list response).

### skillset_content

Request the full archive content of a knowledge-only SkillSet.

- **Endpoint**: `POST /meeting/v1/skillset_content`
- **Body**: `{ "name": "<skillset_name>" }`
- **Response**: Base64-encoded tar.gz archive with content hash for verification

## Exchange Flow

1. Agent A calls `list_skillsets` on Agent B to discover available SkillSets
2. Agent A calls `request_skillset` to inspect metadata and file list
3. Agent A calls `skillset_content` to receive the archive
4. Agent A validates the content hash and verifies knowledge-only constraint
5. Agent A installs via `SkillSetManager#install_from_archive`
6. Both agents record the exchange event to their respective blockchains

## Provenance

Each exchanged SkillSet carries:
- `content_hash`: SHA256 of all files for integrity verification
- Source peer identity from the MMP introduce handshake
- Blockchain record of the install event (layer-dependent)
