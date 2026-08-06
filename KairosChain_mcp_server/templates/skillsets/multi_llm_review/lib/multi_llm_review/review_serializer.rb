# frozen_string_literal: true

require_relative 'sanitizer'

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
        # How much of a reviewer's reply the final record carries without being
        # asked. The record used to carry only the reply's length, so the one
        # thing a later reader needs in order to check what a verdict was drawn
        # from — the reviewer's own words — was reachable from nowhere: all
        # four rounds measured on 2026-08-04 returned raw_text as "" while
        # raw_text_length reported the real size. Nothing is summarised or
        # paraphrased — but the excerpt is NOT a prefix of the reply and NOT
        # verbatim: it is the head of the sanitiser's transcription, and
        # sanitisation rewrites (measured: a tag straddling 4,000 newlines
        # collapses to 18 bytes; a U+2028 line break welds its neighbours).
        # The full extent of the alteration is stated at the excerpt field
        # below and in the tool schema.
        RAW_TEXT_EXCERPT_LEN = 4096

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
        def payload_row(review, include_raw_text: false)
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
            #
            # Left verbatim, deliberately, after an attempt to sanitize it was
            # measured to corrupt what it records. This column exists to say
            # what word a submission offered where a verdict was expected, and
            # the sanitizer normalises before escaping — so a fullwidth APPROVE,
            # refused precisely because it is not the ASCII word, came back as
            # "APPROVE" beside a skip_reason of no_verdict. The record then
            # asserts the reviewer wrote something it did not write, and the one
            # column explaining the refusal becomes the column hiding it.
            # Escaping without normalising is the fix, and it needs a sanitizer
            # entry point that does not exist yet; recorded as separate work.
            'stated_text' => review[:stated_text],
            # INV-R6 / INV-R7: transport diagnostics as state tags, and the
            # delivery form this seat received the artifact in.
            'api_error_status' => review[:api_error_status],
            'fast_mode_state' => review[:fast_mode_state],
            'artifact_delivery' => review[:artifact_delivery],
            'elapsed_seconds' => review[:elapsed_seconds],
            # Left as it arrives, deliberately. Every producer writes a Hash of
            # {type, message}, and sanitize_finding_text begins with `to_s`, so
            # an attempt to sanitize it turned the field into a Ruby inspect
            # string: not JSON, not re-parseable, and cut at 500 characters
            # mid-structure. A reader indexing it by 'type' then gets a
            # substring rather than an error, so the wrong value arrives with no
            # exception. Sanitizing the message leaf while keeping the Hash is
            # the fix; recorded as separate work.
            'error' => review[:error],
            # In BYTES, and a fact about the reply AS IT ARRIVED — before
            # sanitisation. It is not comparable against raw_text_excerpt or
            # raw_text: those are cut after NFKC expanded the text, so the two
            # numbers sit on opposite sides of an expanding transform, and R4
            # measured what treating them as comparable does — a 3,000-byte
            # reply under every bound came back holding 12.4% of itself while
            # the comparison said nothing was cut. R5 tried a completeness flag
            # instead and it was measured wrong in both directions: "was
            # anything dropped" cannot be answered by byte counts taken around
            # a pass that also rewrites, strips and escapes. So the record now
            # claims less, on purpose. This is the arriving size; the two text
            # fields are bounded sanitised transcriptions; and no field asserts
            # whether they hold the whole reply, because nothing here can know.
            'raw_text_length' => review[:raw_text].to_s.bytesize,
            # Written unconditionally, so a caller that has never heard of
            # include_raw_text still reaches evidence. `.compact` drops nil,
            # not '', so a failed row shows an empty excerpt beside a zero
            # length — which says the reviewer answered nothing, where an
            # omitted field would say only that this mapping declined to
            # speak.
            #
            # Sanitized, because this is the first field to put a reviewer's
            # own prose into the returned payload rather than a fact about it.
            # The length above is a measurement and cannot carry an escape; the
            # text can. Sanitised means NOT VERBATIM, and the schema says so:
            # NFKC rewrites compatibility forms (a fullwidth ＡＰＰＲＯＶＥ is
            # stored as the ASCII word, beside a stated_text that deliberately
            # keeps the fullwidth form), the control strip removes invisible
            # characters including five of Unicode's mandatory line breaks
            # (only LF, CR and TAB survive), and the tag escape rewrites — a
            # tag straddling unbounded whitespace collapses to [escaped:tag].
            # Nothing is summarised, but what is stored is the sanitiser's
            # transcription of the reply, not the reply. Escaping without
            # normalising — the entry point stated_text is waiting on above —
            # is the fix for the worst of this, recorded as separate work.
            # Clamped on both sides of the sanitize, for two different reasons.
            # The inner clamp bounds the INPUT: a reviewer reply arrives
            # unbounded, and the per-character control pass over a multi-megabyte
            # string is where the cost is. The outer clamp bounds the OUTPUT:
            # sanitize_finding_text cuts in CHARACTERS and NFKC runs before that
            # cut, so a text inside the byte budget going in can be several times
            # over it coming out. Both bounds are the one the schema declares.
            #
            # NFKC also composes, so the inner clamp can cut marginally earlier
            # than the declared bound where a decomposed sequence would have
            # shrunk. That costs a reader the tail of an excerpt and is accepted
            # rather than mechanised.
            'raw_text_excerpt' =>
              Sanitizer.clamp_finding_bytes(
                Sanitizer.sanitize_finding_text(
                  Sanitizer.clamp_finding_bytes(review[:raw_text], max_bytes: RAW_TEXT_EXCERPT_LEN),
                  max_len: RAW_TEXT_EXCERPT_LEN
                ),
                max_bytes: RAW_TEXT_EXCERPT_LEN
              ),
            'raw_text' =>
              (Sanitizer.clamp_finding_bytes(
                Sanitizer.sanitize_finding_text(
                  Sanitizer.clamp_finding_bytes(
                    review[:raw_text], max_bytes: Sanitizer::RAW_TEXT_FULL_MAX_LEN
                  ),
                  max_len: Sanitizer::RAW_TEXT_FULL_MAX_LEN
                ),
                max_bytes: Sanitizer::RAW_TEXT_FULL_MAX_LEN
              ) if include_raw_text)
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
