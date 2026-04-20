# frozen_string_literal: true

require 'webrick'
require 'json'
require 'securerandom'
require 'fileutils'
require 'time'

module KairosMcp
  class Daemon
    # P2.7 AttachServer: HTTP/SSE control-plane for an already-running daemon.
    #
    # Design rationale (design v0.2 §6):
    #   - Local-only control plane. Binds to 127.0.0.1 ONLY (never 0.0.0.0).
    #   - Bearer-token auth. Token is generated at startup, stored 0600 at
    #     .kairos/run/attach_token, rotated on SIGUSR2 with a 60s grace window
    #     during which both the old and new tokens are accepted.
    #   - CommandMailbox pattern: HTTP handler threads ONLY enqueue commands
    #     into daemon.mailbox. The single daemon event-loop thread is the
    #     sole consumer. Handlers never mutate daemon state directly.
    #   - Read-only endpoints (/v1/status, /v1/mandates, /v1/events) are
    #     allowed to snapshot data, because reads are safe across threads.
    #
    # Endpoints:
    #   GET  /v1/status             — daemon status snapshot (read-only)
    #   GET  /v1/mandates           — list active + queued mandates (read-only)
    #   POST /v1/mandates           — enqueue :create_mandate command
    #   POST /v1/mandates/:id/stop  — enqueue :stop_mandate command
    #   GET  /v1/events             — SSE stream (stub in P2.7; full in P2.8)
    #   POST /v1/admin/reload       — enqueue :reload
    #   POST /v1/admin/shutdown     — enqueue :shutdown
    class AttachServer
      DEFAULT_PORT = 9847
      DEFAULT_HOST = '127.0.0.1'
      DEFAULT_ROTATE_INTERVAL = 24 * 60 * 60  # 24h
      DEFAULT_GRACE_PERIOD = 60               # seconds
      DEFAULT_TOKEN_REL_PATH = '.kairos/run/attach_token'

      attr_reader :port, :host, :token_path, :daemon

      # @param daemon [#mailbox, #status_snapshot] the daemon instance to
      #   forward commands to. Only `mailbox` (for writes) and
      #   `status_snapshot` (for reads) are required.
      # @param root [String] workspace root for resolving the token path
      # @param token_path [String, nil] override token path (tests)
      # @param rotate_interval [Integer] seconds between automatic rotations
      # @param grace_period [Integer] seconds the previous token remains valid
      # @param logger [#info, #warn, #error] logger (optional)
      # @param clock [#call] callable returning current Time (tests)
      def initialize(daemon:,
                     root: Dir.pwd,
                     token_path: nil,
                     rotate_interval: DEFAULT_ROTATE_INTERVAL,
                     grace_period: DEFAULT_GRACE_PERIOD,
                     logger: nil,
                     clock: nil)
        @daemon = daemon
        @root = root
        @token_path = token_path || File.join(@root, DEFAULT_TOKEN_REL_PATH)
        @rotate_interval = Integer(rotate_interval)
        @grace_period = Integer(grace_period)
        @logger = logger
        @clock = clock || -> { Time.now.utc }

        @token_mutex = Mutex.new
        @current_token = nil
        @previous_token = nil
        @previous_expires_at = nil
        @token_rotated_at = nil

        @server = nil
        @thread = nil
        @host = nil
        @port = nil
      end

      # ------------------------------------------------------------------ lifecycle

      # Start the server on host/port. Returns once WEBrick is accepting
      # connections. Runs the accept loop in a background thread.
      #
      # @param port [Integer] TCP port (0 = pick a random free port)
      # @param host [String] bind address — MUST be loopback-only
      def start(port: DEFAULT_PORT, host: DEFAULT_HOST)
        raise 'AttachServer already started' if @server

        unless loopback_address?(host)
          raise ArgumentError,
                "AttachServer refuses to bind to #{host.inspect}: must be loopback"
        end

        generate_token!

        # WEBrick logger that discards output unless a real logger was given.
        wlog = WEBrick::Log.new(File::NULL, WEBrick::Log::WARN)
        alog = []

        @server = WEBrick::HTTPServer.new(
          BindAddress: host,
          Port: port,
          Logger: wlog,
          AccessLog: alog,
          StartCallback: nil,
          DoNotReverseLookup: true
        )

        mount_routes!

        @host = @server.config[:BindAddress]
        @port = @server.config[:Port]

        @thread = Thread.new do
          begin
            @server.start
          rescue StandardError => e
            log(:error, 'attach_server_thread_crashed', error: "#{e.class}: #{e.message}")
          end
        end
        @thread.name = 'kairos-attach-server' if @thread.respond_to?(:name=)

        # Wait briefly until the listener is actually up. WEBrick sets the
        # status to :Running once ready; poll with a short timeout.
        wait_until_listening!

        log(:info, 'attach_server_started', host: @host, port: @port,
                                           token_path: @token_path)
        true
      end

      # Shut down WEBrick and join the accept thread. Safe to call twice.
      def stop
        return unless @server

        begin
          @server.shutdown
        rescue StandardError
          # ignore — server may already be mid-shutdown
        end

        if @thread
          begin
            @thread.join(5)
          rescue StandardError
            # ignore
          end
        end

        @server = nil
        @thread = nil
        log(:info, 'attach_server_stopped')
        true
      end

      # ------------------------------------------------------------------ tokens

      # Generate a fresh token, rotating the current one into the grace window.
      # Writes the new token to disk with 0600 permissions atomically.
      #
      # @return [String] the new token
      def generate_token!
        new_token = SecureRandom.hex(32)
        now = @clock.call

        @token_mutex.synchronize do
          if @current_token
            @previous_token = @current_token
            @previous_expires_at = now + @grace_period
          end
          @current_token = new_token
          @token_rotated_at = now
        end

        write_token_file(new_token)
        log(:info, 'attach_server_token_rotated',
            grace_until: @previous_expires_at&.iso8601)
        new_token
      end

      # Currently-active token (what write-to-disk represents).
      def current_token
        @token_mutex.synchronize { @current_token }
      end

      # True if `token` is the current token, or a previous token still in
      # its grace window.
      def valid_token?(token)
        return false if token.nil? || token.empty?

        @token_mutex.synchronize do
          return true if @current_token && secure_compare(token, @current_token)

          if @previous_token && @previous_expires_at
            return false if @clock.call >= @previous_expires_at

            return true if secure_compare(token, @previous_token)
          end
          false
        end
      end

      # ------------------------------------------------------------------ internals

      private

      def loopback_address?(host)
        host == '127.0.0.1' || host == '::1' || host == 'localhost'
      end

      def write_token_file(token)
        FileUtils.mkdir_p(File.dirname(@token_path))
        tmp = "#{@token_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(token)
        end
        File.chmod(0o600, tmp)
        File.rename(tmp, @token_path)
        File.chmod(0o600, @token_path)
      end

      # Constant-time comparison of two strings. Avoids early-return timing
      # channels when validating bearer tokens.
      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        diff = 0
        a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
        diff.zero?
      end

      def wait_until_listening!
        deadline = Time.now + 5.0
        until @server && @server.status == :Running
          break if Time.now >= deadline

          sleep 0.01
        end
      end

      def log(level, event, **fields)
        return unless @logger

        if @logger.respond_to?(level)
          if fields.empty?
            @logger.send(level, event)
          else
            @logger.send(level, event, source: 'attach_server', details: fields)
          end
        end
      rescue StandardError
        # logging must never crash the server
      end

      # ------------------------------------------------------------------ routing

      def mount_routes!
        @server.mount_proc('/v1/status')     { |req, res| handle_status(req, res) }
        @server.mount_proc('/v1/mandates')   { |req, res| handle_mandates(req, res) }
        @server.mount_proc('/v1/events')     { |req, res| handle_events(req, res) }
        @server.mount_proc('/v1/admin/reload')   { |req, res| handle_reload(req, res) }
        @server.mount_proc('/v1/admin/shutdown') { |req, res| handle_shutdown(req, res) }
      end

      # --- auth helper ---------------------------------------------------

      # Returns true if the request carried a valid bearer token; otherwise
      # writes a 401 JSON body onto `res` and returns false.
      def authenticate!(req, res)
        header = req['Authorization'] || req['authorization']
        token = nil
        if header.is_a?(String) && header.start_with?('Bearer ')
          token = header.sub(/\ABearer\s+/, '').strip
        end

        if token && valid_token?(token)
          true
        else
          json_error(res, 401, 'unauthorized',
                     'missing or invalid bearer token')
          false
        end
      end

      # --- handlers ------------------------------------------------------

      def handle_status(req, res)
        return unless authenticate!(req, res)

        unless req.request_method == 'GET'
          return json_error(res, 405, 'method_not_allowed', 'GET only')
        end

        snap = if @daemon.respond_to?(:status_snapshot)
                 @daemon.status_snapshot
               else
                 { state: 'unknown' }
               end
        json_ok(res, snap)
      end

      def handle_mandates(req, res)
        return unless authenticate!(req, res)

        # Dispatch by method + path. Sub-path "/v1/mandates/:id/stop" is routed
        # via the same mount_proc because WEBrick's mount_proc matches prefix.
        path = req.path
        case req.request_method
        when 'GET'
          return json_error(res, 405, 'method_not_allowed', 'GET / POST only') \
            unless path == '/v1/mandates' || path == '/v1/mandates/'

          mandates = if @daemon.respond_to?(:list_mandates)
                       @daemon.list_mandates
                     else
                       { active: [], queued: [] }
                     end
          json_ok(res, mandates)
        when 'POST'
          if (m = path.match(%r{\A/v1/mandates/([^/]+)/stop/?\z}))
            mandate_id = m[1]
            cmd_id = @daemon.mailbox.enqueue(:stop_mandate, mandate_id: mandate_id)
            if cmd_id.nil?
              json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
            else
              json_ok(res, { enqueued: true, command_id: cmd_id,
                             mandate_id: mandate_id })
            end
          elsif path == '/v1/mandates' || path == '/v1/mandates/'
            payload = parse_json_body(req)
            cmd_id = @daemon.mailbox.enqueue(:create_mandate, payload || {})
            if cmd_id.nil?
              json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
            else
              json_ok(res, { enqueued: true, command_id: cmd_id })
            end
          else
            json_error(res, 404, 'not_found', "no handler for #{path}")
          end
        else
          json_error(res, 405, 'method_not_allowed', 'GET / POST only')
        end
      end

      # SSE stub for P2.7 — full streaming lands in P2.8. For now we respond
      # with a single comment-line so clients can verify the endpoint exists
      # and auth works, then close the connection.
      def handle_events(req, res)
        return unless authenticate!(req, res)

        unless req.request_method == 'GET'
          return json_error(res, 405, 'method_not_allowed', 'GET only')
        end

        res.status = 200
        res['Content-Type'] = 'text/event-stream'
        res['Cache-Control'] = 'no-cache'
        res['Connection'] = 'close'
        # A single SSE comment. Real event streaming is P2.8 scope.
        res.body = ": kairos-attach-server events (P2.7 stub)\n\n"
      end

      def handle_reload(req, res)
        return unless authenticate!(req, res)

        unless req.request_method == 'POST'
          return json_error(res, 405, 'method_not_allowed', 'POST only')
        end

        cmd_id = @daemon.mailbox.enqueue(:reload, source: 'attach_server')
        if cmd_id.nil?
          json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
        else
          json_ok(res, { enqueued: true, command_id: cmd_id })
        end
      end

      def handle_shutdown(req, res)
        return unless authenticate!(req, res)

        unless req.request_method == 'POST'
          return json_error(res, 405, 'method_not_allowed', 'POST only')
        end

        cmd_id = @daemon.mailbox.enqueue(:shutdown, source: 'attach_server')
        if cmd_id.nil?
          json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
        else
          json_ok(res, { enqueued: true, command_id: cmd_id })
        end
      end

      # --- response helpers ---------------------------------------------

      def json_ok(res, body)
        res.status = 200
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate(body)
      end

      def json_error(res, status, code, message)
        res.status = status
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate(error: code, message: message)
      end

      def parse_json_body(req)
        body = req.body.to_s
        return {} if body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
