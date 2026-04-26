# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/sanitizer'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestSanitizer < Minitest::Test
        S = Sanitizer

        def test_nil_returns_empty_string
          assert_equal '', S.sanitize_finding_text(nil)
        end

        def test_passthrough_safe_text
          assert_equal 'normal review finding', S.sanitize_finding_text('normal review finding')
        end

        def test_strips_bidi_override_u202e
          input = "innocent‮text"
          out = S.sanitize_finding_text(input)
          refute_includes out, "‮"
          assert_equal 'innocenttext', out
        end

        def test_strips_zero_width_chars
          input = "abc​def‌ghi‍jkl﻿"
          out = S.sanitize_finding_text(input)
          assert_equal 'abcdefghijkl', out
        end

        def test_strips_lrm_rlm
          input = "text‎lrm‏rlm"
          assert_equal 'textlrmrlm', S.sanitize_finding_text(input)
        end

        def test_strips_word_joiner
          assert_equal 'ab', S.sanitize_finding_text("a⁠b")
        end

        def test_strips_soft_hyphen
          assert_equal 'soft', S.sanitize_finding_text("so­ft")
        end

        def test_strips_alm
          assert_equal 'ab', S.sanitize_finding_text("a؜b")
        end

        def test_strips_tag_chars
          input = +"hello"
          input << [0xE0041].pack('U*') # tag latin A
          assert_equal 'hello', S.sanitize_finding_text(input)
        end

        def test_strips_c0_control
          assert_equal 'ab', S.sanitize_finding_text("a\x07b")
        end

        def test_keeps_newline_and_tab
          # \n (0x0A) and \t (0x09) are NOT in CONTROL_CHAR_RANGES (kept for legibility)
          assert_equal "line1\nline2\twith tab", S.sanitize_finding_text("line1\nline2\twith tab")
        end

        def test_escapes_review_feedback_closing_tag
          input = 'reviewer says </review_feedback> end'
          out = S.sanitize_finding_text(input)
          refute_includes out, '</review_feedback>'
          # New v0.4 sanitizer collapses both `<tag>` and `</tag>` forms into the
          # same escape token (the angle-bracket distinction is irrelevant once
          # the framing is broken; what matters is the framing parser cannot
          # match the wrapper anymore).
          assert_includes out, '[escaped:review_feedback]'
        end

        def test_escapes_artifact_tags
          input = 'see <artifact>payload</artifact> here'
          out = S.sanitize_finding_text(input)
          refute_includes out, '<artifact>'
          refute_includes out, '</artifact>'
        end

        def test_escapes_finding_and_persona_tags
          input = '<finding>x</finding> <persona>y</persona>'
          out = S.sanitize_finding_text(input)
          refute_includes out, '<finding>'
          refute_includes out, '<persona>'
        end

        def test_truncates_after_sanitization
          long = "<artifact>" + ('x' * 600)
          out = S.sanitize_finding_text(long, max_len: 50)
          assert out.length <= 50
        end

        def test_escape_form_does_not_re_match
          # Ensures the loop reaches a fixed point (no oscillation)
          input = '<artifact></artifact><artifact></artifact>'
          out = S.sanitize_finding_text(input)
          refute_includes out, '<artifact>'
          refute_includes out, '</artifact>'
        end

        def test_reject_unsanitized_for_chain_passes_clean
          assert_nil S.reject_unsanitized_for_chain!('safe content')
        end

        def test_reject_unsanitized_for_chain_raises_on_delimiter
          assert_raises(Sanitizer::SanitizationError) do
            S.reject_unsanitized_for_chain!('contains <artifact> raw')
          end
        end

        def test_reject_unsanitized_handles_nil_and_empty
          assert_nil S.reject_unsanitized_for_chain!(nil)
          assert_nil S.reject_unsanitized_for_chain!('')
        end

        def test_re_sanitize_walks_nested_structures
          input = {
            'findings' => [
              { 'issue' => "bad‮marker" },
              { 'issue' => 'safe' }
            ],
            'meta' => { 'note' => "<artifact>x</artifact>" }
          }
          out = S.re_sanitize(input)
          refute_includes out['findings'][0]['issue'], "‮"
          assert_equal 'safe', out['findings'][1]['issue']
          refute_includes out['meta']['note'], '<artifact>'
        end

        def test_nfkc_collapses_fullwidth_angle_brackets
          input = '＜artifact＞payload＜/artifact＞'  # U+FF1C / U+FF1E
          out = S.sanitize_finding_text(input)
          refute_includes out, '<artifact>'
          refute_includes out, '＜artifact＞'
          assert_includes out, '[escaped:artifact]'
        end

        def test_case_insensitive_delimiter_match
          out = S.sanitize_finding_text('<Artifact>x</ARTIFACT>')
          refute_match(/<artifact>/i, out)
          assert_includes out, '[escaped:'
        end

        def test_whitespace_inside_delimiter_match
          out = S.sanitize_finding_text('< artifact >x</ artifact >')
          refute_match(/<\s*artifact\s*>/i, out)
        end

        def test_sanitize_artifact_uses_higher_max_len
          long = 'x' * 1000
          out = S.sanitize_artifact(long)
          assert_equal 1000, out.length
        end

        def test_reject_unsanitized_for_chain_catches_fullwidth
          assert_raises(Sanitizer::SanitizationError) do
            S.reject_unsanitized_for_chain!('safe ＜artifact＞ tail')
          end
        end

        def test_reject_unsanitized_for_chain_catches_case_variant
          assert_raises(Sanitizer::SanitizationError) do
            S.reject_unsanitized_for_chain!('< Artifact >')
          end
        end

        def test_re_sanitize_preserves_non_strings
          input = { 'count' => 5, 'flag' => true, 'pi' => 3.14 }
          assert_equal input, S.re_sanitize(input)
        end
      end
    end
  end
end
