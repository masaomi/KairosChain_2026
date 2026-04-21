# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'

require_relative 'restricted_shell/errors'
require_relative 'restricted_shell/binary_resolver'
require_relative 'restricted_shell/argv_validators'
require_relative 'restricted_shell/sandbox_context'
require_relative 'restricted_shell/sandbox_factory'
require_relative 'restricted_shell/runner'

module KairosMcp
  class Daemon
    # RestrictedShell — sandboxed external binary execution.
    #
    # Design (P3.4 v0.2):
    #   4-layer defense: allowlist → argv validator → OS sandbox → timeout+kill
    #   Network deny by default. Single-threaded, synchronous.
    class RestrictedShell
      MAX_STDIN_BYTES = 8_192  # R2 residual: conservative limit to avoid pipe deadlock
      DEFAULT_ENV_ALLOWLIST = %w[PATH LANG LC_ALL].freeze
      DEFAULT_MAX_OUTPUT = 4 * 1024 * 1024

      Result = Struct.new(
        :status, :signal, :stdout, :stderr, :duration_ms,
        :stdout_truncated, :stderr_truncated, :sandbox_driver, :cmd_hash,
        keyword_init: true
      ) do
        def success? = !signal && status == 0
      end

      # @param cmd [Array<String>] [short_name, *argv]
      # @param cwd [String] absolute path
      # @param timeout [Integer] wall seconds
      # @param allowed_paths [Array<String>] absolute paths for read+write
      # @param env_allowlist [Array<String>] env vars passed through
      # @param network [:deny, :allow] default :deny
      # @param stdin_data [String, nil] piped to stdin
      # @param max_output_bytes [Integer] per-stream cap
      # @return [Result]
      def self.run(cmd:, cwd:, timeout:, allowed_paths:,
                   env_allowlist: DEFAULT_ENV_ALLOWLIST,
                   network: :deny, stdin_data: nil,
                   max_output_bytes: DEFAULT_MAX_OUTPUT)
        cmd = Array(cmd).map(&:to_s)
        raise PolicyViolation, 'cmd must not be empty' if cmd.empty?
        raise PolicyViolation, 'cmd must be an Array' unless cmd.is_a?(Array)
        raise PolicyViolation, "stdin_data exceeds #{MAX_STDIN_BYTES} bytes" \
          if stdin_data && stdin_data.bytesize > MAX_STDIN_BYTES
        raise PolicyViolation, 'cwd must be absolute' unless cwd.start_with?('/')
        raise PolicyViolation, "network must be :deny or :allow" unless %i[deny allow].include?(network)

        short_name = cmd.first
        resolved = BinaryResolver.resolve!(short_name)
        resolved[:validator].validate!(cmd[1..])

        validate_paths!(cwd, allowed_paths)

        env = build_env(env_allowlist, short_name)
        git_home_tmpdir = env.delete(:_git_home_tmpdir)  # internal cleanup handle

        sandbox_ctx = SandboxFactory.wrap(
          bin_path: resolved[:path], argv: cmd[1..],
          cwd: cwd, allowed_paths: allowed_paths, network: network
        )

        begin
          Runner.run_with_timeout(
            wrapped_cmd: sandbox_ctx.cmd,
            env: env, cwd: cwd, timeout: timeout,
            stdin_data: stdin_data,
            max_output_bytes: max_output_bytes,
            cmd_for_hash: cmd
          )
        ensure
          sandbox_ctx.cleanup!
          # R2 residual: cleanup git temp HOME
          FileUtils.rm_rf(git_home_tmpdir) if git_home_tmpdir
        end
      end

      # @api private
      def self.validate_paths!(cwd, allowed_paths)
        allowed_paths.each do |p|
          raise PolicyViolation, "allowed_path must be absolute: #{p}" unless p.start_with?('/')
        end
        # cwd must be under one of allowed_paths
        cwd_real = File.expand_path(cwd)
        unless allowed_paths.any? { |p| cwd_real.start_with?(File.expand_path(p)) }
          raise PolicyViolation, "cwd #{cwd} is not under any allowed_path"
        end
      end

      # @api private
      def self.build_env(allowlist, short_name)
        env = ENV.to_h.slice(*allowlist)
        if short_name == 'git'
          git_home = Dir.mktmpdir('kairos_git_home')
          env.merge!(
            'GIT_CONFIG_NOSYSTEM' => '1',
            'GIT_TERMINAL_PROMPT' => '0',
            'PAGER'              => 'cat',
            'GIT_PAGER'          => 'cat',
            'GIT_DIFF_EXTERNAL'  => '',  # R2 residual: neutralize repo-local diff driver
            'HOME'               => git_home
          )
          env[:_git_home_tmpdir] = git_home  # cleanup handle (removed before spawn)
        end
        env
      end
    end
  end
end
