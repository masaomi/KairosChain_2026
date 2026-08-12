# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/mode_hooks_schema'

# BaseTool stub: these tests exercise the validator's pure judgement, which is
# where the calibration lives. The MCP call path is covered by the tool's own
# BootTimeAssertion, not here.
module KairosMcp
  module Tools
    class BaseTool
      def text_content(str)
        str
      end
    end
  end
end

require_relative '../tools/mode_hooks_validate'
require_relative '../lib/mode_hooks_compiler'

class TestModeHooksValidate < Minitest::Test
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  V = KairosMcp::SkillSets::KairosHookProjector::Tools::ModeHooksValidate

  def setup
    @t = V.new
  end

  # --- section splitting ---------------------------------------------------

  def test_sections_split_on_headings_and_keep_bodies
    body = "# Title\nintro\n\n## A\nforty lines here\n\n### B\nno limit\n"
    secs = @t.send(:sections, body)
    assert_equal %w[A B], secs.map(&:first)
    assert_includes secs[0][1], 'forty lines here'
  end

  # --- candidate detection: the calibration that justifies the regex -------

  def test_candidate_requires_a_quantity_with_a_unit
    hit = "## Shape\n本文は 60 行以内に収める。\n"
    assert_equal ['Shape'], @t.send(:candidates, hit, [], [])

    miss = "## Ethos\n必ず誠実であれ。決して省略するな。never omit.\n"
    assert_empty @t.send(:candidates, miss, [], []),
                 'absolute words alone must not make a section a candidate — ' \
                 'widening to them flags 24 of 53 sections on masa.md v0.4.6'
  end

  def test_candidate_detects_english_units_too
    body = "## Shape\nKeep it under 60 lines and 3 headings.\n"
    assert_equal ['Shape'], @t.send(:candidates, body, [], [])
  end

  def test_gated_and_declined_sections_are_not_candidates
    body = "## Shape\n60 行以内。\n\n## Other\n40 lines max.\n"
    assert_equal %w[Shape Other], @t.send(:candidates, body, [], [])
    assert_equal ['Other'], @t.send(:candidates, body, ['Shape'], [])
    assert_empty @t.send(:candidates, body, ['Shape'], ['Other'])
  end

  def test_section_matching_ignores_section_marks_and_case
    body = "## § Readable Output\n60 行以内。\n"
    assert_empty @t.send(:candidates, body, ['readable output'], []),
                 'a declaration must match its section despite § and case'
  end

  # --- drift ---------------------------------------------------------------

  def sha(str)
    Digest::SHA256.hexdigest(str)
  end

  def test_drift_ok_when_body_matches
    body = "**Version:** 0.4.6\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    assert_equal 'ok', @t.send(:check_drift, doc, body, '/x/masa.md')[:status]
  end

  def test_drift_detected_when_body_edited_without_version_bump
    body = "**Version:** 0.4.6\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    out = @t.send(:check_drift, doc, body + "edited\n", '/x/masa.md')
    assert_equal 'drift', out[:status]
    assert_match(/sha256/, out[:detail])
  end

  def test_drift_detected_on_version_mismatch
    body = "**Version:** 0.4.7\ntext\n"
    doc = { 'binding' => { 'mode_version' => '0.4.6', 'mode_body_sha256' => sha(body) } }
    out = @t.send(:check_drift, doc, body, '/x/masa.md')
    assert_equal 'drift', out[:status]
    assert_match(/version/, out[:detail])
  end

  def test_no_binding_means_unknown_not_ok
    out = @t.send(:check_drift, { 'hooks' => {} }, 'body', '/x/masa.md')
    assert_equal 'unknown', out[:status],
                 'a declaration with no binding must not report a clean bill of health'
  end

  # --- verdict ordering ----------------------------------------------------

  def checks(over = {})
    { drift: { status: 'ok' }, resolvable: { status: 'ok' },
      installed: { status: 'ok' }, declared: { status: 'ok' } }.merge(over)
  end

  def test_verdict_reports_the_most_severe_finding
    assert_equal 'OK', @t.send(:verdict, checks)
    assert_equal 'DRIFT', @t.send(:verdict, checks(drift: { status: 'drift' }))
    assert_equal 'REFUSED', @t.send(:verdict, checks(resolvable: { status: 'refused' }))
    assert_equal 'NOT_INSTALLED', @t.send(:verdict, checks(installed: { status: 'not_installed' }))
    assert_equal 'OPEN_QUESTIONS', @t.send(:verdict, checks(declared: { status: 'open' }))
    assert_equal 'DRIFT',
                 @t.send(:verdict, checks(drift: { status: 'drift' },
                                          declared: { status: 'open' })),
                 'drift outranks an open question'
  end

  # --- the shipped example is not decoration -------------------------------

  def strip_comments(obj)
    case obj
    when Hash then obj.reject { |k, _| k.start_with?('_') }
                     .transform_values { |v| strip_comments(v) }
    when Array then obj.map { |v| strip_comments(v) }
    else obj
    end
  end

  def test_shipped_example_validates_and_compiles
    schema = JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json')))
    doc = strip_comments(JSON.parse(File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_EXAMPLE.json'))))

    errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(doc, schema).errors
    assert_empty errors, "shipped example must be schema-valid. Got: #{errors.inspect}"

    result = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler
             .new.compile(mode_name: 'example', document: doc)
    assert result.compiled?, "shipped example must compile. Got: #{result.record['refusal'].inspect}"
    assert_equal 1, result.record.dig('output', 'hook_count')
  end

  # The shipped example lives in the same directory the compiler scans. The
  # underscore prefix is what keeps it out — the same convention that hides
  # _schema.json and _record_schema.json from the mode inventory.
  def test_example_filename_can_never_be_mistaken_for_a_mode
    assert_nil @t.send(:document_path, 'EXAMPLE'),
               'the example must not resolve as a mode document'
    assert_nil @t.send(:document_path, '_EXAMPLE'),
               'even asked for by its literal name, the example is not a mode'
  end
end
