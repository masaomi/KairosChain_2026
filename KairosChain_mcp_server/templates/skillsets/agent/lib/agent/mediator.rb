# frozen_string_literal: true

require 'socket'
require 'uri'

module KairosMcp
  module SkillSets
    module Agent
      # Mediator — NB-4 sole-path egress mediation for the native body
      # (native body design v0.6 FROZEN, Slice 2).
      #
      # A hostname-terminating forward proxy at a loopback address, run
      # BOUNDARY-SIDE (driver context) — outside the confined process's
      # write and signal reach, so the body cannot disable or rewrite it.
      # The native-body confinement profile denies all network except
      # loopback to this port, making the mediator the ONLY egress path:
      # direct, un-mediated sockets are refused by the substrate, not
      # merely deprioritized.
      #
      # Destination identity is decided by HOSTNAME (what the mechanism can
      # decide), never by raw address — provider endpoints share CDN IPs, so
      # an IP list both under- and over-blocks (R2). The decision is
      # re-made on EVERY hop:
      # - each CONNECT names its destination host and is checked;
      # - each plain-HTTP request is checked against its request target /
      #   Host header, and the connection is closed after one request, so a
      #   keep-alive pipeline cannot smuggle a second host past the check;
      # - an HTTP redirect to a non-provider host therefore surfaces as a
      #   NEW connection through the mediator and is refused at that hop.
      #
      # Scope bounds the destination, not the content (§7 model-trust frame).
      class Mediator
        REFUSED = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\negress refused: destination not in provider scope (NB-4)\r\n"

        attr_reader :port, :refusals

        def initialize(allowed_hosts:)
          @allowed_hosts = Array(allowed_hosts).map { |h| normalize_host(h) }.reject(&:empty?).uniq
          raise ArgumentError, 'mediator requires a non-empty provider host scope (NB-4)' if @allowed_hosts.empty?

          @server = nil
          @threads = []
          @refusals = []
          @mutex = Mutex.new
        end

        # Destination-identity decision: exact hostname match, case-insensitive.
        # No wildcard, no IP reasoning — the curated configuration names the
        # provider destination(s) and only those pass.
        def allowed_host?(host)
          @allowed_hosts.include?(normalize_host(host))
        end

        def start!
          @server = TCPServer.new('127.0.0.1', 0)
          @port = @server.addr[1]
          @accept_thread = Thread.new { accept_loop }
          @accept_thread.abort_on_exception = false
          self
        end

        def stop!
          @server&.close
          @accept_thread&.kill
          @threads.each(&:kill)
          @threads.clear
        end

        def proxy_url
          "http://127.0.0.1:#{@port}"
        end

        private

        def accept_loop
          loop do
            client = @server.accept
            t = Thread.new(client) { |c| handle(c) }
            t.abort_on_exception = false
            @mutex.synchronize { @threads << t }
          end
        rescue IOError, Errno::EBADF
          # server closed — normal shutdown
        end

        def handle(client)
          request_line = client.gets
          return client.close if request_line.nil?

          method, target, = request_line.split(' ', 3)
          headers = read_headers(client)

          if method == 'CONNECT'
            host, port = split_host_port(target, 443)
            return refuse(client, host) unless allowed_host?(host)

            tunnel(client, host, port)
          else
            host, port = destination_of(target, headers)
            return refuse(client, host) unless host && allowed_host?(host)

            forward_plain(client, method, target, headers, host, port)
          end
        rescue StandardError
          client.close rescue nil
        end

        def refuse(client, host)
          @mutex.synchronize { @refusals << host.to_s }
          client.write(REFUSED)
          client.close
        end

        def read_headers(client)
          headers = {}
          while (line = client.gets)
            line = line.strip
            break if line.empty?

            k, v = line.split(':', 2)
            headers[k.to_s.downcase.strip] = v.to_s.strip if k && v
          end
          headers
        end

        def destination_of(target, headers)
          if target.to_s.start_with?('http://', 'https://')
            uri = URI.parse(target)
            [uri.host, uri.port]
          elsif headers['host']
            split_host_port(headers['host'], 80)
          end
        end

        def split_host_port(hostport, default_port)
          host, port = hostport.to_s.split(':', 2)
          [host, (port || default_port).to_i]
        end

        # CONNECT tunnel: the hop was checked; relay bytes both ways. TLS
        # runs end-to-end inside the tunnel — the mediator decides identity
        # at the CONNECT hostname, which is the decidable surface.
        def tunnel(client, host, port)
          upstream = TCPSocket.new(host, port)
          client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
          relay(client, upstream)
        rescue StandardError
          client.close rescue nil
          upstream&.close rescue nil
        end

        # Plain-HTTP forward: exactly ONE request per connection. R1 F5: the
        # request line + headers + declared body are read and forwarded, then
        # the response is pumped back ONE DIRECTION ONLY (upstream→client).
        # Any further client bytes (a pipelined second request) are NOT
        # relayed — a bidirectional relay would carry a second, unchecked
        # request-target to the approved upstream, defeating NB-4's per-hop
        # re-decision. A follow-up request must open a NEW connection, which
        # is re-decided here from scratch.
        def forward_plain(client, method, target, headers, host, port)
          path = target.start_with?('http') ? (URI.parse(target).request_uri || '/') : target
          upstream = TCPSocket.new(host, port)
          # Forward exactly this one request. A write failure (e.g. a server
          # that responds and closes before reading) must NOT discard a
          # response already buffered on the socket, so forwarding is guarded
          # separately from relaying.
          begin
            upstream.write("#{method} #{path} HTTP/1.1\r\n")
            headers = headers.merge('host' => "#{host}:#{port}", 'connection' => 'close')
            headers.each { |k, v| upstream.write("#{k}: #{v}\r\n") }
            upstream.write("\r\n")
            if headers['content-length']
              body = client.read(headers['content-length'].to_i)
              upstream.write(body) if body
            end
            upstream.close_write
          rescue StandardError
            # fall through to relay whatever the upstream already sent
          end
          # Relay the response ONE DIRECTION ONLY (upstream→client); post-
          # request client bytes (a pipelined 2nd request) are never carried.
          pump(upstream, client)
        ensure
          client.close rescue nil
          upstream&.close rescue nil
        end

        def relay(a, b)
          t1 = Thread.new { pump(a, b) }
          t2 = Thread.new { pump(b, a) }
          t1.join
          t2.join
          a.close rescue nil
          b.close rescue nil
        end

        def pump(from, to)
          while (chunk = from.readpartial(65_536))
            to.write(chunk)
          end
        rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
          to.close_write rescue nil
        end

        def normalize_host(host)
          host.to_s.strip.downcase.chomp('.')
        end
      end
    end
  end
end
