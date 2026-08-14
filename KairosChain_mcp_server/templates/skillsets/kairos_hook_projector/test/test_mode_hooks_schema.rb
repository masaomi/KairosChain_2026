# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/mode_hooks_schema'

# Stage 0 commit 2: mode_hooks/_schema.json self-validation tests.
#
# Design reference: docs/drafts/kairos_hook_projector_design_v0.2_draft.md
#   - DoD-0-2: mode_hooks schema is self-validating.
#   - DoD-0-3: composition fields are validation targets; syntactically valid
#     declarations are accepted; syntactically invalid ones are rejected.
#   - §7.2 schema invariants: mode_name/version required, hooks optional,
#     composition fields optional but accepted.
class TestModeHooksSchema < Minitest::Test
  S = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema

  # Round 3 debt. Both of these are what the module calls its important part,
  # and nothing under test reached either: every schema in the suite uses only
  # implemented keywords, and no document made the walk raise.

  # Residual, found while writing this and left as a finding rather than fixed
  # here: the scan only collects keys from nodes that already look like schema
  # nodes, so a bare `{"allOf": [...]}` with no type/properties/items/enum/
  # required beside it is not recognised and passes silently. The keyword is
  # caught only when it sits on a node the scan recognises, which is what this
  # asserts.
  def test_a_schema_using_an_unimplemented_keyword_is_refused_not_passed
    result = S.validate({ 'a' => 1 },
                        'type' => 'object', 'allOf' => [{ 'type' => 'object' }])
    refute result.valid?, 'a schema this validator cannot check must not pass'
    assert_includes result.message, 'allOf'
  end

  def test_a_validator_that_raises_fails_closed
    # A schema that is not an object at all: the walk raises rather than
    # reporting, and a rescue that returned valid would compile the document.
    result = S.validate({ 'a' => 1 }, 'not a schema')
    refute result.valid?, 'a validator error must never be read as a pass'
    assert_includes result.message, 'validator error'
  end

  SKILLSET_ROOT = File.expand_path('..', __dir__)
  SCHEMA_PATH = File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json')

  def setup
    # Through the shipped reader, not a duplicated test-side File.read. The
    # shipped _schema.json carries non-ASCII (§ and — in its descriptions),
    # so this load is the one that raises when load_schema loses its encoding
    # argument under a US-ASCII locale — a test-side read with its own
    # encoding could not see that loss.
    @schema = S.load_schema(SCHEMA_PATH)
  end

  # Test 1 (happy path, DoD-0-2): a minimal valid document with only the
  # required fields validates clean.
  def test_minimal_valid_document_accepted
    doc = { 'mode_name' => 'masa', 'version' => '0.1' }
    errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(doc, @schema).errors
    assert_empty errors,
                 "Minimal valid document {mode_name, version} must validate clean. Got: #{errors.inspect}"
  end

  # Test 2 (reject path, DoD-0-3 second half): a document missing a required
  # field is rejected. Document also exercises a syntactically invalid
  # composition field (extends with non-string entry) to confirm composition
  # fields are real validation targets, not silently passed through.
  def test_syntactically_invalid_document_rejected
    missing_version = { 'mode_name' => 'masa' }
    errors_a = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(missing_version, @schema).errors
    refute_empty errors_a, "Document missing 'version' must be rejected"
    assert errors_a.any? { |e| e.include?('version') },
           "Rejection error must mention the missing 'version' field. Got: #{errors_a.inspect}"

    bad_extends = {
      'mode_name' => 'masa', 'version' => '0.1',
      'extends' => ['conservative', 42] # 42 is not a string
    }
    errors_b = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(bad_extends, @schema).errors
    refute_empty errors_b,
                 "Document with non-string entry in 'extends' must be rejected (composition field is a real validation target, not warn-but-accept)"
  end

  # Test 3 (composition optional + accepted, DoD-0-3 first half + §7.2): a
  # document carrying syntactically valid composition fields (extends,
  # conflict_policy) is accepted. This is the "reservation" invariant — the
  # fields exist in the schema and validate, but stage 0 does not yet attach
  # any compile-time semantics to them.
  def test_composition_fields_optional_and_accepted_when_valid
    doc = {
      'mode_name' => 'masa',
      'version' => '0.1',
      'extends' => %w[conservative agent_aggressive],
      'conflict_policy' => 'error'
    }
    errors = KairosMcp::SkillSets::KairosHookProjector::ModeHooksSchema.validate(doc, @schema).errors
    assert_empty errors,
                 "Composition fields (extends, conflict_policy) must be accepted when syntactically valid. Got: #{errors.inspect}"
  end
end
