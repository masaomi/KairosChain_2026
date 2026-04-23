# frozen_string_literal: true

# KairosChain 24/7 daemon_runtime SkillSet — entry point.
# See log/kairoschain_24x7_autonomous_v0.4_design_20260422.md

module KairosMcp
  module SkillSets
    module DaemonRuntime
    end
  end
end

require_relative 'daemon_runtime/signal_coordinator'
require_relative 'daemon_runtime/main_loop_supervisor'
require_relative 'daemon_runtime/main_loop'
require_relative 'daemon_runtime/attach_auth'
