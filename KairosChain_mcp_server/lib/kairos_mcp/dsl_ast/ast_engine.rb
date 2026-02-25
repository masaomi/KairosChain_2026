# frozen_string_literal: true

require_relative '../skill_contexts'

module KairosMcp
  module DslAst
    # Result of evaluating a single AST node
    NodeResult = Struct.new(:node_name, :node_type, :satisfied, :detail, :evaluable, keyword_init: true)

    # Result of verifying all definition nodes for a skill
    VerificationReport = Struct.new(:skill_id, :results, :timestamp, keyword_init: true) do
      # All deterministic (evaluable) nodes passed?
      def all_deterministic_passed?
        results.select(&:evaluable).all? { |r| r.satisfied == true }
      end

      # Nodes that require human judgment
      def human_required
        results.reject(&:evaluable)
      end

      # Summary counts
      def summary
        total = results.size
        passed = results.count { |r| r.evaluable && r.satisfied == true }
        failed = results.count { |r| r.evaluable && r.satisfied == false }
        unknown = results.count { |r| r.evaluable && r.satisfied == :unknown }
        non_evaluable = results.count { |r| !r.evaluable }
        { total: total, passed: passed, failed: failed, unknown: unknown, human_required: non_evaluable }
      end
    end

    # AST node evaluation engine
    # Verifies definition nodes against a binding context without using eval.
    # Design: verification-only — does not replace behavior block execution.
    # NOTE: The engine itself is infrastructure in Phase 2.
    # Policy aspects (drift thresholds, etc.) may become a SkillSet in Phase 3.
    class AstEngine
      # Allowed methods for condition evaluation via send().
      # Only query methods (no side effects) are permitted.
      ALLOWED_METHODS = %i[
        can_evolve? has_tool? include? key? empty? nil?
        is_a? respond_to? size length count
      ].freeze

      # Verify all definition nodes for a skill
      # @param skill [KairosMcp::SkillsDsl::Skill] the skill to verify
      # @param binding_context [Hash] runtime values for condition evaluation
      # @return [VerificationReport]
      def self.verify(skill, binding_context: {})
        return nil unless skill.definition

        results = skill.definition.nodes.map do |node|
          evaluate_node(node, binding_context: binding_context)
        end

        VerificationReport.new(
          skill_id: skill.id,
          results: results,
          timestamp: Time.now.iso8601
        )
      end

      # Evaluate a single AST node
      # @param node [KairosMcp::AstNode] the node to evaluate
      # @param binding_context [Hash] runtime values for condition evaluation
      # @return [NodeResult]
      def self.evaluate_node(node, binding_context: {})
        case node.type
        when :Constraint
          evaluate_constraint(node, binding_context)
        when :Check
          evaluate_check(node, binding_context)
        when :Plan
          evaluate_plan(node)
        when :ToolCall
          evaluate_tool_call(node)
        when :SemanticReasoning
          evaluate_semantic_reasoning(node)
        else
          NodeResult.new(
            node_name: node.name,
            node_type: node.type,
            satisfied: :unknown,
            detail: "Unknown node type: #{node.type}",
            evaluable: false
          )
        end
      end

      private

      # Evaluate Constraint node via pattern matching (no eval)
      def self.evaluate_constraint(node, binding_context)
        opts = node.options || {}
        condition = opts[:condition]

        if condition.nil?
          # No condition string — check if required key exists in context
          if opts[:required] == true
            # Constraint is a declaration; structurally valid
            return NodeResult.new(
              node_name: node.name,
              node_type: :Constraint,
              satisfied: true,
              detail: "Required constraint declared (structural)",
              evaluable: true
            )
          end

          return NodeResult.new(
            node_name: node.name,
            node_type: :Constraint,
            satisfied: true,
            detail: "Constraint declared (no condition to evaluate)",
            evaluable: true
          )
        end

        # Pattern match the condition string
        result = match_condition(condition, binding_context)
        NodeResult.new(
          node_name: node.name,
          node_type: :Constraint,
          satisfied: result[:satisfied],
          detail: result[:detail],
          evaluable: result[:evaluable]
        )
      end

      # Evaluate Check node
      def self.evaluate_check(node, binding_context)
        opts = node.options || {}
        condition = opts[:condition]

        unless condition
          return NodeResult.new(
            node_name: node.name,
            node_type: :Check,
            satisfied: :unknown,
            detail: "No condition specified",
            evaluable: false
          )
        end

        result = match_condition(condition, binding_context)
        NodeResult.new(
          node_name: node.name,
          node_type: :Check,
          satisfied: result[:satisfied],
          detail: result[:detail],
          evaluable: result[:evaluable]
        )
      end

      # Evaluate Plan node — structural validity (steps exist and are named)
      def self.evaluate_plan(node)
        opts = node.options || {}
        steps = opts[:steps]

        unless steps.is_a?(Array) && !steps.empty?
          return NodeResult.new(
            node_name: node.name,
            node_type: :Plan,
            satisfied: false,
            detail: "Plan has no steps defined",
            evaluable: true
          )
        end

        NodeResult.new(
          node_name: node.name,
          node_type: :Plan,
          satisfied: true,
          detail: "Plan has #{steps.size} steps: #{steps.map(&:to_s).join(' -> ')}",
          evaluable: true
        )
      end

      # Evaluate ToolCall node — command recognition (does not execute)
      def self.evaluate_tool_call(node)
        opts = node.options || {}
        command = opts[:command]

        unless command && !command.to_s.strip.empty?
          return NodeResult.new(
            node_name: node.name,
            node_type: :ToolCall,
            satisfied: false,
            detail: "No command specified",
            evaluable: true
          )
        end

        NodeResult.new(
          node_name: node.name,
          node_type: :ToolCall,
          satisfied: true,
          detail: "Command recognized: #{command}",
          evaluable: true
        )
      end

      # SemanticReasoning — explicitly non-evaluable (requires human judgment)
      def self.evaluate_semantic_reasoning(node)
        opts = node.options || {}
        prompt = opts[:prompt] || "(no prompt)"

        NodeResult.new(
          node_name: node.name,
          node_type: :SemanticReasoning,
          satisfied: :unknown,
          detail: "Requires human judgment: #{prompt}",
          evaluable: false
        )
      end

      # Pattern-match a condition string against binding_context
      # Supported patterns:
      #   "X == true/false" — boolean comparison
      #   "X == VALUE" — equality comparison
      #   "X < Y" / "X > Y" / "X >= Y" / "X <= Y" — numeric comparison
      #   "X.method?(arg)" — method call on context object
      #   "X not in Y" — exclusion check
      # Unsupported patterns return evaluable: false
      def self.match_condition(condition, binding_context)
        # Pattern: "X == true" or "X == false"
        if condition =~ /\A(\w+)\s*==\s*(true|false)\z/
          var_name = $1.to_sym
          expected = $2 == 'true'
          if binding_context.key?(var_name)
            actual = binding_context[var_name]
            return {
              satisfied: actual == expected,
              detail: "#{var_name}: expected #{expected}, got #{actual}",
              evaluable: true
            }
          else
            return {
              satisfied: :unknown,
              detail: "Variable '#{var_name}' not in binding context",
              evaluable: false
            }
          end
        end

        # Pattern: "X < Y" or "X > Y" or "X >= Y" or "X <= Y"
        if condition =~ /\A(\w+)\s*(<|>|<=|>=)\s*(\w+)\z/
          left_name = $1.to_sym
          op = $2
          right_name = $3.to_sym

          left_val = binding_context.key?(left_name) ? binding_context[left_name] : nil
          right_val = binding_context.key?(right_name) ? binding_context[right_name] : nil

          if left_val.nil? || right_val.nil?
            missing = []
            missing << left_name unless binding_context.key?(left_name)
            missing << right_name unless binding_context.key?(right_name)
            return {
              satisfied: :unknown,
              detail: "Missing variables: #{missing.join(', ')}",
              evaluable: false
            }
          end

          begin
            result = case op
                     when '<'  then left_val < right_val
                     when '>'  then left_val > right_val
                     when '<=' then left_val <= right_val
                     when '>=' then left_val >= right_val
                     end

            return {
              satisfied: result,
              detail: "#{left_name}(#{left_val}) #{op} #{right_name}(#{right_val}) = #{result}",
              evaluable: true
            }
          rescue TypeError, ArgumentError => e
            return {
              satisfied: :unknown,
              detail: "Type error in comparison: #{e.message}",
              evaluable: false
            }
          end
        end

        # Pattern: "X.method?(arg)"
        if condition =~ /\A(\w+)\.(\w+\??)\(([^)]*)\)\z/
          obj_name = $1.to_sym
          method_name = $2.to_sym
          arg_str = $3.strip

          if binding_context.key?(obj_name)
            obj = binding_context[obj_name]
            if obj.respond_to?(method_name)
              # Security: only allow whitelisted query methods (no side effects)
              unless ALLOWED_METHODS.include?(method_name)
                return {
                  satisfied: :unknown,
                  detail: "Method '#{method_name}' not in allowed list",
                  evaluable: false
                }
              end
              # Parse argument: try symbol, then string
              arg = arg_str.start_with?(':') ? arg_str[1..-1].to_sym : arg_str
              begin
                result = obj.send(method_name, arg)
                return {
                  satisfied: !!result,
                  detail: "#{obj_name}.#{method_name}(#{arg_str}) = #{result}",
                  evaluable: true
                }
              rescue StandardError => e
                return {
                  satisfied: :unknown,
                  detail: "Error calling #{method_name}: #{e.message}",
                  evaluable: false
                }
              end
            end
          end

          return {
            satisfied: :unknown,
            detail: "Cannot evaluate: #{condition}",
            evaluable: false
          }
        end

        # Pattern: "X not in Y"
        if condition =~ /\A(\w+)\s+not\s+in\s+(\w+)\z/
          item_name = $1.to_sym
          collection_name = $2.to_sym

          if binding_context.key?(item_name) && binding_context.key?(collection_name)
            item = binding_context[item_name]
            collection = binding_context[collection_name]
            if collection.respond_to?(:include?)
              result = !collection.include?(item)
              return {
                satisfied: result,
                detail: "#{item_name} not in #{collection_name}: #{result}",
                evaluable: true
              }
            end
          end

          return {
            satisfied: :unknown,
            detail: "Cannot evaluate exclusion: #{condition}",
            evaluable: false
          }
        end

        # Unrecognized pattern
        {
          satisfied: :unknown,
          detail: "Unrecognized condition pattern: #{condition}",
          evaluable: false
        }
      end
    end
  end
end
