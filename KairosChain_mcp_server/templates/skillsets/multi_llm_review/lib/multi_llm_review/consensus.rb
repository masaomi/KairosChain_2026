# frozen_string_literal: true

require 'json'
require_relative 'verdict_vocabulary'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Three-state consensus engine for multi-LLM review results.
      #
      # States:
      #   APPROVE — reviewer explicitly approved
      #   REJECT  — reviewer explicitly rejected (deliberate)
      #   SKIP    — transport error, timeout, ENOENT, cancelled, or a reply
      #             that carries a verdict word and nothing else
      #
      # Verdicts:
      #   APPROVE      — enough approvals, no rejections
      #   REVISE       — any rejection, or not enough approvals
      #   INSUFFICIENT — fewer than min_quorum successful reviews
      class Consensus
        # INV-E2: only a review with substance enters the denominator. A slot
        # that answers with its verdict and nothing else raises the required
        # agreement without contributing to it — the failure mode that retired
        # one roster occupant after five rounds of replies carrying neither a
        # stated judgement nor findings. The判定 is mechanical by construction:
        # no model is asked whether a review is substantive.
        #
        # The rule is binary and has no tunable floor, which is a correction of
        # three earlier attempts that all measured length and all broke in a
        # different direction: a large floor on the whole reply passed a page of
        # repeated verdict words; a large floor on the residue threw away a
        # terse review carrying a finding; a small floor threw away Japanese
        # reviews ("競合状態あり" leaves six characters) while passing the
        # English "No findings" by a single character. No number is correct,
        # because the quantity being measured is not the one that matters.
        # "Said something beyond its verdict" is the whole of the rule, and it
        # is stated directly rather than approximated by a count.
        #
        # What this rule cannot do, and is not asked to do: separate a terse
        # honest approval from a lazy one. "**Overall Verdict**: APPROVE\n\nNo
        # findings" is the exact form prompt_builder.rb asks reviewers for; a
        # reply is not defective for being what we requested. Whether such a
        # reply should carry the same weight as a long one is a question about
        # the roster and the prompt, not about substance detection, and no
        # residue rule can answer it without discarding legitimate approvals.
        #
        # There is deliberately no fast path for severity markers, and the
        # residue does not keep them either: "APPROVE P0" carries no finding
        # but names the token, and either route counts it. A real finding
        # survives the residue check on its own text.

        SKIP_REASON_TRANSPORT   = 'transport'
        SKIP_REASON_INSUBSTANTIAL = 'insubstantial'
        # INV-E2's other half. A reply can be full of text and still state no
        # judgement, and such a reply is not a review of anything.
        SKIP_REASON_NO_VERDICT  = 'no_verdict'
        # A slot this system declined to run, where the dispatcher recorded no
        # reason of its own. Distinct from `transport`, which asserts a call
        # was attempted and failed.
        SKIP_REASON_NOT_DISPATCHED = 'not_dispatched'

        # Verdicts a submission may state for itself, bypassing text parsing.
        # v0.7 INV-R1: SKIP is not in the vocabulary — no word is special. A
        # row leaves the denominator through what happened to it (:status,
        # substance, no verdict), never by declaring a verdict-shaped word.
        # The declared-SKIP branch this list used to admit was unreachable
        # through shipping writers (measured in round 12) and is gone.
        PARSED_VERDICTS = %w[APPROVE REVISE REJECT].freeze
        # Phase 12 §3.7.2 / PR3 hardening: hard cap on aggregated_findings.
        # FeedbackFormatter also caps the *displayed* slice at 50, but the API
        # contract returns aggregated_findings as a separate array which would
        # otherwise grow unbounded under adversarial reviewer behavior.
        MAX_AGGREGATED_FINDINGS = 200

        # The reviewer's own verdict is the header on the first non-empty line
        # of its reply, and nowhere else.
        #
        # Three rounds tried to tell a stated header from a displayed one by
        # reading the text more cleverly, and each attempt opened a hole in the
        # direction that passes. Round 4 anchored the search to the start of a
        # line; a line inside a fence starts a line. Round 6 excluded fenced and
        # blockquoted regions; a four-backtick fence closes on the inner
        # three-backtick line, and the rest of the reply — including the real
        # verdict — went with it. The pattern is not that the rules were wrong
        # in detail. It is that "which of these headers did the reviewer mean"
        # cannot be decided by looking harder at free text, because a quotation
        # and a statement are the same characters.
        #
        # Position decides it instead, and position is something a reviewer
        # controls deliberately: a quotation cannot be the first line without
        # the reviewer choosing to open with one. The prompt asks for the
        # header there, and every reviewer in the round that found this already
        # wrote it there. What this gives up is the reply that opens with a
        # preamble: it states no verdict, and it leaves the denominator with
        # `no_verdict` beside its name. Nothing catches it further down.
        #
        # This paragraph said the opposite until round 11's review read it
        # against the code. It described the reply falling through to a word
        # heuristic — the last-resort scan round 9 deleted, whose deletion
        # `extract_verdict` records further down under "there is no fourth
        # path" — and it defended that heuristic as unable to read a
        # rejection as an approval because it checked REJECT first. Both halves
        # were wrong: the path was gone, and while it existed the danger ran the
        # other way, since checking REJECT first is exactly how it read the
        # terse approval "no blocking issues" as a rejection. A comment
        # describing a deleted mechanism is worse than no comment, because it is
        # read as a description of the guarantee and there is no guarantee
        # there.
        #
        # This pattern finds the header line and captures the whole of what
        # follows the colon on it. It does not decide anything: deciding is
        # VerdictVocabulary.stated's job, and it answers "is this value a
        # verdict" rather than "does this value mention one".
        #
        #   \A      the reply opens with it. `^` would match any line and give
        #           a quoted sample back its vote. `\s*` after it lets a
        #           transport prepend a blank line without that counting as
        #           declining to answer.
        #   (.*?)$  the rest of the line, all of it. Capturing less was round
        #           7's defect in both directions: a character class of what a
        #           verdict is made of stopped at the slash in the prompt's own
        #           "APPROVE / REJECT" and recorded a stated rejection as an
        #           approval, and written with \s — which includes the newline
        #           in Ruby — it ran past the line entirely.
        VERDICT_HEADER_RE = /\A\s*\*{0,2}Overall\s+Verdict\*{0,2}\s*:[ \t]*(.*?)[ \t]*\r?$/i

        # @param reviews [Array<Hash>] from Dispatcher, each with :status, :raw_text, :role_label, etc.
        # @param rule_str [String] e.g., "3/4 APPROVE"
        # @param min_quorum [Integer] minimum successful reviews needed
        # @return [Hash] with :reference_verdict, :convergence, :reviews, :aggregated_findings
        def self.aggregate(reviews, rule_str = '3/4 APPROVE', min_quorum: 2,
                           excluded_slots: [], escalation: nil)
          # Parsing a verdict and deciding whether the reply belongs in the
          # denominator are separate questions, and keeping them separate is
          # what stops one word ("SKIP") from meaning two things. extract_verdict
          # answers the first; INV-E2 answers the second.
          parsed = reviews.map { |r| apply_substance_rule(extract_verdict(r)) }

          successful = parsed.select { |p| p[:verdict] != 'SKIP' }
          skipped    = parsed.select { |p| p[:verdict] == 'SKIP' }
          approve_n  = successful.count { |p| p[:verdict] == 'APPROVE' }
          reject_n   = successful.count { |p| p[:verdict] == 'REJECT' }

          threshold = parse_threshold(rule_str, successful.size)

          # v0.7 INV-R2: this value is a recorded reference, not the run's
          # conclusion. The run is closed by the operator's declaration, which
          # lives outside this record (L2 / handoff); the record presents the
          # observation. The computation is unchanged — only its seat moved.
          overall = if successful.size < min_quorum
                      'INSUFFICIENT'
                    elsif reject_n > 0
                      'REVISE'
                    elsif approve_n >= threshold
                      'APPROVE'
                    else
                      'REVISE'
                    end

          # INV-R5: a seat whose transport reported a different model than the
          # slot asked for stays in the denominator — removing it would tangle
          # the detection record with a vanished vote — and the tally without
          # those seats is carried beside the main one. Both are reference
          # values.
          non_divergent = successful.reject { |p| p[:model_divergence] }

          findings = aggregate_findings(parsed)
          {
            reference_verdict: overall,
            convergence: {
              approve_count: approve_n,
              reject_count: reject_n,
              skip_count: skipped.size,
              successful_count: successful.size,
              # What this counts is observers that answered — the dispatched
              # slots plus the persona — and it never counted what the
              # configuration named, because a slot the persona took over or
              # the caller declined never reaches this method. Under the old
              # name a reader comparing it against the roster concluded slots
              # had vanished. The question it was misread as answering is
              # answered by denominator_composition, which lists every observer
              # including the ones that did not run.
              observers_reporting: reviews.size,
              threshold: threshold,
              min_quorum: min_quorum,
              rule: rule_str,
              excluding_divergent: {
                approve_count: non_divergent.count { |p| p[:verdict] == 'APPROVE' },
                reject_count: non_divergent.count { |p| p[:verdict] == 'REJECT' },
                successful_count: non_divergent.size,
                threshold: parse_threshold(rule_str, non_divergent.size)
              },
              # INV-E4: how this denominator came to be, readable from the
              # record alone. Without it a later reader cannot tell a 3/4 that
              # lost a slot to transport failure from one that lost it to an
              # empty reply or to the caller declining to review itself, and
              # the per-round ratios stop being comparable.
              denominator_composition: denominator_composition(
                parsed, excluded_slots, escalation
              )
            },
            reviews: parsed,
            aggregated_findings: cap_findings(findings)
          }
        end

        # Cap aggregated_findings to MAX_AGGREGATED_FINDINGS, preserving the
        # highest-severity entries. Excess entries are dropped with a warning
        # to STDERR (audit-visible). Severity ordering: P0 > P1 > P2 > P3 > others.
        def self.cap_findings(findings)
          return findings if findings.nil? || findings.size <= MAX_AGGREGATED_FINDINGS
          severity_order = { 'P0' => 0, 'P1' => 1, 'P2' => 2, 'P3' => 3 }
          sorted = findings.sort_by { |f| severity_order[f[:severity] || f['severity']] || 99 }
          dropped = sorted.size - MAX_AGGREGATED_FINDINGS
          warn "[multi_llm_review::Consensus] aggregated_findings capped: #{dropped} entries dropped (kept highest-severity #{MAX_AGGREGATED_FINDINGS})"
          sorted.first(MAX_AGGREGATED_FINDINGS)
        end

        # Extract verdict from a single review result.
        # Transport errors and insubstantial replies → SKIP (both leave the
        # denominator; INV-E2 treats them alike in effect but the record keeps
        # them apart via :skip_reason).
        def self.extract_verdict(review)
          if review[:status] == :skip || review[:status] == :error
            return review.merge(verdict: 'SKIP', skip_reason: transport_reason(review))
          end

          # A submission that states its verdict as a field has already
          # answered this question, and re-deriving it by searching the
          # rendered text hands the answer to whatever the text happens to
          # contain. That is not hypothetical: in round 4 of this SkillSet's
          # own review, a persona quoted `{"overall_verdict": "APPROVE", ...}`
          # inside a finding as an example of a defect, the search below found
          # it before the "**Overall Verdict**: REVISE" on line 1, and three
          # REVISE verdicts were recorded as a team APPROVE — in the direction
          # that passes.
          declared = review[:verdict].to_s.upcase
          if PARSED_VERDICTS.include?(declared)
            # The gate admits the declaration case-insensitively, so the row
            # carries the canonical form the gate admitted, not the original
            # spelling. Without the merge, a declared `approve` passes this
            # gate unaltered and then misses every `== 'APPROVE'` count
            # downstream — a row in the denominator that cannot contribute to
            # consensus, the shape INV-E2 exists to remove. Round 12 measured
            # that shape on a hand-built row and found it unreachable through
            # shipping writers, since PersonaAssembly.assemble is the only
            # writer of this field and always emits canonical case. The
            # normalization is defensive: it keeps the gate and the row from
            # drifting apart if a second writer ever appears.
            return review.merge(verdict: declared)
          end

          text = review[:raw_text].to_s

          # The header, where the reply opens and nowhere else, and only when
          # what follows the colon is a verdict rather than a sentence
          # containing one. A header further down is not read at all: it may be
          # the reviewer's, or it may be a sample it is discussing, and nothing
          # in the text says which.
          #
          # v0.7 INV-R1: when the header offered a value the vocabulary
          # refuses, the written word itself goes into the record (stated_text)
          # beside the closed no_verdict token. The reason column stays a
          # token; the word form is its own column.
          offered = nil
          if (m = text.match(VERDICT_HEADER_RE))
            offered = m[1]
            if (stated = VerdictVocabulary.stated(offered))
              return review.merge(verdict: stated)
            end
          end

          # Same, for a reply that is a JSON document rather than markdown.
          # Parsed, not pattern-matched: a JSON object quoted inside prose is
          # part of the prose, and only a reply that *is* the document states
          # a verdict through it.
          structured = parse_structured(text)
          if structured && structured['overall_verdict']
            if (stated = VerdictVocabulary.stated(structured['overall_verdict']))
              return review.merge(verdict: stated)
            end
            offered ||= structured['overall_verdict'].to_s
          end

          # There is no fourth path. A reply that did not state its verdict in
          # one of the two forms above is recorded as not having stated one.
          #
          # The last resort that used to stand here scanned the whole reply for
          # a verdict word, and every round it survived it was found to be
          # wrong in a new way: it read the word inside a negation as an
          # approval ("I cannot APPROVE this"), it read a quotation of a prior
          # round's verdict as this reviewer's, and — the one that made it
          # untenable — it read "no blocking issues", the terse approval the
          # prompt itself asks for, as a rejection, and recorded that rejection
          # against a named reviewer who had approved. Guessing produced
          # confident falsehoods about people; refusing to guess produces a
          # visible gap. INV-E4 is what makes the gap legible: the reply leaves
          # the denominator with `no_verdict` beside its name, and an operator
          # reading the record can see that a reviewer answered and was not
          # counted, which is exactly the fact.
          #
          # This is why the prompt states the three acceptable lines verbatim.
          # A roster of five reviewers whose prompts this system writes can be
          # asked to answer in a fixed form; it cannot be asked to write prose
          # that a regular expression will not misread.
          #
          # INV-E2 asks for two things of a reply that counts: that it carry a
          # verdict, and that it have substance. Nothing here carries a
          # verdict, so the reply leaves the denominator rather than being
          # counted as a REVISE nobody stated. The previous conservative REVISE
          # was worse than it looked: an opening sentence with no judgement in
          # it — the exact shape that retired one roster occupant — blocked
          # convergence on a verdict its author never gave.
          skip = { verdict: 'SKIP', skip_reason: SKIP_REASON_NO_VERDICT }
          skip[:stated_text] = offered.to_s[0, 120] unless offered.to_s.strip.empty?
          review.merge(skip)
        end

        # Why a slot that never produced a reply left the denominator. Two
        # different things arrive here: a call that broke (:error), and a slot
        # the dispatcher itself declined to run (:skip — cancelled before
        # start, or dropped when the dispatch window closed). Recording both as
        # `transport` said a reviewer was unreachable when in fact this system
        # chose not to reach it, and a round diagnosed from the record then
        # looks like an external outage instead of a timeout budget that is too
        # small.
        #
        # The dispatcher already writes the specific reason into the entry, so
        # nothing new is invented here — it is carried through instead of
        # being flattened.
        # The dispatcher names its own reasons as tokens (`dispatch_timeout`,
        # `cancelled_before_start`), and only a token is carried through. What
        # arrives here is not always one: an `error` field is free-form, and a
        # message that is a sentence, a traceback, or reviewer-controlled text
        # would land in a record field the runbook documents as a small
        # vocabulary. The shape is the rule rather than a length, because what
        # makes a reason legible is that it names a case, not that it is short.
        DECLARED_REASON_RE = /\A[a-z][a-z0-9_]{0,39}\z/

        def self.transport_reason(review)
          return SKIP_REASON_TRANSPORT unless review[:status] == :skip

          err = review[:error]
          declared = (err['message'] if err.is_a?(Hash)).to_s.strip
          DECLARED_REASON_RE.match?(declared) ? declared : SKIP_REASON_NOT_DISPATCHED
        end


        # A duplicated key makes a JSON document say two things under one name,
        # and JSON.parse keeps whichever came last — silently. A reply whose
        # `overall_verdict` appears twice would then state whichever verdict
        # was written second, which is not a statement anyone can be held to.
        # Raised at insertion so the whole document is refused, at any depth:
        # fail-closed, like every other reading rule here (R12 P1).
        class DuplicateKeyError < StandardError; end

        class DuplicateRefusingHash < Hash
          def []=(key, value)
            raise DuplicateKeyError, "duplicate key: #{key}" if key?(key)

            super
          end
        end

        # A reply that is itself a JSON document, or nil when it is not.
        # Deliberately strict: no scanning for an object embedded in prose,
        # because prose quoting an object is prose — and no document with a
        # repeated key, because such a document does not state one thing.
        def self.parse_structured(text)
          stripped = text.to_s.strip
          return nil unless stripped.start_with?('{')

          parsed = JSON.parse(stripped, object_class: DuplicateRefusingHash)
          # The TOP LEVEL is converted to a plain Hash; nested values keep the
          # refusing subclass. That is enough for every current reader — only
          # overall_verdict is read, and structural_substance reads without
          # writing — but writing into a nested value would raise. A consumer
          # that needs to mutate nested values must deep-convert first.
          parsed.is_a?(Hash) ? {}.merge(parsed) : nil
        rescue JSON::ParserError, DuplicateKeyError
          nil
        end

        # INV-E2, applied after the verdict is parsed. A transport failure is
        # already SKIP and stays as it is; a reply that parsed fine but says
        # nothing beyond its verdict leaves the denominator too, under its own
        # reason so the record keeps the two apart.
        def self.apply_substance_rule(parsed)
          return parsed if parsed[:verdict] == 'SKIP'

          # A structured submission carries its own answer to this question:
          # what makes it substantive is whether its parts say anything, not
          # how the text rendered from them happens to read. Free text has no
          # structure to appeal to, so it is inspected instead.
          decided = parsed[:substantive]
          decided = structural_substance(parsed[:raw_text]) if decided.nil?

          return parsed if decided == true
          return parsed.merge(verdict: 'SKIP', skip_reason: SKIP_REASON_INSUBSTANTIAL) if decided == false

          return parsed if substantive?(parsed[:raw_text])

          parsed.merge(verdict: 'SKIP', skip_reason: SKIP_REASON_INSUBSTANTIAL)
        end

        # INV-E2 requires the substance decision to reach every observer alike.
        # A reply that arrives as a JSON document cannot be judged by the
        # residue of its text, because that residue counts the document's own
        # key names as content: {"overall_verdict": "APPROVE", "findings": [],
        # "reasoning": ""} leaves "overall_verdict findings reasoning", which
        # is three words of schema and no review.
        #
        # So the document is asked the same question the residue rule asks of
        # prose — did anything get said beyond the verdict — of the words it
        # carries rather than of the words it is built from. Which keys those
        # words live under is not asked, and asking it was the defect this
        # replaces: naming `reasoning` and `issue` as the body of a foreign
        # reply threw away a REJECT whose findings used `description`, and
        # every other key a reviewer might reasonably choose. A schema this
        # system authors may be named (PersonaAssembly does, for the persona
        # submission it validates); a schema an external reviewer chose may
        # not be guessed at.
        #
        # Returns nil for anything that is not such a document, leaving it to
        # the residue rule.
        def self.structural_substance(text)
          doc = parse_structured(text)
          return nil unless doc && doc['overall_verdict']

          words_in(doc.reject { |k, _| k.to_s == 'overall_verdict' })
            .any? { |s| !residue(s).empty? }
        end

        # Every string a document carries, at any depth. Only strings: a
        # review is said in words, and a number or a boolean under some key is
        # metadata about the review rather than part of it.
        def self.words_in(node)
          case node
          when Hash  then node.values.flat_map { |v| words_in(v) }
          when Array then node.flat_map { |v| words_in(v) }
          when String then [node]
          else []
          end
        end

        # A reply is substantive when anything at all remains once its verdict
        # is removed. Of the whole reply, including anything it quoted: a
        # reviewer citing the offending code instead of describing it in prose
        # has said something about the artifact, and a rule that discarded
        # fenced material dropped exactly those replies — findings and all,
        # since a SKIP row's findings are never aggregated.
        def self.substantive?(text)
          stripped = text.to_s.strip
          return false if stripped.empty?

          !residue(stripped).empty?
        end

        # What is left of a piece of text once the verdict it states is taken
        # out of it. Only alphanumerics are kept, which under Ruby's
        # Unicode-aware [[:alnum:]] includes every script a reviewer might
        # answer in, so the rule does not favour one language over another.
        # Punctuation and emphasis go too, so that "APPROVE!!!" and
        # "**APPROVE**" reduce to the same empty residue as "APPROVE".
        #
        # A severity tag goes out with the verdict, and for the same reason:
        # "P0" names how bad something is and never what it is, so a reply
        # consisting of a verdict and a tag has still said nothing about the
        # artifact. This is what the removal of the severity fast path was
        # after and did not reach — "APPROVE P0" kept counting, because the
        # tag it named survived in the residue. A finding survives on its own
        # text, which is what it always had to do.
        SEVERITY_TAG = /\bP[0-3]\b/i

        def self.residue(text)
          VerdictVocabulary
            .strip(text.to_s.gsub(/\*{0,2}Overall\s+Verdict\*{0,2}\s*:?/i, ' '))
            .gsub(SEVERITY_TAG, ' ')
            .gsub(/[^[:alnum:]]+/, ' ')
            .strip
        end

        # INV-E4. Every observer that could have counted appears here exactly
        # once, whether it counted or not, with the reason it did not.
        # v0.7 INV-R3/R4: the unit of this list is the seat, and each row says
        # so (`seat: true` — one boolean column, so that if row-level records
        # are ever interleaved here, the seat column stays reconstructible).
        def self.denominator_composition(parsed, excluded_slots, escalation)
          counted = parsed.map do |p|
            {
              role_label: p[:role_label],
              model: p[:model],
              model_declared: p[:model_declared],
              # Naming the flag without naming the value told a reader that the
              # two disagreed and never told them what answered.
              model_observed: p[:model_observed],
              model_source: p[:model_source] || 'declared',
              # INV-P1. Without this a persona row — a declaration standing in
              # for an observer — is field-for-field identical to a dispatched
              # slot whose transport could not report its model, and a reader
              # takes the one for the other. `model_source: declared` does not
              # separate them: an executed slot on a silent transport carries
              # exactly that value too.
              synthetic: p[:synthetic] || false,
              seat: true,
              counted: p[:verdict] != 'SKIP',
              # Every route to SKIP now names its own reason, so there is
              # nothing left to default to. A row that somehow arrives without
              # one omits the field — silence, which a reader can see, rather
              # than `transport`, which a reader cannot tell from a fact.
              reason: (p[:skip_reason] if p[:verdict] == 'SKIP'),
              # INV-R1: the word a final submission offered as its verdict and
              # the vocabulary refused. The reason stays a closed token; the
              # written form is its own column.
              stated_text: p[:stated_text],
              # INV-R7: how the artifact reached this seat, when distribution
              # was an act the system performed for it.
              artifact_delivery: p[:artifact_delivery],
              model_divergence: p[:model_divergence]
            }.compact
          end

          not_dispatched = (excluded_slots || []).map do |slot|
            {
              role_label: slot[:role_label] || slot['role_label'],
              model: slot[:model] || slot['model'],
              seat: true,
              counted: false,
              reason: slot[:reason] || slot['reason'],
              # INV-R7: an undelivered seat's delivery form is a per-seat
              # attribute of the record, not something to dig out of the
              # reason string.
              artifact_delivery: slot[:artifact_delivery] || slot['artifact_delivery'],
              replaced_by: slot[:replaced_by] || slot['replaced_by']
            }.compact
          end

          { observers: counted + not_dispatched,
            escalation: normalize_escalation(escalation) }
        end

        # INV-E4 asks the record to say whether extra observers were asked for,
        # and pending state written before escalation existed carries no such
        # field. A missing field does not say "no" — it says nothing — so that
        # one case is answered, and it is answered truthfully: a version with
        # no escalation to offer cannot have been asked for it.
        #
        # A record that exists speaks for itself, including where it is partial.
        # Filling a partial record was the previous behaviour and it invented:
        # given `{escalated: true, slots: [...]}` from an intermediate version
        # it wrote `requested: false` beside `escalated: true`, which the
        # producing code cannot emit — escalation is only ever escalated
        # because it was requested. Silence about a key is legible to a reader;
        # a value asserted where none was recorded is not, and it is worse than
        # the omission it replaced.
        #
        # Built fresh rather than duplicated from a frozen constant: `freeze` is
        # shallow, so a caller appending to `slots` on one returned record would
        # have reached every later one through the shared array.
        def self.escalation_absent
          { 'requested' => false, 'escalated' => false,
            'slots' => [], 'dispatched' => [] }
        end

        def self.normalize_escalation(escalation)
          return escalation_absent unless escalation.is_a?(Hash)

          escalation.transform_keys(&:to_s)
        end

        # normalize_verdict/1 was deleted here. It answered "what verdict does
        # this text mention", and both of its callers now ask "is this value a
        # verdict" instead. Leaving it in place would leave the inference one
        # call away from whoever next needs a verdict out of some text.
        # PersonaAssembly deleted its own in round 14: the persona verdict
        # field is admitted by `stated` at validate!, whole-value, and a value
        # that is not a verdict is refused back to the caller rather than
        # tolerated — restating our own wording is cheap in a submission the
        # caller authors, where guessing at somebody else's is not.

        # Ratio-based threshold applied to successful count.
        # "3/4 APPROVE" with 2 successful → ceil(2 * 0.75) = 2
        def self.parse_threshold(rule_str, successful_count)
          return 1 if successful_count <= 0

          if rule_str =~ %r{(\d+)\s*/\s*(\d+)}
            ratio = $1.to_f / $2.to_f
            (successful_count * ratio).ceil
          else
            (successful_count * 0.75).ceil
          end
        end

        # Collect severity-tagged findings from all successful reviews.
        # Deduplicates by first 80 chars (case-insensitive).
        def self.aggregate_findings(parsed_verdicts)
          all_findings = []
          parsed_verdicts.each do |r|
            next if r[:verdict] == 'SKIP'
            text = r[:raw_text].to_s

            # Extract "P0: ...", "P1-1: ...", "**P0**:", etc.
            text.scan(/\*{0,2}(P[0-3])\*{0,2}[-\s]*\d*[.:]\s*(.+?)(?=\n\s*\n|\n\s*\*{0,2}P[0-3]|\z)/mi) do |sev, issue|
              all_findings << {
                severity: sev.upcase,
                issue: issue.strip[0..200],
                cited_by: [r[:role_label]]
              }
            end
          end

          # Deduplicate by first 80 chars
          grouped = all_findings.group_by { |f| f[:issue][0..79].downcase }
          grouped.map do |_key, findings|
            {
              severity: findings.map { |f| f[:severity] }.min, # P0 < P1 < P2
              issue: findings.first[:issue],
              cited_by: findings.flat_map { |f| f[:cited_by] }.uniq
            }
          end.sort_by { |f| f[:severity] }
        end
      end
    end
  end
end
