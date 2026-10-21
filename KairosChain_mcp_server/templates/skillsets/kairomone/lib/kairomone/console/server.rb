# frozen_string_literal: true

require 'uri'
begin
  require 'webrick'
rescue LoadError
  nil # Server#start refuses with the install command
end

module Kairomone
  module Console
    # The two secrets. The bootstrap travels only in the fragment of the URL
    # printed at the console's terminal, is spent on first use and expires;
    # the session secret it buys lives in the page's sessionStorage and request
    # headers. Neither is written to a file, an argument, the environment or
    # anything the child receives. Issuing a bootstrap revokes the session.
    class Secret
      # The default clock is monotonic, so a wall-clock step back (NTP, a manual
      # change) cannot revive a URL whose lifetime has passed.
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, bootstrap_ttl: 600)
        @clock = clock
        @ttl = bootstrap_ttl
        @lock = Mutex.new
        @bootstrap = @issued_at = @session = nil
      end

      def issue_bootstrap
        @lock.synchronize do
          @session = nil
          @issued_at = @clock.call
          @bootstrap = SecureRandom.hex(32)
        end
      end

      # A wrong value leaves the bootstrap in place; the right one is spent
      # whether or not it has expired.
      def exchange(bootstrap)
        @lock.synchronize do
          next nil unless @bootstrap && bootstrap.is_a?(String) && OpenSSL.secure_compare(bootstrap, @bootstrap)
          expired = (@clock.call - @issued_at) >= @ttl
          @bootstrap = nil
          next nil if expired
          @session = SecureRandom.hex(32)
        end
      end

      def valid_session?(value)
        current = @lock.synchronize { @session }
        !current.nil? && value.is_a?(String) && OpenSSL.secure_compare(value, current)
      end
    end

    # Loopback HTTP between the owner's page and the Session. Every request
    # must name this exact host and port, every POST this exact origin, and
    # everything but the page itself and the bootstrap exchange needs the
    # session secret. No cookie and no CORS header is ever sent.
    class Server
      BODY_LIMIT = 64 * 1024
      # A refused body up to this size is read and dropped before the answer,
      # so the client can read the answer (closing on unread data resets).
      DRAIN_LIMIT = 1024 * 1024
      POLL_SECONDS = 25
      CHUNK_BYTES = 4 * 1024 * 1024
      ROUTES = { '/events' => 'GET', '/status' => 'GET', '/message' => 'POST', '/mode' => 'POST',
                 '/interrupt' => 'POST', '/stop' => 'POST', '/' => 'GET', '/session' => 'POST' }.freeze
      PERMISSION_PREFIX = '/permission/'
      class BodyTooLarge < StandardError; end
      class BadRequest < StandardError; end

      if defined?(::WEBrick::HTTPServer)
        # WEBrick answers some requests without asking the console: ones it
        # cannot parse (a path that climbs above the root once decoded, an
        # over-long URI or header block, a malformed request line) with its
        # own HTML page, and `OPTIONS *` with an Allow list. This listener
        # hands every parsed request to the console, so the Host, Origin and
        # session rules see them all, and every response it builds carries
        # the contract headers. WEBrick's own error answers become the same
        # fixed JSON the console sends, naming neither the machine nor the
        # server software.
        class Listener < ::WEBrick::HTTPServer
          def initialize(config, console:, headers:)
            @console = console
            @console_headers = headers
            super(config)
          end

          def service(req, res) = @console.serve(req, res)
          def create_response(config) = Response.new(config, @console_headers)
        end

        class Response < ::WEBrick::HTTPResponse
          def initialize(config, headers)
            super(config)
            headers.each { |name, value| self[name] = value }
          end

          # WEBrick's set_error calls this in place of writing its own page.
          def create_error_page
            word = ::WEBrick::HTTPStatus.reason_phrase(status).to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
            self['Content-Type'] = 'application/json; charset=utf-8'
            self.body = JSON.generate('error' => word.empty? ? 'refused' : word)
          end
        end
      end

      attr_reader :port

      def initialize(session:, secret:, status_reader:, page_path:, port: 0, host: '127.0.0.1', on_stop: nil, poll_seconds: POLL_SECONDS)
        raise ArgumentError, 'The console listens on 127.0.0.1 only' unless host == '127.0.0.1'
        @session = session
        @secret = secret
        @status_reader = status_reader
        @requested_port = port
        @host = host
        @on_stop = on_stop
        @poll_seconds = poll_seconds
        @stopping = false
        @page, csp = load_page(page_path)
        @headers = { 'Content-Security-Policy' => csp, 'X-Frame-Options' => 'DENY', 'Referrer-Policy' => 'no-referrer',
                     'Cache-Control' => 'no-store', 'X-Content-Type-Options' => 'nosniff',
                     'Cross-Origin-Resource-Policy' => 'same-origin' }.freeze
      end

      def start
        raise Refusal, 'WEBrick is not installed for this Ruby; install it with: gem install webrick' unless defined?(Listener)
        raise Error, 'The server was already started' if @server
        @server = Listener.new({ BindAddress: @host, Port: @requested_port, DoNotReverseLookup: true,
                                 ServerSoftware: 'kairomone-console',
                                 Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL), AccessLog: [] },
                               console: self, headers: @headers)
        @port = @server.config[:Port]
        @thread = Thread.new { @server.start }
        deadline = monotonic + 5
        sleep 0.01 until @server.status == :Running || monotonic > deadline
        self
      rescue Errno::EADDRINUSE, Errno::EACCES, Errno::EADDRNOTAVAIL => e
        raise Refusal, "Cannot listen on #{@host}:#{@requested_port} (#{e.class})"
      end

      def origin
        "http://#{@host}:#{@port}"
      end

      def shutdown
        @stopping = true
        @server&.shutdown
        @thread&.join(5)
        nil
      end

      # Called by the listener for every request WEBrick has parsed.
      def serve(req, res)
        handle(req, res)
      ensure
        drain(req) if req.request_method == 'POST' && res.status.to_i >= 400
      end

      private

      def handle(req, res)
        secure_headers(res)
        return reply(res, 403, 'error' => 'forbidden') unless req['host'] == "#{@host}:#{@port}"
        origin = req['origin']
        return reply(res, 403, 'error' => 'forbidden') if (origin && origin != self.origin) || (req.request_method == 'POST' && origin.nil?)
        method = req.request_method
        # Routes are matched on the path as it was sent, before WEBrick
        # decodes "%2F" and folds dot segments, so a request id that holds
        # "/" or ".." can name no other request and no other route. `OPTIONS
        # *` and CONNECT have no path and match no route.
        path = req.request_uri&.path
        return page(res) if method == 'GET' && path == '/'
        return bootstrap(req, res) if method == 'POST' && path == '/session'
        return reply(res, 403, 'error' => 'forbidden') unless @secret.valid_session?(req['x-kairomone-session'])
        route(method, path, req, res)
      rescue BodyTooLarge
        reply(res, 413, 'error' => 'too_large')
      rescue BadRequest
        reply(res, 400, 'error' => 'bad_request')
      rescue StandardError
        reply(res, 500, 'error' => 'internal')
      end

      def route(method, path, req, res)
        answer = path.is_a?(String) && path.start_with?(PERMISSION_PREFIX)
        expected = answer ? 'POST' : ROUTES[path]
        return reply(res, 404, 'error' => 'not_found') unless expected
        return reply(res, 405, 'error' => 'method_not_allowed') unless method == expected
        return permission(path.delete_prefix(PERMISSION_PREFIX), req, res) if answer
        case path
        when '/events' then events(req, res)
        when '/status' then status(res)
        when '/message' then message(json_body(req), res)
        when '/mode' then mode(json_body(req), res)
        when '/interrupt' then read_body(req) && interrupt(res)
        when '/stop' then read_body(req) && stop(res)
        else reply(res, 404, 'error' => 'not_found')
        end
      end

      def page(res)
        res.status = 200
        res['Content-Type'] = 'text/html; charset=utf-8'
        res.body = @page
      end

      def bootstrap(req, res)
        read_body(req)
        session = @secret.exchange(req['x-kairomone-bootstrap'])
        return reply(res, 403, 'error' => 'forbidden') unless session
        reply(res, 200, 'session' => session)
      end

      # Long poll: waits up to poll_seconds for events after the given number.
      # A large backlog comes back in parts; "last" is the number to ask after
      # next, so a connection that starts from 0 receives everything.
      def events(req, res)
        raw = req.query['after']&.to_s || '0'
        raise BadRequest unless /\A\d{1,15}\z/.match?(raw)
        after = raw.to_i
        deadline = monotonic + @poll_seconds
        list = @session.events_after(after)
        while list.empty? && !@stopping && monotonic < deadline
          sleep 0.1
          list = @session.events_after(after)
        end
        # The session is checked again after the events are read, so every
        # event returned was emitted while it was still valid: a page whose
        # session was revoked while it waited (Enter at the console's
        # terminal) receives nothing emitted after the revocation.
        return reply(res, 403, 'error' => 'forbidden') unless @secret.valid_session?(req['x-kairomone-session'])
        parts = []
        bytes = 0
        last = nil
        list.each do |event|
          json = JSON.generate(event, max_nesting: false)
          break if !parts.empty? && bytes + json.bytesize > CHUNK_BYTES
          parts << json
          bytes += json.bytesize
          last = event['seq']
        end
        last ||= @session.last_seq
        res.status = 200
        res['Content-Type'] = 'application/json; charset=utf-8'
        res.body = "{\"events\":[#{parts.join(',')}],\"last\":#{Integer(last)}}"
      end

      def status(res)
        body = begin
          @status_reader.call
        rescue StandardError
          return reply(res, 500, 'error' => 'status_unavailable')
        end
        reply(res, 200, body)
      end

      # Text and mode values go to the Session as given: its refusal reasons
      # (409) cover them, so the page sees one vocabulary.
      def message(data, res)
        result = @session.send_message(data['text'])
        return reply(res, 202, 'accepted' => true) if result == :accepted
        reply(res, 409, 'error' => 'not_accepting', 'reason' => Array(result)[1])
      end

      # The id is the single path segment after /permission/ as the page sent
      # it (encodeURIComponent), decoded once.
      def permission(raw, req, res)
        data = json_body(req)
        id = request_id(raw)
        raise BadRequest unless id
        raise BadRequest unless %w[allow deny].include?(data['decision'])
        case @session.answer_permission(id, data['decision'])
        when :ok then reply(res, 200, 'ok' => true)
        when :answered then reply(res, 409, 'error' => 'answered')
        when :not_allowable then reply(res, 409, 'error' => 'not_allowable')
        else reply(res, 404, 'error' => 'not_found')
        end
      end

      def request_id(raw)
        return nil if raw.empty? || raw.include?('/')
        id = URI.decode_uri_component(raw)
        id.valid_encoding? && !id.empty? ? id : nil
      rescue ArgumentError
        nil
      end

      def mode(data, res)
        result = @session.request_mode(data['mode'])
        return reply(res, 202, 'sent' => true) if result == :sent
        reply(res, 409, 'error' => 'refused', 'reason' => Array(result)[1])
      end

      def interrupt(res)
        @session.interrupt!
        reply(res, 202, 'sent' => true)
      end

      # The session is stopped before answering (pending requests denied,
      # turn interrupted); the rest of the shutdown runs after the reply.
      def stop(res)
        @session.stop!(by: :page)
        Thread.new { @on_stop.call(:page) } if @on_stop
        reply(res, 202, 'stopping' => true)
      end

      def json_body(req)
        data = JSON.parse(read_body(req))
        raise BadRequest unless data.is_a?(Hash)
        data
      rescue JSON::ParserError
        raise BadRequest
      end

      def read_body(req)
        length = req['content-length']
        raise BodyTooLarge if length && length.to_i > BODY_LIMIT
        body = +''
        req.body do |chunk|
          body << chunk
          raise BodyTooLarge if body.bytesize > BODY_LIMIT
        end
        body.force_encoding(Encoding::UTF_8)
      rescue WEBrick::HTTPStatus::LengthRequired
        +''
      end

      # Reads what is left of a refused body (a body already read reads as
      # empty), up to DRAIN_LIMIT; a larger one is left and the connection
      # closes on it.
      def drain(req)
        length = req['content-length']
        return if length && length.to_i > DRAIN_LIMIT
        total = 0
        req.body do |chunk|
          total += chunk.bytesize
          raise BodyTooLarge if total > DRAIN_LIMIT
        end
      rescue StandardError
        nil
      end

      def reply(res, status, hash)
        res.status = status
        res['Content-Type'] = 'application/json; charset=utf-8'
        res.body = JSON.generate(hash, max_nesting: false)
        # A refused request may carry an unread body; never drain it.
        res.keep_alive = false if status >= 400
        res
      end

      def secure_headers(res)
        @headers.each { |name, value| res[name] = value }
      end

      # The page's single script and single style are pinned by hash, taken
      # from the page as it is when the console starts and served as read.
      # Hashes are over the element text as a browser parses it (CR and CRLF
      # become LF).
      def load_page(path)
        html = File.binread(path).force_encoding(Encoding::UTF_8)
        raise Refusal, "The console page is not valid UTF-8: #{path}" unless html.valid_encoding?
        scripts = html.scan(%r{<script\b[^>]*>(.*?)</script\s*>}mi).map(&:first)
        styles = html.scan(%r{<style\b[^>]*>(.*?)</style\s*>}mi).map(&:first)
        raise Refusal, "The console page must contain exactly one <script> and one <style>: #{path}" unless scripts.length == 1 && styles.length == 1
        csp = "default-src 'none'; script-src '#{pin(scripts.first)}'; style-src '#{pin(styles.first)}'; " \
              "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        [html, csp]
      rescue SystemCallError => e
        raise Refusal, "Cannot read the console page #{path}: #{e.class}"
      end

      def pin(text)
        "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(text.gsub(/\r\n?/, "\n")))}"
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
