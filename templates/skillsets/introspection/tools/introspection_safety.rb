# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Introspection
      module Tools
        # Visualize all active safety mechanisms across layers:
        # L0 approval workflow, RBAC policies, agent safety gates, blockchain health.
        class IntrospectionSafety < ::KairosMcp::Tools::BaseTool
          def name
            'introspection_safety'
          end

          def description
            'Visualize all active safety mechanisms across layers: ' \
            'L0 approval workflow, RBAC policies, agent safety gates, blockchain health.'
          end

          def category
            :introspection
          end

          def usecase_tags
            %w[safety rbac approval blockchain introspection]
          end

          def related_tools
            %w[introspection_check chain_verify]
          end

          def input_schema
            { type: 'object', properties: {} }
          end

          def call(_arguments)
            inspector = SafetyInspector.new
            result = inspector.inspect_safety
            text_content(JSON.pretty_generate(result))
          end
        end
      end
    end
  end
end
