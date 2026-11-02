# frozen_string_literal: true

# The snapshot page (Kairomone 0.9 design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 10, N6): assets/status.html written by Instance#render_status with
# exactly what Instance#status_public assembled — the public subset — under
# the renderer contract (one JSON marker, escaped, CSP SHA-256 on the one
# script and the one style, connect-src 'none', text-only sinks). All data is
# synthetic and confined to temporary hosts.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'base64'
require 'open3'

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require_relative 'templates/skillsets/kairomone/lib/kairomone'
require_relative 'templates/skillsets/kairomone/test/support_09'

module KairomoneUiPage
  ASSETS = File.join(__dir__, 'templates/skillsets/kairomone/assets')
  PAYLOAD = %r{<script id="kairomone-status" type="application/json">(.*?)</script>}m
  # What the full status carries and the snapshot never does.
  FULL_STATUS_KEYS = %w[schema_version initialized profile kairomone storage knowledge observations integrity backup instructions
                        growth autonomy progression companion chat_memory art].freeze

  def script_bodies(html) = html.scan(/<script\b([^>]*)>(.*?)<\/script>/m)
  def payload_of(html) = JSON.parse(html[PAYLOAD, 1])
  def digest(text) = Base64.strict_encode64(Digest::SHA256.digest(text))
end

class TestKairomoneUi < Minitest::Test
  include KairomoneUiPage

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
    # Exercise the production serialization path with hostile synthetic fields.
    output = @instance.send(:render_status, @fixture)
    [output, File.read(output, encoding: 'UTF-8')]
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
    assert_includes scripts.first.last, '\\u0026'
    assert_includes scripts.first.last, '\\u2028'
    assert_includes scripts.first.last, '\\u2029'
  end

  def test_csp_hashes_match_the_script_and_style_in_production_output
    _, html = rendered_fixture
    js = script_bodies(html).last.last
    assert_includes html, "script-src 'sha256-#{digest(js)}'"
    styles = html.scan(%r{<style>(.*?)</style>}m).flatten
    assert_equal 1, styles.length
    assert_includes html, "style-src 'sha256-#{digest(styles.first)}'"
    assert_includes html, "default-src 'none'"
    assert_includes html, "connect-src 'none'"
    assert_includes html, 'img-src data:;'
    refute_match(/unsafe-inline|unsafe-eval/, html)
  end

  def test_template_is_self_contained_and_uses_text_only_sinks
    html = File.read(File.join(ASSETS, 'status.html'))
    assert_equal 1, html.scan('__KAIROMONE_STATUS_JSON__').length
    # URL parsing in JavaScript is not a CSS resource request. Asset checks apply
    # to markup/styles; independent executable checks below forbid networking.
    markup = html.gsub(/<script\b[^>]*>.*?<\/script>/m, '')
    refute_match(/<(?:link|iframe|object|embed|form|input|a)\b|\bsrc\s*=|\bhref\s*=|@import|url\s*\(/i, markup)
    refute_match(/\sstyle\s*=/, markup, 'style-src is pinned by hash, so no style attribute')
    refute_match(/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write\s*\(/, html)
    refute_match(/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon/, html)
    assert_equal 2, html.scan(/<button\b/).length, 'the language switch is the only control'
    assert_includes html, 'textContent'
    assert_includes html, 'min-height:44px'
    assert_includes html, '@media(max-width:480px)'
    assert_includes html, 'overflow-wrap:anywhere'
    assert_includes html, 'width=device-width, initial-scale=1'
  end

  def test_the_page_carries_the_public_snapshot_and_the_caller_the_full_status
    result = @instance.status(render_html: true)
    refute result[:error], result[:error]
    assert result[:initialized]
    output = result.fetch(:html_path)
    # Instance resolves the host root with realpath (macOS: /var -> /private/var).
    # Kairomone 0.8 (design v0.6 M1): init lists the individual under kairomones/<id>/.
    assert_equal File.join(File.realpath(@tmpdir), 'kairomones', 'synthetic_test_dot', 'exports', 'status.html'), output
    # The caller still gets the full status (0.9 N6: only the page content changes).
    assert_equal [0, true], result[:knowledge].values_at(:count, :available)
    assert_equal [0, true], result[:observations].values_at(:count, :available)
    assert_equal [1, 999], result[:progression].values_at(:level, :level_cap)
    assert_nil result[:profession][:current]
    assert_equal false, result[:autonomy]['configured']
    assert_equal 'Synthetic <script>alert(1)</script> mossling', result[:profile]['display_name']
    html = File.read(output)
    payload = payload_of(html)
    assert_equal Kairomone::Snapshot::SCHEMA, payload['schema']
    assert_equal @instance.status_public.except('generated_at'), payload.except('generated_at'), 'the page holds exactly status_public'
    assert_empty payload.keys & FULL_STATUS_KEYS, 'no full-status field reaches the page'
    assert_equal 'Synthetic <script>alert(1)</script> mossling', payload['name']
    assert_equal [1, 'egg'], [payload['level'], payload.dig('stage', 'id')]
    assert_equal({ 'shown' => 'egg', 'data_uri' => Kairomone::Art.data_uri(Kairomone::Art::EGG) }, payload['drawing'])
    assert_equal({ 'chosen' => false, 'name' => nil, 'lineage' => [] }, payload['profession'])
    assert_equal({ 'lifetime_cycles' => 0, 'learned_sources' => 0, 'own_growth_l1' => 0, 'own_growth_l2' => 0 }, payload['counts'])
    assert_equal [[], [], 0], payload.values_at('drawings', 'cycles', 'withheld')
    refute_includes html, '<script>alert(1)</script>'
    refute_includes html, File.realpath(@tmpdir), 'no local path'
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

# The written page, from a crafted individual that holds every kind of text
# the snapshot must leave out (0.9 Inv 10): owner's direction and lean, a
# cycle's topic, chat, owner-written entries, a skill, a waiting drawing,
# profile text beyond the name, a retrieval reference and local paths.
class TestKairomoneUiCraftedPage < Minitest::Test
  include Kairomone09Support
  include KairomoneUiPage

  SECRET_PROFILE = PROFILE.merge('appearance' => 'SECRET-APPEARANCE', 'voice' => 'SECRET-VOICE', 'personality' => %w[secretive])

  def crafted
    store = create('momo', profile: SECRET_PROFILE)
    store.configure_companion(request_id: 'dir', expected_revision: 0, direction: { 'preset' => 'custom', 'text' => 'SECRET-DIRECTION-TEXT' })
    store.configure_companion(request_id: 'mem', expected_revision: 1, memory_enabled: true)
    store.remember_companion(request_id: 'chat', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 2,
                             summary: 'SECRET-CHAT-SUMMARY', memory_enabled: true)
    one_cycle(store, 'moss', subjects: %w[botany], topic: 'SECRET-TOPIC about my health', title: 'Moss holds water',
                             content: 'Moss can hold many times its weight in water.', finding: 'Peat moss holds the most.',
                             url: 'https://example.com/moss', reference: 'SECRET-RETRIEVAL fetched copy')
    one_cycle(store, 'paths', subjects: %w[ecology], topic: 'SECRET-TOPIC-TWO', title: 'Lichens',
                              finding: "Saved to #{store.root}/notes.txt", url: 'https://example.org/l?access_token=abcdef123456')
    store.create_knowledge(id: 'diary', title: 'SECRET-OWNER-NOTE', content: 'SECRET-OWNER-BODY')
    store.observe(id: 'seen', title: 'SECRET-OWNER-OBSERVATION', content: 'SECRET-OWNER-OBSERVATION-BODY')
    lean(store, 'lean', 'SECRET-LEAN-WORDS', %w[astronomy])
    source = store.skill_material[:own_growth_entries].first.slice('entry_id', 'sha256')
    store.accept_skill(proposal: store.propose_skill(skill: { 'name' => 'SECRET-SKILL', 'description' => 'SECRET-SKILL-TEXT',
                                                              'methods' => %w[quantify], 'focus' => [], 'source' => source })[:proposal])
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'Accepted drawing'), form: 'A mossy egg')[:proposal])
    store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'SECRET-WAITING drawing'), form: 'SECRET-WAITING-FORM')
    store
  end

  def test_the_written_page_holds_what_was_learned_and_nothing_private
    store = crafted
    result = store.status(render_html: true)
    refute result[:error], result[:error]
    assert_equal 'SECRET-DIRECTION-TEXT', result.dig(:companion, 'direction', 'text'), 'the caller still gets the full status'
    html = File.read(result.fetch(:html_path), encoding: 'UTF-8')
    payload = payload_of(html)
    assert_equal store.status_public.except('generated_at'), payload.except('generated_at')
    assert_equal ['Lichens', 'Moss holds water'], payload['cycles'].map { |c| c['title'] }, 'newest first'
    moss = payload['cycles'].last
    assert_equal ['Moss can hold many times its weight in water.', 'Peat moss holds the most.', ['https://example.com/moss'], ['botany']],
                 [moss['synthesis'], moss['finding'], moss['sources'], moss['subjects'].map { |s| s['id'] }]
    assert_equal [nil, []], payload['cycles'].first.values_at('finding', 'sources'), 'a text naming a path or a credential is left out'
    assert_equal 2, payload['withheld']
    assert_equal 'Momo', payload['name']
    assert_equal ['A mossy egg'], payload['drawings'].map { |d| d['form'] }
    %w[SECRET-TOPIC SECRET-DIRECTION SECRET-LEAN SECRET-CHAT SECRET-OWNER SECRET-SKILL SECRET-WAITING SECRET-RETRIEVAL
       SECRET-APPEARANCE SECRET-VOICE secretive astronomy access_token growth_moss Evidence\ SHA-256].each do |secret|
      refute_includes html, secret
    end
    refute_includes html, Base64.strict_encode64(Kairomone::Art::EGG.sub('Kairomone egg', 'SECRET-WAITING drawing')), 'no waiting drawing'
    [store.root, File.realpath(@host), @host, '/Users/', '/home/', 'file:'].each { |path| refute_includes html, path, 'no local path' }
  end

  def test_a_drawing_whose_markup_names_a_path_is_left_out_and_counted_once
    store = create
    leaky = Kairomone::Art::EGG.sub('<title>Kairomone egg</title>', '<title>Kairomone egg</title><desc>drawn in /Users/someone/art</desc>')
    store.accept_art(proposal: store.propose_art(svg: leaky, form: 'A leaky egg')[:proposal])
    snap = store.status_public
    assert_equal({ 'shown' => 'drawing', 'form' => 'A leaky egg' }, snap['drawing'], 'the hero shows no image for it')
    assert_equal [[true, nil]], snap['drawings'].map { |d| d.values_at('missing', 'data_uri') }, 'the history shows it as missing'
    assert_equal 1, snap['withheld'], 'one drawing, counted once though shown twice'
    html = File.read(store.status(render_html: true)[:html_path], encoding: 'UTF-8')
    refute_includes html, Base64.strict_encode64(leaky)
    refute_includes html, '/Users/'
  end
end
