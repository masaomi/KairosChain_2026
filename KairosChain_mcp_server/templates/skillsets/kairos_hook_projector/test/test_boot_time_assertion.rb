# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/boot_time_assertion'

# Stage 0 commit 3: BootTimeAssertion tests.
#
# Design reference: docs/drafts/kairos_hook_projector_design_v0.2_draft.md
#   - Inv-6: stage 0 side-effect-zero is structurally guaranteed (not by
#     convention) via boot-time verification.
#   - DoD-0-4: read-only status tool with boot-time hash/mtime assertion
#     fails fast on any drift in watched projection target files.
#
# Watched target categories the assertion must cover:
#   - existing file unchanged across pre/post -> passes
#   - existing file content changed -> raises (content drift)
#   - absent file stays absent -> passes
#   - absent file appears between pre/post -> raises (absent->present drift)
class TestBootTimeAssertion < Minitest::Test
  AssertionClass = ::KairosMcp::SkillSets::KairosHookProjector::BootTimeAssertion
  FailureClass = AssertionClass::StructuralAssertionFailure

  def setup
    @tmpdir = Dir.mktmpdir('kairos_hook_projector_boot_time_assertion_')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  # Test 1: empty watch_paths is a no-op that always passes.
  # Establishes that the assertion does not require any watched file to exist.
  def test_empty_watch_paths_passes
    assertion = AssertionClass.new(watch_paths: [])
    assertion.snapshot_pre!
    assertion.verify_post!
    assert_empty assertion.snapshots[:pre]
    assert_empty assertion.snapshots[:post]
  end

  # Test 2: existing file unchanged between pre and post -> passes.
  # This is the success path for the read-only tool wrapping its body.
  def test_unchanged_existing_file_passes
    path = File.join(@tmpdir, 'untouched.json')
    File.write(path, '{"hooks":{}}')
    assertion = AssertionClass.new(watch_paths: [path])
    assertion.snapshot_pre!
    # body does nothing
    assertion.verify_post!
    pre = assertion.snapshots[:pre][path]
    post = assertion.snapshots[:post][path]
    assert_equal pre, post,
                 'unchanged file must produce identical pre/post snapshots'
    refute_equal :absent, pre
  end

  # Test 3: file content modified between pre and post -> raises with diff
  # detail. This is the positive control proving the assertion actually
  # catches stage 0 side-effect-zero violations.
  def test_modified_existing_file_raises
    path = File.join(@tmpdir, 'mutated.json')
    File.write(path, '{"hooks":{}}')
    # Ensure mtime resolution does not mask the change on fast filesystems.
    File.utime(Time.now - 60, Time.now - 60, path)

    assertion = AssertionClass.new(watch_paths: [path])
    assertion.snapshot_pre!
    File.write(path, '{"hooks":{"PostToolUse":[]}}')

    error = assert_raises(FailureClass) { assertion.verify_post! }
    assert_includes error.message, 'stage 0 side-effect-zero violation'
    assert_includes error.message, path
  end

  # Test 4: absent file appearing between pre and post -> raises. Stage 0
  # demands that .claude/settings.json which does not exist must remain
  # non-existent for the duration of the tool call.
  def test_absent_file_appearing_raises
    path = File.join(@tmpdir, 'not_yet_present.json')
    refute File.exist?(path), 'precondition: file must be absent'

    assertion = AssertionClass.new(watch_paths: [path])
    assertion.snapshot_pre!
    assert_equal :absent, assertion.snapshots[:pre][path]

    File.write(path, '{"created":"by violation"}')

    error = assert_raises(FailureClass) { assertion.verify_post! }
    assert_includes error.message, path
  end

  # Test 5 (control): absent file that stays absent -> passes. Confirms the
  # assertion does not spuriously fire for projection targets that legitimately
  # do not exist during stage 0.
  def test_absent_file_staying_absent_passes
    path = File.join(@tmpdir, 'stays_absent.json')
    assertion = AssertionClass.new(watch_paths: [path])
    assertion.snapshot_pre!
    assertion.verify_post!
    assert_equal :absent, assertion.snapshots[:pre][path]
    assert_equal :absent, assertion.snapshots[:post][path]
  end

  # Test 6: verify_post! without snapshot_pre! raises. Sanity check on the
  # contract that pre/post calls are ordered.
  def test_verify_post_without_pre_raises
    assertion = AssertionClass.new(watch_paths: [])
    error = assert_raises(RuntimeError) { assertion.verify_post! }
    assert_includes error.message, 'snapshot_pre!'
  end
end
