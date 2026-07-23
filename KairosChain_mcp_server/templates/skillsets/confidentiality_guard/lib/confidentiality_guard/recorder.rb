# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require_relative 'policy'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Constitutive audit records (design v0.3 CG-4).
      #
      # Records are commitment-bound: they identify the verdict (versioned
      # basis, grounding rule, crossing descriptor) and bind the presented
      # content by a salted commitment, never containing it. The commitment
      # construction follows the sdp-1 salted field-commitment pattern
      # (domain-tagged SHA-256 over salt + canonical content; 16-byte hex
      # salt); the salt stays with the operator-visible report, off-chain
      # (salt custody is a §8 choice — slice 1 keeps it operator-side).
      #
      # The audit write itself is constitutive of the guard's operation,
      # not a guarded crossing (CG-4): it goes to the chain directly and
      # never back through the tool surface.
      module Recorder
        module_function

        SALT_BYTES = 16
        COMMITMENT_DOMAIN = 'cg-1/content'

        # Injectable chain factory so design-constraint tests can redirect
        # records away from the live chain store.
        @chain_factory = nil

        def chain_factory=(callable)
          @chain_factory = callable
        end

        def chain
          if @chain_factory
            @chain_factory.call
          else
            # In-server the chain class is already loaded; the require path
            # is a template-layout fallback for standalone runs (tests).
            unless defined?(KairosMcp::KairosChain::Chain)
              # Template layout: 5 ups to the server root (impl review
              # parity fix with chain_distillation R1).
              require_relative '../../../../../lib/kairos_mcp/kairos_chain/chain'
            end
            KairosMcp::KairosChain::Chain.new
          end
        end

        def commitment(content_json)
          salt = SecureRandom.hex(SALT_BYTES)
          digest = Digest::SHA256.hexdigest("#{COMMITMENT_DOMAIN}|#{salt}|#{content_json}")
          { salt: salt, digest: digest }
        end

        # Re-derivation check (CG-4): given a record's digest, the salt from
        # the operator report, and a re-presentation of the content, verify
        # the commitment binds. The record alone reconstructs nothing.
        def commitment_valid?(digest, salt, content_json)
          Digest::SHA256.hexdigest("#{COMMITMENT_DOMAIN}|#{salt}|#{content_json}") == digest
        end

        def record_decision(verdict_result, commitment_digest)
          entry = {
            'type'          => 'cg_guard_decision',
            'verdict'       => verdict_result[:verdict],
            'rule'          => verdict_result[:rule],
            'crossing'      => descriptor_fields(verdict_result[:crossing]),
            'policy_sha256' => verdict_result[:basis][:policy_sha256],
            'engine'        => verdict_result[:basis][:engine],
            'commitment'    => commitment_digest
          }
          append(entry)
        end

        def record_regime_event(event, policy)
          append(
            'type'          => 'cg_guard_regime',
            'event'         => event,
            'policy_sha256' => policy&.sha256,
            'engine'        => KairosMcp::SkillSets::ConfidentialityGuard::Policy::ENGINE_VERSION,
            'profile'       => policy&.profile_path ? File.basename(policy.profile_path) : nil
          )
        end

        def record_policy_edit(descriptor, commitment_digest, policy)
          append(
            'type'          => 'cg_policy_edit',
            'tool'          => descriptor[:tool],
            'path'          => File.basename(descriptor[:path].to_s),
            'pinned_sha256' => policy.sha256,
            'commitment'    => commitment_digest
          )
        end

        def append(entry)
          chain.add_block([JSON.generate(entry)])
        end

        # Record fields are identifiers, versions, descriptors, and
        # commitments — never content (§7). Storage-read records carry the
        # designation id, not the raw caller-supplied path (which can
        # itself be sensitive); the path is bound by the commitment.
        def descriptor_fields(descriptor)
          fields = { 'class' => descriptor[:class].to_s, 'tool' => descriptor[:tool] }
          fields['layer'] = descriptor[:layer] if descriptor[:layer]
          fields['designation'] = descriptor[:designation] if descriptor[:designation]
          fields['certificate_identity'] = descriptor[:certificate_identity] if descriptor[:certificate_identity]
          fields
        end
      end
    end
  end
end
