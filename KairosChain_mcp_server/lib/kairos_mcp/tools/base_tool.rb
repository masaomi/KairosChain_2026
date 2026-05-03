require 'json'
require_relative '../invocation_context'

module KairosMcp
  module Tools
    class BaseTool
      def initialize(safety = nil, registry: nil)
        @safety = safety
        @registry = registry
      end

      # Invoke another tool through the same ToolRegistry, preserving the
      # full gate pipeline and invocation policy (whitelist/blacklist/depth).
      # Only available when the tool was registered with a registry reference.
      def invoke_tool(tool_name, arguments = {}, context: nil)
        raise "Tool invocation not available (no registry)" unless @registry

        ctx = context || InvocationContext.new
        child_ctx = ctx.child(caller_tool: name)

        unless child_ctx.allowed?(tool_name)
          raise InvocationContext::PolicyDeniedError,
                "Tool '#{tool_name}' blocked by invocation policy (caller: #{name})"
        end

        @registry.call_tool(tool_name, arguments, invocation_context: child_ctx)
      end

      def name
        raise NotImplementedError
      end

      def description
        raise NotImplementedError
      end

      def input_schema
        raise NotImplementedError
      end

      def call(arguments)
        raise NotImplementedError
      end

      # Metadata methods for tool discovery and guidance
      # Override in subclasses to provide tool-specific metadata

      # Category for grouping tools in catalog
      # @return [Symbol] one of :chain, :knowledge, :context, :skills, :resource, :state, :guide, :utility
      def category
        :utility
      end

      # Tags for keyword-based search and recommendations
      # @return [Array<String>] list of usecase tags (e.g., ["save", "update", "L1"])
      def usecase_tags
        []
      end

      # Usage examples for this tool
      # @return [Array<Hash>] list of examples with :title and :code keys
      def examples
        []
      end

      # Related tools that are often used together
      # @return [Array<String>] list of tool names
      def related_tools
        []
      end

      # Phase 1.5 — Capability Boundary self-articulation.
      # Override in subclasses to declare harness dependence.
      # Default :core means MCP + filesystem only, no subprocess, no harness-specific tool.
      # See docs/drafts/capability_boundary_design_v1.1.md for the 8 invariants and tier rules.
      #
      # @return [Symbol, Hash] :core | :harness_assisted | :harness_specific
      #                       OR Hash with keys: tier, requires_externals, requires_harness_features,
      #                       fallback_chain, degrades_to, target_harness, reason, note, acknowledgment
      def harness_requirement
        :core
      end

      # Schema for MCP protocol
      def to_schema
        {
          name: name,
          description: description,
          inputSchema: input_schema
        }
      end

      # Extended schema including metadata (for internal use)
      def to_full_schema
        {
          name: name,
          description: description,
          inputSchema: input_schema,
          _metadata: {
            category: category,
            usecase_tags: usecase_tags,
            examples: examples,
            related_tools: related_tools
          }
        }
      end

      protected

      def text_content(text)
        [
          {
            type: 'text',
            text: text
          }
        ]
      end

      # Phase 1.5 — runtime acknowledgment helper (Acknowledgment invariant).
      # Wrap a tool's actual work to articulate which harness path was actually
      # used during this invocation. Block returns inner Hash; helper merges
      # `harness_assistance_used:` field and produces the MCP text_content envelope.
      #
      # Example:
      #   def call(args)
      #     with_acknowledgment(path_taken: 'claude_code_agent_personas',
      #                         tier: :harness_specific,
      #                         target_harness: :claude_code) do
      #       { result: '...', status: 'ok' }
      #     end
      #   end
      def with_acknowledgment(path_taken:, tier:, target_harness: nil, &block)
        inner = block.call
        unless inner.is_a?(Hash)
          raise ArgumentError, 'with_acknowledgment block must return Hash'
        end
        ack = {
          path_taken: path_taken,
          tier_actually_used: tier,
          target_harness: target_harness,
          acknowledgment: "this invocation used #{tier} path '#{path_taken}'" \
                          "#{target_harness ? " (target_harness: #{target_harness})" : ''}" \
                          ' — articulated per Acknowledgment invariant'
        }
        merged = inner.merge(harness_assistance_used: ack)
        text_content(JSON.pretty_generate(merged))
      end
    end
  end
end
