# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'

module MMP
  class PeerManager
    PEER_STATUS = { unknown: 'unknown', online: 'online', offline: 'offline', error: 'error' }.freeze

    Peer = Struct.new(:id, :name, :url, :status, :last_seen, :introduction, :extensions, :added_at, keyword_init: true)

    def initialize(identity:, config: {})
      @identity = identity
      @config = config
      @peers = {}
      @timeout = config['timeout'] || 10
    end

    def add_peer(url)
      intro = fetch_introduction(url)
      return nil unless intro

      peer_id = intro.dig(:identity, :instance_id) || intro.dig('identity', 'instance_id')
      return nil unless peer_id

      peer = Peer.new(
        id: peer_id, name: intro.dig(:identity, :name) || intro.dig('identity', 'name'),
        url: url.chomp('/'), status: PEER_STATUS[:online], last_seen: Time.now.utc,
        introduction: intro, extensions: extract_extensions(intro), added_at: Time.now.utc
      )
      @peers[peer_id] = peer
      peer
    end

    def remove_peer(peer_id) = @peers.delete(peer_id)
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
      @peers.values.map { |p| { id: p.id, name: p.name, url: p.url, status: p.status, last_seen: p.last_seen&.iso8601, extensions: p.extensions, added_at: p.added_at&.iso8601 } }
    end

    def import_peers(peers_data)
      peers_data.each do |data|
        peer = Peer.new(id: data['id']||data[:id], name: data['name']||data[:name], url: data['url']||data[:url], status: PEER_STATUS[:unknown], last_seen: nil, introduction: nil, extensions: data['extensions']||data[:extensions]||[], added_at: parse_time(data['added_at']||data[:added_at]))
        @peers[peer.id] = peer
      end
    end

    private

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
