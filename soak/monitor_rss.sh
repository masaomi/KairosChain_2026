#!/bin/bash
# monitor_rss.sh — RSS monitoring for G2 soak (72h)
# Design (Phase 4 v0.3 §5.2):
#   Run via cron every 5min. Appends timestamp,rss_kb to CSV.
#
# Usage: soak/monitor_rss.sh [csv_path]

CSV_PATH="${1:-/tmp/kairos-soak-g2/rss.csv}"
mkdir -p "$(dirname "$CSV_PATH")"

# Use -x for exact match to avoid matching monitor_rss.sh itself
PID=$(pgrep -x -f 'ruby.*kairos-daemon' | head -1)

if [ -n "$PID" ]; then
  RSS=$(ps -o rss= -p "$PID" | tr -d ' ')
  echo "$(date +%s),$RSS" >> "$CSV_PATH"
fi
