# frozen_string_literal: true

require 'fileutils'
require_relative 'knowledge_provider'
require_relative 'context_manager'
require_relative 'dsl_skills_provider'

module KairosMcp
  # ResourceRegistry: Unified resource access layer for all layers (L0/L1/L2)
  #
  # Provides URI-based access to all KairosChain resources:
  # - l0://kairos.md, l0://kairos.rb (L0 skills)
  # - knowledge://{name}, knowledge://{name}/scripts/{file} (L1)
  # - context://{session}/{name}, context://{session}/{name}/scripts/{file} (L2)
  #
  class ResourceRegistry
    SKILLS_DIR = File.expand_path('../../skills', __dir__)
    KNOWLEDGE_DIR = File.expand_path('../../knowledge', __dir__)
    CONTEXT_DIR = File.expand_path('../../context', __dir__)

    # MIME type mappings
    MIME_TYPES = {
      '.md' => 'text/markdown',
      '.rb' => 'text/x-ruby',
      '.py' => 'text/x-python',
      '.sh' => 'application/x-sh',
      '.bash' => 'application/x-sh',
      '.js' => 'text/javascript',
      '.ts' => 'text/typescript',
      '.json' => 'application/json',
      '.yaml' => 'application/yaml',
      '.yml' => 'application/yaml',
      '.html' => 'text/html',
      '.css' => 'text/css',
      '.txt' => 'text/plain',
      '.png' => 'image/png',
      '.jpg' => 'image/jpeg',
      '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.svg' => 'image/svg+xml',
      '.pdf' => 'application/pdf'
    }.freeze

    def initialize
      @knowledge_provider = KnowledgeProvider.new(KNOWLEDGE_DIR, vector_search_enabled: false)
      @context_manager = ContextManager.new(CONTEXT_DIR)
    end

    # List all resources with optional filtering
    #
    # @param filter [String, nil] Filter by layer or name (e.g., "l0", "knowledge", "context", "example_knowledge")
    # @param type [String] Resource type filter: "all", "md", "scripts", "assets", "references"
    # @param layer [String] Layer filter: "all", "l0", "l1", "l2"
    # @return [Array<Hash>] List of resource info
    def list(filter: nil, type: 'all', layer: 'all')
      resources = []

      # L0 resources
      if include_layer?(layer, 'l0') && include_filter?(filter, 'l0')
        resources.concat(list_l0_resources(type))
      end

      # L1 (knowledge) resources
      if include_layer?(layer, 'l1') && (filter.nil? || filter == 'knowledge' || knowledge_name?(filter))
        resources.concat(list_l1_resources(filter, type))
      end

      # L2 (context) resources
      if include_layer?(layer, 'l2') && (filter.nil? || filter == 'context' || context_filter?(filter))
        resources.concat(list_l2_resources(filter, type))
      end

      resources
    end

    # Read a resource by URI
    #
    # @param uri [String] Resource URI (e.g., "knowledge://example/scripts/test.sh")
    # @return [Hash, nil] Resource content and metadata, or nil if not found
    def read(uri)
      parsed = parse_uri(uri)
      return nil unless parsed

      case parsed[:scheme]
      when 'l0'
        read_l0_resource(parsed)
      when 'knowledge'
        read_l1_resource(parsed)
      when 'context'
        read_l2_resource(parsed)
      else
        nil
      end
    end

    # Parse a URI into components
    #
    # @param uri [String] Resource URI
    # @return [Hash, nil] Parsed components or nil if invalid
    def parse_uri(uri)
      # Match: scheme://path
      match = uri.match(%r{\A(\w+)://(.+)\z})
      return nil unless match

      scheme = match[1]
      path = match[2]

      case scheme
      when 'l0'
        { scheme: scheme, file: path }
      when 'knowledge'
        parse_knowledge_uri(path)
      when 'context'
        parse_context_uri(path)
      else
        nil
      end
    end

    private

    # === L0 (Skills) ===

    def list_l0_resources(type)
      resources = []

      if type == 'all' || type == 'md'
        # kairos.md (Constitution)
        md_path = File.join(SKILLS_DIR, 'kairos.md')
        if File.exist?(md_path)
          resources << build_resource_info(
            uri: 'l0://kairos.md',
            name: 'kairos.md',
            layer: 'L0',
            type: 'md',
            path: md_path
          )
        end

        # kairos.rb (Law)
        rb_path = File.join(SKILLS_DIR, 'kairos.rb')
        if File.exist?(rb_path)
          resources << build_resource_info(
            uri: 'l0://kairos.rb',
            name: 'kairos.rb',
            layer: 'L0',
            type: 'dsl',
            path: rb_path
          )
        end
      end

      resources
    end

    def read_l0_resource(parsed)
      file = parsed[:file]
      path = File.join(SKILLS_DIR, file)

      return nil unless File.exist?(path) && File.file?(path)
      # Security: only allow kairos.md and kairos.rb
      return nil unless %w[kairos.md kairos.rb].include?(file)

      build_resource_content(path, 'l0', "l0://#{file}")
    end

    # === L1 (Knowledge) ===

    def list_l1_resources(filter, type)
      resources = []
      target_names = filter && knowledge_name?(filter) ? [filter] : nil

      knowledge_dirs.each do |dir|
        name = File.basename(dir)
        next if target_names && !target_names.include?(name)

        # Main MD file
        if type == 'all' || type == 'md'
          md_file = File.join(dir, "#{name}.md")
          if File.exist?(md_file)
            resources << build_resource_info(
              uri: "knowledge://#{name}",
              name: "#{name}.md",
              layer: 'L1',
              type: 'md',
              path: md_file
            )
          end
        end

        # Scripts
        if type == 'all' || type == 'scripts'
          resources.concat(list_subdir_resources(dir, name, 'scripts', 'L1', 'knowledge'))
        end

        # Assets
        if type == 'all' || type == 'assets'
          resources.concat(list_subdir_resources(dir, name, 'assets', 'L1', 'knowledge'))
        end

        # References
        if type == 'all' || type == 'references'
          resources.concat(list_subdir_resources(dir, name, 'references', 'L1', 'knowledge'))
        end
      end

      resources
    end

    def read_l1_resource(parsed)
      name = parsed[:name]
      return nil unless name

      knowledge_dir = File.join(KNOWLEDGE_DIR, name)
      return nil unless File.directory?(knowledge_dir)

      if parsed[:subdir] && parsed[:file]
        # Subdir file (scripts/assets/references)
        path = File.join(knowledge_dir, parsed[:subdir], parsed[:file])
        return nil unless File.exist?(path) && File.file?(path)

        uri = "knowledge://#{name}/#{parsed[:subdir]}/#{parsed[:file]}"
        build_resource_content(path, 'l1', uri)
      else
        # Main MD file
        md_file = File.join(knowledge_dir, "#{name}.md")
        return nil unless File.exist?(md_file)

        uri = "knowledge://#{name}"
        build_resource_content(md_file, 'l1', uri)
      end
    end

    def parse_knowledge_uri(path)
      parts = path.split('/')
      return nil if parts.empty?

      name = parts[0]
      result = { scheme: 'knowledge', name: name }

      if parts.length >= 3
        # knowledge://name/subdir/file
        result[:subdir] = parts[1]
        result[:file] = parts[2..].join('/')
      elsif parts.length == 2
        # knowledge://name/subdir (list directory)
        result[:subdir] = parts[1]
      end

      result
    end

    # === L2 (Context) ===

    def list_l2_resources(filter, type)
      resources = []

      session_dirs.each do |session_dir|
        session_id = File.basename(session_dir)

        # Filter by session if specified
        if filter && context_filter?(filter)
          parsed = parse_context_filter(filter)
          next if parsed[:session] && parsed[:session] != session_id
        end

        context_dirs(session_dir).each do |context_dir|
          name = File.basename(context_dir)

          # Filter by context name if specified
          if filter && context_filter?(filter)
            parsed = parse_context_filter(filter)
            next if parsed[:name] && parsed[:name] != name
          end

          # Main MD file
          if type == 'all' || type == 'md'
            md_file = File.join(context_dir, "#{name}.md")
            if File.exist?(md_file)
              resources << build_resource_info(
                uri: "context://#{session_id}/#{name}",
                name: "#{name}.md",
                layer: 'L2',
                type: 'md',
                path: md_file,
                session: session_id
              )
            end
          end

          # Scripts
          if type == 'all' || type == 'scripts'
            resources.concat(list_context_subdir_resources(context_dir, session_id, name, 'scripts'))
          end

          # Assets
          if type == 'all' || type == 'assets'
            resources.concat(list_context_subdir_resources(context_dir, session_id, name, 'assets'))
          end

          # References
          if type == 'all' || type == 'references'
            resources.concat(list_context_subdir_resources(context_dir, session_id, name, 'references'))
          end
        end
      end

      resources
    end

    def read_l2_resource(parsed)
      session_id = parsed[:session]
      name = parsed[:name]
      return nil unless session_id && name

      context_dir = File.join(CONTEXT_DIR, session_id, name)
      return nil unless File.directory?(context_dir)

      if parsed[:subdir] && parsed[:file]
        # Subdir file
        path = File.join(context_dir, parsed[:subdir], parsed[:file])
        return nil unless File.exist?(path) && File.file?(path)

        uri = "context://#{session_id}/#{name}/#{parsed[:subdir]}/#{parsed[:file]}"
        build_resource_content(path, 'l2', uri)
      else
        # Main MD file
        md_file = File.join(context_dir, "#{name}.md")
        return nil unless File.exist?(md_file)

        uri = "context://#{session_id}/#{name}"
        build_resource_content(md_file, 'l2', uri)
      end
    end

    def parse_context_uri(path)
      parts = path.split('/')
      return nil if parts.length < 2

      session_id = parts[0]
      name = parts[1]
      result = { scheme: 'context', session: session_id, name: name }

      if parts.length >= 4
        # context://session/name/subdir/file
        result[:subdir] = parts[2]
        result[:file] = parts[3..].join('/')
      elsif parts.length == 3
        # context://session/name/subdir
        result[:subdir] = parts[2]
      end

      result
    end

    # === Helper Methods ===

    def list_subdir_resources(base_dir, name, subdir, layer, scheme)
      resources = []
      subdir_path = File.join(base_dir, subdir)

      return resources unless File.directory?(subdir_path)

      Dir[File.join(subdir_path, '**/*')].each do |file|
        next unless File.file?(file)

        relative = file.sub("#{subdir_path}/", '')
        resources << build_resource_info(
          uri: "#{scheme}://#{name}/#{subdir}/#{relative}",
          name: File.basename(file),
          layer: layer,
          type: subdir.chomp('s'), # scripts -> script
          path: file
        )
      end

      resources
    end

    def list_context_subdir_resources(context_dir, session_id, name, subdir)
      resources = []
      subdir_path = File.join(context_dir, subdir)

      return resources unless File.directory?(subdir_path)

      Dir[File.join(subdir_path, '**/*')].each do |file|
        next unless File.file?(file)

        relative = file.sub("#{subdir_path}/", '')
        resources << build_resource_info(
          uri: "context://#{session_id}/#{name}/#{subdir}/#{relative}",
          name: File.basename(file),
          layer: 'L2',
          type: subdir.chomp('s'),
          path: file,
          session: session_id
        )
      end

      resources
    end

    def build_resource_info(uri:, name:, layer:, type:, path:, session: nil)
      info = {
        uri: uri,
        name: name,
        layer: layer,
        type: type,
        mime_type: mime_type_for(path),
        size: File.size(path),
        modified_at: File.mtime(path).iso8601
      }
      info[:session] = session if session
      info
    end

    def build_resource_content(path, layer, uri)
      ext = File.extname(path).downcase
      mime = mime_type_for(path)

      result = {
        uri: uri,
        layer: layer.upcase,
        mime_type: mime,
        size: File.size(path),
        path: path,
        modified_at: File.mtime(path).iso8601
      }

      # For text files, include content
      if text_file?(mime)
        result[:content] = File.read(path)
      else
        result[:content] = "[Binary file - #{File.size(path)} bytes]"
        result[:binary] = true
      end

      # For executable scripts
      if File.executable?(path) && script_type?(ext)
        result[:executable] = true
      end

      result
    end

    def mime_type_for(path)
      ext = File.extname(path).downcase
      MIME_TYPES[ext] || 'application/octet-stream'
    end

    def text_file?(mime)
      mime.start_with?('text/') || 
        %w[application/json application/yaml application/x-sh].include?(mime)
    end

    def script_type?(ext)
      %w[.sh .bash .py .rb .js .ts].include?(ext)
    end

    def include_layer?(layer_filter, target)
      layer_filter == 'all' || layer_filter == target
    end

    def include_filter?(filter, target)
      filter.nil? || filter == target
    end

    def knowledge_name?(filter)
      return false if filter.nil?
      return false if %w[l0 knowledge context].include?(filter)

      # Check if it's a knowledge name
      File.directory?(File.join(KNOWLEDGE_DIR, filter))
    end

    def context_filter?(filter)
      return false if filter.nil?

      filter.start_with?('session_') || filter.include?('/')
    end

    def parse_context_filter(filter)
      parts = filter.split('/')
      {
        session: parts[0],
        name: parts[1]
      }
    end

    def knowledge_dirs
      Dir[File.join(KNOWLEDGE_DIR, '*')].select { |f| File.directory?(f) }
    end

    def session_dirs
      Dir[File.join(CONTEXT_DIR, '*')].select { |f| File.directory?(f) }
    end

    def context_dirs(session_dir)
      Dir[File.join(session_dir, '*')].select { |f| File.directory?(f) }
    end
  end
end
