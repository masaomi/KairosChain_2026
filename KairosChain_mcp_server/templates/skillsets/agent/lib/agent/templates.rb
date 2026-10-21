# frozen_string_literal: true

require_relative 'dsl'

module KairosMcp
  module SkillSets
    module Agent
      # Plan templates. The SkillSet writes the plan's source from a template
      # and parameters; the actor does not author it (INV-3), and the stand-in
      # rules on the parameters at the first advance. dev_cycle instantiates
      # L1 design_to_implementation_workflow; impl_cycle is its second half,
      # for a design that is already settled (e.g. "handoff を読んで実装を続けて").
      # doc_cycle edits a document in place on the run branch, survey writes
      # versioned survey files, general takes either form of work. A review
      # closes at no open P0; the policy's rounds for each review are its cap
      # (design v0.6.6).
      module Templates
        NAMES = %w[dev_cycle design_only impl_cycle doc_cycle survey general].freeze

        module_function

        def check_line(tests, test_command, required: true)
          if tests.to_s.strip.empty?
            raise DSL::Error, 'tests (the test directory or glob in the repository) is required' if required

            return test_command ? "check command: #{test_command.to_s.inspect}" : 'check'
          end

          test_command ? "check tests: #{tests.to_s.inspect}, command: #{test_command.to_s.inspect}" : "check tests: #{tests.to_s.inspect}"
        end

        def produce_line(glob, what = 'design_glob (e.g. log/<topic>_design_v*.md)')
          g = glob.to_s
          raise DSL::Error, "#{what} is required" if g.strip.empty?
          raise DSL::Error, "#{what.split(' ').first} must contain * so each version is a new file" unless g.include?('*')

          "produce #{g.inspect}"
        end

        def header(name, template, goal)
          raise DSL::Error, 'goal is required' if goal.to_s.strip.empty?

          "run #{name.to_s.inspect}, template: :#{template} do\n  goal #{goal.to_s.inspect}\n"
        end

        def dev_cycle(name:, goal:, design_glob:, tests:, test_command: nil)
          header(name, :dev_cycle, goal) + <<~RUBY
              phase(:design)                { #{produce_line(design_glob)} }
              phase(:design_review)         { review :mlr, of: :design }
              phase(:implement)             { #{check_line(tests, test_command)} }
              phase(:implementation_review) { review :mlr, of: :implement }
              report :layered_deck
            end
          RUBY
        end

        def design_only(name:, goal:, design_glob:)
          header(name, :design_only, goal) + <<~RUBY
              phase(:design)        { #{produce_line(design_glob)} }
              phase(:design_review) { review :mlr, of: :design }
              report :layered_deck
            end
          RUBY
        end

        def impl_cycle(name:, goal:, tests:, test_command: nil)
          header(name, :impl_cycle, goal) + <<~RUBY
              phase(:implement)             { #{check_line(tests, test_command)} }
              phase(:implementation_review) { review :mlr, of: :implement }
              report :layered_deck
            end
          RUBY
        end

        # A document kept in a git repository, edited in place on the run
        # branch; test_command is an optional build (latexmk, pandoc, make…).
        def doc_cycle(name:, goal:, test_command: nil)
          header(name, :doc_cycle, goal) + <<~RUBY
              phase(:write)        { #{check_line(nil, test_command, required: false)} }
              phase(:write_review) { review :mlr, of: :write, as: :document }
              report :layered_deck
            end
          RUBY
        end

        def survey(name:, goal:, output_glob:)
          header(name, :survey, goal) + <<~RUBY
              phase(:survey)        { #{produce_line(output_glob, 'output_glob (e.g. log/<topic>_survey_v*.md)')} }
              phase(:survey_review) { review :mlr, of: :survey, as: :document }
              report :layered_deck
            end
          RUBY
        end

        # Versioned files (output_glob), or committed work on the run branch
        # with optional tests or command. review_as: design, implementation
        # or document (default document, implementation with tests).
        def general(name:, goal:, output_glob: nil, tests: nil, test_command: nil, review_as: nil)
          work = if output_glob.to_s.strip.empty?
                   check_line(tests, test_command, required: false)
                 else
                   raise DSL::Error, 'give output_glob or tests/test_command, not both' if tests || test_command

                   produce_line(output_glob, 'output_glob (e.g. log/<topic>_v*.md)')
                 end
          as = (review_as || (tests ? 'implementation' : 'document')).to_s
          raise DSL::Error, "review_as must be one of #{DSL::REVIEW_TYPES.join(', ')}" unless DSL::REVIEW_TYPES.include?(as.to_sym)

          header(name, :general, goal) + <<~RUBY
              phase(:work)        { #{work} }
              phase(:work_review) { review :mlr, of: :work, as: :#{as} }
              report :layered_deck
            end
          RUBY
        end

        PARAMS = { 'dev_cycle' => %i[name goal design_glob tests test_command],
                   'design_only' => %i[name goal design_glob],
                   'impl_cycle' => %i[name goal tests test_command],
                   'doc_cycle' => %i[name goal test_command],
                   'survey' => %i[name goal output_glob],
                   'general' => %i[name goal output_glob tests test_command review_as] }.freeze

        def build(template, **params)
          keys = PARAMS[template.to_s] or raise DSL::Error, "unknown template #{template} (#{NAMES.join(', ')})"
          send(template.to_s, **params.slice(*keys).compact)
        end
      end
    end
  end
end
