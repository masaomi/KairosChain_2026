# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'base_tool'
require_relative '../skills_config'
require_relative '../action_log'

module KairosMcp
  module Tools
    class InstructionsUpdate < BaseTool
      # Protected built-in files that cannot be deleted
      PROTECTED_FILES = %w[kairos.md kairos_quickguide.md].freeze
      # Reserved mode names that map to built-in behavior
      RESERVED_MODES = %w[developer user none].freeze

      def name
        'instructions_update'
      end

      def description
        'Create, update, or delete custom instruction files and switch instructions_mode. ' \
        'Instructions control the AI system prompt (L0-level). ' \
        'All changes require human approval and are recorded to blockchain.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[instructions mode L0 system-prompt identity philosophy customize]
      end

      def examples
        [
          {
            title: 'Check current instructions status',
            code: 'instructions_update(command: "status")'
          },
          {
            title: 'Create custom instructions',
            code: 'instructions_update(command: "create", mode_name: "researcher", ' \
                  'content: "# Researcher Constitution\n...", ' \
                  'reason: "Create researcher identity", approved: true)'
          },
          {
            title: 'Switch to custom mode',
            code: 'instructions_update(command: "set_mode", mode_name: "researcher", ' \
                  'reason: "Activate researcher identity", approved: true)'
          }
        ]
      end

      def related_tools
        %w[skills_list skills_get chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "status", "create", "update", "delete", or "set_mode"',
              enum: %w[status create update delete set_mode]
            },
            mode_name: {
              type: 'string',
              description: 'Mode name (resolves to skills/{mode_name}.md). ' \
                           'Cannot be "developer", "user", or "none".'
            },
            content: {
              type: 'string',
              description: 'Full markdown content for the instructions file (for create/update)'
            },
            reason: {
              type: 'string',
              description: 'Reason for the change (recorded in blockchain). Required for create/update/delete/set_mode.'
            },
            approved: {
              type: 'boolean',
              description: 'Human approval flag. Must be true to execute L0-level changes.'
            }
          },
          required: %w[command]
        }
      end

      def call(arguments)
        command = arguments['command']
        mode_name = arguments['mode_name']
        content = arguments['content']
        reason = arguments['reason']
        approved = arguments['approved'] || false

        # Path traversal protection
        if mode_name && mode_name.match?(%r{[/\\]|\.\.})
          return text_content("Error: mode_name must not contain path separators or '..'")
        end

        case command
        when 'status'
          handle_status
        when 'create'
          handle_create(mode_name, content, reason, approved)
        when 'update'
          handle_update(mode_name, content, reason, approved)
        when 'delete'
          handle_delete(mode_name, reason, approved)
        when 'set_mode'
          handle_set_mode(mode_name, reason, approved)
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      # --- status command (no approval needed) ---

      def handle_status
        config = SkillsConfig.load
        current_mode = config['instructions_mode'] || 'user'
        resolved = resolved_path(current_mode)

        # Find all .md files in skills_dir
        available = Dir[File.join(KairosMcp.skills_dir, '*.md')].sort.map do |f|
          basename = File.basename(f)
          mode = basename.sub(/\.md$/, '')
          builtin = PROTECTED_FILES.include?(basename)
          active = (mode == current_mode) ||
                   (current_mode == 'developer' && basename == 'kairos.md') ||
                   (current_mode == 'user' && basename == 'kairos_quickguide.md')
          { file: basename, mode: mode, size: File.size(f), builtin: builtin, active: active }
        end

        output = "## Instructions Status\n\n"
        output += "**Current mode**: `#{current_mode}`\n"
        output += "**Resolved file**: `#{resolved}`\n"
        output += "**File exists**: #{resolved != '(none)' && File.exist?(resolved)}\n\n"
        output += "### Available instruction files\n\n"
        available.each do |f|
          marker = f[:active] ? ' **(ACTIVE)**' : ''
          tag = f[:builtin] ? ' [built-in]' : ' [custom]'
          output += "- `#{f[:file]}`#{tag}#{marker} (#{f[:size]} bytes)\n"
        end

        text_content(output)
      end

      # --- create command ---

      def handle_create(mode_name, content, reason, approved)
        return text_content("Error: mode_name is required") unless mode_name && !mode_name.empty?
        return text_content("Error: content is required for create") unless content && !content.empty?
        return text_content("Error: reason is required for create") unless reason && !reason.empty?
        return text_content("Error: '#{mode_name}' is a reserved mode name") if RESERVED_MODES.include?(mode_name)

        path = instructions_path(mode_name)
        return text_content("Error: '#{mode_name}.md' already exists. Use 'update' command.") if File.exist?(path)

        unless approved
          return text_content(
            "⚠️ Human approval required.\n\n" \
            "**Action**: Create `skills/#{mode_name}.md` (L0-level instructions file)\n" \
            "**Reason**: #{reason}\n" \
            "**Content size**: #{content.length} bytes\n\n" \
            "Set `approved: true` to confirm."
          )
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)

        next_hash = Digest::SHA256.hexdigest(content)

        record_to_blockchain(
          action: 'create_instructions',
          mode_name: mode_name,
          prev_hash: nil,
          next_hash: next_hash,
          reason: reason
        )

        ActionLog.record(
          action: 'instructions_created',
          skill_id: "instructions:#{mode_name}",
          details: { mode_name: mode_name, next_hash: next_hash, reason: reason }
        )

        text_content(
          "✅ Instructions file created\n\n" \
          "**File**: `skills/#{mode_name}.md`\n" \
          "**Hash**: `#{next_hash}`\n\n" \
          "Recorded to blockchain (full recording, L0_law level).\n" \
          "Use `set_mode` command to activate this mode."
        )
      rescue StandardError => e
        text_content("❌ Failed: #{e.message}")
      end

      # --- update command ---

      def handle_update(mode_name, content, reason, approved)
        return text_content("Error: mode_name is required") unless mode_name && !mode_name.empty?
        return text_content("Error: content is required for update") unless content && !content.empty?
        return text_content("Error: reason is required for update") unless reason && !reason.empty?

        path = instructions_path(mode_name)
        return text_content("Error: '#{mode_name}.md' not found. Use 'create' command.") unless File.exist?(path)

        prev_content = File.read(path)
        prev_hash = Digest::SHA256.hexdigest(prev_content)
        next_hash = Digest::SHA256.hexdigest(content)

        return text_content("No changes detected (same content hash).") if prev_hash == next_hash

        unless approved
          return text_content(
            "⚠️ Human approval required.\n\n" \
            "**Action**: Update `skills/#{mode_name}.md` (L0-level instructions file)\n" \
            "**Reason**: #{reason}\n" \
            "**Prev hash**: `#{prev_hash[0..15]}...`\n" \
            "**Next hash**: `#{next_hash[0..15]}...`\n\n" \
            "Set `approved: true` to confirm."
          )
        end

        File.write(path, content)

        record_to_blockchain(
          action: 'update_instructions',
          mode_name: mode_name,
          prev_hash: prev_hash,
          next_hash: next_hash,
          reason: reason
        )

        ActionLog.record(
          action: 'instructions_updated',
          skill_id: "instructions:#{mode_name}",
          details: { mode_name: mode_name, prev_hash: prev_hash, next_hash: next_hash, reason: reason }
        )

        text_content(
          "✅ Instructions file updated\n\n" \
          "**File**: `skills/#{mode_name}.md`\n" \
          "**Prev hash**: `#{prev_hash}`\n" \
          "**Next hash**: `#{next_hash}`\n\n" \
          "Recorded to blockchain (full recording, L0_law level)."
        )
      rescue StandardError => e
        text_content("❌ Failed: #{e.message}")
      end

      # --- delete command ---

      def handle_delete(mode_name, reason, approved)
        return text_content("Error: mode_name is required") unless mode_name && !mode_name.empty?
        return text_content("Error: reason is required for delete") unless reason && !reason.empty?

        filename = "#{mode_name}.md"
        if PROTECTED_FILES.include?(filename)
          return text_content("Error: Cannot delete built-in file '#{filename}'")
        end

        path = instructions_path(mode_name)
        return text_content("Error: '#{mode_name}.md' not found.") unless File.exist?(path)

        # Cannot delete active mode
        config = SkillsConfig.load
        current_mode = config['instructions_mode'] || 'user'
        if current_mode == mode_name
          return text_content(
            "Error: Cannot delete '#{mode_name}.md' while it is the active instructions_mode.\n" \
            "Switch to another mode first using `set_mode`."
          )
        end

        unless approved
          return text_content(
            "⚠️ Human approval required.\n\n" \
            "**Action**: DELETE `skills/#{mode_name}.md` (L0-level instructions file)\n" \
            "**Reason**: #{reason}\n\n" \
            "This action is irreversible.\n" \
            "Set `approved: true` to confirm."
          )
        end

        prev_content = File.read(path)
        prev_hash = Digest::SHA256.hexdigest(prev_content)

        File.delete(path)

        record_to_blockchain(
          action: 'delete_instructions',
          mode_name: mode_name,
          prev_hash: prev_hash,
          next_hash: nil,
          reason: reason
        )

        ActionLog.record(
          action: 'instructions_deleted',
          skill_id: "instructions:#{mode_name}",
          details: { mode_name: mode_name, prev_hash: prev_hash, reason: reason }
        )

        text_content(
          "✅ Instructions file deleted\n\n" \
          "**Deleted**: `skills/#{mode_name}.md`\n" \
          "**Prev hash**: `#{prev_hash}`\n\n" \
          "Recorded to blockchain (full recording, L0_law level)."
        )
      rescue StandardError => e
        text_content("❌ Failed: #{e.message}")
      end

      # --- set_mode command ---

      def handle_set_mode(mode_name, reason, approved)
        return text_content("Error: mode_name is required") unless mode_name && !mode_name.empty?
        return text_content("Error: reason is required for set_mode") unless reason && !reason.empty?

        # Validate custom mode file exists
        unless RESERVED_MODES.include?(mode_name)
          path = instructions_path(mode_name)
          unless File.exist?(path)
            return text_content(
              "Error: No instructions file for mode '#{mode_name}'.\n" \
              "Expected: `skills/#{mode_name}.md`\n" \
              "Create it first with the 'create' command."
            )
          end
        end

        config = SkillsConfig.load
        prev_mode = config['instructions_mode'] || 'user'

        return text_content("instructions_mode is already '#{mode_name}'.") if prev_mode == mode_name

        unless approved
          return text_content(
            "⚠️ Human approval required.\n\n" \
            "**Action**: Change instructions_mode `#{prev_mode}` → `#{mode_name}`\n" \
            "**Reason**: #{reason}\n" \
            "**Effect**: AI system prompt will use `skills/#{mode_name}.md` on next connection.\n\n" \
            "Set `approved: true` to confirm."
          )
        end

        config['instructions_mode'] = mode_name
        SkillsConfig.save(config)

        record_to_blockchain(
          action: 'set_instructions_mode',
          mode_name: mode_name,
          prev_hash: Digest::SHA256.hexdigest(prev_mode),
          next_hash: Digest::SHA256.hexdigest(mode_name),
          reason: reason
        )

        ActionLog.record(
          action: 'instructions_mode_changed',
          skill_id: 'instructions_mode',
          details: { prev_mode: prev_mode, new_mode: mode_name, reason: reason }
        )

        text_content(
          "✅ Instructions mode changed\n\n" \
          "**Previous**: `#{prev_mode}`\n" \
          "**New**: `#{mode_name}`\n\n" \
          "Recorded to blockchain (full recording, L0_law level).\n" \
          "New instructions take effect on next MCP client connection."
        )
      rescue StandardError => e
        text_content("❌ Failed: #{e.message}")
      end

      # --- helpers ---

      def instructions_path(mode_name)
        File.join(KairosMcp.skills_dir, "#{mode_name}.md")
      end

      def resolved_path(mode)
        case mode
        when 'developer' then KairosMcp.md_path
        when 'user'      then KairosMcp.quickguide_path
        when 'none'      then '(none)'
        else File.join(KairosMcp.skills_dir, "#{mode}.md")
        end
      end

      def record_to_blockchain(action:, mode_name:, prev_hash:, next_hash:, reason:)
        require_relative '../kairos_chain/chain'
        require_relative '../kairos_chain/skill_transition'

        transition = KairosChain::SkillTransition.new(
          skill_id: "instructions:#{mode_name}",
          prev_ast_hash: prev_hash || 'nil',
          next_ast_hash: next_hash || 'nil',
          diff_hash: Digest::SHA256.hexdigest("#{prev_hash}#{next_hash}"),
          reason_ref: "#{action}: #{reason}"
        )

        chain = KairosChain::Chain.new
        chain.add_block([transition.to_json])
      rescue StandardError => e
        $stderr.puts "[InstructionsUpdate] Blockchain recording failed: #{e.message}"
      end
    end
  end
end
