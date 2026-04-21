# frozen_string_literal: true

module KairosMcp
  class Daemon
    # ExecutionContext — Fiber-local-ready abstraction for daemon execution state.
    #
    # Design (P3.2 v0.2 §5.2):
    #   Single indirection point for Thread/Fiber-local state. If the daemon
    #   moves to Fiber-based async, only this module needs to change.
    #   Currently delegates to Thread.current (which is Fiber-local in Ruby).
    module ExecutionContext
      def self.current_elevation_token
        Thread.current[:kairos_elevation_token]
      end

      def self.current_elevation_token=(token)
        Thread.current[:kairos_elevation_token] = token
      end
    end
  end
end
