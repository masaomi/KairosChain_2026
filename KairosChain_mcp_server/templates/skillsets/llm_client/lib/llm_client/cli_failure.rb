# frozen_string_literal: true

require 'json'
require 'timeout'
require_relative 'safe_subprocess'

module KairosMcp
  module SkillSets
    module LlmClient
      # Why a CLI call produced no reply, established by the adapter that ran it
      # (multi_llm_review design v0.3.3, INV-H1).
      #
      # A cause is named only from what the CLI said about itself, or from what
      # the adapter observed while running it: the binary missing from the PATH
      # the spawn searched, a refusal that is the whole of the CLI's stderr, the
      # CLI's own answer about its login state when asked after the failure, or
      # the call's own timer. Text that can come from the prompt, from files the
      # model read or from the model's output never names a cause — codex writes
      # the prompt and the files it read to stderr, so a marker found there may be
      # the reviewed artifact quoting itself. When no cause is established the
      # code stays nil and readers record `transport`.
      #
      # The code travels beside the message, never inside it: the message and its
      # excerpt are built exactly as before, so ErrorTaxonomy's `type` (matched
      # on the message) does not move for any caller.
      module CliFailure
        CLI_MISSING = 'cli_missing'
        CLI_UNAUTHENTICATED = 'cli_unauthenticated'
        WORKSPACE_REFUSED = 'workspace_refused'
        CLI_TIMEOUT = 'cli_timeout'
        CODES = [CLI_MISSING, CLI_UNAUTHENTICATED, WORKSPACE_REFUSED, CLI_TIMEOUT].freeze

        # The whole of codex's stderr when it refuses a working directory it
        # neither finds in a git repository nor trusts. Measured 2026-10-21
        # (codex-cli 0.163.0): the refusal comes before any session starts, so
        # nothing else — no banner, no echoed prompt — is written beside it.
        CODEX_WORKSPACE_REFUSAL = 'Not inside a trusted directory and --skip-git-repo-check was not specified.'

        # Each CLI's own command for its login state. None calls a model;
        # measured at 0.0–1.1 s (2026-10-21).
        STATUS_COMMANDS = {
          codex: %w[codex login status],
          cursor: %w[agent status],
          claude: %w[claude auth status]
        }.freeze

        # The status command runs under its own timer, rescued here, so its
        # timeout can never reach an adapter's `rescue Timeout::Error` and turn a
        # seat that failed in seconds into `cli_timeout`.
        STATUS_TIMEOUT_SECONDS = 10

        module_function

        # True when `binary` is an executable file in one of the PATH entries
        # the spawn searched. SafeSubprocess passes the server's PATH through
        # unchanged, so that PATH is the one to search.
        def binary_on_path?(binary, path = ENV['PATH'])
          path.to_s.split(File::PATH_SEPARATOR).any? do |dir|
            next false if dir.empty?

            full = File.join(dir, binary.to_s)
            File.file?(full) && File.executable?(full)
          end
        end

        # `cli_missing` when the spawn failed because the binary is absent from
        # the PATH searched; nil when it is there (a missing working directory
        # also raises ENOENT, and that is not the CLI missing).
        def missing_code(binary)
          binary_on_path?(binary) ? nil : CLI_MISSING
        end

        # `workspace_refused` only when codex's stderr, bar its final newline, is
        # exactly the refusal line.
        def codex_refusal_code(stderr)
          stderr.to_s.sub(/\r?\n\z/, '') == CODEX_WORKSPACE_REFUSAL ? WORKSPACE_REFUSED : nil
        end

        # The dispatcher marks a seat's thread before killing its process
        # (multi_llm_review dispatcher.rb). A call ended that way failed because
        # its dispatch was cancelled, so the CLI is not asked anything.
        def cancelled?
          Thread.current[:cancelled] == true
        end

        # After a non-zero exit, ask the CLI whether it is logged in, in the
        # same environment the seat ran in. `cli_unauthenticated` only on the
        # CLI's own words; an exit code alone, a failed or timed-out status
        # command, or any other answer gives nil.
        def login_code(cli, env: {}, dispatch_id: nil)
          return nil if cancelled?

          argv = STATUS_COMMANDS.fetch(cli)
          stdout, stderr, = SafeSubprocess.safe_capture(
            argv, stdin_data: nil, timeout_seconds: STATUS_TIMEOUT_SECONDS,
                  env: env, dispatch_id: dispatch_id
          )
          logged_out?(cli, stdout.to_s, stderr.to_s) ? CLI_UNAUTHENTICATED : nil
        rescue Timeout::Error, SystemCallError, IOError, KeyError
          nil
        end

        # Each CLI's own statement that it holds no credential it would use.
        #   codex  : "Not logged in" on its own line (stderr; exit 1)
        #   cursor : "Not logged in" on its own line (stdout; exit 0 either way)
        #   claude : JSON on stdout with "loggedIn": false
        def logged_out?(cli, stdout, stderr)
          case cli
          when :codex, :cursor
            "#{stdout}\n#{stderr}".each_line.any? { |l| l.strip == 'Not logged in' }
          when :claude
            data = JSON.parse(stdout)
            data.is_a?(Hash) && data['loggedIn'] == false
          else
            false
          end
        rescue JSON::ParserError
          false
        end
      end
    end
  end
end
