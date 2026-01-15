require 'json'
require_relative 'protocol'
require_relative 'version'

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
  end
end
