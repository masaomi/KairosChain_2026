# frozen_string_literal: true

require_relative '../skill_contexts'

module KairosMcp
  module DslAst
    # AST -> Natural language reverse conversion
    # Template-based decompilation of definition nodes to human-readable Markdown.
    # Used for: drift detection comparison, formalization_record decompile_text field.
    class Decompiler
      # Decompile a full definition to Markdown
      # @param definition [KairosMcp::DefinitionContext] the definition to decompile
      # @return [String] Markdown representation
      def self.decompile(definition)
        return "" unless definition && definition.nodes && !definition.nodes.empty?

        lines = ["## Definition (Decompiled)\n"]

        definition.nodes.each do |node|
          lines << decompile_node(node)
        end

        lines.join("\n")
      end

      # Decompile a single node to a Markdown line
      # @param node [KairosMcp::AstNode] the node to decompile
      # @return [String] Markdown representation
      def self.decompile_node(node)
        case node.type
        when :Constraint
          decompile_constraint(node)
        when :Check
          decompile_check(node)
        when :Plan
          decompile_plan(node)
        when :ToolCall
          decompile_tool_call(node)
        when :SemanticReasoning
          decompile_semantic_reasoning(node)
        else
          "- **Unknown** (`#{node.name}`): type=#{node.type}"
        end
      end

      private

      def self.decompile_constraint(node)
        opts = node.options || {}
        parts = ["- **Requirement** (`#{node.name}`)"]

        if opts[:condition]
          parts << ": #{opts[:condition]}"
        end

        qualifiers = []
        qualifiers << "required" if opts[:required]
        qualifiers << "timing: #{opts[:timing]}" if opts[:timing]
        qualifiers << "scope: #{opts[:scope]}" if opts[:scope]
        qualifiers << "target: #{opts[:target]}" if opts[:target]

        parts << " [#{qualifiers.join(', ')}]" unless qualifiers.empty?

        parts.join
      end

      def self.decompile_check(node)
        opts = node.options || {}
        line = "- **Check** (`#{node.name}`)"
        line += ": #{opts[:condition]}" if opts[:condition]
        line
      end

      def self.decompile_plan(node)
        opts = node.options || {}
        steps = opts[:steps] || []
        step_str = steps.map(&:to_s).join(" -> ")
        "- **Workflow** (`#{node.name}`): #{steps.size} steps — #{step_str}"
      end

      def self.decompile_tool_call(node)
        opts = node.options || {}
        line = "- **Tool Call** (`#{node.name}`)"
        line += ": `#{opts[:command]}`" if opts[:command]
        line
      end

      def self.decompile_semantic_reasoning(node)
        opts = node.options || {}
        prompt = opts[:prompt] || "(no prompt)"
        "- **Human Judgment Required** (`#{node.name}`): #{prompt}"
      end
    end
  end
end
