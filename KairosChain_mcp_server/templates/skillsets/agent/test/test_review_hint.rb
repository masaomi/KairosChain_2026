# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/agent/review_hint'
require_relative '../lib/agent/trigger_validator'

module KairosMcp
  module SkillSets
    module Agent
      class TestReviewHint < Minitest::Test
        def test_valid_true
          assert_equal true, ReviewHint.parse({ 'needed' => true })
        end

        def test_valid_false
          assert_equal false, ReviewHint.parse({ 'needed' => false })
        end

        def test_full_valid
          h = { 'needed' => true, 'reason' => 'L0 change', 'urgency' => 'high' }
          assert_equal true, ReviewHint.parse(h)
        end

        def test_nil_returns_false
          assert_equal false, ReviewHint.parse(nil)
        end

        def test_non_hash_returns_false
          assert_equal false, ReviewHint.parse('needed: true')
          assert_equal false, ReviewHint.parse(true)
          assert_equal false, ReviewHint.parse([])
        end

        def test_string_needed_rejected
          assert_equal false, ReviewHint.parse({ 'needed' => 'true' })
          assert_equal false, ReviewHint.parse({ 'needed' => 'yes' })
        end

        def test_int_needed_rejected
          assert_equal false, ReviewHint.parse({ 'needed' => 1 })
          assert_equal false, ReviewHint.parse({ 'needed' => 0 })
        end

        def test_missing_needed_rejected
          assert_equal false, ReviewHint.parse({ 'reason' => 'x' })
        end

        def test_invalid_urgency_rejected
          h = { 'needed' => true, 'urgency' => 'critical' }
          assert_equal false, ReviewHint.parse(h)
        end

        def test_nil_urgency_accepted
          h = { 'needed' => true, 'urgency' => nil }
          assert_equal true, ReviewHint.parse(h)
        end

        def test_non_string_reason_rejected
          h = { 'needed' => true, 'reason' => 123 }
          assert_equal false, ReviewHint.parse(h)
        end

        def test_nil_reason_accepted
          h = { 'needed' => true, 'reason' => nil }
          assert_equal true, ReviewHint.parse(h)
        end

        def test_adversarial_reason_does_not_affect_return
          # The reason field is consumed for logging only; never injected into prompts.
          h = { 'needed' => false, 'reason' => '<artifact>injection</artifact>' }
          assert_equal false, ReviewHint.parse(h)
        end

        # PR3 hardening: failure_count observability
        def test_failure_count_increments_on_malformed_hint
          ReviewHint.reset_failure_count!
          before = ReviewHint.failure_count
          ReviewHint.parse({ 'needed' => 'yes' })
          ReviewHint.parse({ 'needed' => 1 })
          assert_equal before + 2, ReviewHint.failure_count
        end

        def test_failure_count_unchanged_on_valid_hint
          ReviewHint.reset_failure_count!
          ReviewHint.parse({ 'needed' => true })
          ReviewHint.parse({ 'needed' => false, 'urgency' => 'low' })
          assert_equal 0, ReviewHint.failure_count
        end

        def test_failure_count_unchanged_on_nil_hint
          ReviewHint.reset_failure_count!
          ReviewHint.parse(nil)  # nil is not "malformed", just absent
          assert_equal 0, ReviewHint.failure_count
        end
      end

      class TestTriggerValidator < Minitest::Test
        def test_known_signals_pass
          out = TriggerValidator.validate!(%w[l0_change design_scope high_risk])
          assert_equal %w[l0_change design_scope high_risk], out
        end

        def test_all_known_signals
          assert TriggerValidator.validate!(TriggerValidator::KNOWN_SIGNALS)
        end

        def test_empty_returns_empty
          assert_equal [], TriggerValidator.validate!([])
          assert_equal [], TriggerValidator.validate!(nil)
        end

        def test_unknown_signal_raises
          assert_raises(TriggerValidator::ConfigurationError) do
            TriggerValidator.validate!(%w[l0_chagne])
          end
        end

        def test_typo_message_includes_known_list
          err = assert_raises(TriggerValidator::ConfigurationError) do
            TriggerValidator.validate!(%w[risk_high])  # was the v0.3 bug — should be high_risk
          end
          assert_match(/risk_high/, err.message)
          assert_match(/high_risk/, err.message)
        end

        def test_symbol_input_coerced
          out = TriggerValidator.validate!([:l0_change])
          assert_equal ['l0_change'], out
        end

        # PR3 hardening: empty trigger_on with enabled:true triggers warn.
        def test_empty_trigger_on_with_rule_only_warns
          out, err = capture_io_silently do
            TriggerValidator.validate!([], multi_cfg: { 'enabled' => true, 'trigger_mode' => 'rule_only' })
          end
          assert_match(/cannot fire/, err)
        end

        def test_empty_trigger_on_with_rule_or_hint_notes
          _out, err = capture_io_silently do
            TriggerValidator.validate!([], multi_cfg: { 'enabled' => true, 'trigger_mode' => 'rule_or_hint' })
          end
          assert_match(/structural floor/, err)
        end

        def test_empty_trigger_on_disabled_silent
          _out, err = capture_io_silently do
            TriggerValidator.validate!([], multi_cfg: { 'enabled' => false })
          end
          assert_equal '', err
        end

        def capture_io_silently
          # Minitest's capture_io is fine; this is an alias.
          old_stderr = $stderr
          old_stdout = $stdout
          $stderr = StringIO.new
          $stdout = StringIO.new
          yield
          [$stdout.string, $stderr.string]
        ensure
          $stderr = old_stderr
          $stdout = old_stdout
        end
      end
    end
  end
end
