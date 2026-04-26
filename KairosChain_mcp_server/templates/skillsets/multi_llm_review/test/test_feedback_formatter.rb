# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/feedback_formatter'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestFeedbackFormatter < Minitest::Test
        F = FeedbackFormatter

        def test_empty_findings_returns_empty
          assert_equal '', F.build([])
          assert_equal '', F.build(nil)
        end

        def test_single_finding_format
          out = F.build([{ severity: 'P1', issue: 'missing validation' }])
          expected = <<~TXT.chomp
            Multi-LLM review found issues:
            - P1: missing validation

            Revise plan to address these.
          TXT
          assert_equal expected, out
        end

        def test_string_keys_supported
          out = F.build([{ 'severity' => 'P0', 'issue' => 'critical' }])
          assert_includes out, '- P0: critical'
        end

        def test_severity_falls_back_to_question_mark
          out = F.build([{ issue: 'no severity' }])
          assert_includes out, '- P?: no severity'
        end

        def test_sanitization_applied_to_issue
          out = F.build([{ severity: 'P1', issue: 'see <artifact>payload</artifact>' }])
          refute_includes out, '<artifact>'
          assert_includes out, 'P1:'
        end

        def test_truncates_at_50_findings_with_omission_marker
          findings = (1..100).map { |i| { severity: 'P3', issue: "finding #{i}" } }
          out = F.build(findings)
          assert_includes out, '- P3: finding 1'
          assert_includes out, '- P3: finding 50'
          refute_includes out, 'finding 51'
          assert_includes out, '... (50 more findings omitted'
        end

        def test_no_omission_marker_at_exact_limit
          findings = (1..50).map { |i| { severity: 'P3', issue: "f#{i}" } }
          out = F.build(findings)
          refute_includes out, 'omitted'
        end

        def test_max_aggregated_findings_hard_cap
          findings = (1..300).map { |i| { severity: 'P3', issue: "f#{i}" } }
          out = F.build(findings)
          # Hard cap is 200; first 50 of those shown; omission marker shows 150
          assert_includes out, '... (150 more findings omitted'
        end

        def test_severity_sanitized_to_alphanumeric
          out = F.build([{ severity: 'P1; DROP TABLE', issue: 'x' }])
          assert_includes out, 'P1DROPTA'  # 'P1DROPTABLE' truncated to first 8 alnum chars
          refute_includes out, ';'
        end

        def test_build_insufficient_sanitizes_error
          out = F.build_insufficient('error: <artifact>injection</artifact>')
          assert_includes out, 'could not complete'
          refute_includes out, '<artifact>'
        end

        def test_build_insufficient_truncates_error
          out = F.build_insufficient('x' * 1000)
          assert out.length < 300, "expected short message, got #{out.length}"
        end

        def test_deterministic_output_same_input
          findings = [
            { severity: 'P0', issue: 'first' },
            { severity: 'P1', issue: 'second' }
          ]
          assert_equal F.build(findings), F.build(findings)
        end

        def test_schema_version_constant
          assert_equal 1, F::SCHEMA_VERSION
        end
      end
    end
  end
end
