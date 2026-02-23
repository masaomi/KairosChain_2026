# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'fileutils'

module MMP
  class PeerManager
    PEER_STATUS = { unknown: 'unknown', online: 'online', offline: 'offline', error: 'error' }.freeze
    PEERS_FILE = 'peers.json'

    Peer = Struct.new(:id, :name, :url, :status, :last_seen, :introduction,
                      :extensions, :added_at, :public_key, :verified,
                      keyword_init: true)

    def initialize(identity:, config: {}, data_dir: nil)
      @identity = identity
      @config = config
      @data_dir = data_dir
      @peers = {}
      @timeout = config['timeout'] || 10
      @mutex = Mutex.new
      load_peers if @data_dir
    end

    def add_peer(url)
      intro = fetch_introduction(url)
      return nil unless intro

      peer_id = intro.dig(:identity, :instance_id) || intro.dig('identity', 'instance_id')
      return nil unless peer_id

      # Signature verification (H2 fix)
      verified = false
      public_key = intro[:public_key] || intro['public_key']
      if public_key && (sig = intro[:identity_signature] || intro['identity_signature'])
        begin
          identity_data = intro[:identity] || intro['identity']
          canonical = JSON.generate(identity_data, sort_keys: true)
          crypto = MMP::Crypto.new(auto_generate: false)
          verified = crypto.verify_signature(canonical, sig, public_key)
        rescue StandardError
          verified = false
        end
      end

      @mutex.synchronize do
        # TOFU: detect public key change for known peers
        existing = @peers[peer_id]
        if existing&.public_key && public_key && existing.public_key != public_key
          $stderr.puts "[PeerManager] WARNING: Public key changed for peer #{peer_id}! Possible MITM."
          verified = false
        end

        peer = Peer.new(
          id: peer_id, name: intro.dig(:identity, :name) || intro.dig('identity', 'name'),
          url: url.chomp('/'), status: PEER_STATUS[:online], last_seen: Time.now.utc,
          introduction: intro, extensions: extract_extensions(intro), added_at: Time.now.utc,
          public_key: public_key, verified: verified
        )
        @peers[peer_id] = peer
        save_peers
        peer
      end
    end

    def remove_peer(peer_id)
      @mutex.synchronize do
        result = @peers.delete(peer_id)
        save_peers
        result
      end
    end

    def get_peer(peer_id) = @peers[peer_id]
    def list_peers = @peers.values
    def online_peers = @peers.values.select { |p| p.status == PEER_STATUS[:online] }

    def peer_online?(peer_id)
      peer = @peers[peer_id]
      return false unless peer
      check_peer_status(peer_id)
      peer.status == PEER_STATUS[:online]
    end

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
      save_peers
      peer.status
    end

    def introduce_to(peer_id)
      peer = @peers[peer_id]
      return nil unless peer
      my_intro = @identity.introduce
      response = http_post("#{peer.url}/meeting/v1/introduce", my_intro)
      if response && response[:status] == 'received'
        peer.introduction = response[:peer_identity] if response[:peer_identity]
        peer.last_seen = Time.now.utc
        save_peers
      end
      response
    end

    def send_message(peer_id, message)
      peer = @peers[peer_id]
      return nil unless peer
      response = http_post("#{peer.url}/meeting/v1/message", message)
      peer.last_seen = Time.now.utc if response
      response
    end

    def export_peers
      @peers.values.map { |p| { id: p.id, name: p.name, url: p.url, status: p.status, last_seen: p.last_seen&.iso8601, extensions: p.extensions, added_at: p.added_at&.iso8601, public_key: p.public_key, verified: p.verified } }
    end

    def import_peers(peers_data)
      @mutex.synchronize do
        peers_data.each do |data|
          peer = Peer.new(id: data['id']||data[:id], name: data['name']||data[:name], url: data['url']||data[:url], status: PEER_STATUS[:unknown], last_seen: nil, introduction: nil, extensions: data['extensions']||data[:extensions]||[], added_at: parse_time(data['added_at']||data[:added_at]), public_key: data['public_key']||data[:public_key], verified: data['verified']||data[:verified]||false)
          @peers[peer.id] = peer
        end
        save_peers
      end
    end

    private

    # --- Persistence ---

    def peers_file_path
      return nil unless @data_dir
      File.join(@data_dir, PEERS_FILE)
    end

    def load_peers
      path = peers_file_path
      return unless path && File.exist?(path)

      data = JSON.parse(File.read(path), symbolize_names: true)
      data.each do |peer_data|
        peer = Peer.new(
          id: peer_data[:id],
          name: peer_data[:name],
          url: peer_data[:url],
          status: PEER_STATUS[:unknown], # After restart, status is unknown
          last_seen: parse_time(peer_data[:last_seen]),
          introduction: nil,             # Session data is reset
          extensions: peer_data[:extensions] || [],
          added_at: parse_time(peer_data[:added_at]),
          public_key: peer_data[:public_key],
          verified: peer_data[:verified] || false
        )
        @peers[peer.id] = peer
      end
    rescue JSON::ParserError, StandardError => e
      $stderr.puts "[PeerManager] Failed to load peers: #{e.message}"
      @peers = {}
    end

    def save_peers
      path = peers_file_path
      return unless path

      FileUtils.mkdir_p(File.dirname(path))
      data = @peers.values.map do |p|
        {
          id: p.id,
          name: p.name,
          url: p.url,
          last_seen: p.last_seen&.iso8601,
          extensions: p.extensions,
          added_at: p.added_at&.iso8601,
          public_key: p.public_key,
          verified: p.verified
        }
      end
      File.write(path, JSON.pretty_generate(data))
    rescue StandardError => e
      $stderr.puts "[PeerManager] Failed to save peers: #{e.message}"
    end

    # --- HTTP helpers ---

    def fetch_introduction(url)
      response = http_get("#{url.chomp('/')}/meeting/v1/introduce")
      return nil unless response
      response.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
    rescue StandardError => e
      $stderr.puts "[PeerManager] Failed to fetch introduction from #{url}: #{e.message}"
      nil
    end

    def extract_extensions(intro)
      intro.dig(:capabilities, :supported_actions) || intro.dig('capabilities', 'supported_actions') || []
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
      Time.parse(time_str) rescue nil
    end
  end
end
