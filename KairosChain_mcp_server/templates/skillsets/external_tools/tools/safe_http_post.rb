# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'net/http'
require 'openssl'
require 'uri'
require_relative '../lib/external_tools'
# HttpSupport is defined in safe_http_get.rb. Loading it here keeps the two
# tools usable in either load order.
require_relative 'safe_http_get'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # HTTP POST with auto-injected Idempotency-Key header. Returns response
        # body (truncated at max_bytes), selected response headers, sha256
        # post_hash of the response body, and the Idempotency-Key that was used.
        #
        # Typed external tool (P2.5b):
        #   * Idempotency-Key: taken from arguments['idempotency_key'] or
        #     the invocation context's idem_key; otherwise a UUID is generated.
        #     Always surfaced in the response for WAL replay.
        #   * Pre-hash = nil (POST has no local state precondition).
        #   * Post-hash = sha256(response body slice).
        #   * URL allowlist: https://* by default. http:// rejected unless
        #     allowed_urls explicitly permits it.
        #   * Body encodings: 'json' (default, with Content-Type) or 'form'
        #     (URL-encoded). A pre-serialized raw_body string is also accepted.
        class SafeHttpPost < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          DEFAULT_MAX_BYTES    = 1 * 1024 * 1024 # 1 MiB
          DEFAULT_TIMEOUT_SEC  = 30
          DEFAULT_ALLOWED_URLS = ['https://*'].freeze
          IDEM_HEADER          = 'Idempotency-Key'

          def name
            'safe_http_post'
          end

          def description
            'HTTP POST with auto-injected Idempotency-Key, URL allowlist, ' \
              'size cap, and timeout. Returns body (truncated), selected ' \
              'headers, sha256 post_hash, and the idempotency_key used. ' \
              'No external gems; net/http stdlib only.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[http post network external_tool idempotent]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                url: { type: 'string', description: 'Request URL (http:// or https://)' },
                body: {
                  description: 'Request body. Hash is serialized per body_format; ' \
                                'string is sent raw if raw_body=true.'
                },
                body_format: {
                  type: 'string',
                  enum: %w[json form raw],
                  description: "Body encoding: 'json' (default), 'form', or 'raw'"
                },
                raw_body: { type: 'boolean', description: "Send body as-is (string) with no serialization" },
                headers: { type: 'object', description: 'Additional request headers (values coerced to string)' },
                idempotency_key: { type: 'string', description: 'Override idempotency key (defaults to ctx idem_key or UUID)' },
                allowed_urls: {
                  type: 'array',
                  items: { type: 'string' },
                  description: "URL fnmatch patterns (default: #{DEFAULT_ALLOWED_URLS.inspect})"
                },
                max_bytes: { type: 'integer', description: "Max response body bytes (default: #{DEFAULT_MAX_BYTES})" },
                timeout: { type: 'integer', description: "Open + read timeout in seconds (default: #{DEFAULT_TIMEOUT_SEC})" }
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

            body_str, default_ct = build_body(arguments)
            return json_err(body_str[:error]) if body_str.is_a?(Hash) && body_str[:error]

            idem_key = resolve_idem_key(arguments)

            req = Net::HTTP::Post.new(uri.request_uri)
            req[IDEM_HEADER] = idem_key
            req['Content-Type'] = default_ct if default_ct
            req.body = body_str

            # User headers may override Content-Type (e.g., custom media types)
            # but Idempotency-Key is enforced post-merge so the caller cannot
            # silently suppress it.
            ::KairosMcp::SkillSets::ExternalTools::HttpSupport
              .merge_headers(req, arguments['headers'], credentials_for_tool)
            req[IDEM_HEADER] = idem_key

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
              pre_hash: nil,
              idempotency_key: idem_key
            )
          rescue Net::OpenTimeout, Net::ReadTimeout => e
            json_err("timeout: #{e.class}: #{e.message}")
          rescue StandardError => e
            json_err("http_post failed: #{e.class}: #{e.message}")
          end

          private

          # Build (body_string, default_content_type) from arguments.
          # Returns ({error: msg}, nil) on invalid input.
          def build_body(arguments)
            raw_flag = arguments['raw_body'] == true
            format   = (arguments['body_format'] || (raw_flag ? 'raw' : 'json')).to_s
            body     = arguments['body']

            case format
            when 'raw'
              return [body.to_s, nil] if body.is_a?(String) || body.nil?
              [{ error: 'raw body_format requires string body' }, nil]
            when 'form'
              return [{ error: 'form body_format requires hash body' }, nil] unless body.is_a?(Hash)
              encoded = URI.encode_www_form(body.map { |k, v| [k.to_s, v.to_s] })
              [encoded, 'application/x-www-form-urlencoded']
            when 'json'
              serialized = body.nil? ? '' : JSON.generate(body)
              [serialized, 'application/json']
            else
              [{ error: "unknown body_format: #{format}" }, nil]
            end
          end

          # Pick an idempotency key. Priority:
          #   1. arguments['idempotency_key'] (explicit override)
          #   2. invocation context idem_key (via @safety)
          #   3. fresh UUID
          def resolve_idem_key(arguments)
            explicit = arguments['idempotency_key']
            return explicit.to_s if explicit.is_a?(String) && !explicit.empty?

            ctx_key = nil
            begin
              if @safety.respond_to?(:invocation_context)
                ctx = @safety.invocation_context
                ctx_key = ctx.idem_key if ctx.respond_to?(:idem_key)
              elsif @safety.respond_to?(:idem_key)
                ctx_key = @safety.idem_key
              end
            rescue StandardError
              ctx_key = nil
            end
            return ctx_key.to_s if ctx_key.is_a?(String) && !ctx_key.empty?

            SecureRandom.uuid
          end

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
