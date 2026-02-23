#!/bin/bash
# Sync CLAUDE.md to agent-specific instruction files
#
# KairosChain uses CLAUDE.md as the canonical source for development guidelines.
# This script copies it to equivalent files for other AI coding tools.
#
# Usage: bash scripts/sync_agent_instructions.sh
#
# Supported targets:
#   - .cursor/rules/kairos.mdc (Cursor IDE)
#
# To add a new target, append a copy_to call below.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$PROJECT_ROOT/CLAUDE.md"

if [ ! -f "$SOURCE" ]; then
  echo "Error: CLAUDE.md not found at $SOURCE"
  exit 1
fi

copy_to() {
  local dest="$1"
  local label="$2"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  mkdir -p "$dest_dir"
  cp "$SOURCE" "$dest"
  echo "  Synced: CLAUDE.md -> $label"
}

echo "Syncing agent instructions from CLAUDE.md..."
echo ""

# Cursor IDE
copy_to "$PROJECT_ROOT/.cursor/rules/kairos.mdc" ".cursor/rules/kairos.mdc"

# Add future targets here:
# copy_to "$PROJECT_ROOT/.github/copilot-instructions.md" ".github/copilot-instructions.md"
# copy_to "$PROJECT_ROOT/AGENTS.md" "AGENTS.md"

echo ""
echo "Done. Verify with: diff CLAUDE.md .cursor/rules/kairos.mdc"
