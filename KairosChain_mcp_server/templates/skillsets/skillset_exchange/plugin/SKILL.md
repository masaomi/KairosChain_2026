---
name: skillset_exchange
description: >
  Exchange SkillSets between KairosChain instances via the decentralized Meeting Place.
  Use when acquiring, depositing, withdrawing, or browsing SkillSets from peers.
---

# SkillSet Exchange

Exchange SkillSets between KairosChain instances via the decentralized Meeting Place.

## Recommended Workflow

1. `meeting_connect` — connect to a peer
2. `meeting_browse` — list available SkillSets on the peer
3. `meeting_preview_skill` — check compatibility before acquiring
4. `skillset_acquire` — install the SkillSet
5. `skills_audit` — verify health after installation

## Automated Hooks

After `skillset_acquire` or `skillset_withdraw`, a hook automatically checks if plugin
projection needs to be updated. If new SkillSets have `plugin/` artifacts, they will be
projected and `/reload-plugins` will be suggested.

## Sub-Agents

### `/kairos-chain:exchange-reviewer`
Security review agent for exchange operations. Verifies blockchain integrity,
SkillSet health, and skill freshness. Read-only — cannot modify state or execute commands.

## Trust & Safety

- All exchanges are recorded on the blockchain
- Use `attestation_verify` to check SkillSet trust scores
- Use `meeting_check_freshness` to verify skill currency

## Available Tools

<!-- AUTO_TOOLS -->
