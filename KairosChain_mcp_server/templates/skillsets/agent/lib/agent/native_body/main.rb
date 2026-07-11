# frozen_string_literal: true

# Native body entrypoint — NB-1/NB-3/§5 (native body design v0.6 FROZEN).
#
# Launched by the driver as a separate OS process into the Slice 1
# confinement (scratch write-allow, stores read-deny) under the native-body
# egress-scoped profile, with RubyGems disabled and the load path restricted
# to the pinned staged region (NB-2: a require resolving outside it raises
# LoadError, which this file reports as a closure-escape guard failure).
#
# Intake is value-only on stdin: one JSON payload (task, context values,
# tool-surface grant, ceilings, curated model configuration, credential).
# The body holds no channel back into the instance — its world is the work
# area it was given, the read-only staged code it runs, and the
# provider-scoped egress the mediator provides.
#
# Return is manifest-shaped on stdout: status + what it did. Success is
# decided by the driver's mechanical verdict from boundary position
# regardless (AGT-3) — nothing hangs on this report's honesty.
#
# Exit codes (driver contract):
#   0 completed | 3 halted-by-ceiling | 4 failed | 5 guard failure (halt)

require 'json'
require_relative 'tool_layer'
require_relative 'model_client'
require_relative 'spend_meter'

module KairosMcp
  module SkillSets
    module Agent
      module NativeBody
        class Main
          EXIT_COMPLETED = 0
          EXIT_CEILING = 3
          EXIT_FAILED = 4
          EXIT_GUARD = 5

          def self.run(stdin: $stdin, stdout: $stdout)
            payload = JSON.parse(stdin.read)
            new(payload).run(stdout)
          rescue JSON::ParserError => e
            emit_halt(stdout, "intake payload unreadable: #{e.message}")
          rescue ModelClient::TransportRefusal, ToolLayer::SurfaceRefusal, LoadError, ArgumentError => e
            # Intake-time guard failures (excluded transport, ungoverned
            # grant, closure escape, non-positive ceiling) halt before any
            # loop work — fail-closed, with the reason on the wire.
            emit_halt(stdout, "#{e.class}: #{e.message}")
          end

          def self.emit_halt(stdout, reason)
            stdout.puts JSON.generate({ 'status' => 'guard_failure', 'halt_reason' => reason,
                                        'substrate' => 'native_body' })
            EXIT_GUARD
          end

          def initialize(payload)
            @task = payload['task'].to_s
            @context = payload['context'].to_s
            ceilings = payload['ceilings'] || {}
            @meter = SpendMeter.new(
              max_spend_tokens: ceilings['max_spend_tokens'] || 100_000,
              max_steps: ceilings['max_steps'] || 20
            )
            # In-body mirror of the boundary-side wall-clock cap (the
            # boundary's timeout remains the load-bearing outer backstop).
            @deadline = ceilings['max_wall_seconds'] &&
                        Process.clock_gettime(Process::CLOCK_MONOTONIC) + Integer(ceilings['max_wall_seconds'])
            @tool_layer = ToolLayer.new(
              work_dir: payload['work_dir'] || Dir.pwd,
              granted: payload['tools'] || %w[Read Edit Write Glob Grep]
            )
            @model = ModelClient.new(payload['model_config'] || {}, payload['credential'], @meter)
            @llm_calls = 0
            @tool_calls = 0
          end

          def run(stdout)
            status, summary, reason = loop_until_done
            stdout.puts JSON.generate(report(status, summary, reason))
            case status
            when 'completed' then EXIT_COMPLETED
            when 'halted_ceiling' then EXIT_CEILING
            else EXIT_FAILED
            end
          rescue SpendMeter::CeilingHalt => e
            stdout.puts JSON.generate(report('halted_ceiling', 'ceiling halt', "#{e.kind}: #{e.message}"))
            EXIT_CEILING
          rescue ModelClient::TransportRefusal, ToolLayer::SurfaceRefusal, LoadError => e
            # LoadError inside the closure = a load resolved outside the
            # pinned region (or an excluded adapter was named): NB-2/NB-4
            # guard failure, halted — never degraded into a plain failure.
            stdout.puts JSON.generate(report('guard_failure', 'guard halt', "#{e.class}: #{e.message}"))
            EXIT_GUARD
          rescue StandardError => e
            stdout.puts JSON.generate(report('failed', 'error', "#{e.class}: #{e.message}"))
            EXIT_FAILED
          end

          private

          def loop_until_done
            user_text = @context.empty? ? @task : "#{@context}\n\n#{@task}"
            messages = [{ 'role' => 'user', 'content' => user_text }]
            system_prompt =
              'You are a confined task executor. Your world is the given work area; every file path is ' \
              'work-area-relative. Complete the task using only the provided tools, then reply with a ' \
              'short completion summary (no tool call).'

            loop do
              check_deadline!
              @meter.step!
              @llm_calls += 1
              response = @model.call(messages: messages, system: system_prompt,
                                     tools: @tool_layer.schemas)

              tool_use = response['tool_use']
              if tool_use.nil? || tool_use.empty?
                return ['completed', response['content'].to_s[0, 500], nil]
              end

              messages << { 'role' => 'assistant', 'content' => response['content'],
                            'tool_calls' => tool_use }
              tool_use.each do |tu|
                messages << { 'role' => 'tool', 'tool_use_id' => tu['id'],
                              'content' => perform_tool(tu) }
              end
            end
          end

          # A model proposal never widens anything (NB-4): an out-of-surface
          # or out-of-area request is refused by the tool layer and the
          # refusal is reported back to the model as the tool result.
          def perform_tool(tool_use)
            @tool_calls += 1
            result = @tool_layer.execute(tool_use['name'], tool_use['input'])
            JSON.generate(result)
          rescue ToolLayer::SurfaceRefusal, ToolLayer::PathRefusal => e
            JSON.generate({ 'error' => e.message, 'refused' => true })
          end

          def check_deadline!
            return unless @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

            raise SpendMeter::CeilingHalt.new(:wall_clock, 'in-body wall-clock mirror reached')
          end

          def report(status, summary, halt_reason)
            {
              'status' => status,
              'summary' => summary.to_s,
              'halt_reason' => halt_reason,
              'llm_calls' => @llm_calls,
              'tool_calls' => @tool_calls,
              'refused_tool_requests' => @tool_layer ? @tool_layer.refused_requests : [],
              'spend' => @meter ? @meter.report : nil,
              'substrate' => 'native_body'
            }
          end
        end
      end
    end
  end
end

exit(KairosMcp::SkillSets::Agent::NativeBody::Main.run) if $PROGRAM_NAME == __FILE__
