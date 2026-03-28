# frozen_string_literal: true

require 'digest'
require 'json'

module Autoexec
  # Immutable data structures for task plans
  TaskPlan = Struct.new(:task_id, :meta, :steps, :source_hash, keyword_init: true) do
    def to_h
      { task_id: task_id, meta: meta, steps: steps.map(&:to_h), source_hash: source_hash }
    end
  end

  TaskStep = Struct.new(:step_id, :action, :risk, :depends_on,
                        :requires_human_cognition,
                        :tool_name, :tool_arguments,
                        keyword_init: true) do
    def to_h
      h = { step_id: step_id, action: action, risk: risk,
            depends_on: depends_on, requires_human_cognition: requires_human_cognition }
      h[:tool_name] = tool_name if tool_name
      h[:tool_arguments] = tool_arguments if tool_arguments
      h
    end
  end

  TaskMeta = Struct.new(:description, :risk_default, :premise_assumptions, keyword_init: true) do
    def to_h
      { description: description, risk_default: risk_default,
        premise_assumptions: premise_assumptions }
    end
  end

  # Regex/state-machine DSL parser. NO eval, NO instance_eval, NO BasicObject sandbox.
  # Parses a restricted DSL format:
  #
  #   task :task_id do
  #     meta description: "...", risk_default: :low
  #     step :step_id, action: "...", risk: :low, depends_on: [:other]
  #   end
  #
  # Also accepts JSON input via from_json.
  class TaskDsl
    ALLOWED_STEP_KEYS = %i[action risk depends_on requires_human_cognition].freeze
    ALLOWED_META_KEYS = %i[description risk_default premise_assumptions].freeze
    ALLOWED_RISK_VALUES = %i[low medium high].freeze

    # Dangerous patterns that must never appear in DSL source
    FORBIDDEN_PATTERNS = [
      /\beval\b/, /\bsystem\b/, /\bexec\b/, /\b`[^`]*`/,
      /\brequire\b/, /\bload\b/, /\bFile\b/, /\bIO\b/,
      /\bKernel\b/, /\bProcess\b/, /\bObjectSpace\b/,
      /\b__send__\b/, /\bsend\b/, /\bmethod\b/,
      /\binstance_eval\b/, /\binstance_exec\b/, /\bclass_eval\b/,
      /\bconst_get\b/, /\bconst_set\b/,
      /\bopen\b/, /\bsocket\b/i, /\bnet\/http\b/i,
      /\bENV\b/, /\bSTDIN\b/, /\bSTDOUT\b/, /\bSTDERR\b/,
    ].freeze

    class ParseError < StandardError; end

    # --- Public API ---

    def self.parse(source)
      raise ParseError, 'Source is empty' if source.nil? || source.strip.empty?

      # Security: check for forbidden patterns before parsing
      check_forbidden!(source)

      task_id = extract_task_id(source)
      meta = extract_meta(source)
      steps = extract_steps(source)

      plan = TaskPlan.new(
        task_id: task_id,
        meta: meta,
        steps: steps,
        source_hash: compute_hash(source)
      )

      errors = validate(plan)
      raise ParseError, "Validation errors: #{errors.join(', ')}" unless errors.empty?

      plan
    end

    def self.from_json(json_string)
      data = JSON.parse(json_string, symbolize_names: true)

      task_id = data[:task_id]&.to_s
      raise ParseError, 'Missing task_id in JSON' unless task_id && !task_id.empty?
      raise ParseError, "Invalid task_id '#{task_id}': must contain only word characters" unless task_id.match?(/\A\w+\z/)

      task_id = task_id.to_sym

      meta = TaskMeta.new(
        description: data.dig(:meta, :description) || '',
        risk_default: (data.dig(:meta, :risk_default) || 'medium').to_sym,
        premise_assumptions: data.dig(:meta, :premise_assumptions) || []
      )

      steps = (data[:steps] || []).map do |s|
        risk = (s[:risk] || meta.risk_default).to_sym
        raise ParseError, "Invalid risk '#{risk}' for step #{s[:step_id]}" unless ALLOWED_RISK_VALUES.include?(risk)

        deps = Array(s[:depends_on]).map(&:to_sym)

        # tool_arguments: deep-stringify keys to avoid symbol/string mismatch
        raw_args = s[:tool_arguments]
        tool_args = raw_args ? deep_stringify_keys(raw_args) : nil

        TaskStep.new(
          step_id: s[:step_id].to_sym,
          action: s[:action] || '',
          risk: risk,
          depends_on: deps,
          requires_human_cognition: s[:requires_human_cognition] == true,
          tool_name: s[:tool_name]&.to_s,
          tool_arguments: tool_args
        )
      end

      has_executable = steps.any? { |s| s.tool_name }
      plan = TaskPlan.new(task_id: task_id, meta: meta, steps: steps, source_hash: nil)

      if has_executable
        # Executable plans: hash from canonical JSON (no DSL involved)
        plan_hash = compute_plan_hash(plan)
      else
        # Legacy plans: hash from DSL source
        source = to_source(plan)
        check_forbidden!(source)
        plan_hash = compute_hash(source)
      end
      plan = TaskPlan.new(task_id: task_id, meta: meta, steps: steps, source_hash: plan_hash)

      errors = validate(plan)
      raise ParseError, "Validation errors: #{errors.join(', ')}" unless errors.empty?

      plan
    end

    def self.validate(plan)
      errors = []
      errors << 'Missing task_id' unless plan.task_id

      max_steps = Autoexec.config.dig('max_steps') || 20
      errors << "Too many steps (#{plan.steps.size} > #{max_steps})" if plan.steps.size > max_steps

      step_ids = plan.steps.map(&:step_id)
      dupes = step_ids.select { |id| step_ids.count(id) > 1 }.uniq
      errors << "Duplicate step IDs: #{dupes.join(', ')}" unless dupes.empty?

      plan.steps.each do |step|
        step.depends_on.each do |dep|
          errors << "Step #{step.step_id} depends on unknown step #{dep}" unless step_ids.include?(dep)
        end
        errors << "Invalid risk '#{step.risk}' for step #{step.step_id}" unless ALLOWED_RISK_VALUES.include?(step.risk)

        # Validate tool_name / tool_arguments (Phase 2)
        if step.tool_name
          if step.tool_name.empty?
            errors << "Empty tool_name for step #{step.step_id}"
          elsif !step.tool_name.match?(/\A[a-z][a-z0-9_]*\z/)
            errors << "Invalid tool_name '#{step.tool_name}' for step #{step.step_id}"
          end
        end
        if step.tool_arguments && !step.tool_arguments.is_a?(Hash)
          errors << "tool_arguments must be a Hash for step #{step.step_id}"
        end
      end

      # Check for circular dependencies
      errors << 'Circular dependency detected' if circular_dependency?(plan.steps)

      errors
    end

    def self.to_source(plan)
      lines = ["task :#{plan.task_id} do"]

      if plan.meta
        meta_parts = []
        meta_parts << "description: #{plan.meta.description.inspect}" if plan.meta.description && !plan.meta.description.empty?
        meta_parts << "risk_default: :#{plan.meta.risk_default}" if plan.meta.risk_default
        lines << "  meta #{meta_parts.join(', ')}" unless meta_parts.empty?
      end

      lines << '' if plan.meta && !plan.steps.empty?

      plan.steps.each do |step|
        parts = ["action: #{step.action.inspect}"]
        parts << "risk: :#{step.risk}"
        parts << "depends_on: [#{step.depends_on.map { |d| ":#{d}" }.join(', ')}]" unless step.depends_on.empty?
        parts << 'requires_human_cognition: true' if step.requires_human_cognition
        lines << "  step :#{step.step_id}, #{parts.join(', ')}"
      end

      lines << 'end'
      lines.join("\n") + "\n"
    end

    def self.compute_hash(source)
      Digest::SHA256.hexdigest(source)
    end

    # Canonical JSON for executable plans (deterministic, sorted keys)
    def self.canonical_plan_json(plan)
      steps = plan.steps.map { |s| canonical_step(s) }
      JSON.generate({
        task_id: plan.task_id.to_s,
        meta: plan.meta ? { description: plan.meta.description, risk_default: plan.meta.risk_default.to_s } : nil,
        steps: steps
      })
    end

    def self.compute_plan_hash(plan)
      Digest::SHA256.hexdigest(canonical_plan_json(plan))
    end

    def self.deep_stringify_keys(obj)
      case obj
      when Hash then obj.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
      when Array then obj.map { |v| deep_stringify_keys(v) }
      else obj
      end
    end

    # --- Private ---

    class << self
      private

      def canonical_step(step)
        h = {
          step_id: step.step_id.to_s,
          action: step.action,
          risk: step.risk.to_s,
          depends_on: step.depends_on.map(&:to_s).sort,
          requires_human_cognition: step.requires_human_cognition || false
        }
        h[:tool_name] = step.tool_name if step.tool_name
        h[:tool_arguments] = sort_keys_deep(step.tool_arguments) if step.tool_arguments
        h
      end

      def sort_keys_deep(obj)
        case obj
        when Hash then obj.sort_by { |k, _| k.to_s }.to_h.transform_values { |v| sort_keys_deep(v) }
        when Array then obj.map { |v| sort_keys_deep(v) }
        else obj
        end
      end

      def check_forbidden!(source)
        FORBIDDEN_PATTERNS.each do |pat|
          match = source.match(pat)
          if match
            raise ParseError, "Forbidden pattern detected: #{match[0].inspect}. DSL must not contain executable Ruby."
          end
        end
      end

      def extract_task_id(source)
        match = source.match(/\Atask\s+:(\w+)\s+do\s*$/)
        raise ParseError, 'Invalid task declaration. Expected: task :task_id do' unless match

        match[1].to_sym
      end

      def extract_meta(source)
        match = source.match(/^\s*meta\s+(.+)$/)
        return TaskMeta.new(description: '', risk_default: :medium, premise_assumptions: []) unless match

        meta_str = match[1].strip
        desc_match = meta_str.match(/description:\s*"([^"]*)"/)
        risk_match = meta_str.match(/risk_default:\s*:(\w+)/)

        description = desc_match ? desc_match[1] : ''
        risk_default = risk_match ? risk_match[1].to_sym : :medium

        raise ParseError, "Invalid risk_default: #{risk_default}" unless ALLOWED_RISK_VALUES.include?(risk_default)

        TaskMeta.new(description: description, risk_default: risk_default, premise_assumptions: [])
      end

      def extract_steps(source)
        steps = []
        source.scan(/^\s*step\s+:(\w+),\s*(.+)$/) do |step_id, rest|
          step = parse_step_line(step_id, rest)
          steps << step
        end
        steps
      end

      def parse_step_line(step_id, rest)
        action_match = rest.match(/action:\s*"([^"]*)"/)
        risk_match = rest.match(/risk:\s*:(\w+)/)
        deps_match = rest.match(/depends_on:\s*\[([^\]]*)\]/)
        cognition_match = rest.match(/requires_human_cognition:\s*(true|false)/)

        action = action_match ? action_match[1] : ''
        risk = risk_match ? risk_match[1].to_sym : :medium
        depends_on = deps_match ? deps_match[1].scan(/:(\w+)/).flatten.map(&:to_sym) : []
        requires_human_cognition = cognition_match ? cognition_match[1] == 'true' : false

        raise ParseError, "Invalid risk '#{risk}' for step #{step_id}" unless ALLOWED_RISK_VALUES.include?(risk)
        raise ParseError, "Empty action for step #{step_id}" if action.empty? && action_match.nil?

        # Check for unknown keys (strip quoted strings first to avoid false positives)
        known_keys = %w[action risk depends_on requires_human_cognition]
        rest_without_strings = rest.gsub(/"[^"]*"/, '""')
        rest_without_strings.scan(/(\w+):/).each do |key_match|
          key = key_match[0]
          unless known_keys.include?(key)
            raise ParseError, "Unknown step key '#{key}' in step #{step_id}. Allowed: #{known_keys.join(', ')}"
          end
        end

        TaskStep.new(
          step_id: step_id.to_sym,
          action: action,
          risk: risk,
          depends_on: depends_on,
          requires_human_cognition: requires_human_cognition
        )
      end

      def circular_dependency?(steps)
        step_map = steps.map { |s| [s.step_id, s.depends_on] }.to_h
        visited = {}

        detect_cycle = lambda do |node, path|
          return true if path.include?(node)
          return false if visited[node]

          visited[node] = true
          (step_map[node] || []).any? { |dep| detect_cycle.call(dep, path + [node]) }
        end

        step_map.keys.any? { |node| detect_cycle.call(node, []) }
      end
    end
  end
end
