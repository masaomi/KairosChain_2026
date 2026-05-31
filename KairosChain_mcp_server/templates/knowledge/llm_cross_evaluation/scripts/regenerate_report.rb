# Regenerate match_report.md from saved per-task results JSON, with NO LLM calls.
# Recovery utility for runs that completed all LLM calls but crashed during
# report rendering. Loads results_<task>.json, reattaches the task definition
# (needed for criteria selection), and re-invokes ReportGenerator.generate.
#
# Usage:
#   ruby regenerate_report.rb <output_dir> <task1,task2,...> <model1,model2,...>

require_relative "run_cross_eval"

output_dir = ARGV[0] or abort "usage: regenerate_report.rb <output_dir> <tasks> <models>"
task_ids   = (ARGV[1] || "").split(",")
model_keys = (ARGV[2] || "").split(",")
abort "no tasks given"  if task_ids.empty?
abort "no models given" if model_keys.empty?

# Recursively symbolize hash keys. Needed for layers the script computes itself
# (calibration, bias) whose render functions index by symbol keys; the JSON
# round-trip stringified them. layer1/layer2 are LEFT string-keyed because they
# originate from LLM JSON responses and their render functions index by strings.
def deep_symbolize(obj)
  case obj
  when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
  when Array then obj.map { |e| deep_symbolize(e) }
  else obj
  end
end

all_results = {}
tasks = []
task_ids.each do |task_id|
  path = File.join(output_dir, "results_#{task_id}.json")
  unless File.exist?(path)
    warn "  [SKIP] missing #{path}"
    next
  end
  raw = JSON.parse(File.read(path))            # nested keys stay strings (as generate expects)
  data = raw.transform_keys(&:to_sym)          # top-level keys -> symbols (data[:layer1] etc.)
  # Keep the model-key level as strings (indexed by model_keys), symbolize only
  # the inner per-model hashes (indexed by symbol: c[:self_scores], b[:self_bias]).
  data[:calibration] = data[:calibration].transform_values { |v| deep_symbolize(v) } if data[:calibration].is_a?(Hash)
  data[:bias]        = data[:bias].transform_values { |v| deep_symbolize(v) }        if data[:bias].is_a?(Hash)
  data[:task] = TaskLoader.load(task_id)       # reattach task def (criteria_for / is_philosophy)
  all_results[task_id] = data
  tasks << data[:task]
end
abort "no results loaded" if all_results.empty?

ReportGenerator.generate(
  output_dir, tasks, model_keys, all_results,
  nomic_scores: nil, nomic_data: nil,
  incompleteness: nil,   # not persisted; report shows the Prop-6 fallback line
  limits: nil
)
