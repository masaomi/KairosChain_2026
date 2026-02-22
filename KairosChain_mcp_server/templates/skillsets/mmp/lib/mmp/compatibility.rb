# frozen_string_literal: true

module MMP
  class Compatibility
    VERSION_REGEX = /^(\d+)\.(\d+)\.(\d+)(-(.+))?$/
    attr_reader :local_version, :local_extensions, :local_actions

    def initialize(protocol_version:, extensions:, actions:)
      @local_version = protocol_version
      @local_extensions = extensions || []
      @local_actions = actions || []
    end

    def negotiate(peer_info)
      peer_extensions = peer_info[:extensions] || peer_info['extensions'] || []
      peer_capabilities = peer_info[:capabilities] || peer_info['capabilities'] || []
      peer_version = extract_version(peer_info)
      version_result = check_version_compatibility(peer_version)
      common_ext = @local_extensions & peer_extensions
      common_act = @local_actions & peer_capabilities
      mode = determine_mode(version_result, common_ext, common_act)
      { compatible: mode != :incompatible, mode: mode, local_version: @local_version, peer_version: peer_version, version_compatible: version_result[:compatible], common_extensions: common_ext, common_actions: common_act }
    end

    def action_available?(action, peer_capabilities)
      @local_actions.include?(action) && peer_capabilities.include?(action) ? { available: true } : { available: false }
    end

    def fallback_action(preferred, peer_caps)
      { 'discuss' => %w[reflect introduce], 'negotiate' => %w[offer_skill introduce] }.fetch(preferred, []).find { |a| @local_actions.include?(a) && peer_caps.include?(a) }
    end

    private

    def extract_version(info)
      info[:protocol_version] || info['protocol_version'] || info.dig(:identity, :protocol_version) || '1.0.0'
    end

    def check_version_compatibility(peer_version)
      local = parse_version(@local_version); peer = parse_version(peer_version)
      return { compatible: true, message: 'Same version' } if local == peer
      return { compatible: false, message: 'Major version mismatch', can_upgrade: local[:major] < peer[:major] } if local[:major] != peer[:major]
      { compatible: true, message: 'Minor/patch difference', can_upgrade: local[:minor] < peer[:minor] || local[:patch] < peer[:patch] }
    end

    def parse_version(v)
      m = VERSION_REGEX.match(v.to_s)
      m ? { major: m[1].to_i, minor: m[2].to_i, patch: m[3].to_i } : { major: 1, minor: 0, patch: 0 }
    end

    def determine_mode(version_result, common_ext, common_act)
      return :incompatible unless version_result[:compatible]
      common_ext.include?('meeting_protocol_skill_exchange') ? :full : (common_act.include?('introduce') ? :basic : :minimal)
    end
  end
end
