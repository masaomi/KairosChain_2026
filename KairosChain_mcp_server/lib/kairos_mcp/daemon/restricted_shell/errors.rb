# frozen_string_literal: true

module KairosMcp
  class Daemon
    class RestrictedShell
      class ShellError        < StandardError; end
      class PolicyViolation   < ShellError; end
      class SandboxError      < ShellError; end
      class ResolverError     < ShellError; end

      class TimeoutError < ShellError
        attr_reader :elapsed_ms, :pid
        def initialize(msg, elapsed_ms:, pid:)
          super(msg)
          @elapsed_ms = elapsed_ms
          @pid = pid
        end
      end

      class OutputTruncated < ShellError
        attr_reader :stream, :limit
        def initialize(stream, limit)
          super("stream=#{stream} exceeded #{limit} bytes")
          @stream = stream
          @limit = limit
        end
      end
    end
  end
end
