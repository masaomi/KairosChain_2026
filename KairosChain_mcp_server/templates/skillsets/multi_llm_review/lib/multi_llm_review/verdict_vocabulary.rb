# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # The words a reviewer may use to state a judgement, in one place.
      #
      # There were two vocabularies before this: Consensus recognised
      # APPROVE/PASS/ACCEPT, REJECT/FAIL/BLOCK, REVISE/CHANGES REQUIRED, and
      # PersonaAssembly recognised those plus LGTM, SHIP IT, NO-GO, NACK, DENY,
      # VETO, REWORK. The same reply then meant different things depending on
      # which observer carried it: a persona answering NO-GO was recorded as a
      # REJECT, and an external slot answering NO-GO stated no judgement at all
      # and left the denominator under `no_verdict`. Both halves of that
      # divergence remove a vote, and the vote removed is a blocking one.
      #
      # Which words belong here is a question about reviewers, not about the
      # observer that happens to relay them, so it is answered once.
      module VerdictVocabulary
        APPROVE = /\b(?:APPROVE[DS]?|PASS(?:ED)?|ACCEPT(?:ED)?|LGTM|SHIP[_\s]*IT)\b/i
        REJECT  = /\b(?:REJECT(?:ED)?|FAIL(?:ED|URE)?|BLOCK(?:ED|ER|ING)?|NO[_\s\-]*GO|NACK|DENY|VETO)\b/i
        REVISE  = /\b(?:REVISE[DS]?|CHANGES?[_\s]*REQUIRED|NEEDS?[_\s]*(?:WORK|REVISION|CHANGES?)|REWORK)\b/i

        ALL = [REJECT, REVISE, APPROVE].freeze

        # The same words, matched against a whole value rather than found
        # inside one.
        #
        # Finding a verdict word inside text is inference, and inference is
        # what rounds 4, 6 and 8 each broke in a new way. It cannot see
        # negation ("NOT APPROVED" contains APPROVE and nothing else), it
        # cannot tell a menu from a choice (the prompt's own template line,
        # "APPROVE / REJECT", echoed back), and it cannot tell a statement from
        # a quotation. None of those are adversarial inputs; they are ordinary
        # sentences that happen to contain the word.
        #
        # Matching the whole value asks a different question — "is this value a
        # verdict" rather than "does this value mention one" — and that
        # question has an answer. What it costs is the decorated verdict:
        # "APPROVE (no changes required)" is no longer read. That reviewer
        # leaves the denominator with `no_verdict` beside its name, which is
        # visible in the record, where being told the opposite of what it said
        # is not.
        #
        # Because no string matches two of these, precedence does not arise
        # here. That is a property worth having: the order of these three lines
        # cannot be got wrong.
        EXACT = {
          'REJECT' => /\A(?:REJECT(?:ED)?|FAIL(?:ED|URE)?|BLOCK(?:ED|ER)?|NO[_ \-]?GO|NACK|DENY|VETO)\z/i,
          'REVISE' => /\A(?:REVISE[DS]?|CHANGES?[_ ]?REQUIRED|NEEDS?[_ ]?(?:WORK|REVISION|CHANGES?)|REWORK)\z/i,
          'APPROVE' => /\A(?:APPROVE[DS]?|PASS(?:ED)?|ACCEPT(?:ED)?|LGTM|SHIP[_ ]?IT)\z/i
        }.freeze

        module_function

        # The verdict a value *is*, or nil when it is not one. Surrounding
        # emphasis and whitespace are not part of the value; anything else is.
        def stated(value)
          bare = value.to_s.strip.gsub(/\A\*+|\*+\z/, '').strip
          return nil if bare.empty?

          EXACT.each { |canonical, re| return canonical if re.match?(bare) }
          nil
        end

        # The judgement a piece of text states, or nil when it states none.
        #
        # Precedence is REJECT, then REVISE, then APPROVE, and it is the same
        # precedence PersonaAssembly uses to combine several personas into one
        # verdict. A reply carrying more than one of these words has not said
        # two things; it has qualified one, and the qualification is what a
        # reader of the record needs to survive. Deciding it the other way
        # around ("approve, with changes required" → APPROVE) discards the
        # qualification in the direction that passes.
        def classify(text)
          s = text.to_s
          return 'REJECT'  if s.match?(REJECT)
          return 'REVISE'  if s.match?(REVISE)
          return 'APPROVE' if s.match?(APPROVE)
          nil
        end

        # The text with every judgement word removed. What is left is what the
        # reviewer said in addition to stating its judgement — the quantity
        # INV-E2 asks about.
        def strip(text)
          ALL.reduce(text.to_s) { |acc, re| acc.gsub(re, ' ') }
        end
      end
    end
  end
end
