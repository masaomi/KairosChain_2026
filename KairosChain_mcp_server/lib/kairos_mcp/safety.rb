require 'yaml'
require 'pathname'
require_relative '../kairos_mcp'

module KairosMcp
  class Safety
    # =========================================================================
    # SkillSet Policy Registry
    # =========================================================================

    @policies = {}
    @policy_mutex = Mutex.new

    # Register a named authorization policy for a capability.
    # Keys should match capability method names (e.g. :can_modify_l0).
    def self.register_policy(name, &block)
      @policy_mutex.synchronize { @policies[name.to_sym] = block }
    end

    def self.unregister_policy(name)
      @policy_mutex.synchronize { @policies.delete(name.to_sym) }
    end

    def self.policy_for(name)
      @policy_mutex.synchronize { @policies[name.to_sym] }
    end

    # Thread-safe list of registered policy names.
    # Used by introspection SkillSet for safety visibility.
    def self.registered_policy_names
      @policy_mutex.synchronize { @policies.keys.map(&:to_s) }
    end

    # For testing only
    def self.clear_policies!
      @policy_mutex.synchronize { @policies = {} }
    end

    # =========================================================================

    attr_reader :workspace_root, :current_user

    def initialize
      @config = load_config
      @default_root = File.expand_path(@config['safe_root'] || KairosMcp.data_dir)
      @workspace_root = nil  # Set dynamically via set_workspace
      @current_user = nil    # Set dynamically via set_user (HTTP mode)
      @allowed_paths = @config['allowed_paths'] || []
      @blocklist = @config['blocklist'] || []
      @limits = @config['limits'] || {}
    end

    # Set user context from HTTP authentication
    #
    # @param user_context [Hash, nil] { user: "name", role: "owner"|"member"|"guest", ... }
    def set_user(user_context)
      @current_user = user_context
      if user_context
        $stderr.puts "[INFO] User context set: #{user_context[:user]} (#{user_context[:role]})"
      end
    end

    # Role-based authorization hooks.
    # When no policy is registered (STDIO mode / no Multiuser SkillSet),
    # these return true (permissive fallback). SkillSets register policies
    # via Safety.register_policy to enforce RBAC.

    def can_modify_l0?
      return true unless @current_user
      policy = self.class.policy_for(:can_modify_l0)
      policy ? policy.call(@current_user) : true
    end

    def can_modify_l1?
      return true unless @current_user
      policy = self.class.policy_for(:can_modify_l1)
      policy ? policy.call(@current_user) : true
    end

    def can_modify_l2?
      return true unless @current_user
      policy = self.class.policy_for(:can_modify_l2)
      policy ? policy.call(@current_user) : true
    end

    def can_manage_tokens?
      return true unless @current_user
      policy = self.class.policy_for(:can_manage_tokens)
      policy ? policy.call(@current_user) : true
    end

    def can_manage_grants?
      return true unless @current_user
      policy = self.class.policy_for(:can_manage_grants)
      # Default: deny (unlike can_manage_tokens? which defaults to allow).
      # Service Grant admin ops should be blocked if the policy SkillSet is not loaded.
      policy ? policy.call(@current_user) : false
    end

    # Set workspace root from MCP client (roots) or environment
    def set_workspace(roots = nil)
      if roots && roots.is_a?(Array) && !roots.empty?
        root = roots.first
        if root.is_a?(Hash) && root['uri']
          uri = root['uri']
          @workspace_root = uri.sub(/^file:\/\//, '')
        elsif root.is_a?(String)
          @workspace_root = root.sub(/^file:\/\//, '')
        end
      end

      @workspace_root ||= ENV['KAIROS_WORKSPACE']
      @workspace_root ||= @default_root

      $stderr.puts "[INFO] Workspace root set to: #{@workspace_root}"
      @workspace_root
    end

    def safe_root
      @workspace_root || @default_root
    end

    def validate_path(path)
      absolute_path = File.expand_path(path, safe_root)
      
      # 1. Check if path is within safe_root
      unless inside_safe_root?(absolute_path)
        raise "Access denied: Path is outside safe root (#{safe_root})"
      end

      # 2. Check blocklist
      if blocked?(absolute_path)
        raise "Access denied: File matches blocklist pattern"
      end

      absolute_path
    end

    def max_read_bytes
      @limits['max_read_bytes'] || 100_000
    end

    def max_search_lines
      @limits['max_search_lines'] || 500
    end

    def max_tree_depth
      @limits['max_tree_depth'] || 5
    end

    private

    def load_config
      config_path = KairosMcp.safety_config_path
      if File.exist?(config_path)
        YAML.load_file(config_path)
      else
        {}
      end
    end

    def inside_safe_root?(path)
      path.start_with?(safe_root)
    end

    def blocked?(path)
      filename = File.basename(path)
      @blocklist.any? do |pattern|
        File.fnmatch?(pattern, filename, File::FNM_DOTMATCH)
      end
    end
  end
end
