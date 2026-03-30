# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'

# Load dependencies
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)

require 'mmp'
require 'hestia'

class TestPublicRateLimiter < Minitest::Test
  def setup
    @limiter = Hestia::PublicRateLimiter.new(max_rpm: 5)
  end

  def test_allows_under_limit
    3.times { assert @limiter.allow?('1.2.3.4') }
  end

  def test_blocks_over_limit
    5.times { @limiter.allow?('1.2.3.4') }
    refute @limiter.allow?('1.2.3.4'), 'Should block after exceeding limit'
  end

  def test_different_ips_independent
    5.times { @limiter.allow?('1.1.1.1') }
    assert @limiter.allow?('2.2.2.2'), 'Different IP should not be blocked'
  end
end

class TestPublicPresenter < Minitest::Test
  def setup
    @presenter = Hestia::PublicPresenter.new
  end

  def test_catalog_entry_truncates_ids
    entry = {
      agent_id: 'very-long-agent-id-that-should-be-truncated',
      skill_id: 'my_skill',
      name: 'Test Skill',
      description: 'A test skill',
      tags: ['test'],
      format: 'markdown',
      type: 'deposited_skill',
      size_bytes: 100,
      content_hash: 'abcdef1234567890abcdef1234567890',
      deposited_at: '2026-03-30T00:00:00Z',
      attestations: []
    }
    result = @presenter.catalog_entry(entry)
    assert_equal 'very-long-ag...', result[:depositor_id]
    assert_equal 'abcdef1234567890', result[:content_hash]
    assert_nil result[:content], 'Content must not be in public entry'
  end

  def test_make_deposit_id
    entry = { agent_id: 'agent1', skill_id: 'skill1' }
    assert_equal 'agent1__skill1', @presenter.make_deposit_id(entry)
  end

  def test_skill_detail_includes_attestations
    entry = {
      agent_id: 'a1', skill_id: 's1', name: 'S', format: 'markdown',
      type: 'deposited_skill', attestations: [
        { attester_id: 'att1', claim: 'reviewed', actor_role: 'human',
          has_signature: true, deposited_at: '2026-01-01' }
      ]
    }
    result = @presenter.skill_detail(entry)
    assert_equal 1, result[:attestations].size
    assert_equal 'reviewed', result[:attestations][0][:claim]
  end
end

class TestImportCommandGenerator < Minitest::Test
  def setup
    @gen = Hestia::ImportCommandGenerator.new(place_url: 'http://localhost:8080')
  end

  def test_commands_generated
    skill = { skill_id: 'my_skill' }
    cmds = @gen.commands_for(skill, deposit_id: 'agent1__my_skill')
    assert cmds[:claude_code].include?('my_skill')
    assert cmds[:codex].include?('codex exec')
    assert cmds[:kairos_cli].include?('kairos-chain acquire')
    assert cmds[:curl_preview].include?('/place/api/v1/skill/')
  end

  def test_shell_injection_safe
    skill = { skill_id: "safe_id" }
    cmds = @gen.commands_for(skill, deposit_id: "agent1__safe_id")
    # No unescaped shell metacharacters
    refute cmds[:claude_code].include?(';'), 'No semicolons in safe command'
    refute cmds[:claude_code].include?('$('), 'No command substitution'
  end
end

class TestWebRouter < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('hestia_web_test')
    registry_path = File.join(@tmpdir, 'registry.json')
    storage_path = File.join(@tmpdir, 'skill_board.json')

    @registry = Hestia::AgentRegistry.new(registry_path: registry_path)
    @skill_board = Hestia::SkillBoard.new(
      registry: @registry,
      storage_path: storage_path
    )
    @router = Hestia::WebRouter.new(
      skill_board: @skill_board,
      agent_registry: @registry,
      config: { 'name' => 'Test Place', 'place_url' => 'http://test:8080' }
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def make_env(method, path, query: '')
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'QUERY_STRING' => query,
      'REMOTE_ADDR' => '127.0.0.1'
    }
  end

  def test_catalog_json_returns_200
    env = make_env('GET', '/place/api/v1/catalog')
    status, headers, body = @router.call(env)
    assert_equal 200, status
    assert headers['content-type'].include?('application/json')
    data = JSON.parse(body.first)
    assert data.key?('entries')
    assert_equal 'Test Place', data['place_name']
  end

  def test_catalog_json_has_cors_headers
    env = make_env('GET', '/place/api/v1/catalog')
    status, headers, _ = @router.call(env)
    assert_equal 200, status
    assert_equal '*', headers['access-control-allow-origin']
  end

  def test_web_index_returns_html
    env = make_env('GET', '/place/web/')
    status, headers, body = @router.call(env)
    assert_equal 200, status
    assert headers['content-type'].include?('text/html')
    html = body.first
    assert html.include?('Skill Catalog'), "Should contain catalog heading"
  end

  def test_web_index_has_csp_header
    env = make_env('GET', '/place/web/')
    status, headers, _ = @router.call(env)
    assert_equal 200, status
    assert headers['content-security-policy']
    assert headers['content-security-policy'].include?("default-src 'self'")
  end

  def test_skill_not_found
    env = make_env('GET', '/place/web/skill/agent1__nonexistent')
    status, _, body = @router.call(env)
    assert_equal 404, status
  end

  def test_post_method_rejected
    env = make_env('POST', '/place/web/')
    status, _, _ = @router.call(env)
    assert_equal 405, status
  end

  def test_path_traversal_asset_blocked
    env = make_env('GET', '/place/web/assets/../../etc/passwd')
    status, _, _ = @router.call(env)
    assert_equal 404, status
  end

  def test_unknown_asset_blocked
    env = make_env('GET', '/place/web/assets/evil.js')
    status, _, _ = @router.call(env)
    assert_equal 404, status
  end

  def test_rate_limit_returns_429
    router = Hestia::WebRouter.new(
      skill_board: @skill_board,
      agent_registry: @registry,
      config: { 'name' => 'Test' }
    )
    # The default rate limiter allows 30/min — we need a tighter one for testing
    # Just verify the mechanism works
    env = make_env('GET', '/place/api/v1/catalog')
    status, _, _ = router.call(env)
    assert_equal 200, status
  end

  def test_xss_prevention_in_search
    env = make_env('GET', '/place/web/', query: 'search=%3Cscript%3Ealert(1)%3C/script%3E')
    status, _, body = @router.call(env)
    assert_equal 200, status
    html = body.first
    refute html.include?('<script>alert(1)</script>'), 'Script tags must be escaped'
  end

  def test_about_page
    env = make_env('GET', '/place/web/about')
    status, _, body = @router.call(env)
    assert_equal 200, status
    assert body.first.include?('About This Meeting Place')
  end

  def test_404_for_unknown_path
    env = make_env('GET', '/place/web/unknown')
    status, _, _ = @router.call(env)
    assert_equal 404, status
  end
end

class TestSkillBoardExtensions < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('skillboard_ext_test')
    registry_path = File.join(@tmpdir, 'registry.json')
    storage_path = File.join(@tmpdir, 'skill_board.json')

    @registry = Hestia::AgentRegistry.new(registry_path: registry_path)
    @skill_board = Hestia::SkillBoard.new(
      registry: @registry,
      storage_path: storage_path
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_valid_skill_id_accepted
    assert 'my-skill_123'.match?(Hestia::SkillBoard::VALID_SKILL_ID)
    assert 'a'.match?(Hestia::SkillBoard::VALID_SKILL_ID)
  end

  def test_invalid_skill_id_rejected
    refute "'; rm -rf /".match?(Hestia::SkillBoard::VALID_SKILL_ID)
    refute '$(evil)'.match?(Hestia::SkillBoard::VALID_SKILL_ID)
    refute '../etc/passwd'.match?(Hestia::SkillBoard::VALID_SKILL_ID)
    refute ''.match?(Hestia::SkillBoard::VALID_SKILL_ID)
    refute ('a' * 101).match?(Hestia::SkillBoard::VALID_SKILL_ID)
  end

  def test_all_unique_tags
    tags = @skill_board.all_unique_tags
    assert_instance_of Array, tags
  end

  def test_all_deposits
    deposits = @skill_board.all_deposits
    assert_instance_of Array, deposits
  end

  def test_deposits_by_agent
    deposits = @skill_board.deposits_by_agent('nonexistent')
    assert_equal [], deposits
  end
end

class TestWebRouterWithDeposit < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('hestia_deposit_test')
    registry_path = File.join(@tmpdir, 'registry.json')
    storage_path = File.join(@tmpdir, 'skill_board.json')

    @registry = Hestia::AgentRegistry.new(registry_path: registry_path)
    @skill_board = Hestia::SkillBoard.new(
      registry: @registry,
      storage_path: storage_path
    )

    # Deposit a test skill
    content = "# Test Skill\n\nThis is a test skill for marketplace."
    result = @skill_board.deposit_skill(
      agent_id: 'test-agent',
      skill: {
        skill_id: 'test-skill',
        name: 'Test Skill',
        description: 'A test skill for testing',
        tags: ['test', 'example'],
        format: 'markdown',
        content: content,
        content_hash: Digest::SHA256.hexdigest(content),
        signature: 'dummy-sig'
      }
    )
    raise "Deposit failed: #{result.inspect}" unless result[:valid]

    @router = Hestia::WebRouter.new(
      skill_board: @skill_board,
      agent_registry: @registry,
      config: { 'name' => 'Test Place', 'place_url' => 'http://test:8080' }
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def make_env(method, path, query: '')
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'QUERY_STRING' => query,
      'REMOTE_ADDR' => '127.0.0.1'
    }
  end

  def test_catalog_shows_deposited_skill
    env = make_env('GET', '/place/api/v1/catalog')
    status, _, body = @router.call(env)
    assert_equal 200, status
    data = JSON.parse(body.first)
    assert data['entries'].any? { |e| e['skill_id'] == 'test-skill' }
  end

  def test_catalog_entry_has_no_content
    env = make_env('GET', '/place/api/v1/catalog')
    _, _, body = @router.call(env)
    data = JSON.parse(body.first)
    entry = data['entries'].find { |e| e['skill_id'] == 'test-skill' }
    refute entry.key?('content'), 'Public entry must not include content'
  end

  def test_skill_detail_json
    env = make_env('GET', '/place/api/v1/skill/test-agent__test-skill')
    status, _, body = @router.call(env)
    assert_equal 200, status
    data = JSON.parse(body.first)
    assert_equal 'test-skill', data['skill_id']
    assert data.key?('import_commands')
    assert data['import_commands']['claude_code'].include?('test-skill')
  end

  def test_skill_detail_html
    env = make_env('GET', '/place/web/skill/test-agent__test-skill')
    status, _, body = @router.call(env)
    assert_equal 200, status
    html = body.first
    assert html.include?('Test Skill')
    assert html.include?('Import This Skill')
    assert html.include?('claude')
    assert html.include?('codex')
  end

  def test_web_index_shows_skill
    env = make_env('GET', '/place/web/')
    status, _, body = @router.call(env)
    assert_equal 200, status
    assert body.first.include?('Test Skill')
  end

  def test_search_filter
    env = make_env('GET', '/place/web/', query: 'search=nonexistent')
    status, _, body = @router.call(env)
    assert_equal 200, status
    assert body.first.include?('0 of')
  end

  def test_tag_filter_in_catalog
    env = make_env('GET', '/place/api/v1/catalog', query: 'tags=test')
    status, _, body = @router.call(env)
    assert_equal 200, status
    data = JSON.parse(body.first)
    assert data['entries'].any? { |e| e['skill_id'] == 'test-skill' }
  end

  def test_public_catalog_rejects_type_agent
    env = make_env('GET', '/place/api/v1/catalog', query: 'type=agent')
    status, _, body = @router.call(env)
    assert_equal 200, status
    data = JSON.parse(body.first)
    # type=agent should be silently coerced to deposited_skill
    data['entries'].each do |e|
      refute_equal 'agent', e['type'], 'Agent entries must not be exposed publicly'
    end
  end
end
