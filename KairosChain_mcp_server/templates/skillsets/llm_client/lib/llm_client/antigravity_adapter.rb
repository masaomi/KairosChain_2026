# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'tmpdir'
require 'fileutils'
require_relative 'adapter'
require_relative 'safe_subprocess'
require_relative 'cli_failure'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that uses the Antigravity CLI (`agy`) as the LLM backend.
      # Uses the CLI's own login state under ~/.gemini/antigravity-cli/; HOME is
      # preserved so that state is reachable.
      #
      # Transport (measured 2026-11-15, agy 1.5.9; re-measured 2026-11-18, 1.5.10):
      #   - `agy -p` takes the prompt only as the flag's value. `-p -` sends the
      #     literal "-" as the prompt, and an empty value is refused. A review
      #     prompt on argv would be bounded by ARG_MAX and visible in ps, so it
      #     is not used.
      #   - `--input-format stream-json` reads NDJSON from stdin, one line per
      #     turn, shaped {"event":"user","message":{"content":"..."}}. It
      #     requires `--output-format stream-json` and refuses -p beside it.
      #     A 103,620-byte prompt went through on one line (2026-11-18).
      #   - Output is NDJSON: an `init` event, then `step_update` events (each
      #     with a step_type; tool steps carry tool_name and a state), then one
      #     `result` event carrying status, response and usage.
      #   - A turn whose tool needed permission can end with exit 0 and an empty
      #     response, so exit status alone cannot mean success. Success here is
      #     exit 0, a `result` with status SUCCESS and a non-empty response, and
      #     no tool step that completed.
      #
      # Confinement. A review seat only answers; it needs no tool. `agy` is an
      # agent with file, shell, web-search, browser and scheduling tools, and
      # each guard below closes a path the others leave open (measured
      # 2026-11-18, log/mlr_agy_gemini_seat_20261115/r2_probes/):
      #   - A per-call agent definition in the per-call workspace,
      #     `.agents/agents/kairos_review_seat_<random>.md`, with an empty
      #     `tools` allowlist, selected with `--agent`. This is the only guard
      #     that removes `search_web`: deny rules, including `*`, do not reach
      #     it, and toolPermission "strict" does not stop it in headless mode.
      #     Under the agent the model reports no web, file or shell tool; one
      #     tool, `manage_task`, is still declared to it. The name is random per
      #     call so no agent of the same name elsewhere (for example under
      #     ~/.gemini/config/agents/) can stand in for it.
      #   - `--settings` (one session, never saved): deny rules on all seven
      #     permission actions, toolPermission "strict", no non-workspace
      #     access, the terminal sandbox on, slash commands off, agentMode ""
      #     rather than "plan". A read outside the workspace and a shell fetch
      #     were both refused by the deny rules.
      #   - `--mode plan` is NOT used. It injects the /plan procedure, and on
      #     2026-11-15 plan-mode sessions wrote plan files under
      #     ~/.gemini/antigravity-cli/brain/. Plan mode is not read-only.
      #   - Fail closed on what the session reports, on every run, before the
      #     run is judged a success or a failure: the init event must name this
      #     call's agent (when the definition is not loaded, init carries no
      #     agent) and permission mode "strict" (this shows toolPermission is in
      #     effect; the CLI does not report the deny list). Every step must be
      #     user input, a model response, or a tool step whose last reported
      #     state ended in ERROR with the CLI's permission refusal (matched
      #     against the whole message). Anything else (a tool that completed,
      #     ran and then failed, or never reported an outcome; an unrecognised
      #     state, step type or event) refuses the reply. A run that failed
      #     before any init event is an ordinary failure, not a breach. The
      #     write probe has not been run. The check
      #     happens after the run, so it cannot undo what a tool did; it makes
      #     sure such a run is never counted as a confined review. On a timeout
      #     the CLI's output is not returned to the adapter, so a breach there
      #     cannot be seen.
      #
      # Not confined: agy keeps every turn on disk under
      # ~/.gemini/antigravity-cli/ (brain/<id>/.system_generated/, including
      # logs/ and steps/, conversations/, conversation_summaries.db). No
      # setting turns this off, so an artifact reviewed through this seat
      # persists there; the response carries the CLI's conversation_id so the
      # copy can be found. The operator's own agy configuration outside the
      # per-call workspace (global MCP servers, plugins, hooks, skills under
      # ~/.gemini/config/) is not read by this adapter and not overridden by it
      # beyond the guards above; whether a configured MCP server is started
      # (its calls are denied) and whether hooks fire is not measured.
      #
      # Model attribution: the init event names a model before the model has
      # answered (it appears on runs that fail with zero turns), so it is not
      # evidence of who answered and is not returned as model_observed. (agy's
      # own transcript does record the generating model per response step;
      # under the agent it read gemini-4-hydrogen-high on 2026-11-18. That
      # store is the CLI's private format and is not read here.)
      #
      # Effort is part of the model id (e.g. gemini-4-hydrogen-high), so no
      # effort flag is built; a configured effort would be recorded and never
      # sent, which is why roster entries for this provider carry none.
      class AntigravityAdapter < Adapter
        DEFAULT_TIMEOUT = 180
        BINARY = 'agy'
        AGENT_PREFIX = 'kairos_review_seat'

        DENY_RULES = %w[
          read_file(*) write_file(*) read_url(*) execute_url(*)
          command(*) mcp(*) unsandboxed(*)
        ].freeze

        SESSION_SETTINGS = {
          'agentMode' => '',
          'toolPermission' => 'strict',
          'allowNonWorkspaceAccess' => false,
          'enableTerminalSandbox' => true,
          'disableSlashCommands' => true,
          'permissions' => { 'deny' => DENY_RULES }
        }.freeze

        BASE_ARGS = [
          BINARY, '--sandbox', '--disable-slash-commands',
          '--settings', JSON.generate(SESSION_SETTINGS),
          '--input-format', 'stream-json', '--output-format', 'stream-json'
        ].freeze

        # Shapes that are not a breach. Events: init, step_update, result.
        # Steps: user input, a model response, or a tool step whose LAST
        # reported state (per step_index) is ERROR with the CLI's own permission
        # refusal, matched against the whole message in the shape measured on
        # 2026-11-18:
        #   permission check failed for read_file "<path>": Permission denied
        #   for read_file(<path>). Matches user-configured deny rule.
        # A tool step that never reports an outcome is a breach too.
        ALLOWED_EVENTS = %w[init step_update result].freeze
        ALLOWED_STEP_TYPES = %w[user_input agent_response].freeze
        REFUSAL_RE = /\Apermission check failed for \S+ ".*": Permission denied for \S+\(.*\)\. Matches user-configured deny rule\.\z/m

        def self.agent_definition(name)
          <<~MD
            ---
            name: #{name}
            description: Answers the message in a single reply, without tools.
            tools: []
            mainAgent: true
            subagent: false
            model: inherit
            commandExecutionPolicy: "off"
            ---
            Answer the user's message directly, in a single reply. You have no tools.
          MD
        end

        # Status codes count only where the text says they are a status: a
        # bare "500" also matches "500 tokens".
        TRANSIENT_PATTERNS = [
          /unavailable/i, /overloaded/i, /temporar/i, /rate.?limit/i,
          /resource.?exhausted/i,
          /\b(?:http|status|code|error)\s*[:=]?\s*(?:429|500|502|503|504)\b/i
        ].freeze

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          prompt = build_prompt(messages, system, tools, output_schema)
          timeout_seconds = @config&.dig('timeout_seconds') || DEFAULT_TIMEOUT

          agent = "#{AGENT_PREFIX}_#{SecureRandom.hex(6)}"
          args = BASE_ARGS + ['--agent', agent]
          args << '--model' << model.to_s if model && !model.to_s.strip.empty?

          stdin_line = JSON.generate({ 'event' => 'user', 'message' => { 'content' => prompt } }) + "\n"

          workdir = Dir.mktmpdir('kairos_agy_')
          stdout, stderr, status = begin
            write_agent_definition(workdir, agent)
            SafeSubprocess.safe_capture(
              args,
              stdin_data: stdin_line,
              timeout_seconds: timeout_seconds,
              env: {},
              dispatch_id: @config&.dig('dispatch_id'),
              chdir: workdir
            )
          ensure
            FileUtils.remove_entry(workdir, true)
          end

          events = parse_events(stdout)
          result = events.reverse.find { |e| e['event'] == 'result' }&.dig('result')
          ok = status&.success? && result && result['status'] == 'SUCCESS' &&
               !result['response'].to_s.strip.empty?

          # Confinement first, on every run that reached the session: a breach
          # on a run that also failed must not read as an ordinary (possibly
          # retryable) failure. A run that failed before any init event (CLI
          # not started, unknown agent, login) has no session to judge and is
          # an ordinary failure.
          started = events.any? { |e| e['event'] == 'init' }
          breach = started || ok ? confinement_breach(events, agent) : nil
          if breach
            also = ok ? '' : " (the run also failed: #{failure_detail(result, stderr, status)[0..200]})"
            raise ApiError.new(
              "agy seat not confined: #{breach}#{also}", provider: 'antigravity', retryable: false
            )
          end

          unless ok
            detail = failure_detail(result, stderr, status)
            raise ApiError.new(
              "agy exited with status #{status&.exitstatus.inspect}: #{detail[0..300]}",
              provider: 'antigravity',
              retryable: TRANSIENT_PATTERNS.any? { |re| re.match?(detail) }
            )
          end

          build_response(result, tools, model)
        rescue Timeout::Error
          raise ApiError.new(
            "agy timed out after #{timeout_seconds}s",
            provider: 'antigravity', retryable: true, code: CliFailure::CLI_TIMEOUT
          )
        rescue Errno::ENOENT
          raise ApiError.new(
            'agy CLI not found. Install the Antigravity CLI.',
            provider: 'antigravity', retryable: false, code: CliFailure.missing_code(BINARY)
          )
        rescue ApiError
          raise
        rescue StandardError => e
          raise ApiError.new("agy error: #{e.message}", provider: 'antigravity')
        end

        private

        def write_agent_definition(workdir, name)
          dir = File.join(workdir, '.agents', 'agents')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "#{name}.md"), self.class.agent_definition(name))
        end

        # What the session itself reports. Returns a description of the first
        # breach, or nil. Allow-list shaped: anything not recognised as safe is
        # a breach.
        def confinement_breach(events, agent)
          init = events.find { |e| e['event'] == 'init' }&.dig('init')
          return 'no init event' unless init.is_a?(Hash)

          loaded = init['agent']
          unless loaded == agent
            return "agent #{loaded.inspect}, not this call's #{agent} (tool allowlist not in effect)"
          end

          mode = init['permission_mode'].to_s
          return "permission mode #{mode.inspect}, not \"strict\"" unless mode == 'strict'

          last = {}
          events.each_with_index do |e, i|
            kind = e['event'].to_s
            return "unrecognised event #{kind.inspect}" unless ALLOWED_EVENTS.include?(kind)
            next unless kind == 'step_update'

            s = e['step_update']
            return 'malformed step_update' unless s.is_a?(Hash)

            type = s['step_type'].to_s
            next if ALLOWED_STEP_TYPES.include?(type)
            return "unrecognised step type #{type.inspect}" unless type == 'tool'

            name = s['tool_name'] || s.dig('tool_info', 'name') || 'unnamed tool'
            state = s['state'].to_s
            next last[s['step_index'] || "anon#{i}"] = [name, s] if state == 'ACTIVE'
            next last[s['step_index'] || "anon#{i}"] = [name, s] if state == 'ERROR' && refused?(s)

            return "tool #{name} reached #{state.empty? ? '(no state)' : state}"
          end
          open = last.values.find { |_name, s| s['state'] == 'ACTIVE' }
          open ? "tool #{open[0]} never reported an outcome" : nil
        end

        def refused?(step)
          REFUSAL_RE.match?(step.dig('tool_info', 'error', 'message').to_s)
        end

        def build_prompt(messages, system, tools, output_schema = nil)
          parts = []

          if system
            parts << "[System]: #{system}"
            parts << ''
          end

          if tools && !tools.empty?
            parts << '[Available tools - respond with JSON when you want to use a tool]:'
            tools.each do |t|
              name = t[:name] || t['name']
              desc = t[:description] || t['description']
              schema = t[:input_schema] || t['input_schema'] || t[:inputSchema] || t['inputSchema']
              parts << "- #{name}: #{desc}"
              if schema.is_a?(Hash) && schema['properties']
                parts << "  Parameters: #{schema['properties'].keys.join(', ')}"
              end
            end
            parts << ''
            parts << 'To use a tool, include in your response:'
            parts << '```json'
            parts << '{"tool_use": [{"name": "tool_name", "input": {"param": "value"}}]}'
            parts << '```'
            parts << ''
          end

          if output_schema
            qualifier = tools && !tools.empty? ? 'When you are NOT using a tool, respond' : 'Respond'
            parts << "[Output Format]: #{qualifier} with ONLY valid JSON (no markdown fences) matching this schema:"
            parts << JSON.generate(output_schema)
            parts << ''
          end

          messages.each do |msg|
            role = msg['role'] || msg[:role]
            content = msg['content'] || msg[:content]
            case role
            when 'user'
              parts << content.to_s
            when 'assistant'
              parts << "[Previous assistant response]: #{content}"
            when 'tool'
              tool_id = msg['tool_use_id'] || msg[:tool_use_id] || 'unknown'
              parts << "[Tool result for #{tool_id}]: #{content}"
            end
          end

          prompt = parts.join("\n")
          prompt.lstrip.start_with?('/') ? "[Request]:\n#{prompt}" : prompt
        end

        # One JSON object per line; lines that are not JSON objects are skipped
        # so a stray warning on stdout cannot hide the result event.
        def parse_events(stdout)
          strip_ansi(stdout).each_line.filter_map do |line|
            line = line.strip
            next if line.empty?

            obj = JSON.parse(line)
            obj.is_a?(Hash) ? obj : nil
          rescue JSON::ParserError
            nil
          end
        end

        # Everything the CLI said about the failure, each part naming the
        # condition it actually observed: the missing or failed result, an
        # empty reply, a non-zero exit beside a good result, and stderr (where
        # agy explains an auto-denied tool). Joined so no part hides another.
        def failure_detail(result, stderr, status)
          parts = []
          if result.nil?
            parts << 'no result event'
          else
            st = result['status'].to_s.strip
            parts << "result status #{st.empty? ? '(none)' : st}" unless st == 'SUCCESS'
            parts << result['error'].to_s.strip
            parts << 'empty response' if result['response'].to_s.strip.empty?
            if st == 'SUCCESS' && !result['response'].to_s.strip.empty? && !status&.success?
              parts << (status&.exitstatus.nil? ? 'result SUCCESS but the process ended without an exit status' : 'result SUCCESS but the process exited non-zero')
            end
          end
          err = strip_ansi(stderr).strip
          parts << (err.empty? ? 'stderr empty' : err)
          parts.reject(&:empty?).join(' | ')
        end

        def build_response(result, tools, model)
          text = result['response'].to_s
          # Only a caller that offered tools asked for tool calls. Without
          # tools, a JSON tool_use sample inside a review is part of the review.
          tool_use = tools && !tools.empty? ? extract_tool_use(text) : nil
          usage = result['usage'].is_a?(Hash) ? result['usage'] : {}

          {
            'content' => tool_use ? nil : text,
            'tool_use' => tool_use,
            'stop_reason' => tool_use ? 'tool_use' : 'end_turn',
            'model' => model || 'agy-cli-default',
            'input_tokens' => usage['input_tokens'],
            'output_tokens' => usage['output_tokens'],
            # Where agy keeps its own copy of this turn (see header).
            'conversation_id' => result['conversation_id']
          }
        end

        def extract_tool_use(text)
          json_match = text.match(/```json\s*\n?(.*?)\n?\s*```/m) ||
                       text.match(/\{[^{}]*"tool_use"\s*:[^{}]*\}/m)
          return nil unless json_match

          parsed = JSON.parse(json_match[1] || json_match[0])
          return nil unless parsed.is_a?(Hash) && parsed['tool_use'].is_a?(Array)

          parsed['tool_use'].map do |tu|
            {
              'id' => "ag_#{SecureRandom.hex(4)}",
              'name' => tu['name'],
              'input' => tu['input'] || {}
            }
          end
        rescue JSON::ParserError
          nil
        end

        def strip_ansi(s)
          return '' if s.nil?

          s.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
        end
      end
    end
  end
end
