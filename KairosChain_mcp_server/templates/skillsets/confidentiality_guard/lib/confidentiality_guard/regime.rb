# frozen_string_literal: true

require 'yaml'
require 'json'
require 'time'
require_relative 'policy'
require_relative 'canon'
require_relative 'surfaces'
require_relative 'verdict'
require_relative 'recorder'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Regime lifecycle and tool-surface interception (design v0.3 CG-1/CG-2).
      #
      # Activation is an environment-level act read at instance start
      # (KAIROS_CONFIDENTIALITY_GUARD env var, then config guard.enabled),
      # never negotiated per-call by the deciding model. The policy is
      # pinned at activation; the regime judges every tool call through a
      # registry gate BEFORE the tool's effect (CG-2: verdict precedes
      # effect — GateDeniedError aborts the call before tool.call runs).
      #
      # Fail-closed activation: any activation failure is re-raised as
      # ToolRegistry::FailClosedError, which the skillset loader never
      # swallows — an enabled regime cannot be silently skipped.
      #
      # Cessation is recorded on graceful shutdown (at_exit) or explicit
      # deactivation. Abnormal termination leaves an open interval, read
      # conservatively as continued-active; per-decision records carry the
      # pinned basis independently (design v0.3 CG-1 R3 disposition).
      module Regime
        module_function

        GATE_NAME = :confidentiality_guard
        ENV_SWITCH = 'KAIROS_CONFIDENTIALITY_GUARD'
        ENV_ON  = %w[1 true on].freeze
        ENV_OFF = %w[0 false off].freeze

        @lock = Mutex.new
        @active = false
        @policy = nil
        @activated_at = nil
        @at_exit_registered = false
        @skillset_root = File.expand_path('../..', __dir__)

        def skillset_root=(path)
          @skillset_root = path
        end

        def skillset_root
          @skillset_root
        end

        def config
          path = File.join(@skillset_root, 'config', 'confidentiality_guard.yml')
          return {} unless File.file?(path)
          begin
            YAML.safe_load(File.read(path)) || {}
          rescue Psych::Exception => e
            # Fail-closed: an unreadable regime config must not silently
            # resolve to "off" (Policy::ActivationError propagates through
            # enabled? and becomes FailClosedError at the loader seam).
            raise Policy::ActivationError, "guard config unparseable: #{e.message}"
          end
        end

        # CG-1 activation precedence: environment variable wins, then config.
        def enabled?
          value = ENV[ENV_SWITCH].to_s.strip.downcase
          return true if ENV_ON.include?(value)
          return false if ENV_OFF.include?(value)
          config.dig('guard', 'enabled') == true
        end

        def active?
          @active
        end

        def policy
          @policy
        end

        # Primary activation seam: called by the skillset loader at
        # load time (skillset.json activation_hook), independent of whether
        # any tool is instantiated. Fail-closed on any error.
        def activate_on_load!(registry_class: nil)
          ensure_activated!(registry_class: registry_class)
        end

        # Idempotent activation entry point. Fail-closed: an enabled regime
        # that cannot activate raises FailClosedError, which the loader
        # re-raises, so the instance never comes up enabled-but-unguarded.
        def ensure_activated!(registry_class: nil)
          @lock.synchronize do
            begin
              return unless enabled?
              return if @active
              activate_locked(registry_class)
            rescue StandardError => e
              raise fail_closed_error(e)
            end
          end
        end

        def deactivate!(reason: 'deactivation')
          @lock.synchronize do
            next unless @active
            Recorder.record_regime_event("cessation/#{reason}", @policy)
            @registry_class&.unregister_gate(GATE_NAME)
            @active = false
          end
          nil
        end

        # The gate body: classify, resolve paths, judge, record, enforce
        # (CG-2/CG-3/CG-4). Reads pinned state into locals; lifecycle
        # transitions are mutex-guarded, so a gate invocation sees a
        # consistent policy. `safety` carries the workspace root the read
        # tools resolve relative paths against — the guard must resolve the
        # same way or a relative path would be judged against a different
        # file (impl review R2).
        def gate(tool_name, arguments, safety = nil)
          policy = @policy
          return unless @active && policy
          raw = arguments.is_a?(Hash) ? arguments : {}
          args = Canon.stringify(raw)
          descriptor = Surfaces.classify(tool_name, args)
          return if descriptor.nil?

          content = Verdict.present_content(raw)
          root = workspace_root(args, safety)

          case descriptor[:class]
          when :file_write
            resolved = resolve_target(descriptor[:raw_path], root)
            observe_policy_edit(resolved, descriptor, content)
            return
          when :storage_read
            descriptor = descriptor.merge(path: resolve_target(descriptor[:raw_path], root))
          when :copy
            # The destination write is watched for policy edits; the source
            # read is judged as a restricted read (a restricted file must
            # not be copied out).
            observe_policy_edit(resolve_target(descriptor[:raw_dest], root),
                                descriptor.merge(path: descriptor[:raw_dest]), content)
            descriptor = { class: :storage_read, tool: tool_name,
                           path: resolve_target(descriptor[:raw_source], root) }
          end

          result = Verdict.judge(policy, descriptor, content)
          if result[:verdict] == 'deny'
            commitment = Recorder.commitment(content)
            Recorder.record_decision(result, commitment[:digest])
            raise KairosMcp::ToolRegistry::GateDeniedError.new(
              tool_name, :confidentiality_guard, denial_report(result, commitment)
            )
          elsif result[:recordable]
            commitment = Recorder.commitment(content)
            Recorder.record_decision(result, commitment[:digest])
          end
          nil
        end

        # Effective workspace root, matching the external-tools read
        # resolution precedence (workspace_root arg > safety.workspace_root
        # > safety.safe_root > env > cwd), so the guard resolves a relative
        # read path to the same file the tool will.
        def workspace_root(args, safety)
          root = args['workspace_root']
          root = nil unless root.is_a?(String) && !root.empty?
          root ||= safety.workspace_root if safety.respond_to?(:workspace_root) && safety.workspace_root.is_a?(String)
          root ||= safety.safe_root if safety.respond_to?(:safe_root) && safety.safe_root.is_a?(String)
          root ||= ENV['KAIROS_WORKSPACE']
          root = Dir.pwd unless root.is_a?(String) && !root.empty?
          File.realpath(root)
        rescue StandardError
          File.expand_path(root.is_a?(String) ? root : Dir.pwd)
        end

        # Resolve a raw path to an absolute, symlink-resolved location under
        # the workspace root. Returns '' (→ unextractable, denied) on a
        # non-String, empty, or malformed (e.g. null-byte) path so the read
        # never degrades open.
        def resolve_target(raw_path, root)
          return '' unless raw_path.is_a?(String) && !raw_path.empty?
          absolute = raw_path.start_with?(File::SEPARATOR) ? raw_path : File.join(root, raw_path)
          Policy.resolve(absolute)
        rescue StandardError
          ''
        end

        # CG-1 readable-anytime regime state. Never raises — an unreadable
        # config surfaces as enabled: 'error' rather than crashing the one
        # tool an operator uses to inspect the fail-closed posture.
        def status
          enabled_state = begin
            enabled?
          rescue StandardError
            'error'
          end
          {
            enabled: enabled_state,
            active: @active,
            activated_at: @activated_at,
            policy_sha256: @policy&.sha256,
            policy_empty: @policy ? @policy.empty? : nil,
            engine: Policy::ENGINE_VERSION,
            surfaces: {
              inward_write: Surfaces::INWARD_WRITE_TOOLS.keys,
              storage_read: Surfaces::STORAGE_READ_TOOLS.keys,
              unmapped_read_denied: Surfaces::UNMAPPED_READ_TOOLS,
              outward_denied_wholesale: Surfaces::OUTWARD_TOOLS
            }
          }
        end

        # Test seam: reset module state without recording.
        def reset!
          @lock.synchronize do
            @registry_class&.unregister_gate(GATE_NAME) if @active
            @active = false
            @policy = nil
            @activated_at = nil
            @registry_class = nil
            @profile_path = nil
          end
          nil
        end

        # CG-6: the denial report names the rule and the crossing without
        # republishing the content; it carries the commitment salt so an
        # operator holding the content can re-derive the verdict (CG-4).
        def denial_report(result, commitment)
          JSON.generate(
            guard: 'confidentiality_guard',
            verdict: 'deny',
            rule: result[:rule],
            crossing: Recorder.descriptor_fields(result[:crossing]),
            policy_sha256: result[:basis][:policy_sha256],
            engine: result[:basis][:engine],
            commitment: commitment[:digest],
            salt: commitment[:salt]
          )
        end

        # CG-1: edits to the policy data (profile AND regime config, both
        # of which drive the verdict) are inert until adoption; CG-4: they
        # are recorded. The caller passes the already-resolved target so
        # equivalent paths (symlinked roots, relative paths) are recognized.
        def observe_policy_edit(resolved, descriptor, content)
          return if resolved.nil? || resolved.empty?
          watched = [@profile_path, @config_path].compact.map { |p| Policy.resolve(p) }
          return unless watched.include?(resolved)
          commitment = Recorder.commitment(content)
          Recorder.record_policy_edit(descriptor, commitment[:digest], @policy)
          nil
        end

        # -- internals (still module_function-public for tests) -----------

        def activate_locked(registry_class)
          profile_name = config.dig('guard', 'profile') || 'profile.yml'
          profile_path = File.join(@skillset_root, 'config', profile_name)
          policy = Policy.load(profile_path)
          registry_klass = registry_class || resolve_registry_class

          # Set pinned state and go active BEFORE registering the gate, so
          # there is never a window in which the gate is registered but
          # reads @active == false (which would fail OPEN). All under @lock
          # and before the server serves requests.
          @policy = policy
          @profile_path = profile_path
          @config_path = File.join(@skillset_root, 'config', 'confidentiality_guard.yml')
          @registry_class = registry_klass
          @activated_at = Time.now.utc.iso8601
          @active = true

          begin
            Recorder.record_regime_event('activation', policy)
            registry_klass.register_gate(GATE_NAME) do |tool_name, arguments, safety|
              Regime.gate(tool_name, arguments, safety)
            end
          rescue StandardError
            # Roll back to a clean inactive state — no phantom activation,
            # no half-registered gate.
            registry_klass.unregister_gate(GATE_NAME)
            @active = false
            @policy = nil
            @registry_class = nil
            raise
          end

          unless @at_exit_registered
            @at_exit_registered = true
            at_exit { Regime.deactivate!(reason: 'shutdown') if Regime.active? }
          end
          nil
        end

        def fail_closed_error(error)
          klass = resolve_registry_class::FailClosedError
          return error if error.is_a?(klass)
          klass.new("confidentiality_guard enabled but activation failed (fail-closed): #{error.class}: #{error.message}")
        end

        def resolve_registry_class
          # In-server the registry is already loaded; the require path is a
          # template-layout fallback for standalone runs (tests).
          unless defined?(KairosMcp::ToolRegistry)
            require_relative '../../../../lib/kairos_mcp/tool_registry'
          end
          KairosMcp::ToolRegistry
        end
      end
    end
  end
end
