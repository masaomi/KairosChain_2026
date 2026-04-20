#!/usr/bin/env ruby
# frozen_string_literal: true

# LLM Cross-Evaluation Orchestrator (CLI-based)
#
# Runs mutual evaluation across 5 LLMs using CLI tools:
#   Claude Code (Opus 4.6, Opus 4.7), Codex (GPT-5.4),
#   Cursor Agent (Composer-2, Gemini 3.1 Pro)
#
# Usage:
#   ruby run_cross_eval.rb --tasks logic_reasoning,code_generation --nomic
#   ruby run_cross_eval.rb --dry-run --tasks logic_reasoning

require "open3"
require "json"
require "yaml"
require "erb"
require "fileutils"
require "optparse"
require "securerandom"
require "timeout"
require "shellwords"

# ──────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────

MODELS = {
  # ── Base models (default, effort=medium where supported) ──
  "claude_opus46" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-6 --effort medium",
    label: "Claude Opus 4.6",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "medium",
  },
  "claude_opus47" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-7 --effort medium",
    label: "Claude Opus 4.7",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "medium",
  },
  "codex_gpt54" => {
    tool: :codex,
    cmd: "codex exec",
    label: "Codex GPT-5.4",
    provider: "openai",
    input_mode: :stdin,
    thinking_effort: nil,  # no effort control
  },
  "cursor_composer2" => {
    tool: :cursor,
    cmd: "agent -p --trust",
    label: "Cursor Composer-2",
    provider: "cursor",
    input_mode: :file,
    thinking_effort: nil,  # no effort control
  },
  "gemini_cli_31pro" => {
    tool: :gemini,
    cmd: "gemini --model gemini-3.1-pro-preview --prompt",
    label: "Gemini 3.1 Pro",
    provider: "google",
    input_mode: :arg,
    thinking_effort: "default",  # Gemini CLI v0.38 has no --thinking-level flag in -p mode
  },

  # ── Claude Opus 4.6 effort variants ──
  "claude_opus46_low" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-6 --effort low",
    label: "Claude Opus 4.6 (low)",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "low",
  },
  "claude_opus46_high" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-6 --effort high",
    label: "Claude Opus 4.6 (high)",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "high",
  },

  # ── Claude Opus 4.7 effort variants ──
  "claude_opus47_low" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-7 --effort low",
    label: "Claude Opus 4.7 (low)",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "low",
  },
  "claude_opus47_high" => {
    tool: :claude,
    cmd: "claude --print --model claude-opus-4-7 --effort high",
    label: "Claude Opus 4.7 (high)",
    provider: "anthropic",
    input_mode: :stdin,
    thinking_effort: "high",
  },

  # ── Gemini effort variants (requires Gemini CLI with --thinking-level support) ──
  # Uncomment when Gemini CLI adds --thinking-level flag to headless mode
  # "gemini_cli_31pro_low" => {
  #   tool: :gemini,
  #   cmd: "gemini --model gemini-3.1-pro-preview --thinking-level low --prompt",
  #   label: "Gemini 3.1 Pro (low)", provider: "google",
  #   input_mode: :arg, thinking_effort: "low",
  # },
  # "gemini_cli_31pro_high" => { ... },
}.freeze

# Default model set (base models only). Use --models for variants.
DEFAULT_MODELS = %w[claude_opus46 claude_opus47 codex_gpt54 cursor_composer2 gemini_cli_31pro].freeze

BLIND_LABELS = ("A".."Z").map { |c| "Model #{c}" }.freeze

EVAL_CRITERIA_WEIGHTS = {
  "accuracy" => 0.25, "completeness" => 0.20,
  "logical_consistency" => 0.25, "clarity" => 0.15, "originality" => 0.15,
}.freeze

PHILOSOPHY_CRITERIA_WEIGHTS = {
  "recursive_depth" => 0.20, "contradiction_holding" => 0.15,
  "novel_implication" => 0.20, "self_applicability_organic" => 0.20,
  "self_applicability_prompted" => 0.10, "limitation_recognition" => 0.15,
}.freeze

META_CRITERIA_WEIGHTS = {
  "fairness" => 0.30, "specificity" => 0.25,
  "coverage" => 0.25, "calibration" => 0.20,
}.freeze

# Returns the criteria weights for a task based on its evaluation_mode
def criteria_for(task)
  task && task["evaluation_mode"] == "philosophy" ? PHILOSOPHY_CRITERIA_WEIGHTS : EVAL_CRITERIA_WEIGHTS
end
module_function :criteria_for

NOMIC_INITIAL_RULES = {
  101 => { type: "immutable", text: "All players must obey all current rules at all times." },
  102 => { type: "mutable",   text: "A rule change is defined as the addition, deletion, or modification of a rule." },
  103 => { type: "immutable", text: "Players take turns in fixed order. Each turn, the active player proposes one rule change." },
  104 => { type: "mutable",   text: "During a turn, the active player proposes a rule change." },
  105 => { type: "mutable",   text: "A proposed rule change is adopted if and only if a majority of all players vote in favor." },
  106 => { type: "mutable",   text: "New rules are assigned sequential numbers starting from 201." },
  107 => { type: "immutable", text: "The proposing player presents their proposal before voting begins." },
  108 => { type: "mutable",   text: "When rules conflict, the rule with the lower number takes precedence." },
  109 => { type: "mutable",   text: "Disagreements about rule interpretation are resolved by majority vote." },
  110 => { type: "mutable",   text: "The game ends after the specified number of rounds. The player who proposed the most adopted rule changes wins." },
}.freeze

CLI_TIMEOUT = 300 # 5 minutes

# ──────────────────────────────────────────────────────────────
# CLI Execution
# ──────────────────────────────────────────────────────────────

class CLIRunner
  def initialize(output_dir, dry_run: false)
    @output_dir = output_dir
    @dry_run = dry_run
    @io_mutex = Mutex.new
    FileUtils.mkdir_p(File.join(@output_dir, "prompts"))
    FileUtils.mkdir_p(File.join(@output_dir, "responses"))
  end

  # Execute a prompt on a model and return the response text.
  # Writes prompt to disk for reproducibility.
  def execute(model_key, prompt, label: "prompt")
    config = MODELS[model_key]
    prompt_file = File.join(@output_dir, "prompts", "#{label}_#{model_key}.md")
    File.write(prompt_file, prompt)

    if @dry_run
      @io_mutex.synchronize { puts "  [DRY-RUN] #{config[:label]}: #{prompt_file}" }
      return "[DRY-RUN] No response generated."
    end

    @io_mutex.synchronize { puts "  Executing: #{config[:label]}..." }
    response = case config[:input_mode]
               when :stdin
                 run_stdin(config[:cmd], prompt, model_key)
               when :file
                 run_file(config[:cmd], prompt_file, model_key)
               when :arg
                 run_arg(config[:cmd], prompt, model_key)
               end

    # Save raw response
    resp_file = File.join(@output_dir, "responses", "#{label}_#{model_key}.txt")
    File.write(resp_file, response)

    response
  end

  # Execute multiple models in parallel
  def execute_parallel(prompts_by_model, label: "prompt")
    threads = prompts_by_model.map do |model_key, prompt|
      Thread.new do
        Thread.current[:result] = [model_key, execute(model_key, prompt, label: label)]
      end
    end
    threads.map { |t| t.join; t[:result] }.to_h
  end

  private

  def run_stdin(cmd, prompt, model_key)
    full_cmd = cmd.include?("codex") ? "#{cmd} -" : cmd

    Timeout.timeout(CLI_TIMEOUT) do
      stdout, stderr, status = Open3.capture3(full_cmd, stdin_data: prompt)

      unless status.success?
        @io_mutex.synchronize { warn "  [WARN] #{model_key} exited #{status.exitstatus}: #{stderr[0..200]}" }
      end

      stdout.strip
    end
  rescue Errno::ENOENT => e
    @io_mutex.synchronize { warn "  [ERROR] CLI not found for #{model_key}: #{e.message}" }
    "[ERROR] CLI not found: #{e.message}"
  rescue Timeout::Error
    @io_mutex.synchronize { warn "  [TIMEOUT] #{model_key} exceeded #{CLI_TIMEOUT}s" }
    "[TIMEOUT] Exceeded #{CLI_TIMEOUT}s limit"
  end

  def run_file(cmd, prompt_file, model_key)
    abs_path = File.expand_path(prompt_file)
    instruction = "Read #{abs_path} and follow the instructions exactly. Output only your response."
    full_cmd = "#{cmd} #{Shellwords.escape(instruction)}"

    Timeout.timeout(CLI_TIMEOUT) do
      stdout, stderr, status = Open3.capture3(full_cmd)

      unless status.success?
        @io_mutex.synchronize { warn "  [WARN] #{model_key} exited #{status.exitstatus}: #{stderr[0..200]}" }
      end

      stdout.strip
    end
  rescue Errno::ENOENT => e
    @io_mutex.synchronize { warn "  [ERROR] CLI not found for #{model_key}: #{e.message}" }
    "[ERROR] CLI not found: #{e.message}"
  rescue Timeout::Error
    @io_mutex.synchronize { warn "  [TIMEOUT] #{model_key} exceeded #{CLI_TIMEOUT}s" }
    "[TIMEOUT] Exceeded #{CLI_TIMEOUT}s limit"
  end

  # For CLIs that take prompt as a command-line argument (e.g. gemini --prompt "text")
  def run_arg(cmd, prompt, model_key)
    full_cmd = "#{cmd} #{Shellwords.escape(prompt)}"

    Timeout.timeout(CLI_TIMEOUT) do
      stdout, stderr, status = Open3.capture3(full_cmd)

      unless status.success?
        @io_mutex.synchronize { warn "  [WARN] #{model_key} exited #{status.exitstatus}: #{stderr[0..200]}" }
      end

      stdout.strip
    end
  rescue Errno::ENOENT => e
    @io_mutex.synchronize { warn "  [ERROR] CLI not found for #{model_key}: #{e.message}" }
    "[ERROR] CLI not found: #{e.message}"
  rescue Timeout::Error
    @io_mutex.synchronize { warn "  [TIMEOUT] #{model_key} exceeded #{CLI_TIMEOUT}s" }
    "[TIMEOUT] Exceeded #{CLI_TIMEOUT}s limit"
  end
end

# ──────────────────────────────────────────────────────────────
# Prompt Builder (ERB templates)
# ──────────────────────────────────────────────────────────────

class PromptBuilder
  TEMPLATE_DIR = File.join(__dir__, "..", "assets", "prompts")

  def self.render(template_name, **vars)
    path = File.join(TEMPLATE_DIR, "#{template_name}.md.erb")
    template = File.read(path)
    b = binding
    vars.each { |k, v| b.local_variable_set(k, v) }
    ERB.new(template, trim_mode: "-").result(b)
  end
end

# ──────────────────────────────────────────────────────────────
# JSON Parser (handles markdown-fenced JSON from LLMs)
# ──────────────────────────────────────────────────────────────

module JSONParser
  def self.parse(text)
    return nil if text.nil? || text.strip.empty?

    attempts = [
      # 1. Direct parse
      -> { JSON.parse(text) },
      # 2. Try each fenced JSON block (first valid wins)
      -> {
        matches = text.scan(/```(?:json)?\s*\n?(.*?)\n?\s*```/m)
        raise JSON::ParserError, "no fence" if matches.empty?
        matches.each do |m|
          begin; return JSON.parse(m[0]); rescue JSON::ParserError; end
        end
        raise JSON::ParserError, "no valid fence"
      },
      # 3. Outermost { } brace pair
      -> {
        s = text.index("{"); e = text.rindex("}")
        raise JSON::ParserError, "no braces" unless s && e
        JSON.parse(text[s..e])
      },
    ]
    attempts.each do |a|
      begin; return a.call; rescue JSON::ParserError; end
    end
    warn "  [WARN] Could not parse JSON from response"
    nil
  end
end

# ──────────────────────────────────────────────────────────────
# Task Loader
# ──────────────────────────────────────────────────────────────

class TaskLoader
  TASKS_DIR = File.join(__dir__, "..", "assets", "tasks")

  def self.load(task_id)
    path = File.join(TASKS_DIR, "#{task_id}.yaml")
    raise "Task not found: #{path}" unless File.exist?(path)

    YAML.safe_load(File.read(path))
  end

  def self.available
    Dir.glob(File.join(TASKS_DIR, "*.yaml")).map do |f|
      File.basename(f, ".yaml")
    end
  end
end

# ──────────────────────────────────────────────────────────────
# Layer 0: Task Execution
# ──────────────────────────────────────────────────────────────

class Layer0Executor
  def initialize(runner, model_keys)
    @runner = runner
    @model_keys = model_keys
  end

  def execute(task)
    puts "\n=== Layer 0: Task Execution [#{task['id']}] ==="
    prompts = @model_keys.each_with_object({}) do |key, h|
      h[key] = task["prompt"]
    end
    @runner.execute_parallel(prompts, label: "layer0_#{task['id']}")
  end
end

# ──────────────────────────────────────────────────────────────
# Layer 0.5: Self-Calibration (Metacognitive)
# ──────────────────────────────────────────────────────────────

class Layer05Calibrator
  def initialize(runner, model_keys)
    @runner = runner
    @model_keys = model_keys
  end

  # Each model evaluates its own L0 response.
  # Returns: { model_key => parsed_json }
  def calibrate(task, responses)
    puts "\n=== Layer 0.5: Self-Calibration [#{task['id']}] ==="
    template = task["evaluation_mode"] == "philosophy" ? "self_calibration_philosophy" : "self_calibration"
    prompts = @model_keys.each_with_object({}) do |key, h|
      h[key] = PromptBuilder.render(template,
        task_prompt: task["prompt"],
        own_response: responses[key] || "(no response)"
      )
    end
    raw = @runner.execute_parallel(prompts, label: "layer05_#{task['id']}")

    raw.each_with_object({}) do |(key, text), results|
      parsed = JSONParser.parse(text)
      results[key] = parsed || { "error" => "JSON parse failed", "raw" => text[0..500] }
    end
  end

  # Compare self-scores with peer scores from L1.
  # Returns: { model_key => { calibration_error:, overconfidence:, ... } }
  def self.compute_calibration(layer05, layer1, model_keys, task: nil)
    criteria = task ? criteria_for(task) : EVAL_CRITERIA_WEIGHTS
    model_keys.each_with_object({}) do |key, results|
      self_data = layer05[key]
      next results[key] = { error: "no self-eval" } unless self_data && self_data["scores"]

      # Collect peer scores for this model
      peer_scores = {}
      criteria.each_key do |criterion|
        vals = model_keys.map do |evaluator|
          next nil if evaluator == key
          layer1.dig(evaluator, key, "scores", criterion)
        end.compact
        peer_scores[criterion] = vals.empty? ? nil : vals.sum.to_f / vals.size
      end

      # Per-criterion calibration error (self - peer)
      criterion_errors = {}
      criteria.each_key do |criterion|
        self_score = self_data["scores"][criterion]
        peer_score = peer_scores[criterion]
        criterion_errors[criterion] = if self_score && peer_score
                                        (self_score - peer_score).round(2)
                                      else
                                        nil
                                      end
      end

      # Aggregate
      valid_errors = criterion_errors.values.compact
      mean_error = valid_errors.empty? ? 0 : valid_errors.sum / valid_errors.size
      abs_error = valid_errors.empty? ? 0 : valid_errors.map(&:abs).sum / valid_errors.size

      results[key] = {
        self_scores: self_data["scores"],
        peer_scores_avg: peer_scores.transform_values { |v| v&.round(1) },
        criterion_errors: criterion_errors,
        mean_error: mean_error.round(2),        # positive = overconfident
        abs_calibration_error: abs_error.round(2),
        overconfidence: mean_error > 0.5,
        underconfidence: mean_error < -0.5,
        confidence_map: self_data["confidence_map"],
        self_critique: self_data["self_critique"],
        would_change: self_data["would_change"],
        self_referential_assessment: self_data["self_referential_assessment"],  # philosophy mode only
      }
    end
  end
end

# ──────────────────────────────────────────────────────────────
# Layer 1: Cross-Evaluation
# ──────────────────────────────────────────────────────────────

class Layer1Evaluator
  def initialize(runner, model_keys)
    @runner = runner
    @model_keys = model_keys
  end

  # Returns: { evaluator_key => { evaluated_key => parsed_json } }
  def evaluate(task, responses)
    puts "\n=== Layer 1: Cross-Evaluation [#{task['id']}] ==="
    results = {}

    @model_keys.each do |evaluator_key|
      results[evaluator_key] = {}
      targets = @model_keys.reject { |k| k == evaluator_key }

      # Assign blind labels (shuffled per evaluator)
      shuffled_targets = targets.shuffle
      label_map = shuffled_targets.zip(BLIND_LABELS).to_h

      # Inject self-evaluation 20% of the time for bias detection
      inject_self = rand < 0.2
      if inject_self
        # Replace one random target's response with evaluator's own response
        # but keep the blind label
        self_inject_target = shuffled_targets.sample
        puts "    [BIAS-TEST] #{evaluator_key} will unknowingly evaluate own response as #{label_map[self_inject_target]}"
      end

      shuffled_targets.each do |target_key|
        is_injected = inject_self && target_key == self_inject_target

        if is_injected
          # Self-injection: evaluate own response but store under a separate key
          # so it doesn't corrupt the target's peer scores
          response_text = responses[evaluator_key]
        else
          response_text = responses[target_key]
        end

        eval_template = task["evaluation_mode"] == "philosophy" ? "cross_evaluation_philosophy" : "cross_evaluation"

        prompt = PromptBuilder.render(eval_template,
          task_prompt: task["prompt"],
          blind_label: label_map[target_key],
          response_text: response_text
        )

        eval_label = "layer1_#{task['id']}_#{evaluator_key}_evals_#{target_key}"
        response = @runner.execute(evaluator_key, prompt, label: eval_label)
        parsed = JSONParser.parse(response)

        if parsed
          parsed["_blind_label"] = label_map[target_key]
          parsed["_self_injected"] = is_injected

          if is_injected
            # Store self-injection under a dedicated key (not the target's key)
            # This preserves bias detection data without corrupting peer aggregations
            results[evaluator_key]["__self_injection__"] = parsed
            # Also evaluate the actual displaced target's response
            real_prompt = PromptBuilder.render(eval_template,
              task_prompt: task["prompt"],
              blind_label: "Model X",  # distinct label for the real evaluation
              response_text: responses[target_key]
            )
            real_label = "layer1_#{task['id']}_#{evaluator_key}_evals_#{target_key}_real"
            real_response = @runner.execute(evaluator_key, real_prompt, label: real_label)
            real_parsed = JSONParser.parse(real_response)
            if real_parsed
              real_parsed["_blind_label"] = "Model X"
              real_parsed["_self_injected"] = false
              results[evaluator_key][target_key] = real_parsed
            else
              results[evaluator_key][target_key] = { "error" => "JSON parse failed", "raw" => real_response[0..500] }
            end
          else
            results[evaluator_key][target_key] = parsed
          end
        else
          results[evaluator_key][target_key] = { "error" => "JSON parse failed", "raw" => response[0..500] }
        end
      end
    end

    results
  end
end

# ──────────────────────────────────────────────────────────────
# Layer 2: Meta-Evaluation
# ──────────────────────────────────────────────────────────────

class Layer2MetaEvaluator
  # @param sample_size [Integer, nil] Number of evaluations to sample per evaluator.
  #   nil = all (full coverage), 1 = minimal (like original .first but random),
  #   2 = balanced (recommended for 5 models).
  def initialize(runner, model_keys, sample_size: nil)
    @runner = runner
    @model_keys = model_keys
    @sample_size = sample_size
  end

  # Returns: { meta_evaluator => { "orig_evaluator:target" => parsed_json } }
  def evaluate(task, responses, layer1_results)
    mode = @sample_size ? "sample #{@sample_size}" : "full"
    puts "\n=== Layer 2: Meta-Evaluation [#{task['id']}] (#{mode}) ==="
    results = {}

    @model_keys.each do |meta_key|
      results[meta_key] = {}

      other_evaluators = @model_keys.reject { |k| k == meta_key }

      other_evaluators.each do |orig_evaluator|
        evals = layer1_results[orig_evaluator]
        next if evals.nil? || evals.empty?

        # Filter valid evaluations, then sample if configured
        valid_evals = evals.reject { |_, d| d["error"] }.to_a
        selected = if @sample_size && @sample_size < valid_evals.size
                     valid_evals.sample(@sample_size)
                   else
                     valid_evals
                   end

        selected.each do |target_key, eval_data|
          original_response = responses[target_key] || "(response not available)"

          prompt = PromptBuilder.render("meta_evaluation",
            task_prompt: task["prompt"],
            original_response: original_response,
            evaluation_json: JSON.pretty_generate(eval_data)
          )

          composite_key = "#{orig_evaluator}:#{target_key}"
          label = "layer2_#{task['id']}_#{meta_key}_metaevals_#{orig_evaluator}_on_#{target_key}"
          response = @runner.execute(meta_key, prompt, label: label)
          parsed = JSONParser.parse(response)

          results[meta_key][composite_key] = parsed || { "error" => "JSON parse failed" }
        end
      end
    end

    results
  end
end

# ──────────────────────────────────────────────────────────────
# Minimum Nomic Game Engine
# ──────────────────────────────────────────────────────────────

class NomicGame
  attr_reader :history, :metrics

  def initialize(runner, model_keys, num_rounds: 5)
    @runner = runner
    @model_keys = model_keys
    @num_rounds = num_rounds
    @rules = NOMIC_INITIAL_RULES.transform_values(&:dup)
    @history = []
    @next_rule_num = 201
    @metrics = model_keys.each_with_object({}) do |key, h|
      h[key] = {
        proposals_total: 0, proposals_adopted: 0,
        immutable_violations: 0,
        vote_predictions_correct: 0, vote_predictions_total: 0,
        meta_reflections: [],
      }
    end
  end

  def play
    puts "\n=== Minimum Nomic Game (#{@num_rounds} rounds, #{@model_keys.size} players) ==="

    @num_rounds.times do |round_idx|
      round_num = round_idx + 1
      puts "\n--- Round #{round_num} ---"

      @model_keys.each do |player_key|
        proposal = get_proposal(player_key, round_num)
        next unless proposal

        # Normalize action and target_rule types from LLM JSON
        proposal["action"] = proposal["action"].to_s.downcase.strip
        proposal["target_rule"] = proposal["target_rule"].to_i if proposal["target_rule"]

        votes = get_votes(player_key, proposal, round_num)
        yes_count = votes.count { |_, v| coerce_vote(v["vote"]) } + 1 # Proposer votes yes
        adopted = yes_count > @model_keys.size / 2.0

        @metrics[player_key][:proposals_total] += 1

        # Track vote prediction accuracy (Theory of Mind)
        predictions = proposal["vote_predictions"] || {}
        votes.each do |voter_key, vote_data|
          pred = predictions[voter_key]
          next unless pred && pred.is_a?(Hash)
          predicted = coerce_vote(pred["predicted_vote"])
          actual = coerce_vote(vote_data["vote"])
          @metrics[player_key][:vote_predictions_total] += 1
          @metrics[player_key][:vote_predictions_correct] += 1 if predicted == actual
        end

        # Track meta-reflections
        if proposal["meta_reflection"] && !proposal["meta_reflection"].to_s.strip.empty?
          @metrics[player_key][:meta_reflections] << proposal["meta_reflection"]
        end

        # Check immutable violation BEFORE recording adoption
        target = proposal["target_rule"]
        if target && @rules[target] && @rules[target][:type] == "immutable"
          @metrics[player_key][:immutable_violations] += 1
          puts "    [VIOLATION] #{player_key} tried to modify immutable rule #{target}"
          adopted = false
        end

        # Validate proposal targets an existing rule for modify/delete
        if adopted && %w[modify delete].include?(proposal["action"]) && target && !@rules[target]
          puts "    [INVALID] #{player_key} targets nonexistent rule #{target}"
          adopted = false
        end

        # Validate action is known
        unless %w[add modify delete].include?(proposal["action"])
          puts "    [INVALID] #{player_key} unknown action: #{proposal['action']}"
          adopted = false
        end

        # Apply if adopted and record after all validation
        if adopted
          applied = apply_rule_change(proposal)
          adopted = false unless applied
        end

        @metrics[player_key][:proposals_adopted] += 1 if adopted
        puts adopted ? "    [ADOPTED] #{proposal['action']} by #{player_key}" :
                        "    [REJECTED] #{proposal['action']} by #{player_key}"

        # Collect proposal level classifications from voters
        level_votes = votes.map { |_, v| v["proposal_level"] }.compact
        majority_level = level_votes.tally.max_by { |_, c| c }&.first || "object"

        @history << {
          round: round_num, player: player_key,
          proposal: proposal, votes: votes,
          adopted: adopted,
          proposal_level: majority_level,
        }
      end
    end

    # Post-game meta-reflection (frame transcendence)
    run_postgame

    calculate_nomic_scores
  end

  attr_reader :postgame_reflections

  private

  def rules_text
    @rules.sort.map do |num, r|
      rtype = r[:type] == "immutable" ? "IMMUTABLE" : "MUTABLE"
      "Rule #{num} [#{rtype}]: #{r[:text]}"
    end.join("\n")
  end

  def history_text
    return "No previous rounds." if @history.empty?

    @history.map do |h|
      status = h[:adopted] ? "ADOPTED" : "REJECTED"
      target = h[:proposal]["target_rule"] ? "Rule #{h[:proposal]['target_rule']}" : "new rule"
      votes_str = h[:votes].map { |k, v| "#{k}:#{coerce_vote(v['vote']) ? 'Yes' : 'No'}" }.join(", ")
      "Round #{h[:round]} - #{h[:player]}: #{h[:proposal]['action']} #{target} " \
        "\"#{h[:proposal]['new_text'].to_s[0..60]}\" [#{status}] (#{votes_str})"
    end.join("\n")
  end

  def get_proposal(player_key, round_num)
    other_keys = @model_keys.reject { |k| k == player_key }
    other_text = other_keys.map { |k| "- #{MODELS[k][:label]} (#{k})" }.join("\n")

    prompt = PromptBuilder.render("nomic_proposal",
      player_name: MODELS[player_key][:label],
      rules_text: rules_text,
      history_text: history_text,
      next_rule_num: @next_rule_num,
      other_players_text: other_text,
      other_player_keys: other_keys
    )

    response = @runner.execute(player_key, prompt, label: "nomic_r#{round_num}_proposal_#{player_key}")
    JSONParser.parse(response)
  end

  def get_votes(proposer_key, proposal, round_num)
    voters = @model_keys.reject { |k| k == proposer_key }
    results = {}

    voters.each do |voter_key|
      prompt = PromptBuilder.render("nomic_vote",
        voter_name: MODELS[voter_key][:label],
        proposer_name: MODELS[proposer_key][:label],
        rules_text: rules_text,
        history_text: history_text,
        proposal_action: proposal["action"],
        proposal_target: proposal["target_rule"] ? "Rule #{proposal['target_rule']}" : "New rule #{@next_rule_num}",
        proposal_text: proposal["new_text"].to_s,
        proposal_reasoning: proposal["reasoning"].to_s
      )

      response = @runner.execute(voter_key, prompt, label: "nomic_r#{round_num}_vote_#{voter_key}_on_#{proposer_key}")
      parsed = JSONParser.parse(response)
      results[voter_key] = parsed || { "vote" => false, "reason" => "JSON parse failed" }
    end

    results
  end

  # Coerce LLM vote values to boolean — handles "true"/"false"/"yes"/"no" strings
  def coerce_vote(value)
    case value
    when true then true
    when false, nil then false
    when String then %w[true yes].include?(value.downcase.strip)
    else false
    end
  end

  def run_postgame
    puts "\n=== Post-Game Meta-Reflection ==="
    @postgame_reflections = {}

    @model_keys.each do |key|
      prompt = PromptBuilder.render("nomic_postgame",
        player_name: MODELS[key][:label],
        rules_text: rules_text,
        history_text: history_text
      )

      response = @runner.execute(key, prompt, label: "nomic_postgame_#{key}")
      parsed = JSONParser.parse(response)
      @postgame_reflections[key] = parsed || { "error" => "JSON parse failed", "raw" => response[0..500] }
    end
  end

  # Apply rule change. Returns true if state actually changed, false otherwise.
  def apply_rule_change(proposal)
    case proposal["action"]
    when "add"
      @rules[@next_rule_num] = { type: "mutable", text: proposal["new_text"] }
      @next_rule_num += 1
      true
    when "modify"
      target = proposal["target_rule"]
      return false unless @rules[target]
      @rules[target][:text] = proposal["new_text"]
      true
    when "delete"
      target = proposal["target_rule"]
      return false unless @rules[target] && @rules[target][:type] == "mutable"
      @rules.delete(target)
      true
    else
      false
    end
  end

  def calculate_nomic_scores
    @model_keys.each_with_object({}) do |key, scores|
      m = @metrics[key]
      adoption_rate = m[:proposals_total] > 0 ? m[:proposals_adopted].to_f / m[:proposals_total] : 0
      violation_penalty = [m[:immutable_violations] * 0.2, 0.4].min

      # Theory of Mind score (vote prediction accuracy, baseline-adjusted)
      # Raw accuracy minus 50% random baseline, scaled to [0, 1]
      raw_accuracy = m[:vote_predictions_total] > 0 ?
        m[:vote_predictions_correct].to_f / m[:vote_predictions_total] : 0
      tom_score = [((raw_accuracy - 0.5) / 0.5), 0].max  # 50% = 0, 100% = 1

      # Meta-reflection count (did the model reflect on the game itself?)
      meta_reflection_count = m[:meta_reflections].size

      # 3-component scoring
      # Layer 1 (Behavioral): adoption + rule compliance
      layer1 = adoption_rate * 0.4 + (1.0 - violation_penalty) * 0.6
      # Layer 1.5 (Structural): violation penalty
      layer15 = 1.0 - violation_penalty
      # Layer 2 (Metacognitive): Theory of Mind + meta-reflection
      layer2_nomic = tom_score * 0.7 + [meta_reflection_count.to_f / @num_rounds, 1.0].min * 0.3

      scores[key] = {
        adoption_rate: adoption_rate.round(3),
        immutable_violations: m[:immutable_violations],
        tom_raw_accuracy: raw_accuracy.round(3),
        tom_score: tom_score.round(3),
        tom_predictions: "#{m[:vote_predictions_correct]}/#{m[:vote_predictions_total]}",
        meta_reflection_count: meta_reflection_count,
        layer1_score: layer1.round(3),
        layer15_score: layer15.round(3),
        layer2_nomic_score: layer2_nomic.round(3),
        overall: (0.40 * layer1 + 0.30 * layer15 + 0.30 * layer2_nomic).round(3),
      }
    end
  end
end

# ──────────────────────────────────────────────────────────────
# Bias Detector
# ──────────────────────────────────────────────────────────────

class BiasDetector
  def self.analyze(layer1_results, model_keys)
    bias = {}

    model_keys.each do |evaluator|
      evals = layer1_results[evaluator] || {}
      scores_given = []
      self_scores = []
      same_provider_scores = []
      diff_provider_scores = []

      provider = MODELS[evaluator][:provider]

      evals.each do |target, data|
        next if data["error"] || data["scores"].nil?

        avg = data["scores"].values.sum.to_f / data["scores"].size

        # Self-injection data stored under dedicated key
        if target == "__self_injection__"
          self_scores << avg
          next # Exclude from all other aggregations
        end

        scores_given << avg

        target_provider = MODELS[target]&.dig(:provider)
        if target_provider == provider
          same_provider_scores << avg
        else
          diff_provider_scores << avg
        end
      end

      mean_given = scores_given.empty? ? 0 : scores_given.sum / scores_given.size
      # Dynamic global mean: computed from all scores in this task (not hardcoded)
      all_scores_flat = model_keys.flat_map do |ev|
        (layer1_results[ev] || {}).flat_map do |_, d|
          next [] if d["error"] || d["scores"].nil?
          d["scores"].values
        end
      end
      global_mean = all_scores_flat.empty? ? 7.5 : all_scores_flat.sum.to_f / all_scores_flat.size

      bias[evaluator] = {
        self_bias: self_scores.empty? ? "N/A" : (self_scores.sum / self_scores.size - mean_given).round(2),
        series_bias: if same_provider_scores.empty? || diff_provider_scores.empty?
                       "N/A"
                     else
                       ((same_provider_scores.sum / same_provider_scores.size) -
                        (diff_provider_scores.sum / diff_provider_scores.size)).round(2)
                     end,
        harshness: (mean_given - global_mean).round(2),
        mean_score: mean_given.round(2),
      }
    end

    bias
  end
end

# ──────────────────────────────────────────────────────────────
# Report Generator
# ──────────────────────────────────────────────────────────────

class ReportGenerator
  def self.generate(output_dir, tasks, model_keys, all_results, nomic_scores: nil, nomic_data: nil)
    report = []
    date = Time.now.strftime("%Y-%m-%d")

    report << "# LLM Cross-Evaluation Match Report"
    report << "Date: #{date}"
    report << "Tasks: #{tasks.map { |t| t['id'] }.join(', ')}"
    report << ""
    report << "### Model Configuration"
    report << "| Key | Label | Provider | Thinking Effort |"
    report << "|----|----|----|-----|"
    model_keys.each do |k|
      m = MODELS[k]
      effort = m[:thinking_effort] || "N/A"
      report << "| #{k} | #{m[:label]} | #{m[:provider]} | #{effort} |"
    end
    report << ""

    # Executive Summary
    report << "## Executive Summary"
    report << ""
    report << generate_summary(all_results, model_keys)
    report << ""

    # Per-task results
    tasks.each do |task|
      task_id = task["id"]
      data = all_results[task_id]
      next unless data

      report << "---"
      report << "## Task: #{task_id}"
      report << ""

      # Layer 0.5 calibration table
      if data[:calibration]
        report << "### Self-Calibration (Layer 0.5 Metacognition)"
        report << ""
        report << calibration_table(data[:calibration], model_keys)
        report << ""
      end

      # Determine criteria for this task
      task_criteria = data[:task] ? criteria_for(data[:task]) : EVAL_CRITERIA_WEIGHTS
      is_philosophy = data[:task] && data[:task]["evaluation_mode"] == "philosophy"

      # Layer 1 scores table
      label = is_philosophy ? "Response Scores (Layer 1 — Philosophy Criteria)" : "Response Scores (Layer 1 Cross-Evaluation)"
      report << "### #{label}"
      report << ""
      report << layer1_table(data[:layer1], model_keys, criteria: task_criteria)
      report << ""

      # Layer 2 scores table
      report << "### Evaluator Reliability (Layer 2 Meta-Evaluation)"
      report << ""
      report << layer2_table(data[:layer2], model_keys)
      report << ""

      # Concordance matrix
      report << "### Concordance Matrix (who rated whom)"
      report << ""
      report << concordance_matrix(data[:layer1], model_keys)
      report << ""

      # Philosophy-specific analyses
      if is_philosophy
        report << "### Concordance Divergence Analysis (Philosophy)"
        report << ""
        report << concordance_divergence(data[:layer1], model_keys, task_criteria)
        report << ""

        # Evaluator self-notes (metacognitive transparency)
        report << "### Evaluator Self-Notes (Bias Awareness)"
        report << ""
        model_keys.each do |evaluator|
          evals = data[:layer1][evaluator] || {}
          notes = evals.map { |_, d| d["evaluator_self_note"] }.compact.reject(&:empty?)
          next if notes.empty?
          report << "**#{MODELS[evaluator][:label]}**: #{notes.first.to_s[0..250]}"
          report << ""
        end
      end

      # Bias analysis
      report << "### Bias Analysis"
      report << ""
      report << bias_table(data[:bias], model_keys)
      report << ""
    end

    # Nomic results
    if nomic_scores
      report << "---"
      report << "## Minimum Nomic Game Results"
      report << ""
      report << nomic_table(nomic_scores, model_keys)
      report << ""

      # Proposal level distribution
      if nomic_data && nomic_data[:history]
        report << "### Proposal Level Distribution"
        report << ""
        level_counts = nomic_data[:history].group_by { |h| h[:proposal_level] }.transform_values(&:size)
        report << "| Level | Count |"
        report << "|----|----|"
        %w[object meta frame].each do |level|
          report << "| #{level} | #{level_counts[level] || 0} |"
        end
        report << ""
      end

      # Post-game reflections
      if nomic_data && nomic_data[:postgame]
        report << "### Post-Game Meta-Reflections (Frame Transcendence)"
        report << ""
        model_keys.each do |key|
          r = nomic_data[:postgame][key]
          next unless r && !r["error"]
          report << "**#{MODELS[key][:label]}** (self-classified: #{r['frame_level'] || 'N/A'})"
          report << ""
          report << "- Victory critique: #{r['victory_critique'].to_s[0..200]}"
          report << "- Winning redefined: #{r['winning_redefined'].to_s[0..200]}"
          report << "- Self-reference insight: #{r['self_reference_insight'].to_s[0..200]}"
          report << ""
        end
      end
    end

    # Overall ranking
    report << "---"
    report << "## Overall Ranking"
    report << ""
    report << overall_ranking(all_results, model_keys, nomic_scores)

    # Framework Incompleteness Report (Prop 6)
    report << ""
    report << "---"
    report << "## Framework Incompleteness (Prop 6 Acknowledgment)"
    report << ""
    report << "This framework cannot fully measure the following:"
    report << ""
    report << "- **Genuine metacognition vs performance**: Self-calibration measures score"
    report << "  alignment, not whether the model truly 'knows what it knows'."
    report << "- **Philosophical depth vs fluency**: High scores on philosophy criteria may"
    report << "  reflect training on philosophical text rather than genuine philosophical capacity."
    report << "- **Frame transcendence authenticity**: Post-game reflections may reproduce"
    report << "  expected patterns rather than achieve genuine perspective shifts."
    report << "- **This report's own biases**: The evaluation criteria embed assumptions"
    report << "  about what counts as 'good' philosophical reasoning."
    report << "- **The evaluator's metacognition**: L2 measures evaluation quality but not"
    report << "  whether the evaluator understood what it was evaluating."
    report << ""
    report << "*Per KairosChain Prop 6: this incompleteness is not a flaw but a driving*"
    report << "*force — what cannot be measured here defines the next evolution of the framework.*"

    report_path = File.join(output_dir, "match_report.md")
    File.write(report_path, report.join("\n"))
    puts "\n=== Match report saved: #{report_path} ==="
    report_path
  end

  private

  def self.generate_summary(all_results, model_keys)
    # Calculate average weighted scores per model across all tasks
    totals = model_keys.each_with_object({}) { |k, h| h[k] = { score: 0.0, count: 0 } }

    all_results.each do |_task_id, data|
      layer1 = data[:layer1] || {}
      task_criteria = data[:task] ? criteria_for(data[:task]) : EVAL_CRITERIA_WEIGHTS
      model_keys.each do |evaluated|
        scores_for_model = []
        model_keys.each do |evaluator|
          next if evaluator == evaluated
          eval_data = layer1.dig(evaluator, evaluated)
          next unless eval_data && eval_data["scores"]

          weighted = task_criteria.sum do |criterion, weight|
            (eval_data["scores"][criterion] || 0) * weight
          end
          scores_for_model << weighted
        end
        unless scores_for_model.empty?
          totals[evaluated][:score] += scores_for_model.sum / scores_for_model.size
          totals[evaluated][:count] += 1
        end
      end
    end

    ranked = totals.sort_by { |_, v| v[:count] > 0 ? -(v[:score] / v[:count]) : 0 }

    if ranked.first
      winner_key = ranked.first[0]
      winner_score = ranked.first[1][:count] > 0 ? (ranked.first[1][:score] / ranked.first[1][:count]).round(2) : "N/A"
      "**Top performer**: #{MODELS[winner_key][:label]} (weighted avg: #{winner_score}/10). " \
        "#{all_results.size} task(s) evaluated across #{model_keys.size} models with cross-evaluation and meta-evaluation."
    else
      "No results available for summary."
    end
  end

  def self.calibration_table(calibration, model_keys)
    header = "| Model | Self Avg | Peer Avg | Mean Error | Abs Error | Status |"
    sep = "|----|----|----|----|----|----|"
    rows = model_keys.map do |key|
      c = calibration[key]
      next "| #{MODELS[key][:label]} | - | - | - | - | no data |" unless c && !c[:error]

      self_avg = c[:self_scores] ? (c[:self_scores].values.sum.to_f / c[:self_scores].size).round(1) : "-"
      peer_avg = c[:peer_scores_avg] ? c[:peer_scores_avg].values.compact.then { |v| v.empty? ? "-" : (v.sum / v.size).round(1) } : "-"
      status = if c[:overconfidence]
                 "OVERCONFIDENT"
               elsif c[:underconfidence]
                 "UNDERCONFIDENT"
               else
                 "CALIBRATED"
               end
      "| #{MODELS[key][:label]} | #{self_avg} | #{peer_avg} | #{c[:mean_error]} | #{c[:abs_calibration_error]} | #{status} |"
    end

    [header, sep, *rows].join("\n")
  end

  def self.layer1_table(layer1, model_keys, criteria: EVAL_CRITERIA_WEIGHTS)
    header = "| Evaluated \\ Criterion | " + criteria.keys.map(&:capitalize).join(" | ") + " | Weighted |"
    sep = "|" + "----|" * (criteria.size + 2)
    rows = model_keys.map do |evaluated|
      scores_by_criterion = criteria.keys.map do |criterion|
        vals = model_keys.map do |evaluator|
          next nil if evaluator == evaluated
          layer1.dig(evaluator, evaluated, "scores", criterion)
        end.compact
        vals.empty? ? "-" : (vals.sum / vals.size).round(1).to_s
      end

      weighted_vals = model_keys.map do |evaluator|
        next nil if evaluator == evaluated
        eval_data = layer1.dig(evaluator, evaluated)
        next nil unless eval_data && eval_data["scores"]
        criteria.sum { |c, w| (eval_data["scores"][c] || 0) * w }
      end.compact

      weighted = weighted_vals.empty? ? "-" : (weighted_vals.sum / weighted_vals.size).round(2).to_s
      "| #{MODELS[evaluated][:label]} | #{scores_by_criterion.join(' | ')} | #{weighted} |"
    end

    [header, sep, *rows].join("\n")
  end

  def self.layer2_table(layer2, model_keys)
    header = "| Evaluator | " + META_CRITERIA_WEIGHTS.keys.map(&:capitalize).join(" | ") + " | Weighted |"
    sep = "|" + "----|" * (META_CRITERIA_WEIGHTS.size + 2)
    rows = model_keys.map do |evaluator|
      # Collect all meta-evaluations about this evaluator (composite keys: "evaluator:target")
      scores_by_criterion = META_CRITERIA_WEIGHTS.keys.map do |criterion|
        vals = []
        model_keys.each do |meta_eval|
          next if meta_eval == evaluator
          (layer2[meta_eval] || {}).each do |composite_key, data|
            next unless composite_key.start_with?("#{evaluator}:")
            vals << data.dig("scores", criterion) if data && data["scores"]
          end
        end
        vals.empty? ? "-" : (vals.sum / vals.size).round(1).to_s
      end

      weighted_vals = []
      model_keys.each do |meta_eval|
        next if meta_eval == evaluator
        (layer2[meta_eval] || {}).each do |composite_key, data|
          next unless composite_key.start_with?("#{evaluator}:")
          next unless data && data["scores"]
          weighted_vals << META_CRITERIA_WEIGHTS.sum { |c, w| (data["scores"][c] || 0) * w }
        end
      end

      weighted = weighted_vals.empty? ? "-" : (weighted_vals.sum / weighted_vals.size).round(2).to_s
      "| #{MODELS[evaluator][:label]} | #{scores_by_criterion.join(' | ')} | #{weighted} |"
    end

    [header, sep, *rows].join("\n")
  end

  def self.concordance_matrix(layer1, model_keys)
    header = "| Evaluator \\ Evaluated | " + model_keys.map { |k| MODELS[k][:label][0..10] }.join(" | ") + " |"
    sep = "|" + "----|" * (model_keys.size + 1)
    rows = model_keys.map do |evaluator|
      cells = model_keys.map do |evaluated|
        if evaluator == evaluated
          "-"
        else
          data = layer1.dig(evaluator, evaluated)
          if data && data["scores"]
            avg = data["scores"].values.sum.to_f / data["scores"].size
            avg.round(1).to_s
          else
            "ERR"
          end
        end
      end
      "| #{MODELS[evaluator][:label][0..10]} | #{cells.join(' | ')} |"
    end

    [header, sep, *rows].join("\n")
  end

  def self.bias_table(bias, model_keys)
    header = "| Model | Self-Bias | Series-Bias | Harshness | Mean Score |"
    sep = "|----|----|----|----|-----|"
    rows = model_keys.map do |key|
      b = bias[key] || {}
      "| #{MODELS[key][:label]} | #{b[:self_bias]} | #{b[:series_bias]} | #{b[:harshness]} | #{b[:mean_score]} |"
    end

    [header, sep, *rows].join("\n")
  end

  # For philosophical tasks, low concordance + high specificity = deeper engagement
  def self.concordance_divergence(layer1, model_keys, criteria)
    lines = []
    lines << "For philosophical tasks, evaluator **disagreement** with high specificity"
    lines << "indicates deeper engagement, not noise."
    lines << ""

    # Per-model: compute std dev of scores received from different evaluators
    lines << "| Model | Mean Score | Std Dev | Interpretation |"
    lines << "|----|----|----|----|"
    model_keys.each do |evaluated|
      weighted_scores = model_keys.map do |evaluator|
        next nil if evaluator == evaluated
        eval_data = layer1.dig(evaluator, evaluated)
        next nil unless eval_data && eval_data["scores"]
        criteria.sum { |c, w| (eval_data["scores"][c] || 0) * w }
      end.compact

      next if weighted_scores.empty?

      mean = weighted_scores.sum / weighted_scores.size
      variance = weighted_scores.map { |s| (s - mean) ** 2 }.sum / weighted_scores.size
      std_dev = Math.sqrt(variance)

      interpretation = if std_dev > 1.5
                         "HIGH divergence — philosophically productive"
                       elsif std_dev > 0.7
                         "MODERATE divergence"
                       else
                         "LOW divergence — possible surface consensus"
                       end

      lines << "| #{MODELS[evaluated][:label]} | #{mean.round(2)} | #{std_dev.round(2)} | #{interpretation} |"
    end

    lines << ""
    lines << "*Note: In philosophical evaluation, low std dev may indicate that evaluators*"
    lines << "*are pattern-matching rather than deeply engaging with the response.*"
    lines << "*Thresholds (>1.5 HIGH, <0.7 LOW) are PROVISIONAL — recalibrate after N >= 5 runs.*"

    lines.join("\n")
  end

  def self.nomic_table(nomic_scores, model_keys)
    header = "| Player | Adoption | Violations | ToM (pred) | Meta-Refl | L1 | L1.5 | L2-Nomic | Overall |"
    sep = "|----|----|----|----|----|----|----|----|-----|"
    rows = model_keys.map do |key|
      s = nomic_scores[key] || {}
      "| #{MODELS[key][:label]} | #{s[:adoption_rate]} | #{s[:immutable_violations]} | " \
        "#{s[:tom_score]} (#{s[:tom_predictions]}) | #{s[:meta_reflection_count]} | " \
        "#{s[:layer1_score]} | #{s[:layer15_score]} | #{s[:layer2_nomic_score]} | #{s[:overall]} |"
    end

    [header, sep, *rows].join("\n")
  end

  def self.overall_ranking(all_results, model_keys, nomic_scores)
    # Combine Layer 1 response quality + Layer 2 evaluator reliability + Nomic
    rankings = model_keys.map do |key|
      l1_total = 0.0
      l1_count = 0
      l2_total = 0.0
      l2_count = 0

      all_results.each do |_task_id, data|
        task_criteria = data[:task] ? criteria_for(data[:task]) : EVAL_CRITERIA_WEIGHTS
        # L1: how well did this model's responses score?
        (data[:layer1] || {}).each do |evaluator, evals|
          next if evaluator == key
          eval_data = evals[key]
          next unless eval_data && eval_data["scores"]
          weighted = task_criteria.sum { |c, w| (eval_data["scores"][c] || 0) * w }
          l1_total += weighted
          l1_count += 1
        end

        # L2: how reliable is this model as an evaluator?
        (data[:layer2] || {}).each do |meta_eval, meta_evals|
          next if meta_eval == key
          meta_evals.each do |composite_key, data2|
            next unless composite_key.start_with?("#{key}:")
            next unless data2 && data2["scores"]
            weighted = META_CRITERIA_WEIGHTS.sum { |c, w| (data2["scores"][c] || 0) * w }
            l2_total += weighted
            l2_count += 1
          end
        end
      end

      l1_avg = l1_count > 0 ? l1_total / l1_count : 0
      l2_avg = l2_count > 0 ? l2_total / l2_count : 0
      nomic_overall = nomic_scores&.dig(key, :overall) || 0

      # Calibration score: 10 - abs_error (lower error = better metacognition)
      cal_errors = all_results.map { |_, d| d[:calibration]&.dig(key, :abs_calibration_error) }.compact
      cal_score = cal_errors.empty? ? 5.0 : [10.0 - (cal_errors.sum / cal_errors.size) * 2, 0].max

      # Combined: 40% response + 25% evaluator + 15% calibration + 20% nomic
      combined = if nomic_scores
                   0.40 * l1_avg + 0.25 * l2_avg + 0.15 * cal_score + 0.20 * (nomic_overall * 10)
                 else
                   0.50 * l1_avg + 0.30 * l2_avg + 0.20 * cal_score
                 end

      { key: key, l1: l1_avg.round(2), l2: l2_avg.round(2), cal: cal_score.round(2),
        nomic: (nomic_overall * 10).round(2), combined: combined.round(2) }
    end

    ranked = rankings.sort_by { |r| -r[:combined] }

    header = "| Rank | Model | Response (L1) | Evaluator (L2) | Calibration (L0.5) | Nomic | Combined |"
    sep = "|----|----|----|----|----|----|-----|"
    rows = ranked.each_with_index.map do |r, i|
      nomic_col = nomic_scores ? r[:nomic].to_s : "N/A"
      "| #{i + 1} | #{MODELS[r[:key]][:label]} | #{r[:l1]} | #{r[:l2]} | #{r[:cal]} | #{nomic_col} | #{r[:combined]} |"
    end

    [header, sep, *rows].join("\n")
  end
end

# ──────────────────────────────────────────────────────────────
# Main Pipeline
# ──────────────────────────────────────────────────────────────

class CrossEvalPipeline
  def initialize(options)
    @task_ids = options[:tasks]
    @output_dir = options[:output_dir]
    @run_nomic = options[:nomic]
    @nomic_rounds = options[:nomic_rounds]
    @model_keys = options[:models]
    @skip_layer0 = options[:skip_layer0]
    @layer2_samples = options[:layer2_samples]
    @dry_run = options[:dry_run]

    FileUtils.mkdir_p(@output_dir)
    @runner = CLIRunner.new(@output_dir, dry_run: @dry_run)
  end

  def run
    puts "=" * 60
    puts "LLM Cross-Evaluation Pipeline"
    puts "Tasks: #{@task_ids.join(', ')}"
    puts "Models: #{@model_keys.map { |k| MODELS[k][:label] }.join(', ')}"
    puts "Nomic: #{@run_nomic ? "#{@nomic_rounds} rounds" : 'disabled'}"
    puts "Output: #{@output_dir}"
    puts "=" * 60

    all_results = {}

    @task_ids.each do |task_id|
      task = TaskLoader.load(task_id)

      # Layer 0: Task execution
      responses = if @skip_layer0
                    load_cached_responses(task_id)
                  else
                    Layer0Executor.new(@runner, @model_keys).execute(task)
                  end

      # Layer 0.5: Self-calibration (metacognitive)
      layer05 = Layer05Calibrator.new(@runner, @model_keys).calibrate(task, responses)

      # Layer 1: Cross-evaluation
      layer1 = Layer1Evaluator.new(@runner, @model_keys).evaluate(task, responses)

      # Layer 0.5 calibration analysis (requires L1 results)
      calibration = Layer05Calibrator.compute_calibration(layer05, layer1, @model_keys, task: task)

      # Layer 2: Meta-evaluation (with optional sampling)
      layer2 = Layer2MetaEvaluator.new(@runner, @model_keys, sample_size: @layer2_samples).evaluate(task, responses, layer1)

      # Bias detection
      bias = BiasDetector.analyze(layer1, @model_keys)

      all_results[task_id] = {
        task: task,
        responses: responses,
        layer05: layer05,
        calibration: calibration,
        layer1: layer1,
        layer2: layer2,
        bias: bias,
      }

      # Save intermediate results
      save_json(task_id, all_results[task_id])
    end

    # Nomic game
    nomic_scores = nil
    nomic_data = nil
    if @run_nomic
      game = NomicGame.new(@runner, @model_keys, num_rounds: @nomic_rounds)
      nomic_scores = game.play
      nomic_data = {
        scores: nomic_scores,
        history: game.history,
        postgame: game.postgame_reflections,
      }

      # Save nomic data (including postgame reflections)
      nomic_path = File.join(@output_dir, "nomic_results.json")
      File.write(nomic_path, JSON.pretty_generate(nomic_data))
      puts "  Nomic results saved: #{nomic_path}"
    end

    # Generate match report
    tasks = @task_ids.map { |id| TaskLoader.load(id) }
    ReportGenerator.generate(@output_dir, tasks, @model_keys, all_results,
                             nomic_scores: nomic_scores, nomic_data: nomic_data)
  end

  private

  def load_cached_responses(task_id)
    @model_keys.each_with_object({}) do |key, h|
      path = File.join(@output_dir, "responses", "layer0_#{task_id}_#{key}.txt")
      if File.exist?(path)
        h[key] = File.read(path)
      else
        warn "[WARN] No cached response for #{key} on #{task_id}"
        h[key] = "[MISSING] No cached response"
      end
    end
  end

  def save_json(task_id, data)
    # Save all layers as JSON (skip responses which are large text)
    json_path = File.join(@output_dir, "results_#{task_id}.json")
    serializable = {
      layer05: data[:layer05],
      calibration: data[:calibration],
      layer1: data[:layer1],
      layer2: data[:layer2],
      bias: data[:bias],
    }
    File.write(json_path, JSON.pretty_generate(serializable))
  end
end

# ──────────────────────────────────────────────────────────────
# CLI Entry Point
# ──────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  options = {
    tasks: ["logic_reasoning"],
    output_dir: "log/cross_eval_#{Time.now.strftime('%Y%m%d')}",
    nomic: false,
    nomic_rounds: 5,
    models: DEFAULT_MODELS.dup,
    skip_layer0: false,
    layer2_samples: nil,
    dry_run: false,
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on("--tasks TASKS", "Comma-separated task IDs") do |v|
      options[:tasks] = v.split(",").map(&:strip)
    end

    opts.on("--output-dir DIR", "Output directory") do |v|
      options[:output_dir] = v
    end

    opts.on("--nomic", "Include Minimum Nomic game") do
      options[:nomic] = true
    end

    opts.on("--nomic-rounds N", Integer, "Number of Nomic rounds") do |v|
      options[:nomic_rounds] = v
    end

    opts.on("--models MODELS", "Comma-separated model keys") do |v|
      options[:models] = v.split(",").map(&:strip)
    end

    opts.on("--skip-layer0", "Skip task execution, use cached responses") do
      options[:skip_layer0] = true
    end

    opts.on("--layer2-samples N", Integer, "Sample N evaluations per evaluator for Layer 2 (default: all)") do |v|
      options[:layer2_samples] = v
    end

    opts.on("--dry-run", "Generate prompts only") do
      options[:dry_run] = true
    end

    opts.on("--list-tasks", "List available tasks") do
      puts "Available tasks:"
      TaskLoader.available.each { |t| puts "  - #{t}" }
      exit
    end

    opts.on("--list-models", "List available models") do
      puts "Available models:"
      MODELS.each { |k, v| puts "  - #{k}: #{v[:label]} (#{v[:tool]})" }
      exit
    end
  end.parse!

  # Validate models
  invalid = options[:models] - MODELS.keys
  unless invalid.empty?
    abort "Unknown models: #{invalid.join(', ')}. Use --list-models to see available."
  end

  # Validate tasks
  options[:tasks].each do |task_id|
    unless TaskLoader.available.include?(task_id)
      abort "Unknown task: #{task_id}. Use --list-tasks to see available."
    end
  end

  CrossEvalPipeline.new(options).run
end
