# frozen_string_literal: true

module KairosMcp
  class Daemon
    # ScopeClassifier — deterministic path → scope mapping.
    #
    # Design (P3.2 v0.2 §2):
    #   Pure function. No side effects. No LLM involvement.
    #   .kairos/ is a closed namespace: unmatched .kairos/** → L0 (fail-closed).
    #   Only paths outside .kairos/ and KairosChain_mcp_server/ default to L2.
    module ScopeClassifier
      # @param absolute_path [String] must be an absolute path
      # @param workspace_root [String] workspace root directory
      # @return [Hash] frozen { scope:, auto_approve:, reason:, matched_rule: }
      def self.classify(absolute_path, workspace_root: Dir.pwd)
        raise ArgumentError, 'path must be absolute' unless absolute_path.start_with?('/')

        rel = rel_path(absolute_path, workspace_root)
        return rule(:core_code,      :l0)              if rel.start_with?('KairosChain_mcp_server/')
        return rule(:skills_dsl,     :l0)              if rel.start_with?('.kairos/skills/')
        return rule(:knowledge,      :l1)              if rel.start_with?('.kairos/knowledge/')
        return rule(:context,        :l2, auto: true)  if rel.start_with?('.kairos/context/')
        return rule(:skillset,       :l0)              if rel.start_with?('.kairos/skillsets/')
        # Fail-closed: ANY unmatched .kairos/ path is L0
        return rule(:kairos_unknown, :l0)              if rel.start_with?('.kairos/') || rel == '.kairos'
        rule(:general_workspace, :l2, auto: true)
      end

      # @api private
      def self.rule(name, scope, auto: false)
        { scope: scope, auto_approve: auto,
          reason: "matched #{name}", matched_rule: name }.freeze
      end

      # @api private
      def self.rel_path(abs, root)
        abs_n  = File.expand_path(abs)
        root_n = File.expand_path(root)
        raise ArgumentError, 'path escapes workspace' unless abs_n.start_with?(root_n + '/')
        abs_n[(root_n.length + 1)..]
      end
    end
  end
end
