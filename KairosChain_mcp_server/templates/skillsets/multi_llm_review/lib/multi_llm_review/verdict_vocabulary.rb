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
      # observer that happens to relay them, so it is answered once — since
      # round 13, literally once, in WORDS below. Two hand-kept copies of the
      # word list were tried first, held equal by an equivalence test; round 11
      # found them apart on 8 of 30 forms, and round 12 found the test blind to
      # the single-token edits it was kept to catch. A list written twice is a
      # divergence with a delay on it.
      #
      # Verdict *reading* is `stated` and nothing else. The word-search
      # patterns below serve `strip` — the substance measurement INV-E2 asks
      # for — and are consulted by nothing that decides what a value's verdict
      # is. The last reader that decided verdicts by word-search, the persona
      # path's normalize_verdict, was retired in round 13: round 12 measured it
      # finding APPROVED inside "NOT APPROVED", and reading a verdict behind an
      # invisible Unicode space (U+00A0, U+3000, U+2028, …) that `stated`
      # refuses — 48 of 48 probed pairs read differently by the two paths,
      # each difference moving a vote (probe recorded in the round-12 L2
      # handoff). Round 13 replaced the search with a logged REVISE fallback,
      # and its review measured that too moving votes — a decorated rejection
      # became a non-rejecting row. Since round 14 the persona field is
      # admitted by `stated` at validation and a non-verdict is refused back
      # to the caller, so a value that is not a verdict is never counted, on
      # either path, as anything.
      module VerdictVocabulary
        # v0.7 INV-R1: the vocabulary a reviewer is told it may write and the
        # vocabulary this system reads are one and the same, and it consists of
        # the three canonical words and their tense/inflection forms — nothing
        # else. The alias list that used to live here (LGTM, PASS, FAIL,
        # BLOCK, NO-GO, NACK, DENY, VETO, ACCEPT, SHIP IT, CHANGES REQUIRED,
        # NEEDS WORK, REWORK) is gone, and with it the compound-word separator
        # grammar: no remaining form spans more than one token. The prompt has
        # always stated the three canonical lines verbatim; the acceptance side
        # now promises nothing wider. This reduction ships in the same change
        # as the reference-value demotion of the ratio (INV-R1×R2 are mutual
        # conditions): under a gate, a word outside the vocabulary silently
        # cost a vote; as a reference value, it lands in the record as
        # "no_verdict" with the written word beside it (stated_text).
        #
        # These are strings, and the mutation sweep that measures this file
        # mutates regexp bodies and not strings — moving the words here took
        # them out of its reach. That cost is paid deliberately and where it
        # is cheapest: a word dropped or misspelt here is held by the
        # per-form assertions in the test suite. What the sweep must keep
        # seeing — the anchors and the padding, where rounds 9 through 12
        # fought — stays inside the regexp literals below.
        WORDS = {
          'REJECT' => ['REJECT(?:ED|S|ING)?'].freeze,
          'REVISE' => ['REVIS(?:E|ED|ES|ING)'].freeze,
          'APPROVE' => ['APPROV(?:E|ED|ES|ING)'].freeze
        }.freeze

        def self.alternation(canonical)
          WORDS.fetch(canonical).join('|')
        end
        private_class_method :alternation

        # Does a piece of prose mention a judgement word. These serve `strip`
        # and through it the residue rule; they decide no verdict.
        APPROVE = /\b(?:#{alternation('APPROVE')})\b/i
        REJECT  = /\b(?:#{alternation('REJECT')})\b/i
        REVISE  = /\b(?:#{alternation('REVISE')})\b/i

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
        # "APPROVE (no changes required)" is no longer read. What happens then
        # depends on who is asking. An external reply is final, so that
        # reviewer leaves the denominator with `no_verdict` beside its name,
        # visible in the record, where being told the opposite of what it said
        # is not. A persona submission is authored by the caller and can be
        # restated, so PersonaAssembly refuses it at validation and the
        # corrected submission carries the vote.
        #
        # Because no string matches two of these, precedence does not arise
        # here. That is a property worth having: the order of these three lines
        # cannot be got wrong.
        #
        # The padding a verdict may wear is declared here rather than removed
        # before matching. The previous version normalised first — strip, drop
        # leading and trailing asterisks, strip again — and then asked for an
        # exact match. Normalising has no end: each round found another
        # character to take off, and the second strip took the newline off
        # `"**\nAPPROVE"`, so a two-line value arrived at the anchored pattern
        # as a one-line verdict and was read as APPROVE. The anchor was doing
        # its job on a value that was no longer the value. Declaring the shape
        # instead keeps the tolerance finite and visible: whitespace outside,
        # asterisks around, and between the asterisks and the word nothing but
        # spaces and tabs. `[ \t]` rather than `\s` is the entire mechanism —
        # it is what stops content on another line from being padding.
        #
        # What this refuses is worth stating, because refusing is the point:
        # "APPROVE." and "APPROVE!" are not verdicts, nor is "APPROVE APPROVE",
        # nor a full-width "ＡＰＰＲＯＶＥ". On the external path each leaves
        # the denominator with `no_verdict` beside the reviewer's name, which
        # the prompt says will happen; on the persona path each is refused at
        # validation and restated. Being told the opposite of what a reviewer
        # said is the failure this trade buys off.
        #
        # The padding is repeated on each line rather than named once and
        # interpolated. That is deliberate and it cost something: a first
        # version wrote `PAD_OPEN = '\A\s*\**[ \t]*'` and interpolated it, which
        # reads better and moved the anchors out of every regexp literal and
        # into a string. The mutation sweep that measures this file dropped from
        # 33 mutants to 20 in the same commit, because it mutates regexp bodies
        # and not string literals — the invariant had become invisible to the
        # instrument that had just caught it being broken. A rule that cannot be
        # mutated cannot be shown to be held. (The words interpolate from WORDS
        # for the opposite reason: their failure mode is a divergence between
        # two copies, which no sweep of one copy at a time can see, and which
        # explicit per-word assertions hold instead.)
        #
        EXACT = {
          'REJECT' => /\A\s*\**[ \t]*(?:#{alternation('REJECT')})[ \t]*\**\s*\z/i,
          'REVISE' => /\A\s*\**[ \t]*(?:#{alternation('REVISE')})[ \t]*\**\s*\z/i,
          'APPROVE' => /\A\s*\**[ \t]*(?:#{alternation('APPROVE')})[ \t]*\**\s*\z/i
        }.freeze

        module_function

        # The verdict a value *is*, or nil when it is not one. The value is not
        # altered on the way in: whether its padding is allowed is part of the
        # question EXACT answers.
        def stated(value)
          s = value.to_s
          EXACT.each { |canonical, re| return canonical if re.match?(s) }
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
