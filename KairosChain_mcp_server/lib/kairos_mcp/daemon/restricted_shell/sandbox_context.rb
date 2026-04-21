# frozen_string_literal: true

require 'fileutils'

module KairosMcp
  class Daemon
    class RestrictedShell
      # SandboxContext — holds sandbox-wrapped command + cleanup handle.
      class SandboxContext
        attr_reader :cmd, :driver

        def initialize(cmd:, driver: :none, tmpdir: nil)
          @cmd = cmd
          @driver = driver
          @tmpdir = tmpdir
        end

        def cleanup!
          FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
        rescue StandardError
          # best-effort
        end
      end
    end
  end
end
