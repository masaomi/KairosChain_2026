# frozen_string_literal: true

module Hestia
  # Shared presenter for public data — used by both JSON API and HTML views.
  # Truncates IDs and strips content to prevent information leakage.
  class PublicPresenter
    ID_TRUNCATE_LENGTH = 12

    def catalog_entry(entry, auditor = nil)
      deposit_id = make_deposit_id(entry)
      {
        deposit_id: deposit_id,
        skill_id: entry[:skill_id],
        name: entry[:name],
        description: truncate(entry[:description], 500),
        tags: entry[:tags] || [],
        format: entry[:format],
        type: entry[:type],
        size_bytes: entry[:size_bytes],
        content_hash: entry[:content_hash]&.slice(0, 16),
        deposited_at: entry[:deposited_at],
        depositor_id: truncate_id(entry[:agent_id] || entry[:depositor_id]),
        summary: truncate(entry[:summary], 500),
        version: entry[:version],
        license: entry[:license],
        attestation_count: entry[:attestations]&.size || 0,
        audit_status: auditor ? auditor.audit_status(deposit_id)[:status] : nil
      }
    end

    def skill_detail(skill, auditor = nil)
      base = catalog_entry(skill, auditor)
      base.merge(
        sections: skill[:sections],
        first_lines: skill[:first_lines],
        input_output: skill[:input_output],
        attestations: present_attestations(skill[:attestations]),
        trust_notice: skill[:trust_notice],
        audit_detail: auditor ? auditor.audit_status(make_deposit_id(skill)) : nil
      )
    end

    def agent_profile(agent)
      id = agent.respond_to?(:id) ? agent.id : agent[:id]
      {
        agent_id: truncate_id(id),
        name: agent.respond_to?(:name) ? agent.name : agent[:name],
        description: agent.respond_to?(:description) ? agent.description : agent[:description],
        registered_at: agent.respond_to?(:registered_at) ? agent.registered_at : agent[:registered_at]
      }
    end

    def make_deposit_id(entry)
      agent = entry[:agent_id] || entry[:depositor_id]
      skill = entry[:skill_id]
      "#{agent}__#{skill}" if agent && skill
    end

    private

    def present_attestations(attestations)
      return [] unless attestations

      attestations.map do |a|
        {
          claim: a[:claim],
          attester_id: truncate_id(a[:attester_id]),
          attester_name: a[:attester_name],
          actor_role: a[:actor_role],
          has_signature: a[:has_signature],
          deposited_at: a[:deposited_at]
        }
      end
    end

    def truncate_id(id)
      return nil unless id
      id.length > ID_TRUNCATE_LENGTH ? "#{id[0, ID_TRUNCATE_LENGTH]}..." : id
    end

    def truncate(text, max)
      return nil unless text
      text.length > max ? "#{text[0, max]}..." : text
    end
  end
end
