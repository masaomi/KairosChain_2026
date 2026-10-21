# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStart < KairosMcp::Tools::BaseTool
          def name
            'agent_start'
          end

          def description
            "Start an agent run (a long, autonomous development run in this session) from a plan template, or take up a run without a report (resume). Needs an adopted policy (the operator's mandate) and the agent hooks live in this session; the session binds to the run at once. Templates: dev_cycle (design → design review → implement → implementation review → report), impl_cycle (implement → implementation review → report, for a settled design), design_only."
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent run autonomous]
          end

          def related_tools
            %w[agent_start agent_status agent_advance agent_items agent_finish agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                goal: { type: 'string', description: "What the run is for, in the operator's words where possible." },
                template: { type: 'string', description: 'dev_cycle (default: design → review → implement → review), impl_cycle (design settled), design_only, doc_cycle (write or revise a document kept in git, in place on the run branch), survey (survey a theme into versioned files), or general (any other work: output_glob, or committed work).' },
                design_glob: { type: 'string', description: 'Where design versions go in the main checkout, e.g. log/foo_design_v*.md (each version a new file).' },
                output_glob: { type: 'string', description: 'survey, general: where versions of the output go in the main checkout, e.g. log/foo_survey_v*.md (each version a new file).' },
                tests: { type: 'string', description: 'Test directory or glob in the repository (required for dev_cycle, impl_cycle; optional for general). A directory pins every file under it from the base commit; a glob pins only what it matches. Test files are re-run by the SkillSet.' },
                test_command: { type: 'string', description: 'With tests: a test runner (ruby, bundle, rake, pytest, npm, go, cargo, make, … or a script the repository tracks), run without a shell with one test file appended (default: ruby -Ilib -Itest, or python3 -m pytest). Without tests (doc_cycle, general): a build run once from the worktree root (latexmk, pandoc, typst, quarto, make, or a tracked script).' },
                review_as: { type: 'string', description: 'general: the review type (design, implementation or document; default document, implementation with tests).' },
                target_repo: { type: 'string', description: "Repository the run works on (default: this session's project)." },
                name: { type: 'string', description: 'Short run name.' },
                resume: { type: 'string', description: 'Run id of a run without a report (its session gone or quiet, interrupted, or ended) to take up in this session.' }
              },
              required: []
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).start(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
