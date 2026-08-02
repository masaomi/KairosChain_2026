# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # The single shape a dispatched review takes when it crosses into pending
      # state and back.
      #
      # This exists because the same mapping used to be written out three times
      # — in the tool's synchronous delegate path, in the detached worker, and
      # in collect — and R1 found that all three had been left behind when the
      # dispatcher started recording model provenance. The fields were computed
      # and then dropped before anything was written. One mapping in one place
      # can be tested; three copies can only be inspected.
      module ReviewSerializer
        module_function

        def serialize(review)
          {
            'role_label' => review[:role_label],
            'provider' => review[:provider],
            'model' => review[:model],
            # INV-E5 / INV-P1: what the slot was defined to call, what answered
            # if the transport could say, and whether the two disagreed.
            'model_declared' => review[:model_declared],
            'model_observed' => review[:model_observed],
            'model_source' => review[:model_source],
            'model_divergence' => review[:model_divergence],
            # INV-R6: transport diagnostics, as state tags — never bodies or
            # credentials. The adapter has reported these since the 2026-07-31
            # divergence diagnosis; dropping them here was the gap.
            'api_error_status' => review[:api_error_status],
            'fast_mode_state' => review[:fast_mode_state],
            # INV-R7: the form in which this seat was handed the artifact.
            'artifact_delivery' => review[:artifact_delivery],
            'raw_text' => review[:raw_text].to_s,
            'elapsed_seconds' => review[:elapsed_seconds],
            'error' => review[:error],
            'status' => review[:status].to_s,
            'usage' => review[:usage]
          }
        end

        # The row this review becomes in the final record's `reviews` list.
        #
        # This was the fourth copy of a mapping this module exists to hold, and
        # it was written twice — once in the tool's single-phase path, once in
        # collect. Round 8 found the predictable consequence: a fix went to one
        # of the two, so the record's shape depended on which path had run, and
        # the comment at the fixed site described a rule the other site broke.
        # The two callers now cannot disagree, because there is nothing left to
        # disagree about.
        #
        # `.compact` drops what has no value, rather than asserting null. The
        # composition already omits a reason it was not given; a record that
        # omits in one half and nulls in the other makes a reader interpret a
        # difference that means nothing.
        def payload_row(review)
          {
            'role_label' => review[:role_label],
            'provider' => review[:provider],
            'model' => review[:model],
            'model_observed' => review[:model_observed],
            'model_source' => review[:model_source] || 'declared',
            'model_divergence' => review[:model_divergence],
            # INV-P1: a declaration standing in for an observer is not an
            # observer that ran, and this is the only field that says so. It is
            # written even when false, because "not synthetic" is a fact about
            # the row rather than a missing value.
            'synthetic' => review[:synthetic] || false,
            'verdict' => review[:verdict],
            # INV-R3: for a persona seat, the rule that derived the seat's
            # verdict from its rows — and the rows themselves, one per
            # accepted persona body (name + stated verdict).
            'verdict_derivation' => review[:verdict_derivation],
            'persona_rows' => review[:persona_rows],
            # INV-E4: why the denominator moved belongs beside the row, not
            # only in the composition. Carried, never defaulted — the reason is
            # decided where the SKIP is decided, and a default here states a
            # cause this mapping does not know.
            'skip_reason' => (review[:skip_reason] if review[:verdict] == 'SKIP'),
            # INV-R1: the word a final submission offered where a verdict was
            # expected, kept as its own column beside the closed reason token.
            'stated_text' => review[:stated_text],
            # INV-R6 / INV-R7: transport diagnostics as state tags, and the
            # delivery form this seat received the artifact in.
            'api_error_status' => review[:api_error_status],
            'fast_mode_state' => review[:fast_mode_state],
            'artifact_delivery' => review[:artifact_delivery],
            'elapsed_seconds' => review[:elapsed_seconds],
            'error' => review[:error],
            'raw_text_length' => review[:raw_text].to_s.length
          }.compact
        end

        def deserialize(hash)
          {
            role_label: hash['role_label'],
            provider: hash['provider'],
            model: hash['model'],
            model_declared: hash['model_declared'],
            model_observed: hash['model_observed'],
            # A record written before provenance existed says nothing about
            # where its model name came from. 'declared' is the honest reading
            # of that silence: it is what was asked for, not what was seen.
            model_source: hash['model_source'] || 'declared',
            model_divergence: hash['model_divergence'],
            api_error_status: hash['api_error_status'],
            fast_mode_state: hash['fast_mode_state'],
            artifact_delivery: hash['artifact_delivery'],
            raw_text: hash['raw_text'].to_s,
            elapsed_seconds: hash['elapsed_seconds'] || 0,
            error: hash['error'],
            status: (hash['status'] || 'success').to_sym,
            usage: hash['usage']
          }
        end
      end
    end
  end
end
