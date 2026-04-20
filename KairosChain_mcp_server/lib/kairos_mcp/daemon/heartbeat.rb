# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module KairosMcp
  class Daemon
    # Heartbeat — P2.8 liveness beacon.
    #
    # Design (v0.2 P2.8):
    #   * At most once per `interval` seconds, the daemon writes a small JSON
    #     file at .kairos/run/heartbeat.json with current liveness fields.
    #   * External monitors (health checks, attach clients, ops scripts)
    #     stat+read this file to answer "is the daemon alive, and when did
    #     it last complete a cycle?"
    #
    # Atomicity:
    #   Writes go tmp → rename. A torn write leaves either the previous
    #   heartbeat or the new one intact — never a half-written JSON.
    #
    # Decoupling:
    #   `emit(daemon)` duck-types the daemon. Required: `#status_snapshot`
    #   (for pid + tick_count). Optional: `#active_mandate_id`,
    #   `#queue_depth`, `#last_cycle_at`. Missing optionals default to
    #   nil / 0 — this keeps Heartbeat testable without the full daemon.
    class Heartbeat
      DEFAULT_PATH     = '.kairos/run/heartbeat.json'
      DEFAULT_INTERVAL = 10 # seconds

      attr_reader :path

      # @param path  [String] absolute path to heartbeat.json
      # @param clock [#call, nil] returns current Time (UTC-ish)
      def initialize(path: DEFAULT_PATH, clock: nil)
        @path = path
        @clock = clock || -> { Time.now.utc }
      end

      # Emit a heartbeat right now. Returns the Time it was emitted at.
      def emit(daemon)
        now = @clock.call
        payload = build_payload(daemon, now)
        write_atomic(payload)
        now
      end

      # Rate-limited variant. If `interval` seconds have not yet elapsed
      # since `last_emit_at`, do nothing and return `last_emit_at`.
      # Otherwise emit and return the new emit time.
      #
      # `last_emit_at` may be nil (first call) — in that case we emit.
      def emit_if_due(daemon, last_emit_at, interval: DEFAULT_INTERVAL)
        now = @clock.call
        return last_emit_at if last_emit_at && (now - last_emit_at) < interval

        payload = build_payload(daemon, now)
        write_atomic(payload)
        now
      end

      # Parse and return the current heartbeat.json, or nil if absent /
      # unparseable. Never raises.
      def read
        return nil unless File.exist?(@path)

        JSON.parse(File.read(@path))
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------- private

      private

      def build_payload(daemon, now)
        snap = safe_snapshot(daemon)
        {
          'pid'               => snap['pid'] || Process.pid,
          'ts'                => now.iso8601,
          'last_cycle_at'     => iso_or_nil(optional(daemon, :last_cycle_at)),
          'active_mandate_id' => optional(daemon, :active_mandate_id),
          'queue_depth'       => Integer(optional(daemon, :queue_depth) || 0),
          'tick_count'        => snap['tick_count'] || 0,
          'state'             => snap['state']
        }
      end

      def safe_snapshot(daemon)
        return {} unless daemon.respond_to?(:status_snapshot)

        snap = daemon.status_snapshot
        # status_snapshot returns symbol keys — stringify for JSON consistency.
        snap.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      rescue StandardError
        {}
      end

      def optional(daemon, meth)
        return nil unless daemon.respond_to?(meth)

        daemon.public_send(meth)
      rescue StandardError
        nil
      end

      def iso_or_nil(v)
        return nil if v.nil?
        return v if v.is_a?(String)

        v.respond_to?(:iso8601) ? v.iso8601 : v.to_s
      end

      def write_atomic(payload)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp.#{$$}"
        begin
          File.open(tmp, 'w', 0o600) do |f|
            f.write(JSON.generate(payload))
            f.flush
            begin
              f.fsync
            rescue StandardError
              # best-effort on platforms without fsync
            end
          end
          File.rename(tmp, @path)
        ensure
          begin
            File.unlink(tmp) if tmp && File.exist?(tmp)
          rescue StandardError
            # cleanup must not raise
          end
        end
      end
    end
  end
end
