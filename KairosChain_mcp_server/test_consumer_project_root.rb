# frozen_string_literal: true

# Tests for consumer_project_root separation (design v0.2).
# Reference: log/20260512_consumer_project_root_separation_design_v0.2.md
#
# Coverage targets (§7 test surface invariants):
#   1. Independence (data_dir at A, project_root at B unrelated)
#   2. Default-rule per transport (stdio/cli use cwd if plausible; http returns nil)
#   3. Loud-failure conditions (coincidence, non-existent, unauthorized → refusal)
#   4. Graceful skip (no candidate → nil + diagnostic)
#   5. Backward compatibility (legacy data_dir = project_root/.kairos still works)
#   6. Round-trip inspection (consumer_project_root + source queryable)
#   7. SKIPPED — Inv 9 (multi-consumer routing) deferred from v0.2 implementation
#   8. Canonical path (symlinks resolve to same real path)
#   9. Authorization (explicit setter records source provenance)
#
# Plus regression: the original SUSHI bug (--data-dir outside cwd).

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/plugin_projector'

class ConsumerProjectRootTest < Minitest::Test
  def setup
    @original_env_project_root = ENV.delete('KAIROS_PROJECT_ROOT')
    @original_env_data_dir = ENV.delete('KAIROS_DATA_DIR')
    @original_pwd = Dir.pwd
    KairosMcp.reset_data_dir!
    KairosMcp.reset_consumer_project_root!
    @tmpdir = Dir.mktmpdir('kc_test_consumer_root_')
  end

  def teardown
    Dir.chdir(@original_pwd) if Dir.exist?(@original_pwd)
    ENV['KAIROS_PROJECT_ROOT'] = @original_env_project_root if @original_env_project_root
    ENV['KAIROS_DATA_DIR'] = @original_env_data_dir if @original_env_data_dir
    KairosMcp.reset_data_dir!
    KairosMcp.reset_consumer_project_root!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  # --- §7.5 backward compatibility ---

  def test_backward_compat_default_to_cwd_when_plausible
    project = File.join(@tmpdir, 'my_project')
    FileUtils.mkdir_p(File.join(project, '.git'))
    Dir.chdir(project) do
      KairosMcp.reset_consumer_project_root!
      root = KairosMcp.resolve_consumer_project_root(transport: :stdio_mcp)
      assert_equal File.realpath(project), root
      assert_equal :transport_default, KairosMcp.consumer_project_root_source
    end
  end

  # --- §7.2 default-rule tests ---

  def test_default_fails_plausibility_when_no_marker_present
    bare = File.join(@tmpdir, 'no_markers')
    FileUtils.mkdir_p(bare)
    Dir.chdir(bare) do
      KairosMcp.reset_consumer_project_root!
      root = KairosMcp.resolve_consumer_project_root(transport: :stdio_mcp)
      assert_nil root
      assert_equal :absent, KairosMcp.consumer_project_root_source
    end
  end

  def test_http_mcp_has_no_default
    project = File.join(@tmpdir, 'project')
    FileUtils.mkdir_p(File.join(project, '.git'))
    Dir.chdir(project) do
      KairosMcp.reset_consumer_project_root!
      root = KairosMcp.resolve_consumer_project_root(transport: :http_mcp)
      assert_nil root, "HTTP MCP must not default even when plausible cwd is available"
      assert_equal :absent, KairosMcp.consumer_project_root_source
    end
  end

  # --- §7 explicit/env resolution ---

  def test_explicit_setter_overrides_default
    project_a = File.join(@tmpdir, 'a')
    project_b = File.join(@tmpdir, 'b')
    FileUtils.mkdir_p(File.join(project_a, '.git'))
    FileUtils.mkdir_p(File.join(project_b, 'CLAUDE.md').then { |p| File.dirname(p) })
    File.write(File.join(project_b, 'CLAUDE.md'), '# B')
    Dir.chdir(project_a) do
      KairosMcp.reset_consumer_project_root!
      KairosMcp.consumer_project_root = project_b
      assert_equal File.realpath(project_b), KairosMcp.consumer_project_root
      assert_equal :explicit_cli, KairosMcp.consumer_project_root_source
    end
  end

  def test_env_var_takes_precedence_over_default
    project_env = File.join(@tmpdir, 'env_root')
    project_cwd = File.join(@tmpdir, 'cwd_root')
    FileUtils.mkdir_p(File.join(project_env, '.claude'))
    FileUtils.mkdir_p(File.join(project_cwd, '.git'))
    ENV['KAIROS_PROJECT_ROOT'] = project_env
    Dir.chdir(project_cwd) do
      KairosMcp.reset_consumer_project_root!
      root = KairosMcp.resolve_consumer_project_root(transport: :stdio_mcp)
      assert_equal File.realpath(project_env), root
      assert_equal :explicit_env, KairosMcp.consumer_project_root_source
    end
  ensure
    ENV.delete('KAIROS_PROJECT_ROOT')
  end

  # --- §7.8 canonical path ---

  def test_symlink_resolves_to_same_real_path
    project = File.join(@tmpdir, 'real_project')
    FileUtils.mkdir_p(File.join(project, '.git'))
    link = File.join(@tmpdir, 'link_to_project')
    File.symlink(project, link)
    KairosMcp.reset_consumer_project_root!
    KairosMcp.consumer_project_root = link
    assert_equal File.realpath(project), KairosMcp.consumer_project_root
    refute_equal link, KairosMcp.consumer_project_root, "symlink path itself must not be stored"
  end

  # --- §7.6 round-trip inspection ---

  def test_source_provenance_recorded
    project = File.join(@tmpdir, 'p')
    FileUtils.mkdir_p(File.join(project, '.git'))

    KairosMcp.reset_consumer_project_root!
    KairosMcp.consumer_project_root = project
    assert_equal :explicit_cli, KairosMcp.consumer_project_root_source

    KairosMcp.reset_consumer_project_root!
    ENV['KAIROS_PROJECT_ROOT'] = project
    KairosMcp.resolve_consumer_project_root(transport: :stdio_mcp)
    assert_equal :explicit_env, KairosMcp.consumer_project_root_source
  ensure
    ENV.delete('KAIROS_PROJECT_ROOT')
  end

  # --- Plausibility predicate ---

  def test_plausibility_each_marker
    %w[CLAUDE.md .git .claude].each do |marker|
      dir = File.join(@tmpdir, "with_#{marker.delete('.')}")
      FileUtils.mkdir_p(dir)
      if marker == 'CLAUDE.md'
        File.write(File.join(dir, marker), 'x')
      else
        FileUtils.mkdir_p(File.join(dir, marker))
      end
      assert KairosMcp.plausibility_check(dir), "marker #{marker.inspect} should pass plausibility"
    end
  end

  def test_plausibility_prior_manifest_marker
    dir = File.join(@tmpdir, 'with_prior_manifest')
    FileUtils.mkdir_p(File.join(dir, '.kairos'))
    File.write(File.join(dir, '.kairos', 'projection_manifest.json'), '{}')
    assert KairosMcp.plausibility_check(dir)
  end

  def test_plausibility_fails_on_bare_dir
    dir = File.join(@tmpdir, 'bare')
    FileUtils.mkdir_p(dir)
    refute KairosMcp.plausibility_check(dir)
  end

  def test_plausibility_fails_on_nonexistent
    refute KairosMcp.plausibility_check(File.join(@tmpdir, 'nope'))
    refute KairosMcp.plausibility_check(nil)
    refute KairosMcp.plausibility_check('')
  end
end

# =============================================================================
# PluginProjector Inv 3 enforcement
# =============================================================================

class PluginProjectorCoincidenceTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('kc_test_coincidence_')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  # --- §7.1 independence ---

  def test_constructs_when_project_root_and_data_dir_distinct
    pr = File.join(@tmpdir, 'project')
    dd = File.join(@tmpdir, 'data')
    FileUtils.mkdir_p(pr)
    FileUtils.mkdir_p(dd)
    p = KairosMcp::PluginProjector.new(pr, mode: :project, data_dir: dd)
    assert_equal pr, p.project_root
    assert_equal dd, p.data_dir
  end

  # --- §6 row "coincidence → loud failure" ---

  def test_refuses_when_project_root_equals_data_dir
    same = File.join(@tmpdir, 'same')
    FileUtils.mkdir_p(same)
    err = assert_raises(KairosMcp::PluginProjector::CoincidenceRefused) do
      KairosMcp::PluginProjector.new(same, mode: :project, data_dir: same)
    end
    assert_match(/coincide/, err.message)
  end

  def test_refuses_coincidence_via_symlink
    real = File.join(@tmpdir, 'real')
    link = File.join(@tmpdir, 'link')
    FileUtils.mkdir_p(real)
    File.symlink(real, link)
    assert_raises(KairosMcp::PluginProjector::CoincidenceRefused) do
      KairosMcp::PluginProjector.new(real, mode: :project, data_dir: link)
    end
  end

  # --- §7.5 backward-compat: legacy single-arg constructor still works ---

  def test_legacy_constructor_without_data_dir_kwarg
    pr = File.join(@tmpdir, 'legacy_project')
    FileUtils.mkdir_p(pr)
    p = KairosMcp::PluginProjector.new(pr, mode: :project)
    assert_equal pr, p.project_root
    assert_equal File.join(pr, '.kairos'), p.data_dir
  end

  # --- §7.1 independence test (end-to-end smoke) ---

  def test_projection_writes_under_project_root_not_data_dir
    pr = File.join(@tmpdir, 'consumer_project')
    dd = File.join(@tmpdir, 'kairos_data')
    FileUtils.mkdir_p(File.join(pr, '.claude'))
    FileUtils.mkdir_p(dd)

    p = KairosMcp::PluginProjector.new(pr, mode: :project, data_dir: dd)
    body = "# test mode body\n"
    result = p.project_instruction_mode!('testmode', body, mode_version: '0.1')

    assert_path_exists result[:artifact_path]
    assert result[:artifact_path].start_with?(File.realpath(pr)) ||
           result[:artifact_path].start_with?(pr),
           "artifact should be under project_root #{pr}, got #{result[:artifact_path]}"
    refute result[:artifact_path].start_with?(dd),
           "artifact must NOT be under data_dir #{dd}"

    # CLAUDE.md must be at project_root, not data_dir
    assert_path_exists File.join(pr, 'CLAUDE.md')
    refute File.exist?(File.join(dd, 'CLAUDE.md')), "CLAUDE.md must NOT be created in data_dir"

    # Manifest lives in data_dir, not project_root
    assert_path_exists File.join(dd, 'instruction_mode_manifest.json')
  end
end

# =============================================================================
# Regression: original SUSHI bug
# =============================================================================

class OriginalBugRegressionTest < Minitest::Test
  def setup
    @original_env_project_root = ENV.delete('KAIROS_PROJECT_ROOT')
    @original_env_data_dir = ENV.delete('KAIROS_DATA_DIR')
    @original_pwd = Dir.pwd
    KairosMcp.reset_data_dir!
    KairosMcp.reset_consumer_project_root!
    @tmpdir = Dir.mktmpdir('kc_test_regression_')
  end

  def teardown
    Dir.chdir(@original_pwd) if Dir.exist?(@original_pwd)
    ENV['KAIROS_PROJECT_ROOT'] = @original_env_project_root if @original_env_project_root
    ENV['KAIROS_DATA_DIR'] = @original_env_data_dir if @original_env_data_dir
    KairosMcp.reset_data_dir!
    KairosMcp.reset_consumer_project_root!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  # Reproduces the SUSHI handoff scenario:
  #   consumer cwd: /srv/sushi/masa_test_sushi_*  (only .git, no projection yet)
  #   data_dir:    /srv/sushi/SUSHI.../KairosChain_mcp_server  (unrelated, server-side)
  #
  # Under v0.1 behavior, projection would target File.dirname(data_dir) = server side.
  # Under v0.2 with explicit --project-root, projection targets the consumer.
  def test_explicit_project_root_overrides_remote_data_dir
    consumer = File.join(@tmpdir, 'consumer_workspace')
    server   = File.join(@tmpdir, 'remote_server')
    FileUtils.mkdir_p(File.join(consumer, '.git'))
    FileUtils.mkdir_p(File.join(consumer, '.claude'))
    server_data = File.join(server, 'KairosChain_mcp_server')
    FileUtils.mkdir_p(server_data)

    KairosMcp.data_dir = server_data
    KairosMcp.consumer_project_root = consumer

    p = KairosMcp::PluginProjector.new(
      KairosMcp.consumer_project_root,
      mode: :project,
      data_dir: KairosMcp.data_dir,
    )
    result = p.project_instruction_mode!('sushilover', "# sushilover mode\n", mode_version: '0.1')

    # Artifact and CLAUDE.md must land on consumer side, NOT server side
    assert result[:artifact_path].start_with?(File.realpath(consumer)),
           "artifact should be on consumer side; got #{result[:artifact_path]}"
    assert_path_exists File.join(consumer, 'CLAUDE.md')
    refute File.exist?(File.join(File.dirname(server_data), 'CLAUDE.md')),
           "no CLAUDE.md should be created at File.dirname(data_dir) anymore"
  end

  # Without --project-root and without env var, in a non-plausible cwd, projection
  # is refused with a clear signal (no silent writes).
  def test_no_silent_write_when_cwd_implausible
    bare = File.join(@tmpdir, 'bare_cwd')
    FileUtils.mkdir_p(bare)
    Dir.chdir(bare) do
      KairosMcp.reset_consumer_project_root!
      root = KairosMcp.resolve_consumer_project_root(transport: :stdio_mcp)
      assert_nil root
      assert_equal :absent, KairosMcp.consumer_project_root_source
      # No file should have been written anywhere
      assert_empty Dir.glob(File.join(bare, '**', '*'))
    end
  end
end
