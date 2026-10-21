# frozen_string_literal: true

module Kairomone
  module Console
    # The PreToolUse gate. It only ever refuses (exit 2) or stays silent (exit
    # 0, no output); it never emits a decision, so it can narrow what Claude
    # Code would ask about but never grant anything. The tool list is closed:
    # a tool a later CLI adds is refused before it runs, in every mode.
    module Gate
      BUILTINS = %w[Bash Read Grep Glob ToolSearch].freeze
      # kairomone_backup is admitted only for these commands: restores are done
      # in a terminal session, and a command added later is refused, not passed.
      BACKUP_COMMANDS = %w[create verify].freeze
      INPUT_LIMIT = 4 * 1024 * 1024

      # One rule text, run in two places: decide evaluates it in-process and
      # program embeds it verbatim in the hook, so the two cannot drift.
      RULE = <<~'RUBY'
        lambda do |input, server, builtins, backup_commands|
          next 'Kairomone console: the hook input is not a JSON object' unless input.is_a?(Hash)
          name = input['tool_name']
          next 'Kairomone console: the hook input names no tool' unless name.is_a?(String) && !name.empty?
          shown = name[0, 128].gsub(/[^\w.:-]/, '?')
          args = input.key?('tool_input') ? input['tool_input'] : {}
          next "Kairomone console: the input for #{shown} is not an object" unless args.is_a?(Hash)
          prefix = "mcp__#{server}__kairomone_"
          if builtins.include?(name)
            next 'Kairomone console: Bash in the background is not available in this console' if name == 'Bash' && args['run_in_background']
            nil
          elsif name.start_with?(prefix) && name.length > prefix.length
            next nil unless name == "#{prefix}backup"
            next nil if backup_commands.include?(args['command'])
            'Kairomone console: only backup create and verify run here; restore from a terminal session'
          else
            "Kairomone console: tool #{shown} is not available in this console"
          end
        end
      RUBY
      RULE_LAMBDA = eval(RULE, binding, "#{__FILE__} (Gate::RULE)", 1) # rubocop:disable Security/Eval -- constant text above

      module_function

      # => nil (stay silent) or a String reason (refuse).
      def decide(hook_input, server:)
        RULE_LAMBDA.call(hook_input, server!(server), BUILTINS, BACKUP_COMMANDS)
      end

      # Source for `ruby -e`. Anything unexpected, including unreadable or
      # oversized input, is a refusal.
      def program(server:)
        <<~PROGRAM
          require 'json'
          rule = #{RULE.strip}
          reason = begin
            raw = $stdin.read(#{INPUT_LIMIT + 1}).to_s
            if raw.bytesize > #{INPUT_LIMIT}
              'Kairomone console: the hook input is too large'
            else
              rule.call(JSON.parse(raw), #{server!(server).dump}, #{BUILTINS.inspect}, #{BACKUP_COMMANDS.inspect})
            end
          rescue Exception
            'Kairomone console: the hook input could not be read'
          end
          exit 0 if reason.nil?
          $stderr.write(reason.to_s + "\\n")
          exit 2
        PROGRAM
      end

      # A shell command (Claude Code runs hook commands through a shell). The
      # program is inline so the child has no file to edit; RUBYOPT and gems
      # are disabled so the environment cannot load code into the gate.
      def hook_command(server:, ruby: RbConfig.ruby)
        "#{shell_quote(ruby)} --disable=gems,rubyopt -e #{shell_quote(program(server: server))}"
      end

      def flag_settings(server:, rules:)
        lists = %w[deny ask].to_h do |key|
          list = rules[key] || rules[key.to_sym] || []
          raise ArgumentError, "rules[#{key}] must be a list of strings" unless list.is_a?(Array) && list.all?(String)
          [key, list.dup]
        end
        { 'crossSessionInbound' => 'refuse',
          'autoMemoryEnabled' => false,
          'permissions' => lists,
          'hooks' => { 'PreToolUse' => [{ 'matcher' => '.*', 'hooks' => [{ 'type' => 'command', 'command' => hook_command(server: server) }] }] } }
      end

      def server!(server)
        raise ArgumentError, 'server must be 1-64 letters, digits, "_" or "-"' unless server.is_a?(String) && Project::SERVER_NAME.match?(server)
        server
      end

      def shell_quote(text)
        "'#{text.to_s.gsub("'") { "'\\''" }}'"
      end
    end
  end
end
