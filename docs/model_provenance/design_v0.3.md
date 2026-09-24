---
title: model_provenance — recording which model actually answered
version: 0.3
date: 2026-09-24
status: design frozen after round 2 (operator standing rule: 1–2 design rounds, then implement and review the implementation); v0.3 fixes are checked in the implementation review
author: Claude Opus 5.5 (orchestrator) on operator instruction
changes: |
  0.1 → 0.1.1 pre-flight falsifier corrections (7 refuted of 28), before any dispatch.
  0.1.1 → 0.2 round-1 fixes (5; what each newly claims):
  F1 INV-7 — divergence is any observed answering model ≠ declared persona model (a marker is a cause, not the condition); mixed persona states aggregate in a stated order; the persona↔subagent binding is a caller declaration recorded as such; a missing, late or malformed binding yields unobserved for that persona and never refuses the submission.
  F2 INV-3 — unobserved always carries a cause attributed to the layer that failed to observe; a switch actually seen outranks a missing tail; the observation store is append-only. § 4 now states both absent-SkillSet cases separately and moves the lookup into collect.
  F3 INV-6 — stated per response, not per turn: each affected response is reported exactly once, current session only, including unobserved responses and model changes with no recognised cause; the summary no longer says the operator is never told.
  F4 INV-2 — the observer acts only on Claude Code hook input and is a no-op elsewhere (the Codex projection receives the same hooks); the transcript reader is not loadable from KairosChain-layer code; each record names its originating host.
  F5 INV-1 / INV-4 / the fallback definition — Claude Code mechanism lists moved to § 7; the invariant sentences stand alone.
  0.2 → 0.2.1 pre-flight falsifier corrections before round 2 (4 refuted of 23, 2 partial; 4 internal contradictions): the /model-attachment claim is qualified by Claude Code version; INV-6 separates per-response reports from per-transcript unobserved reports, names subagents still running, and has Stop observe any subagent transcript left without a record; INV-7 no longer relies on collect knowing the session.
  0.2.1 → 0.3 round-2 fixes (5; new (a)+(b) P0s fell from 12 to 6 after de-duplication):
  G1 INV-7 — an observation read incompletely with no divergence seen ranks with unobserved for the seat; the seat is observed only when every persona's observation is complete.
  G2 INV-6 — the next normally-ending turn reads every finished response of the session not yet reported, in any turn and any transcript, including records marked incomplete; § 4 no longer limits Stop to the current turn.
  G3 INV-3/INV-7 — a record states the extent of the transcript it covers and the run it belongs to; a binding resolves to the newest record covering the subagent's latest run; collect records which record it bound, reads once, and a later record does not revise the finished run while INV-6 still shows it to the operator; a resumed run's return to its declared model is a change of recognised origin.
  G4 INV-3 — a cause names the layer that detected the non-observation and what it saw, not which layer failed; collect cannot tell 'not yet stopped' from 'no record', so it records 'no record for this binding at collect'.
  G5 INV-2/INV-6 — the silent no-op applies only to input positively identified as another host's; unplaceable input is a visible non-blocking failure; the 'no line means' guarantee holds only after the observer's first record in the session, and the first normally-ending turn of a session says once that the observer is active.
---

## 要約（人向け）

Opus 5.5 と Fable 5.1 は安全チェックに引っかかると、Claude Code が同じ依頼を別のモデル
（生物分野は Opus 5、サイバー分野は Opus 4.8）でやり直し、以後その会話はそのモデルのまま続く
（Opus 5 自身は、生物分野では拒否で終わる）。Claude Code は切り替えた時に本体の会話へ一度だけ
知らせるが、以後の返信ごとには知らせず、サブエージェントの切り替えは知らせない。答えたモデル
本人も知らされない。この設計は、Claude Code 側のフックだけが会話ログを読んで「実際に答えた
モデル」を観測し、(1) 利用者に知らせ、(2) 本体の会話ではモデル本人に伝え、(3) 多LLMレビューの
ペルソナ席の記録に残す。観測できなかった場合も「観測できなかった」と理由つきで残し、切り替え
なしと混同しない。新しい SkillSet として作り、core は変えない。

---

## 1. Problem

Claude Code runs Opus 5.5, Opus 5 and the Fable models with safety classifiers.
When a classifier flags a request and the category has a fallback model, Claude
Code re-runs the request on that model — from Fable 5.1, Fable 5 or Opus 5.5,
biology-flagged requests on Opus 5 and cybersecurity-flagged requests on Opus 4.8;
from Opus 5, cybersecurity-flagged requests on Opus 4.8 while biology-flagged ones
end in a refusal — shows a notice in the transcript, and **the session continues on
the fallback model** (Claude Code docs, model-config § Automatic model fallback). The
trigger can be workspace context alone, such as CLAUDE.md content, on the first
request.

Observed in this project's transcripts on 2026-09-24, two subagent transcripts
(`<session>/subagents/agent-<id>.jsonl`) contain an assistant record whose content
is a single block of the form
`{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}`.
In the first, 12 of 102 assistant records carry `message.model: claude-opus-5-5`
and the other 90, the marker record included, carry `claude-opus-5`; grouped by
request, 6 of 62 requests end on 5.5 and 56 on 5, and the marker shares its
`requestId` with the flagged request's records. In the second (a concurrent session)
the marker has its own `requestId`. In both, the parent session's records stayed on
`claude-opus-5-5`, and nothing in the subagent's output mentions the switch. The
first transcript's only identity record is a `model` attachment at its start naming
Opus 5.5; from Claude Code 2.1.268 on, manual `/model` switches are followed by a
fresh `model` attachment (14 of 14 user-typed switches with a later turn), and none
follows the marker in either marked transcript (both 2.1.281) (U2).

Three consequences:

- The operator is told once, in the main session, and not for subagents; nothing
  says, response by response, which model answered.
- The answering model has no documented signal that it replaced another, so its
  statements about itself cannot be relied on.
- Multi-LLM review records the persona seat by declaration only
  (`PersonaAssembly`, `model_source: 'declared'`). A fallback inside a persona
  subagent — or a persona that simply ran on another model — attributes one model's
  findings to another. Among dispatched seats only the Claude CLI seat is observed:
  the dispatcher flags `model_divergence` whenever the observed model differs from
  the declared one, and consensus reports an `excluding_divergent` count; codex and
  cursor seats are declared, and are not subject to Claude fallback.

## 2. Design Direction (this artifact)

**Problem this artifact solves**: make the model that actually answered observable
— to the operator, to the answering model where the harness allows, and in
multi-LLM review persona-seat records — without relying on any model's statement
about itself, and without ever presenting a failure to observe as an observation.

**Problems this artifact does NOT solve** (out of scope):
- Preventing fallback, or deciding whether to switch. `switchModelsOnFlag: false`
  (Claude Code setting) makes a flagged request pause and ask instead; that is the
  operator's policy choice, and in non-interactive runs it turns a flag into a
  refusal, so it cannot replace recording.
- Removing the trigger (e.g. biology content in CLAUDE.md). Separate question.
- Correcting other records made during a fallen-back session (chain records, L2
  saves, commit trailers keep the declared model). Recorded here as a known gap.
- The Claude CLI seat's existing observation, which picks the model with the most
  output tokens and so can hide a partial fallback (U6).

**Rejected alternatives and reasons**:
- Instruct the model (mode / CLAUDE.md) to state its model in every reply —
  rejected: the model has no documented signal of a switch, the transcript's only
  identity record names the original model, and a model's account of itself is a
  self-report — per masa § Self-verification the question is who could have
  authored it, and here it is the party whose identity is in question.
- Have the MCP server (`multi_llm_review_collect`) read Claude Code transcripts —
  rejected: it places Claude Code's internal file format inside the KairosChain
  layer, the concern recorded on 2026-04-23 in L1 `multi_llm_review_workflow`
  § Orchestrator Self-Identification ("depends on Claude Code internals (format may
  change between versions)").
- Ship a `kairos-*` executable in the gem so the hook commands pass the projector's
  allow-pattern without warnings — rejected for v0.1: it is a core change for a
  SkillSet concern. The commands run `ruby <data dir>/skillsets/model_provenance/…`
  as project_manager's SessionStart hook does, accepting one projection warning per
  declared hook event (three).

**Design tradeoffs adopted**:
- observation over declaration: what the harness recorded about a response
  outranks what anyone says about it, including the model.
- SkillSet over core: a new SkillSet with hooks projected by the existing plugin
  projector; no core file changes.
- report over gate: the hooks inform and record; they never block a turn, never
  alter output.
- declaration and observation side by side: the 2026-04-23 argument-passing decision
  for `orchestrator_model` stands (dispatch-time declaration); this adds an
  after-the-fact observation next to it, so divergence between the two becomes a
  recorded fact rather than an invisible one. That decision's assumption that the
  system-prompt line is authoritative no longer holds after a fallback (§ 7).

**Declared Open Unknowns**: see § 5.

**Where to register additions/objections**: new mechanisms → § 7 backlog;
style/readability → (c) advisory.

## 3. Invariants

**INV-1 (observation source).** Which model answered is derived only from what the
harness recorded — the transcript's per-response model and fallback markers, and
hook input — never from a model's statement about itself.

**INV-2 (layer and host confinement).** Only the Claude Code-layer component reads
Claude Code's transcript format or hook input, and it acts only when the input is
Claude Code hook input. Input positively identified as another host's gets a silent
no-op; input it cannot place is a visible non-blocking failure (INV-4), never
silence. KairosChain-layer code reads only the KairosChain-owned observation record and
cannot load the transcript reader. Every record names the host and layer that
produced it. A change in Claude Code's format breaks one reader, in one place,
visibly.

**INV-3 (observed, switched, or unobserved — never a guess).** Every observation is
*observed* (with the answering models and response counts, the switch that explains
any change when there is one, and the extent of the transcript and the run it covers)
or *unobserved*, and *unobserved* always carries its cause: the layer that detected
the non-observation and what it saw, never a claim about which layer failed. Evidence that was
read outranks evidence that is missing: a switch actually seen stays a switch, with
its counts marked incomplete, and *unobserved* applies only when no model evidence
was read. *Unobserved* is never recorded or displayed as *no switch*, and never
filled in with a declared model. The observation store is append-only; no record is
rewritten.

**INV-4 (report, never gate).** No hook of this SkillSet blocks, halts, prolongs or
alters a turn or its output. A failure is visible, never silent: it leaves no
partial success behind and surfaces as a non-blocking error, within a runtime
bounded well inside the hook timeout.

**INV-5 (the model is told, main session).** When the main session's model changes
automatically, the next request after the hook runs carries one statement naming the
model now answering and the model it replaced, so the model's statements about
itself need not rest on introspection. This does not reach the response already
produced by the switched request, nor subagents whose parent session's model did not
change (U1).

**INV-6 (the operator is told).** At the end of every normally-ending main-session
turn, every finished response of the current session not yet reported — in any
turn and any transcript, including those whose earlier record was incomplete — is
read, and the operator is shown, for each transcript affected (the main session's
or a subagent's), one line naming what has not been shown before: responses answered through automatic fallback or on a model changed
with no recognised cause, each counted once, with the answering model and the model
it replaced; a transcript that could not be observed, once per cause; and subagents
still running, as not yet observed. Every subagent transcript of the session is
observed by the first such turn after it stops, whether or not its own stop hook
produced a record. From the observer's first record in the session — announced once,
at the first normally-ending turn — no line means that everything read so far
matched and nothing started is pending. Responses from turns that end by interrupt or error are
carried by the next normally-ending turn; a session that ends without one leaves
them in the record only.

**INV-7 (review attribution).** When the caller binds a persona to its subagent, the
persona seat carries that persona's observation, and the binding itself is recorded
as the caller's declaration. A persona is divergent when any of its observed
responses was answered by a model other than the declared persona model, whatever
the cause; a fallback marker is recorded as the cause, not required as the
condition. The seat takes the most severe persona state in the order *divergent* >
*unobserved* > *observed, matching*; an observation read incompletely with no
divergence seen ranks as *unobserved*, and the seat counts as observed only when
every submitted persona's observation is complete; existing divergence handling then applies to it as to the Claude CLI
seat. A binding resolves to the newest record covering the subagent's latest run; one that
is missing, malformed or resolves to no such record yields *unobserved* for that
persona with the cause collect saw, and never refuses the submission. The observation
is read once, at collect, and collect records which record it bound; a later record
does not revise the finished run, and INV-6 still shows it to the operator. When the caller binds no persona, the seat is recorded exactly as today.

"Answered through automatic fallback" (INV-6/7): a fallback marker precedes the
response's final record in the same transcript, the response's model is the marker's
target, and no model change of another origin and no response on a different model
lies in between; a resumed run's return to its declared model is a change of
recognised origin. A response is one request's output, counted once for the model that
finished it; markers and harness-synthesised records are not responses.

## 4. Components

```
Claude Code layer (hook script: the only transcript reader, INV-2)      KairosChain layer
───────────────────────────────────────────────────────────────         ─────────────────
PostModelSwitch hook   additionalContext → main-session model (INV-5)
SubagentStop hook      reads the subagent's own transcript        ──►  observation record
Stop hook              reads all unreported finished responses ─────► (append-only)
                       systemMessage → operator (INV-6)                        │
                                                                              ▼
                                            multi_llm_review_collect ── resolves bindings
                                                     │                  (INV-7)
                                            PersonaAssembly.assemble(reviews, model, observations)
```

- **SkillSet `model_provenance`** (new; `templates/skillsets/`, installed to the
  instance): the transcript reader and hook script (Claude Code layer, not loadable
  from KairosChain-layer code), `plugin/hooks.json` declaring PostModelSwitch, Stop
  and SubagentStop, and an observation-record reader that other SkillSets may call.
  No MCP tools in v0.1.
- **`multi_llm_review` change**: `orchestrator_reviews[]` items accept an optional
  subagent binding. `multi_llm_review_collect` resolves bindings through the
  observation-record reader and passes the results into `PersonaAssembly.assemble`,
  which stays a function of its inputs. Without any binding, behaviour is today's.
  With a binding while the observation-record reader is not loaded, that persona is
  *unobserved* with the cause "observation reader not loaded at collect".

## 5. Declared Open Unknowns

- **U1** — PostModelSwitch is documented to fire when the *session's* model changes.
  In both observed subagent fallbacks the parent session did not change, so it
  probably does not fire for them; INV-5 is therefore scoped to the main session.
- **U2** — whether the system prompt's model line is rewritten after a fallback. The
  first transcript has no fresh `model` attachment after its marker, which suggests
  not; if it is, INV-5's statement is redundant but harmless.
- **U3** — availability-based substitutions ("fallback model chains") may leave no
  marker; under INV-6 they appear as a model change with no recognised cause.
- **U4** — flush timing: hook input may precede the transcript's final records. What
  was read is recorded as read; a missing tail is recorded as incomplete (INV-3).
- **U5** — frequency: 2 marked transcripts of about 490 so far.
- **U6** — the Claude CLI seat's partial fallback. Unaddressed in v0.1.
- **U7** — where a SubagentStop `systemMessage` or error is shown is undocumented;
  INV-6 therefore routes subagent reports through the main session's Stop.
- **U8** — `source: "auto"` covers fallback "or other change Claude Code made on its
  own"; INV-5's statement says the model changed automatically, not why, unless a
  marker confirms it.
- **U9** — whether the id the Agent tool returns equals the id SubagentStop reports.
  If not, every binding resolves to *unobserved* (INV-7) — visible, not wrong.
- **U10** — a wrong binding (the caller attaches persona A's subagent to persona B)
  cannot be detected; it is recorded as the caller's declaration (INV-7).
- **U11** — findings stay credited to the seat label; a divergent persona's findings
  are not re-attributed by model.
- **U12** — how Codex runs hooks projected into `.codex/hooks.json`; INV-2 makes the
  observer a no-op there regardless.
- **U13** — how `systemMessage` appears in non-interactive (`claude -p`) runs, and
  whether PostModelSwitch `source: "resume"` restores a pre-fallback model.

## 6. Review spec (pre-declared, frozen for round 2)

APPROVE requires all of: (i) every invariant is realizable from documented Claude
Code hook fields and the transcript facts cited in § 1; (ii) no path lets a hook
block or alter a turn (INV-4); (iii) multi-LLM review behaviour is unchanged when no
binding is supplied (INV-7); (iv) no KairosChain-layer code reads Claude Code's
formats (INV-2); (v) unknowns that bear on an invariant are declared. Target: § 1–5.
Appendix (advisory only, never blocking): § 7. Round 2 also asks each seat for a
closure verdict on the round-1 P0 ledger supplied with this artifact.

## 7. Backlog / mechanism sketch (appendix — advisory)

- Mechanisms behind the invariants (moved from § 3 in 0.2): INV-4 — no exit 2, no
  `decision: "block"`, no `continue: false`, no Stop/SubagentStop
  `additionalContext`; on failure nothing on stdout, cause on stderr, exit 1.
  Model changes of another origin: PostModelSwitch input with `source` other than
  `auto`, and `/model` records in the transcript. INV-2 host check: act only when the
  input carries Claude Code's `hook_event_name` and a `transcript_path` under
  `~/.claude/projects/`; otherwise exit 0 silently.
- Observation store: one directory per session under `<data dir>/model_provenance/`,
  one file per record written whole and renamed into place (no interleaving, no torn
  lines; a torn or unparsable file reads as *unobserved*, cause "record unreadable");
  "reported" is a separate append-only record keyed by `{session_id, response}`.
- Record fields: `observed_at, host, layer, session_id, prompt_id, scope, agent_id,
  agent_type, state, models: {model: responses}, switch: {from, to, cause},
  complete, cause, told_model` (INV-5 emission, for which switch).
- Cause vocabulary for *unobserved*: transcript absent / unreadable / no model field;
  subagent not yet stopped; no record for binding; binding malformed; observer not
  installed; record unreadable.
- Response unit: records grouped by `requestId`; records with model `<synthetic>`
  (including API-error records that carry a `requestId`) or no `requestId` are not
  responses.
- Stop's inputs for INV-6: the main transcript and the session's `subagents/`
  transcripts from the last reported extent onward (records marked incomplete are
  re-read), and the Stop input's `background_tasks` for subagents still running.
- Run boundary: a subagent run starts at its first record or at a resume
  (SendMessage); records carry `run` and the covered extent (last `requestId`/line).
- Liveness: the observer writes one `observer_live` record per session at its first
  Stop and shows `[model_provenance] active` once.
- Orchestrator practice for MLR: call collect after the personas' task-notifications,
  not on their hand-backs (hand-backs arrive 1.2–13.6 s before the final record).
- SubagentStop fires for Claude Code's internal agents too; their `agent_type` is
  empty, or the session's own agent name when one is set, so the filter is on that
  value rather than on emptiness alone.
- Notice text: one line, model IDs verbatim, e.g. `[model_provenance] 56/62
  responses in agent <type>: claude-opus-5 (automatic fallback from claude-opus-5-5)`.
- Advisory items from round 1 kept for later: a distinct `model_source` value for
  caller-bound observations; divergence qualifying a replaced-slot relation; an L1
  amendment (via L2) to § Orchestrator Self-Identification saying which identity to
  declare after a fallback notice; PostToolUse/PostToolBatch `additionalContext` to
  tell a subagent it was switched; the Agent tool result's `modelsUsed` for
  foreground subagents; Claude CLI partial-fallback divergence (U6); an MCP query
  tool; a `kairos-*` bin if the warnings prove costly.
