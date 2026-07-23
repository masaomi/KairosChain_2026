# frozen_string_literal: true

require 'json'
require_relative 'policy'
require_relative 'canon'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Mechanical, conjunctive verdict (design v0.3 CG-3).
      #
      # Deterministic and LLM-free: a pure function of the pinned policy,
      # the crossing descriptor, and the presented content. The affirmative
      # form is conjunctive — the crossing must be affirmatively designated
      # (absence is denial, CG-1) AND the presented content must clear the
      # policy's content classes. Detection firing nothing on a designated
      # crossing is a pass (detection-bounded, residual stated in CG-5).
      module Verdict
        module_function

        # judge(policy, descriptor, content_json) => constant-key hash:
        #   { verdict: 'pass'|'deny', rule:, crossing:, recordable:, basis: }
        # `recordable` implements the CG-4 record scope for slice 1:
        # denials anywhere, restricted reads (permitted or not), policy-file
        # edits; permitted inward writes are exempt (principled asymmetry).
        def judge(policy, descriptor, content_json)
          basis = { policy_sha256: policy.sha256, engine: Policy::ENGINE_VERSION }
          case descriptor[:class]
          when :outward
            # CG-1 coverage clause: slice 1 ships no outward enforcement,
            # so the whole class is denied, not passed.
            deny('coverage/outward-unenforced', descriptor, basis)
          when :distillation_outward
            # Guard slice-2 first increment (distillation crossing only):
            # conjunctive per-destination verdict. The crossing must be
            # affirmatively designated by the policy (closed-world, CG-1)
            # AND the presented content must clear the content classes.
            # Outward verdicts are recorded pass or deny (CG-4).
            destination = descriptor[:tool]
            return deny("designation/absent:#{destination}", descriptor, basis) unless policy.distillation_crossing?(destination)
            if (hit = policy.content_class_hit(content_json))
              deny("content/#{hit[:id]}", descriptor, basis)
            else
              { verdict: 'pass', rule: "designation/distillation:#{destination}", crossing: descriptor,
                recordable: true, basis: basis }
            end
          when :inward_write
            admission = policy.persistent_admission(descriptor[:layer])
            return deny("designation/absent:#{descriptor[:layer]}", descriptor, basis) unless admission == 'permitted'
            if (hit = policy.content_class_hit(content_json))
              # Transform-and-pass is a slice-2 opt-in; any detection in
              # slice 1 denies (CG-6 default, CG-1 coverage for transform).
              deny("content/#{hit[:id]}", descriptor, basis)
            else
              { verdict: 'pass', rule: "designation/#{descriptor[:layer]}", crossing: descriptor,
                recordable: false, basis: basis }
            end
          when :storage_read
            path = descriptor[:path].to_s
            # An enrolled read tool whose target cannot be extracted must
            # not degrade open (impl review R1): fail-closed.
            return deny('coverage/unextractable-path', descriptor, basis) if path.empty?
            entry = policy.restricted_entry(path)
            # Undesignated storage: not a guarded crossing (§1 scope (c)).
            return { verdict: 'pass', rule: 'unguarded/not-restricted', crossing: descriptor,
                     recordable: false, basis: basis } if entry.nil?
            described = descriptor.merge(designation: entry[:id])
            if entry[:reads] == 'permitted'
              { verdict: 'pass', rule: "designation/read:#{entry[:id]}", crossing: described,
                recordable: true, basis: basis }
            else
              deny("designation/read-denied:#{entry[:id]}", described, basis)
            end
          when :unmapped_read
            # CG-1 coverage clause: resource-scheme readers ship without
            # uri-to-path mapping in slice 1, so the class denies wholesale.
            deny('coverage/read-unmapped', descriptor, basis)
          else
            # Unknown crossing class reaching the verdict is a coverage gap:
            # fail-closed (CG-1).
            deny('coverage/unclassified', descriptor, basis)
          end
        end

        def deny(rule, descriptor, basis)
          { verdict: 'deny', rule: rule, crossing: descriptor, recordable: true, basis: basis }
        end

        # Canonical presentation of the call's content for detection and
        # commitment: deterministic serialization of the arguments (CG-3
        # requires the verdict be reproducible from policy + descriptor +
        # content alone). Faithful to false/nil and to mixed-key hashes
        # (both entries emitted) — see Canon.
        def present_content(arguments)
          Canon.canonical(arguments.is_a?(Hash) ? arguments : {})
        end
      end
    end
  end
end
