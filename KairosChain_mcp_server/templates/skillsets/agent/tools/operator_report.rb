# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        # The way a plan hands prose to the person.
        #
        # Observed 2026-08-26: two runs produced the ranking the goal asked for,
        # and both ended with a step marked for a person whose whole content was
        # "there is no tool that puts this in front of the operator". The plan
        # had the answer and no way to deliver it.
        #
        # Why a file rather than a return value: autoexec truncates a step's
        # result at 500 characters, so a report returned inline is cut without
        # anyone being told. The tool writes the whole text and returns the path;
        # the agent loop reads the file back and surfaces it in the cycle result.
        #
        # Deliberately named without the agent_ prefix: the agent context
        # blacklists 'agent_*', so a tool the plan must be able to call cannot
        # carry that prefix.
        class OperatorReport < KairosMcp::Tools::BaseTool
          MAX_CHARS = 200_000

          def name
            'operator_report'
          end

          def description
            'Put prose in front of the operator. Use for the deliverable itself — ' \
            'a ranking, an analysis, a summary, an answer — and for anything the ' \
            'goal asked you to report rather than store. The text is written whole ' \
            'and shown to the operator at the end of the cycle. This does not need ' \
            'requires_human_cognition: reporting is the tool doing its job, not a ' \
            'handoff.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[report operator deliverable prose]
          end

          def related_tools
            %w[context_save write_section]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                content: {
                  type: 'string',
                  description: 'The full text for the operator. Markdown is fine.'
                },
                title: {
                  type: 'string',
                  description: 'Short title, used in the filename and the heading'
                }
              },
              required: ['content']
            }
          end

          def call(arguments)
            content = arguments['content'].to_s
            title = arguments['title'].to_s

            if content.strip.empty?
              return text_content(JSON.generate({
                'error' => 'content is required and must not be empty'
              }))
            end

            if content.length > MAX_CHARS
              return text_content(JSON.generate({
                'error' => "content is #{content.length} characters, over the " \
                           "#{MAX_CHARS} limit. Split it across reports."
              }))
            end

            path = write_report(title, content)
            text_content(JSON.generate({
              'status' => 'ok',
              'report_path' => path,
              'chars' => content.length
            }))
          rescue StandardError => e
            text_content(JSON.generate({ 'error' => "#{e.class}: #{e.message}" }))
          end

          private

          def write_report(title, content)
            dir = File.join(KairosMcp.data_dir, 'log', 'agent_reports')
            FileUtils.mkdir_p(dir)
            stamp = Time.now.strftime('%Y%m%d_%H%M%S')
            path = File.join(dir, "#{stamp}_#{slug(title)}.md")
            File.write(path, body(title, content))
            path
          end

          # The title becomes a heading only when the text has not already got
          # one. The first report written, on 2026-08-26, opened with two
          # headings saying nearly the same thing: the model wrote its own and
          # this prepended another.
          def body(title, content)
            return content if title.strip.empty? || content.lstrip.start_with?('#')

            "# #{title.strip}\n\n#{content}"
          end

          # Filenames only. A title is operator-facing prose and may be in any
          # script, so anything outside a conservative set becomes an underscore
          # rather than being transliterated.
          def slug(title)
            s = title.strip.gsub(/[^A-Za-z0-9_-]+/, '_').gsub(/\A_+|_+\z/, '')
            s.empty? ? 'report' : s[0, 40]
          end
        end
      end
    end
  end
end
