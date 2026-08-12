# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/mode_hooks_schema'
require 'tmpdir'
require 'digest'
require_relative '../lib/mode_hooks_compiler'

# Stage 1 DoD-S1-1 .. DoD-S1-8.
# Design: docs/drafts/kairos_hook_projector_stage1_design_v0.2_draft.md
class TestModeHooksCompiler < Minitest::Test
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  RECORD_SCHEMA = JSON.parse(
    File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_record_schema.json'))
  )
  DOC_SCHEMA = JSON.parse(
    File.read(File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json'))
  )

  def setup
    @c = KairosMcp::SkillSets::KairosHookProjector::ModeHooksCompiler.new
  end

  def doc(overrides = {})
    {
      'mode_name' => 'masa',
      'version' => '1',
      'hooks' => {
        'Stop' => [
          { 'gate' => 'readable_gate', 'section' => '§ Readable',
            'params' => { 'max_lines' => 60 } }
        ]
      }
    }.merge(overrides)
  end

  S = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema

  # Uses the shipped validator, not the json-schema gem — that gem is absent
  # from the gemspec entirely, so a test depending on it passes only on a
  # machine that happened to have it. The validator's own completeness is
  # asserted separately, by requiring it to implement every construct the
  # schemas use.
  def assert_record_valid(record)
    result = S.validate(record, RECORD_SCHEMA)
    assert result.valid?, "compile record must validate. Got: #{result.message}"
  end

  def assert_document_valid(document)
    result = S.validate(document, DOC_SCHEMA)
    assert result.valid?, "document must validate. Got: #{result.message}"
  end

  # --- DoD-S1-1: both accepted input shapes ---------------------------------

  def test_absent_document_compiles_to_empty_artifact
    r = @c.compile(mode_name: 'masa')
    assert r.compiled?
    assert_equal 'absent', r.record['resolution_path']
    assert_equal @c.empty_artifact, r.artifact
    assert_nil r.record['input']['document_sha256']
    assert_record_valid r.record
  end

  def test_document_with_no_hooks_is_empty_document_not_absent
    r = @c.compile(mode_name: 'masa', document: doc('hooks' => {}))
    assert r.compiled?
    assert_equal 'empty-document', r.record['resolution_path']
    assert_equal @c.empty_artifact, r.artifact
    refute_nil r.record['input']['document_sha256']
    assert_record_valid r.record
  end

  # Inv-D3: absent and empty-document differ only in the record.
  def test_absent_and_empty_document_are_artifact_identical
    a = @c.compile(mode_name: 'masa')
    b = @c.compile(mode_name: 'masa', document: doc('hooks' => {}))
    assert_equal a.artifact, b.artifact
    refute_equal a.record['resolution_path'], b.record['resolution_path']
  end

  # Inv-D2: the empty artifact does not vary by mode.
  def test_empty_artifact_is_mode_independent
    a = @c.compile(mode_name: 'masa').artifact
    b = @c.compile(mode_name: 'tutorial').artifact
    assert_equal @c.canonical_json(a), @c.canonical_json(b)
  end

  # --- DoD-S1-2: refusal categories, each reachable, none overlapping -------

  def test_refuses_composition_content
    r = @c.compile(mode_name: 'masa', document: doc('extends' => ['conservative']))
    assert r.refused?
    assert_equal 'composition_content_present', r.record['refusal']['category']
    assert_nil r.artifact
    assert_record_valid r.record
  end

  def test_an_empty_extends_list_is_not_composition_content
    r = @c.compile(mode_name: 'masa', document: doc('extends' => []))
    assert r.compiled?, 'a declared-but-empty extends list must not refuse'
  end

  # An empty conflict_policy used to reach the composition check. It cannot
  # now: the schema gives it minLength 1, so shape refuses it first. Both
  # halves are refusals; only the category differs, and the category is what
  # tells the author which rule they broke.
  def test_an_empty_conflict_policy_is_a_shape_refusal
    r = @c.compile(mode_name: 'masa', document: doc('conflict_policy' => ''))
    assert r.refused?
    assert_equal 'schema_invalid', r.record['refusal']['category']
  end

  def test_refuses_binding_mismatch_on_mode_name
    r = @c.compile(mode_name: 'tutorial', document: doc)
    assert r.refused?
    assert_equal 'binding_mismatch', r.record['refusal']['category']
    assert_record_valid r.record
  end

  def test_refuses_when_mode_body_moved_on
    body = "# masa mode\nv0.4.6\n"
    d = doc('binding' => { 'mode_version' => '0.4.6',
                           'mode_body_sha256' => Digest::SHA256.hexdigest(body) })
    ok = @c.compile(mode_name: 'masa', document: d, mode_body: body)
    assert ok.compiled?, 'matching body must compile'

    drifted = @c.compile(mode_name: 'masa', document: d, mode_body: body + "edited\n")
    assert drifted.refused?
    assert_equal 'binding_mismatch', drifted.record['refusal']['category']
    assert_match(/mode body has changed/, drifted.record['refusal']['detail'])
  end

  def test_document_without_binding_cannot_drift
    r = @c.compile(mode_name: 'masa', document: doc, mode_body: 'anything at all')
    assert r.compiled?, 'absent binding means drift is undetectable, not failed'
  end

  def test_refuses_unknown_gate
    d = doc('hooks' => { 'Stop' => [{ 'gate' => 'no_such_gate', 'section' => 'x' }] })
    r = @c.compile(mode_name: 'masa', document: d)
    assert r.refused?
    assert_equal 'unknown_gate', r.record['refusal']['category']
    assert_record_valid r.record
  end

  # Partition property: one input, exactly one category.
  def test_each_refusal_category_is_reachable_and_singular
    cases = {
      'composition_content_present' => doc('extends' => ['x']),
      'unknown_gate' => doc('hooks' => { 'Stop' => [{ 'gate' => 'zzz', 'section' => 's' }] })
    }
    seen = cases.map do |expected, d|
      r = @c.compile(mode_name: 'masa', document: d)
      assert r.refused?
      assert_equal expected, r.record['refusal']['category']
      expected
    end
    seen << @c.compile(mode_name: 'other', document: doc).record['refusal']['category']
    assert_equal seen.uniq.size, seen.size, 'categories must not collide'
  end

  # --- malformed input is a refusal, never a raise (Inv-C1) ----------------

  # Every one of these raised a raw Ruby exception before the shape check went
  # in — a third domain outcome, which Inv-C1 forbids. Reported by three
  # reviewers independently in round 1.
  def test_malformed_shapes_refuse_instead_of_raising
    {
      'document is an array' => [],
      'document is a string' => 'nope',
      'hooks is an array' => doc('hooks' => [{ 'gate' => 'readable_gate' }]),
      'hooks is a string' => doc('hooks' => 'nope'),
      'event value is an object' => doc('hooks' => { 'Stop' => { 'gate' => 'g' } }),
      'entry is an integer' => doc('hooks' => { 'Stop' => [7] }),
      'entry is a string' => doc('hooks' => { 'Stop' => ['nope'] }),
      'entry lacks section' => doc('hooks' => { 'Stop' => [{ 'gate' => 'readable_gate' }] }),
      'unknown top-level key' => doc('zzz' => 1),
      'version missing' => { 'mode_name' => 'masa' }
    }.each do |name, document|
      r = @c.compile(mode_name: 'masa', document: document)
      assert r.refused?, "#{name}: expected a refusal, got #{r.record['outcome']}"
      assert_equal 'schema_invalid', r.record['refusal']['category'], name
      refute_empty r.record['refusal']['detail'], name
    end
  end

  def test_a_null_event_value_is_refused_not_silently_empty
    r = @c.compile(mode_name: 'masa', document: doc('hooks' => { 'Stop' => nil }))
    assert r.refused?, 'a null event value used to compile to the empty artifact'
    assert_equal 'schema_invalid', r.record['refusal']['category']
  end

  # --- the mode identity becomes a filename --------------------------------

  def test_a_traversing_mode_name_is_refused
    ['../evil', 'a/b', '/abs', '..', '', "nul\0byte"].each do |name|
      r = @c.compile(mode_name: name, document: doc('mode_name' => name))
      assert r.refused?, "#{name.inspect} must not reach a filename"
      assert_equal 'unsafe_mode_name', r.record['refusal']['category'], name.inspect
    end
  end

  # --- only Stop-family events carry a once-per-turn brake -----------------

  def test_an_event_without_a_once_per_turn_brake_is_refused
    d = doc('hooks' => { 'UserPromptSubmit' => [{ 'gate' => 'readable_gate', 'section' => 's' }] })
    r = @c.compile(mode_name: 'masa', document: d)
    assert r.refused?
    assert_equal 'unsupported_event', r.record['refusal']['category']
    assert_match(/once-per-turn/, r.record['refusal']['detail'])
  end

  def test_subagent_stop_is_permitted
    d = doc('hooks' => { 'SubagentStop' => [{ 'gate' => 'readable_gate', 'section' => 's' }] })
    assert @c.compile(mode_name: 'masa', document: d).compiled?
  end

  # --- the record is validated against its own schema (Inv-6) --------------

  def test_the_compile_record_satisfies_its_own_schema
    # Not asserted by re-validating here — that would only prove the test can
    # call the validator. The producer validates, so a record that drifts
    # raises out of compile, and every other test in this file would fail.
    schema = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.load_schema(
      File.join(SKILLSET_ROOT, 'mode_hooks', '_record_schema.json')
    )
    unsupported = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema
                  .unsupported_keywords(schema)
    assert_empty unsupported,
                 'the validator must implement every construct the record schema uses, ' \
                 'or it reports a pass it did not establish'
  end

  # --- DoD-S1-3: ordering determinism, >= 3 hooks on one event -------------

  def three_hook_doc
    doc('hooks' => {
          'Stop' => [
            { 'gate' => 'readable_gate', 'section' => 'A', 'params' => { 'max_lines' => 10 } },
            { 'gate' => 'readable_gate', 'section' => 'B', 'params' => { 'max_lines' => 20 } },
            { 'gate' => 'readable_gate', 'section' => 'C', 'params' => { 'max_lines' => 30 } }
          ]
        })
  end

  def test_ordering_is_deterministic_and_positional
    a = @c.compile(mode_name: 'masa', document: three_hook_doc)
    b = @c.compile(mode_name: 'masa', document: three_hook_doc)
    assert_equal @c.canonical_json(a.artifact), @c.canonical_json(b.artifact)

    events = a.record['output']['events']['Stop']
    assert_equal [0, 1, 2], events.map { |e| e['position'] }
    assert_equal %w[A B C], events.map { |e| e['section'] },
                 'realized ordering must be readable off the record alone'
  end

  def test_artifact_is_pure_across_runs
    a = @c.compile(mode_name: 'masa', document: doc)
    b = @c.compile(mode_name: 'masa', document: doc)
    assert_equal a.record['output']['artifact_sha256'],
                 b.record['output']['artifact_sha256']
    refute_equal(a.record.keys.sort, [], 'sanity')
  end

  # --- Artifact shape ------------------------------------------------------

  def test_artifact_carries_mode_params_and_unresolved_path_tokens
    r = @c.compile(mode_name: 'masa', document: doc)
    cmd = r.artifact['hooks']['Stop'][0]['command']
    assert_includes cmd, 'kairos-readable-gate',
                    'the harness must invoke the shipped executable, not an interpreter'
    refute_includes cmd, 'python', 'no interpreter may be frozen into the artifact'
    assert_includes cmd, '${KAIROS_HOOK_CONFIG_ROOT}/masa.Stop.readable_gate.0.json'

    cfg = JSON.parse(r.artifact['files']['masa.Stop.readable_gate.0.json'])
    assert_equal 60, cfg['max_lines'], "the mode's number must survive verbatim"
    assert_equal 'masa', cfg['mode_name']
    assert_equal '§ Readable', cfg['section']
  end

  def test_input_document_is_never_mutated
    d = doc
    before = Marshal.dump(d)
    @c.compile(mode_name: 'masa', document: d)
    assert_equal before, Marshal.dump(d)
  end

  # --- DoD-S1-8: no filesystem side effects --------------------------------

  def test_compile_writes_nothing
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        before = Dir.glob('**/*', File::FNM_DOTMATCH).sort
        @c.compile(mode_name: 'masa', document: three_hook_doc)
        @c.compile(mode_name: 'masa')
        @c.compile(mode_name: 'x', document: doc)
        after = Dir.glob('**/*', File::FNM_DOTMATCH).sort
        assert_equal before, after, 'compile must not touch the filesystem'
      end
    end
  end

  # --- Schema agreement between producer and consumer (DoD-S1-7) -----------

  def test_fixture_documents_validate_against_the_document_schema
    [doc, three_hook_doc, doc('hooks' => {}),
     doc('not_gated' => [{ 'section' => '§ Three Pillars', 'reason' => 'no trace' }])].each do |d|
      errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(d, DOC_SCHEMA).errors
      assert_empty errors, "fixture must be schema-valid. Got: #{errors.inspect}"
    end
  end

  def test_schema_rejects_hook_entry_without_section
    d = doc('hooks' => { 'Stop' => [{ 'gate' => 'readable_gate' }] })
    errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(d, DOC_SCHEMA).errors
    refute_empty errors, 'a gate entry with no section must be rejected'
  end
end
