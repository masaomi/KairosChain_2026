require 'json'
require 'yaml'
require_relative 'protocol'
require_relative 'version'
require_relative '../kairos_mcp'

module KairosMcp
  class Server
    def self.run
      new.run
    end

    def initialize
      @protocol = Protocol.new
    end

    def run
      log "Starting KairosChain MCP Server v#{VERSION}..."
      check_version_mismatch
      
      $stdout.sync = true
      
      $stdin.each_line do |line|
        begin
          response = @protocol.handle_message(line)
          if response
            $stdout.puts(response.to_json)
            $stdout.flush
          end
        rescue StandardError => e
          log_error("Error processing message: #{e.message}", e.backtrace)
        end
      end
      
      log "KairosChain MCP Server stopped."
    rescue Interrupt
      log "KairosChain MCP Server interrupted."
    end

    private

    def log(message)
      $stderr.puts "[INFO] #{message}"
    end

    def log_error(message, backtrace = nil)
      $stderr.puts "[ERROR] #{message}"
      backtrace&.each { |line| $stderr.puts "  #{line}" }
    end

    # Check if data directory was initialized with a different gem version
    def check_version_mismatch
      meta_path = KairosMcp.meta_path
      return unless File.exist?(meta_path)

      meta = YAML.safe_load(File.read(meta_path)) rescue nil
      return unless meta.is_a?(Hash) && meta['kairos_mcp_version']

      data_version = meta['kairos_mcp_version']
      return if data_version == VERSION

      $stderr.puts "[KairosChain] Data directory was initialized with v#{data_version}, current gem is v#{VERSION}."
      $stderr.puts "[KairosChain] Run 'system_upgrade command=\"check\"' or 'kairos-chain upgrade' to see available updates."
    end
  end
end
