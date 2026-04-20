# frozen_string_literal: true

require 'json'
require 'digest'
require 'net/http'
require 'openssl'
require 'uri'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      # Shared HTTP helpers for safe_http_* tools. Defined once; both tools
      # reopen the same module via require_relative.
      module HttpSupport
        SAFE_RESPONSE_HEADERS = %w[
          content-type content-length content-encoding
          etag last-modified cache-control date server
        ].freeze

        module_function

        # Check whether `url` matches any fnmatch pattern in `allowlist`.
        # An explicit empty allowlist denies everything.
        def url_allowed?(url, allowlist)
          patterns = Array(allowlist).map(&:to_s)
          return false if patterns.empty?
          patterns.any? { |p| File.fnmatch(p, url, File::FNM_CASEFOLD) }
        end

        # Pick the subset of response headers we are willing to surface. Keys
        # are lowercased; values are collapsed to a single string.
        def select_headers(response, whitelist = SAFE_RESPONSE_HEADERS)
          out = {}
          whitelist.each do |h|
            v = response[h]
            out[h] = v.to_s unless v.nil?
          end
          out
        end

        # Merge user-supplied headers with scoped credentials, enforcing
        # string values. Credentials win over user headers only when the user
        # did not already set that exact key (case-insensitive).
        def merge_headers(req, user_headers, credentials)
          user_keys = {}
          (user_headers || {}).each do |k, v|
            sk = k.to_s
            sv = v.to_s
            req[sk] = sv
            user_keys[sk.downcase] = true
          end
          (credentials || {}).each do |k, v|
            next if v.nil? || v.to_s.empty?
            sk = k.to_s
            next if user_keys[sk.downcase]
            req[sk] = v.to_s
          end
          req
        end

        # Issue `req` against `uri` with the given timeout. Enforces TLS for
        # https. Net::HTTP errors propagate to the caller.
        def execute(uri, req, timeout: 30)
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = timeout
          http.read_timeout = timeout
          if uri.scheme == 'https'
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          end
          http.request(req)
        end
      end

      module Tools
        # HTTP GET confined by a URL allowlist. Returns response body (truncated
        # at max_bytes), selected response headers, and sha256 post_hash.
        #
        # Typed external tool (P2.5b):
        #   * Pre-hash is nil (GET has no local state precondition).
        #   * Post-hash is sha256(body slice) — stable for WAL idempotency_check.
        #   * URL allowlist: https://* by default. http:// is rejected unless
        #     the caller supplies a matching pattern in allowed_urls.
        #   * No external gems: net/http stdlib only.
        #   * Credentials are fetched via @safety.credentials.fetch_for(name)
        #     when the daemon credentials store is wired in; absence is not
        #     an error (anonymous GETs are legitimate).
        class SafeHttpGet < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          DEFAULT_MAX_BYTES    = 1 * 1024 * 1024 # 1 MiB
          DEFAULT_TIMEOUT_SEC  = 30
          DEFAULT_ALLOWED_URLS = ['https://*'].freeze

          def name
            'safe_http_get'
          end

          def description
            'HTTP GET with URL allowlist, size cap, and timeout. Returns body ' \
              '(truncated at max_bytes), selected headers, and sha256 post_hash. ' \
              'No external gems; net/http stdlib only.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[http get network external_tool]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                url: { type: 'string', description: 'Request URL (http:// or https://)' },
                headers: {
                  type: 'object',
                  description: 'Additional request headers (values coerced to string)'
                },
                allowed_urls: {
                  type: 'array',
                  items: { type: 'string' },
                  description: "URL fnmatch patterns (default: #{DEFAULT_ALLOWED_URLS.inspect})"
                },
                max_bytes: {
                  type: 'integer',
                  description: "Max response body bytes (default: #{DEFAULT_MAX_BYTES})"
                },
                timeout: {
                  type: 'integer',
                  description: "Open + read timeout in seconds (default: #{DEFAULT_TIMEOUT_SEC})"
                }
              },
              required: ['url']
            }
          end

          def call(arguments)
            url = arguments['url'].to_s
            return json_err('url is required') if url.empty?

            allowed = Array(arguments['allowed_urls'] || DEFAULT_ALLOWED_URLS).map(&:to_s)
            unless ::KairosMcp::SkillSets::ExternalTools::HttpSupport.url_allowed?(url, allowed)
              return json_err("url not in allowlist: #{url}", allowed_urls: allowed)
            end

            begin
              uri = URI.parse(url)
            rescue URI::InvalidURIError => e
              return json_err("invalid url: #{e.message}")
            end
            return json_err("unsupported scheme: #{uri.scheme.inspect}") unless %w[http https].include?(uri.scheme)

            max_bytes = (arguments['max_bytes'] || DEFAULT_MAX_BYTES).to_i
            timeout   = (arguments['timeout']   || DEFAULT_TIMEOUT_SEC).to_i

            req = Net::HTTP::Get.new(uri.request_uri)
            ::KairosMcp::SkillSets::ExternalTools::HttpSupport
              .merge_headers(req, arguments['headers'], credentials_for_tool)

            response = ::KairosMcp::SkillSets::ExternalTools::HttpSupport
                       .execute(uri, req, timeout: timeout)

            body_full  = response.body.to_s
            truncated  = body_full.bytesize > max_bytes
            body_slice = truncated ? body_full.byteslice(0, max_bytes) : body_full
            post_hash  = Digest::SHA256.hexdigest(body_slice)

            json_ok(
              url: url,
              status_code: response.code.to_i,
              headers: ::KairosMcp::SkillSets::ExternalTools::HttpSupport.select_headers(response),
              body: body_slice,
              body_bytes: body_slice.bytesize,
              truncated: truncated,
              post_hash: post_hash,
              pre_hash: nil
            )
          rescue Net::OpenTimeout, Net::ReadTimeout => e
            json_err("timeout: #{e.class}: #{e.message}")
          rescue StandardError => e
            json_err("http_get failed: #{e.class}: #{e.message}")
          end

          private

          # Best-effort credential fetch — never raises.
          # Returns {} if the daemon credentials store is not wired into @safety.
          def credentials_for_tool
            store = @safety.respond_to?(:credentials) ? @safety.credentials : nil
            return {} if store.nil? || !store.respond_to?(:fetch_for)
            store.fetch_for(name) || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
