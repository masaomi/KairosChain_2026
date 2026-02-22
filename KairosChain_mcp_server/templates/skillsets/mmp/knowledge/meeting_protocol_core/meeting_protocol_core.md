---
name: meeting_protocol_core
description: Core MMP (Model Meeting Protocol) definitions for P2P agent communication
version: 1.0.0
type: protocol_definition
bootstrap: true
immutable: true
layer: L1
actions:
  - introduce
  - goodbye
  - error
  - offer_skill
  - request_skill
  - accept
  - decline
  - reflect
  - skill_content
tags:
  - mmp
  - protocol
  - p2p
  - communication
public: true
---

# Meeting Protocol Core (MMP)

The Model Meeting Protocol (MMP) defines semantic actions for agent-to-agent communication.
These are "speech acts" - intentional communication primitives.

## Core Actions (Immutable)

- **introduce**: Self-introduction with identity, capabilities, and available skills
- **goodbye**: Graceful session termination
- **error**: Error reporting with recovery hints

## Exchange Actions

- **offer_skill**: Propose sharing a skill with another agent
- **request_skill**: Ask for a specific skill
- **accept**: Accept an offer or request
- **decline**: Decline with optional reason
- **skill_content**: Transfer actual skill content
- **reflect**: Post-interaction reflection
