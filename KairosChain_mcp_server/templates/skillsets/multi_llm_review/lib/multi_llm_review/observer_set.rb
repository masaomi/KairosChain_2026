# frozen_string_literal: true

require_relative 'persona_assembly'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Constructs the observer set for one review run.
      #
      # This is the implementation of the design invariants frozen on
      # 2026-07-27 (docs/drafts/multi_llm_review_escalation_and_persona_model_design_v06):
      #
      #   INV-E1  the canonical set lives in config; callers may only ask for
      #           extra slots, never replace the set
      #   INV-E3  extra slots come from a provider-neutral container in config
      #   INV-E5  every externally executed slot names the model and provider
      #           it calls; nothing inherits an external CLI default
      #   INV-P2  the observer set is determined uniquely from the canonical
      #           set plus the declarations, in one pass with explicit
      #           precedence
      #
      # The precedence in build/1 is load-bearing and was arrived at after a
      # round of review in which two separate invariants issued opposite
      # instructions for the same slot. Occupancy is resolved first; the
      # caller-slot rule then applies only to what occupancy did not claim.
      class ObserverSet
        class RosterError < StandardError; end

        # Reasons a canonical slot does not appear as an independent observer.
        REASON_PERSONA_OCCUPIED = 'persona_occupied'
        REASON_CALLER_SLOT      = 'caller_slot_not_self_reviewed'

        Result = Struct.new(
          :dispatch,            # slots to run as external processes
          :persona,             # {convened:, model:, occupies:, independent:}
          :excluded,            # [{role_label:, model:, reason:}]
          :escalation_requested,  # the caller asked, whatever came of it
          :escalated,             # true when the container contributed slots
          :escalation_labels,     # role_labels contributed by the container
          :escalation_dispatched, # of those, the ones that actually ran
          keyword_init: true
        ) do
          # How many fewer observers answer than the configuration named.
          #
          # Not the same question as "did a slot leave the set": a slot the
          # persona took over left the set and was answered for, and a caller
          # slot dropped while an independent persona was convened cost the
          # denominator nothing. The rule that lowers the bar after an
          # exclusion is about the denominator, so it asks this rather than
          # asking which reason fired.
          def observers_lost
            excluded.size - (persona[:convened] ? 1 : 0)
          end
        end

        # @param roster [Array<Hash>] canonical reviewer entries (symbol keys)
        # @param escalation [Array<Hash>] container entries from config
        # @param escalate [Boolean] caller asked for the container
        # @param persona_model [String, nil] declared persona execution model
        # @param orchestrator_model [String, nil] declared caller model
        # @param separate_context [Boolean] caller asked for its own slot to
        #   run as a fresh external process anyway
        # @param convene_persona [Boolean] when false, no persona is convened
        #   even though a declaration is present. This is how a caller declines
        #   the INV-P2 fallback (the legacy "exclude" strategy): its slot still
        #   leaves the set, but nothing takes its place.
        def self.build(roster:, escalation: [], escalate: false,
                       persona_model: nil, orchestrator_model: nil,
                       separate_context: false, convene_persona: true)
          slots = normalize(roster)
          escalation_slots = escalate ? normalize(escalation) : []

          # Validation comes before anything reads a field off a slot, so
          # malformed config is reported as a roster fault rather than as
          # whatever the first read happens to raise.
          all = slots + escalation_slots
          validate_slots!(all)

          escalation_labels = escalation_slots.map { |s| s[:role_label] }

          # INV-P2, clause 1: the persona is convened when a persona model is
          # declared, or when only the caller declares itself (its declaration
          # then stands in that position). With neither, no persona is
          # convened and the run completes in a single phase.
          effective_persona = present(persona_model) || present(orchestrator_model)
          effective_persona = nil unless convene_persona
          convened = !effective_persona.nil?

          # The persona is an observer in the record like any other, so the
          # rule against two observers sharing a name reaches it too. Only the
          # slots were checked against each other, and the persona's own name
          # is not one of them: it is constructed from a declaration the caller
          # makes at call time, so a roster can be written today that collides
          # with a persona convened tomorrow. Both rows then appear under one
          # name and the findings each cited become unattributable.
          #
          # Compared against every slot, not only the dispatched ones: a slot
          # the persona took over, or one dropped as the caller's own, still
          # appears in the composition under its name.
          if convened
            persona_label = PersonaAssembly.role_label_for(effective_persona)
            if all.any? { |s| s[:role_label] == persona_label }
              raise RosterError,
                "a reviewer slot is named #{persona_label}, which is the name " \
                'this system gives the persona team convened on ' \
                "#{effective_persona}. Two observers would share one name in " \
                'the record; rename the slot.'
            end
          end

          occupied = nil
          if convened
            # INV-P2, clause 2: exactly one matching slot is occupied. Which
            # one, when several match, is deliberately left to this choice
            # (first in canonical order) — the invariant fixes the count, not
            # the selection.
            occupied = all.find { |s| s[:model] == effective_persona }
          end

          # Both rules compare against the caller's declaration, so both use
          # the same normalized value. Comparing occupancy against the stripped
          # form and the caller-slot rule against the raw argument meant a
          # trailing space made one rule fire and the other silently not.
          caller = present(orchestrator_model)

          excluded = []
          caller_slot_taken = false
          dispatch = all.reject do |slot|
            if occupied && slot.equal?(occupied)
              excluded << exclusion(slot, REASON_PERSONA_OCCUPIED,
                                    PersonaAssembly.role_label_for(effective_persona))
              true
            elsif !caller_slot_taken && !separate_context &&
                  caller && slot[:model] == caller
              # INV-P2, clause 3: applies only to what occupancy did not claim,
              # which is what makes the two rules non-conflicting when the
              # caller and the persona declare the same model.
              #
              # "one matching the caller does not run" is read as written: at
              # most one. Clause 2 fixes its own count explicitly ("exactly
              # one") and this clause does not, so reading it as "every match"
              # would add a quantifier the invariant declines to state.
              #
              # The reading is only observable from three matching slots up: at
              # one, clause 2 takes it; at two, clause 2 takes one and this
              # clause takes the other; from three, the surplus runs — as a
              # fresh external process on that model, which is the same thing a
              # separate-context request buys deliberately. Reading this as
              # "every match" would silently shrink a roster somebody built on
              # purpose, and a caller wanting that can ask for it.
              #
              # Settled by the author on 2026-07-27 as letter, not purpose:
              # overriding a frozen invariant from the code is the wrong
              # direction, and widening it belongs in a re-freeze of the
              # invariant text rather than here.
              caller_slot_taken = true
              excluded << exclusion(slot, REASON_CALLER_SLOT)
              true
            else
              false
            end
          end

          Result.new(
            dispatch: dispatch,
            persona: {
              convened: convened,
              model: effective_persona,
              occupies: occupied && occupied[:role_label],
              independent: convened && occupied.nil?
            },
            excluded: excluded,
            # INV-E4. Asking for extra observers and getting none is a
            # different run from not asking, and only this field tells them
            # apart: an empty or misspelt container collapses the one onto the
            # other, and the record then asserts — not omits — that escalation
            # was never requested. Because the convergence rule is a ratio, the
            # denominator the operator intended and the one they got differ,
            # and a reader diagnosing a low observer count concludes the flag
            # was forgotten.
            escalation_requested: escalate ? true : false,
            escalated: !escalation_slots.empty?,
            escalation_labels: escalation_labels,
            # What the container offered and what it actually added are not the
            # same number. A contributed slot can be taken over by the persona
            # or dropped as the caller's own, and a record that lists only the
            # offer says a slot ran when it did not. Resolved after the
            # rejection pass for exactly that reason.
            #
            # Matched by slot identity, not by label: an intersection of label
            # lists answers "does this name appear on both sides", which is a
            # different question and gives the wrong answer whenever a name
            # appears more than once. Uniqueness is now enforced, so the two
            # agree — but the question this field asks is which slot objects
            # survived, and it should ask it directly.
            escalation_dispatched: dispatch
              .select { |s| escalation_slots.any? { |e| e.equal?(s) } }
              .map { |s| s[:role_label] }
          )
        end

        # INV-E5: a slot that does not name its model would inherit whatever
        # the external CLI happens to default to, which is user-editable and
        # outside this repository. That is how the recorded role label and the
        # answering model came apart in production on 2026-07-27, so this is
        # refused rather than warned about.
        def self.validate_slots!(slots)
          slots.each do |slot|
            unless slot.is_a?(Hash)
              raise RosterError,
                "reviewer slot #{slot.inspect} is not a mapping; each entry " \
                'names a provider, a model and a role_label'
            end

            label = slot[:role_label] || slot[:provider] || '(unnamed)'
            if blank?(slot[:provider])
              raise RosterError, "reviewer slot #{label} does not name a provider"
            end
            if blank?(slot[:model])
              raise RosterError,
                "reviewer slot #{label} does not name a model; a slot that " \
                'omits it inherits the external CLI default, which INV-E5 forbids'
            end
            if blank?(slot[:role_label])
              raise RosterError,
                "a reviewer slot on #{slot[:provider]}/#{slot[:model]} has no " \
                'role_label; the record identifies observers by that name'
            end
          end

          # INV-E4: the record identifies an observer by its role_label, so two
          # slots sharing one are indistinguishable in it — and if both run,
          # one model casts two votes while the composition shows two rows a
          # reader cannot tell apart. The way this actually happens is a roster
          # entry also listed in the escalation container, where the duplicate
          # only appears on calls that escalate.
          duplicates = slots.map { |s| s[:role_label] }
                            .tally.select { |_, n| n > 1 }.keys
          return if duplicates.empty?

          raise RosterError,
            "reviewer slots share a role_label: #{duplicates.sort.join(', ')}. " \
            'Observers are identified by that name in the record, and a ' \
            'repeated one both votes twice and cannot be told apart afterwards.'
        end

        def self.normalize(entries)
          (entries || []).map do |e|
            e.is_a?(Hash) ? e.transform_keys(&:to_sym) : e
          end
        end

        def self.exclusion(slot, reason, replaced_by = nil)
          entry = { role_label: slot[:role_label], model: slot[:model], reason: reason }
          # A slot the persona took over appears twice in the record: once as
          # the slot that did not run, once as the persona that answered in its
          # place. Naming the replacement keeps a reader from counting the two
          # as separate observers.
          entry[:replaced_by] = replaced_by if replaced_by
          entry
        end

        def self.present(value)
          s = value.to_s.strip
          s.empty? ? nil : s
        end

        def self.blank?(value)
          value.nil? || value.to_s.strip.empty?
        end

        private_class_method :exclusion, :present, :blank?
      end
    end
  end
end
