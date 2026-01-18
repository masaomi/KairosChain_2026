# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module KairosMcp
  # AnthropicSkillParser: Parses Anthropic skills format (YAML frontmatter + Markdown)
  #
  # Directory structure:
  #   skill_name/
  #   ├── skill_name.md       # Required: YAML frontmatter + Markdown content
  #   ├── scripts/            # Optional: Executable scripts (Python, Bash, Node, etc.)
  #   ├── assets/             # Optional: Templates, images, CSS, etc.
  #   └── references/         # Optional: Reference materials, datasets
  #
  class AnthropicSkillParser
    # Struct representing a parsed skill entry
    SkillEntry = Struct.new(
      :name,
      :description,
      :version,
      :layer,
      :tags,
      :content,
      :frontmatter,
      :base_path,
      :md_file_path,
      :scripts_path,
      :assets_path,
      :references_path,
      keyword_init: true
    ) do
      def has_scripts?
        File.directory?(scripts_path)
      end

      def has_assets?
        File.directory?(assets_path)
      end

      def has_references?
        File.directory?(references_path)
      end

      def to_h
        {
          name: name,
          description: description,
          version: version,
          layer: layer,
          tags: tags,
          content: content,
          has_scripts: has_scripts?,
          has_assets: has_assets?,
          has_references: has_references?
        }
      end
    end

    class << self
      # Parse a skill directory and return a SkillEntry
      #
      # @param skill_dir [String] Path to the skill directory
      # @return [SkillEntry, nil] Parsed skill entry or nil if invalid
      def parse(skill_dir)
        return nil unless File.directory?(skill_dir)

        md_file = find_md_file(skill_dir)
        return nil unless md_file

        content = File.read(md_file)
        frontmatter, body = extract_frontmatter(content)

        skill_name = File.basename(skill_dir)

        SkillEntry.new(
          name: frontmatter['name'] || skill_name,
          description: frontmatter['description'],
          version: frontmatter['version'],
          layer: frontmatter['layer'],
          tags: frontmatter['tags'] || [],
          content: body.strip,
          frontmatter: frontmatter,
          base_path: skill_dir,
          md_file_path: md_file,
          scripts_path: File.join(skill_dir, 'scripts'),
          assets_path: File.join(skill_dir, 'assets'),
          references_path: File.join(skill_dir, 'references')
        )
      end

      # Create a new skill directory with the Anthropic format
      #
      # @param base_dir [String] Base directory (knowledge/ or context/session_id/)
      # @param name [String] Skill name
      # @param content [String] Full content including YAML frontmatter
      # @param create_subdirs [Boolean] Whether to create scripts/assets/references dirs
      # @return [SkillEntry] The created skill entry
      def create(base_dir, name, content, create_subdirs: false)
        skill_dir = File.join(base_dir, name)
        FileUtils.mkdir_p(skill_dir)

        md_file = File.join(skill_dir, "#{name}.md")
        File.write(md_file, content)

        if create_subdirs
          FileUtils.mkdir_p(File.join(skill_dir, 'scripts'))
          FileUtils.mkdir_p(File.join(skill_dir, 'assets'))
          FileUtils.mkdir_p(File.join(skill_dir, 'references'))
        end

        parse(skill_dir)
      end

      # Update an existing skill's content
      #
      # @param skill_dir [String] Path to the skill directory
      # @param new_content [String] New content including YAML frontmatter
      # @return [SkillEntry] The updated skill entry
      def update(skill_dir, new_content)
        md_file = find_md_file(skill_dir)
        raise "No markdown file found in #{skill_dir}" unless md_file

        File.write(md_file, new_content)
        parse(skill_dir)
      end

      # List all scripts in a skill
      #
      # @param skill [SkillEntry] The skill entry
      # @return [Array<Hash>] List of script info
      def list_scripts(skill)
        return [] unless skill.has_scripts?

        Dir[File.join(skill.scripts_path, '*')].map do |f|
          {
            name: File.basename(f),
            path: f,
            executable: File.executable?(f),
            size: File.size(f)
          }
        end
      end

      # List all assets in a skill
      #
      # @param skill [SkillEntry] The skill entry
      # @return [Array<Hash>] List of asset info
      def list_assets(skill)
        return [] unless skill.has_assets?

        Dir[File.join(skill.assets_path, '**/*')].select { |f| File.file?(f) }.map do |f|
          {
            name: File.basename(f),
            path: f,
            relative_path: f.sub(skill.assets_path + '/', ''),
            size: File.size(f),
            extension: File.extname(f)
          }
        end
      end

      # List all references in a skill
      #
      # @param skill [SkillEntry] The skill entry
      # @return [Array<Hash>] List of reference info
      def list_references(skill)
        return [] unless skill.has_references?

        Dir[File.join(skill.references_path, '**/*')].select { |f| File.file?(f) }.map do |f|
          {
            name: File.basename(f),
            path: f,
            relative_path: f.sub(skill.references_path + '/', ''),
            size: File.size(f),
            extension: File.extname(f)
          }
        end
      end

      # Generate YAML frontmatter + Markdown content
      #
      # @param frontmatter [Hash] Frontmatter data
      # @param body [String] Markdown body content
      # @return [String] Complete file content
      def generate_content(frontmatter, body)
        yaml_str = frontmatter.to_yaml.sub(/^---\n/, '')
        "---\n#{yaml_str}---\n\n#{body}"
      end

      # Extract frontmatter and body from content
      #
      # @param content [String] Full file content
      # @return [Array<Hash, String>] [frontmatter, body]
      def extract_frontmatter(content)
        if content =~ /\A---\r?\n(.+?)\r?\n---\r?\n(.*)/m
          frontmatter = YAML.safe_load($1, permitted_classes: [Symbol, Date, Time]) || {}
          body = $2
          [frontmatter, body]
        else
          [{}, content]
        end
      end

      private

      def find_md_file(skill_dir)
        # First try to find a file with the same name as the directory
        skill_name = File.basename(skill_dir)
        expected_file = File.join(skill_dir, "#{skill_name}.md")
        return expected_file if File.exist?(expected_file)

        # Fall back to any .md file in the directory
        Dir[File.join(skill_dir, '*.md')].first
      end
    end
  end
end
