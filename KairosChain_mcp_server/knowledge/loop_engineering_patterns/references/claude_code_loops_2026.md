# [Source pointer] Getting Started with Loops

> **Provenance / 来歴**
> - **Source (official):** https://claude.com/blog/getting-started-with-loops
> - **Publisher:** Anthropic / Claude Code
> - **Retrieved:** 2026-07-03
> - **Companion:** JP video walkthrough ("【神記事】Claude Code 公式が遂に『ループエンジニアリング』を解説") — user-supplied summary; canonical URL not recorded.
>
> **This is a pointer, not a copy.** The article's text is Anthropic's
> copyrighted content and is **not redistributed in this gem**. The canonical
> source is the URL above.

## What the source covers (facts, for indexing)

**Four loop types:** turn-driven (trigger: user prompt; stop: task done or needs context) · goal-driven (`/goal`; stop: goal met OR max turns; a separate evaluator model checks exit criteria) · time-driven (`/loop`, `/schedule`; stop: user cancels or work done) · autonomous/proactive (events/schedule, no human present; each task exits on goal, routine runs until disabled).

**Design principles:** maintain clean codebases; encode verification as skills with quantitative checks; keep documentation accessible/current; deploy a second independent agent for review. Micro/macro loops compose — match loop complexity to problem abstraction.

**Operational notes:** bound cost with explicit success criteria + max-turn caps; script deterministic work rather than re-reasoning it; monitor spend (`/usage`, `/goal` metrics, `/workflows`); match scheduling interval to actual change frequency; auto mode removes manual permission for routine execution.

**Slash examples:** `/goal get the homepage Lighthouse score to 90 or above, stop after 5 tries` · `/loop 5m check my PR, address review comments, and fix failing CI` · `/schedule every hour: check #project-feedback for bug reports`.

For the KairosChain reading through layers, see `loop_engineering_patterns.md` §A/§B/§C. For full prose, open the URL above.
