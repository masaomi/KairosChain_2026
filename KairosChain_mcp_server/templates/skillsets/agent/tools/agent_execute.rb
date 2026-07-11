# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'uri'
require_relative '../lib/agent/confinement'
require_relative '../lib/agent/staging'
require_relative '../lib/agent/mediator'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentExecute < KairosMcp::Tools::BaseTool
          DEFAULT_TOOLS = %w[Read Edit Write Glob Grep].freeze
          # Include auth + config vars Claude Code needs to function
          SAFE_ENV_VARS = %w[
            PATH HOME LANG LC_ALL TERM USER SHELL TMPDIR
            XDG_CONFIG_HOME XDG_DATA_HOME
            ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK
            AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
          ].freeze
          MAX_OUTPUT_BYTES = 1_048_576  # 1MB
          MAX_STDERR_BYTES = 1_048_576  # 1MB
          DEFAULT_TIMEOUT = 120
          MAX_TIMEOUT = 600
          DEFAULT_BUDGET_USD = 0.50

          def name
            'agent_execute'
          end

          def description
            'Execute a software engineering task via Claude Code subprocess. ' \
              'Delegates file operations (Read/Edit/Write) to a sandboxed Claude Code instance. ' \
              'Bash is excluded by default; requires allowed_tools patterns (e.g., Bash(git:*)). ' \
              'Mandate risk_budget is enforced at the ACT routing level, not within this tool.'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent execute file edit code subprocess]
          end

          def related_tools
            %w[agent_start agent_step autoexec_run]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                task: {
                  type: 'string',
                  description: 'Task description for Claude Code to execute'
                },
                context: {
                  type: 'string',
                  description: 'Goal/progress context injected via --append-system-prompt (optional)'
                },
                tools: {
                  type: 'array', items: { type: 'string' },
                  description: 'Tools to enable (default: Read,Edit,Write,Glob,Grep). ' \
                    'Add "Bash" for shell access (requires risk_budget: medium + allowed_tools patterns).'
                },
                allowed_tools: {
                  type: 'array', items: { type: 'string' },
                  description: 'Fine-grained tool patterns for --allowedTools (e.g., "Bash(git:*) Bash(ruby:*)")'
                },
                timeout: {
                  type: 'integer',
                  description: "Timeout in seconds (default: #{DEFAULT_TIMEOUT}, max: #{MAX_TIMEOUT})"
                },
                max_budget_usd: {
                  type: 'number',
                  description: "Max API cost in USD (default: #{DEFAULT_BUDGET_USD})"
                },
                model: {
                  type: 'string',
                  description: 'Model override (default: sonnet for speed)'
                },
                input_files: {
                  type: 'array', items: { type: 'string' },
                  description: 'Guard track (AGT-2): boundary-curated files copied into the ' \
                    'scratch work area before execution. Only used when guard.enabled.'
                }
              },
              required: ['task']
            }
          end

          def call(arguments)
            task = arguments['task']
            return error_text('task is required') if task.nil? || task.strip.empty?

            context = arguments['context']
            tools = arguments['tools'] || agent_execute_config('default_tools', DEFAULT_TOOLS).dup
            allowed_tools_patterns = arguments['allowed_tools']
            cfg_max_timeout = agent_execute_config('max_timeout', MAX_TIMEOUT).to_i
            cfg_default_timeout = agent_execute_config('default_timeout', DEFAULT_TIMEOUT).to_i
            timeout = [[arguments['timeout'] || cfg_default_timeout, 1].max, cfg_max_timeout].min
            model = arguments['model'] || agent_execute_config('default_model', 'sonnet')

            # Clamp budget to configured max
            config_max = agent_execute_config('max_budget_usd', 2.0).to_f
            raw_budget = arguments['max_budget_usd'] || agent_execute_config('default_budget_usd', DEFAULT_BUDGET_USD).to_f
            budget = [raw_budget, config_max].min

            # Bash gating: require fine-grained patterns and risk_budget: medium
            if tools.include?('Bash')
              unless allowed_tools_patterns&.any? { |p| p.start_with?('Bash(') }
                return error_text(
                  "Bash requires fine-grained patterns via allowed_tools (e.g., 'Bash(git:*)'). " \
                  "Unrestricted Bash is not permitted."
                )
              end
              # Check mandate risk_budget if available via invocation context
              if @safety&.respond_to?(:current_user)
                # In autonomous mode, risk_budget is checked at the mandate level
                # agent_execute trusts that the ACT phase has already passed Gate 5
              end
            end

            safe_env = build_safe_env
            substrate = agent_execute_config('substrate', 'cli').to_s
            args = build_args(tools, allowed_tools_patterns, budget, model, context)

            if substrate != 'native_body'
              # Verify claude CLI exists using the same scrubbed env
              _out, _err, st = Open3.capture3(safe_env, 'which', 'claude', unsetenv_others: true)
              unless st.success?
                return error_text('Claude Code CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code')
              end
            end
            root = project_root

            # AGT-6: the driver's decision is authoritative. If the driver
            # (agent_step, which holds the session) says guard is required, we
            # confine regardless of what this tool re-reads from disk — and a
            # config that cannot be resolved never silently downgrades to
            # unconfined (guard_required? raises on a malformed existing file).
            #
            # Slice 2 (NB-5): which substrate carries the delegated act is
            # fixed by boundary-owned configuration before the loop runs —
            # never chosen per-act by the deciding context. One dispatch
            # contract, two substrates: the guard wiring (guard flag, scratch
            # declaration, input curation, manifest return) is shared code
            # path below, not a parallel implementation.
            result =
              if substrate == 'native_body'
                unless guard_required?(arguments)
                  # The native body runs only under its egress-scoped profile;
                  # an unconfined launch has no profile at all and is refused
                  # (NB-5 substrate→profile binding, fail-closed).
                  raise Agent::Confinement::ConfinementError,
                        'native body requires the guard (egress-scoped confinement); unguarded launch refused (NB-5)'
                end
                execute_confined_native(task, context, timeout, root,
                                        arguments['input_files'] || [])
              elsif guard_required?(arguments)
                execute_confined(safe_env, args, task, timeout, root,
                                 arguments['input_files'] || [])
              else
                execute_with_timeout(safe_env, args, task, timeout, root)
              end
            text_content(JSON.generate(result))
          rescue Agent::Confinement::ConfinementError => e
            # AGT-6: guard failures halt, they do not degrade to unconfined execution.
            text_content(JSON.generate({ 'status' => 'guard_halt', 'error' => e.message }))
          rescue SubprocessTimeout => e
            text_content(JSON.generate({
              'status' => 'timeout', 'error' => e.message, 'timeout_seconds' => timeout
            }))
          rescue StandardError => e
            error_text("#{e.class}: #{e.message}")
          end

          private

          class SubprocessTimeout < StandardError; end

          # Guard is required if the driver flagged it OR local config enables
          # it. Fail-closed: an existing-but-malformed config raises (the caller
          # returns guard_halt) rather than resolving to "unguarded".
          def guard_required?(arguments)
            return true if arguments['guard_required'] == true

            agent_yml.dig('guard', 'enabled') == true
          end

          # Guard track Stage B (AGT-1/AGT-2, design v0.3.1 FROZEN): the act runs
          # in a per-act scratch area, disjoint by construction from the project
          # tree and the stores, under substrate-level write confinement with the
          # stores read-denied. Results are returned as a manifest; the return to
          # the live tree is the driver's verdict-gated merge, never this tool's.
          def execute_confined(env, args, task, timeout, root, input_files)
            scratch, stores_dir, baseline = prepare_guarded_scratch(env, root, input_files)

            confined_args = Agent::Confinement.wrap(args, scratch, stores_dir)
            result = execute_with_timeout(env, confined_args, task, timeout, scratch)
            result['guard'] = 'confined'
            result['scratch_dir'] = scratch
            result['manifest'] = Agent::Confinement.manifest(scratch, baseline: baseline)
            result['substrate'] = 'cli'
            result
          end

          # Shared guard wiring for both substrates (§4: one dispatch
          # contract — the scratch declaration, input curation, and manifest
          # geometry never fork per substrate).
          def prepare_guarded_scratch(env, root, input_files)
            stores_dir = File.join(root, '.kairos')
            unless File.directory?(stores_dir)
              raise Agent::Confinement::ConfinementError, "stores dir not found: #{stores_dir}"
            end
            _out, _err, st = Open3.capture3(env, 'which', 'sandbox-exec', unsetenv_others: true)
            unless st.success?
              raise Agent::Confinement::ConfinementError,
                    'sandbox-exec not available — confined execution impossible (fail-closed)'
            end

            scratch = Dir.mktmpdir('agent_act_')
            scratch = Agent::Confinement.assert_disjoint!(scratch, root)

            stores_real = File.realpath(stores_dir)
            copied = input_files.map do |f|
              # Curated inputs must not smuggle the stores into the executor's
              # readable scratch (AGT-2). Resolve fail-closed and refuse any
              # input that resolves into the stores.
              src = begin
                File.realpath(f)
              rescue StandardError => e
                raise Agent::Confinement::ConfinementError, "input_file unresolvable (#{e.class}): #{f}"
              end
              if src == stores_real || src.start_with?("#{stores_real}/")
                raise Agent::Confinement::ConfinementError, "input_file resolves into the stores (refused): #{f}"
              end
              rel = File.basename(f)
              FileUtils.cp(src, File.join(scratch, rel))
              rel
            end
            baseline = Agent::Confinement.baseline(scratch, copied)
            [scratch, stores_dir, baseline]
          end

          # Slice 2 (NB-1..5): the native-body substrate on the delegated act
          # route. Same scratch geometry, input curation, and manifest return
          # as the CLI substrate; what changes is the launched program — a
          # staged, content-address-pinned executable closure run with
          # RubyGems disabled under the egress-scoped profile, its only
          # outbound path the boundary-side mediator.
          def execute_confined_native(task, context, timeout, root, input_files)
            native_cfg = native_body_config
            provider = native_cfg['provider'].to_s
            # NB-4 driver-side structural gates, evaluated before any staging or
            # launch: (1) an excluded transport named by configuration is
            # refused; (2) the egress scope must be non-empty. R1 F6: an empty
            # scope is a native PRE-LAUNCH guard failure (ConfinementError →
            # guard_halt), not an ordinary act error — a bare ArgumentError
            # from Mediator.new would be caught as StandardError → status
            # 'error', which agent_step does NOT treat as a guard checkpoint.
            Agent::Staging.assert_eligible_provider!(provider)
            allowed_hosts = allowed_hosts_for(provider, native_cfg)
            if allowed_hosts.empty?
              raise Agent::Confinement::ConfinementError,
                    "native body egress scope is empty for provider #{provider.inspect} " \
                    '(curate base_url/allowed_hosts) — refusing an unscoped launch (NB-4)'
            end

            env = build_native_env(nil)
            scratch, stores_dir, baseline = prepare_guarded_scratch(env, root, input_files)

            # NB-2: stage the whole executable closure read-only, outside the
            # work area, pinned by one content address; re-verify immediately
            # before launch (same pre-launch step — no TOCTOU window, §9).
            staged_root = Dir.mktmpdir('agent_stage_')
            staged = Agent::Staging.stage!(staged_root, scratch_dir: scratch, project_root: root)
            closure_sha = Agent::Staging.verify!(staged['staged_dir'])

            # NB-4: credential is resolved driver-side and delivered into the
            # body's intake (stdin) — never argv, never a work-area file, and
            # ABSENT from the process environment the tool loop runs under.
            env_var = native_cfg['api_key_env'].to_s
            credential = env_var.empty? ? nil : ENV[env_var]
            if provider != 'local' && (credential.nil? || credential.empty?)
              raise Agent::Confinement::ConfinementError,
                    "provider credential not resolvable driver-side (#{env_var}) — refusing an unauthenticatable launch"
            end

            # NB-4: sole-path egress mediator, boundary-side, hostname-scoped
            # to the curated provider destination(s) (validated non-empty
            # above), re-checked every hop. Started before the payload so the
            # mediator enters the adapter as an EXPLICIT proxy (ambient env
            # proxies are silently skipped for loopback destinations by
            # URI#find_proxy — structural, not ambient, is the sole-path
            # guarantee).
            # RD-3: create AND start inside the begin whose ensure stops it, so
            # a raise during start! cannot leak the listening socket/threads.
            mediator = Agent::Mediator.new(allowed_hosts: allowed_hosts)
            begin
              mediator.start!
              payload = {
                'task' => task,
                'context' => context.to_s,
                'tools' => native_cfg['tools'] || DEFAULT_TOOLS,
                'ceilings' => {
                  'max_steps' => native_cfg['max_steps'] || 20,
                  'max_spend_tokens' => native_cfg['max_spend_tokens'] || 100_000,
                  'max_wall_seconds' => timeout
                },
                'model_config' => {
                  'provider' => provider,
                  'model' => native_cfg['model'],
                  'api_key_env' => env_var,
                  'base_url' => native_cfg['base_url'],
                  'proxy' => mediator.proxy_url,
                  'max_tokens' => native_cfg['max_tokens'] || 4096,
                  'timeout_seconds' => timeout
                }.compact,
                'credential' => credential.to_s,
                'work_dir' => scratch
              }
              # NB-3: intake is value-only — a payload carrying a store handle
              # or an instance-channel grant is refused HERE, before launch.
              Agent::Staging.validate_intake!(payload)

              env = build_native_env(mediator.proxy_url)
              cmd = [RbConfig.ruby, '--disable-gems',
                     *Agent::Staging.load_path_args(staged['staged_dir']),
                     Agent::Staging.body_entrypoint(staged['staged_dir'])]
              # wrap_native asserts the profile is egress-scoped (NB-5
              # substrate→profile binding) before anything launches.
              wrapped = Agent::Confinement.wrap_native(cmd, scratch, stores_dir, mediator.port)

              result = execute_with_timeout(env, wrapped, JSON.generate(payload), timeout, scratch,
                                            output_parser: method(:parse_native_output))
            ensure
              mediator.stop! if mediator
            end

            result['guard'] = 'confined'
            result['scratch_dir'] = scratch
            result['manifest'] = Agent::Confinement.manifest(scratch, baseline: baseline)
            result['substrate'] = 'native_body'
            # The constitutive record of the act names WHICH executable
            # carried it (NB-2): closure digest next to the spec hash.
            result['closure_sha256'] = closure_sha
            result['egress_refusals'] = mediator.refusals unless mediator.refusals.empty?
            result
          ensure
            FileUtils.remove_entry(staged_root) if staged_root && Dir.exist?(staged_root)
          end

          def native_body_config
            cfg = agent_execute_config('native_body', nil)
            unless cfg.is_a?(Hash) && cfg['provider']
              # Fail-closed: a native-substrate selection without a curated
              # model configuration never guesses a provider.
              raise Agent::Confinement::ConfinementError,
                    'substrate is native_body but agent_execute.native_body config (provider/model) is missing'
            end
            cfg
          end

          # Provider destination identity for the egress scope. `local` and
          # explicit base_url derive the hostname from the curated URL —
          # identity comes from the curated configuration, never from what
          # the body asks for.
          PROVIDER_HOSTS = {
            'anthropic' => ['api.anthropic.com'],
            'openai' => ['api.openai.com'],
            'openrouter' => ['openrouter.ai']
          }.freeze

          def allowed_hosts_for(provider, native_cfg)
            hosts = Array(native_cfg['allowed_hosts']).map(&:to_s)
            hosts += PROVIDER_HOSTS.fetch(provider, [])
            if native_cfg['base_url']
              # R2 G4: a malformed base_url is a native pre-launch guard
              # failure (ConfinementError → guard_halt), not an ordinary act
              # error — a bare URI::InvalidURIError would be caught as
              # StandardError → status 'error', which agent_step does not treat
              # as a guard checkpoint (the F6 class of bug, second input).
              host = begin
                URI.parse(native_cfg['base_url'].to_s).host
              rescue URI::InvalidURIError => e
                raise Agent::Confinement::ConfinementError,
                      "native base_url is unparseable (#{e.message}) — refusing launch (NB-4)"
              end
              hosts << host if host
            end
            hosts.uniq
          end

          # The native body's process environment: minimal runtime vars plus
          # the mediator proxy. Deliberately NOT build_safe_env — that list
          # carries provider credentials for the CLI substrate, and the
          # credential must be absent from the tool loop's environment (NB-4).
          NATIVE_ENV_VARS = %w[PATH HOME LANG LC_ALL TERM TMPDIR].freeze

          def build_native_env(proxy_url)
            env = {}
            NATIVE_ENV_VARS.each { |k| env[k] = ENV[k] if ENV[k] }
            if proxy_url
              env['http_proxy'] = proxy_url
              env['https_proxy'] = proxy_url
              env['HTTP_PROXY'] = proxy_url
              env['HTTPS_PROXY'] = proxy_url
            end
            env
          end

          # Body stdout contract: one JSON report line (see native_body/main.rb).
          # Maps body statuses onto the driver result statuses the guard
          # wiring already consumes ('guard_halt' halts the loop; anything
          # not 'ok' propagates as act failure — never silent success).
          def parse_native_output(raw, truncated: false)
            line = raw.to_s.lines.map(&:strip).reject(&:empty?).last
            data = begin
              line && JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
            unless data.is_a?(Hash)
              return { 'status' => 'no_result', 'result' => raw.to_s[0, 500],
                       'truncated' => truncated, 'is_error' => true }
            end

            status =
              case data['status']
              when 'completed' then 'ok'
              when 'guard_failure' then 'guard_halt'
              else data['status'] # halted_ceiling / failed — non-success
              end
            {
              'status' => status,
              'result' => data['summary'].to_s,
              'error' => data['halt_reason'],
              'tool_calls_count' => data['tool_calls'] || 0,
              'llm_calls' => data['llm_calls'] || 0,
              'spend' => data['spend'],
              'refused_tool_requests' => data['refused_tool_requests'] || [],
              'truncated' => truncated,
              'is_error' => status != 'ok'
            }.compact
          end

          def build_args(tools, allowed_tools_patterns, budget, model, context)
            args = ['claude', '-p',
                    '--output-format', 'stream-json',
                    '--permission-mode', 'acceptEdits',
                    '--tools', tools.join(','),
                    '--max-budget-usd', budget.to_s,
                    '--model', model]

            if allowed_tools_patterns && !allowed_tools_patterns.empty?
              args += ['--allowedTools', allowed_tools_patterns.join(',')]
            end

            if context && !context.strip.empty?
              args += ['--append-system-prompt', context]
            end

            args
          end

          def build_safe_env
            env = {}
            SAFE_ENV_VARS.each { |k| env[k] = ENV[k] if ENV[k] }
            env
          end

          def execute_with_timeout(env, args, task, timeout, root, output_parser: method(:parse_stream_output))
            stdout_data = +''
            stderr_data = +''
            pid = nil

            Open3.popen3(env, *args, unsetenv_others: true, chdir: root) do |stdin, stdout, stderr, wait_thr|
              pid = wait_thr.pid
              stdin.write(task)
              stdin.close

              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
              readers = [stdout, stderr]

              until readers.empty?
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if remaining <= 0
                  kill_process(pid)
                  wait_thr.join(5)
                  raise SubprocessTimeout, "Timed out after #{timeout}s"
                end

                ready = IO.select(readers, nil, nil, [remaining, 5].min)
                next unless ready

                ready[0].each do |io|
                  begin
                    chunk = io.read_nonblock(65536)
                    if io == stdout
                      stdout_data << chunk
                      if stdout_data.bytesize > MAX_OUTPUT_BYTES
                        kill_process(pid)
                        wait_thr.join(5)
                        stdout_data = stdout_data.byteslice(0, MAX_OUTPUT_BYTES)
                        return output_parser.call(stdout_data, truncated: true)
                      end
                    else
                      stderr_data << chunk
                      stderr_data = stderr_data.byteslice(0, MAX_STDERR_BYTES) if stderr_data.bytesize > MAX_STDERR_BYTES
                    end
                  rescue IO::WaitReadable, Errno::EAGAIN
                    # Spurious readability — retry on next select
                  rescue EOFError
                    readers.delete(io)
                  end
                end
              end

              # IO done — wait for process with timeout guard
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if remaining > 0
                unless wait_thr.join([remaining, 30].min)
                  kill_process(pid)
                  wait_thr.join(5)
                  raise SubprocessTimeout, "Process did not exit after IO closed (#{timeout}s deadline)"
                end
              else
                kill_process(pid)
                wait_thr.join(5)
                raise SubprocessTimeout, "Timed out after #{timeout}s"
              end

              result = output_parser.call(stdout_data)
              result['exit_status'] = wait_thr.value&.exitstatus
              result['stderr'] = stderr_data[0..500] unless stderr_data.empty?
              result
            end
          end

          def kill_process(pid)
            Process.kill('TERM', pid)
            sleep 2
            Process.kill('KILL', pid) rescue nil
          rescue Errno::ESRCH
            # Already dead
          end

          def parse_stream_output(raw, truncated: false)
            lines = raw.split("\n").filter_map { |l| JSON.parse(l) rescue nil }

            result_msg = lines.find { |l| l['type'] == 'result' }

            tool_uses = lines.select { |l|
              l['type'] == 'assistant' &&
                l.dig('message', 'content')&.any? { |c| c['type'] == 'tool_use' }
            }

            files_modified = extract_modified_files(tool_uses)

            {
              'status' => result_msg ? 'ok' : 'no_result',
              'result' => result_msg&.dig('result') || '',
              'files_modified' => files_modified,
              'tool_calls_count' => tool_uses.size,
              'truncated' => truncated,
              'is_error' => result_msg&.dig('is_error') || false
            }
          end

          def extract_modified_files(tool_uses)
            files = Set.new
            tool_uses.each do |tu|
              (tu.dig('message', 'content') || []).each do |c|
                next unless c['type'] == 'tool_use'
                input = c['input'] || {}
                case c['name']
                when 'Edit', 'Write'
                  files << input['file_path'] if input['file_path']
                end
              end
            end
            files.to_a
          end

          def project_root
            if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
              root = File.dirname(KairosMcp.data_dir)
              return root if File.directory?(root)
            end
            Dir.pwd
          end

          def agent_yml
            @_agent_yml_cache ||= begin
              config_path = File.join(__dir__, '..', 'config', 'agent.yml')
              if File.exist?(config_path)
                require 'yaml'
                # A present-but-unparseable config must NOT resolve to {} — that
                # would silently disable the guard (AGT-6 fail-open). Let the
                # parse error propagate; the guard path turns it into guard_halt.
                YAML.safe_load(File.read(config_path)) || {}
              else
                {}
              end
            end
          end

          def agent_execute_config(key, default = nil)
            agent_yml.dig('agent_execute', key) || default
          end

          def error_text(message)
            text_content(JSON.generate({ 'status' => 'error', 'error' => message }))
          end
        end
      end
    end
  end
end
