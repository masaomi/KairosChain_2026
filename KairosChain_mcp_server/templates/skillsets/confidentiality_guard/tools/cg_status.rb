# frozen_string_literal: true

require_relative '../lib/confidentiality_guard/regime'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      module Tools
        # Read-only regime-state tool (CG-1: the regime's own state is
        # readable at any time). Instantiation at tool-registration time is
        # also the activation seam: the regime activates, fail-closed, at
        # instance start — before any session work runs — never per-call.
        class CgStatus < KairosMcp::Tools::BaseTool
          def initialize(safety = nil, registry: nil)
            super
            # Belt-and-suspenders: activation is primarily driven by the
            # skillset load-time activation_hook (independent of any tool).
            # This idempotent call keeps activation working if this tool is
            # constructed before that hook ran. Gates are class-global, so
            # the concrete registry class is resolved inside ensure_activated!.
            Regime.ensure_activated!
          end

          def name
            'cg_status'
          end

          def description
            'Report the confidentiality-guard regime state: enabled/active, pinned policy version, engine version, and the enrolled slice-1 surfaces. Read-only (CG-1).'
          end

          def category
            :guard
          end

          def usecase_tags
            %w[guard confidentiality status audit regime]
          end

          def input_schema
            { type: 'object', properties: {}, required: [] }
          end

          def call(_arguments)
            text_content(JSON.pretty_generate(Regime.status))
          end
        end
      end
    end
  end
end
