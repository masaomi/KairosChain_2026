---
name: account_manager_guide
description: How the account_manager ledger holds together — what a posting is, what a close freezes, why a sealed year is corrected in equity, and which decisions were made in code because prose could not settle them.
version: 0.1.0
layer: L1
author: Masaomi Hatakeyama
created: 2026-08-05
---

# account_manager — the working guide

This is the knowledge an operator or an agent needs to use the ledger correctly and to change it
without breaking it. It is not the design draft: the draft carries five defects this
implementation fixes, and where they differ, this file and the code are right.

## 1. What the system is

A double-entry ledger for one person with two purses — a sole proprietorship whose owner also buys
groceries. The books must separate for tax; the money does not separate at all. The owner draws
from the business and pays business costs from a private card, and a design that models these as
two unrelated datasets forces the owner to reconcile by hand, which is the work the tool exists to
remove.

It is not a tax filing engine and it knows no country's rules. It produces the figures and the
evidence a filing needs; a human or an accountant files.

## 2. The four record types, and which ones are figures

| Record | Counted by a report? | Can it change? |
|---|---|---|
| **posting** | yes, always | only while its month is open |
| **proposal** | never | until decided; a discard can be undone |
| **closing record** | no — it *freezes* figures | append-only; a re-open appends, it does not erase |
| **evidence** | no | never removed in v0.1; there is no delete command |

The line between proposal and posting is the system's one real boundary. Everything inferential —
reading an amount off a photograph, parsing a typed sentence, guessing an account, proposing that
two rows are one transaction — happens on the proposal side, where it costs a correction. Only an
explicit operator call moves a proposal across.

## 3. Ranges, and why there is no range table

A **range** is one calendar month of transaction dates. It is derived from the date, not declared:

```
transaction_date 2026-03-14 ──▶ range "2026-03"
```

Because ranges are derived, they cannot overlap and cannot leave a gap, so the refusals that would
have policed those conditions do not exist. The design draft declared ranges as spans and then had
to forbid overlaps — which made the annual close, written as closing a *year* span, permanently
refused after any monthly close. Deriving the range deletes the rule and the defect together.

A range is in one of three states, folded from the append-only closing log:

```
open ──close──▶ closed ──reopen──▶ open
                   │
                   └──seal (annual close)──▶ sealed   [terminal]
```

## 4. The two dates

| | transaction date | settlement date |
|---|---|---|
| Means | the day it happened | the day money moved |
| Places the posting in a range | **yes, alone** | never |
| Used by P&L and balance sheet | yes | never |
| Used by reconciliation | no | **only this** |
| Absent when | never | no money moved |

Three reviewers independently named the ambiguity between these two the worst defect in the design.
The rule is one sentence: transaction date decides membership, settlement date decides
reconciliation, and neither ever does the other's job.

A posting for which no money moved carries **no** settlement date, and the tool refuses one. It can
tell because the chart marks bank, cash and card accounts with `cash: true`. Without that flag the
refusal would be unimplementable — which is what the design draft left it as.

## 5. Crossing between books

Give the ledger two lines that cross the books and it stores four:

```
"toner 42.30, business expense, paid on the private card"

  you give:   Dr expense_supplies  42.30  [business]
              Cr private_card      42.30  [private]

  it stores:  Dr expense_supplies  42.30  [business]
              Cr owner_account     42.30  [business]   ← added
              Dr business_claim    42.30  [private]    ← added
              Cr private_card      42.30  [private]

  business balances alone.  private balances alone.
```

The pair is configuration (`crossing:`), and a ledger for an entity that must account separately
sets `crossing: none` and gets a refusal instead.

**The order matters and is load-bearing**: the posting is checked for overall balance *first*, and
crossed *second*. A crossing redistributes a residue between books; it must never absorb one. If it
ran first, a posting simply wrong by ten would land as a crossing of ten and the balance invariant
would hold vacuously. (This was found by a test, not by reading.)

## 6. The annual close

```
annual_close(2026)
   │
   ├─ 1. post the closing entry, dated 2026-12-31
   │       every income and expense balance ──▶ retained_earnings
   │       (this is the ONE posting allowed into a period-closed range)
   │
   └─ 2. seal every month of the fiscal year
           2026-01 … 2026-12  ──▶ sealed, terminal
```

Post first, seal second. Sealing first would leave the entry with nowhere to go.

**Operator decision, 2026-08-05:** the closing entry may be posted into a month that is already
period-closed, and the annual close is the only operation that may do this. In ordinary use every
month is closed before the year is, so refusing would make the annual close unreachable — the exact
defect this ordering exists to fix. The seal record captures each range's final figures, so the
change is visible rather than hidden.

Without the closing entry, year two's balance sheet is short by year one's result on the first day
of January, and the balance sheet and the profit-and-loss stop agreeing.

The profit-and-loss **excludes** closing entries. They transfer a result rather than produce one,
and counting them would make every closed year read as zero.

## 7. Correcting an error

| When the error is found | What to do |
|---|---|
| Month still open | Edit the posting in place |
| Month closed, year open | Re-open the month, edit, close it again. The superseded closing record stays |
| Year sealed | One **new** posting in an open month, against the prior-period-adjustment account |

The sealed-year correction never touches an income or expense account, and the tool refuses one
that tries. Those balances are already inside retained earnings; restating them would drop last
year's error into this year's profit — the precise outcome the correction exists to prevent. One
side is `prior_period_adjustment` (type `equity`); the other is the balance-sheet account that was
actually misstated — the bank, a payable. No money moves, so there is no settlement date.

## 8. Import keys

A key is the pair **(profile, reference)**, never the reference alone. Two banks both numbering
their bookings from 1 would otherwise collide and the second bank's row would be taken for the
first's.

- A re-import whose key is present and whose content **matches** → reported as already present.
- A re-import whose key is present and whose content **differs** → reported as *changed*, with both
  rows, and nothing is written. A bank revising a provisional amount must not leave the stale
  figure standing because the tool recognised the key and looked no further.
- A source with no reference field → keyed by batch and position, and every re-import is reported
  as undeduplicable. A line dictated twice is proposed twice, on purpose.
- A discarded proposal is **kept**, which is what stops the next re-import proposing it again, and
  the discard can be undone.

## 9. Configuration is the jurisdiction

No tool's code holds an account name, a tax rate or a country's rule. Adding a country means
writing one YAML file. A household-only setup is the same file with one book, `crossing: none` and
no tax labels.

The loader has exactly one refusal, with a closed list of causes: an account removed or retyped
while postings reference it; a required named account missing or wrongly typed; a currency changed
while postings exist; an import profile naming a column it does not map. It reports every cause at
once. Renaming an account is always safe — the chart is editable in use, and a close stores the
chart it was taken against, so editing never restates a closed period.

## 10. What is deliberately absent

- **More than one currency.** With it went conversion, rates, revaluation and every foreign
  account. A foreign payment is recorded at what the account was charged; the original amount is a
  note nothing parses. Multi-currency is a separate design against a ledger that already works.
- **Value-added-tax derivation.** A registered entity needs the split at posting time, because
  input tax is a balance-sheet claim and the expense must be recorded net. Registration is a
  redesign. Labels here are opaque: reports group by them and stop.
- **Deleting evidence,** and with it any retention setting. A tool that cannot delete cannot delete
  wrongly.
- **A "cash movement" report.** Reconciliation covers the need; the scope list named a report no
  tool ever produced.
- **A second ledger.** Only the addressing is built.

## 11. Open questions, carried

1. How opening balances are represented — an ordinary posting in a month later closed, or a record
   type of their own. The spreadsheet migration makes this concrete.
2. Whether closing-record detection should anchor each record's hash on the attestation chain.
   Records carry a hash today; nothing external verifies the sequence.
3. Whether the private book should be excluded from report output by default, so a business report
   cannot carry household lines into an accountant's hands.
4. Whether the store should keep an edit history for open-range postings. Today an open-range edit
   overwrites, so the correction history exists only for months that were closed and re-opened.
5. Whether a posting may have more than one settlement line. Reconciliation currently assumes not.
6. Whether a ledger migrated mid-year should mark its first annual close as covering a partial
   year, so a ten-month result is not read as a twelve-month one.
