# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Admission — AGT-5 store-write admission for the in-process act route,
      # plus AGT-1 route symmetry for in-process live-tree writers
      # (guard track design v0.3.1 FROZEN).
      #
      # Store-touching writes performed within an agent cycle are admitted
      # against the mandate's declared layer surface, pinned before the loop
      # ran. Enforcement is refusal, not detection: denied tools are added to
      # the ACT invocation-context blacklist, so the call is refused at
      # dispatch (PolicyDeniedError) and the write never lands.
      #
      # - The declaration can name only governance-store surfaces (l0 / l1).
      #   The record store is NEVER declarable: record-store tools are in the
      #   deny set for every possible declaration — refused by construction,
      #   not by favorable interpretation.
      # - The single path to the record store is the driver's own constitutive
      #   recording (record_agent_cycle and the driver's checkpoint records),
      #   which runs in driver context outside the ACT blacklist — an inherent
      #   boundary act, structurally distinct from any act-route call. Its API
      #   accepts only cycle-record shapes, so it cannot carry an arbitrary
      #   write (exemption boundary).
      # - Live-tree-writing governed tools are denied in-process under the
      #   guard (AGT-1: one geometry — live-tree effects go through the
      #   delegated route's scratch area with verdict-gated return; a governed
      #   tool writing the live tree in-process would land pre-verdict).
      # - No bypass: every in-process ACT tool call flows through invoke_tool
      #   with the ACT context, which is where this deny set is enforced.
      module Admission
        class SurfaceError < StandardError; end

        # Governance-store surfaces the mandate may declare, and the governed
        # tools that write each surface. L2 is deliberately absent: it is the
        # free-modification session layer, not a layer-defining store.
        LAYER_WRITE_TOOLS = {
          'l0' => %w[skills_evolve skills_rollback instructions_update system_upgrade],
          'l1' => %w[knowledge_update skills_promote]
        }.freeze

        # Record-store (chain / attestation) writers: never declarable, always
        # denied on the act route regardless of the declared surface.
        RECORD_STORE_TOOLS = %w[
          chain_record chain_import chain_migrate_execute state_commit
          formalization_record attestation_issue attestation_revoke
          l2_attestation_commit l2_attestation_revoke l2_attestation_decline
        ].freeze

        # Governed tools whose effects land in the live project tree. Under
        # the guard these are refused in-process (AGT-1 route symmetry): the
        # act must be expressed as file operations and travel the delegated
        # route, where the scratch area quarantines it until the verdict.
        LIVE_TREE_WRITE_TOOLS = %w[write_section sc_scaffold plugin_project].freeze

        # What constrains the agent or its operator, and so may not be touched
        # by an act (read or written) through any path argument of any tool:
        # the KairosChain stores (the agent's own config and session files,
        # L1, the instruction mode, the chain), the harness configuration
        # (.claude: permission rules and hooks that run as the operator;
        # .codex; .mcp.json) and the instruction files every agent body reads
        # (CLAUDE.md, AGENTS.md). Checked by destination, not by tool name, so
        # a tool that was not anticipated is covered by its arguments.
        #
        # Also protected: what git and the operator's development tools execute
        # or load as configuration (design v0.3 §6.5). A hook written into
        # .git/hooks, or core.hooksPath set in .git/config, runs as the operator
        # on the next git command, including a plain `git status` — which would
        # hand the act the operator's shell. The same holds for CI workflows
        # (.github), editor tasks (.vscode), other agents' rules (.cursor,
        # .gemini, .cursorrules) and direnv (.envrc).
        #
        # And private keys: a keys/ directory anywhere, the usual private-key
        # file names and extensions. The base table classifies safe_file_read,
        # and a key read in one step could leave through an API llm_call in the
        # next (keys/mmp_keypair.pem sits at this project's root).
        PROTECTED_SEGMENTS = %w[.kairos .claude .codex .git .github .vscode .cursor .gemini keys].freeze
        PROTECTED_BASENAMES = %w[claude.md agents.md .mcp.json .envrc .cursorrules .cursorignore
                                 id_rsa id_dsa id_ecdsa id_ed25519].freeze
        PROTECTED_EXTENSIONS = %w[.pem .key .p12 .pfx].freeze

        # Argument names that carry a filesystem location, matched by word
        # (split on '_' / '-') so 'profile' or 'output_format' is not a path.
        # Tokens come from splitting on '_', '-' and camelCase. A token also
        # matches when it ends in 'dir' or 'path' (workdir, outdir, filepath)
        # — not 'file', or 'profile' would match.
        PATH_TOKENS = %w[path paths file files filename filenames dir dirs dirname directory dest
                         destination source target root workspace src dst cwd folder location].freeze
        PATH_SUFFIXES = %w[dir path].freeze
        ROOT_TOKENS = %w[root workspace cwd].freeze

        # Tools an act may not call, with or without the guard: they rewrite
        # the configuration that governs every later call (llm_configure:
        # provider, endpoint and which key is sent; the mode-hook tools and
        # plugin_project: .claude hooks and permission surfaces) without
        # naming a path, or launch an external agent body (hermes_*).
        # multi_llm_review is here too: its codex seat runs `codex exec` (read-
        # only, but able to read files) in the project root, and its cursor
        # seat may read absolute paths, so a plan-authored artifact could have
        # a seat read the instance's keys. The driver's own review gate is not
        # the act route and is unaffected.
        ACT_CONFIG_WRITERS = %w[llm_configure mode_hooks_add mode_hooks_project plugin_project hermes_*
                                multi_llm_review*].freeze

        # llm_call providers an act may use: claude_code runs sandboxed (the
        # driver forces sandbox_mode); the API providers carry no tools. CLI
        # bodies that carry tools (codex, codex_mcp, cursor) and any provider
        # not named here are refused.
        # (openrouter is not listed: without a configured base_url it falls
        # back to the OpenAI endpoint and would send the OpenRouter key there.)
        ACT_SAFE_LLM_PROVIDERS = %w[claude_code anthropic openai bedrock].freeze

        # Tools that call llm_call internally with the instance's default
        # provider (no override possible from the plan).
        DEFAULT_PROVIDER_LLM_TOOLS = %w[write_section].freeze

        module_function

        # Steps of a plan that would touch a protected location or leave the
        # project, as [{ 'step_id', 'tool_name', 'path' }].
        #   protected_dirs  absolute protected directories (the stores,
        #                   <project>/.claude, <project>/.codex)
        #   roots           every directory a tool may resolve a relative path
        #                   against
        #   allowed_roots   where an act may touch anything at all (the
        #                   project); a path or a root argument resolving
        #                   outside them is refused, so an explicit
        #                   workspace_root cannot turn the check into a
        #                   deny-list over the whole disk
        # Every argument at any depth whose name is path-like is checked.
        # Fail-closed throughout: arguments that are not an object, a '..'
        # segment, an unresolvable path and a dangling symlink are hits.
        # Comparison ignores case (APFS is case-insensitive by default).
        def protected_path_violations(task_json, protected_dirs, roots, allowed_roots = nil)
          protected = Array(protected_dirs).map { |d| safe_canonical(d).downcase }
          allowed = Array(allowed_roots).compact.map { |d| safe_canonical(d) }
          steps = task_json.is_a?(Hash) ? task_json['steps'] : nil
          return [] unless steps.is_a?(Array)

          steps.flat_map do |step|
            next [{ 'step_id' => nil, 'tool_name' => nil, 'path' => '(malformed step)' }] unless step.is_a?(Hash)

            args = step['tool_arguments']
            next [] if args.nil?
            unless args.is_a?(Hash)
              next [{ 'step_id' => step['step_id'], 'tool_name' => step['tool_name'], 'path' => '(arguments not an object)' }]
            end

            pairs = path_pairs(args)
            explicit_roots = pairs.select { |k, _| (key_tokens(k) & ROOT_TOKENS).any? }.map(&:last)
            # Resolve against the explicit roots AND the tools' default roots: a
            # root argument in the plan is text the planner writes, while the
            # tool decides where it actually resolves (some tools ignore the
            # argument). Judging only at the plan's root would let a decoy
            # 'workspace_root' move the check away from the real write. On an
            # instance whose default root is the stores this over-refuses; the
            # refusal tells the operator to set safe_root.
            candidate_roots = (explicit_roots + Array(roots)).compact.map(&:to_s).reject(&:empty?)
            # No root to resolve against means the check cannot be made.
            next [{ 'step_id' => step['step_id'], 'tool_name' => step['tool_name'], 'path' => '(no root)',
                    'rule' => 'unresolvable' }] if candidate_roots.empty? && !pairs.empty?
            pairs.filter_map do |_key, raw|
              # A leading '~' is read as the home directory by File.expand_path
              # but kept as a literal directory name by the tools (File.join), so
              # the check and the write would disagree about where it lands.
              rule = if raw.start_with?('~') then 'tilde'
                     elsif protected_name?(raw) then 'protected'
                     elsif raw.split(%r{[/\\]}).include?('..') then 'dotdot'
                     else candidate_roots.lazy.map { |root| touch_rule(raw, root, protected, allowed) }.find(&:itself)
                     end
              { 'step_id' => step['step_id'], 'tool_name' => step['tool_name'], 'path' => raw, 'rule' => rule } if rule
            end
          end
        end

        def key_tokens(key)
          key.to_s.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase.split(/[_\-]/)
        end

        def path_key?(key)
          key_tokens(key).any? do |t|
            PATH_TOKENS.include?(t) || PATH_SUFFIXES.any? { |suf| t.end_with?(suf) }
          end
        end

        # [key, string] for every path-like key at any depth; an array takes
        # its key from the parent.
        def path_pairs(node, key = nil)
          case node
          when Hash then node.flat_map { |k, v| path_pairs(v, k) }
          when Array then node.flat_map { |v| path_pairs(v, key) }
          when String
            key && path_key?(key) && !node.strip.empty? ? [[key.to_s, node]] : []
          else []
          end
        end

        # llm_call steps whose provider would launch a tool-carrying body:
        # [{ 'step_id', 'tool_name', 'path' => '(provider X)', 'rule' }].
        # default_provider is the instance's configured provider (nil when it
        # cannot be read, which refuses steps that do not name a safe one).
        def unsafe_llm_steps(task_json, default_provider)
          steps = task_json.is_a?(Hash) && task_json['steps'].is_a?(Array) ? task_json['steps'] : []
          steps.filter_map do |step|
            next unless step.is_a?(Hash)

            tool = step['tool_name'].to_s
            next unless tool == 'llm_call' || DEFAULT_PROVIDER_LLM_TOOLS.include?(tool)

            args = step['tool_arguments'].is_a?(Hash) ? step['tool_arguments'] : {}
            provider = tool == 'llm_call' ? args['provider_override'].to_s : ''
            provider = default_provider.to_s if provider.empty?
            next if ACT_SAFE_LLM_PROVIDERS.include?(provider)

            { 'step_id' => step['step_id'], 'tool_name' => tool,
              'path' => "(provider #{provider.empty? ? 'unknown' : provider})", 'rule' => 'unsafe_provider' }
          end
        end

        # True when a work-tree write is inside its allowed place (design v0.3
        # §6.5 as ruled 2026-10-06). The accepted input is deliberately narrow,
        # so that this check and the tool read the path the same way: every
        # location argument must be a plain relative path, written as
        # '<write root>/.../<name>', with no root argument beside it. Then:
        #   - no segment below the root may start with '.' (no hidden files or
        #     directories, where agent tools keep rules), as written and as
        #     resolved;
        #   - the file name must start with name_prefix and carry one of
        #     extensions, as written and as resolved (no agent tool loads
        #     'draft_*' as instructions; a link named .md is not a document);
        #   - resolved with symlinks followed against every default root a tool
        #     may use, the path must land strictly inside the same write root.
        # A leading '/', '~' or '\', a backslash, an empty, '.' or '..' segment,
        # a NUL or other control character, a root argument, or anything that
        # cannot be resolved makes the step not inside. Never raises.
        def within_write_scope?(args, write_roots, extensions, roots, project_root:, name_prefix: nil)
          return false unless args.is_a?(Hash)

          pairs = path_pairs(args)
          root_args, files = pairs.partition { |k, _| (key_tokens(k) & ROOT_TOKENS).any? }
          return false if files.empty? || !root_args.empty?

          exts = Array(extensions).map(&:downcase)
          candidates = Array(roots).compact.map(&:to_s).reject(&:empty?)
          rels = Array(write_roots).map(&:to_s)
          return false if rels.empty? || exts.empty? || candidates.empty?

          name_ok = lambda do |name|
            exts.include?(File.extname(name).downcase) && (name_prefix.nil? || name.start_with?(name_prefix))
          end

          files.all? do |_key, raw|
            next false if raw.match?(/[[:cntrl:]\\]/) || raw.start_with?('/', '~')

            segments = raw.split('/', -1)
            next false if segments.any? { |p| p.empty? || p == '.' || p == '..' }

            rel = rels.find { |r| raw.start_with?("#{r}/") }
            next false unless rel

            below = raw.delete_prefix("#{rel}/").split('/')
            next false if below.empty? || below.any? { |p| p.start_with?('.') } || !name_ok.call(below.last)

            dir = canonical(File.expand_path(rel, project_root))
            candidates.all? do |root|
              full = canonical(File.expand_path(raw, root))
              next false unless full.start_with?("#{dir}/")

              resolved = full.delete_prefix("#{dir}/").split('/')
              !resolved.empty? && resolved.none? { |p| p.start_with?('.') } && name_ok.call(resolved.last)
            rescue StandardError
              false
            end
          rescue StandardError
            false
          end
        rescue StandardError
          false
        end

        # A protected segment or file name anywhere in the path refuses it,
        # whatever root the tool resolves against.
        def protected_name?(raw)
          # A control character (NUL included) is refused outright: no real
          # location needs one, and File.extname raises on NUL.
          return true if raw.to_s.match?(/[[:cntrl:]]/)

          parts = raw.split(%r{[/\\]}).map(&:downcase)
          # No hidden name, anywhere, for any step (operator ruling 2026-10-06):
          # dotfiles and dot-directories are where secrets (.env, .ssh, .aws,
          # .netrc) and tool configuration live, and naming them one by one did
          # not close. '.' and '..' are not names; '..' is refused on its own.
          return true if parts.any? { |p| p.start_with?('.') && p != '.' && p != '..' }

          parts.any? { |p| PROTECTED_SEGMENTS.include?(p) } || PROTECTED_BASENAMES.include?(parts.last) ||
            PROTECTED_EXTENSIONS.include?(File.extname(parts.last.to_s))
        end

        # True when the path, resolved against root, lands in a protected
        # directory, lies outside every allowed root, or has a protected name
        # once symlinks are resolved. Names are checked only below the allowed
        # root, so a project that itself lives under a protected segment (a
        # Claude Code worktree under .claude/worktrees) is not refused wholesale.
        # The rule a path breaks when resolved against root, or nil.
        # Protected directories compare case-insensitively (fail-closed on
        # case-insensitive filesystems); containment compares with case kept,
        # so on a case-sensitive filesystem /srv/project is not inside
        # /srv/Project. No allowed root at all means nothing is allowed.
        def touch_rule(path, root, protected, allowed)
          full = canonical(File.expand_path(path, root))
          low = full.downcase
          return 'protected' if protected.any? { |dir| low == dir || low.start_with?("#{dir}/") }
          return 'outside' if allowed.empty?

          base = allowed.select { |dir| full == dir || full.start_with?("#{dir}/") }.max_by(&:length)
          return 'outside' unless base

          below = full.delete_prefix(base).delete_prefix('/')
          !below.empty? && protected_name?(below) ? 'protected' : nil
        rescue StandardError
          'unresolvable'
        end

        def touches?(path, root, protected, allowed)
          !touch_rule(path, root, protected, allowed).nil?
        end

        # realpath of the deepest existing ancestor, with the rest appended,
        # so a symlink inside the workspace that points at a protected
        # location is seen. A symlink counts as existing even when its target
        # does not, and its realpath then raises: a dangling link is a hit.
        def canonical(path)
          existing = path
          rest = []
          until File.exist?(existing) || File.symlink?(existing) || existing == File.dirname(existing)
            rest.unshift(File.basename(existing))
            existing = File.dirname(existing)
          end
          base = File.exist?(existing) || File.symlink?(existing) ? File.realpath(existing) : existing
          rest.empty? ? base : File.join(base, *rest)
        end

        def safe_canonical(path)
          canonical(File.expand_path(path.to_s))
        rescue StandardError
          File.expand_path(path.to_s)
        end

        # Validate a declared layer surface fail-closed: unknown entries are
        # refused, and any attempt to declare the record store is refused with
        # its own message (AGT-5: never declarable).
        def validate_surface!(layer_surface)
          surface = Array(layer_surface).map(&:to_s)
          surface.each do |layer|
            if %w[record chain attestation].include?(layer)
              raise SurfaceError,
                    "the record store is never declarable (AGT-5): #{layer.inspect}"
            end
            unless LAYER_WRITE_TOOLS.key?(layer)
              raise SurfaceError,
                    "unknown layer surface #{layer.inspect} (declarable: #{LAYER_WRITE_TOOLS.keys.join(', ')})"
            end
          end
          surface
        end

        # Deny set for the ACT invocation context under a declared surface:
        # record-store writers + live-tree writers + every governance writer
        # whose layer is not declared + configured extras.
        def act_blacklist(layer_surface, extra_denied: [])
          surface = validate_surface!(layer_surface)
          denied = RECORD_STORE_TOOLS.dup
          denied.concat(LIVE_TREE_WRITE_TOOLS)
          LAYER_WRITE_TOOLS.each do |layer, tools|
            denied.concat(tools) unless surface.include?(layer)
          end
          denied.concat(Array(extra_denied).map(&:to_s))
          denied.uniq
        end
      end
    end
  end
end
