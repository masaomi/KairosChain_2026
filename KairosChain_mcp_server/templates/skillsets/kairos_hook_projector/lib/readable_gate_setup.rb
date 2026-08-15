# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      # Add the readable gate to a mode, in one call: declare it, then install
      # it. Nothing else.
      #
      # It does not read the mode body and it decides nothing about it. An
      # earlier draft derived `section` from the validator's candidate list and
      # refused when that list was not exactly one entry — which put a reading
      # of the mode inside a command whose job is to add a gate, and turned
      # `tutorial` into an interrogation. The declaration is written from the
      # catalogue, section and thresholds included; they are the mode's own to
      # edit afterwards, in the file this points at.
      #
      # `blocking` stays false, because that is what the catalogue ships. The
      # verdict is reported as the validator states it — including
      # OPEN_QUESTIONS, which means the gate is installed and some other
      # section of the mode carries a limit with no recorded decision. That is
      # information, not failure, and the same draft reported it as a refusal
      # after a successful install.
      class ReadableGateSetup
        # status: :ok | :proposed | :refused
        Result = Struct.new(:status, :detail, :data, keyword_init: true)

        GATE = 'readable_gate'

        # `tools` exists so the sequence and the status mapping can be driven
        # with doubles, the way this SkillSet's other tests drive the tools
        # themselves. Default is the real trio; nothing else supplies it.
        def initialize(skillset_root:, tools: nil)
          @root = skillset_root
          @tools = tools
        end

        def run(mode:, section: nil, apply: false)
          load_tools

          added = call(tool(:add), 'mode' => mode, 'gate' => GATE)
          declaration = added['declaration']
          unless declaration && %w[created appended].include?(added['action'])
            return refuse('mode_hooks_add wrote no declaration: ' \
                          "#{added['refusal'] || added['error'] || added['action'] || added.inspect}")
          end
          rename_section(declaration, section) if section

          plan = call(tool(:project), 'mode' => mode)
          if plan['plan_sha256'].nil?
            return refuse("mode_hooks_project refused: #{plan['detail'] || plan.inspect}")
          end

          data = { 'declaration' => declaration, 'plan' => plan }
          return Result.new(status: :proposed, detail: 'nothing written', data: data) unless apply

          applied = call(tool(:project), 'mode' => mode, 'apply' => true,
                                         'confirm_sha256' => plan['plan_sha256'])
          unless applied['action'] == 'applied'
            return refuse("apply did not apply: #{applied['action'] || applied.inspect}")
          end

          # The apply result asserts no liveness in either direction, by design.
          # A fresh read is the only thing that answers whether the gate is on.
          after = call(tool(:validate), 'mode' => mode)
          Result.new(status: :ok, detail: 'installed',
                     data: data.merge('verdict' => after['verdict'],
                                      'checks' => after['checks']))
        end

        private

        def refuse(detail)
          Result.new(status: :refused, detail: detail, data: nil)
        end

        # mode_hooks_add takes no `section`, so a caller who named one has it
        # written here, into the file add just wrote. No check that the heading
        # exists: the caller said it, and the mode body is theirs.
        def rename_section(path, section)
          doc = JSON.parse(File.read(path, encoding: 'UTF-8'))
          entry = doc.dig('hooks', 'Stop')&.find { |e| e['gate'] == GATE }
          return if entry.nil?

          entry['section'] = section
          File.write(path, JSON.pretty_generate(doc) + "\n", encoding: 'UTF-8')
        end

        def call(klass, args)
          JSON.parse(klass.new.call(args).first[:text])
        end

        def tool(which)
          return @tools.fetch(which) if @tools

          { add: Tools::ModeHooksAdd, project: Tools::ModeHooksProject,
            validate: Tools::ModeHooksValidate }.fetch(which)
        end

        def load_tools
          return if @tools || (defined?(@loaded) && @loaded)

          %w[mode_hooks_add mode_hooks_project mode_hooks_validate].each do |t|
            require File.join(@root, 'tools', t)
          end
          @loaded = true
        end
      end
    end
  end
end
