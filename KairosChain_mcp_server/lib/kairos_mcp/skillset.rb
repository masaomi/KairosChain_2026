# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  # Represents a single SkillSet plugin installed in .kairos/skillsets/{name}/
  #
  # A SkillSet is an independent package containing tools, libraries, knowledge,
  # and configuration. The layer declaration determines governance policy
  # (blockchain recording level, approval requirements, RAG indexing).
  class Skillset
    REQUIRED_FIELDS = %w[name version].freeze
    VALID_LAYERS = %i[L0 L1 L2].freeze
    EXECUTABLE_EXTENSIONS = %w[.rb .py .sh .js .ts .pl .lua .exe .so .dylib .dll .class .jar .wasm].freeze

    attr_reader :name, :path, :metadata

    def initialize(path)
      @path = File.expand_path(path)
      @metadata = load_metadata
      @name = @metadata['name']
      @loaded = false
    end

    # Layer as symbol (:L0, :L1, :L2), with override support
    def layer
      @layer_override || default_layer
    end

    def layer=(sym)
      sym = sym.to_sym
      raise ArgumentError, "Invalid layer: #{sym}. Valid: #{VALID_LAYERS}" unless VALID_LAYERS.include?(sym)

      @layer_override = sym
    end

    def default_layer
      raw = @metadata['layer'] || 'L1'
      raw.to_sym
    end

    def version
      @metadata['version']
    end

    def description
      @metadata['description'] || ''
    end

    def author
      @metadata['author'] || ''
    end

    def depends_on
      @metadata['depends_on'] || []
    end

    def provides
      @metadata['provides'] || []
    end

    def tool_class_names
      @metadata['tool_classes'] || []
    end

    def config_files
      @metadata['config_files'] || []
    end

    def knowledge_dir_names
      @metadata['knowledge_dirs'] || []
    end

    def index_knowledge?
      return @metadata['index_knowledge'] == true if @metadata.key?('index_knowledge')

      # Default: L0 and L1 are indexed, L2 is not
      %i[L0 L1].include?(layer)
    end

    # Load the SkillSet code (require lib/ and tools/)
    def load!
      return if @loaded

      lib_dir = File.join(@path, 'lib')
      $LOAD_PATH.unshift(lib_dir) if File.directory?(lib_dir) && !$LOAD_PATH.include?(lib_dir)

      # Require lib entry point if it exists
      entry_point = Dir[File.join(lib_dir, '*.rb')].first
      require entry_point if entry_point

      # Ensure BaseTool is available before loading SkillSet tools
      require_relative 'tools/base_tool'

      # Require all tool files
      tools_dir = File.join(@path, 'tools')
      if File.directory?(tools_dir)
        Dir[File.join(tools_dir, '*.rb')].sort.each { |f| require f }
      end

      @loaded = true
    end

    def loaded?
      @loaded
    end

    # Full path to knowledge directories
    def knowledge_dirs
      knowledge_dir_names.map { |d| File.join(@path, d) }.select { |d| File.directory?(d) }
    end

    def has_knowledge?
      !knowledge_dirs.empty?
    end

    # Compute content hash of all files in the SkillSet
    def content_hash
      Digest::SHA256.hexdigest(all_file_hashes.to_json)
    end

    # Hash of each file for full blockchain recording (L0)
    def all_file_hashes
      hashes = {}
      Dir[File.join(@path, '**', '*')].select { |f| File.file?(f) }.sort.each do |file|
        relative = file.sub("#{@path}/", '')
        hashes[relative] = Digest::SHA256.hexdigest(File.read(file))
      end
      hashes
    end

    # True if the SkillSet contains no executable code (tools/ or lib/)
    # Checks for executable extensions (.rb, .py, .sh, etc.) and shebang lines
    def knowledge_only?
      tools_dir = File.join(@path, 'tools')
      lib_dir = File.join(@path, 'lib')
      no_tools = !File.directory?(tools_dir) ||
        Dir[File.join(tools_dir, '**', '*')].none? { |f|
          File.file?(f) && (executable_extension?(f) || has_shebang?(f))
        }
      no_lib = !File.directory?(lib_dir) ||
        Dir[File.join(lib_dir, '**', '*')].none? { |f|
          File.file?(f) && (executable_extension?(f) || has_shebang?(f))
        }
      no_tools && no_lib
    end

    # Only knowledge-only SkillSets are safe to exchange over the network
    def exchangeable?
      knowledge_only? && valid?
    end

    # Sorted list of relative file paths within the SkillSet
    def file_list
      Dir[File.join(@path, '**', '*')]
        .select { |f| File.file?(f) }
        .map { |f| f.sub("#{@path}/", '') }
        .sort
    end

    def to_h
      {
        name: @name,
        version: version,
        description: description,
        author: author,
        layer: layer,
        depends_on: depends_on,
        provides: provides,
        tool_classes: tool_class_names,
        knowledge_only: knowledge_only?,
        exchangeable: exchangeable?,
        path: @path,
        loaded: @loaded
      }
    end

    def valid?
      REQUIRED_FIELDS.all? { |f| @metadata[f] && !@metadata[f].to_s.strip.empty? }
    rescue StandardError
      false
    end

    private

    def executable_extension?(filepath)
      EXECUTABLE_EXTENSIONS.include?(File.extname(filepath).downcase)
    end

    def has_shebang?(filepath)
      File.binread(filepath, 2) == '#!'
    rescue StandardError
      false
    end

    def load_metadata
      json_path = File.join(@path, 'skillset.json')
      raise ArgumentError, "skillset.json not found in #{@path}" unless File.exist?(json_path)

      JSON.parse(File.read(json_path))
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid skillset.json in #{@path}: #{e.message}"
    end
  end
end
