# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'base64'
require 'open3'

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require_relative 'templates/skillsets/kairomone/lib/kairomone'

class TestKairomoneUi < Minitest::Test
  ASSETS = File.join(__dir__, 'templates/skillsets/kairomone/assets')

  def setup
    @tmpdir = Dir.mktmpdir('kairomone_ui_test')
    @old_data_dir = ENV['KAIROS_DATA_DIR']
    ENV['KAIROS_DATA_DIR'] = @tmpdir
    KairosMcp.reset_data_dir!
    @fixture = JSON.parse(File.read(File.join(ASSETS, 'fixtures/status_xss.json')))
    @instance = Kairomone::Instance.new(host_root: @tmpdir)
    @instance.init(dot_id: 'synthetic_test_dot', display_name: 'Synthetic <script>alert(1)</script> mossling')
  end

  def teardown
    @old_data_dir ? ENV['KAIROS_DATA_DIR'] = @old_data_dir : ENV.delete('KAIROS_DATA_DIR')
    KairosMcp.reset_data_dir!
    FileUtils.remove_entry(@tmpdir)
  end

  def rendered_fixture
    # Exercise the production serialization path with malicious synthetic fields,
    # including fields that normal status production currently does not populate.
    output = @instance.send(:render_status, @fixture)
    [output, File.read(output, encoding: 'UTF-8')]
  end

  def script_bodies(html)
    html.scan(/<script\b([^>]*)>(.*?)<\/script>/m)
  end

  def test_production_renderer_round_trips_hostile_json_without_new_markup
    _, html = rendered_fixture
    scripts = script_bodies(html)
    assert_equal 2, scripts.length
    assert_includes scripts.first.first, 'type="application/json"'
    assert_equal @fixture, JSON.parse(scripts.first.last)
    refute_includes html, '<script>globalThis.__KAIROMONE_XSS__'
    refute_includes html, '<img src=x'
    refute_match(/[<>&\u2028\u2029]/, scripts.first.last)
    assert_includes scripts.first.last, '\\u003c/script\\u003e'
    assert_includes scripts.first.last, '\\u2028'
    assert_includes scripts.first.last, '\\u2029'
  end

  def test_csp_hash_matches_the_executable_script_in_production_output
    _, html = rendered_fixture
    js = script_bodies(html).last.last
    hash = Base64.strict_encode64(Digest::SHA256.digest(js))
    assert_includes html, "script-src 'sha256-#{hash}'"
    assert_includes html, "default-src 'none'"
    assert_includes html, "connect-src 'none'"
    refute_match(/script-src[^;]*unsafe-inline/, html)
  end

  def test_template_is_self_contained_and_uses_text_only_sinks
    html = File.read(File.join(ASSETS, 'status.html'))
    assert_equal 1, html.scan('__KAIROMONE_STATUS_JSON__').length
    # URL parsing in JavaScript is not a CSS resource request. Asset checks apply
    # to markup/styles; independent executable checks below forbid networking.
    markup = html.gsub(/<script\b[^>]*>.*?<\/script>/m, '')
    refute_match(/<(?:link|iframe|object|embed|form)\b|\bsrc\s*=|\bhref\s*=|@import|url\s*\(/i, markup)
    refute_match(/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write\s*\(/, html)
    refute_match(/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon/, html)
    assert_includes html, 'textContent'
    assert_includes html, 'min-height:44px'
    assert_includes html, '@media(max-width:480px)'
    assert_includes html, 'overflow-wrap:anywhere'
    assert_includes html, 'width=device-width, initial-scale=1'
  end

  def test_public_status_generates_real_initialized_snapshot
    result = @instance.status(render_html: true)
    refute result[:error], result[:error]
    assert result[:initialized]
    output = result.fetch(:html_path)
    # Instance resolves the host root with realpath (macOS: /var -> /private/var).
    # Kairomone 0.8 (design v0.6 M1): init lists the individual under kairomones/<id>/.
    assert_equal File.join(File.realpath(@tmpdir), 'kairomones', 'synthetic_test_dot', 'exports', 'status.html'), output
    payload = JSON.parse(script_bodies(File.read(output)).first.last)
    assert_equal 0, payload.dig('knowledge', 'count')
    assert_equal true, payload.dig('knowledge', 'available')
    assert_equal 0, payload.dig('observations', 'count')
    assert_equal true, payload.dig('observations', 'available')
    assert_equal 1, payload.dig('progression', 'level')
    assert_equal 999, payload.dig('progression', 'level_cap')
    assert_equal 0, payload.dig('progression', 'total_xp')
    assert_nil payload.dig('profession', 'selected_id')
    assert_equal true, payload.dig('profession', 'selection_required')
    assert_equal false, payload.dig('autonomy', 'configured')
    assert_equal 'Synthetic <script>alert(1)</script> mossling', payload.dig('profile', 'display_name')
    refute_includes File.read(output), '<script>alert(1)</script>'
  end

  def test_render_is_fixed_to_private_instance_export_without_source_changes
    template_path = File.join(ASSETS, 'status.html')
    before = Digest::SHA256.file(template_path).hexdigest
    output, = rendered_fixture
    assert_equal File.join(@instance.root, 'exports/status.html'), output
    assert_equal 0o600, File.stat(output).mode & 0o777
    assert_equal before, Digest::SHA256.file(template_path).hexdigest
  end

  def test_dependency_free_javascript_dom_and_state_checks
    output, status = Open3.capture2e('node', File.join(ASSETS, 'test_status_ui.mjs'))
    assert status.success?, output
    assert_includes output, 'PASS:'
  rescue Errno::ENOENT
    skip 'Node is optional for UI development checks; Ruby production-renderer tests still run.'
  end
end
