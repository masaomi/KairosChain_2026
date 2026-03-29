# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStep < KairosMcp::Tools::BaseTool
          BASE_ORIENT_TOOLS = %w[knowledge_list knowledge_get chain_history
                                skills_list resource_list resource_read context_save
                                mcp_list_remote].freeze

          def name
            'agent_step'
          end

          def description
            'Advance the agent session by one step. Actions depend on current state: ' \
              '"approve" at [observed] runs Orient+Decide, at [proposed] runs Act+Reflect, ' \
              'at [checkpoint] starts next cycle. "revise" re-runs Decide with feedback. ' \
              '"skip" skips Act. "stop" terminates.'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent step ooda advance]
          end

          def related_tools
            %w[agent_start agent_status agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: {
                  type: 'string',
                  description: 'Agent session ID'
                },
                action: {
                  type: 'string',
                  description: 'Action: "approve", "revise", "skip", or "stop"',
                  enum: %w[approve revise skip stop]
                },
                feedback: {
                  type: 'string',
                  description: 'Feedback for "revise" action (optional)'
                }
              },
              required: %w[session_id action]
            }
          end

          def call(arguments)
            session_id = arguments['session_id']
            action = arguments['action']
            feedback = arguments['feedback']

            session = Session.load(session_id)
            return error_result("Session not found: #{session_id}") unless session

            case action
            when 'stop'
              handle_stop(session)
            when 'approve'
              handle_approve(session)
            when 'revise'
              handle_revise(session, feedback)
            when 'skip'
              handle_skip(session)
            else
              error_result("Unknown action: #{action}")
            end
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error', 'error' => "#{e.class}: #{e.message}"
            }))
          end

          private

          def handle_stop(session)
            session.update_state('terminated')
            session.save
            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'terminated', 'reason' => 'user_stop'
            }))
          end

          def handle_approve(session)
            case session.state
            when 'observed'
              run_orient_decide(session)
            when 'proposed'
              run_act_reflect(session)
            when 'checkpoint'
              run_next_cycle(session)
            else
              error_result("Cannot approve in state: #{session.state}")
            end
          end

          def handle_revise(session, feedback)
            return error_result("revise only valid at [proposed]") unless session.state == 'proposed'
            run_decide_with_feedback(session, feedback || 'Please revise the plan.')
          end

          def handle_skip(session)
            return error_result("skip only valid at [proposed]") unless session.state == 'proposed'
            # Skip ACT, go directly to REFLECT with "skipped"
            session.update_state('reflecting')
            act_result = { 'skipped' => true, 'summary' => 'skipped' }
            reflect_result = run_reflect(session, act_result)

            # Chain recording + progress (same as run_act_reflect)
            decision_payload = session.load_decision || {}
            record_agent_cycle(session, decision_payload, act_result, reflect_result)
            session.save_progress(
              reflect_result, session.cycle_number + 1,
              'skipped', decision_payload['summary'] || ''
            )

            session.increment_cycle
            session.update_state('checkpoint')
            session.save
            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'checkpoint', 'reflect' => reflect_result
            }))
          end

          # ---- ORIENT + DECIDE ----

          def run_orient_decide(session)
            loop_inst = CognitiveLoop.new(self, session)

            # Load observation (Fix #6: pass to ORIENT)
            observation = session.load_observation
            observation_text = observation ? JSON.generate(observation) : '(no observation data)'

            # ORIENT
            session.update_state('orienting')
            orient_prompt = build_orient_prompt(session, observation_text)
            messages = [{ 'role' => 'user', 'content' => orient_prompt }]

            orient_result = loop_inst.run_phase('orient', orient_system_prompt, messages, orient_tools(session))
            return error_with_state(session, 'observed', orient_result) if orient_result['error']

            # DECIDE (single-stage; see design v0.4 sec 3.3 for future extension)
            session.update_state('deciding')
            decide_messages = [{ 'role' => 'user', 'content' => build_decide_prompt(session, orient_result) }]

            decide_result = loop_inst.run_decide(decide_system_prompt, decide_messages)
            return error_with_state(session, 'observed', decide_result) if decide_result['error']

            # M4: Loop detection (after DECIDE, before presenting to user)
            decision_payload = decide_result['decision_payload']
            loop_term = check_loop_detection(session, orient_result, decision_payload)
            if loop_term
              return text_content(JSON.generate({
                'status' => 'terminated', 'reason' => 'loop_detected',
                'session_id' => session.session_id
              }))
            end

            # Fix #1: persist decision for proposed→ACT transition
            session.save_decision(decision_payload)
            session.update_state('proposed')
            session.save

            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'proposed',
              'orient' => summarize_orient(orient_result),
              'decision_payload' => decide_result['decision_payload']
            }))
          end

          # ---- ACT + REFLECT ----

          def run_act_reflect(session)
            decision_payload = load_last_decision(session)
            return error_result("No decision payload found") unless decision_payload

            # Check risk before ACT
            proposal = MandateAdapter.to_mandate_proposal(decision_payload)
            mandate = ::Autonomos::Mandate.load(session.mandate_id)
            if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
              ::Autonomos::Mandate.update_status(session.mandate_id, 'paused_risk_exceeded')
              session.update_state('terminated')
              session.save
              return text_content(JSON.generate({
                'status' => 'paused', 'reason' => 'risk_exceeded',
                'session_id' => session.session_id, 'state' => 'terminated'
              }))
            end

            # ACT via autoexec with derived context
            session.update_state('acting')
            act_result = run_act(session, decision_payload)

            # REFLECT
            session.update_state('reflecting')
            reflect_result = run_reflect(session, act_result)

            # Record cycle
            record_agent_cycle(session, decision_payload, act_result, reflect_result)

            # M5: Save cumulative progress after REFLECT (1-based cycle numbering)
            act_summary = act_result['summary'] || act_result['error'] || 'completed'
            decision_summary = decision_payload['summary'] || ''
            session.save_progress(reflect_result, session.cycle_number + 1, act_summary, decision_summary)

            session.increment_cycle
            session.update_state('checkpoint')
            session.save

            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'checkpoint',
              'act_summary' => act_result['summary'] || 'completed',
              'reflect' => reflect_result
            }))
          end

          def run_act(session, decision_payload)
            act_ctx = session.invocation_context.derive(
              blacklist_remove: %w[autoexec_plan autoexec_run]
            )

            # Create plan
            plan_result = invoke_tool('autoexec_plan', {
              'task_json' => JSON.generate(decision_payload['task_json'])
            }, context: act_ctx)

            plan_parsed = JSON.parse(plan_result.map { |b| b[:text] || b['text'] }.compact.join)
            return { 'error' => plan_parsed['error'] } if plan_parsed['status'] == 'error'

            task_id = plan_parsed['task_id']
            plan_hash = plan_parsed['plan_hash']

            # Execute
            run_result = invoke_tool('autoexec_run', {
              'task_id' => task_id,
              'mode' => 'internal_execute',
              'approved_hash' => plan_hash,
              'invocation_context_json' => act_ctx.to_json
            }, context: act_ctx)

            run_parsed = JSON.parse(run_result.map { |b| b[:text] || b['text'] }.compact.join)
            {
              'task_id' => task_id,
              'plan_hash' => plan_hash,
              'execution' => run_parsed,
              'summary' => run_parsed['status'] == 'ok' ? 'completed' : 'failed'
            }
          rescue StandardError => e
            { 'error' => "ACT failed: #{e.message}" }
          end

          def run_reflect(session, act_result)
            loop = CognitiveLoop.new(self, session)
            messages = [{ 'role' => 'user', 'content' => build_reflect_prompt(session, act_result) }]
            result = loop.run_phase('reflect', reflect_system_prompt, messages, [])

            if result['content']
              parse_reflect_json(result['content'])
            else
              { 'confidence' => 0.0, 'error' => result['error'] || 'no content' }
            end
          end

          # Parse REFLECT response, handling code fences and nested JSON
          def parse_reflect_json(content)
            # Try direct parse first
            JSON.parse(content)
          rescue JSON::ParserError
            # Try extracting from code fences
            if content =~ /```(?:json)?\s*\n?(.*?)\n?\s*```/m
              begin
                return JSON.parse($1)
              rescue JSON::ParserError
                # fall through
              end
            end
            # Last resort: confidence 0.0 with raw content preserved
            { 'confidence' => 0.0, 'raw' => content }
          end

          # ---- NEXT CYCLE ----

          # Fix #3: approve at [checkpoint] means the user has approved continuation.
          # checkpoint_due? is checked BEFORE reaching [checkpoint] (in run_act_reflect).
          # When the user approves at [checkpoint], we always proceed to the next cycle.
          def run_next_cycle(session)
            mandate = ::Autonomos::Mandate.load(session.mandate_id)

            # Check termination conditions
            term_reason = ::Autonomos::Mandate.check_termination(mandate)
            if term_reason
              ::Autonomos::Mandate.update_status(session.mandate_id, 'terminated')
              session.update_state('terminated')
              session.save
              return text_content(JSON.generate({
                'status' => 'terminated', 'reason' => term_reason,
                'session_id' => session.session_id
              }))
            end

            # Re-observe and continue to next cycle
            observation = run_observe_for_next_cycle(session)
            session.save_observation(observation)
            session.update_state('observed')
            session.save

            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'observed', 'cycle' => session.cycle_number + 1,
              'observation' => observation
            }))
          end

          def run_observe_for_next_cycle(session)
            # Progress history is injected via build_orient_prompt (not duplicated here)
            { 'goal_name' => session.goal_name, 'timestamp' => Time.now.iso8601,
              'cycle' => session.cycle_number + 1 }
          end

          # ---- DECIDE with feedback ----

          def run_decide_with_feedback(session, feedback)
            loop_inst = CognitiveLoop.new(self, session)

            # Include prior decision for context continuity (Fix #5)
            prior_decision = session.load_decision
            prior_json = prior_decision ? JSON.generate(prior_decision) : '(none)'

            # Include tool catalog so revise path has same tool awareness as initial DECIDE
            catalog = build_tool_catalog(session)

            messages = [
              { 'role' => 'user', 'content' =>
                "## Available Tools\n#{catalog}\n\n" \
                "Previous plan:\n#{prior_json}\n\n" \
                "This plan was rejected. Feedback: #{feedback}\n\n" \
                "Please revise the plan and output a new decision_payload as JSON. " \
                "Use ONLY tools listed above." }
            ]
            decide_result = loop_inst.run_decide(decide_system_prompt, messages)
            return error_with_state(session, 'proposed', decide_result) if decide_result['error']

            session.save_decision(decide_result['decision_payload'])
            session.save
            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'proposed', 'decision_payload' => decide_result['decision_payload']
            }))
          end

          # ---- Loop detection (M4) ----

          # M4: Loop detection using decision_payload['summary'] as canonical gap
          # description (matches autonomos_loop's approach).
          # Single-session-per-mandate assumed (no concurrent mandate writes).
          def check_loop_detection(session, _orient_result, decision_payload)
            mandate = ::Autonomos::Mandate.load(session.mandate_id)
            return nil unless mandate

            # Use decision summary as gap description (same source as proposal)
            gap_desc = decision_payload['summary'] || 'unknown'
            recent_gaps = Array(mandate[:recent_gap_descriptions])
            recent_gaps_updated = (recent_gaps + [gap_desc]).last(3)

            proposal = MandateAdapter.to_mandate_proposal(decision_payload)

            if ::Autonomos::Mandate.loop_detected?(proposal, recent_gaps)
              # Single save: update both status and gap history atomically
              mandate[:status] = 'terminated'
              mandate[:recent_gap_descriptions] = recent_gaps_updated
              ::Autonomos::Mandate.save(session.mandate_id, mandate)
              session.update_state('terminated')
              session.save
              return true
            end

            # Update gap history even if no loop detected
            mandate[:recent_gap_descriptions] = recent_gaps_updated
            ::Autonomos::Mandate.save(session.mandate_id, mandate)
            nil
          rescue StandardError => e
            warn "[agent] Loop detection failed: #{e.message}"
            nil
          end

          # ---- Chain recording ----

          def record_agent_cycle(session, decision_payload, act_result, reflect_result)
            evaluation = MandateAdapter.reflect_to_evaluation(reflect_result)
            ::Autonomos::Mandate.record_cycle(
              session.mandate_id,
              cycle_id: "#{session.session_id}_cycle#{session.cycle_number}",
              evaluation: evaluation
            )
          rescue StandardError => e
            # Non-fatal: log but don't block the cycle
            warn "[agent] Failed to record cycle: #{e.message}"
          end

          # ---- Prompts ----

          def orient_system_prompt
            "You are an analytical assistant in the ORIENT phase of an OODA loop. " \
            "Analyze the observation, identify gaps, set priorities, and recommend an action. " \
            "You have access to knowledge and context tools for research. " \
            "Return your analysis as structured text."
          end

          def decide_system_prompt
            "You are a planning assistant in the DECIDE phase of an OODA loop. " \
            "Based on the orientation analysis, create a concrete execution plan. " \
            "Output ONLY a JSON object with keys 'summary' (string) and 'task_json' " \
            "(object with task_id, meta, steps array). Each step needs: step_id, action, " \
            "tool_name, tool_arguments, risk (low/medium/high), depends_on, requires_human_cognition."
          end

          def reflect_system_prompt
            "You are an evaluator in the REFLECT phase of an OODA loop. " \
            "Assess the execution results against the original goal. " \
            "Output a JSON object: {confidence: 0.0-1.0, achieved: [...], " \
            "remaining: [...], learnings: [...], open_questions: [...]}."
          end

          def build_orient_prompt(session, observation_text = nil)
            parts = ["Goal: #{session.goal_name}", "Cycle: #{session.cycle_number + 1}"]
            # M5: Prepend progress summary for cross-cycle continuity
            progress = session.load_progress
            parts << "Progress from previous cycles:\n#{format_progress_for_prompt(progress)}" unless progress.empty?
            parts << "Observation:\n#{observation_text}" if observation_text
            parts << "Analyze the current state and identify what needs to be done."
            parts.join("\n\n")
          end

          def format_progress_for_prompt(progress_entries)
            return "No previous cycles." if progress_entries.empty?

            progress_entries.map { |e|
              "Cycle #{e['cycle']} (confidence: #{e['confidence']}): " \
              "Achieved: #{(e['achieved'] || []).join(', ')}. " \
              "Remaining: #{(e['remaining'] || []).join(', ')}. " \
              "Learnings: #{(e['learnings'] || []).join(', ')}."
            }.join("\n")
          end

          def build_decide_prompt(session, orient_result)
            analysis = orient_result['content'] || orient_result.to_json
            catalog = build_tool_catalog(session)

            "Based on this analysis:\n#{analysis}\n\n" \
            "## Available Tools\n#{catalog}\n\n" \
            "Create a task execution plan as JSON (decision_payload format). " \
            "Use ONLY tools listed above."
          end

          def build_reflect_prompt(session, act_result)
            "Goal: #{session.goal_name}\n" \
            "Execution result:\n#{JSON.generate(act_result)}\n\n" \
            "Evaluate: what was achieved, what remains, confidence level (0.0-1.0)."
          end

          # ---- Capability Discovery ----

          # Config-driven ORIENT tools: base + optional extras from agent.yml
          def orient_tools(session)
            extra = session&.config&.dig('orient_tools_extra') || []
            (BASE_ORIENT_TOOLS + extra).uniq
          end

          # Build a filtered tool catalog for DECIDE prompt.
          # Uses session's InvocationContext.allowed? for blacklist/whitelist
          # consistency with the ACT phase execution policy.
          # Includes parameter schemas so DECIDE LLM generates correct tool_arguments.
          def build_tool_catalog(session)
            return "(no registry available)" unless @registry

            ctx = session&.invocation_context
            tools = @registry.list_tools
            tools = tools.reject { |t| ctx && !ctx.allowed?(t[:name]) } if ctx

            tools.map { |t|
              format_tool_entry(t)
            }.join("\n")
          end

          # Format a single tool entry with parameter details for DECIDE.
          def format_tool_entry(tool)
            schema = tool[:inputSchema] || {}
            required_names = extract_required_params(schema)
            properties = schema[:properties] || schema['properties'] || {}

            lines = ["- **#{tool[:name]}**: #{tool[:description]}"]

            unless properties.empty?
              req_parts = []
              opt_parts = []
              properties.each do |param_name, param_def|
                pname = param_name.to_s
                ptype = param_def['type'] || param_def[:type] || '?'
                pdesc = param_def['description'] || param_def[:description]
                short_desc = pdesc ? pdesc.to_s[0..60] : nil
                entry = short_desc ? "#{pname} (#{ptype}: #{short_desc})" : "#{pname} (#{ptype})"
                if required_names.include?(pname)
                  req_parts << entry
                else
                  opt_parts << entry
                end
              end
              lines << "  Required: #{req_parts.join(', ')}" unless req_parts.empty?
              lines << "  Optional: #{opt_parts.join(', ')}" unless opt_parts.empty?
            end

            lines.join("\n")
          end

          # Extract required parameter names from an inputSchema hash.
          def extract_required_params(schema)
            return [] unless schema.is_a?(Hash)
            required = schema[:required] || schema['required'] || []
            required.map(&:to_s)
          end

          # ---- Helpers ----

          def load_last_decision(session)
            session.load_decision
          end

          def summarize_orient(result)
            result['content'] ? result['content'][0..500] : result.to_json[0..500]
          end

          def error_result(message)
            text_content(JSON.generate({ 'status' => 'error', 'error' => message }))
          end

          def error_with_state(session, revert_state, result)
            session.update_state(revert_state)
            session.save
            text_content(JSON.generate({
              'status' => 'error', 'session_id' => session.session_id,
              'state' => revert_state, 'error' => result['error']
            }))
          end
        end
      end
    end
  end
end
