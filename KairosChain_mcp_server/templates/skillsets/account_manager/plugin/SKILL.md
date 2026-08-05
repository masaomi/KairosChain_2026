---
name: account_manager
description: >
  Double-entry bookkeeping for a one-person business that is also a household. Use when recording
  an expense or an income, importing a bank statement, attaching a receipt, closing a month or a
  year, or producing a profit-and-loss, a balance sheet or a reconciliation. 帳簿、経費、領収書、
  口座の照合、月次締め、年次締め、決算書。
---

# account_manager

A ledger for one person with two purses: a sole proprietorship whose owner also buys groceries.
The books separate for tax; the money does not. It knows no country's rules — the chart of
accounts, the tax labels, the fiscal year and the import profiles are all configuration.

## The one thing to understand first

```
  a receipt, a CSV row, a sentence
              │
              ▼
        PROPOSAL ──── visible to queries
              │       counted by NO report
              │       carries who authored it
              │
    the operator posts it  ◀── the only way across
              │
              ▼
         POSTING ──── balanced, both books balance alone
              │       counted by every report
              ▼
      P&L · balance sheet · reconciliation
```

Nothing crosses that line without an explicit operator call. An agent that misreads a receipt costs
a correction, never a wrong figure.

## The six tools

| Tool | Use it for |
|---|---|
| `am_entry` | post; edit or note a posting whose month is open; correct a sealed year; record, post, discard or un-discard a proposal; confirm a join |
| `am_import` | CSV rows → proposals, keyed by (profile, reference) |
| `am_query` | find postings, proposals, or the state of each month |
| `am_report` | profit and loss, balance sheet, reconciliation — markdown, CSV or figures |
| `am_receipt` | copy evidence in under its content hash, bind it, list what has none |
| `am_close` | close a month, re-open one, take the annual close |

## The rules that will surprise you

**Two dates, one job each.** The *transaction date* is when it happened, and it alone decides which
month the entry belongs to. The *settlement date* is when money moved, and it is used by
reconciliation and by nothing else. A posting where no money moved — an owner draw, a correction —
carries no settlement date, and putting one on it is refused.

**Each book balances alone.** Pay a business expense with a private card and the ledger completes
the entry through the configured owner-draw pair, so the business book and the private book each
balance on their own. You give it two lines; it stores four, and says so.

**A closed month is closed.** You cannot post into it, edit inside it, or even attach a receipt.
Re-open it, change what is wrong, close it again — the superseded closing record stays, so the
change is visible rather than absent.

**A sealed year is different in kind.** After the annual close there is no re-opening, ever. An
error found later is corrected by a new entry in an open month: one side against the
prior-period-adjustment account (equity), the other against the balance-sheet account that was
actually misstated. It never touches an income or expense account, because those are already inside
retained earnings — putting it there would drop last year's error into this year's profit.

**The annual close posts before it seals.** It transfers the year's income and expense into
retained earnings, dated the last day of the fiscal year, and then seals every month of that year.
That order is why year two's balance sheet carries year one's result.

**One currency.** A payment made abroad is recorded at what your account was actually charged. The
original currency and amount go in a note that nothing sums, converts or parses. There is no
exchange rate anywhere in this system.

## Setting up

Copy `config/accounts.yml` to `.kairos/accounts/main/config.yml` and edit it. That file is the
whole jurisdiction surface: currency, books, the crossing pair, fiscal year start, the chart of
accounts (with a `cash` flag on anything money sits in), tax labels, the retained-earnings and
prior-period-adjustment accounts, and one import profile per bank.

The loader refuses exactly one thing: a configuration that would make the ledger's own rules
unsatisfiable — an account removed or retyped while postings reference it, a required account
missing or wrongly typed, a currency changed under existing postings, a profile naming a column it
does not map. It names every cause at once and nothing runs until they are fixed. Renaming an
account is always safe.

Migrating from a spreadsheet: import the history under a profile, then post one opening entry.

## Sub-agent

`am-bookkeeper` transcribes receipts and statements into proposals and reads the figures back out.
It can import, query and report. It cannot post, confirm, discard, close or bind evidence.
