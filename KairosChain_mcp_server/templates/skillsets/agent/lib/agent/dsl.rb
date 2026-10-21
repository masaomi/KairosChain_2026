# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module Agent
      # One Ruby DSL for the two documents that shape a run (design v0.5 §4):
      # the operator's policy (the mandate) and the run plan. Both are kept as
      # source text and pinned by the SHA-256 of their bytes; the objects
      # built from them are frozen. A plan may narrow the policy, never widen
      # it (INV-2); `Plan#check_against` enforces that at instantiation.
      module DSL
        class Error < StandardError; end

        STAND_IN_CLASSES = %i[precedent instruction_mode novel_reversible].freeze
        CONSENT_KINDS = %i[review].freeze
        REVIEW_TYPES = %i[design implementation document].freeze

        Policy = Struct.new(:name, :stand_in_classes, :consents, :free_of_personal_data,
                            :spend, :source, :digest, keyword_init: true) do
          def consents?(kind, scope = nil)
            consents.any? { |c| c[:kind] == kind && (scope.nil? || c[:of] == scope) }
          end

          def free_of_personal_data?(project)
            free_of_personal_data.include?(project.to_s)
          end

          def allows?(stand_in_class)
            stand_in_classes.include?(stand_in_class.to_sym)
          end
        end

        Phase = Struct.new(:name, :kind, :args, keyword_init: true)

        Plan = Struct.new(:name, :template, :goal, :tier, :phases, :report, :spend,
                          :source, :digest, keyword_init: true) do
          def phase(name)
            phases.find { |p| p.name == name.to_sym }
          end

          def phase_names
            phases.map(&:name)
          end

          # Spend may be narrowed by a plan, never raised above the policy's.
          def check_against(policy)
            policy.spend.each do |key, limit|
              mine = spend[key]
              next if mine.nil?
              raise Error, "plan spend #{key}=#{mine} exceeds policy #{limit}" if mine > limit
            end
            self
          end
        end

        module_function

        def digest(source)
          Digest::SHA256.hexdigest(source)
        end

        # Policies are operator-owned files; evaluated in a builder that
        # exposes only the DSL's words.
        def parse_policy(source)
          builder = PolicyBuilder.new
          builder.instance_eval(source, '(policy)')
          builder.result(source)
        end

        def parse_plan(source)
          builder = PlanBuilder.new
          builder.instance_eval(source, '(plan)')
          builder.result(source)
        end

        class PolicyBuilder < BasicObject
          def initialize
            @name = nil
            @classes = []
            @consents = []
            @free = []
            @spend = {}
          end

          def policy(name, &block)
            ::Kernel.raise Error, 'one policy per document' if @name
            @name = name.to_s
            instance_eval(&block)
          end

          def stand_in(may:)
            bad = ::Kernel.Array(may) - STAND_IN_CLASSES
            ::Kernel.raise Error, "unknown stand-in classes: #{bad.inspect}" unless bad.empty?
            @classes = ::Kernel.Array(may).map(&:to_sym)
          end

          def consent(**opts)
            kind = opts.keys.first
            ::Kernel.raise Error, "unknown consent: #{kind.inspect}" unless CONSENT_KINDS.include?(kind)
            @consents << { kind: kind, value: opts[kind], of: opts[:of] }
          end

          def free_of_personal_data(projects:)
            @free = ::Kernel.Array(projects).map(&:to_s)
          end

          def spend(default:)
            @spend = default.transform_keys(&:to_sym)
          end

          def result(source)
            ::Kernel.raise Error, 'policy has no name' unless @name
            ::Kernel.raise Error, 'policy sets no spend bound' if @spend.empty?
            Policy.new(name: @name, stand_in_classes: @classes.freeze, consents: @consents.freeze,
                       free_of_personal_data: @free.freeze, spend: @spend.freeze,
                       source: source, digest: DSL.digest(source)).freeze
          end
        end

        class PlanBuilder < BasicObject
          def initialize
            @name = nil
            @phases = []
            @spend = {}
          end

          def run(name, template:, &block)
            ::Kernel.raise Error, 'one run per document' if @name
            @name = name.to_s
            @template = template.to_sym
            instance_eval(&block)
          end

          def goal(text)
            @goal = text.to_s
          end

          def tier(n)
            @tier = ::Kernel.Integer(n)
          end

          def spend(**limits)
            @spend = limits.transform_keys(&:to_sym)
          end

          def phase(name, &block)
            builder = PhaseBuilder.new(name.to_sym)
            builder.instance_eval(&block) if block
            @phases << builder.result
          end

          def report(kind)
            @report = kind.to_sym
          end

          def result(source)
            ::Kernel.raise Error, 'plan has no name' unless @name
            ::Kernel.raise Error, 'plan has no phases' if @phases.empty?
            # A review reads an earlier produce or check phase.
            @phases.each_with_index do |ph, i|
              next unless ph.kind == :review

              target = @phases.first(i).find { |q| q.name == ph.args[:of] }
              unless target && %i[produce check].include?(target.kind)
                ::Kernel.raise Error, "review #{ph.name} must name an earlier produce or check phase, not #{ph.args[:of]}"
              end
            end
            Plan.new(name: @name, template: @template, goal: @goal, tier: @tier, phases: @phases.freeze,
                     report: @report || :layered_deck, spend: @spend.freeze,
                     source: source, digest: DSL.digest(source)).freeze
          end
        end

        class PhaseBuilder < BasicObject
          def initialize(name)
            @name = name
            @kind = nil
            @args = {}
          end

          def produce(glob)
            set(:produce, glob: glob.to_s)
          end

          # A review closes at no open P0; max_rounds, when given, is a cap
          # at which it waits for the operator. `as` is the review type; by
          # default it follows the reviewed phase's kind.
          def review(kind, of:, max_rounds: nil, as: nil)
            ::Kernel.raise Error, "unknown review type #{as.inspect}" if as && !REVIEW_TYPES.include?(as.to_sym)

            set(:review, reviewer: kind.to_sym, of: of.to_sym, max_rounds: max_rounds && ::Kernel.Integer(max_rounds),
                         as: as&.to_sym)
          end

          # Committed work on the run branch, checked by its tests, by a
          # command (a test runner or a build), or by neither.
          def check(tests: nil, command: nil)
            set(:check, tests: tests&.to_s, command: command&.to_s)
          end

          def result
            ::Kernel.raise Error, "phase #{@name} has no kind" unless @kind
            Phase.new(name: @name, kind: @kind, args: @args.freeze).freeze
          end

          private

          def set(kind, args)
            ::Kernel.raise Error, "phase #{@name} has two kinds" if @kind
            @kind = kind
            @args = args
          end
        end
      end
    end
  end
end
