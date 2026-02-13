# frozen_string_literal: true

require 'erb'
require 'securerandom'
require 'digest'

module KairosMcp
  module Admin
    # Helpers: ERB template helpers for the admin UI
    #
    # Provides HTML escaping, template rendering, flash messages,
    # CSRF protection, and session management utilities.
    #
    module Helpers
      VIEWS_DIR = File.expand_path('views', __dir__)
      STATIC_DIR = File.expand_path('static', __dir__)

      # HTML-escape a string to prevent XSS
      #
      # @param text [String, nil] Raw text
      # @return [String] HTML-escaped text
      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      # Render an ERB template
      #
      # @param template_name [String] Template file name (without .erb)
      # @param layout [Boolean] Whether to wrap in layout
      # @param locals [Hash] Local variables for the template
      # @return [String] Rendered HTML
      def render(template_name, layout: true, **locals)
        template_path = File.join(VIEWS_DIR, "#{template_name}.erb")
        template = ERB.new(File.read(template_path), trim_mode: '-')

        # Make locals available as instance variables for ERB binding
        b = binding
        locals.each { |k, v| b.local_variable_set(k, v) }

        content = template.result(b)

        if layout
          render_layout(content)
        else
          content
        end
      end

      # Render a partial (no layout)
      #
      # @param partial_name [String] Partial file name (without .erb, with _prefix)
      # @param locals [Hash] Local variables
      # @return [String] Rendered HTML fragment
      def render_partial(partial_name, **locals)
        render("partials/#{partial_name}", layout: false, **locals)
      end

      # Wrap content in the shared layout
      #
      # @param content [String] Page content HTML
      # @return [String] Full HTML page
      def render_layout(content)
        @content = content
        layout_path = File.join(VIEWS_DIR, 'layout.erb')
        layout_template = ERB.new(File.read(layout_path), trim_mode: '-')
        layout_template.result(binding)
      end

      # Generate an HTML response
      #
      # @param status [Integer] HTTP status code
      # @param body [String] HTML body
      # @return [Array] Rack response triple
      def html_response(status, body)
        [status, { 'Content-Type' => 'text/html; charset=utf-8' }, [body]]
      end

      # Redirect response
      #
      # @param path [String] Redirect target
      # @return [Array] Rack response triple
      def redirect(path)
        [302, { 'Location' => path }, []]
      end

      # Serve a static file
      #
      # @param filename [String] File name in static/ directory
      # @return [Array] Rack response triple
      def serve_static(filename)
        filepath = File.join(STATIC_DIR, filename)
        return [404, {}, ['Not found']] unless File.exist?(filepath)

        content_type = case File.extname(filename)
                       when '.css' then 'text/css'
                       when '.js'  then 'application/javascript'
                       when '.png' then 'image/png'
                       when '.svg' then 'image/svg+xml'
                       else 'application/octet-stream'
                       end

        [200, { 'Content-Type' => content_type, 'Cache-Control' => 'public, max-age=3600' },
         [File.read(filepath)]]
      end

      # -----------------------------------------------------------------------
      # Session Management
      # -----------------------------------------------------------------------

      SESSION_COOKIE = 'kairos_admin_session'
      SESSION_SECRET = ENV['KAIROS_SESSION_SECRET'] || SecureRandom.hex(32)

      # Encode a session value into a signed cookie
      #
      # @param data [Hash] Session data
      # @return [String] Signed cookie value
      def encode_session(data)
        payload = JSON.generate(data)
        encoded = [payload].pack('m0') # Base64 (no newlines)
        signature = sign(encoded)
        "#{encoded}--#{signature}"
      end

      # Decode and verify a signed session cookie
      #
      # @param cookie_value [String] Raw cookie value
      # @return [Hash, nil] Session data or nil if invalid
      def decode_session(cookie_value)
        return nil unless cookie_value

        encoded, signature = cookie_value.split('--', 2)
        return nil unless encoded && signature
        return nil unless secure_compare(sign(encoded), signature)

        payload = encoded.unpack1('m0')
        JSON.parse(payload, symbolize_names: true)
      rescue StandardError
        nil
      end

      # Extract session from Rack env
      #
      # @param env [Hash] Rack environment
      # @return [Hash, nil] Session data
      def get_session(env)
        cookies = parse_cookies(env)
        cookie_value = cookies[SESSION_COOKIE]
        decode_session(cookie_value)
      end

      # Build Set-Cookie header for session
      #
      # @param data [Hash] Session data
      # @return [String] Set-Cookie header value
      def session_cookie(data)
        value = encode_session(data)
        "#{SESSION_COOKIE}=#{value}; Path=/admin; HttpOnly; SameSite=Strict"
      end

      # Build Set-Cookie header to clear session
      #
      # @return [String] Set-Cookie header value
      def clear_session_cookie
        "#{SESSION_COOKIE}=; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=0"
      end

      # -----------------------------------------------------------------------
      # CSRF Protection
      # -----------------------------------------------------------------------

      # Generate a CSRF token
      #
      # @return [String] CSRF token
      def generate_csrf_token
        SecureRandom.hex(32)
      end

      # Verify a CSRF token from form submission
      #
      # @param env [Hash] Rack environment
      # @param session [Hash] Current session
      # @return [Boolean] Whether CSRF token is valid
      def valid_csrf?(env, session)
        body = env['rack.input']&.read
        env['rack.input']&.rewind
        return false unless body

        params = parse_form_body(body)
        submitted_token = params['_csrf']
        session_token = session&.dig(:csrf_token)

        return false unless submitted_token && session_token

        secure_compare(submitted_token, session_token)
      end

      # -----------------------------------------------------------------------
      # Form/Cookie Parsing
      # -----------------------------------------------------------------------

      # Parse cookies from Rack env
      #
      # @param env [Hash] Rack environment
      # @return [Hash] Cookie name → value
      def parse_cookies(env)
        cookie_header = env['HTTP_COOKIE'] || ''
        cookie_header.split(';').each_with_object({}) do |pair, hash|
          key, value = pair.strip.split('=', 2)
          hash[key] = value if key
        end
      end

      # Parse URL-encoded form body
      #
      # @param body [String] Form body
      # @return [Hash] Parameter name → value
      def parse_form_body(body)
        body.split('&').each_with_object({}) do |pair, hash|
          key, value = pair.split('=', 2)
          hash[URI.decode_www_form_component(key)] = URI.decode_www_form_component(value || '')
        end
      end

      # Parse query string
      #
      # @param env [Hash] Rack environment
      # @return [Hash] Query parameters
      def parse_query(env)
        qs = env['QUERY_STRING'] || ''
        parse_form_body(qs)
      end

      private

      def sign(data)
        Digest::SHA256.hexdigest("#{data}#{SESSION_SECRET}")
      end

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        l = a.unpack("C#{a.bytesize}")
        r = b.unpack("C#{b.bytesize}")
        result = 0
        l.zip(r) { |x, y| result |= x ^ y }
        result.zero?
      end
    end
  end
end
