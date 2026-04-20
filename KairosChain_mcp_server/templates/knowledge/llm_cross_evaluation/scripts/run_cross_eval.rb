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
    cmd: "gemini --model gemini-3.1-pro-preview --thinking-level medium --prompt",
    label: "Gemini 3.1 Pro",
    provider: "google",
    input_mode: :arg,
    thinking_effort: "medium",
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

  # ── Gemini effort variants ──
  "gemini_cli_31pro_low" => {
    tool: :gemini,
    cmd: "gemini --model gemini-3.1-pro-preview --thinking-level low --prompt",
    label: "Gemini 3.1 Pro (low)",
    provider: "google",
    input_mode: :arg,
    thinking_effort: "low",
  },
  "gemini_cli_31pro_high" => {
    tool: :gemini,
    cmd: "gemini --model gemini-3.1-pro-preview --thinking-level high --prompt",
    label: "Gemini 3.1 Pro (high)",
    provider: "google",
    input_mode: :arg,
    thinking_effort: "high",
  },
}.freeze

# Default model set (base models only). Use --models for variants.
DEFAULT_MODELS = %w[claude_opus46 claude_opus47 codex_gpt54 cursor_composer2 gemini_cli_31pro].freeze

BLIND_LABELS = ("A".."Z").map { |c| "Model #{c}" }.freeze

EVAL_CRITERIA_WEIGHTS = {
  "accuracy" => 0.25, "completeness" => 0.20,
  "logical_consistency" => 0.25, "clarity" => 0.15, "originality" => 0.15,
}.freeze

META_CRITERIA_WEIGHTS = {
  "fairness" => 0.30, "specificity" => 0.25,
  "coverage" => 0.25, "calibration" => 0.20,
}.freeze

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
        response_text = if inject_self && target_key == self_inject_target
                          responses[evaluator_key] # Self-injection
                        else
                          responses[target_key]
                        end

        prompt = PromptBuilder.render("cross_evaluation",
          task_prompt: task["prompt"],
          blind_label: label_map[target_key],
          response_text: response_text
        )

        eval_label = "layer1_#{task['id']}_#{evaluator_key}_evals_#{target_key}"
        response = @runner.execute(evaluator_key, prompt, label: eval_label)
        parsed = JSONParser.parse(response)

        if parsed
          parsed["_blind_label"] = label_map[target_key]
          parsed["_self_injected"] = (inject_self && target_key == self_inject_target)
          results[evaluator_key][target_key] = parsed
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

        @history << {
          round: round_num, player: player_key,
          proposal: proposal, votes: votes,
          adopted: adopted,
        }
      end
    end

    calculate_nomic_scores
  end

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
    prompt = PromptBuilder.render("nomic_proposal",
      player_name: MODELS[player_key][:label],
      rules_text: rules_text,
      history_text: history_text,
      next_rule_num: @next_rule_num
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

      # Simplified 2-layer scoring (Layer 1 + Layer 1.5)
      layer1 = adoption_rate * 0.4 + (1.0 - violation_penalty) * 0.6
      layer15 = 1.0 - violation_penalty

      scores[key] = {
        adoption_rate: adoption_rate.round(3),
        immutable_violations: m[:immutable_violations],
        layer1_score: layer1.round(3),
        layer15_score: layer15.round(3),
        overall: (0.55 * layer1 + 0.45 * layer15).round(3),
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
        scores_given << avg

        if data["_self_injected"]
          self_scores << avg
          next # Exclude self-injected from series-bias to avoid provider misattribution
        end

        target_provider = MODELS[target][:provider]
        if target_provider == provider
          same_provider_scores << avg
        else
          diff_provider_scores << avg
        end
      end

      mean_given = scores_given.empty? ? 0 : scores_given.sum / scores_given.size
      global_mean = 7.5 # Approximate expected mean

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
  def self.generate(output_dir, tasks, model_keys, all_results, nomic_scores: nil)
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

      # Layer 1 scores table
      report << "### Response Scores (Layer 1 Cross-Evaluation)"
      report << ""
      report << layer1_table(data[:layer1], model_keys)
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
    end

    # Overall ranking
    report << "---"
    report << "## Overall Ranking"
    report << ""
    report << overall_ranking(all_results, model_keys, nomic_scores)

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
      model_keys.each do |evaluated|
        scores_for_model = []
        model_keys.each do |evaluator|
          next if evaluator == evaluated
          eval_data = layer1.dig(evaluator, evaluated)
          next unless eval_data && eval_data["scores"]

          weighted = EVAL_CRITERIA_WEIGHTS.sum do |criterion, weight|
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

  def self.layer1_table(layer1, model_keys)
    header = "| Evaluated \\ Criterion | " + EVAL_CRITERIA_WEIGHTS.keys.map(&:capitalize).join(" | ") + " | Weighted |"
    sep = "|" + "----|" * (EVAL_CRITERIA_WEIGHTS.size + 2)
    rows = model_keys.map do |evaluated|
      scores_by_criterion = EVAL_CRITERIA_WEIGHTS.keys.map do |criterion|
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
        EVAL_CRITERIA_WEIGHTS.sum { |c, w| (eval_data["scores"][c] || 0) * w }
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

  def self.nomic_table(nomic_scores, model_keys)
    header = "| Player | Adoption Rate | Immutable Violations | Layer 1 | Layer 1.5 | Overall |"
    sep = "|----|----|----|----|----|----|"
    rows = model_keys.map do |key|
      s = nomic_scores[key] || {}
      "| #{MODELS[key][:label]} | #{s[:adoption_rate]} | #{s[:immutable_violations]} | #{s[:layer1_score]} | #{s[:layer15_score]} | #{s[:overall]} |"
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
        # L1: how well did this model's responses score?
        (data[:layer1] || {}).each do |evaluator, evals|
          next if evaluator == key
          eval_data = evals[key]
          next unless eval_data && eval_data["scores"]
          weighted = EVAL_CRITERIA_WEIGHTS.sum { |c, w| (eval_data["scores"][c] || 0) * w }
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

      # Combined: 50% response quality + 30% evaluator reliability + 20% nomic
      combined = if nomic_scores
                   0.50 * l1_avg + 0.30 * l2_avg + 0.20 * (nomic_overall * 10)
                 else
                   0.60 * l1_avg + 0.40 * l2_avg
                 end

      { key: key, l1: l1_avg.round(2), l2: l2_avg.round(2),
        nomic: (nomic_overall * 10).round(2), combined: combined.round(2) }
    end

    ranked = rankings.sort_by { |r| -r[:combined] }

    header = "| Rank | Model | Response (L1) | Evaluator (L2) | Nomic | Combined |"
    sep = "|----|----|----|----|----|-----|"
    rows = ranked.each_with_index.map do |r, i|
      nomic_col = nomic_scores ? r[:nomic].to_s : "N/A"
      "| #{i + 1} | #{MODELS[r[:key]][:label]} | #{r[:l1]} | #{r[:l2]} | #{nomic_col} | #{r[:combined]} |"
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

      # Layer 1: Cross-evaluation
      layer1 = Layer1Evaluator.new(@runner, @model_keys).evaluate(task, responses)

      # Layer 2: Meta-evaluation (with optional sampling)
      layer2 = Layer2MetaEvaluator.new(@runner, @model_keys, sample_size: @layer2_samples).evaluate(task, responses, layer1)

      # Bias detection
      bias = BiasDetector.analyze(layer1, @model_keys)

      all_results[task_id] = {
        responses: responses,
        layer1: layer1,
        layer2: layer2,
        bias: bias,
      }

      # Save intermediate results
      save_json(task_id, all_results[task_id])
    end

    # Nomic game
    nomic_scores = nil
    if @run_nomic
      game = NomicGame.new(@runner, @model_keys, num_rounds: @nomic_rounds)
      nomic_scores = game.play

      # Save nomic data
      nomic_path = File.join(@output_dir, "nomic_results.json")
      File.write(nomic_path, JSON.pretty_generate(
        scores: nomic_scores,
        history: game.history
      ))
      puts "  Nomic results saved: #{nomic_path}"
    end

    # Generate match report
    tasks = @task_ids.map { |id| TaskLoader.load(id) }
    ReportGenerator.generate(@output_dir, tasks, @model_keys, all_results, nomic_scores: nomic_scores)
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
    # Save layer1 and layer2 as JSON (skip responses which are large text)
    json_path = File.join(@output_dir, "results_#{task_id}.json")
    serializable = {
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
