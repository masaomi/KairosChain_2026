# frozen_string_literal: true

require 'json'
require 'digest'
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
                },
                apply_permission_hook: {
                  type: 'boolean',
                  description: 'Apply the suggested PreToolUse hook to .claude/settings.json (requires prior permission_advisory)'
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

            if arguments['apply_permission_hook']
              result = apply_permission_hook
              return text_content(JSON.generate(result)) unless result['status'] == 'ok'
            end

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
            log_agent(:info, 'session_stopped', session, reason: 'user_stop')
            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'terminated', 'reason' => 'user_stop'
            }))
          end

          def handle_approve(session)
            case session.state
            when 'observed', 'autonomous_cycling'
              session.autonomous? ? run_autonomous_loop(session) : run_orient_decide(session)
            when 'proposed'
              run_act_reflect(session)
            when 'checkpoint'
              session.autonomous? ? run_autonomous_loop(session) : run_next_cycle(session)
            when 'paused_risk'
              handle_resume_from_risk(session)
            when 'paused_error'
              handle_resume_from_error(session)
            else
              error_result("Cannot approve in state: #{session.state}")
            end
          end

          def handle_revise(session, feedback)
            return error_result("revise only valid at [proposed]") unless session.state == 'proposed'
            run_decide_with_feedback(session, feedback || 'Please revise the plan.')
          end

          def handle_skip(session)
            return error_result("skip not valid in state: #{session.state}") unless %w[proposed paused_error paused_risk].include?(session.state)
            return handle_resume_from_error(session) if session.state == 'paused_error'
            # Skip ACT, go directly to REFLECT with skip reason
            skip_reason = session.state == 'paused_risk' ? 'skipped_risk' : 'skipped'
            session.update_state('reflecting')
            act_result = { 'skipped' => true, 'summary' => skip_reason, 'reason' => skip_reason }
            reflect_loop = CognitiveLoop.new(self, session)
            messages = [{ 'role' => 'user', 'content' => build_reflect_prompt(session, act_result) }]
            reflect_raw = reflect_loop.run_phase('reflect', reflect_system_prompt, messages, [])
            reflect_result = reflect_raw['content'] ? parse_reflect_json(reflect_raw['content']) : { 'confidence' => 0.0 }

            # Chain recording + progress (same as run_act_reflect)
            decision_payload = session.load_decision || {}
            record_agent_cycle(session, decision_payload, act_result, reflect_result)
            session.save_progress(
              reflect_result, session.cycle_number + 1,
              act_result['summary'] || 'skipped', decision_payload['summary'] || ''
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

          # Internal version: returns Hash, never calls text_content.
          # Used by both manual wrapper and autonomous loop.
          # mandate_override: pass in-memory mandate from autonomous loop to avoid stale reads.
          def run_orient_decide_internal(session, mandate_override: nil)
            log_agent(:info, 'phase_orient_decide_start', session)
            loop_inst = CognitiveLoop.new(self, session)

            observation = session.load_observation
            observation_text = observation ? JSON.generate(observation) : '(no observation data)'

            session.update_state('orienting')
            orient_prompt = build_orient_prompt(session, observation_text)
            messages = [{ 'role' => 'user', 'content' => orient_prompt }]

            orient_ctx = phase_context(session, 'orient')
            orient_result = loop_inst.run_phase('orient', orient_system_prompt, messages, orient_tools(session),
                                                invocation_context: orient_ctx)
            if orient_result['error']
              session.update_state('observed')
              session.save
              return { error: orient_result['error'], llm_calls: loop_inst.total_calls }
            end

            session.update_state('deciding')
            decide_messages = [{ 'role' => 'user', 'content' => build_decide_prompt(session, orient_result) }]

            decide_result = loop_inst.run_decide(decide_system_prompt, decide_messages)
            if decide_result['error']
              session.update_state('observed')
              session.save
              return { error: decide_result['error'], llm_calls: loop_inst.total_calls }
            end

            decision_payload = decide_result['decision_payload']
            loop_term = check_loop_detection(session, orient_result, decision_payload,
                                             mandate_override: mandate_override)
            if loop_term
              return { loop_detected: true, llm_calls: loop_inst.total_calls }
            end

            session.save_decision(decision_payload)
            { orient: orient_result, decision_payload: decision_payload,
              loop_detected: false, error: nil, llm_calls: loop_inst.total_calls }
          end

          # Manual mode wrapper: pure format converter
          def run_orient_decide(session)
            result = run_orient_decide_internal(session)
            if result[:error]
              return error_with_state(session, 'observed', { 'error' => result[:error] })
            end
            if result[:loop_detected]
              return text_content(JSON.generate({
                'status' => 'terminated', 'reason' => 'loop_detected',
                'session_id' => session.session_id
              }))
            end

            session.update_state('proposed')
            session.save
            text_content(JSON.generate({
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'proposed',
              'orient' => summarize_orient(result[:orient]),
              'decision_payload' => result[:decision_payload]
            }))
          end

          # ---- ACT + REFLECT ----

          # Internal version: returns Hash, never calls text_content.
          # Increments cycle and saves session. Does NOT set final state.
          def run_act_reflect_internal(session)
            decision_payload = session.load_decision
            return { act_error: 'No decision payload found', llm_calls: 0 } unless decision_payload

            log_agent(:info, 'phase_act_reflect_start', session,
                      summary: decision_payload['summary'].to_s[0..80])

            session.update_state('acting')
            act_result = run_act(session, decision_payload)

            session.update_state('reflecting')
            reflect_loop = CognitiveLoop.new(self, session)
            messages = [{ 'role' => 'user', 'content' => build_reflect_prompt(session, act_result) }]
            reflect_raw = reflect_loop.run_phase('reflect', reflect_system_prompt, messages, [])
            reflect_result = if reflect_raw['content']
                               parse_reflect_json(reflect_raw['content'])
                             else
                               { 'confidence' => 0.0, 'error' => reflect_raw['error'] || 'no content' }
                             end

            record_agent_cycle(session, decision_payload, act_result, reflect_result)

            act_summary = act_result['summary'] || act_result['error'] || 'completed'
            decision_summary = decision_payload['summary'] || ''
            session.save_progress(reflect_result, session.cycle_number + 1, act_summary, decision_summary)

            session.increment_cycle
            session.save

            act_succeeded = !act_result['error'] && act_result['summary'] != 'failed'

            { act: act_result, reflect: reflect_result, cycle: session.cycle_number,
              act_error: act_result['error'], act_succeeded: act_succeeded,
              llm_calls: reflect_loop.total_calls }
          end

          # Manual mode wrapper: pure format converter
          def run_act_reflect(session)
            decision_payload = load_last_decision(session)
            return error_result("No decision payload found") unless decision_payload

            proposal = MandateAdapter.to_mandate_proposal(decision_payload)
            mandate = ::Autonomos::Mandate.load(session.mandate_id)
            if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
              ::Autonomos::Mandate.update_status(session.mandate_id, 'paused_risk_exceeded')
              session.update_state('paused_risk')
              session.save
              return text_content(JSON.generate({
                'status' => 'paused', 'reason' => 'risk_exceeded',
                'session_id' => session.session_id, 'state' => 'paused_risk'
              }))
            end

            result = run_act_reflect_internal(session)
            session.update_state('checkpoint')
            session.save
            response = {
              'status' => 'ok', 'session_id' => session.session_id,
              'state' => 'checkpoint',
              'act_summary' => result.dig(:act, 'summary') || 'completed',
              'reflect' => result[:reflect]
            }
            response['permission_advisory'] = session.permission_advisory if session.permission_advisory
            text_content(JSON.generate(response))
          end

          # ---- AUTONOMOUS LOOP ----

          def run_autonomous_loop(session)
            auto_cfg = session.config['autonomous'] || {}
            max_total_llm = auto_cfg['max_total_llm_calls'] || 60
            max_duration = auto_cfg['max_duration_seconds'] || 300
            min_exit_cycles = auto_cfg['min_cycles_before_exit'] || 2
            confidence_threshold = auto_cfg['confidence_exit_threshold'] || 0.9

            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            total_llm_calls = 0
            results = []

            ::Autonomos::Mandate.with_lock(session.mandate_id) do |mandate|
              while session.cycle_number < (mandate[:max_cycles] || 3)
                session.update_state('autonomous_cycling')
                session.save

                # Gate 1: Mandate termination
                term_reason = ::Autonomos::Mandate.check_termination(mandate)
                if term_reason
                  mandate[:status] = 'terminated'
                  ::Autonomos::Mandate.save(session.mandate_id, mandate)
                  session.update_state('terminated')
                  return finalize_autonomous(session, results, terminated: term_reason)
                end

                # Gate 2: Goal drift
                if goal_drifted?(session, mandate)
                  mandate[:status] = 'paused_goal_drift'
                  ::Autonomos::Mandate.save(session.mandate_id, mandate)
                  session.update_state('checkpoint')
                  session.save
                  return finalize_autonomous(session, results, checkpoint: true,
                                             warning: 'goal_content_changed')
                end

                # Gate 3: Wall-clock timeout
                elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
                if elapsed > max_duration
                  session.update_state('checkpoint')
                  session.save
                  return finalize_autonomous(session, results, checkpoint: true,
                                             paused: 'timeout')
                end

                # Gate 4: Aggregate LLM budget
                if total_llm_calls >= max_total_llm
                  session.update_state('checkpoint')
                  session.save
                  return finalize_autonomous(session, results, checkpoint: true,
                                             paused: 'llm_budget_exceeded')
                end

                # OBSERVE (cycle 2+; cycle 1 already observed by agent_start)
                if session.cycle_number > 0
                  observation = run_observe_for_next_cycle(session)
                  session.save_observation(observation)
                end

                # ORIENT + DECIDE (pass in-memory mandate to avoid stale reads)
                od_result = run_orient_decide_internal(session, mandate_override: mandate)
                total_llm_calls += od_result[:llm_calls] || 0
                if od_result[:error]
                  session.update_state('paused_error')
                  session.save
                  return finalize_autonomous(session, results, error: od_result[:error])
                end
                if od_result[:loop_detected]
                  session.update_state('terminated')
                  return finalize_autonomous(session, results, terminated: 'loop_detected')
                end

                # Gate 5: Risk budget (after loop detection, existing order)
                decision_payload = session.load_decision
                proposal = MandateAdapter.to_mandate_proposal(decision_payload)
                if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
                  mandate[:status] = 'paused_risk_exceeded'
                  ::Autonomos::Mandate.save(session.mandate_id, mandate)
                  session.update_state('paused_risk')
                  session.save
                  return finalize_autonomous(session, results, paused: 'risk_exceeded')
                end

                # Gate 5.5: Complexity-driven review
                review_cfg = session.config['complexity_review'] || {}
                complexity = assess_decision_complexity(decision_payload)
                llm_hint = decision_payload['complexity_hint']
                complexity = merge_complexity(complexity, llm_hint) if llm_hint

                if review_enabled?(session)
                  # Gate 5.5a: L0 escalation (before persona review — save LLM cost)
                  if complexity[:signals].include?('l0_change') &&
                     review_cfg.fetch('l0_always_checkpoint', true)
                    # Phase 12 §3.4 + §3.11 (PR3): obtain ready-to-paste bundle from
                    # multi_llm_review_bundle SkillSet (single source of truth) and
                    # record on chain so the L0 Kairotic moment is constitutive
                    # (Proposition 5). Falls back to hand-rolled prompt if bundle
                    # tool unavailable (e.g., older runtime).
                    bundle_response = build_l0_bundle_for_checkpoint(session, decision_payload)
                    if bundle_response
                      record_l0_checkpoint_bundle(session, decision_payload, bundle_response)
                      multi_llm_prompt = format_bundle_for_human(bundle_response)
                    else
                      multi_llm_prompt = generate_multi_llm_review_prompt(session, decision_payload)
                    end
                    session.update_state('checkpoint')
                    session.save
                    return finalize_autonomous(session, results, checkpoint: true,
                                               warning: 'l0_requires_external_review',
                                               multi_llm_prompt: multi_llm_prompt)
                  end

                  # Gate 5.5c: Multi-LLM review (before persona review)
                  # Phase 12 §3.2 trust boundary + OR-floor:
                  #   review_needed = rule_fired || hint_needed
                  # rule_fired uses ONLY trusted (deterministic) complexity[:signals];
                  # hint_needed comes from validated review_hint and is ADDITIVE — cannot
                  # suppress the rule. Unknown trigger_mode fails-closed to rule_only.
                  multi_cfg = review_cfg['multi_llm_review']
                  if multi_cfg && (multi_cfg['enabled'] || review_force_enabled?) && multi_llm_review_needed?(multi_cfg, complexity, decision_payload)
                    mreview = run_multi_llm_review(session, decision_payload, complexity, multi_cfg)
                    total_llm_calls += mreview[:llm_calls] || 0
                    session.save_review_result(mreview.merge(kind: 'multi_llm'))

                    case mreview[:verdict]
                    when 'APPROVE'
                      # proceed to persona review or ACT
                    when 'REVISE'
                      # Phase 12 §3.3: prefer SkillSet-emitted feedback_text (sanitized,
                      # severity-prefixed, capped). Fall back to local construction for
                      # v0.3.x multi_llm_review responses that lack this field.
                      findings_text = mreview[:feedback_text]
                      if findings_text.nil? || findings_text.empty?
                        findings_list = Array(mreview[:aggregated_findings]).map { |f|
                          sev = (f[:severity] || f['severity']).to_s
                          # PR1 review fix: sanitize fallback path so reviewer-controlled
                          # text cannot inject framing into re-DECIDE prompt. Mirrors the
                          # multi_llm_review SkillSet sanitization contract (§3.7) but
                          # without cross-SkillSet require (layer hygiene).
                          issue = sanitize_review_fallback(f[:issue] || f['issue'])
                          "#{sev}: #{issue}"
                        }
                        findings_text = if findings_list.empty?
                                          "Multi-LLM review verdict was REVISE but no specific findings were extracted. " \
                                          "Review the plan for potential issues and revise."
                                        else
                                          "Multi-LLM review found issues:\n- #{findings_list.join("\n- ")}\n\nRevise plan."
                                        end
                      end
                      decide_result = run_decide_with_review_feedback_internal(
                        session, findings_text
                      )
                      total_llm_calls += decide_result[:llm_calls] || 0
                      if decide_result[:error]
                        session.update_state('paused_error')
                        session.save
                        return finalize_autonomous(session, results, error: decide_result[:error])
                      end
                      decision_payload = session.load_decision

                      # Re-check loop detection on revised plan (mirrors persona-review path)
                      tagged_summary = "#{decision_payload['summary']}_mreview_rev1"
                      loop_term = check_loop_detection(
                        session, nil,
                        decision_payload.merge('summary' => tagged_summary),
                        mandate_override: mandate
                      )
                      if loop_term
                        session.update_state('terminated')
                        return finalize_autonomous(session, results, terminated: 'loop_detected')
                      end

                      # Re-check risk budget on revised plan
                      proposal = MandateAdapter.to_mandate_proposal(decision_payload)
                      if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
                        mandate[:status] = 'paused_risk_exceeded'
                        ::Autonomos::Mandate.save(session.mandate_id, mandate)
                        session.update_state('paused_risk')
                        session.save
                        return finalize_autonomous(session, results, paused: 'risk_exceeded')
                      end

                      complexity = assess_decision_complexity(decision_payload)
                      llm_hint = decision_payload['complexity_hint']
                      complexity = merge_complexity(complexity, llm_hint) if llm_hint
                    when 'INSUFFICIENT'
                      # Phase 12 §3.8: fail-closed. INSUFFICIENT never auto-treated as APPROVE.
                      # Falls through to persona review (single-Agent reviewers) which is the
                      # in-process safety net. Persona REVISE/REJECT will block ACT.
                      warn "[agent_step] multi_llm_review INSUFFICIENT (#{mreview[:error] || 'quorum not met'}); falling through to persona review"
                    end
                  end

                  # Gate 5.5b: High-complexity persona review (inner retry loop)
                  if complexity[:level] == 'high'
                    review_retries = 0
                    max_retries = review_cfg['max_review_retries'] || 2

                    loop do
                      # Budget guard inside inner loop (P1-2 fix)
                      if total_llm_calls >= max_total_llm
                        session.update_state('checkpoint')
                        session.save
                        return finalize_autonomous(session, results, checkpoint: true,
                                                   paused: 'llm_budget_exceeded')
                      end

                      review = run_persona_review(session, decision_payload, complexity)
                      total_llm_calls += review[:llm_calls] || 0
                      session.save_review_result(review)

                      case review[:overall_verdict]
                      when 'APPROVE'
                        break
                      when 'REJECT'
                        session.update_state('checkpoint')
                        session.save
                        return finalize_autonomous(session, results, checkpoint: true,
                                                   warning: 'review_rejected', review: review)
                      else # REVISE or parse fallback
                        review_retries += 1
                        if review_retries > max_retries
                          session.update_state('checkpoint')
                          session.save
                          return finalize_autonomous(session, results, checkpoint: true,
                                                     warning: 'review_max_retries', review: review)
                        end

                        findings = Array(review[:key_findings]).join("\n- ")
                        feedback = "Persona review (attempt #{review_retries}/#{max_retries}) found issues:\n- #{findings}\n\nRevise the plan to address these concerns."
                        decide_result = run_decide_with_review_feedback_internal(session, feedback)
                        total_llm_calls += decide_result[:llm_calls] || 0

                        if decide_result[:error]
                          session.update_state('paused_error')
                          session.save
                          return finalize_autonomous(session, results, error: decide_result[:error])
                        end

                        decision_payload = session.load_decision

                        # Re-check loop detection with review-tagged summary
                        tagged_summary = "#{decision_payload['summary']}_review_rev#{review_retries}"
                        loop_term = check_loop_detection(
                          session, nil,
                          decision_payload.merge('summary' => tagged_summary),
                          mandate_override: mandate
                        )
                        if loop_term
                          session.update_state('terminated')
                          return finalize_autonomous(session, results, terminated: 'loop_detected')
                        end

                        # Re-check risk budget on revised plan
                        proposal = MandateAdapter.to_mandate_proposal(decision_payload)
                        if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
                          mandate[:status] = 'paused_risk_exceeded'
                          ::Autonomos::Mandate.save(session.mandate_id, mandate)
                          session.update_state('paused_risk')
                          session.save
                          return finalize_autonomous(session, results, paused: 'risk_exceeded')
                        end

                        # Re-assess complexity for revised plan
                        complexity = assess_decision_complexity(decision_payload)
                        llm_hint = decision_payload['complexity_hint']
                        complexity = merge_complexity(complexity, llm_hint) if llm_hint

                        break unless complexity[:level] == 'high'
                      end
                    end
                  end
                end

                # ACT + REFLECT
                ar_result = run_act_reflect_internal(session)
                total_llm_calls += ar_result[:llm_calls] || 0
                results << ar_result
                if ar_result[:act_error]
                  session.update_state('paused_error')
                  session.save
                  return finalize_autonomous(session, results, paused: 'act_failed',
                                             error: ar_result[:act_error])
                end

                # Gate 6: Post-ACT termination (record_cycle may have incremented errors)
                mandate = ::Autonomos::Mandate.reload(session.mandate_id)
                term_reason = ::Autonomos::Mandate.check_termination(mandate)
                if term_reason
                  session.update_state('terminated')
                  return finalize_autonomous(session, results, terminated: term_reason)
                end

                # Gate 6.5: Post-ACT advisory review for medium complexity
                if review_enabled?(session) &&
                   review_cfg.fetch('post_act_review', true) &&
                   complexity[:level] == 'medium' &&
                   ar_result[:act_succeeded]
                  post_review = run_lightweight_review(session, decision_payload, ar_result)
                  total_llm_calls += post_review[:llm_calls] || 0
                  if Array(post_review[:concerns]).any?
                    ar_result[:reflect]['review_concerns'] = post_review[:concerns]
                    session.save_progress_amendment(post_review[:concerns])
                  end
                end

                # Gate 7: Confidence-based early exit
                if session.cycle_number >= min_exit_cycles
                  confidence = clamp_confidence(ar_result.dig(:reflect, 'confidence'))
                  remaining = ar_result.dig(:reflect, 'remaining')
                  if confidence >= confidence_threshold &&
                     remaining.is_a?(Array) && remaining.empty? &&
                     ar_result[:act_succeeded]
                    session.update_state('terminated')
                    return finalize_autonomous(session, results, terminated: 'goal_achieved')
                  end
                end

                # Gate 8: Checkpoint pause
                checkpoint_every = mandate[:checkpoint_every] || 1
                if session.cycle_number > 0 &&
                   (session.cycle_number % checkpoint_every).zero?
                  mandate[:status] = 'paused_at_checkpoint'
                  ::Autonomos::Mandate.save(session.mandate_id, mandate)
                  session.update_state('checkpoint')
                  session.save
                  return finalize_autonomous(session, results, checkpoint: true)
                end
              end

              # All cycles exhausted (inside lock)
              session.update_state('terminated')
              session.save
              finalize_autonomous(session, results, terminated: 'max_cycles_reached')
            end
          rescue ::Autonomos::Mandate::LockError => e
            error_result("Session locked: #{e.message}")
          end

          def finalize_autonomous(session, cycle_results, terminated: nil, paused: nil,
                                  checkpoint: nil, error: nil, warning: nil,
                                  review: nil, multi_llm_prompt: nil)
            session.save

            reason = terminated || paused || warning || (error ? 'error' : 'checkpoint')
            log_agent(:info, 'autonomous_finalized', session,
                      terminated: terminated, paused: paused, error: error&.to_s&.[](0..100),
                      cycles_completed: session.cycle_number, reason: reason)

            status = if checkpoint then 'checkpoint'
                     elsif paused then 'paused'
                     elsif error then 'error'
                     else 'completed'
                     end

            response = {
              'status' => status,
              'session_id' => session.session_id,
              'state' => session.state,
              'cycles_completed' => session.cycle_number,
              'terminated_reason' => terminated,
              'paused_reason' => paused,
              'error' => error,
              'warning' => warning,
              'cycle_results' => cycle_results.map { |r|
                { 'cycle' => r[:cycle],
                  'act_summary' => r.dig(:act, 'summary') || 'completed',
                  'confidence' => clamp_confidence(r.dig(:reflect, 'confidence')),
                  'remaining_count' => Array(r.dig(:reflect, 'remaining')).size }
              }
            }
            response['permission_advisory'] = session.permission_advisory if session.permission_advisory
            response['review'] = review if review
            response['multi_llm_prompt'] = multi_llm_prompt if multi_llm_prompt
            text_content(JSON.generate(response))
          end

          def clamp_confidence(raw)
            val = raw.to_f
            [[val, 0.0].max, 1.0].min
          end

          def goal_drifted?(session, mandate)
            current_goal = load_goal_content(session.goal_name)
            current_hash = Digest::SHA256.hexdigest(current_goal || session.goal_name)[0..15]
            current_hash != mandate[:goal_hash].to_s
          rescue StandardError
            false
          end

          def load_goal_content(goal_name)
            # Use Ooda (same path as agent_start's run_observe)
            if defined?(::Autonomos::Ooda)
              helper = Class.new { include ::Autonomos::Ooda }.new
              goal = helper.load_goal(goal_name)
              return goal[:content] if goal && goal[:found]
            end
            # Fallback: direct L1 lookup (matches agent_start's load_goal_fallback)
            if defined?(KairosMcp::KnowledgeProvider)
              provider = KairosMcp::KnowledgeProvider.new(nil)
              result = provider.get(goal_name)
              return result[:content] if result && result[:content] && !result[:content].strip.empty?
            end
            nil
          rescue StandardError
            nil
          end

          # ---- RESUME HANDLERS ----

          def handle_resume_from_risk(session)
            mandate = ::Autonomos::Mandate.load(session.mandate_id)
            decision_payload = session.load_decision
            return error_result("No decision to re-check") unless decision_payload

            proposal = MandateAdapter.to_mandate_proposal(decision_payload)
            if ::Autonomos::Mandate.risk_exceeds_budget?(proposal, mandate[:risk_budget])
              return text_content(JSON.generate({
                'status' => 'still_paused', 'reason' => 'risk_still_exceeded',
                'session_id' => session.session_id,
                'hint' => 'Update mandate risk_budget or call stop'
              }))
            end

            # Resume: risk now within budget. Execute the paused proposal (ACT+REFLECT),
            # not a new ORIENT+DECIDE cycle. decision_payload is already saved.
            mandate[:status] = 'active'
            ::Autonomos::Mandate.save(session.mandate_id, mandate)

            if session.autonomous?
              # In autonomous mode, run ACT+REFLECT for the paused proposal,
              # then continue the autonomous loop from next cycle.
              ar_result = run_act_reflect_internal(session)
              if ar_result[:act_error]
                session.update_state('paused_error')
                session.save
                return finalize_autonomous(session, [ar_result], paused: 'act_failed',
                                           error: ar_result[:act_error])
              end
              # Continue to next cycle in autonomous loop
              session.update_state('observed')
              session.save
              run_autonomous_loop(session)
            else
              # Manual mode: resume at ACT+REFLECT for the existing proposal
              result = run_act_reflect_internal(session)
              session.update_state('checkpoint')
              session.save
              text_content(JSON.generate({
                'status' => 'ok', 'session_id' => session.session_id,
                'state' => 'checkpoint',
                'act_summary' => result.dig(:act, 'summary') || 'completed',
                'reflect' => result[:reflect]
              }))
            end
          end

          def handle_resume_from_error(session)
            # Record skipped cycle in mandate before advancing
            begin
              ::Autonomos::Mandate.record_cycle(
                session.mandate_id,
                cycle_id: "#{session.session_id}_cycle#{session.cycle_number}_skipped",
                evaluation: 'failed'
              )
            rescue StandardError => e
              warn "[agent] Failed to record skipped cycle: #{e.message}"
            end

            # Do NOT increment session.cycle_number here — the next
            # run_act_reflect_internal will do it after a successful cycle.
            # We only record the skip in mandate.
            observation = run_observe_for_next_cycle(session)
            session.save_observation(observation)
            session.update_state('observed')
            session.save

            if session.autonomous?
              run_autonomous_loop(session)
            else
              text_content(JSON.generate({
                'status' => 'ok', 'session_id' => session.session_id,
                'state' => 'observed', 'cycle' => session.cycle_number + 1,
                'observation' => observation
              }))
            end
          end

          def run_act(session, decision_payload)
            task_json = decision_payload['task_json']

            # Route: file operations → agent_execute; MCP tools → autoexec
            if requires_file_operations?(task_json)
              run_act_via_agent_execute(session, decision_payload)
            else
              run_act_via_autoexec(session, decision_payload)
            end
          rescue StandardError => e
            { 'error' => "ACT failed: #{e.message}" }
          end

          FILE_TOOL_NAMES = %w[Edit Write Read Bash file_edit file_write file_read].freeze

          def requires_file_operations?(task_json)
            steps = task_json&.dig('steps') || []
            steps.any? { |s| FILE_TOOL_NAMES.include?(s['tool_name']) }
          end

          def run_act_via_autoexec(session, decision_payload)
            act_ctx = session.invocation_context.derive(
              blacklist_remove: %w[autoexec_plan autoexec_run]
            )

            plan_result = invoke_tool('autoexec_plan', {
              'task_json' => JSON.generate(decision_payload['task_json'])
            }, context: act_ctx)

            plan_parsed = JSON.parse(plan_result.map { |b| b[:text] || b['text'] }.compact.join)
            return { 'error' => plan_parsed['error'] } if plan_parsed['status'] == 'error'

            task_id = plan_parsed['task_id']
            plan_hash = plan_parsed['plan_hash']

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
              'summary' => run_parsed['outcome']&.end_with?('_complete') ? 'completed' : 'failed'
            }
          end

          def run_act_via_agent_execute(session, decision_payload)
            # Must remove both the exact entry AND the wildcard 'agent_*' to unblock agent_execute.
            # Re-add other agent tools to keep them blocked.
            act_ctx = session.invocation_context.derive(
              blacklist_remove: %w[agent_execute agent_*],
              blacklist_add: %w[agent_start agent_step agent_status agent_stop]
            )

            context = build_agent_execute_context(session)
            task_summary = decision_payload['summary'] || ''
            task_detail = format_steps_as_instructions(decision_payload['task_json'])

            result = invoke_tool('agent_execute', {
              'task' => "#{task_summary}\n\n#{task_detail}",
              'context' => context
            }, context: act_ctx)

            parsed = JSON.parse(result.map { |b| b[:text] || b['text'] }.compact.join)

            # Propagate subprocess failures as 'error' for ACT failure gates
            error_msg = nil
            unless parsed['status'] == 'ok'
              error_msg = parsed['error'] || "agent_execute #{parsed['status']}: #{parsed['result'].to_s[0..200]}"
            end

            {
              'execution' => parsed,
              'files_modified' => parsed['files_modified'] || [],
              'tool_calls_count' => parsed['tool_calls_count'] || 0,
              'summary' => parsed['status'] == 'ok' ? 'completed' : 'failed',
              'error' => error_msg
            }
          end

          def build_agent_execute_context(session)
            parts = ["Goal: #{session.goal_name}",
                     "Cycle: #{session.cycle_number + 1}"]
            progress = session.load_progress
            unless progress.empty?
              parts << "Previous cycles:"
              progress.last(3).each { |p|
                parts << "  Cycle #{p['cycle']}: #{p['act_summary']} (confidence: #{p['confidence']})"
              }
            end
            parts.join("\n")
          end

          def format_steps_as_instructions(task_json)
            steps = task_json&.dig('steps') || []
            return '(no steps)' if steps.empty?

            steps.map.with_index(1) { |s, i|
              "Step #{i}: #{s['action'] || s['tool_name']} — #{s.dig('tool_arguments', 'description') || s['tool_arguments'].to_json}"
            }.join("\n")
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
          # Accepts optional in-memory mandate to avoid stale reads in autonomous mode.
          def check_loop_detection(session, _orient_result, decision_payload, mandate_override: nil)
            mandate = mandate_override || ::Autonomos::Mandate.load(session.mandate_id)
            return nil unless mandate

            gap_desc = decision_payload['summary'] || 'unknown'
            recent_gaps = Array(mandate[:recent_gap_descriptions])
            recent_gaps_updated = (recent_gaps + [gap_desc]).last(3)

            proposal = MandateAdapter.to_mandate_proposal(decision_payload)

            if ::Autonomos::Mandate.loop_detected?(proposal, recent_gaps)
              mandate[:status] = 'terminated'
              mandate[:recent_gap_descriptions] = recent_gaps_updated
              ::Autonomos::Mandate.save(session.mandate_id, mandate)
              session.update_state('terminated')
              session.save
              return true
            end

            # Update gap history in-memory and on disk
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

          # ---- Complexity Assessment ----

          L0_TOOLS = %w[skills_evolve skills_rollback instructions_update system_upgrade].freeze
          STATE_MUTATION_TOOLS = %w[state_commit chain_record knowledge_update formalization_record].freeze

          def assess_decision_complexity(decision_payload)
            signals = []
            steps = decision_payload.dig('task_json', 'steps') || []

            signals << 'high_risk' if steps.any? { |s| s['risk'] == 'high' }
            signals << 'many_steps' if steps.size > 5
            signals << 'design_scope' if decision_payload['summary']&.match?(
              ::Autonomos::Ooda::COMPLEX_KEYWORDS
            )
            signals << 'l0_change' if steps.any? { |s| L0_TOOLS.include?(s['tool_name']) }
            signals << 'core_files' if steps.any? { |s|
              path = s.dig('tool_arguments', 'file_path').to_s
              path.include?('/lib/') && path.include?('kairos')
            }
            file_paths = steps.filter_map { |s| s.dig('tool_arguments', 'file_path') }.uniq
            signals << 'multi_file' if file_paths.size > 3
            signals << 'state_mutation' if steps.any? { |s| STATE_MUTATION_TOOLS.include?(s['tool_name']) }

            level = case signals.size
                    when 0 then 'low'
                    when 1 then 'medium'
                    else 'high'
                    end

            # L0 override: always high
            level = 'high' if signals.include?('l0_change')

            { level: level, signals: signals }
          end

          def merge_complexity(structural, llm_hint)
            levels = { 'low' => 0, 'medium' => 1, 'high' => 2 }
            s_val = levels[structural[:level]] || 0
            l_val = levels[llm_hint&.dig('level') || llm_hint&.dig(:level)] || 0
            # LLM can raise by at most 1 level
            capped_llm = [l_val, s_val + 1].min
            final_val = [s_val, capped_llm].max
            final_level = levels.key(final_val) || 'low'
            # Phase 12 §3.2 / v0.4 P-2 trust boundary fix:
            # `signals` is the input to OR-floor's rule_fired computation. It MUST
            # be deterministic (produced by assess_decision_complexity from task_json
            # structure), never sourced from LLM output. Previously this method
            # union'd llm_hint signals into `:signals`, which let a compromised
            # DECIDE LLM influence the rule_fired left side of the OR.
            # LLM-emitted signals are now kept in a separate `:complexity_hint_signals`
            # field for UI/log purposes only — NOT consumed by any review-trigger logic.
            llm_hint_signals = Array(llm_hint&.dig('signals') || llm_hint&.dig(:signals))
            {
              level: final_level,
              signals: structural[:signals],            # TRUSTED — deterministic only
              complexity_hint_signals: llm_hint_signals # advisory; never feeds OR-floor
            }
          end

          def review_enabled?(session)
            review_cfg = session.config['complexity_review'] || {}
            review_cfg.fetch('enabled', true)
          end

          # ---- Persona Review ----

          def run_persona_review(session, decision_payload, complexity)
            review_cfg = session.config['complexity_review'] || {}
            personas = if complexity[:signals].include?('l0_change')
                         review_cfg['high_personas'] || %w[kairos pragmatic skeptic]
                       else
                         review_cfg['personas'] || %w[pragmatic skeptic]
                       end

            persona_defs = load_persona_definitions(personas, session)
            prompt = build_persona_review_prompt(decision_payload, complexity, persona_defs)
            review_loop = CognitiveLoop.new(self, session)
            messages = [{ 'role' => 'user', 'content' => prompt }]
            result = review_loop.run_phase('review', persona_review_system_prompt, messages, [])

            parsed = parse_persona_review(result['content'])
            parsed[:llm_calls] = review_loop.total_calls
            parsed
          end

          def run_lightweight_review(session, decision_payload, ar_result)
            prompt = build_lightweight_review_prompt(decision_payload, ar_result)
            review_loop = CognitiveLoop.new(self, session)
            messages = [{ 'role' => 'user', 'content' => prompt }]
            result = review_loop.run_phase('review', lightweight_review_system_prompt, messages, [])

            parsed = parse_lightweight_review(result['content'])
            parsed[:llm_calls] = review_loop.total_calls
            parsed
          end

          # ---- Multi-LLM Review (Gate 5.5c) ----

          # Phase 12 §10 / PR3 hardening: test/CI affordance to force-enable review
          # regardless of agent.yml. MUST be no-op when KAIROS_ENV=production.
          # Use case: PR1 bake tests need to exercise INSUFFICIENT/budget paths
          # without flipping enabled:true in production agent.yml.
          def review_force_enabled?
            return false unless ENV['KAIROS_TEST_FORCE_REVIEW'] == 'true'
            if ENV['KAIROS_ENV'].to_s.downcase == 'production'
              warn '[agent_step] KAIROS_TEST_FORCE_REVIEW ignored: KAIROS_ENV=production'
              return false
            end
            true
          end

          # Phase 12 §3.2 OR-floor trigger.
          #   rule_fired = (trigger_on ∩ complexity[:signals]).any?
          #   hint_needed = parse_review_hint(decision_payload['review_hint'])
          #   review_needed = rule_fired || hint_needed
          # Property: hint cannot suppress rule. needed:false + l0_change still fires.
          # Trust: complexity[:signals] is deterministic (assess_decision_complexity);
          # LLM hint signals live in :complexity_hint_signals (not consulted here).
          def multi_llm_review_needed?(multi_cfg, complexity, decision_payload)
            mode = (multi_cfg['trigger_mode'] || 'rule_or_hint').to_s
            unless %w[rule_only rule_or_hint].include?(mode)
              warn "[agent_step] unknown trigger_mode #{mode.inspect}; failing closed to rule_only"
              mode = 'rule_only'
            end
            rule_fired = (Array(multi_cfg['trigger_on']) & Array(complexity[:signals])).any?
            return rule_fired if mode == 'rule_only'

            hint_needed = ::KairosMcp::SkillSets::Agent::ReviewHint.parse(
              decision_payload['review_hint']
            )
            rule_fired || hint_needed
          end

          def run_multi_llm_review(session, decision_payload, complexity, multi_cfg)
            summary = decision_payload['summary'] || 'unknown'
            steps = decision_payload.dig('task_json', 'steps') || []
            step_desc = steps.map.with_index(1) { |s, i|
              "#{i}. #{s['action'] || s['tool_name']} (risk: #{s['risk']}, tool: #{s['tool_name']})"
            }.join("\n")

            artifact_content = <<~ARTIFACT
              # Decision Payload Review

              ## Summary
              #{summary}

              ## Complexity: #{complexity[:level]} (#{complexity[:signals].join(', ')})

              ## Steps
              #{step_desc}

              ## Full Payload
              ```json
              #{JSON.pretty_generate(decision_payload)}
              ```
            ARTIFACT

            review_ctx = session.invocation_context.derive(
              blacklist_remove: %w[multi_llm_review llm_call llm_status]
            )

            review_args = {
              'artifact_content' => artifact_content,
              'artifact_name' => "decision_cycle#{session.cycle_number}_#{session.session_id[0..7]}",
              'review_type' => 'design',
              'review_context' => 'independent'
            }

            # Apply agent.yml overrides
            review_args['max_concurrent_override'] = multi_cfg['max_concurrent'] if multi_cfg['max_concurrent']
            review_args['timeout_seconds_override'] = multi_cfg['timeout_seconds'] if multi_cfg['timeout_seconds']

            raw = invoke_tool('multi_llm_review', review_args, context: review_ctx)
            parsed = JSON.parse(raw.map { |b| b[:text] || b['text'] }.compact.join)

            if parsed['status'] == 'error'
              { verdict: 'INSUFFICIENT', error: parsed['error'], llm_calls: 0,
                aggregated_findings: [], feedback_text: nil }
            elsif (skew = schema_version_check(parsed))
              # Phase 12 §3.10 fail-closed: missing or newer-than-supported schema
              # version → INSUFFICIENT. Never silently misinterpret an APPROVE that
              # may carry semantics this Agent version doesn't understand.
              warn "[agent_step] multi_llm_review schema rejected: #{skew}"
              { verdict: 'INSUFFICIENT', error: "schema_version: #{skew}",
                llm_calls: parsed['llm_calls'] || 0,
                aggregated_findings: [], feedback_text: nil }
            else
              {
                verdict: parsed['verdict'],
                convergence: parsed['convergence'],
                aggregated_findings: (parsed['aggregated_findings'] || []).map { |f|
                  f.transform_keys(&:to_sym)
                },
                llm_calls: parsed['llm_calls'] || 0,
                reviews: parsed['reviews'],
                # Phase 12 §3.3: prefer SkillSet-emitted feedback_text. Nil fallback preserved
                # for compat with v0.3.x callers; Gate 5.5c builds locally when nil.
                feedback_text: parsed['feedback_text'],
                verdict_schema_version: parsed['verdict_schema_version'],
                feedback_text_schema_version: parsed['feedback_text_schema_version']
              }
            end
          rescue StandardError => e
            warn "[agent_step] multi_llm_review failed: #{e.message}"
            { verdict: 'INSUFFICIENT', error: e.message, llm_calls: 0,
              aggregated_findings: [], feedback_text: nil }
          end

          # Phase 12 §3.10 fail-closed schema versioning.
          # Returns nil if response schema is acceptable, else a string reason.
          SUPPORTED_VERDICT_SCHEMA_VERSION = 1
          SUPPORTED_FEEDBACK_TEXT_SCHEMA_VERSION = 1

          def schema_version_check(parsed)
            v_ver = parsed['verdict_schema_version']
            f_ver = parsed['feedback_text_schema_version']
            return 'verdict_schema_version missing' if v_ver.nil?
            return "verdict_schema_version newer than supported (got #{v_ver}, max #{SUPPORTED_VERDICT_SCHEMA_VERSION})" if v_ver.is_a?(Integer) && v_ver > SUPPORTED_VERDICT_SCHEMA_VERSION
            return 'feedback_text_schema_version missing' if f_ver.nil?
            return "feedback_text_schema_version newer than supported (got #{f_ver}, max #{SUPPORTED_FEEDBACK_TEXT_SCHEMA_VERSION})" if f_ver.is_a?(Integer) && f_ver > SUPPORTED_FEEDBACK_TEXT_SCHEMA_VERSION
            nil
          end

          # Inline sanitize for the v0.3.x fallback path. Mirrors multi_llm_review's
          # Sanitizer.sanitize_finding_text (NFKC + control-char strip + delimiter
          # escape) but inlined to avoid cross-SkillSet require. New v0.4+ responses
          # bring already-sanitized findings via feedback_text and bypass this.
          REVIEW_FALLBACK_DELIMITER_RE =
            Regexp.union(
              %w[artifact review_feedback finding persona].flat_map do |t|
                ["<\\s*#{t}\\s*>", "<\\s*/\\s*#{t}\\s*>"]
              end.map { |p| Regexp.new(p, Regexp::IGNORECASE) }
            ).freeze

          def sanitize_review_fallback(s, max_len: 500)
            return '' if s.nil?
            s = s.to_s
            s = s.unicode_normalize(:nfkc) if s.respond_to?(:unicode_normalize)
            # C0/C1 controls + key invisible/bidi chars (subset of multi_llm_review Sanitizer)
            s = s.each_char.reject do |c|
              o = c.ord
              (o <= 0x08) || (o == 0x0B) || (o == 0x0C) ||
                (o >= 0x0E && o <= 0x1F) || (o >= 0x7F && o <= 0x9F) ||
                (o >= 0x200B && o <= 0x200F) || (o >= 0x202A && o <= 0x202E) ||
                (o >= 0x2060 && o <= 0x2064) || (o >= 0x2066 && o <= 0x2069) ||
                o == 0xFEFF || o == 0x00AD
            end.join
            s = s.gsub(REVIEW_FALLBACK_DELIMITER_RE) { |m| "[escaped:#{m.gsub(/[<>\s\/]/, '')}]" }
            s[0, max_len]
          end

          def parse_persona_review(content)
            return review_parse_fallback('no content') unless content

            json_str = extract_json_from_content(content)
            return review_parse_fallback('no JSON found') unless json_str

            parsed = JSON.parse(json_str)
            verdict = parsed['overall_verdict']
            unless verdict.is_a?(String)
              return review_parse_fallback("invalid overall_verdict type: #{verdict.class}")
            end
            parsed['overall_verdict'] = verdict.upcase
            parsed.transform_keys(&:to_sym)
          rescue JSON::ParserError => e
            review_parse_fallback("JSON parse error: #{e.message}")
          end

          def review_parse_fallback(reason)
            {
              overall_verdict: 'REVISE',
              key_findings: ["Review parse failed (#{reason}) — defaulting to REVISE"],
              parse_error: true,
              personas: {}
            }
          end

          def parse_lightweight_review(content)
            return { concerns: [], llm_calls: 0 } unless content

            json_str = extract_json_from_content(content)
            if json_str
              parsed = JSON.parse(json_str)
              { concerns: Array(parsed['concerns']), suggestions: Array(parsed['suggestions']) }
            else
              { concerns: [], suggestions: [], parse_error: true }
            end
          rescue JSON::ParserError
            { concerns: [], suggestions: [], parse_error: true }
          end

          def load_persona_definitions(persona_names, session)
            result = invoke_tool('knowledge_get', { 'name' => 'persona_definitions' },
                                 context: session.invocation_context)
            parsed = JSON.parse(result.map { |b| b[:text] || b['text'] }.compact.join)
            content = parsed['content'] || ''
            extract_persona_sections(content, persona_names)
          rescue StandardError
            # Hardcoded fallback
            {
              'pragmatic' => 'Evaluate for real-world utility, implementation complexity, and maintenance burden.',
              'skeptic' => 'Challenge assumptions, identify edge cases, failure modes, and unintended consequences.',
              'kairos' => 'Evaluate alignment with KairosChain philosophy: self-referentiality, structural integrity, and layer boundaries.'
            }.slice(*persona_names)
          end

          def extract_persona_sections(content, persona_names)
            defs = {}
            persona_names.each do |name|
              # Try to find "### name" or "## name" section
              if content =~ /##\s*#{Regexp.escape(name)}\s*\n(.*?)(?=\n##|\z)/mi
                defs[name] = $1.strip[0..300]
              end
            end
            defs
          end

          # ---- Internal DECIDE with Review Feedback ----

          def run_decide_with_review_feedback_internal(session, feedback)
            loop_inst = CognitiveLoop.new(self, session)

            prior_decision = session.load_decision
            prior_json = prior_decision ? JSON.generate(prior_decision) : '(none)'
            catalog = build_tool_catalog(session)

            messages = [
              { 'role' => 'user', 'content' =>
                "## Available Tools\n#{catalog}\n\n" \
                "Previous plan:\n#{prior_json}\n\n" \
                "This plan was flagged by persona review. Feedback:\n#{feedback}\n\n" \
                "Revise the plan and output a new decision_payload as JSON. " \
                "Include a complexity_hint key in your output. Use ONLY tools listed above." }
            ]

            decide_result = loop_inst.run_decide(decide_system_prompt, messages)
            if decide_result['error']
              return { error: decide_result['error'], llm_calls: loop_inst.total_calls }
            end

            session.save_decision(decide_result['decision_payload'])
            { decision_payload: decide_result['decision_payload'],
              llm_calls: loop_inst.total_calls, error: nil }
          end

          # ---- Phase 12 §3.4 + §3.11 (PR3): L0 checkpoint bundle + chain_record ----

          # Invoke multi_llm_review_bundle tool to get a ready-to-paste prompt bundle
          # for human-driven external review. Returns the parsed response Hash, or
          # nil if the tool is unavailable / errors (caller falls back to legacy path).
          def build_l0_bundle_for_checkpoint(session, decision_payload)
            artifact_content = build_decision_artifact(session, decision_payload)
            args = {
              'artifact_content' => artifact_content,
              'artifact_name'    => "l0_checkpoint_cycle#{session.cycle_number}_#{session.session_id[0..7]}",
              'review_type'      => 'design',
              'review_context'   => 'independent'
            }
            ctx = session.invocation_context.derive(
              blacklist_remove: %w[multi_llm_review_bundle]
            )
            raw = invoke_tool('multi_llm_review_bundle', args, context: ctx)
            parsed = JSON.parse(raw.map { |b| b[:text] || b['text'] }.compact.join)
            return nil if parsed['status'] != 'ok'
            parsed
          rescue StandardError => e
            warn "[agent_step] multi_llm_review_bundle unavailable, falling back: #{e.class}: #{e.message}"
            nil
          end

          # Phase 12 §3.11: record the L0 checkpoint constitutively on chain.
          # Includes decision_payload_hash + bundle_hash + reviewer_roster_hash +
          # config_hash for replay/audit. Decision payload itself recorded inline
          # if ≤16KB (rare for a single decision); larger payloads are rejected
          # rather than silently CAS'd in PR3 (CAS infrastructure is PR4 scope).
          def record_l0_checkpoint_bundle(session, decision_payload, bundle_response)
            payload_json = JSON.generate(decision_payload)
            payload_hash = "sha256:#{Digest::SHA256.hexdigest(payload_json)}"
            inline = payload_json.bytesize <= 16_384

            bundle = bundle_response['bundle'] || {}
            record = {
              'kind'                    => 'l0_checkpoint_review_bundle',
              'session_id'              => session.session_id,
              'cycle_number'            => session.cycle_number,
              'decision_payload_hash'   => payload_hash,
              'decision_payload_inline' => inline ? decision_payload : nil,
              'bundle_schema_version'   => bundle_response['bundle_schema_version'],
              'bundle_hash'             => bundle_response['bundle_hash'],
              'bundle_size_bytes'       => bundle_response['size_bytes'],
              'reviewer_roster_hash'    => bundle['reviewer_roster_hash'],
              'config_hash'             => bundle['config_hash'],
              'recorded_at'             => Time.now.utc.iso8601
            }
            log_str = JSON.generate(record)
            invoke_tool('chain_record', { 'logs' => [log_str] })
            true
          rescue StandardError => e
            # Recording failures must NOT block the checkpoint (the human still needs
            # the prompt bundle). Log + carry on.
            warn "[agent_step] chain_record failed for L0 checkpoint: #{e.class}: #{e.message}"
            false
          end

          def format_bundle_for_human(bundle_response)
            bundle = bundle_response['bundle'] || {}
            prompts = bundle['per_reviewer_prompts'] || []
            sections = ["# L0 Change Review — Multi-LLM Bundle",
                        "Bundle hash: #{bundle_response['bundle_hash']}",
                        "Reviewer roster hash: #{bundle['reviewer_roster_hash']}",
                        "Config hash: #{bundle['config_hash']}",
                        '',
                        '## Run each reviewer independently and aggregate per the convergence rule below.',
                        '',
                        "Convergence rule: #{bundle['convergence_rule']}",
                        '',
                        '## Aggregation instructions',
                        bundle['aggregation_instructions'].to_s,
                        '']
            prompts.each_with_index do |r, i|
              sections << "### Reviewer #{i + 1}: #{r['role_label']} (#{r['provider']}/#{r['model'] || 'default'})"
              sections << '```'
              sections << "[System]\n#{r['system_prompt']}\n"
              sections << "[Prompt]\n#{r['prompt']}"
              sections << '```'
              sections << ''
            end
            sections.join("\n")
          end

          def build_decision_artifact(session, decision_payload)
            summary = decision_payload['summary'] || 'unknown'
            steps = decision_payload.dig('task_json', 'steps') || []
            step_desc = steps.map.with_index(1) { |s, i|
              "  #{i}. #{s['action'] || s['tool_name']} (risk: #{s['risk']})"
            }.join("\n")
            <<~ART
              # L0 Change Review Required

              Goal: #{session.goal_name}
              Cycle: #{session.cycle_number}
              Summary: #{summary}

              Steps:
              #{step_desc}

              Full decision payload:
              ```json
              #{JSON.pretty_generate(decision_payload)}
              ```
            ART
          end

          # ---- Multi-LLM Review Prompt Generation ----

          def generate_multi_llm_review_prompt(session, decision_payload)
            summary = decision_payload['summary'] || 'unknown'
            steps = decision_payload.dig('task_json', 'steps') || []
            step_desc = steps.map.with_index(1) { |s, i|
              "  #{i}. #{s['action'] || s['tool_name']} (risk: #{s['risk']})"
            }.join("\n")

            <<~PROMPT
              # L0 Change Review Required

              An autonomous agent proposed the following L0-level change.
              L0 changes modify the KairosChain framework itself and require external review.

              ## Goal: #{session.goal_name}
              ## Summary: #{summary}
              ## Steps:
              #{step_desc}

              ## Review Criteria
              1. Does this change preserve structural self-referentiality?
              2. Is the change recorded on the blockchain?
              3. Could this be a SkillSet instead of core infrastructure?
              4. Are layer boundaries (L0/L1/L2) respected?

              Please evaluate with APPROVE / REVISE / REJECT and explain your reasoning.
            PROMPT
          end

          # ---- Prompts ----

          def orient_system_prompt
            "You are an analytical assistant in the ORIENT phase of an OODA loop. " \
            "Analyze the observation, identify gaps, set priorities, and recommend an action. " \
            "You have access to knowledge and context tools for research. " \
            "Return your analysis as structured text."
          end

          def decide_system_prompt
            # Phase 12 §3.2 / §11: review_hint is REQUIRED but ADVISORY.
            # The OR-floor in Gate 5.5c uses (rule_fired || hint_needed); a hint of
            # `needed:false` cannot suppress rule-based triggers. Use it to RAISE
            # the gate when you (the planner) sense a subtle risk the structural
            # rule would miss. Use `false` for routine plans.
            "You are a planning assistant in the DECIDE phase of an OODA loop. " \
            "Based on the orientation analysis, create a concrete execution plan. " \
            "Output ONLY a JSON object with these keys:\n" \
            "  - summary (string)\n" \
            "  - task_json (object with task_id, meta, steps array). Each step needs: " \
            "step_id, action, tool_name, tool_arguments, risk (low/medium/high), " \
            "depends_on, requires_human_cognition.\n" \
            "  - review_hint (object) — REQUIRED. Shape: { needed: <bool>, " \
            "reason: <string|null>, urgency: \"low\"|\"medium\"|\"high\"|null }. " \
            "Set needed:true to REQUEST multi-LLM review for subtle high-impact " \
            "decisions; set needed:false for routine plans. The hint is advisory " \
            "and additive — structural rules may still fire review independently."
          end

          def reflect_system_prompt
            "You are an evaluator in the REFLECT phase of an OODA loop. " \
            "Assess the execution results against the original goal. " \
            "Output a JSON object: {confidence: 0.0-1.0, achieved: [...], " \
            "remaining: [...], learnings: [...], open_questions: [...]}."
          end

          def persona_review_system_prompt
            "You are a multi-perspective review panel evaluating an autonomous agent's " \
            "proposed action plan. Each persona has a distinct viewpoint. Evaluate " \
            "independently, then synthesize. Output ONLY a JSON object with the " \
            "structure specified in the prompt."
          end

          def lightweight_review_system_prompt
            "You are a skeptical reviewer evaluating the results of an autonomous agent's " \
            "execution. Identify any concerns, edge cases, or quality issues. " \
            "Output a JSON object: {concerns: [...], suggestions: [...]}."
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
            "Include a 'complexity_hint' key: {\"level\": \"low\"|\"medium\"|\"high\", " \
            "\"signals\": [\"reason1\"]}. Assess complexity based on risk, step count, " \
            "architectural scope, and L0 framework changes. " \
            "Use ONLY tools listed above."
          end

          def build_persona_review_prompt(decision_payload, complexity, persona_defs)
            summary = decision_payload['summary'] || 'unknown'
            steps = decision_payload.dig('task_json', 'steps') || []
            step_text = steps.map.with_index(1) { |s, i|
              "  #{i}. #{s['action'] || s['tool_name']} (risk: #{s['risk']}, tool: #{s['tool_name']})"
            }.join("\n")

            persona_sections = persona_defs.map { |name, desc|
              "### #{name}\n#{desc}\nEvaluate from this perspective."
            }.join("\n\n")

            <<~PROMPT
              Evaluate the following proposed action plan from multiple perspectives.

              ## Proposal
              Summary: #{summary}
              Complexity: #{complexity[:level]} (#{complexity[:signals].join(', ')})
              Steps:
              #{step_text}

              ## Personas
              #{persona_sections}

              For EACH persona, provide:
              - VERDICT: APPROVE | REVISE | REJECT
              - CONCERNS: [list of specific concerns]
              - SUGGESTIONS: [list of improvements]

              Then provide:
              - OVERALL_VERDICT: APPROVE (all approve) | REVISE (any revise) | REJECT (any reject)
              - KEY_FINDINGS: [consolidated list of all concerns]

              Output as a single JSON object.
            PROMPT
          end

          def build_lightweight_review_prompt(decision_payload, ar_result)
            summary = decision_payload['summary'] || 'unknown'
            act_summary = ar_result.dig(:act, 'summary') || 'unknown'
            confidence = ar_result.dig(:reflect, 'confidence') || 0.0
            achieved = ar_result.dig(:reflect, 'achieved') || []

            <<~PROMPT
              Review the execution results of an autonomous agent cycle.

              Plan summary: #{summary}
              Execution result: #{act_summary}
              Confidence: #{confidence}
              Achieved: #{achieved.join(', ')}

              As a skeptical reviewer, identify any concerns about:
              1. Whether the execution actually achieved what was planned
              2. Edge cases or error handling that may have been missed
              3. Quality issues in the approach taken

              Output a JSON object: {"concerns": [...], "suggestions": [...]}
            PROMPT
          end

          def build_reflect_prompt(session, act_result)
            "Goal: #{session.goal_name}\n" \
            "Execution result:\n#{JSON.generate(act_result)}\n\n" \
            "Evaluate: what was achieved, what remains, confidence level (0.0-1.0)."
          end

          # ---- Phase Context (Enhancement D: Phase Tool Filter) ----

          # Build a phase-specific InvocationContext from agent.yml phase_tools config.
          # Returns the session's base context if phase_tool_filter is disabled or
          # no config exists for the given phase.
          def phase_context(session, phase_name)
            return session.invocation_context unless feature_enabled?(session, 'phase_tool_filter')

            phase_tools = session&.config&.dig('phase_tools', phase_name)
            return session.invocation_context unless phase_tools

            whitelist = phase_tools['include']
            return session.invocation_context if whitelist.nil? || whitelist.empty?

            session.invocation_context.derive_for_phase(
              whitelist: whitelist,
              blacklist_add: phase_tools['exclude'] || []
            )
          end

          # Check if a v1.1c feature is enabled in agent.yml
          def feature_enabled?(session, feature_name)
            session&.config&.dig('features', feature_name) != false
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

          # ---- JSON Extraction ----

          # Extract valid JSON from content that may include code fences or prose.
          # Same logic as CognitiveLoop#extract_json but accessible from AgentStep.
          def extract_json_from_content(content)
            JSON.parse(content)
            content
          rescue JSON::ParserError
            # Try code fences first
            if content =~ /```(?:json)?\s*\n?(.*?)\n?```/m
              begin
                JSON.parse($1)
                return $1
              rescue JSON::ParserError
                # fall through
              end
            end
            # Bare JSON after prose: find first { to last }
            if content =~ /(\{.*\})/m
              begin
                JSON.parse($1)
                return $1
              rescue JSON::ParserError
                nil
              end
            end
          end

          # ---- Structured Logging ----

          # Log an agent event via KairosMcp.logger (non-fatal).
          def log_agent(level, event, session, **fields)
            return unless defined?(::KairosMcp) && ::KairosMcp.respond_to?(:logger) && ::KairosMcp.logger
            fields[:source] = 'agent_step'
            fields[:session_id] = session&.session_id
            fields[:goal] = session&.goal_name
            fields[:cycle] = session&.cycle_number
            ::KairosMcp.logger.send(level, event, **fields)
          rescue StandardError
            # Logger must never crash the agent
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

          # ---- Permission Hook Management ----

          def apply_permission_hook
            mcp_name = detect_mcp_server_name
            return { 'status' => 'error', 'error' => 'Could not detect MCP server name' } unless mcp_name

            settings_path = find_settings_path
            return { 'status' => 'error', 'error' => 'No .claude/settings.json found' } unless settings_path

            settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
            settings['hooks'] ||= {}
            settings['hooks']['PreToolUse'] ||= []

            matcher = "mcp__#{mcp_name}__*"

            # Check if already configured
            if settings['hooks']['PreToolUse'].any? { |h| h['matcher'] == matcher }
              return { 'status' => 'ok', 'message' => "PreToolUse hook for #{matcher} already configured" }
            end

            hook_entry = {
              'matcher' => matcher,
              'hooks' => [{
                'type' => 'command',
                'command' => "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\"," \
                             "\"permissionDecision\":\"allow\"," \
                             "\"permissionDecisionReason\":\"Auto-allowed for #{mcp_name} agent autonomous mode\"}}'",
                'statusMessage' => "Auto-allowing #{mcp_name} tool..."
              }]
            }

            settings['hooks']['PreToolUse'] << hook_entry
            File.write(settings_path, JSON.pretty_generate(settings) + "\n")

            { 'status' => 'ok', 'message' => "PreToolUse hook added for #{matcher} in #{settings_path}" }
          rescue StandardError => e
            { 'status' => 'error', 'error' => "Failed to apply hook: #{e.message}" }
          end

          def detect_mcp_server_name
            settings_candidates.each do |path|
              next unless File.exist?(path)
              settings = JSON.parse(File.read(path))
              (settings['mcpServers'] || {}).each do |name, config|
                cmd_parts = Array(config['command']) + Array(config['args'])
                return name if cmd_parts.any? { |part| part.to_s.include?('kairos-chain') }
              end
            end
            nil
          rescue StandardError
            nil
          end

          def find_settings_path
            # Prefer project-level settings, fall back to global
            settings_candidates.find { |p| File.exist?(p) }
          end

          def settings_candidates
            project_settings = File.join(Dir.pwd, '.claude', 'settings.json')
            global_settings = File.join(Dir.home, '.claude', 'settings.json')
            [project_settings, global_settings]
          end
        end
      end
    end
  end
end
