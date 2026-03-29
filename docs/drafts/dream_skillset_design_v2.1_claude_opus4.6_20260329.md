# Dream SkillSet Design Draft v2.1

**Date**: 2026-03-29
**Author**: Masaomi Hatakeyama (design intent) + Claude Opus 4.6 (designer)
**Status**: Draft v2.1 — R1 review findings addressed
**Scope**: L1 SkillSet for memory consolidation, knowledge promotion, and L2 lifecycle management

---

## Changes from v2.0

| Change | R1 Finding | Reviewers |
|--------|-----------|-----------|
| `dry_run` default → `true` | Contradictory defaults in v2.0 | Claude HIGH, Cursor HIGH |
| `summary_mode: "auto"` removed → `summary` required param | Conflicts with "Dream doesn't call LLM" | 3/3 MEDIUM |
| Directory-level archive (move full dir, leave stub dir) | .md-only stub leaves scripts/assets visible | Codex HIGH |
| Atomic archive (tempfile + rename) + flock | Race condition during archive | 3/3 HIGH/MEDIUM |
| SHA256 inline verification after gzip write | No verification between archive and recall | Claude HIGH, Codex MEDIUM |
| Stub accumulation: scan filters archived contexts | Stubs grow indefinitely, scan walks all | Claude HIGH |
| Bisociation: explicitly experimental, off by default | PMI brittle on small corpora | Codex MEDIUM, Cursor agrees |
| ContextManager metadata requirements documented | API lacks modified_at, size_bytes | Codex HIGH, Cursor MEDIUM |
| Staleness = mtime-based, explicitly defined | Ambiguity between mtime and semantic reference | Cursor MEDIUM |

---

## Sections Unchanged from v2.0

The following sections are inherited without modification:
- Section 0: Design Intent & Philosophical Motivation
- Section 2.1: dream_scan (except signal table updates noted below)
- Section 2.2: dream_propose
- Section 3: Autonomos Integration
- Section 5: Kairotic Trigger Design
- Section 8: Self-Referentiality Assessment (tool list updated)

Only changed/new sections are documented below.

---

## 2.3 dream_archive (REVISED)

### Parameter Changes

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `targets` | array[object] | Yes | — | Archive targets (from dream_scan or manual) |
| `summary` | string | **Yes** | — | Caller-provided summary text for the stub. LLM generates this before calling dream_archive. |
| `dry_run` | boolean | No | **true** | Preview only. Must explicitly set `false` to execute. |

**Removed**: `summary_mode` parameter. Dream does not call LLM (Read-heavy, Write-light).
The calling LLM reads the context, generates a summary, and passes it as `summary`.

### Directory-Level Archive (REVISED)

**Problem** (Codex R1): Replacing only the `.md` file leaves `scripts/`, `assets/`,
`references/` in the context directory. `resource_list` and `manifest_builder` still
treat the directory as live.

**New Design**: Move the **entire context directory** to the Dream archive location.
Leave behind a **stub-only directory** containing only the stub `.md` file.

```
BEFORE:
.kairos/context/session_20260115_.../old_deployment_notes/
├── old_deployment_notes.md          ← full text
├── scripts/
│   └── deploy.sh                    ← 420 bytes
└── assets/
    └── diagram.png                  ← 15KB

AFTER dream_archive:
.kairos/context/session_20260115_.../old_deployment_notes/
└── old_deployment_notes.md          ← stub only (no scripts/, assets/, references/)

.kairos/dream/archive/session_20260115_.../old_deployment_notes/
├── old_deployment_notes.md.gz       ← gzip of original .md
├── scripts/
│   └── deploy.sh                    ← moved as-is
└── assets/
    └── diagram.png                  ← moved as-is
```

**Rationale**:
- `resource_list` sees only the stub `.md` — no stale scripts/assets exposed
- `manifest_builder` counts the stub directory but it contains minimal data
- Full directory structure is preserved in archive for `dream_recall` restoration
- Only the `.md` is gzipped (text compresses well); binary assets are moved as-is

### Atomic Archive Operation (NEW)

```ruby
def archive_context!(session_id:, context_name:, summary:)
  src_dir  = context_dir_path(session_id, context_name)
  arch_dir = archive_dir_path(session_id, context_name)
  md_file  = File.join(src_dir, "#{context_name}.md")

  # 1. Validate source exists and is not already archived
  raise "Context not found" unless File.exist?(md_file)
  raise "Already archived" if archived?(session_id, context_name)

  # 2. Read and compress the markdown
  original_content = File.read(md_file)
  content_hash = Digest::SHA256.hexdigest(original_content)

  FileUtils.mkdir_p(arch_dir)
  gz_path = File.join(arch_dir, "#{context_name}.md.gz")
  Zlib::GzipWriter.open(gz_path) { |gz| gz.write(original_content) }

  # 3. Verify gzip integrity immediately
  verify_hash = Digest::SHA256.hexdigest(Zlib::GzipReader.open(gz_path, &:read))
  unless verify_hash == content_hash
    FileUtils.rm_f(gz_path)
    raise "Gzip verification failed — archive aborted, original intact"
  end

  # 4. Move subdirectories (scripts/, assets/, references/) to archive
  %w[scripts assets references].each do |subdir|
    sub_src = File.join(src_dir, subdir)
    next unless File.directory?(sub_src)
    FileUtils.mv(sub_src, File.join(arch_dir, subdir))
  end

  # 5. Write stub atomically (tempfile + rename)
  stub_content = generate_stub(context_name, summary, content_hash, original_content.size)
  tmp_path = "#{md_file}.tmp"
  File.write(tmp_path, stub_content)
  File.rename(tmp_path, md_file)  # POSIX atomic

  # 6. Record on blockchain
  chain_record_archive(session_id, context_name, content_hash, original_content.size)

  { success: true, content_hash: content_hash, original_size: original_content.size }
end
```

**Crash analysis**:
- Crash after Step 2 (gzip written): Archive dir has gzip, source is intact. Cleanup: delete orphan gzip.
- Crash after Step 4 (subdirs moved): Source has .md but no subdirs, archive has subdirs + gzip. Recovery: move subdirs back or complete archive.
- Crash after Step 5 (stub written): Archive complete, chain_record pending. Recovery: re-run records the event.

**Ordering**: gzip first → verify → move assets → write stub last. The destructive step (stub overwrite) is last, matching the chain_archive v3 pattern.

### Stub Format (REVISED)

```yaml
---
title: "old_deployment_notes"
tags: [deployment, docker, notes]
description: "Docker Compose v2 production deploy procedure"
status: soft-archived
archived_at: "2026-03-29T10:00:00Z"
archived_by: dream_archive
archive_ref: "dream/archive/session_20260115_.../old_deployment_notes/"
content_hash: "a1b2c3d4..."
original_size: 4500
has_scripts: true
has_assets: true
summary: |
  Docker Compose v2 production deploy procedure. Port config,
  volume mounts, env var notes. Puma worker recommendations.
---

# old_deployment_notes [ARCHIVED]

This context has been soft-archived. Use `dream_recall` to restore.

**Tags**: deployment, docker, notes
**Original size**: 4,500 bytes
**Includes**: scripts/, assets/
```

Added fields vs v2.0:
- `content_hash`: SHA256 of original content (for integrity verification)
- `has_scripts`, `has_assets`: flags for what was moved to archive
- `description`: short description for search hit improvement (Cursor suggestion)

### dream_archive Output

```yaml
archive_result:
  archived: 3
  skipped: 0
  total_bytes_saved: 12400
  items:
    - name: "old_deployment_notes"
      session: "session_20260115_..."
      original_size: 4500
      content_hash: "a1b2c3d4..."
      stub_size: 650
      moved_subdirs: ["scripts", "assets"]
      verified: true    # gzip SHA256 verified
```

---

## 2.4 dream_recall (REVISED)

### Parameter Changes

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `session_id` | string | Yes | — | Session ID |
| `context_name` | string | Yes | — | Context name |
| `preview` | boolean | No | false | Decompress and display without restoring |
| `verify_only` | boolean | No | false | Check archive integrity without restoring |

### Restore with Directory Reconstruction

```ruby
def recall_context!(session_id:, context_name:)
  src_dir  = context_dir_path(session_id, context_name)
  arch_dir = archive_dir_path(session_id, context_name)
  md_file  = File.join(src_dir, "#{context_name}.md")
  gz_path  = File.join(arch_dir, "#{context_name}.md.gz")

  # 1. Verify archive exists and integrity
  raise "Archive not found: #{gz_path}" unless File.exist?(gz_path)
  stub = parse_stub(md_file)
  restored_content = Zlib::GzipReader.open(gz_path, &:read)
  restored_hash = Digest::SHA256.hexdigest(restored_content)
  unless restored_hash == stub[:content_hash]
    raise "Archive integrity check failed. Expected #{stub[:content_hash]}, " \
          "got #{restored_hash}. Archive may be corrupted."
  end

  # 2. Restore markdown atomically
  tmp_path = "#{md_file}.tmp"
  File.write(tmp_path, restored_content)
  File.rename(tmp_path, md_file)

  # 3. Move subdirectories back
  %w[scripts assets references].each do |subdir|
    sub_arch = File.join(arch_dir, subdir)
    next unless File.directory?(sub_arch)
    FileUtils.mv(sub_arch, File.join(src_dir, subdir))
  end

  # 4. Clean up archive (configurable)
  if config[:preserve_gzip]
    # Keep gzip for safety, but mark as recalled
  else
    FileUtils.rm_rf(arch_dir)
  end

  # 5. Record on blockchain
  chain_record_recall(session_id, context_name)
end
```

---

## 2.1 dream_scan — Signal Table Update

### Staleness Definition (CLARIFIED)

**L2 staleness = file modification time (mtime) based.**

```ruby
def detect_stale_l2(contexts, threshold_days: 90)
  now = Time.now
  contexts.reject { |ctx| ctx[:status] == 'soft-archived' }  # skip archived stubs
          .select do |ctx|
    mtime = File.mtime(ctx[:path])
    days_since = (now - mtime) / 86400
    days_since > threshold_days
  end
end
```

**Explicit definition**: Staleness is measured by file system mtime only. "Semantic
reference" (whether a context was read/cited by another session) is a v2.2+ concept
requiring a reference tracking mechanism that does not exist yet. The design
deliberately uses the simpler, filesystem-native signal.

### Scan Filtering for Archived Contexts (NEW)

Scan walks **skip** stubs in promotion/consolidation detection but **include** them
for health_summary statistics:

```ruby
def scan_l2(scope:, since_session: nil)
  all_contexts = load_all_contexts(since_session)

  # Partition: live contexts vs archived stubs
  live, archived = all_contexts.partition { |c| c[:status] != 'soft-archived' }

  # Promotion/consolidation: only live contexts
  promotion_candidates = detect_promotion_patterns(live)
  consolidation_candidates = detect_consolidation(live)
  archive_candidates = detect_stale_l2(live)

  # Health summary: includes archived count
  health = {
    total_l2: all_contexts.size,
    total_live: live.size,
    total_archived: archived.size,
    # ...
  }
end
```

**Rationale** (Claude R1): Without filtering, stubs accumulate and every `dream_scan`
walks them for promotion detection. Archived stubs are by definition old and should
not re-appear as promotion candidates. They remain visible for tag search and
bisociation (if enabled) via their stub metadata.

### ContextManager Metadata Requirements (DOCUMENTED)

`dream_scan` requires the following metadata per context. If `ContextManager` does not
provide them natively, the scanner falls back to filesystem stat:

| Field | Source (preferred) | Fallback |
|-------|-------------------|----------|
| `modified_at` | ContextManager metadata | `File.mtime(path)` |
| `size_bytes` | ContextManager metadata | `File.size(path)` |
| `status` | YAML frontmatter `status` field | `nil` (treat as active) |
| `tags` | YAML frontmatter `tags` field | `[]` |

**No L0 ContextManager changes required for v2.1.** The scanner reads frontmatter
directly and uses filesystem stat as fallback. If ContextManager is extended in the
future to expose structured metadata, the scanner can switch to the preferred source.

---

## 7. Bisociation Detection (REVISED — Experimental)

### Status: Experimental, Off by Default

```yaml
# dream.yml
bisociation:
  enabled: false         # CHANGED from true → false
  min_pmi: 1.5
  min_pair_count: 2      # NEW: minimum co-occurrence count before PMI calculation
  min_tag_types: 15      # NEW: minimum distinct tag types to enable detection
  max_results: 5
```

Bisociation detection is:
- **Included in the v2.1 design** (Phase 5 implementation)
- **Off by default** in `dream.yml`
- **Not part of the v2.1 release criteria** — can ship without it
- **Gated by guards**: `min_pair_count >= 2` AND `min_tag_types >= 15`

Users who want to experiment enable it manually. The signal remains Advisory (LLM
evaluates substance; no auto-promotion).

---

## 4. Blockchain Recording (REVISED)

| Event | Record Type | When | Data |
|-------|-------------|------|------|
| Scan with findings | `dream_scan_findings` | Non-empty only | Scope, counts, health |
| Proposal | `dream_proposal` | Always | Candidates, actions |
| **L2 archived** | `dream_archive` | **Always** | Targets, content_hash, sizes, moved_subdirs |
| **L2 recalled** | `dream_recall` | **Always** | Target, restored_hash, verified |
| **Verify** | — | Inline in archive/recall | Not separately recorded |

**Change from v2.0**: `content_hash` is now recorded in the chain event, enabling
future cross-verification without decompressing the gzip.

---

## 9. Safety Considerations (REVISED)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Accidental archive of active context | Medium | `dry_run: true` default; 90-day staleness; user confirmation |
| Race condition during archive | Medium | Atomic stub write (tempfile+rename); sequential processing |
| Gzip corruption undetected | Low | **SHA256 verified immediately after write**; hash stored in stub and chain |
| Stub accumulation | Low | Scan filters skip archived stubs; health_summary reports count |
| Summary quality | Low | Caller (LLM) generates summary; dream_recall preview to verify |
| Directory partially moved on crash | Low | Crash analysis documented; verify_only mode for diagnostics |

### Crash Recovery Procedures

| Crash Point | State | Recovery |
|-------------|-------|----------|
| After gzip write, before subdir move | Source intact + orphan gzip in archive | Delete orphan gzip, retry |
| After subdir move, before stub write | Source .md intact but subdirs in archive | Move subdirs back, retry |
| After stub write, before chain_record | Archive complete, unrecorded | Re-run dream_archive (idempotent via `already archived` check) |

---

## 10. skillset.json (v2.1)

```json
{
  "name": "dream",
  "version": "0.2.1",
  "description": "Memory consolidation and L2 lifecycle management. Scans for recurring patterns, manages L2 soft-archive (compress full text + move assets, keep searchable stub), and packages promotion proposals. Experimental bisociation detection (off by default). Read-heavy, write-light.",
  "author": "Masaomi Hatakeyama",
  "layer": "L1",
  "depends_on": [],
  "provides": [
    "pattern_detection",
    "promotion_discovery",
    "knowledge_health_scan",
    "l2_soft_archive",
    "l2_recall"
  ],
  "tool_classes": [
    "KairosMcp::SkillSets::Dream::Tools::DreamScan",
    "KairosMcp::SkillSets::Dream::Tools::DreamPropose",
    "KairosMcp::SkillSets::Dream::Tools::DreamArchive",
    "KairosMcp::SkillSets::Dream::Tools::DreamRecall"
  ],
  "config_files": ["config/dream.yml"],
  "knowledge_dirs": ["knowledge/dream_trigger_policy"],
  "min_core_version": "2.8.0"
}
```

Note: `bisociation_detection` removed from `provides` (experimental, off by default).

---

## 11. dream.yml (v2.1)

```yaml
scan:
  default_scope: "l2"
  min_recurrence: 3
  max_candidates: 5
  skip_archived: true              # scan filters skip soft-archived stubs

archive:
  staleness_threshold_days: 90
  dry_run_default: true            # CHANGED: safe by default
  preserve_gzip: true
  archive_dir: "dream/archive"

bisociation:
  enabled: false                   # CHANGED: off by default
  min_pmi: 1.5
  min_pair_count: 2                # NEW
  min_tag_types: 15                # NEW
  max_results: 5

staleness:
  method: "mtime"                  # NEW: explicit definition
  # future options: "referenced" (requires reference tracking)

recording:
  scan_findings_only: true
  archive_events: true
```

---

## 12. Implementation Phases (REVISED)

| Phase | Deliverable | Priority | Notes |
|-------|-------------|----------|-------|
| **Phase 0** | ContextManager metadata fallback (mtime, size via File.stat) | **Prerequisite** | No L0 change; scanner uses filesystem directly |
| **Phase 1** | `dream_scan` (tags + L2 staleness + archive candidates + stub filtering) | **Highest** | |
| **Phase 2** | `dream_archive` + `dream_recall` (directory-level, atomic, verified) | **High** | |
| **Phase 3** | `dream_propose` (proposal packaging) | Medium | |
| **Phase 4** | `dream_trigger_policy` (L1 knowledge) | Medium | |
| **Phase 5** | Bisociation detection (experimental, off by default) | **Low** | Not a release criterion |
| **Phase 6** | Autonomos integration | Low | Optional |

---

## 13. Open Questions (UPDATED)

### Q1: Summary generation — RESOLVED
Dream does not call LLM. The calling LLM generates the summary and passes it as
the required `summary` parameter to `dream_archive`. `summary_mode` is removed.

### Q2: Tag index cache — UNCHANGED
Defer to implementation time. Filesystem walk is acceptable for < 1000 contexts.

### Q3: Bisociation minimum threshold — RESOLVED
`min_pair_count: 2` + `min_tag_types: 15` + `enabled: false` by default.

### Q4: dream_archive vs skills_audit — UNCHANGED
Separate: L2 (dream) vs L1 (skills_audit). Different layers, different concerns.

### Q5 (NEW): Should dream_recall verify before restoring by default?
**Answer**: Yes. `dream_recall` always verifies SHA256 before restoring. If verification
fails, it raises an error and does not modify the stub. `verify_only: true` mode allows
checking integrity without attempting restore.

### Q6 (NEW): What happens to a recalled context's archive?
**Answer**: Configurable via `preserve_gzip: true` (default). When true, the gzip remains
in the archive directory after recall (safety net). When false, the archive directory is
cleaned up after successful recall.

---

*Generated: 2026-03-29 by Claude Opus 4.6*
*Review status: v2.1 — R1 findings addressed. Ready for R2 review.*
