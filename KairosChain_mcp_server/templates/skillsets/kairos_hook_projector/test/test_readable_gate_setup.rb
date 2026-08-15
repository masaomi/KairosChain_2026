# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'

require_relative '../lib/readable_gate_setup'

# The one-call path: declare, then install. What is worth witnessing here is
# not the tools — they have their own suites — but the sequence and the status
# this reports for each answer they can give. The first draft of this class got
# the last one wrong in the shape this whole SkillSet exists to prevent: it
# reported a successful install as a refusal.
class TestReadableGateSetup < Minitest::Test
  S = KairosMcp::SkillSets::KairosHookProjector::ReadableGateSetup

  # A double per tool, returning canned bodies in the tools' real shape.
  class FakeTool
    class << self
      attr_accessor :replies, :calls
    end

    def call(args)
      self.class.calls ||= []
      self.class.calls << args
      body = self.class.replies.shift
      [{ type: 'text', text: JSON.generate(body) }]
    end
  end

  def tool_class(*replies)
    Class.new(FakeTool).tap { |k| k.replies = replies.dup }
  end

  def setup
    @dir = Dir.mktmpdir
    @decl = File.join(@dir, 'demo.mode_hooks.json')
    File.write(@decl, JSON.generate(
                        'mode_name' => 'demo', 'version' => '1',
                        'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                                  'section' => '§ Readable output' }] }
                      ))
  end

  def added(action = 'created')
    { 'action' => action, 'declaration' => @decl }
  end

  def run_with(add:, project:, validate: nil, **kwargs)
    S.new(skillset_root: @dir,
          tools: { add: add, project: project, validate: validate })
     .run(**{ mode: 'demo' }.merge(kwargs))
  end

  def test_a_declared_gate_is_installed_and_the_validators_verdict_is_carried_out
    project = tool_class({ 'plan_sha256' => 'abc' }, { 'action' => 'applied' })
    out = run_with(add: tool_class(added), project: project,
                   validate: tool_class('verdict' => 'OK',
                                        'checks' => { 'installed' => { 'status' => 'ok' } }),
                   apply: true)
    assert_equal :ok, out.status
    assert_equal 'OK', out.data['verdict']
    assert_equal @decl, out.data['declaration']

    # The apply must echo the digest the proposal returned; a fresh digest, or
    # none, is refused by the tool and nothing would be written.
    assert_equal 'abc', project.calls.last['confirm_sha256']
    assert_equal true, project.calls.last['apply']
  end

  # The defect this file exists for. OPEN_QUESTIONS means the gate IS installed
  # and some other section of the mode states a limit with no recorded
  # decision. Reporting that as a refusal told the operator their install had
  # failed when it had not — the same false sentence about a live gate that
  # round 16 removed from the validator.
  def test_open_questions_after_a_successful_install_is_reported_not_refused
    out = run_with(add: tool_class(added),
                   project: tool_class({ 'plan_sha256' => 'abc' }, { 'action' => 'applied' }),
                   validate: tool_class('verdict' => 'OPEN_QUESTIONS',
                                        'checks' => { 'installed' => { 'status' => 'ok' },
                                                      'declared' => { 'status' => 'open' } }),
                   apply: true)
    assert_equal :ok, out.status,
                 'the gate is installed; an unrecorded decision elsewhere is not a failure'
    assert_equal 'OPEN_QUESTIONS', out.data['verdict'], 'and the verdict is not swallowed'
    assert_equal 'ok', out.data.dig('checks', 'installed', 'status')
  end

  def test_without_apply_it_proposes_and_the_project_tool_is_called_once
    project = tool_class('plan_sha256' => 'abc')
    out = run_with(add: tool_class(added), project: project)
    assert_equal :proposed, out.status
    assert_equal 1, project.calls.length, 'a proposal must not be followed by an apply'
    refute project.calls.first.key?('apply')
  end

  # Found by running it: `gate enable masa --apply` on a mode that already has
  # the gate answered "mode_hooks_add wrote no declaration: gate_already_
  # declared" and exited 1 — while the same reply carried the declaration's
  # path, so the sentence disproved itself. Already declared is the goal
  # already met. It carries on, so a second run converges and so that "edit the
  # numbers, then run it again" is a true instruction rather than a hopeful one.
  def test_a_mode_that_already_declares_the_gate_carries_on_instead_of_refusing
    project = tool_class({ 'plan_sha256' => 'abc', 'up_to_date' => true },
                         { 'action' => 'applied' })
    out = run_with(add: tool_class('error' => 'gate_already_declared',
                                   'declaration' => @decl, 'nothing_written' => true),
                   project: project,
                   validate: tool_class('verdict' => 'OK',
                                        'checks' => { 'installed' => { 'status' => 'ok' } }),
                   apply: true)
    assert_equal :ok, out.status, 'an already-declared gate is not a failure'
    assert_equal true, out.data['already_declared'], 'and the caller is told which it was'
    assert_equal 'OK', out.data['verdict']
    assert_equal 2, project.calls.length,
                 're-applying is how an edited threshold reaches the harness'
  end

  # The declaration is not rewritten from the catalogue on a second run: it may
  # carry thresholds the mode tuned, and for masa a live blocking gate.
  def test_an_already_declared_mode_keeps_its_tuned_declaration
    File.write(@decl, JSON.generate(
                        'mode_name' => 'demo', 'version' => '1',
                        'hooks' => { 'Stop' => [{ 'gate' => 'readable_gate',
                                                  'section' => '§ tuned',
                                                  'blocking' => true,
                                                  'params' => { 'max_lines' => 12 } }] }
                      ))
    run_with(add: tool_class('error' => 'gate_already_declared', 'declaration' => @decl),
             project: tool_class({ 'plan_sha256' => 'abc' }, { 'action' => 'applied' }),
             validate: tool_class('verdict' => 'OK'), apply: true)
    e = JSON.parse(File.read(@decl, encoding: 'UTF-8')).dig('hooks', 'Stop', 0)
    assert_equal '§ tuned', e['section']
    assert_equal true, e['blocking'], 'a live blocking gate must not be reset to the catalogue'
    assert_equal 12, e.dig('params', 'max_lines')
  end

  # The boundary of the clause above, and the reason it names one error rather
  # than testing that an error is present. Six other refusals from the add tool
  # ALSO carry a declaration path — declaration_not_json, declaration_unreadable
  # (twice), mode_name_mismatch, declaration_ships_inside_the_skillset, and
  # existing_declaration_refused. Widening "already declared" to "any error with
  # a path" would send a corrupt or misnamed declaration on to the projector
  # under the words "already declared". These must still refuse.
  def test_other_add_refusals_that_also_carry_a_path_are_not_read_as_already_declared
    %w[declaration_not_json declaration_unreadable mode_name_mismatch
       declaration_ships_inside_the_skillset existing_declaration_refused].each do |err|
      project = tool_class('plan_sha256' => 'abc')
      out = run_with(add: tool_class('error' => err, 'declaration' => @decl,
                                     'nothing_written' => true),
                     project: project, apply: true)
      assert_equal :refused, out.status, "#{err}: a broken declaration is not an installed one"
      assert_match(/#{err}/, out.detail)
      assert_nil project.calls, "#{err}: nothing may be projected from it"
    end
  end

  def test_a_refused_declaration_stops_before_the_projector_runs
    project = tool_class('plan_sha256' => 'abc')
    out = run_with(add: tool_class('action' => 'refused', 'refusal' => 'unknown_gate'),
                   project: project, apply: true)
    assert_equal :refused, out.status
    assert_match(/unknown_gate/, out.detail)
    assert_nil project.calls, 'nothing may be projected from a declaration that was not written'
  end

  # An apply that answers anything other than `applied` has not written. Taking
  # the call's return as evidence of the write is how this SkillSet's stage 2
  # went a whole round having never written a file.
  def test_an_apply_that_did_not_apply_is_refused_and_no_verdict_is_invented
    validate = tool_class('verdict' => 'OK')
    out = run_with(add: tool_class(added),
                   project: tool_class({ 'plan_sha256' => 'abc' },
                                       { 'action' => 'refused_confirmation' }),
                   validate: validate, apply: true)
    assert_equal :refused, out.status
    assert_match(/refused_confirmation/, out.detail)
    assert_nil validate.calls, 'a validate answer must not be reported for a write that did not happen'
  end

  def test_a_named_section_replaces_the_catalogues_and_nothing_else_moves
    run_with(add: tool_class(added),
             project: tool_class('plan_sha256' => 'abc'),
             section: '§ 形')
    doc = JSON.parse(File.read(@decl, encoding: 'UTF-8'))
    assert_equal '§ 形', doc.dig('hooks', 'Stop', 0, 'section')
    assert_equal 'readable_gate', doc.dig('hooks', 'Stop', 0, 'gate')
    assert_equal 'demo', doc['mode_name']
  end

  def test_without_a_section_the_catalogues_value_is_left_alone
    run_with(add: tool_class(added), project: tool_class('plan_sha256' => 'abc'))
    doc = JSON.parse(File.read(@decl, encoding: 'UTF-8'))
    assert_equal '§ Readable output', doc.dig('hooks', 'Stop', 0, 'section'),
                 'this command reads no mode body and must not decide the section'
  end
end
