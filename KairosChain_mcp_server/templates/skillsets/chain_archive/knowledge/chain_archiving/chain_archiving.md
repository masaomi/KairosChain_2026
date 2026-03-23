---
name: chain_archiving
description: Blockchain archive strategy for KairosChain — how to prune the live chain without losing audit history
version: "1.0"
layer: L1
tags: [blockchain, archive, storage, pruning, maintenance]
---

# Blockchain Archiving (chain_archive SkillSet)

## Problem

KairosChain's blockchain grows indefinitely. Every `chain_record`, `knowledge_update`,
`skills_evolve`, and similar operation appends a block. Over time `blockchain.json`
becomes very large, slowing loads and consuming disk space.

## Solution: Segment-based archiving with archive blocks

When the live chain exceeds a configurable threshold (default: 1,000 blocks), the
`chain_archive_run` tool:

1. **Compresses** all current blocks to `storage/archives/segment_NNNNNN.json.gz`
2. **Records** the segment in `storage/archives/manifest.json`
3. **Appends** a single *archive block* that continues the hash chain

The archive block is a normal block (index = last archived index + 1) whose
`previous_hash` links cryptographically to the last archived block, and whose
`data` contains a JSON envelope referencing the archive:

```json
{
  "type": "archive_block",
  "segment_num": 0,
  "segment_filename": "segment_000000.json.gz",
  "segment_hash": "<sha256>",
  "blocks_archived": 1247,
  "last_archived_hash": "<hash of last archived block>",
  "total_segments": 1,
  "archived_at": "2026-03-08T12:00:00Z"
}
```

Because the archive block's `previous_hash` equals the last archived block's hash,
the chain boundary is **cryptographically anchored** — not merely referenced as a
string in data. Any tampering with the segment breaks the hash linkage, which
`chain_archive_verify` will detect.

## Directory layout

```
storage/
  blockchain.json          ← live chain (small, starts from checkpoint)
  archives/
    manifest.json          ← index of all segments
    segment_000000.json.gz ← compressed original blocks
    segment_000001.json.gz ← next archive cycle, etc.
```

## MCP Tools

| Tool | Purpose |
|------|---------|
| `chain_archive_status` | Show live chain size, segment count, threshold |
| `chain_archive_run` | Trigger archiving (optionally with `reason` and `threshold` overrides) |
| `chain_archive_verify` | Verify SHA256 and internal chain integrity of all segments |

## When to archive

- **Routine maintenance**: when `chain_archive_status` reports `should_archive: true`
- **Before export/backup**: shrink the live chain for faster exports
- **After a major milestone**: explicitly record why the archive happened via `reason`

## Integrity guarantees

- Each segment's SHA256 is recorded in the manifest and re-verified by `chain_archive_verify`
- Within a segment, `previous_hash` chains are validated block-by-block
- The archive block's `previous_hash` cryptographically links the live chain to the last archived block
- The archive block's `segment_hash` binds the segment file contents into the chain
- The live chain itself remains valid per standard `chain_verify`

## Limitations

- Works with the **file backend** (`blockchain.json`). SQLite users should run
  `chain_export` first to materialise `blockchain.json`, then use this SkillSet.
- Archiving is a **destructive write** to `blockchain.json`. Always run
  `chain_archive_verify` after archiving to confirm segment integrity.
- Blocks archived in segment N cannot be retrieved without decompressing the segment.
  Use standard `gunzip` + JSON tools to inspect archived blocks directly.

## Philosophy note

Archiving is consistent with KairosChain's Kairotic temporality: each archive cycle is
an irreversible reconstitution of the system's present state. The archive block is
the new "decisive moment" from which the system's live identity continues. The past is
not erased — it is preserved in the archive and can always be re-examined.
