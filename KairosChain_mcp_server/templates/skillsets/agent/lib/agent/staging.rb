# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'confinement'

module KairosMcp
  module SkillSets
    module Agent
      # Staging — NB-2 driver-side staging of the native body's executable
      # closure (native body design v0.6 FROZEN, Slice 2).
      #
      # The body's code and the model-adapter code it runs live in the
      # governance stores; the executor position cannot read the stores
      # (AGT-2). They cross the boundary the way every other value does: by
      # copy. This module stages the WHOLE executable closure — body, the
      # eligible HTTP adapters, and the vendored gems those adapters load —
      # into a read-only staged-code region outside the writable work area,
      # fixes its identity by ONE content address over the entire set, and
      # re-verifies that identity immediately before launch.
      #
      # Structural exclusion (NB-4): the subprocess-CLI adapters
      # (claude_code / codex / cursor / codex_mcp), bedrock (aws-sdk,
      # ~/.aws credential chain), and the dispatching call_router (which
      # carries the AuthError→claude_code fallback) are simply NOT in the
      # staged set. Inside the closure a `require` of any of them resolves
      # nowhere and raises — refusal by construction, not a runtime check.
      #
      # Self-containment (NB-2): the body is launched with RubyGems disabled
      # and a load path restricted to the staged region, so a load that
      # resolves outside the pinned region (a system gem, an ambient library)
      # raises LoadError and the act halts (AGT-6). The Ruby VM and its
      # standard library are the execution substrate the parent's partial-
      # autopoiesis frame already names as external — they are not part of
      # the pin, the way the interpreter binary is not part of the pin.
      module Staging
        class StagingError < Confinement::ConfinementError; end

        SIDECAR = 'closure.sha256'

        # NB-4 eligible transports: direct-HTTP only. openrouter/local front
        # through the OpenAI adapter (verified: call_router.rb:144).
        ELIGIBLE_PROVIDERS = {
          'anthropic'  => { 'require' => 'llm_client/anthropic_adapter', 'class' => 'AnthropicAdapter' },
          'openai'     => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' },
          'openrouter' => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' },
          'local'      => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' }
        }.freeze

        # The adapter files that enter the closure. call_router.rb is
        # deliberately absent (dispatcher + AuthError→claude_code fallback);
        # so are all subprocess-CLI adapters and bedrock.
        ADAPTER_FILES = %w[
          adapter.rb
          anthropic_adapter.rb
          openai_adapter.rb
          schema_converter.rb
        ].freeze

        # Body files staged from the agent SkillSet itself.
        BODY_FILES = %w[
          main.rb
          tool_layer.rb
          model_client.rb
          spend_meter.rb
        ].freeze

        # Gems vendored into the closure (transitive HTTP-transport load
        # closure of the eligible adapters). json/logger/net-http are default
        # gems whose code lives in the Ruby stdlib path and loads under
        # --disable-gems; they are substrate, not closure.
        VENDORED_GEMS = %w[faraday faraday-net_http].freeze

        # Intake keys that would carry a store handle or an instance channel
        # into the executor (NB-3: the body is not a client of the instance).
        # Refused driver-side before launch, recursively.
        FORBIDDEN_INTAKE_KEYS = %w[
          stores_dir store_handle instance_channel invocation_context
          mcp_endpoint mcp_socket tool_registry chain_handle
        ].freeze

        module_function

        # Stage the full executable closure into `staged_root` and pin it.
        # Returns { 'staged_dir' => ..., 'closure_sha256' => ... }.
        # Fail-closed: any unresolvable source, overlap with the work area /
        # stores / live tree, or an uncomputable digest raises (AGT-6).
        def stage!(staged_root, scratch_dir:, project_root:,
                   body_src: default_body_src, adapter_src: default_adapter_src)
          staged = Confinement.realpath_strict(staged_root, 'staged_root')
          assert_staged_geometry!(staged, scratch_dir, project_root)

          copy_set(body_src, BODY_FILES, File.join(staged, 'lib', 'native_body'), 'body file')
          copy_set(adapter_src, ADAPTER_FILES, File.join(staged, 'lib', 'llm_client'), 'adapter file')
          vendor_gems!(File.join(staged, 'vendor'))

          sha = compute_digest(staged)
          File.write(File.join(staged, SIDECAR), sha)
          # Defense in depth: the substrate write-deny (staged region is
          # outside the scratch allowlist) is the load-bearing read-only
          # enforcement; the chmod just makes driver-side mistakes loud.
          sidecar_path = File.join(staged, SIDECAR)
          Dir.glob(File.join(staged, '**', '*')).each do |p|
            File.chmod(0o444, p) if File.file?(p) && p != sidecar_path
          end
          { 'staged_dir' => staged, 'closure_sha256' => sha }
        end

        # Content address over the entire staged set: sorted relative paths,
        # each bound to its content hash. The sidecar records the digest and
        # is excluded from it.
        def compute_digest(staged_dir)
          staged = Confinement.realpath_strict(staged_dir, 'staged_dir')
          # R1 F2: a symlink must be REFUSED, never silently dropped. Dropping
          # it left the content address blind to a planted symlink — verify!
          # would report the closure unchanged while a load through that
          # symlink (first on the restricted -I path) executed unpinned code,
          # defeating NB-2's closure-escape halt. Raise on ANY symlink in the
          # staged tree (files and directories alike) so the pin covers the
          # true load closure, not a symlink-filtered view of it.
          all = Dir.glob(File.join(staged, '**', '*'), File::FNM_DOTMATCH)
          all.each do |p|
            next unless File.symlink?(p)

            raise StagingError, "symlink in staged closure (refused): #{p.delete_prefix("#{staged}/")}"
          end

          entries = all.select { |p| File.file?(p) }
                       .map { |p| p.delete_prefix("#{staged}/") }
                       .reject { |rel| rel == SIDECAR }
                       .sort
          raise StagingError, 'staged closure is empty (nothing to pin)' if entries.empty?

          acc = Digest::SHA256.new
          entries.each do |rel|
            acc << rel << "\0" << Digest::SHA256.file(File.join(staged, rel)).hexdigest << "\n"
          end
          acc.hexdigest
        end

        # Re-verify the pinned identity immediately before launch (NB-2:
        # staging and verifying belong to the same pre-launch step). A
        # missing sidecar, a mismatch, or an uncomputable digest halts.
        def verify!(staged_dir, expected_sha = nil)
          staged = Confinement.realpath_strict(staged_dir, 'staged_dir')
          sidecar = File.join(staged, SIDECAR)
          recorded = expected_sha ||
                     (File.exist?(sidecar) ? File.read(sidecar).strip : nil)
          raise StagingError, 'no recorded closure digest (NB-2: unpinned closure never launches)' if recorded.nil? || recorded.empty?

          actual = compute_digest(staged)
          if actual != recorded
            raise StagingError,
                  "closure tamper detected: pinned #{recorded[0, 12]}… != actual #{actual[0, 12]}… (NB-2)"
          end
          actual
        end

        # NB-2 geometry: the staged region must be disjoint from the stores,
        # the live tree, the agent SkillSet's own code (same trust set as the
        # scratch area), AND from the writable work area itself.
        def assert_staged_geometry!(staged_dir, scratch_dir, project_root)
          staged = Confinement.assert_disjoint!(staged_dir, project_root)
          scratch = Confinement.realpath_strict(scratch_dir, 'scratch_dir')
          if Confinement.within?(staged, scratch) || Confinement.within?(scratch, staged)
            raise StagingError,
                  "staged-code region overlaps the work area: #{staged} vs #{scratch} (NB-2 disjointness)"
          end
          staged
        end

        # NB-4 structural gate, driver-side half: a curated configuration
        # naming an excluded transport is refused before any act runs. The
        # in-closure half is structural (the adapter is not staged, so it
        # cannot load).
        def assert_eligible_provider!(provider)
          p = provider.to_s
          return ELIGIBLE_PROVIDERS[p] if ELIGIBLE_PROVIDERS.key?(p)

          raise StagingError,
                "provider #{p.inspect} is not an eligible native-body transport " \
                "(NB-4 direct-HTTP only; eligible: #{ELIGIBLE_PROVIDERS.keys.join(', ')})"
        end

        # NB-3 driver-side intake refusal: a payload carrying a store handle
        # or an instance-channel grant is refused before launch, never left
        # to the body's self-report.
        def validate_intake!(payload)
          offending = forbidden_keys_in(payload)
          unless offending.empty?
            raise StagingError,
                  "intake payload carries instance/store grants (refused pre-launch, NB-3): #{offending.uniq.join(', ')}"
          end
          payload
        end

        def forbidden_keys_in(node)
          case node
          when Hash
            node.flat_map do |k, v|
              hit = FORBIDDEN_INTAKE_KEYS.include?(k.to_s) ? [k.to_s] : []
              hit + forbidden_keys_in(v)
            end
          when Array
            node.flat_map { |v| forbidden_keys_in(v) }
          else
            []
          end
        end

        # Load-path arguments restricting the body to the pinned region.
        # Combined with --disable-gems this is the closure-escape mechanism:
        # a require resolving outside these roots raises LoadError → halt.
        def load_path_args(staged_dir)
          staged = Confinement.realpath_strict(staged_dir, 'staged_dir')
          roots = [File.join(staged, 'lib')]
          VENDORED_GEMS.each { |g| roots << File.join(staged, 'vendor', g, 'lib') }
          roots.flat_map { |r| ['-I', r] }
        end

        def body_entrypoint(staged_dir)
          File.join(staged_dir, 'lib', 'native_body', 'main.rb')
        end

        # --- staging sources (driver side, gems enabled) ---

        def default_body_src
          File.join(__dir__, 'native_body')
        end

        # Instance layout and gem-template layout share the same relative
        # geometry: <skillsets>/agent/lib/agent/ → <skillsets>/llm_client/.
        def default_adapter_src
          File.expand_path('../../../llm_client/lib/llm_client', __dir__)
        end

        def copy_set(src_dir, files, dest_dir, what)
          FileUtils.mkdir_p(dest_dir)
          files.each do |f|
            src = File.join(src_dir, f)
            unless File.file?(src)
              raise StagingError, "#{what} missing at staging time: #{src} (fail-closed)"
            end

            FileUtils.cp(File.realpath(src), File.join(dest_dir, f))
          end
        end

        def vendor_gems!(vendor_root)
          VENDORED_GEMS.each do |name|
            spec = begin
              Gem::Specification.find_by_name(name)
            rescue Gem::MissingSpecError => e
              raise StagingError, "vendored gem #{name} not resolvable (#{e.class}) — closure incomplete"
            end
            src_lib = File.join(spec.full_gem_path, 'lib')
            raise StagingError, "gem #{name} has no lib dir: #{src_lib}" unless File.directory?(src_lib)

            dest = File.join(vendor_root, name)
            FileUtils.mkdir_p(dest)
            FileUtils.cp_r(src_lib, dest)
          end
        end
      end
    end
  end
end
