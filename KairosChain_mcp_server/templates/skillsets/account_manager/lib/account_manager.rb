# frozen_string_literal: true

# account_manager SkillSet — a jurisdiction-neutral double-entry ledger for a
# sole proprietorship that is also a household cash book.
#
# Invariant wiring (design v1.0, corrected by the 2026-08-05 handoff §4 and by
# operator decision 12 of the same day):
# - INV-AM-1: every stored posting is a balanced journal entry.
# - INV-AM-2: each book balances alone; crossings pass through the owner-draw pair.
# - INV-AM-3: one currency; a foreign amount is an unparsed note.
# - INV-AM-4: evidence is identified by content and never removed in v0.1.
# - INV-AM-5: ranges partition by transaction date; a close freezes one; an
#   annual close posts the year's closing entry, then seals the year's ranges.
# - INV-AM-6: jurisdiction is data, validated whole, refused with one raise.
# - INV-AM-7: nothing becomes a figure without the operator; no tool infers.
# - INV-AM-8: a posting's tax label is copied onto the line at posting time.
# - INV-AM-9: a key is (profile, reference); a changed re-import is reported.
# - INV-AM-10: transaction date places a posting; settlement date is
#   reconciliation's alone, and is absent when no money moved.

require 'account_manager/money'
require 'account_manager/config'
require 'account_manager/store'
require 'account_manager/importer'
require 'account_manager/report'
require 'account_manager/tool_helpers'

module AccountManager
  VERSION = '0.1.0'
end
