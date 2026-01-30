# frozen_string_literal: true

require 'optparse'
require 'net/http'
require 'json'
require 'uri'
require 'time'

module KairosMcp
  module CLI
    # Admin CLI for Meeting Place server management
    # IMPORTANT: This CLI shows METADATA ONLY. Message content is E2E encrypted
    # and CANNOT be read by the administrator.
    class AdminCLI
      DEFAULT_URL = 'http://localhost:8888'

      def initialize
        @base_url = ENV['KAIROS_MEETING_PLACE_URL'] || DEFAULT_URL
      end

      def run(args)
        command = args.shift || 'help'

        case command
        when 'stats'
          cmd_stats(args)
        when 'audit'
          cmd_audit(args)
        when 'agents'
          cmd_agents(args)
        when 'relay'
          cmd_relay(args)
        when 'keys'
          cmd_keys(args)
        when 'prune'
          cmd_prune(args)
        when 'help', '--help', '-h'
          cmd_help
        else
          puts "Unknown admin command: #{command}"
          puts "Run 'kairos_meeting_place admin help' for usage."
          exit 1
        end
      end

      private

      # === Commands ===

      def cmd_stats(args)
        options = { url: @base_url }
        
        OptionParser.new do |opts|
          opts.banner = "Usage: kairos_meeting_place admin stats [options]"
          opts.on('--url URL', "Server URL (default: #{DEFAULT_URL})") { |v| options[:url] = v }
        end.parse!(args)

        @base_url = options[:url]

        data = get('/place/v1/stats')
        return unless data

        puts "Meeting Place Statistics"
        puts "=" * 60
        puts
        puts "Place: #{data[:place]}"
        puts "Time: #{data[:timestamp]}"
        puts

        # Registry stats
        if data[:registry]
          puts "Registry:"
          puts "  Total agents: #{data[:registry][:total_agents]}"
          puts "  Active agents: #{data[:registry][:active_agents]}"
        end
        puts

        # Bulletin board stats
        if data[:bulletin_board]
          puts "Bulletin Board:"
          puts "  Total postings: #{data[:bulletin_board][:total_postings]}"
          puts "  Active postings: #{data[:bulletin_board][:active_postings]}"
          if data[:bulletin_board][:by_type]
            puts "  By type:"
            data[:bulletin_board][:by_type].each do |type, count|
              puts "    #{type}: #{count}"
            end
          end
        end
        puts

        # Message relay stats
        if data[:message_relay]
          relay = data[:message_relay]
          puts "Message Relay:"
          puts "  Total messages: #{relay[:total_messages]}"
          puts "  Active queues: #{relay[:active_queues]}"
          puts "  Total size: #{format_bytes(relay[:total_size_bytes])}"
          puts "  Average size: #{format_bytes(relay[:average_size_bytes])}"
          if relay[:oldest_message]
            puts "  Oldest message: #{relay[:oldest_message]} seconds ago"
          end
        end
        puts

        # Audit stats
        if data[:audit]
          audit = data[:audit]
          puts "Audit:"
          puts "  Total relays: #{audit[:total_relays]}"
          puts "  Total bytes relayed: #{format_bytes(audit[:total_bytes_relayed])}"
          puts "  Started at: #{audit[:started_at]}"
          puts "  Last activity: #{audit[:last_activity_at]}"
        end

        puts
        puts "Privacy Note: Statistics contain NO message content."
      end

      def cmd_audit(args)
        options = { url: @base_url, limit: 50, type: nil, since: nil, hourly: false }
        
        OptionParser.new do |opts|
          opts.banner = "Usage: kairos_meeting_place admin audit [options]"
          opts.on('--url URL', "Server URL (default: #{DEFAULT_URL})") { |v| options[:url] = v }
          opts.on('-l', '--limit N', Integer, 'Number of entries (default: 50)') { |v| options[:limit] = v }
          opts.on('--type TYPE', 'Filter by event type (relay, registration, etc.)') { |v| options[:type] = v }
          opts.on('--since DATE', 'Show entries since date (YYYY-MM-DD)') { |v| options[:since] = v }
          opts.on('--hourly', 'Show hourly statistics') { options[:hourly] = true }
        end.parse!(args)

        @base_url = options[:url]

        if options[:hourly]
          show_hourly_stats
        else
          show_audit_log(options)
        end
      end

      def cmd_agents(args)
        options = { url: @base_url }
        
        OptionParser.new do |opts|
          opts.banner = "Usage: kairos_meeting_place admin agents [options]"
          opts.on('--url URL', "Server URL (default: #{DEFAULT_URL})") { |v| options[:url] = v }
        end.parse!(args)

        @base_url = options[:url]

        data = get('/place/v1/agents')
        return unless data

        puts "Registered Agents"
        puts "=" * 60
        puts

        agents = data[:agents] || []
        if agents.empty?
          puts "(No agents registered)"
        else
          agents.each do |agent|
            puts "#{agent[:name] || agent[:id]}"
            puts "  ID: #{agent[:id]}"
            puts "  Scope: #{agent[:scope]}" if agent[:scope]
            puts "  Registered: #{agent[:registered_at]}"
            puts "  Last seen: #{agent[:last_seen_at]}"
            puts
          end
          puts "Total: #{agents.size} agents"
        end

        puts
        puts "Privacy Note: Agent list shows registration info only, no communication content."
      end

      def cmd_relay(args)
        options = { url: @base_url }
        
        OptionParser.new do |opts|
          opts.banner = "Usage: kairos_meeting_place admin relay [options]"
          opts.on('--url URL', "Server URL (default: #{DEFAULT_URL})") { |v| options[:url] = v }
        end.parse!(args)

        @base_url = options[:url]

        data = get('/place/v1/relay/stats')
        return unless data

        puts "Message Relay Status"
        puts "=" * 60
        puts
        puts "Total messages in queue: #{data[:total_messages]}"
        puts "Active queues: #{data[:active_queues]}"
        puts "Total size: #{format_bytes(data[:total_size_bytes])}"
        puts "Average message size: #{format_bytes(data[:average_size_bytes])}"
        puts "Max message size: #{format_bytes(data[:max_size_bytes])}"
        
        if data[:oldest_message]
          puts "Oldest message age: #{data[:oldest_message]} seconds"
        end

        puts
        puts "Privacy Note: Relay stats show sizes and counts only."
        puts "Message content is E2E encrypted and CANNOT be read."
      end

      def cmd_keys(args)
        options = { url: @base_url }
        
        OptionParser.new do |opts|
          opts.banner = "Usage: kairos_meeting_place admin keys [options]"
          opts.on('--url URL', "Server URL (default: #{DEFAULT_URL})") { |v| options[:url] = v }
        end.parse!(args)

        @base_url = options[:url]

        # Get stats which includes key registration count
        data = get('/place/v1/stats')
        return unless data

        puts "Public Key Registry"
        puts "=" * 60
        puts

        if data[:audit] && data[:audit][:total_key_registrations]
          puts "Total key registrations: #{data[:audit][:total_key_registrations]}"
        else
          puts "Key registration stats not available."
        end

        puts
        puts "Note: Only public keys are stored. Private keys remain with agents."
      end

      def cmd_prune(args)
        puts "Prune command not yet implemented."
        puts "This would clean up old data from the server."
        puts
        puts "For now, restart the server to clear in-memory data,"
        puts "or manually delete the audit log file."
      end

      def cmd_help
        puts <<~HELP
          KairosChain Meeting Place - Admin CLI
          
          Usage: kairos_meeting_place admin <command> [options]
          
          Commands:
            stats      Show server statistics
            audit      Show audit log (metadata only)
            agents     List registered agents
            relay      Show message relay status
            keys       Show public key registry info
            prune      Clean up old data (not yet implemented)
            help       Show this help
          
          Global Options:
            --url URL  Server URL (default: http://localhost:8888)
                       Can also set KAIROS_MEETING_PLACE_URL environment variable
          
          Examples:
            kairos_meeting_place admin stats
            kairos_meeting_place admin audit --limit 100
            kairos_meeting_place admin audit --hourly
            kairos_meeting_place admin agents
            kairos_meeting_place admin relay
          
          ╔════════════════════════════════════════════════════════════╗
          ║                     PRIVACY NOTICE                         ║
          ╠════════════════════════════════════════════════════════════╣
          ║  This CLI shows METADATA ONLY:                             ║
          ║  - Timestamps                                              ║
          ║  - Participant IDs (optionally anonymized)                 ║
          ║  - Message types and sizes                                 ║
          ║  - Content hashes (NOT content)                            ║
          ║                                                            ║
          ║  Message CONTENT is END-TO-END ENCRYPTED.                  ║
          ║  The server administrator CANNOT read message content.     ║
          ╚════════════════════════════════════════════════════════════╝
        HELP
      end

      # === Helper Methods ===

      def show_audit_log(options)
        params = { limit: options[:limit] }
        params[:type] = options[:type] if options[:type]
        params[:since] = options[:since] if options[:since]

        data = get('/place/v1/audit', params)
        return unless data

        puts "Audit Log (Metadata Only)"
        puts "=" * 60
        puts

        entries = data[:entries] || []
        if entries.empty?
          puts "(No audit entries)"
        else
          entries.each do |entry|
            print_audit_entry(entry)
          end
          puts
          puts "Showing #{entries.size} entries"
        end

        puts
        puts data[:note] if data[:note]
      end

      def show_hourly_stats
        data = get('/place/v1/audit/stats', { hours: 24 })
        return unless data

        puts "Hourly Statistics (Last 24 Hours)"
        puts "=" * 60
        puts

        if data[:summary]
          puts "Summary:"
          puts "  Total relays: #{data[:summary][:total_relays]}"
          puts "  Total bytes: #{format_bytes(data[:summary][:total_bytes_relayed])}"
          puts
        end

        if data[:hourly]
          puts "Hour                      Relays    Bytes      Agents"
          puts "-" * 60
          
          data[:hourly].to_a.sort.reverse.first(24).each do |hour, stats|
            relays = stats[:relay_count] || 0
            bytes = format_bytes(stats[:total_bytes] || 0).rjust(10)
            agents = stats[:unique_agents] || 0
            puts "#{hour}    #{relays.to_s.rjust(6)}    #{bytes}    #{agents.to_s.rjust(6)}"
          end
        end
      end

      def print_audit_entry(entry)
        time = entry[:timestamp]
        event = entry[:event_type]
        action = entry[:action]

        case event
        when 'relay'
          participants = entry[:participants]&.join(' <-> ') || 'unknown'
          type = entry[:message_type] || 'unknown'
          size = format_bytes(entry[:size_bytes] || 0)
          hash = entry[:content_hash]&.slice(0, 20) || ''
          
          puts "[#{time}] RELAY #{action}: #{participants}"
          puts "    Type: #{type}, Size: #{size}, Hash: #{hash}..."
        when 'registration'
          agent = entry[:agent_id] || 'unknown'
          puts "[#{time}] REGISTRATION #{action}: #{agent}"
        when 'key_registration'
          agent = entry[:agent_id] || 'unknown'
          fingerprint = entry[:key_fingerprint] || ''
          puts "[#{time}] KEY_REGISTRATION: #{agent}"
          puts "    Fingerprint: #{fingerprint}"
        when 'bulletin'
          agent = entry[:agent_id] || 'unknown'
          posting_type = entry[:posting_type] || 'unknown'
          puts "[#{time}] BULLETIN #{action}: #{agent} (#{posting_type})"
        else
          puts "[#{time}] #{event.upcase} #{action}"
        end
        puts
      end

      def get(path, params = {})
        uri = URI.parse("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 5
        http.read_timeout = 10

        response = http.get(uri.request_uri)
        
        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body, symbolize_names: true)
        else
          $stderr.puts "Error: HTTP #{response.code}"
          $stderr.puts response.body
          nil
        end
      rescue Errno::ECONNREFUSED
        $stderr.puts "Error: Cannot connect to #{@base_url}"
        $stderr.puts "Is the Meeting Place server running?"
        nil
      rescue StandardError => e
        $stderr.puts "Error: #{e.message}"
        nil
      end

      def format_bytes(bytes)
        return '0 B' if bytes.nil? || bytes == 0
        
        units = ['B', 'KB', 'MB', 'GB']
        unit_index = 0
        size = bytes.to_f
        
        while size >= 1024 && unit_index < units.length - 1
          size /= 1024
          unit_index += 1
        end
        
        "#{size.round(1)} #{units[unit_index]}"
      end
    end
  end
end
