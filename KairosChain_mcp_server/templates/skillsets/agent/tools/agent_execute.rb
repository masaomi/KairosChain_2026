# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'

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
            args = build_args(tools, allowed_tools_patterns, budget, model, context)

            # Verify claude CLI exists using the same scrubbed env
            _out, _err, st = Open3.capture3(safe_env, 'which', 'claude', unsetenv_others: true)
            unless st.success?
              return error_text('Claude Code CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code')
            end
            root = project_root

            result = execute_with_timeout(safe_env, args, task, timeout, root)
            text_content(JSON.generate(result))
          rescue SubprocessTimeout => e
            text_content(JSON.generate({
              'status' => 'timeout', 'error' => e.message, 'timeout_seconds' => timeout
            }))
          rescue StandardError => e
            error_text("#{e.class}: #{e.message}")
          end

          private

          class SubprocessTimeout < StandardError; end

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

          def execute_with_timeout(env, args, task, timeout, root)
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
                        return parse_stream_output(stdout_data, truncated: true)
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

              result = parse_stream_output(stdout_data)
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

          def agent_execute_config(key, default = nil)
            @_agent_yml_cache ||= begin
              config_path = File.join(__dir__, '..', 'config', 'agent.yml')
              if File.exist?(config_path)
                require 'yaml'
                YAML.safe_load(File.read(config_path)) || {}
              else
                {}
              end
            rescue StandardError
              {}
            end
            @_agent_yml_cache.dig('agent_execute', key) || default
          end

          def error_text(message)
            text_content(JSON.generate({ 'status' => 'error', 'error' => message }))
          end
        end
      end
    end
  end
end
