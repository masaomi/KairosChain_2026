# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../upgrade_analyzer'
require_relative '../config_merger'

module KairosMcp
  module Tools
    class SystemUpgrade < BaseTool
      def name
        'system_upgrade'
      end

      def description
        'Check for gem updates and safely migrate data directory templates. ' \
        'Supports check, preview, apply, and status commands.'
      end

      def category
        :utility
      end

      def usecase_tags
        %w[upgrade update migration version template system maintenance]
      end

      def examples
        [
          {
            title: 'Check if upgrade is needed',
            code: 'system_upgrade(command: "check")'
          },
          {
            title: 'Preview all changes before applying',
            code: 'system_upgrade(command: "preview")'
          },
          {
            title: 'Apply the upgrade',
            code: 'system_upgrade(command: "apply", approved: true)'
          },
          {
            title: 'Show current meta status',
            code: 'system_upgrade(command: "status")'
          }
        ]
      end

      def related_tools
        %w[skills_evolve chain_record chain_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "check", "preview", "apply", or "status"',
              enum: %w[check preview apply status]
            },
            approved: {
              type: 'boolean',
              description: 'Set to true to approve and apply the upgrade (required for apply command)'
            }
          },
          required: ['command']
        }
      end

      def call(arguments)
        command = arguments['command']
        approved = arguments['approved'] || false

        case command
        when 'check'
          handle_check
        when 'preview'
          handle_preview
        when 'apply'
          handle_apply(approved)
        when 'status'
          handle_status
        else
          text_content("Unknown command: #{command}. Use check, preview, apply, or status.")
        end
      end

      private

      # =====================================================================
      # check — Quick version comparison
      # =====================================================================
      def handle_check
        analyzer = UpgradeAnalyzer.new

        output = "# System Upgrade Check\n\n"
        output += "Gem version:  #{analyzer.gem_version}\n"
        output += "Data version: #{analyzer.meta_version || '(unknown — no .kairos_meta.yml)'}\n\n"

        if analyzer.upgrade_needed?
          analyzer.analyze
          summary = analyzer.summary

          output += "**Upgrade available!**\n\n"
          output += "Files to process:\n"
          output += "  - Auto-updatable: #{summary[:auto_updatable] || 0}\n"
          output += "  - User-modified (kept): #{summary[:user_modified] || 0}\n"
          output += "  - Conflicts (need review): #{summary[:conflict] || 0}\n"
          output += "  - Unchanged: #{summary[:unchanged] || 0}\n\n"
          output += "Run `system_upgrade command=\"preview\"` for detailed analysis.\n"
          output += "Run `system_upgrade command=\"apply\" approved=true` to apply.\n"
        else
          output += "No upgrade needed. Data directory is up to date.\n"
        end

        text_content(output)
      end

      # =====================================================================
      # preview — Detailed file-by-file analysis
      # =====================================================================
      def handle_preview
        analyzer = UpgradeAnalyzer.new
        analyzer.analyze

        output = "# Upgrade Preview\n\n"
        output += "Gem version:  #{analyzer.gem_version}\n"
        output += "Data version: #{analyzer.meta_version || '(unknown)'}\n"

        unless analyzer.has_meta
          output += "\n> **Warning**: No `.kairos_meta.yml` found.\n"
          output += "> All modified files will be treated as conflicts (safe fallback).\n"
          output += "> Run `kairos_mcp_server init` to create the meta file for future upgrades.\n"
        end

        output += "\n## File Analysis\n\n"

        analyzer.results.each do |template_name, result|
          icon = pattern_icon(result[:pattern])
          output += "### #{icon} #{template_name}\n"
          output += "  Pattern: #{result[:pattern]}\n"
          output += "  Type: #{result[:file_type]}\n"
          output += "  Action: #{result[:action]}\n"

          # Show config merge preview for conflict YAML files
          if result[:pattern] == :conflict && result[:file_type] == :config_yaml
            output += format_config_merge_preview(result)
          end

          # Show diff hint for L0 conflicts
          if result[:pattern] == :conflict && result[:file_type] == :l0_dsl
            output += "  Note: A `skills_evolve` proposal will be generated.\n"
            output += "        New template additions will be extracted as individual proposals.\n"
          end

          output += "\n"
        end

        # Summary
        summary = analyzer.summary
        output += "## Summary\n"
        output += "  Auto-updatable: #{summary[:auto_updatable] || 0}\n"
        output += "  User-modified:  #{summary[:user_modified] || 0}\n"
        output += "  Conflicts:      #{summary[:conflict] || 0}\n"
        output += "  Unchanged:      #{summary[:unchanged] || 0}\n\n"

        if (summary[:auto_updatable] || 0) > 0 || (summary[:conflict] || 0) > 0
          output += "Run `system_upgrade command=\"apply\" approved=true` to apply.\n"
        end

        text_content(output)
      end

      # =====================================================================
      # apply — Execute the upgrade
      # =====================================================================
      def handle_apply(approved)
        unless approved
          return text_content(
            "Upgrade requires approval.\n\n" \
            "Run `system_upgrade command=\"preview\"` first to review changes,\n" \
            "then `system_upgrade command=\"apply\" approved=true` to confirm."
          )
        end

        analyzer = UpgradeAnalyzer.new
        analyzer.analyze

        unless analyzer.upgrade_needed?
          return text_content("No upgrade needed. Data directory is already up to date.")
        end

        actions = {
          auto_updated: [],
          merged: [],
          l0_proposed: [],
          skipped: [],
          unchanged: [],
          errors: []
        }

        output = "# Applying Upgrade\n\n"
        output += "From v#{analyzer.meta_version || 'unknown'} → v#{analyzer.gem_version}\n\n"

        analyzer.results.each do |template_name, result|
          case result[:pattern]
          when :unchanged
            actions[:unchanged] << template_name

          when :auto_updatable
            begin
              apply_auto_update(result)
              actions[:auto_updated] << template_name
              output += "  [AUTO-UPDATED] #{template_name}\n"
            rescue => e
              actions[:errors] << { file: template_name, error: e.message }
              output += "  [ERROR] #{template_name}: #{e.message}\n"
            end

          when :user_modified
            actions[:skipped] << template_name
            output += "  [KEPT] #{template_name} (user-modified, template unchanged)\n"

          when :conflict
            begin
              conflict_output = apply_conflict(result)
              output += conflict_output

              case result[:file_type]
              when :config_yaml
                actions[:merged] << template_name
              when :l0_dsl
                actions[:l0_proposed] << template_name
              when :l0_doc
                actions[:skipped] << template_name
              end
            rescue => e
              actions[:errors] << { file: template_name, error: e.message }
              output += "  [ERROR] #{template_name}: #{e.message}\n"
            end
          end
        end

        # Update .kairos_meta.yml
        update_meta(analyzer.gem_version)
        output += "\n  [UPDATED] .kairos_meta.yml → v#{analyzer.gem_version}\n"

        # Record to blockchain
        record_upgrade_to_chain(analyzer.meta_version, analyzer.gem_version, actions)
        output += "  [RECORDED] Upgrade recorded to KairosChain blockchain\n"

        # Summary
        output += "\n## Upgrade Complete\n\n"
        output += "  Auto-updated: #{actions[:auto_updated].length}\n"
        output += "  Merged:       #{actions[:merged].length}\n"
        output += "  L0 proposals: #{actions[:l0_proposed].length}\n"
        output += "  Kept/Skipped: #{actions[:skipped].length}\n"
        output += "  Unchanged:    #{actions[:unchanged].length}\n"
        output += "  Errors:       #{actions[:errors].length}\n" if actions[:errors].any?

        if actions[:l0_proposed].any?
          output += "\n**L0 changes require manual review.**\n"
          output += "Use `skills_evolve` to review and approve the proposals.\n"
        end

        output += "\n**Restart the MCP server to load updated configurations.**\n"

        text_content(output)
      end

      # =====================================================================
      # status — Show current .kairos_meta.yml state
      # =====================================================================
      def handle_status
        meta_path = KairosMcp.meta_path

        output = "# System Status\n\n"
        output += "Gem version: #{KairosMcp::VERSION}\n"
        output += "Data directory: #{KairosMcp.data_dir}\n"
        output += "Meta file: #{meta_path}\n\n"

        if File.exist?(meta_path)
          meta = YAML.safe_load(File.read(meta_path)) || {}
          output += "Data version: #{meta['kairos_mcp_version'] || 'unknown'}\n"
          output += "Initialized at: #{meta['initialized_at'] || 'unknown'}\n"

          if meta.key?('last_upgrade')
            output += "\nLast upgrade:\n"
            output += "  From: #{meta['last_upgrade']['from_version']}\n"
            output += "  To: #{meta['last_upgrade']['to_version']}\n"
            output += "  At: #{meta['last_upgrade']['timestamp']}\n"
          end

          output += "\nTemplate hashes:\n"
          (meta['template_hashes'] || {}).each do |name, hash|
            output += "  #{name}: #{hash[0..20]}...\n"
          end
        else
          output += "No .kairos_meta.yml found.\n"
          output += "Run `kairos_mcp_server init` to create one,\n"
          output += "or the next `system_upgrade apply` will create it.\n"
        end

        text_content(output)
      end

      # =====================================================================
      # Helpers
      # =====================================================================

      def pattern_icon(pattern)
        case pattern
        when :unchanged then 'OK'
        when :auto_updatable then 'UP'
        when :user_modified then 'USER'
        when :conflict then 'CONFLICT'
        else '?'
        end
      end

      # Auto-update: copy new template over user file (user hasn't modified)
      def apply_auto_update(result)
        if result[:user_exists]
          # Backup existing file
          backup_path = "#{result[:user_path]}.bak.#{Time.now.strftime('%Y%m%d%H%M%S')}"
          FileUtils.cp(result[:user_path], backup_path)
        end

        FileUtils.cp(result[:new_template_path], result[:user_path])
      end

      # Handle conflict based on file type
      def apply_conflict(result)
        output = ""

        case result[:file_type]
        when :config_yaml
          output += apply_config_merge(result)
        when :l0_dsl
          output += apply_l0_dsl_proposal(result)
        when :l0_doc
          output += "  [DIFF-ONLY] #{result[:template_name]} — L0 document, manual review:\n"
          output += generate_simple_diff(result[:user_path], result[:new_template_path])
        else
          output += "  [SKIPPED] #{result[:template_name]} — unknown file type, manual review needed\n"
        end

        output
      end

      # Structural YAML merge for config files
      def apply_config_merge(result)
        user_config = YAML.safe_load(File.read(result[:user_path])) || {}
        new_config = YAML.safe_load(File.read(result[:new_template_path])) || {}

        merged = ConfigMerger.merge(user_config, new_config)

        # Backup
        backup_path = "#{result[:user_path]}.bak.#{Time.now.strftime('%Y%m%d%H%M%S')}"
        FileUtils.cp(result[:user_path], backup_path)

        # Write merged config
        File.write(result[:user_path], YAML.dump(merged))

        preview = ConfigMerger.preview(user_config, new_config)
        added_count = preview[:added].length

        "  [MERGED] #{result[:template_name]} (#{added_count} new key(s) added, user values preserved)\n"
      end

      # Generate skills_evolve proposal for L0 kairos.rb
      def apply_l0_dsl_proposal(result)
        output = "  [L0-PROPOSAL] #{result[:template_name]}\n"

        new_content = File.read(result[:new_template_path])
        user_content = File.read(result[:user_path])

        # Extract skill definitions from new template that don't exist in user file
        new_skills = extract_skill_names(new_content)
        user_skills = extract_skill_names(user_content)
        added_skills = new_skills - user_skills

        if added_skills.any?
          output += "    New skills detected: #{added_skills.join(', ')}\n"
          output += "    Use `skills_evolve` to add them:\n\n"

          added_skills.each do |skill_name|
            definition = extract_skill_definition(new_content, skill_name)
            if definition
              output += "    ```\n"
              output += "    skills_evolve(\n"
              output += "      command: \"add\",\n"
              output += "      skill_id: \"#{skill_name}\",\n"
              output += "      definition: #{definition.inspect},\n"
              output += "      reason: \"Added in gem v#{KairosMcp::VERSION} upgrade\",\n"
              output += "      approved: true\n"
              output += "    )\n"
              output += "    ```\n\n"
            end
          end
        else
          output += "    No new skills detected, but template has changed.\n"
          output += "    Diff:\n"
          output += generate_simple_diff(result[:user_path], result[:new_template_path])
        end

        output
      end

      # Extract skill names from DSL content
      def extract_skill_names(content)
        content.scan(/^\s*skill\s+:(\w+)/).flatten
      end

      # Extract a single skill definition block from DSL content
      def extract_skill_definition(content, skill_name)
        # Match skill :name do ... end block
        pattern = /^(\s*skill\s+:#{Regexp.escape(skill_name)}\s+do\b.*?^end)/m
        match = content.match(pattern)
        match ? match[1] : nil
      end

      # Generate a simple line-based diff
      def generate_simple_diff(file_a, file_b)
        lines_a = File.readlines(file_a).map(&:chomp)
        lines_b = File.readlines(file_b).map(&:chomp)

        output = ""
        max_lines = [lines_a.length, lines_b.length].max

        # Simple comparison (not a full LCS diff, but useful for small files)
        added = lines_b - lines_a
        removed = lines_a - lines_b

        if added.any?
          output += "    Added lines:\n"
          added.first(10).each { |l| output += "      + #{l}\n" }
          output += "      ... (#{added.length - 10} more)\n" if added.length > 10
        end

        if removed.any?
          output += "    Removed lines:\n"
          removed.first(10).each { |l| output += "      - #{l}\n" }
          output += "      ... (#{removed.length - 10} more)\n" if removed.length > 10
        end

        output += "    (no differences detected)\n" if added.empty? && removed.empty?
        output
      end

      # Format config merge preview for the preview command
      def format_config_merge_preview(result)
        return "" unless result[:user_exists] && result[:new_exists]

        begin
          user_config = YAML.safe_load(File.read(result[:user_path])) || {}
          new_config = YAML.safe_load(File.read(result[:new_template_path])) || {}
          preview = ConfigMerger.preview(user_config, new_config)

          output = ""
          if preview[:added].any?
            output += "  New keys to add:\n"
            preview[:added].each { |a| output += "    + #{a[:path]}: #{a[:value].inspect}\n" }
          end
          if preview[:user_customized].any?
            output += "  User customizations (kept):\n"
            preview[:user_customized].each do |c|
              output += "    ~ #{c[:path]}: #{c[:user_value].inspect} (template: #{c[:template_value].inspect})\n"
            end
          end
          output
        rescue => e
          "  (Preview unavailable: #{e.message})\n"
        end
      end

      # Update .kairos_meta.yml with new version and hashes
      def update_meta(new_version)
        meta = if File.exist?(KairosMcp.meta_path)
                 YAML.safe_load(File.read(KairosMcp.meta_path)) || {}
               else
                 {}
               end

        old_version = meta['kairos_mcp_version']

        meta['kairos_mcp_version'] = new_version
        meta['template_hashes'] = {}

        # Record current state of all template files in data directory
        KairosMcp::TEMPLATE_FILES.each do |template_name, accessor|
          path = KairosMcp.send(accessor)
          if File.exist?(path)
            meta['template_hashes'][template_name] =
              "sha256:#{Digest::SHA256.file(path).hexdigest}"
          end
        end

        meta['last_upgrade'] = {
          'from_version' => old_version,
          'to_version' => new_version,
          'timestamp' => Time.now.utc.iso8601
        }

        File.write(KairosMcp.meta_path, YAML.dump(meta))
      end

      # Record the upgrade operation to KairosChain blockchain
      def record_upgrade_to_chain(from_version, to_version, actions)
        require_relative '../kairos_chain/chain'

        record = {
          type: 'system_upgrade',
          from_version: from_version || 'unknown',
          to_version: to_version,
          actions: {
            auto_updated: actions[:auto_updated],
            merged: actions[:merged],
            l0_proposed: actions[:l0_proposed],
            skipped: actions[:skipped],
            unchanged: actions[:unchanged]
          },
          timestamp: Time.now.utc.iso8601
        }.to_json

        chain = KairosChain::Chain.new
        chain.add_block([record])
      rescue => e
        $stderr.puts "[KairosChain] Warning: Failed to record upgrade to blockchain: #{e.message}"
      end
    end
  end
end
