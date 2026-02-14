require 'yaml'
require 'pathname'
require_relative '../kairos_mcp'

module KairosMcp
  class Safety
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

    # Phase 2: Role-based authorization hooks
    # These methods return true for all roles in Phase 1.
    # Override behavior when role-based authorization is implemented.

    # Check if current user can modify L0 skills
    # Phase 2: Only 'owner' role
    def can_modify_l0?
      true # Phase 1: no role restrictions
    end

    # Check if current user can modify L1 knowledge
    # Phase 2: 'owner' and 'member' roles
    def can_modify_l1?
      true # Phase 1: no role restrictions
    end

    # Check if current user can modify L2 context
    # Phase 2: all roles (guests limited to own context)
    def can_modify_l2?
      true # Phase 1: no role restrictions
    end

    # Check if current user can manage tokens
    # Phase 2: Only 'owner' role
    def can_manage_tokens?
      true # Phase 1: no role restrictions
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
