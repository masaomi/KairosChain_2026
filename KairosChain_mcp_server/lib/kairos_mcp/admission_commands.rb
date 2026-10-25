# frozen_string_literal: true

require 'uri'
require_relative 'admission_records'

module KairosMcp
  # Operator commands behind `kairos-chain peer pin …` and
  # `kairos-chain skillset publish|unpublish` (secure MMP v1, I4).
  #
  # Each returns a Hash and raises AdmissionRecords::Error when nothing was
  # recorded. Additions and publications are reached only from the CLI;
  # the peer_pin MCP tool reaches revoke alone.
  module AdmissionCommands
    DEFAULT_PORTS = { 'https' => 443, 'http' => 80 }.freeze

    module_function

    def records
      AdmissionRecords.for_data_dir(KairosMcp.data_dir)
    end

    # Where a command acts, so the operator can see it before trusting it.
    def context
      r = records
      {
        data_dir: KairosMcp.data_dir,
        ledger: r.ledger_path,
        key_sha256: r.own_key_sha256
      }
    end

    # "scheme://host[:port]", lowercased, default port dropped; nil if not http(s).
    def normalize_origin(url)
      uri = URI.parse(url.to_s.strip)
      scheme = uri.scheme&.downcase
      return nil unless DEFAULT_PORTS.key?(scheme) && uri.host && !uri.host.empty?
      return nil unless uri.path.to_s.empty? || uri.path == '/'
      return nil if uri.query || uri.fragment || uri.userinfo

      host = uri.host.downcase
      host = "[#{host}]" if host.include?(':') && !host.start_with?('[')
      uri.port && uri.port != DEFAULT_PORTS[scheme] ? "#{scheme}://#{host}:#{uri.port}" : "#{scheme}://#{host}"
    rescue URI::InvalidURIError
      nil
    end

    def pin_add(alias_name, key_sha256, url:)
      alias_name = alias_name.to_s
      key_sha256 = key_sha256.to_s.downcase.delete(':')
      origin = normalize_origin(url)
      raise AdmissionRecords::Error, "url must be http(s)://host[:port] with nothing after it (got #{url.inspect})" unless origin
      raise AdmissionRecords::Error, 'this key is this instance\'s own key' if key_sha256 == records.own_key_sha256

      existing = records.pin_for_alias(alias_name)
      if existing && existing['key_sha256'] == key_sha256 && existing['url'] == origin
        return { recorded: false, reason: 'already pinned', pin: existing }.merge(context)
      end

      replaces = existing && existing['key_sha256'] != key_sha256 ? existing['key_sha256'] : nil
      record = records.append(AdmissionRecords::PIN,
                              { 'action' => 'add', 'alias' => alias_name, 'key_sha256' => key_sha256,
                                'url' => origin, 'replaces' => replaces },
                              private_key: AdmissionRecords.load_private_key(KairosMcp.data_dir))
      { recorded: true, record: record, replaces: replaces }.merge(context)
    end

    # target: an alias or a full key hash.
    def pin_revoke(target)
      target = target.to_s.downcase.delete(':')
      pin = records.admitted_pins.find { |p| p['alias'] == target || p['key_sha256'] == target }
      raise AdmissionRecords::Error, "no admitted pin matches #{target.inspect}" unless pin

      record = records.append(AdmissionRecords::PIN,
                              { 'action' => 'revoke', 'alias' => pin['alias'], 'key_sha256' => pin['key_sha256'] },
                              private_key: AdmissionRecords.load_private_key(KairosMcp.data_dir))
      { recorded: true, record: record }.merge(context)
    end

    def pin_list
      r = records
      st = r.state
      {
        status: st.status, cause: st.cause,
        pins: r.admitted_pins,
        ignored_records: st.ignored
      }.merge(context)
    end

    def publish(name)
      skillset = find_skillset(name)
      raise AdmissionRecords::Error, "SkillSet '#{name}' is not exchangeable (it contains code), so it cannot be published" unless skillset.exchangeable?

      if records.published?(skillset.name, skillset.content_hash)
        return { recorded: false, reason: 'already published at this content', name: skillset.name,
                 content_hash: skillset.content_hash }.merge(context)
      end

      record = records.append(AdmissionRecords::PUBLICATION,
                              { 'action' => 'publish', 'name' => skillset.name, 'content_hash' => skillset.content_hash },
                              private_key: AdmissionRecords.load_private_key(KairosMcp.data_dir))
      { recorded: true, record: record }.merge(context)
    end

    def unpublish(name)
      skillset = find_skillset(name)
      record = records.append(AdmissionRecords::PUBLICATION,
                              { 'action' => 'unpublish', 'name' => skillset.name, 'content_hash' => skillset.content_hash },
                              private_key: AdmissionRecords.load_private_key(KairosMcp.data_dir))
      { recorded: true, record: record }.merge(context)
    end

    def find_skillset(name)
      require_relative 'skillset_manager'
      skillset = SkillSetManager.new.find_skillset(name.to_s)
      raise AdmissionRecords::Error, "no SkillSet named #{name.inspect}" unless skillset

      skillset
    end
  end
end
