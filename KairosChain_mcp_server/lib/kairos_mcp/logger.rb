# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module KairosMcp
  # Structured JSON lines logger for KairosChain.
  # Writes to .kairos/logs/kairos.log with daily rotation (max 7 files).
  # All entries pass through SecretRedactor before writing.
  #
  # Log levels: DEBUG, INFO, WARN, ERROR
  # Entry format: {"ts","level","event","source","details",...}
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    MAX_ROTATED_FILES = 7
    DEFAULT_LOG_DIR = '.kairos/logs'
    DEFAULT_LOG_FILE = 'kairos.log'

    # Patterns for secret redaction (applied to serialized JSON).
    # Uses simple patterns compatible with Ruby 3.1+ (no variable-length lookbehind).
    SECRET_PATTERNS = [
      # Bare API key formats (provider-specific prefixes)
      /\b(sk-[a-zA-Z0-9]{20,})\b/,
      /\b(anthropic-[a-zA-Z0-9]{20,})\b/,
      /\b(ghp_[a-zA-Z0-9]{20,})\b/,
      /\b(xoxb-[a-zA-Z0-9\-]{20,})\b/,
    ].freeze

    attr_reader :level, :log_path

    # @param log_dir [String] directory for log files (default: .kairos/logs)
    # @param level [Symbol] minimum log level (:debug, :info, :warn, :error)
    def initialize(log_dir: nil, level: :info)
      @log_dir = log_dir || File.join(Dir.pwd, DEFAULT_LOG_DIR)
      @level = LEVELS[level] || LEVELS[:info]
      @log_path = File.join(@log_dir, DEFAULT_LOG_FILE)
      @mutex = Mutex.new
      @current_date = nil
      @io = nil
    end

    def debug(event, **fields)
      write_entry(:debug, event, fields)
    end

    def info(event, **fields)
      write_entry(:info, event, fields)
    end

    def warn(event, **fields)
      write_entry(:warn, event, fields)
    end

    def error(event, **fields)
      write_entry(:error, event, fields)
    end

    # Flush and close the log file.
    def close
      @mutex.synchronize do
        @io&.close
        @io = nil
      end
    end

    private

    def write_entry(level_sym, event, fields)
      return if LEVELS[level_sym] < @level

      entry = build_entry(level_sym, event, fields)
      json_line = redact_secrets(JSON.generate(entry))

      @mutex.synchronize do
        ensure_log_file
        rotate_if_needed
        @io.puts(json_line)
        @io.flush
      end
    rescue StandardError => e
      # Logger must never crash the system
      $stderr.puts "[kairos-logger] Write failed: #{e.message}"
    end

    def build_entry(level_sym, event, fields)
      entry = {
        ts: Time.now.utc.iso8601(3),
        level: level_sym.to_s.upcase,
        event: event.to_s
      }
      # Merge caller-provided fields (source, mandate_id, cycle, details, etc.)
      fields.each do |k, v|
        entry[k] = v unless v.nil?
      end
      entry
    end

    def ensure_log_file
      return if @io && !@io.closed?

      FileUtils.mkdir_p(@log_dir)
      @io = File.open(@log_path, 'a')
      @io.sync = true
      @current_date = Date.today
    end

    def rotate_if_needed
      today = Date.today
      return if @current_date == today

      @io&.close
      @io = nil

      # Rotate existing files
      rotate_files
      @current_date = today
      ensure_log_file
    end

    def rotate_files
      return unless File.exist?(@log_path)

      # Shift existing rotated files
      (MAX_ROTATED_FILES - 1).downto(1) do |i|
        src = "#{@log_path}.#{i}"
        dst = "#{@log_path}.#{i + 1}"
        File.rename(src, dst) if File.exist?(src)
      end

      # Current → .1
      File.rename(@log_path, "#{@log_path}.1")

      # Delete oldest if over limit
      oldest = "#{@log_path}.#{MAX_ROTATED_FILES}"
      File.delete(oldest) if File.exist?(oldest)
    end

    def redact_secrets(json_string)
      result = json_string
      SECRET_PATTERNS.each do |pattern|
        result = result.gsub(pattern) { |match| match[0..3] + '*' * [match.length - 4, 4].max }
      end
      result
    end
  end

  # Global logger instance (singleton, lazy-initialized).
  # Access via KairosMcp.logger
  @logger = nil
  @logger_mutex = Mutex.new

  def self.logger
    @logger_mutex.synchronize do
      @logger ||= Logger.new
    end
  end

  def self.logger=(instance)
    @logger_mutex.synchronize do
      @logger = instance
    end
  end
end
