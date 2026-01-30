# frozen_string_literal: true

module KairosMcp
  module Meeting
    # Compatibility manages protocol version negotiation and
    # extension compatibility between agents.
    #
    # It handles:
    # - Protocol version comparison
    # - Extension intersection (common extensions)
    # - Graceful degradation when capabilities don't match
    # - Version upgrade suggestions
    class Compatibility
      # Semantic versioning comparison
      VERSION_REGEX = /^(\d+)\.(\d+)\.(\d+)(-(.+))?$/

      attr_reader :local_version, :local_extensions, :local_actions

      def initialize(protocol_version:, extensions:, actions:)
        @local_version = protocol_version
        @local_extensions = extensions || []
        @local_actions = actions || []
      end

      # Negotiate compatibility with a peer
      # @param peer_info [Hash] Peer's introduce payload
      # @return [Hash] Compatibility result
      def negotiate(peer_info)
        peer_extensions = peer_info[:extensions] || peer_info['extensions'] || []
        peer_capabilities = peer_info[:capabilities] || peer_info['capabilities'] || []
        peer_version = extract_version(peer_info)

        # Check version compatibility
        version_result = check_version_compatibility(peer_version)
        
        # Find common extensions
        common_extensions = @local_extensions & peer_extensions
        
        # Find common actions (from capabilities)
        common_actions = @local_actions & peer_capabilities
        
        # Determine communication mode
        mode = determine_mode(version_result, common_extensions, common_actions)

        {
          compatible: mode != :incompatible,
          mode: mode,
          local_version: @local_version,
          peer_version: peer_version,
          version_compatible: version_result[:compatible],
          version_message: version_result[:message],
          common_extensions: common_extensions,
          common_actions: common_actions,
          local_only_extensions: @local_extensions - peer_extensions,
          peer_only_extensions: peer_extensions - @local_extensions,
          can_upgrade: version_result[:can_upgrade],
          suggested_actions: suggest_actions(mode, common_extensions)
        }
      end

      # Check if a specific action can be used with a peer
      # @param action [String] Action name
      # @param peer_capabilities [Array<String>] Peer's capabilities
      # @return [Hash] Result
      def action_available?(action, peer_capabilities)
        if @local_actions.include?(action) && peer_capabilities.include?(action)
          { available: true, action: action }
        elsif !@local_actions.include?(action)
          { available: false, reason: 'not_supported_locally', action: action }
        else
          { available: false, reason: 'not_supported_by_peer', action: action }
        end
      end

      # Get fallback action when preferred action is not available
      # @param preferred_action [String] Action we wanted to use
      # @param peer_capabilities [Array<String>] Peer's capabilities
      # @return [String, nil] Fallback action or nil
      def fallback_action(preferred_action, peer_capabilities)
        # Define fallback chains
        fallbacks = {
          'discuss' => ['reflect', 'introduce'],
          'negotiate' => ['offer_skill', 'introduce'],
          'debate' => ['reflect', 'introduce']
        }

        chain = fallbacks[preferred_action] || []
        
        chain.find do |action|
          @local_actions.include?(action) && peer_capabilities.include?(action)
        end
      end

      # Check if extension can be shared with peer
      # @param extension_name [String] Extension name
      # @param peer_extensions [Array<String>] Peer's current extensions
      # @return [Hash] Result
      def can_share_extension?(extension_name, peer_extensions)
        if peer_extensions.include?(extension_name)
          { can_share: false, reason: 'peer_already_has', extension: extension_name }
        elsif !@local_extensions.include?(extension_name)
          { can_share: false, reason: 'not_available_locally', extension: extension_name }
        else
          { can_share: true, extension: extension_name }
        end
      end

      # Generate compatibility report for logging/debugging
      # @param peer_info [Hash] Peer's introduce payload
      # @return [String] Human-readable report
      def compatibility_report(peer_info)
        result = negotiate(peer_info)
        
        lines = []
        lines << "=== Compatibility Report ==="
        lines << "Mode: #{result[:mode]}"
        lines << ""
        lines << "Version:"
        lines << "  Local: #{result[:local_version]}"
        lines << "  Peer:  #{result[:peer_version]}"
        lines << "  Compatible: #{result[:version_compatible]}"
        lines << ""
        lines << "Common Extensions (#{result[:common_extensions].size}):"
        result[:common_extensions].each { |e| lines << "  - #{e}" }
        lines << ""
        lines << "Local Only Extensions:"
        result[:local_only_extensions].each { |e| lines << "  - #{e}" }
        lines << ""
        lines << "Peer Only Extensions:"
        result[:peer_only_extensions].each { |e| lines << "  - #{e}" }
        lines << ""
        lines << "Suggested Actions:"
        result[:suggested_actions].each { |a| lines << "  - #{a}" }
        lines << "=========================="
        
        lines.join("\n")
      end

      private

      def extract_version(peer_info)
        # Try different places where version might be
        peer_info[:protocol_version] ||
          peer_info['protocol_version'] ||
          peer_info.dig(:identity, :protocol_version) ||
          peer_info.dig('identity', 'protocol_version') ||
          '1.0.0'
      end

      def check_version_compatibility(peer_version)
        local_parts = parse_version(@local_version)
        peer_parts = parse_version(peer_version)

        return { compatible: true, message: 'Same version' } if local_parts == peer_parts

        # Major version must match
        if local_parts[:major] != peer_parts[:major]
          return {
            compatible: false,
            message: "Major version mismatch: #{@local_version} vs #{peer_version}",
            can_upgrade: local_parts[:major] < peer_parts[:major]
          }
        end

        # Minor version differences are OK with backward compatibility
        if local_parts[:minor] < peer_parts[:minor]
          return {
            compatible: true,
            message: "Peer has newer minor version: #{peer_version}",
            can_upgrade: true
          }
        end

        if local_parts[:minor] > peer_parts[:minor]
          return {
            compatible: true,
            message: "Local has newer minor version, using compatible subset",
            can_upgrade: false
          }
        end

        # Patch differences are always compatible
        {
          compatible: true,
          message: "Patch version difference: #{@local_version} vs #{peer_version}",
          can_upgrade: local_parts[:patch] < peer_parts[:patch]
        }
      end

      def parse_version(version_string)
        match = VERSION_REGEX.match(version_string.to_s)
        return { major: 1, minor: 0, patch: 0 } unless match

        {
          major: match[1].to_i,
          minor: match[2].to_i,
          patch: match[3].to_i,
          prerelease: match[5]
        }
      end

      def determine_mode(version_result, common_extensions, common_actions)
        return :incompatible unless version_result[:compatible]

        if common_extensions.include?('meeting_protocol_skill_exchange')
          :full  # Can do skill exchange
        elsif common_actions.include?('introduce') && common_actions.include?('goodbye')
          :basic  # Core actions only
        else
          :minimal  # Just introduce
        end
      end

      def suggest_actions(mode, common_extensions)
        suggestions = []

        case mode
        when :full
          suggestions << "Full communication available"
          suggestions << "Can exchange skills"
          if common_extensions.size > 1
            suggestions << "Additional extensions available: #{common_extensions.join(', ')}"
          end
        when :basic
          suggestions << "Basic communication only"
          suggestions << "Consider requesting skill_exchange extension from peer"
        when :minimal
          suggestions << "Minimal communication"
          suggestions << "Exchange introduce messages to learn more about peer capabilities"
        when :incompatible
          suggestions << "Communication not possible"
          suggestions << "Protocol versions are incompatible"
        end

        suggestions
      end
    end
  end
end
