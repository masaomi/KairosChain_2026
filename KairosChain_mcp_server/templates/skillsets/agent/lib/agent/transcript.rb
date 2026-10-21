# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Agent
      # Reading the host's transcript for the operator's own words (INV-5):
      # user entries the operator typed — origin human, prompt source typed,
      # or a command typed with arguments; not meta, not a sidechain. Hook
      # output, peer messages, task notifications and tool results are never
      # the operator's words.
      module Transcript
        module_function

        def typed_entries(path)
          return [] unless path && File.exist?(path)

          File.foreach(path, encoding: 'UTF-8').filter_map do |line|
            d = JSON.parse(line)
            next unless typed?(d)

            { 'uuid' => d['uuid'], 'prompt_id' => d['promptId'], 'at' => d['timestamp'], 'text' => text_of(d) }
          rescue JSON::ParserError
            nil
          end.reject { |e| e['text'].to_s.strip.empty? }
        end

        # Both origin.kind == human and promptSource == typed are required:
        # compaction summaries, bare slash commands and interruption notices
        # carry neither and are not the operator's words. A command the
        # operator typed with arguments is the exception; its arguments are
        # the operator's. The host records a skill command with origin human
        # and often no prompt source, and a built-in command (/goal, /effort)
        # with neither, its name tag first.
        def typed?(d)
          return false unless d['type'] == 'user'
          return false if d['isMeta'] || d['isSidechain'] || d['isCompactSummary'] || d['isVisibleInTranscriptOnly']

          text = content_of(d).to_s
          origin = d['origin']
          return d['promptSource'].nil? && builtin_command_args?(text) if origin.nil?
          return false unless origin.is_a?(Hash) && origin['kind'] == 'human'

          if (args = command_args(text))
            return [nil, 'typed', 'queued'].include?(d['promptSource']) && !args.strip.empty?
          end
          return false unless %w[typed queued].include?(d['promptSource'])

          text = text.lstrip
          !(text.start_with?('<') || slash_command?(text) || text.start_with?('[Request interrupted'))
        end

        # The entry's words; for a command typed with arguments, the arguments.
        def text_of(d)
          text = content_of(d)
          command_args(text.to_s) || text
        end

        def content_of(d)
          c = d.dig('message', 'content')
          case c
          when String then c
          when Array then c.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join("\n")
          end
        end

        # Was this prompt text typed by the operator in that transcript? The
        # text must match, and the prompt id too when it is known.
        def typed_prompt?(path, text:, prompt_id: nil)
          return false if text.to_s.strip.empty?

          typed_entries(path).any? do |e|
            e['text'].strip == text.to_s.strip && (prompt_id.nil? || e['prompt_id'] == prompt_id)
          end
        end

        # A slash command (/compact, /effort xhigh), not a path (/Users/…).
        SLASH_COMMAND = %r{\A\s*(/[A-Za-z][\w:-]*)(?:\s|\z)}

        # The tags the host records a command invocation with, in any order.
        COMMAND_TAG = %r{<command-(name|message|args)>(.*?)</command-\1>}m

        # Prompts the host delivers as user input that no person typed.
        NOT_TYPED = /\A\s*(<|Another Claude session sent a message|\[SYSTEM NOTIFICATION|\[Request interrupted)/

        # A first word naming an existing file or directory ("/tmp に置いて")
        # is a path the operator typed, not a command.
        def slash_command?(text)
          m = SLASH_COMMAND.match(text.to_s)
          !m.nil? && !File.exist?(m[1])
        end

        # The arguments of a recorded command invocation, when the text is
        # exactly one command name, its arguments and optionally its message.
        def command_args(text)
          return nil unless text.gsub(COMMAND_TAG, '').strip.empty?

          tags = text.scan(COMMAND_TAG)
          names = tags.select { |k, _| k == 'name' }
          args = tags.select { |k, _| k == 'args' }
          return nil unless names.size == 1 && names[0][1].start_with?('/') && args.size == 1

          args[0][1]
        end

        # A built-in command as the host records it: name, message, arguments,
        # in that order, with arguments. A skill command is recorded message
        # first, with an origin.
        def builtin_command_args?(text)
          args = command_args(text)
          !args.nil? && !args.strip.empty? && text.lstrip.start_with?('<command-name>')
        end

        def plausibly_typed?(text)
          !NOT_TYPED.match?(text.to_s) && !slash_command?(text)
        end

        # The operator's own words in a UserPromptSubmit prompt: a command's
        # arguments ("/agent do X" → "do X", a bare "/compact" → nil), nil for
        # a prompt no person typed, else the prompt. A command's arguments are
        # what typed_entries reads from its transcript entry.
        def operator_text(prompt)
          text = prompt.to_s
          if slash_command?(text)
            args = text.lstrip.sub(SLASH_COMMAND, '').strip
            return args.empty? ? nil : args
          end
          plausibly_typed?(text) && !text.strip.empty? ? text : nil
        end
      end
    end
  end
end
