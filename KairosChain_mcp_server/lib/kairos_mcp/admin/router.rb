# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'helpers'

module KairosMcp
  module Admin
    # Router: Handles all /admin/* requests for the admin UI
    #
    # Provides lightweight session-based authentication (using existing Bearer tokens),
    # CSRF protection, and delegates to page-specific handlers.
    #
    # Pages:
    #   GET  /admin/login   - Login form
    #   POST /admin/login   - Authenticate with Bearer token
    #   GET  /admin/logout  - Clear session
    #   GET  /admin         - Dashboard
    #   GET  /admin/tokens  - Token management
    #   POST /admin/tokens/* - Token operations (htmx)
    #   GET  /admin/chain   - Chain explorer
    #   POST /admin/chain/* - Chain operations (htmx)
    #   GET  /admin/skills  - Skills viewer
    #   GET  /admin/knowledge - Knowledge viewer
    #   GET  /admin/config  - Config viewer
    #   GET  /admin/static/* - Static files (CSS, JS)
    #
    class Router
      include Helpers

      attr_reader :token_store, :authenticator

      def initialize(token_store:, authenticator:)
        @token_store = token_store
        @authenticator = authenticator
        @flash = nil
      end

      # Main entry point: route an admin request
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple [status, headers, body]
      def call(env)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO']

        # Static files: no auth required
        if path.start_with?('/admin/static/')
          filename = path.sub('/admin/static/', '')
          return serve_static(filename)
        end

        # Login page: no auth required
        case [method, path]
        when ['GET', '/admin/login']
          return handle_login_page(env)
        when ['POST', '/admin/login']
          return handle_login(env)
        end

        # All other routes require authentication
        session = get_session(env)
        unless session && session[:token]
          return redirect('/admin/login')
        end

        # Verify token is still valid
        user_info = @token_store.verify(session[:token])
        unless user_info
          return redirect_with_flash('/admin/login', 'Session expired. Please login again.')
        end

        # Verify owner role
        unless user_info[:role] == 'owner'
          return redirect_with_flash('/admin/login', 'Admin access requires owner role.')
        end

        @current_user = user_info
        @csrf_token = session[:csrf_token]

        # CSRF check for POST requests
        if method == 'POST' && !valid_csrf?(env, session)
          return html_response(403, render('layout', content: '<p>CSRF validation failed. Please try again.</p>'))
        end

        # Authenticated routes
        route(method, path, env)
      rescue StandardError => e
        $stderr.puts "[ADMIN ERROR] #{e.message}"
        $stderr.puts e.backtrace.first(5).join("\n")
        html_response(500, render('_error', layout: true, error: e.message))
      end

      private

      # -----------------------------------------------------------------------
      # Route Dispatcher
      # -----------------------------------------------------------------------

      def route(method, path, env)
        case [method, path]
        when ['GET', '/admin'], ['GET', '/admin/']
          handle_dashboard
        when ['GET', '/admin/logout']
          handle_logout

        # Token management
        when ['GET', '/admin/tokens']
          handle_tokens_page
        when ['POST', '/admin/tokens/create']
          handle_token_create(env)
        when ['POST', '/admin/tokens/revoke']
          handle_token_revoke(env)
        when ['POST', '/admin/tokens/rotate']
          handle_token_rotate(env)
        when ['GET', '/admin/tokens/list']
          handle_tokens_list_partial

        # Chain explorer
        when ['GET', '/admin/chain']
          handle_chain_page
        when ['GET', '/admin/chain/status']
          handle_chain_status_partial
        when ['GET', '/admin/chain/history']
          handle_chain_history_partial(env)
        when ['POST', '/admin/chain/verify']
          handle_chain_verify_partial

        # Skills viewer
        when ['GET', '/admin/skills']
          handle_skills_page
        when ['GET', '/admin/knowledge']
          handle_knowledge_page(env)
        when ['GET', '/admin/context']
          handle_context_page
        when ['GET', '/admin/config']
          handle_config_page
        else
          # Dynamic routes with path params
          if method == 'GET' && path.match?(%r{\A/admin/skills/dsl/.+\z})
            skill_id = path.sub('/admin/skills/dsl/', '')
            handle_skill_detail_partial(skill_id)
          elsif method == 'GET' && path.match?(%r{\A/admin/knowledge/.+\z})
            name = path.sub('/admin/knowledge/', '')
            handle_knowledge_detail_partial(name)
          elsif method == 'GET' && path.match?(%r{\A/admin/context/session/[^/]+/[^/]+\z})
            parts = path.sub('/admin/context/session/', '').split('/', 2)
            handle_context_detail_partial(parts[0], parts[1])
          elsif method == 'GET' && path.match?(%r{\A/admin/context/session/[^/]+\z})
            session_id = path.sub('/admin/context/session/', '')
            handle_context_list_partial(session_id)
          elsif method == 'GET' && path.match?(%r{\A/admin/chain/block/\d+\z})
            index = path.split('/').last.to_i
            handle_chain_block_detail_partial(index)
          else
            html_response(404, render('_error', layout: true, error: 'Page not found'))
          end
        end
      end

      # -----------------------------------------------------------------------
      # Authentication Handlers
      # -----------------------------------------------------------------------

      def handle_login_page(env)
        session = get_session(env)
        flash_msg = @flash || parse_query(env)['flash']
        html_response(200, render('login', layout: false, flash: flash_msg))
      end

      def handle_login(env)
        body = env['rack.input']&.read
        env['rack.input']&.rewind
        params = parse_form_body(body || '')
        raw_token = params['token']&.strip

        unless raw_token && !raw_token.empty?
          return html_response(200, render('login', layout: false,
                                           flash: 'Please enter a token.'))
        end

        user_info = @token_store.verify(raw_token)

        unless user_info
          return html_response(200, render('login', layout: false,
                                           flash: 'Invalid, expired, or revoked token.'))
        end

        unless user_info[:role] == 'owner'
          return html_response(200, render('login', layout: false,
                                           flash: 'Admin access requires owner role.'))
        end

        # Create session with CSRF token
        csrf_token = generate_csrf_token
        session_data = {
          token: raw_token,
          user: user_info[:user],
          role: user_info[:role],
          csrf_token: csrf_token,
          logged_in_at: Time.now.iso8601
        }

        headers = {
          'Location' => '/admin',
          'Set-Cookie' => session_cookie(session_data)
        }

        [302, headers, []]
      end

      def handle_logout
        [302, { 'Location' => '/admin/login', 'Set-Cookie' => clear_session_cookie }, []]
      end

      # -----------------------------------------------------------------------
      # Dashboard
      # -----------------------------------------------------------------------

      def handle_dashboard
        # Gather summary data from tools
        chain_data = fetch_chain_status
        token_data = @token_store.list(include_revoked: false)
        knowledge_data = fetch_knowledge_list
        skills_data = fetch_skills_list
        state_data = fetch_state_status
        context_data = fetch_context_sessions

        html_response(200, render('dashboard',
                                  chain: chain_data,
                                  tokens: token_data,
                                  knowledge: knowledge_data,
                                  skills: skills_data,
                                  state: state_data,
                                  context_sessions: context_data,
                                  current_user: @current_user))
      end

      # -----------------------------------------------------------------------
      # Token Management
      # -----------------------------------------------------------------------

      def handle_tokens_page
        tokens = @token_store.list(include_revoked: true)
        html_response(200, render('tokens', tokens: tokens, current_user: @current_user))
      end

      def handle_tokens_list_partial
        tokens = @token_store.list(include_revoked: true)
        html_response(200, render_partial('_token_list', tokens: tokens))
      end

      def handle_token_create(env)
        body = env['rack.input']&.read
        env['rack.input']&.rewind
        params = parse_form_body(body || '')

        user = params['user']&.strip
        role = params['role'] || 'member'
        expires_in = params['expires_in']
        expires_in = nil if expires_in&.empty?

        unless user && !user.empty?
          tokens = @token_store.list(include_revoked: true)
          return html_response(200, render_partial('_token_list',
                                                   tokens: tokens,
                                                   flash: 'Username is required.'))
        end

        result = @token_store.create(
          user: user,
          role: role,
          issued_by: @current_user[:user],
          expires_in: expires_in
        )

        record_admin_action('token_created', user: user, role: role)

        tokens = @token_store.list(include_revoked: true)
        html_response(200, render_partial('_token_list',
                                          tokens: tokens,
                                          new_token: result['raw_token'],
                                          new_token_user: user))
      rescue ArgumentError => e
        tokens = @token_store.list(include_revoked: true)
        html_response(200, render_partial('_token_list', tokens: tokens, flash: e.message))
      end

      def handle_token_revoke(env)
        body = env['rack.input']&.read
        env['rack.input']&.rewind
        params = parse_form_body(body || '')
        user = params['user']

        count = @token_store.revoke(user: user)
        record_admin_action('token_revoked', user: user, count: count)

        tokens = @token_store.list(include_revoked: true)
        msg = count > 0 ? "Revoked #{count} token(s) for '#{user}'." : "No active tokens for '#{user}'."
        html_response(200, render_partial('_token_list', tokens: tokens, flash: msg))
      end

      def handle_token_rotate(env)
        body = env['rack.input']&.read
        env['rack.input']&.rewind
        params = parse_form_body(body || '')
        user = params['user']

        result = @token_store.rotate(user: user, issued_by: @current_user[:user])
        record_admin_action('token_rotated', user: user)

        tokens = @token_store.list(include_revoked: true)
        html_response(200, render_partial('_token_list',
                                          tokens: tokens,
                                          new_token: result['raw_token'],
                                          new_token_user: user))
      end

      # -----------------------------------------------------------------------
      # Chain Explorer
      # -----------------------------------------------------------------------

      def handle_chain_page
        chain_data = fetch_chain_status
        html_response(200, render('chain', chain: chain_data, current_user: @current_user))
      end

      def handle_chain_status_partial
        chain_data = fetch_chain_status
        html_response(200, render_partial('_chain_status', chain: chain_data))
      end

      def handle_chain_history_partial(env)
        params = parse_query(env)
        limit = (params['limit'] || 20).to_i
        offset = (params['offset'] || 0).to_i

        chain = KairosChain::Chain.new
        blocks = chain.chain.reverse
        total = blocks.length
        paged_blocks = blocks[offset, limit] || []

        html_response(200, render_partial('_chain_blocks',
                                          blocks: paged_blocks,
                                          total: total,
                                          limit: limit,
                                          offset: offset))
      end

      def handle_chain_block_detail_partial(index)
        chain = KairosChain::Chain.new
        block = chain.chain.find { |b| b.respond_to?(:index) ? b.index == index : b['index'] == index }

        if block
          html_response(200, render_partial('_chain_detail', block: block))
        else
          html_response(200, "<p>Block ##{index} not found.</p>")
        end
      end

      def handle_chain_verify_partial
        chain = KairosChain::Chain.new
        valid = chain.valid?
        length = chain.chain.length

        result = if valid
                   "<div class='flash flash-success'>Chain is valid. #{length} blocks verified.</div>"
                 else
                   "<div class='flash flash-error'>Chain integrity check FAILED!</div>"
                 end
        html_response(200, result)
      end

      # -----------------------------------------------------------------------
      # Skills Viewer
      # -----------------------------------------------------------------------

      def handle_skills_page
        skills = fetch_skills_list
        html_response(200, render('skills', skills: skills, current_user: @current_user))
      end

      def handle_skill_detail_partial(skill_id)
        require_relative '../dsl_skills_provider'
        provider = DslSkillsProvider.new
        skill = provider.get_skill(skill_id.to_sym)

        if skill
          html_response(200, render_partial('_skill_detail', skill: skill))
        else
          html_response(200, "<p>Skill '#{h(skill_id)}' not found.</p>")
        end
      end

      # -----------------------------------------------------------------------
      # Knowledge Viewer
      # -----------------------------------------------------------------------

      def handle_knowledge_page(env)
        params = parse_query(env)
        search = params['q']
        knowledge = fetch_knowledge_list(search: search)
        html_response(200, render('knowledge', knowledge: knowledge,
                                               search: search,
                                               current_user: @current_user))
      end

      def handle_knowledge_detail_partial(name)
        require_relative '../knowledge_provider'
        provider = KnowledgeProvider.new
        entry = provider.get(name)

        if entry
          html_response(200, render_partial('_knowledge_detail', entry: entry))
        else
          html_response(200, "<p>Knowledge '#{h(name)}' not found.</p>")
        end
      end

      # -----------------------------------------------------------------------
      # Context Viewer (L2)
      # -----------------------------------------------------------------------

      def handle_context_page
        sessions = fetch_context_sessions
        html_response(200, render('context', sessions: sessions, current_user: @current_user))
      end

      def handle_context_list_partial(session_id)
        require_relative '../context_manager'
        manager = ContextManager.new
        contexts = manager.list_contexts_in_session(session_id)
        html_response(200, render_partial('_context_list',
                                          session_id: session_id,
                                          contexts: contexts))
      end

      def handle_context_detail_partial(session_id, name)
        require_relative '../context_manager'
        manager = ContextManager.new
        entry = manager.get_context(session_id, name)

        if entry
          html_response(200, render_partial('_context_detail',
                                            entry: entry,
                                            session_id: session_id))
        else
          html_response(200, "<p>Context '#{h(name)}' not found in session '#{h(session_id)}'.</p>")
        end
      end

      # -----------------------------------------------------------------------
      # Config Viewer
      # -----------------------------------------------------------------------

      def handle_config_page
        config = SkillsConfig.load
        state_data = fetch_state_status
        html_response(200, render('config', config: config,
                                            state: state_data,
                                            current_user: @current_user))
      end

      # -----------------------------------------------------------------------
      # Data Fetchers (internal tool calls)
      # -----------------------------------------------------------------------

      def fetch_chain_status
        require_relative '../kairos_chain/chain'
        chain = KairosChain::Chain.new
        backend = SkillsConfig.storage_backend

        latest = chain.latest_block
        latest_h = latest.respond_to?(:to_h) ? latest.to_h : latest

        {
          valid: chain.valid?,
          length: chain.chain.length,
          storage: { backend: backend },
          latest_block: latest_h
        }
      rescue StandardError => e
        { valid: false, length: 0, storage: { backend: 'unknown' },
          latest_block: {}, error: e.message }
      end

      def fetch_knowledge_list(search: nil)
        require_relative '../knowledge_provider'
        provider = KnowledgeProvider.new
        if search && !search.empty?
          provider.search(search)
        else
          provider.list
        end
      rescue StandardError
        []
      end

      def fetch_skills_list
        require_relative '../dsl_skills_provider'
        provider = DslSkillsProvider.new
        provider.list_skills
      rescue StandardError
        []
      end

      def fetch_state_status
        require_relative '../state_commit/commit_service'
        service = StateCommit::CommitService.new
        service.status
      rescue StandardError
        { enabled: false, has_changes: false,
          pending_changes: { total: 0 }, snapshot_count: 0 }
      end

      def fetch_context_sessions
        require_relative '../context_manager'
        manager = ContextManager.new
        manager.list_sessions
      rescue StandardError
        []
      end

      # -----------------------------------------------------------------------
      # Utility
      # -----------------------------------------------------------------------

      def redirect_with_flash(path, message)
        encoded = URI.encode_www_form_component(message)
        redirect("#{path}?flash=#{encoded}")
      end

      def record_admin_action(action, **details)
        require_relative '../action_log'
        ActionLog.record(
          action: "admin_#{action}",
          skill_id: nil,
          details: details.merge(
            admin_user: @current_user[:user],
            timestamp: Time.now.iso8601
          )
        )
      rescue StandardError
        # Don't fail the request if action log fails
      end
    end
  end
end
