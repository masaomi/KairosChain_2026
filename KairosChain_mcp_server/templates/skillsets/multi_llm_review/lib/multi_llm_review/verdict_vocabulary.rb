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
        # One word list, two grammars. A compound word carries <SEP> where its
        # parts join (<SEP-> where a hyphen is also conventional), and each
        # pattern below substitutes the separator class it is prepared to
        # defend: `[_\s]*` when searching prose, where a line break between
        # SHIP and IT is prose being prose; `[ \t_]*` when judging a whole
        # value, where a line break means two statements.
        #
        # These are strings, and the mutation sweep that measures this file
        # mutates regexp bodies and not strings — moving the words here took
        # them out of its reach. That cost is paid deliberately and where it
        # is cheapest: a word dropped or misspelt here is held by the
        # per-alias assertions in the test suite, which state every word in
        # every accepted separator. What the sweep must keep seeing — the
        # anchors and the padding, where rounds 9 through 12 fought — stays
        # inside the regexp literals below.
        WORDS = {
          'REJECT' => ['REJECT(?:ED)?', 'FAIL(?:ED|URE)?', 'BLOCK(?:ED|ER|ING)?',
                       'NO<SEP->GO', 'NACK', 'DENY', 'VETO'].freeze,
          'REVISE' => ['REVISE[DS]?', 'CHANGES?<SEP>REQUIRED',
                       'NEEDS?<SEP>(?:WORK|REVISION|CHANGES?)', 'REWORK'].freeze,
          'APPROVE' => ['APPROVE[DS]?', 'PASS(?:ED)?', 'ACCEPT(?:ED)?', 'LGTM',
                        'SHIP<SEP>IT'].freeze
        }.freeze

        def self.alternation(canonical, sep:, hyphen_sep:)
          WORDS.fetch(canonical)
               .map { |w| w.gsub('<SEP->', hyphen_sep).gsub('<SEP>', sep) }
               .join('|')
        end
        private_class_method :alternation

        # Does a piece of prose mention a judgement word. These serve `strip`
        # and through it the residue rule; they decide no verdict.
        APPROVE = /\b(?:#{alternation('APPROVE', sep: '[_\s]*', hyphen_sep: '[_\s\-]*')})\b/i
        REJECT  = /\b(?:#{alternation('REJECT',  sep: '[_\s]*', hyphen_sep: '[_\s\-]*')})\b/i
        REVISE  = /\b(?:#{alternation('REVISE',  sep: '[_\s]*', hyphen_sep: '[_\s\-]*')})\b/i

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
        # `[ \t_]` and not `[_\s]` inside a compound word: the separator inside
        # a verdict is subject to the same rule as the padding around it,
        # because `SHIP\nIT` is two lines and two lines are two statements. The
        # search side uses `\s` there — it is searching prose either way — and
        # that is the one place the two grammars are allowed to disagree.
        EXACT = {
          'REJECT' => /\A\s*\**[ \t]*(?:#{alternation('REJECT', sep: '[ \t_]*', hyphen_sep: '[ \t_\-]*')})[ \t]*\**\s*\z/i,
          'REVISE' => /\A\s*\**[ \t]*(?:#{alternation('REVISE', sep: '[ \t_]*', hyphen_sep: '[ \t_\-]*')})[ \t]*\**\s*\z/i,
          'APPROVE' => /\A\s*\**[ \t]*(?:#{alternation('APPROVE', sep: '[ \t_]*', hyphen_sep: '[ \t_\-]*')})[ \t]*\**\s*\z/i
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
