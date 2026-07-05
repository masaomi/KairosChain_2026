# frozen_string_literal: true

module Synoptis
  module Constitutive
    # ACT-2 selection criterion (first-cut, revisable). Given a session, proposes the
    # session's judgment-bearing L2 contexts — those whose frontmatter `type` is in the
    # configured judgment set (default: handoff / decision / debrief).
    #
    # This is intentionally simple and config-driven now; it evolves toward an
    # LLM-semantic criterion that reads content (design §4 note, §11). Simplicity is safe
    # because ACT-1 puts a human approval gate after every proposal: a wrong proposal is
    # declined, never silently attested. Proposals are recommendations only — they create
    # no attestation and no obligation until approved.
    class ProposalCriterion
      DEFAULT_JUDGMENT_TYPES = %w[handoff decision debrief].freeze

      def initialize(context_dir:, judgment_types: DEFAULT_JUDGMENT_TYPES)
        @context_dir = context_dir
        @judgment_types = Array(judgment_types).map(&:to_s)
      end

      # Returns an array of proposals:
      #   { subject_id:, type:, content_state: }
      def propose(session_id:)
        session_dir = File.join(@context_dir, session_id.to_s)
        return [] unless Dir.exist?(session_dir)

        Dir.children(session_dir).sort.filter_map do |context_name|
          next unless File.directory?(File.join(session_dir, context_name))

          uri = "context://#{session_id}/#{context_name}"
          type = SubjectRef.frontmatter_type(uri, context_dir: @context_dir)
          next unless type && @judgment_types.include?(type.to_s)

          {
            subject_id: uri,
            type: type.to_s,
            content_state: SubjectRef.content_state(uri, context_dir: @context_dir)
          }
        end
      end
    end
  end
end
