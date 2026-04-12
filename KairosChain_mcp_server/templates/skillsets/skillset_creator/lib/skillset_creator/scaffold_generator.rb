# frozen_string_literal: true

module SkillsetCreator
  # Generates SkillSet directory structures with skeleton files.
  module ScaffoldGenerator
    module_function

    NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

    def validate_name!(name)
      return if name.match?(NAME_PATTERN)

      raise ArgumentError, "Invalid SkillSet name '#{name}'. Must match /#{NAME_PATTERN.source}/"
    end

    def validate_output!(output_path, name)
      target = File.join(output_path, name)
      raise ArgumentError, "Directory already exists: #{target}" if File.directory?(target)
      raise ArgumentError, "Parent directory does not exist: #{output_path}" unless File.directory?(output_path)
    end

    def preview(name:, tools: [], knowledge: [], has_config: true, depends_on: [], has_plugin: false)
      validate_name!(name)
      build_tree(name: name, tools: tools, knowledge: knowledge, has_config: has_config, depends_on: depends_on, has_plugin: has_plugin)
    end

    def generate(name:, output_path:, tools: [], knowledge: [], has_config: true, depends_on: [], has_plugin: false)
      validate_name!(name)
      validate_output!(output_path, name)

      root = File.join(output_path, name)
      created_files = []

      FileUtils.mkdir_p(root)

      created_files << write_skillset_json(root, name, tools, knowledge, has_config, depends_on, has_plugin)
      created_files << write_entry_point(root, name)
      created_files.concat(write_tool_skeletons(root, name, tools))
      created_files.concat(write_knowledge_skeletons(root, knowledge))
      created_files << write_config(root, name) if has_config
      created_files.concat(write_plugin_skeleton(root, name)) if has_plugin

      created_files
    end

    def build_tree(name:, tools: [], knowledge: [], has_config: true, depends_on: [], has_plugin: false)
      lines = ["#{name}/"]
      lines << '├── skillset.json'
      lines << '├── lib/'
      lines << "│   ├── #{name}.rb"
      lines << "│   └── #{name}/"

      lines << '├── tools/'
      tools.each_with_index do |tool, i|
        prefix = (i == tools.length - 1 && knowledge.empty? && !has_config && !has_plugin) ? '│   └── ' : '│   ├── '
        lines << "#{prefix}#{tool}.rb"
      end

      unless knowledge.empty?
        lines << '├── knowledge/'
        knowledge.each_with_index do |k, i|
          prefix = i == knowledge.length - 1 ? '│   └── ' : '│   ├── '
          lines << "#{prefix}#{k}/"
          lines << "#{prefix.gsub('└', ' ').gsub('├', '│')}   └── #{k}.md"
        end
      end

      if has_plugin
        last = !has_config
        lines << (last ? '└── plugin/' : '├── plugin/')
        lines << (last ? '    └── SKILL.md' : '│   └── SKILL.md')
      end

      if has_config
        lines << '└── config/'
        lines << "    └── #{name}.yml"
      end

      lines.join("\n")
    end

    def write_skillset_json(root, name, tools, knowledge, has_config, depends_on, has_plugin = false)
      module_name = to_module_name(name)
      tool_classes = tools.map { |t| "KairosMcp::SkillSets::#{module_name}::Tools::#{to_class_name(t)}" }
      knowledge_dirs = knowledge.map { |k| "knowledge/#{k}" }

      data = {
        name: name,
        version: '0.1.0',
        description: 'TODO: What + When + Negative scope',
        author: 'TODO',
        layer: 'L1',
        depends_on: depends_on.map { |d| { name: d } },
        provides: [],
        tool_classes: tool_classes,
        config_files: has_config ? ["config/#{name}.yml"] : [],
        knowledge_dirs: knowledge_dirs,
        min_core_version: '2.7.0'
      }

      if has_plugin
        data[:plugin] = { skill_md: 'plugin/SKILL.md' }
      end

      path = File.join(root, 'skillset.json')
      File.write(path, JSON.pretty_generate(data) + "\n", encoding: 'UTF-8')
      path
    end

    def write_entry_point(root, name)
      module_name = to_module_name(name)
      lib_dir = File.join(root, 'lib')
      FileUtils.mkdir_p(File.join(lib_dir, name))

      content = <<~RUBY
        # frozen_string_literal: true

        module #{module_name}
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          KNOWLEDGE_DIR = File.join(SKILLSET_ROOT, 'knowledge')
          VERSION = '0.1.0'

          class << self
            def load!(config: {})
              @config = config
              @loaded = true
            end

            def loaded?
              @loaded == true
            end

            def unload!
              @config = nil
              @loaded = false
            end

            def provider(user_context: nil)
              provider = KairosMcp::KnowledgeProvider.new(nil, user_context: user_context)
              provider.add_external_dir(
                KNOWLEDGE_DIR,
                source: "skillset:#{name}",
                layer: :L1,
                index: true
              )
              provider
            end
          end

          load! unless loaded?
        end
      RUBY

      path = File.join(lib_dir, "#{name}.rb")
      File.write(path, content, encoding: 'UTF-8')
      path
    end

    def write_tool_skeletons(root, name, tools)
      module_name = to_module_name(name)
      tools_dir = File.join(root, 'tools')
      FileUtils.mkdir_p(tools_dir)

      tools.map do |tool|
        class_name = to_class_name(tool)
        content = <<~RUBY
          # frozen_string_literal: true

          module KairosMcp
            module SkillSets
              module #{module_name}
                module Tools
                  class #{class_name} < KairosMcp::Tools::BaseTool
                    def name
                      '#{tool}'
                    end

                    def description
                      'TODO: describe what this tool does'
                    end

                    def input_schema
                      {
                        type: 'object',
                        properties: {
                          command: { type: 'string', enum: %w[TODO], description: 'TODO' }
                        },
                        required: %w[command]
                      }
                    end

                    def call(arguments)
                      text_content('Not yet implemented')
                    rescue StandardError => e
                      text_content(JSON.pretty_generate({ error: e.message }))
                    end
                  end
                end
              end
            end
          end
        RUBY

        path = File.join(tools_dir, "#{tool}.rb")
        File.write(path, content, encoding: 'UTF-8')
        path
      end
    end

    def write_knowledge_skeletons(root, knowledge_names)
      knowledge_names.map do |k|
        dir = File.join(root, 'knowledge', k)
        FileUtils.mkdir_p(dir)

        display_name = k.split('_').map(&:capitalize).join(' ')
        content = <<~MARKDOWN
          ---
          name: #{k}
          description: >
            TODO: What + When + Negative scope
          version: "0.1"
          layer: L1
          tags: [TODO]
          ---

          # #{display_name}

          TODO: content
        MARKDOWN

        path = File.join(dir, "#{k}.md")
        File.write(path, content, encoding: 'UTF-8')
        path
      end
    end

    def write_config(root, name)
      config_dir = File.join(root, 'config')
      FileUtils.mkdir_p(config_dir)

      content = <<~YAML
        #{name}:
          # Add configuration options here
      YAML

      path = File.join(config_dir, "#{name}.yml")
      File.write(path, content, encoding: 'UTF-8')
      path
    end

    def write_plugin_skeleton(root, name)
      plugin_dir = File.join(root, 'plugin')
      FileUtils.mkdir_p(plugin_dir)

      content = <<~SKILL
        ---
        name: #{name}
        description: >
          TODO: Describe when to use this skill and what it provides.
        ---

        # #{to_module_name(name)}

        TODO: Describe the recommended workflow for this SkillSet.

        ## Available Tools

        <!-- AUTO_TOOLS -->
      SKILL

      path = File.join(plugin_dir, 'SKILL.md')
      File.write(path, content, encoding: 'UTF-8')
      [path]
    end

    def to_module_name(snake_case)
      snake_case.split('_').map(&:capitalize).join
    end

    def to_class_name(snake_case)
      snake_case.split('_').map(&:capitalize).join
    end
  end
end
