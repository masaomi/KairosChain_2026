# frozen_string_literal: true

# multi_llm_review 0.12.0 — reviews when reviewer CLIs are missing or the host is
# not Claude Code (design log/mlr_non_claude_host_design_v0.3.3).
#
#   INV-H1  a failed seat's reason is the cause its transport established
#   INV-H2  the roster's state is said wherever a result is read
#   INV-H3  quorum and rule do not depend on host or maker diversity
#   INV-H4  the persona seat names the declared host; none is assumed silently
#
# Unit tests drive RosterHealth, Consensus, FeedbackFormatter and
# PersonaAssembly directly; the rest drive the tool's own call body and collect
# with a stub llm_call, as test_tool_wiring does.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'time'

require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/roster_health'
require_relative '../lib/multi_llm_review/feedback_formatter'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../lib/multi_llm_review/dispatcher'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/build_review_bundle'

unless defined?(KairosMcp::Tools::BaseTool)
  module KairosMcp
    module Tools
      class BaseTool
        def initialize(*) ; end
        def text_content(str) = [{ type: 'text', text: str }]
        def invoke_tool(*) = nil
      end
    end
  end
end

require_relative '../tools/multi_llm_review'
require_relative '../tools/multi_llm_review_collect'
require_relative '../tools/multi_llm_review_wait'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      APPROVE_TEXT = "**Overall Verdict**: APPROVE\n\nChecked the roster, the record and the reasons."

      def self.row(label, model, verdict: 'APPROVE', status: :success, error: nil,
                   model_source: 'declared', model_observed: nil, synthetic: false)
        r = { role_label: label, model: model, model_source: model_source,
              synthetic: synthetic, status: status, error: error,
              raw_text: status == :success ? APPROVE_TEXT.sub('APPROVE', verdict) : '' }
        r[:model_observed] = model_observed if model_observed
        r
      end

      # The Claude-Code full roster as 0.11.1 records it: sonnet observed,
      # codex and cursor declaration-derived, the persona synthetic, and the
      # opus slot the persona took over.
      PERSONA_OCCUPIED = [{ role_label: 'claude_cli_opus5.5', model: 'claude-opus-5-5',
                            reason: 'persona_occupied', replaced_by: 'claude_team_claude-opus-5-5' }].freeze

      class TestRosterHealth < Minitest::Test
        H = RosterHealth

        def aggregate(rows, excluded = PERSONA_OCCUPIED, min_quorum: 2)
          Consensus.aggregate(rows, '3/4 APPROVE', min_quorum: min_quorum, excluded_slots: excluded)
        end

        def full_roster(codex: nil, cursor: nil)
          [
            MultiLlmReview.row('claude_cli_sonnet5.5', 'claude-sonnet-5-5',
                               model_source: 'observed', model_observed: 'claude-sonnet-5-5'),
            codex || MultiLlmReview.row('codex_gpt6-astra', 'gpt-6-astra'),
            cursor || MultiLlmReview.row('cursor_composer2.5', 'composer-2.5[fast=true]'),
            MultiLlmReview.row('claude_team_claude-opus-5-5', 'claude-opus-5-5', synthetic: true)
          ]
        end

        def test_maker_table
          assert_equal 'anthropic', H.maker_of('claude-opus-5-5')
          assert_equal 'openai', H.maker_of('gpt-6-astra')
          assert_equal 'openai', H.maker_of('o3')
          assert_equal 'cursor', H.maker_of('composer-2.5[fast=true]')
          assert_equal 'google', H.maker_of('gemini-3.1')
          assert_equal 'unknown', H.maker_of('eu.anthropic.claude-sonnet-5-5')
          assert_equal 'unknown', H.maker_of('claude-opus-5-5,gpt-6-astra')
          assert_equal 'unknown', H.maker_of(nil)
        end

        def test_full_roster_is_whole_and_diverse
          c = aggregate(full_roster)
          rh = c[:vote_tally][:roster_health]
          assert_equal 4, rh[:seats], 'the persona and the slot it took over are one seat'
          assert_equal 4, rh[:counted]
          assert_equal c[:vote_tally][:successful_count], rh[:counted]
          assert_equal 'established', rh[:maker_diversity]
          assert_equal 1, rh[:counted_declared]
          refute H.degraded?(rh)
          sources = rh[:makers].to_h { |m| [m[:role_label], m[:source]] }
          assert_equal 'observed', sources['claude_cli_sonnet5.5']
          assert_equal 'configured', sources['codex_gpt6-astra']
          assert_equal 'declared', sources['claude_team_claude-opus-5-5']
        end

        # The motivating case: a Claude Code user without codex or cursor.
        def test_claude_only_reaches_approve_with_the_mark
          missing = { 'type' => 'unknown', 'message' => 'codex CLI not found', 'code' => 'cli_missing' }
          c = aggregate(full_roster(
            codex: MultiLlmReview.row('codex_gpt6-astra', 'gpt-6-astra', status: :error, error: missing),
            cursor: MultiLlmReview.row('cursor_composer2.5', 'composer-2.5', status: :error,
                                       error: missing.merge('message' => 'cursor agent CLI not found'))
          ))
          assert_equal 'APPROVE', c[:reference_verdict], 'INV-H3: quorum does not depend on makers'
          rh = c[:vote_tally][:roster_health]
          assert_equal [4, 2], [rh[:seats], rh[:counted]]
          assert_equal 'not_established', rh[:maker_diversity]
          assert_equal %w[cli_missing cli_missing], rh[:not_counted].map { |r| r[:reason] }
          assert H.degraded?(rh)
        end

        # W2 (round 3): a partly observed persona carries a joined
        # model_observed while its row says declared; it never counts as known.
        def test_partly_observed_persona_is_declared_and_cannot_establish_diversity
          rows = [
            MultiLlmReview.row('codex_gpt6-astra', 'gpt-6-astra'),
            MultiLlmReview.row('claude_team_claude-opus-5-5', 'claude-opus-5-5', synthetic: true,
                               model_source: 'declared', model_observed: 'claude-opus-5-5,claude-opus-5')
          ]
          rh = aggregate(rows, [])[:vote_tally][:roster_health]
          assert_equal 'declared', rh[:makers].last[:source]
          assert_equal 'not_established', rh[:maker_diversity]
          assert_equal 1, rh[:counted_declared]
        end

        def test_fully_observed_persona_counts_as_observed
          rows = [
            MultiLlmReview.row('codex_gpt6-astra', 'gpt-6-astra'),
            MultiLlmReview.row('claude_team_claude-opus-5-5', 'claude-opus-5-5', synthetic: true,
                               model_source: 'observed', model_observed: 'claude-opus-5-5')
          ]
          rh = aggregate(rows, [])[:vote_tally][:roster_health]
          assert_equal %w[configured observed], rh[:makers].map { |m| m[:source] }
          assert_equal 'established', rh[:maker_diversity]
          assert_equal 0, rh[:counted_declared]
        end

        def test_caller_declaration_alone_never_establishes_diversity
          rows = [
            MultiLlmReview.row('codex_gpt6-astra', 'gpt-6-astra'),
            # A Codex host that copied a Claude model into its declaration.
            MultiLlmReview.row('codex_team_claude-opus-5-5', 'claude-opus-5-5', synthetic: true)
          ]
          rh = aggregate(rows, [])[:vote_tally][:roster_health]
          assert_equal 'not_established', rh[:maker_diversity]
        end
      end

      class TestCauseReasons < Minitest::Test
        def reason(err)
          Consensus.transport_reason({ status: :error, error: err })
        end

        def test_established_codes_are_carried
          %w[cli_missing cli_unauthenticated workspace_refused cli_timeout].each do |code|
            assert_equal code, reason({ 'type' => 'unknown', 'message' => 'x', 'code' => code })
          end
        end

        def test_anything_else_is_transport_and_the_message_is_never_read
          assert_equal 'transport', reason({ 'type' => 'auth_error', 'message' => 'Not logged in' })
          assert_equal 'transport', reason({ 'code' => 'made_up' })
          assert_equal 'transport', reason(nil)
        end

        def test_skip_rows_keep_their_dispatcher_tokens
          assert_equal 'dispatch_timeout',
                       Consensus.transport_reason({ status: :skip, error: { 'message' => 'dispatch_timeout' } })
        end
      end

      class TestFeedbackForResult < Minitest::Test
        F = FeedbackFormatter
        CTX = { path: '/usr/bin:/bin', cwd: '/work/project' }.freeze

        def consensus(verdict, health, successful: 2, min_quorum: 2)
          { reference_verdict: verdict,
            vote_tally: { roster_health: health, successful_count: successful, min_quorum: min_quorum } }
        end

        def whole
          { seats: 4, counted: 4, not_counted: [], makers: [], maker_diversity: 'established', counted_declared: 1 }
        end

        def claude_only
          { seats: 4, counted: 2, maker_diversity: 'not_established', counted_declared: 1, makers: [],
            not_counted: [{ role_label: 'codex_gpt6-astra', reason: 'cli_missing' },
                          { role_label: 'cursor_composer2.5', reason: 'cli_missing' }] }
        end

        def test_approve_on_a_whole_roster_stays_null
          assert_nil F.for_result(consensus('APPROVE', whole), [], CTX)
        end

        def test_approve_on_a_degraded_roster_carries_one_line_that_is_not_a_finding
          text = F.for_result(consensus('APPROVE', claude_only), [], CTX)
          assert_equal 1, text.lines.size
          assert_match(/\ARoster: 2 of 4 seats counted \(1 caller-declared\)/, text)
          assert_includes text, 'cli_missing: codex_gpt6-astra, cursor_composer2.5'
          assert_includes text, 'maker diversity not established'
          refute_match(/\bP[0-3]\b/, text)
        end

        def test_insufficient_names_counted_needed_the_seat_route_and_restoring_actions
          health = { seats: 4, counted: 1, maker_diversity: 'not_established', counted_declared: 0, makers: [],
                     not_counted: [{ role_label: 'claude_cli_sonnet5.5', reason: 'cli_missing' },
                                   { role_label: 'cursor_composer2.5', reason: 'cli_unauthenticated' },
                                   { role_label: 'codex_x', reason: 'workspace_refused' },
                                   { role_label: 'codex_y', reason: 'no_verdict' }] }
          text = F.for_result(consensus('INSUFFICIENT', health, successful: 1), [], CTX)
          assert_includes text, '1 of 2 seats needed counted'
          assert_includes text, 'A seat can be added in config'
          assert_includes text, 'claude_cli_sonnet5.5: cli_missing — install the CLI'
          assert_includes text, '/usr/bin:/bin'
          assert_includes text, 'cursor_composer2.5: cli_unauthenticated — log in'
          assert_includes text, 'codex_x: workspace_refused'
          assert_includes text, '/work/project'
          assert_includes text, "- codex_y: no_verdict\n", 'a reason with no restoring action is named only'
          refute_match(/subprocess|orchestrator_strategy|short wait/i, text, 'the tool advises no strategy')
        end

        def test_revise_puts_the_roster_line_before_the_findings
          text = F.for_result(consensus('REVISE', claude_only),
                              [{ 'severity' => 'P0', 'issue' => 'a real finding' }], CTX)
          assert_match(/\ARoster: /, text)
          assert_includes text, '- P0: a real finding'
        end
      end

      class TestHostLabels < Minitest::Test
        def test_claude_code_or_nothing_keeps_the_legacy_label_and_provider
          [nil, 'claude_code'].each do |host|
            assert_equal 'claude_team_claude-opus-5-5', PersonaAssembly.role_label_for('claude-opus-5-5', host)
            assert_equal 'claude_code', PersonaAssembly.provider_for(host)
          end
        end

        def test_other_hosts_take_their_own_label_and_a_provider_no_seat_uses
          assert_equal 'codex_team_gpt-6-astra', PersonaAssembly.role_label_for('gpt-6-astra', 'codex_cli')
          assert_equal 'codex_host', PersonaAssembly.provider_for('codex_cli')
          assert_equal 'cursor_team_composer-2.5', PersonaAssembly.role_label_for('composer-2.5', 'cursor')
          assert_equal 'other_host', PersonaAssembly.provider_for('other')
        end

        def test_the_collision_check_uses_the_declared_host
          roster = [{ 'provider' => 'codex', 'model' => 'gpt-6-sol', 'role_label' => 'codex_team_gpt-6-astra' },
                    { 'provider' => 'codex', 'model' => 'gpt-6-astra', 'role_label' => 'codex_gpt6-astra' }]
          assert_raises(ObserverSet::RosterError) do
            ObserverSet.build(roster: roster, orchestrator_model: 'gpt-6-astra', persona_host: 'codex_cli')
          end
          ObserverSet.build(roster: roster, orchestrator_model: 'gpt-6-astra') # claude_team_ collides with nothing
        end

        def test_every_seat_is_dispatched_with_no_fallback
          d = Dispatcher.new(nil)
          args = d.send(:build_llm_args, { provider: 'openai', model: 'gpt-6-astra', role_label: 'x' },
                        [], 'sys', 'dispatch-1', 'independent')
          assert_equal true, args['no_fallback']
        end
      end

      class TestToolHostAndRoster < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr-host-')
          @cwd = Dir.pwd
          Dir.chdir(@tmp)
        end

        def teardown
          Dir.chdir(@cwd)
          FileUtils.remove_entry(@tmp)
        end

        ROSTER = [
          { 'provider' => 'claude_code', 'model' => 'claude-sonnet-5-5', 'role_label' => 'claude_cli_sonnet5.5' },
          { 'provider' => 'codex', 'model' => 'gpt-6-astra', 'role_label' => 'codex_gpt6-astra' },
          { 'provider' => 'cursor', 'model' => 'composer-2.5', 'role_label' => 'cursor_composer2.5' }
        ].freeze

        # Seats on a model named in `failing` fail with that code, the rest
        # answer; the stub records what each seat was handed.
        def tool(failing: {})
          t = Tools::MultiLlmReview.new
          cfg = { 'reviewers' => ROSTER, 'convergence_rule' => '3/4 APPROVE', 'min_quorum' => 2,
                  'delegation' => { 'parallel' => { 'default' => false } } }
          calls = @calls = []
          t.define_singleton_method(:load_review_config) { cfg }
          t.define_singleton_method(:invoke_tool) do |_name, args, **_kw|
            calls << args
            if (code = failing[args['model']])
              next [{ text: JSON.generate('status' => 'error',
                                          'error' => { 'type' => 'unknown', 'message' => 'failed', 'code' => code }) }]
            end
            [{ text: JSON.generate('status' => 'ok', 'provider' => 'stub',
                                   'response' => { 'content' => APPROVE_TEXT }, 'usage' => {}) }]
          end
          t
        end

        def run_review(t, args = {})
          JSON.parse(t.call({ 'artifact_content' => 'body', 'artifact_name' => 'n',
                              'review_type' => 'design', 'parallel' => false }.merge(args)).first[:text])
        end

        def test_single_phase_names_the_cause_and_says_so_on_approve
          out = run_review(tool(failing: { 'composer-2.5' => 'cli_missing' }))
          assert_equal 'APPROVE', out['reference_verdict']
          assert_equal 3, out['verdict_schema_version']
          assert_equal 2, out['feedback_text_schema_version']
          lost = out['vote_tally']['denominator_composition']['observers'].find { |o| o['role_label'] == 'cursor_composer2.5' }
          assert_equal 'cli_missing', lost['reason']
          assert_match(/\ARoster: 2 of 3 seats counted/, out['feedback_text'])
          assert_equal 'undeclared', out['orchestrator_host']
          assert(@calls.all? { |a| a['no_fallback'] == true })
        end

        def test_an_unknown_host_is_refused
          out = run_review(tool, 'orchestrator_host' => 'codex')
          assert_equal 'error', out['status']
          assert_match(/orchestrator_host must be one of/, out['error'])
        end

        # INV-H4 end to end: a Codex host declares itself, its persona seat is
        # named for it at collect, and the record keeps declaration and
        # detection side by side.
        def test_declared_codex_host_names_the_persona_seat_at_collect
          out = run_review(tool, 'orchestrator_model' => 'gpt-6-astra', 'orchestrator_host' => 'codex_cli')
          assert_equal 'delegation_pending', out['status']
          refute_match(/Agent tool\b(?! or)/, out['delegation']['instruction'].sub("Claude Code's Agent tool", ''))
          state = PendingState.load_state(out['collect_token'])
          assert_equal 'codex_cli', state['orchestrator_host']

          payload = JSON.parse(Tools::MultiLlmReviewCollect.new.call(
            'collect_token' => out['collect_token'],
            'orchestrator_reviews' => [{ 'persona' => 'p', 'verdict' => 'APPROVE', 'reasoning' => 'checked the record' }]
          ).first[:text])
          persona = payload['reviews'].find { |r| r['role_label'].start_with?('codex_team_') }
          refute_nil persona, 'the persona seat is named for the declared host'
          assert_equal 'codex_host', persona['provider']
          assert_equal 'codex_cli', payload['persona_host']
          assert payload.key?('host_detected')
        end

        def test_undeclared_host_keeps_claude_team
          out = run_review(tool, 'orchestrator_model' => 'gpt-6-astra')
          payload = JSON.parse(Tools::MultiLlmReviewCollect.new.call(
            'collect_token' => out['collect_token'],
            'orchestrator_reviews' => [{ 'persona' => 'p', 'verdict' => 'APPROVE', 'reasoning' => 'checked the record' }]
          ).first[:text])
          assert(payload['reviews'].any? { |r| r['role_label'] == 'claude_team_gpt-6-astra' })
          assert_equal 'undeclared', payload['persona_host']
        end
      end

      class TestWaitSeatOutcomes < Minitest::Test
        def test_answered_and_failed_are_counted_apart
          w = Tools::MultiLlmReviewWait.new
          out = w.send(:seat_outcomes, [
            { 'role_label' => 'a', 'status' => 'success' },
            { 'role_label' => 'b', 'status' => 'error', 'error' => { 'code' => 'cli_missing' } },
            { 'role_label' => 'c', 'status' => 'error', 'error' => { 'message' => 'boom' } },
            { 'role_label' => 'd', 'status' => 'skip', 'error' => { 'message' => 'dispatch_timeout' } }
          ])
          assert_equal 1, out[:subprocess_answered]
          assert_equal [%w[b cli_missing], %w[c transport], %w[d dispatch_timeout]],
                       out[:subprocess_failed].map { |f| [f['role_label'], f['reason']] }
        end
      end
    end
  end
end
