# frozen_string_literal: true

require 'yaml'
require 'monitor'

module KairosMcp
  class Daemon
    # Credentials — Scoped, auto-redacting secret store for daemon-mode tools.
    #
    # Design (v0.2 §P2.6):
    #   A daemon running unattended needs access to API keys (ANTHROPIC_API_KEY,
    #   GITHUB_TOKEN, ...) but each tool should only see the credentials it
    #   actually needs. secrets.yml declares, per secret, which tool names may
    #   request it; `fetch_for(tool_name)` returns only the matching subset.
    #
    #   Pattern matching uses File.fnmatch so patterns like 'llm_*' or
    #   'safe_http_*' work the same way as in InvocationContext.
    #
    # Secret sources:
    #   env      — value = ENV[spec['env_var']]
    #   file     — value = File.read(spec['file_path']).strip
    #   keychain — stub; logs a warning and returns nil.
    #
    # Safety:
    #   • Empty or missing scoped_to means the secret is NOT handed to any tool.
    #   • Missing env var / unreadable file → value is nil, not an exception,
    #     so a misconfigured secret never leaks a filesystem path or ENV name
    #     via a backtrace.
    #   • `redact(str)` replaces every known secret *value* with '***REDACTED***'
    #     so log lines and exception messages can be scrubbed before they
    #     escape the daemon.
    #
    # Thread-safety:
    #   `reload!` can race with in-flight `fetch_for` calls from signal
    #   handlers (SIGHUP). A Monitor guards the mutable state.
    class Credentials
      REDACTED = '***REDACTED***'

      # @param logger [#warn, #info, nil] optional logger for keychain stubs
      def initialize(logger: nil)
        @logger = logger
        @monitor = Monitor.new
        @path = nil
        @specs = []       # Array<Hash> — normalized secret specs
        @values = {}      # { name => String } — resolved values
      end

      # Parse secrets.yml. Non-existent path → empty (no crash).
      # @param secrets_path [String, Pathname]
      # @return [self]
      def load(secrets_path)
        @monitor.synchronize do
          @path = secrets_path.to_s
          @specs = parse_file(@path)
          @values = resolve_all(@specs)
        end
        self
      end

      # Re-read the previously loaded secrets.yml. No-op if load was never
      # called. Called from the SIGHUP handler.
      # @return [self]
      def reload!
        @monitor.synchronize do
          return self if @path.nil?
          @specs = parse_file(@path)
          @values = resolve_all(@specs)
        end
        self
      end

      # Return the subset of secrets whose scoped_to pattern matches
      # `tool_name`. Only *resolved, non-nil* values are included.
      #
      # @param tool_name [String, Symbol]
      # @return [Hash{String => String}]
      def fetch_for(tool_name)
        name = tool_name.to_s
        out = {}
        @monitor.synchronize do
          @specs.each do |spec|
            next unless matches?(spec, name)
            value = @values[spec['name']]
            next if value.nil? || value.empty?
            out[spec['name']] = value
          end
        end
        out
      end

      # Replace every known secret value in `str` with REDACTED.
      # Handles nil and empty input without raising so callers can pipe
      # arbitrary log/exception strings through unconditionally.
      #
      # @param str [String, nil]
      # @return [String, nil]
      def redact(str)
        return str if str.nil?
        return str if str.empty?
        out = str.dup
        @monitor.synchronize do
          # Replace longer values first so a secret that is a substring of
          # another does not get partially redacted.
          @values.values.compact.reject(&:empty?)
                 .sort_by { |v| -v.length }
                 .each { |v| out.gsub!(v, REDACTED) }
        end
        out
      end

      # Flat list of every scoped_to pattern across all specs, for diagnostics.
      # @return [Array<String>]
      def all_patterns
        @monitor.synchronize do
          @specs.flat_map { |s| Array(s['scoped_to']) }.map(&:to_s).uniq
        end
      end

      # Names of loaded secrets (for diagnostics). Values are NOT exposed.
      # @return [Array<String>]
      def secret_names
        @monitor.synchronize { @specs.map { |s| s['name'] }.compact }
      end

      private

      # Parse a secrets.yml file into normalized spec hashes. Returns [] for
      # a missing file. Accepts both symbol and string keys.
      def parse_file(path)
        return [] unless File.exist?(path)
        data = YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false) || {}
        list = data['secrets'] || data[:secrets] || []
        list.map { |h| stringify(h) }
      end

      # Resolve every spec's current value. Failures → nil (not raise).
      def resolve_all(specs)
        specs.each_with_object({}) do |spec, acc|
          name = spec['name']
          next if name.nil? || name.empty?
          acc[name] = resolve_one(spec)
        end
      end

      def resolve_one(spec)
        case spec['source'].to_s
        when 'env'
          var = spec['env_var'].to_s
          return nil if var.empty?
          ENV[var]
        when 'file'
          fpath = spec['file_path'].to_s
          return nil if fpath.empty? || !File.exist?(fpath)
          begin
            File.read(fpath).strip
          rescue StandardError
            nil
          end
        when 'keychain'
          @logger&.warn("[credentials] keychain source not implemented (secret=#{spec['name']})")
          nil
        else
          nil
        end
      end

      # fnmatch-style scope check. Empty / missing scoped_to → no match.
      def matches?(spec, tool_name)
        patterns = Array(spec['scoped_to'])
        return false if patterns.empty?
        patterns.any? { |p| File.fnmatch(p.to_s, tool_name) }
      end

      # Turn symbol-keyed hashes into string-keyed ones so parse_file output
      # is uniform regardless of how the YAML was written.
      def stringify(hash)
        return {} unless hash.is_a?(Hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      end
    end
  end
end
