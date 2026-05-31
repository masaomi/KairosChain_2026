# Build a COMBINED match_report.md from a prior task run + a separate Nomic run,
# with NO LLM calls. Task-layer scores come from <task_dir>/results_<task>.json;
# Nomic scores/history/postgame come from <nomic_results.json>. The report's
# Overall Standing automatically switches to the Nomic-weighted combined formula.
#
# Usage:
#   ruby regenerate_combined_report.rb <task_dir> <nomic_results.json> <output_dir> <tasks> <models>

require_relative "run_cross_eval"

task_dir   = ARGV[0] or abort "usage: <task_dir> <nomic_json> <output_dir> <tasks> <models>"
nomic_path = ARGV[1] or abort "missing nomic_results.json path"
output_dir = ARGV[2] or abort "missing output_dir"
task_ids   = (ARGV[3] || "").split(",")
model_keys = (ARGV[4] || "").split(",")
abort "no tasks"  if task_ids.empty?
abort "no models" if model_keys.empty?
require "fileutils"
FileUtils.mkdir_p(output_dir)

def deep_symbolize(obj)
  case obj
  when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
  when Array then obj.map { |e| deep_symbolize(e) }
  else obj
  end
end

# ── Task layers (string-keyed layer1/layer2; symbol-keyed calibration/bias inner) ──
all_results = {}
tasks = []
task_ids.each do |task_id|
  path = File.join(task_dir, "results_#{task_id}.json")
  unless File.exist?(path)
    warn "  [SKIP] missing #{path}"
    next
  end
  data = JSON.parse(File.read(path)).transform_keys(&:to_sym)
  data[:calibration] = data[:calibration].transform_values { |v| deep_symbolize(v) } if data[:calibration].is_a?(Hash)
  data[:bias]        = data[:bias].transform_values { |v| deep_symbolize(v) }        if data[:bias].is_a?(Hash)
  data[:task] = TaskLoader.load(task_id)
  all_results[task_id] = data
  tasks << data[:task]
end
abort "no task results loaded" if all_results.empty?

# ── Nomic layer ──
# nomic_table / overall_ranking index inner per-model score hashes by SYMBOL (:overall,
# :layer1_score, ...). history rendering uses h[:proposal_level] (symbol). postgame
# rendering uses r['frame_level'] / r['victory_critique'] (STRING) — leave it string.
nomic_raw    = JSON.parse(File.read(nomic_path))
nomic_scores = nomic_raw["scores"].transform_values { |v| deep_symbolize(v) }
nomic_data = {
  scores:   nomic_scores,
  history:  Array(nomic_raw["history"]).map { |h| h.transform_keys(&:to_sym) },
  postgame: nomic_raw["postgame"], # keep string keys
}

report_path = ReportGenerator.generate(
  output_dir, tasks, model_keys, all_results,
  nomic_scores: nomic_scores, nomic_data: nomic_data,
  incompleteness: nil, limits: nil
)

# ── Provenance & limits appendix (effort / model-variant asymmetry across the two runs) ──
provenance = <<~MD

  ---
  ## Run Provenance & Limits (combined report)

  This report merges two separate runs. They are NOT a single synchronized run.

  | Layer | Source run | Date |
  |----|----|----|
  | Tasks (Layer 0.5/1/2, bias, Layer D) | `#{task_dir}` | 2026-05-30 |
  | Nomic (Layer 2 self-reference) | `#{nomic_path}` | 2026-05-31 |

  ### Effort / model-variant asymmetry (LimitsReport)
  - **Codex GPT-5.5**: task run used the global `~/.codex/config.toml` effort (medium, but
    not pinned at run time — whether the config held medium then is unverified); the Nomic
    run pinned `model_reasoning_effort="medium"` explicitly. Treat task-vs-Nomic Codex as
    "medium, with task-side provenance unverified".
  - **Cursor**: task run used the default `composer-2.5-fast`; the Nomic run used
    `composer-2.5` (current, non-fast). **The Overall Standing therefore blends two Cursor
    variants** — task-side L1/L2/Calibration are -fast, Nomic-side is current. Cursor has no
    effort-control flag in either run.
  - Anthropic Opus 4.8/4.7/4.6 are medium in both runs (consistent).

  ### Combined-score note
  Overall Standing uses the Nomic-weighted formula `0.40·L1 + 0.25·L2 + 0.15·Calib + 0.20·Nomic`.
  This differs from the task-only report (`0.50·L1 + 0.30·L2 + 0.20·Calib`); ranking shifts
  are expected and are not a discrepancy.
MD

File.write(report_path, File.read(report_path) + provenance)
puts "=== Provenance appended to #{report_path} ==="
