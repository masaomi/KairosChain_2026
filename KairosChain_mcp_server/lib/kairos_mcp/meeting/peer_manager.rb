# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'

module KairosMcp
  module Meeting
    # PeerManager handles connections to other KairosChain instances.
    # It maintains a list of known peers and provides methods to communicate with them.
    class PeerManager
      # Peer status
      PEER_STATUS = {
        unknown: 'unknown',
        online: 'online',
        offline: 'offline',
        error: 'error'
      }.freeze

      Peer = Struct.new(
        :id,              # Peer's instance_id
        :name,            # Peer's name
        :url,             # Base URL (e.g., "http://localhost:9999")
        :status,          # Current status
        :last_seen,       # Last successful contact
        :introduction,    # Cached introduction data
        :extensions,      # Supported extensions
        :added_at,
        keyword_init: true
      )

      def initialize(identity:, config: {})
        @identity = identity
        @config = config
        @peers = {}  # id => Peer
        @timeout = config['timeout'] || 10  # seconds
      end

      # Add a new peer by URL
      # @param url [String] Base URL of the peer (e.g., "http://localhost:8080")
      # @return [Peer, nil] The peer if successfully added
      def add_peer(url)
        # Try to connect and get introduction
        intro = fetch_introduction(url)
        return nil unless intro

        peer_id = intro.dig(:identity, :instance_id) || intro.dig('identity', 'instance_id')
        return nil unless peer_id

        peer = Peer.new(
          id: peer_id,
          name: intro.dig(:identity, :name) || intro.dig('identity', 'name'),
          url: url.chomp('/'),
          status: PEER_STATUS[:online],
          last_seen: Time.now.utc,
          introduction: intro,
          extensions: extract_extensions(intro),
          added_at: Time.now.utc
        )

        @peers[peer_id] = peer
        peer
      end

      # Remove a peer
      # @param peer_id [String] Peer's instance_id
      def remove_peer(peer_id)
        @peers.delete(peer_id)
      end

      # Get a peer by ID
      # @param peer_id [String] Peer's instance_id
      # @return [Peer, nil]
      def get_peer(peer_id)
        @peers[peer_id]
      end

      # List all known peers
      # @return [Array<Peer>]
      def list_peers
        @peers.values
      end

      # List online peers
      # @return [Array<Peer>]
      def online_peers
        @peers.values.select { |p| p.status == PEER_STATUS[:online] }
      end

      # Check if a peer is online
      # @param peer_id [String] Peer's instance_id
      # @return [Boolean]
      def peer_online?(peer_id)
        peer = @peers[peer_id]
        return false unless peer

        check_peer_status(peer_id)
        peer.status == PEER_STATUS[:online]
      end

      # Refresh peer status
      # @param peer_id [String] Peer's instance_id
      # @return [String] Updated status
      def check_peer_status(peer_id)
        peer = @peers[peer_id]
        return PEER_STATUS[:unknown] unless peer

        begin
          response = http_get("#{peer.url}/health")
          if response && response['status'] == 'ok'
            peer.status = PEER_STATUS[:online]
            peer.last_seen = Time.now.utc
          else
            peer.status = PEER_STATUS[:offline]
          end
        rescue StandardError
          peer.status = PEER_STATUS[:offline]
        end

        peer.status
      end

      # Send introduce to a peer
      # @param peer_id [String] Peer's instance_id
      # @return [Hash, nil] Response from peer
      def introduce_to(peer_id)
        peer = @peers[peer_id]
        return nil unless peer

        my_intro = @identity.introduce
        response = http_post("#{peer.url}/meeting/v1/introduce", my_intro)
        
        # Update peer's introduction if they responded
        if response && response[:status] == 'received'
          peer.introduction = response[:peer_identity] if response[:peer_identity]
          peer.last_seen = Time.now.utc
        end

        response
      end

      # Send a message to a peer
      # @param peer_id [String] Peer's instance_id
      # @param message [Hash] Message to send
      # @return [Hash, nil] Response from peer
      def send_message(peer_id, message)
        peer = @peers[peer_id]
        return nil unless peer

        response = http_post("#{peer.url}/meeting/v1/message", message)
        peer.last_seen = Time.now.utc if response
        response
      end

      # Offer a skill to a peer
      # @param peer_id [String] Peer's instance_id
      # @param skill_id [String] Skill to offer
      # @return [Hash, nil] Offer message that was sent
      def offer_skill_to(peer_id, skill_id)
        peer = @peers[peer_id]
        return nil unless peer

        # Create offer via our protocol
        # The actual sending should be done through the HTTP server
        {
          action: 'offer_skill',
          to: peer_id,
          skill_id: skill_id,
          peer_url: peer.url
        }
      end

      # Request a skill from a peer
      # @param peer_id [String] Peer's instance_id
      # @param description [String] What skill is needed
      # @return [Hash, nil] Request message
      def request_skill_from(peer_id, description)
        peer = @peers[peer_id]
        return nil unless peer

        {
          action: 'request_skill',
          to: peer_id,
          description: description,
          peer_url: peer.url
        }
      end

      # Get common extensions with a peer
      # @param peer_id [String] Peer's instance_id
      # @return [Array<String>] Common extensions
      def common_extensions(peer_id)
        peer = @peers[peer_id]
        return [] unless peer

        my_extensions = @identity.capabilities[:supported_actions] || []
        peer_extensions = peer.extensions || []

        my_extensions & peer_extensions
      end

      # Export peers list to JSON
      # @return [Array<Hash>]
      def export_peers
        @peers.values.map do |peer|
          {
            id: peer.id,
            name: peer.name,
            url: peer.url,
            status: peer.status,
            last_seen: peer.last_seen&.iso8601,
            extensions: peer.extensions,
            added_at: peer.added_at&.iso8601
          }
        end
      end

      # Import peers from saved list
      # @param peers_data [Array<Hash>] Peers data
      def import_peers(peers_data)
        peers_data.each do |data|
          peer = Peer.new(
            id: data['id'] || data[:id],
            name: data['name'] || data[:name],
            url: data['url'] || data[:url],
            status: PEER_STATUS[:unknown],
            last_seen: nil,
            introduction: nil,
            extensions: data['extensions'] || data[:extensions] || [],
            added_at: parse_time(data['added_at'] || data[:added_at])
          )
          @peers[peer.id] = peer
        end
      end

      private

      def fetch_introduction(url)
        response = http_get("#{url.chomp('/')}/meeting/v1/introduce")
        return nil unless response

        # Handle both symbol and string keys
        response.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
      rescue StandardError => e
        $stderr.puts "[PeerManager] Failed to fetch introduction from #{url}: #{e.message}"
        nil
      end

      def extract_extensions(intro)
        intro.dig(:capabilities, :supported_actions) ||
          intro.dig('capabilities', 'supported_actions') ||
          []
      end

      def http_get(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = Net::HTTP::Get.new(uri.request_uri)
        request['Accept'] = 'application/json'

        response = http.request(request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        $stderr.puts "[PeerManager] HTTP GET #{url} failed: #{e.message}"
        nil
      end

      def http_post(url, data)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request.body = JSON.generate(data)

        response = http.request(request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        $stderr.puts "[PeerManager] HTTP POST #{url} failed: #{e.message}"
        nil
      end

      def parse_time(time_str)
        return nil unless time_str

        Time.parse(time_str)
      rescue StandardError
        nil
      end
    end
  end
end
