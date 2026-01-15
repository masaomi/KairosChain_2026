require 'yaml'
require 'pathname'

module KairosMcp
  class Safety
    CONFIG_PATH = File.expand_path('../../config/safety.yml', __dir__)
    SERVER_ROOT = File.expand_path('../..', __dir__)

    attr_reader :workspace_root

    def initialize
      @config = load_config
      @default_root = File.expand_path(@config['safe_root'] || SERVER_ROOT)
      @workspace_root = nil  # Set dynamically via set_workspace
      @allowed_paths = @config['allowed_paths'] || []
      @blocklist = @config['blocklist'] || []
      @limits = @config['limits'] || {}
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
      if File.exist?(CONFIG_PATH)
        YAML.load_file(CONFIG_PATH)
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
