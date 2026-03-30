# frozen_string_literal: true

require 'cgi'
require 'erb'
require 'json'
require 'rack/utils'

module Hestia
  # WebRouter handles public (unauthenticated) web UI and JSON API.
  #
  # Routes:
  #   /place/web/*       HTML pages (skill catalog, detail, agent, about)
  #   /place/api/v1/*    JSON API (catalog, skill detail)
  #
  # Security:
  #   - No authentication required (public read-only)
  #   - IP-based rate limiting (PublicRateLimiter)
  #   - CSP headers on HTML, CORS on JSON
  #   - All output HTML-escaped via h()
  #   - Asset whitelist (no path traversal)
  class WebRouter
    VIEWS_DIR = File.join(__dir__, 'web', 'views')
    ASSETS_DIR = File.join(__dir__, 'web', 'assets')

    ALLOWED_ASSETS = %w[marketplace.css pico.min.css].freeze

    def initialize(skill_board:, agent_registry:, auditor: nil, config: {})
      @skill_board = skill_board
      @agent_registry = agent_registry
      @auditor = auditor
      @config = config
      @rate_limiter = PublicRateLimiter.new
      @presenter = PublicPresenter.new
      @import_gen = ImportCommandGenerator.new(
        place_url: config['place_url'] || 'http://localhost:8080'
      )
    end

    def call(env)
      ip = env['HTTP_X_REAL_IP'] || env['REMOTE_ADDR'] || 'unknown'
      unless @rate_limiter.allow?(ip)
        return [429, { 'content-type' => 'text/plain' }, ['Rate limit exceeded. Try again later.']]
      end

      path = env['PATH_INFO']
      method = env['REQUEST_METHOD']
      return [405, {}, ['Method Not Allowed']] unless method == 'GET'

      route_request(env, path)
    rescue => e
      $stderr.puts "[WebRouter] Error: #{e.class}: #{e.message}"
      [500, { 'content-type' => 'text/plain' }, ['Internal Server Error']]
    end

    private

    def route_request(env, path)
      case path
      # HTML pages
      when '/place/web/', '/place/web'
        handle_web_index(env)
      when %r{\A/place/web/skill/([a-zA-Z0-9_-]+__[a-zA-Z0-9_-]+)\z}
        handle_web_skill(env, $1)
      when %r{\A/place/web/agent/([a-zA-Z0-9_-]+)\z}
        handle_web_agent(env, $1)
      when '/place/web/about'
        handle_web_about(env)
      when %r{\A/place/web/assets/([a-zA-Z0-9_.-]+)\z}
        handle_web_asset($1)

      # JSON API
      when '/place/api/v1/catalog'
        handle_public_catalog(env)
      when %r{\A/place/api/v1/skill/([a-zA-Z0-9_-]+__[a-zA-Z0-9_-]+)\z}
        handle_public_skill(env, $1)

      else
        [404, { 'content-type' => 'text/html' }, ['Not Found']]
      end
    end

    # --- HTML Handlers ---

    def handle_web_index(env)
      params = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
      catalog = @skill_board.browse(
        type: 'deposited_skill',
        search: params['search'],
        tags: params['tags']&.split(','),
        limit: [params.fetch('limit', 50).to_i, 100].min
      )

      entries = catalog[:entries].map { |e| @presenter.catalog_entry(e, @auditor) }
      all_tags = @skill_board.all_unique_tags

      html = render('web_index',
        entries: entries,
        total: catalog[:total_available],
        available_tags: all_tags,
        params: params,
        place_name: place_name
      )
      html_response(200, html)
    end

    def handle_web_skill(env, deposit_id)
      parts = deposit_id.split('__', 2)
      return html_response(404, render_error('Skill not found')) unless parts.size == 2

      owner_agent_id, skill_id = parts
      preview_lines = @config.fetch('preview_lines', 20)
      skill = @skill_board.preview_skill(skill_id, owner_agent_id: owner_agent_id,
                                          first_lines: preview_lines)
      return html_response(404, render_error('Skill not found')) unless skill

      presented = @presenter.skill_detail(skill, @auditor)
      import_commands = @import_gen.commands_for(skill, deposit_id: deposit_id)

      html = render('web_skill',
        skill: presented,
        import_commands: import_commands,
        deposit_id: deposit_id,
        place_url: @config['place_url'] || 'http://localhost:8080',
        place_name: place_name
      )
      html_response(200, html)
    end

    def handle_web_agent(env, agent_id)
      agent = @agent_registry.get(agent_id)
      return html_response(404, render_error('Agent not found')) unless agent

      deposits = @skill_board.deposits_by_agent(agent_id)
      presented_deposits = deposits.map { |d| @presenter.catalog_entry(d, @auditor) }

      html = render('web_agent',
        agent: @presenter.agent_profile(agent),
        deposits: presented_deposits,
        place_name: place_name
      )
      html_response(200, html)
    end

    def handle_web_about(env)
      info = {
        name: place_name,
        place_url: @config['place_url'],
        deposit_stats: @skill_board.deposit_stats,
        agent_count: @agent_registry.count,
        audit_enabled: !!@auditor
      }
      html = render('web_about', info: info, place_name: place_name)
      html_response(200, html)
    end

    def handle_web_asset(filename)
      return [404, {}, ['Not Found']] unless ALLOWED_ASSETS.include?(filename)

      asset_path = File.join(ASSETS_DIR, filename)
      return [404, {}, ['Not Found']] unless File.exist?(asset_path)

      content_type = case File.extname(filename)
                     when '.css' then 'text/css; charset=utf-8'
                     when '.js'  then 'application/javascript; charset=utf-8'
                     else 'application/octet-stream'
                     end
      [200, {
        'content-type' => content_type,
        'cache-control' => 'public, max-age=3600'
      }, [File.read(asset_path)]]
    end

    # --- JSON API Handlers ---

    # Public-safe types only — agent/need entries are not exposed publicly
    PUBLIC_SAFE_TYPES = %w[deposited_skill].freeze

    def handle_public_catalog(env)
      params = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
      requested_type = params['type'] || 'deposited_skill'
      requested_type = 'deposited_skill' unless PUBLIC_SAFE_TYPES.include?(requested_type)
      catalog = @skill_board.browse(
        type: requested_type,
        search: params['search'],
        tags: params['tags']&.split(','),
        limit: [params.fetch('limit', 50).to_i, 100].min
      )

      entries = catalog[:entries].map { |e| @presenter.catalog_entry(e, @auditor) }

      json_response(200, {
        place_name: place_name,
        entries: entries,
        total_available: catalog[:total_available],
        returned: catalog[:returned],
        sampling: catalog[:sampling]
      })
    end

    def handle_public_skill(env, deposit_id)
      parts = deposit_id.split('__', 2)
      return json_response(404, { error: 'not_found' }) unless parts.size == 2

      owner_agent_id, skill_id = parts
      preview_lines = @config.fetch('preview_lines', 20)
      skill = @skill_board.preview_skill(skill_id, owner_agent_id: owner_agent_id,
                                          first_lines: preview_lines)
      return json_response(404, { error: 'not_found' }) unless skill

      presented = @presenter.skill_detail(skill, @auditor)
      import_commands = @import_gen.commands_for(skill, deposit_id: deposit_id)
      presented[:import_commands] = import_commands

      json_response(200, presented)
    end

    # --- Rendering ---

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def render(template_name, **locals)
      template_path = File.join(VIEWS_DIR, "#{template_name}.erb")
      layout_path = File.join(VIEWS_DIR, 'web_layout.erb')

      return "[Template not found: #{template_name}]" unless File.exist?(template_path)

      content = render_template(template_path, **locals)

      if File.exist?(layout_path)
        render_template(layout_path, content: content, **locals)
      else
        content
      end
    end

    def render_error(message)
      "<h2>#{h(message)}</h2><p><a href=\"/place/web/\">Back to catalog</a></p>"
    end

    def render_template(path, **locals)
      template = File.read(path)
      b = binding
      locals.each { |k, v| b.local_variable_set(k, v) }
      ERB.new(template, trim_mode: '-').result(b)
    end

    def place_name
      @config['name'] || 'KairosChain Meeting Place'
    end

    def html_response(status, body)
      [status, {
        'content-type' => 'text/html; charset=utf-8',
        'content-security-policy' => "default-src 'self'; style-src 'self' 'unsafe-inline'",
        'x-content-type-options' => 'nosniff',
        'x-frame-options' => 'DENY'
      }, [body]]
    end

    def json_response(status, data)
      [status, {
        'content-type' => 'application/json; charset=utf-8',
        'access-control-allow-origin' => '*',
        'access-control-allow-methods' => 'GET',
        'x-content-type-options' => 'nosniff'
      }, [JSON.generate(data)]]
    end
  end
end
