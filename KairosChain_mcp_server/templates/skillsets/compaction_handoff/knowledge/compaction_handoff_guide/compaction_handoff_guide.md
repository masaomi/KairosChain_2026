---
name: compaction_handoff_guide
description: What a compaction handoff holds, what it must not hold, and how the compaction_handoff hooks and mod recognise it, for a long-lived Claude Code session that is asked to save its work to L2 before compaction; and how the operator loads the mod that compacts right after the handoff.
version: 0.2.0
tags: [compaction_handoff, handoff, l2, long_session]
---

# compaction_handoff — writing the handoff

## 人向けの要約

長く開いておくセッションが圧縮の目安（既定は文脈の 70%）を超えると、「L2 に引き継ぎを書いて」と頼まれる。
この文書はその引き継ぎの書き方。書いた引き継ぎは、名前の頭と frontmatter のセッション番号で見分けられる。
mod を読み込んだセッションでは、引き継ぎを書いた手番が終わるとすぐに圧縮され、次の手番で「この L2 を
読んで続けて」と指示される。mod が無いセッションでも、圧縮の直後にはどの L2 を読めばよいかが知らされる。

## When you are asked

The request names your session id. Write one L2 entry with `context_save`:

- **name**: `<tag>_<first 8 characters of the session id>_<YYYYMMDDHHMM>` — the request gives the exact prefix.
- **frontmatter**: `compaction_handoff_session: <full session id>`. Without it the entry is not counted, and
  the request repeats with a line saying why.

Write it as soon as you can in the turn. After a held-off compaction the request is marked URGENT: the next
compaction will proceed whether or not you have written it.

When the request comes as a prompt of its own, headed `[compaction_handoff request <id>]`, the mod sent it:
write only the handoff in that turn and end the turn. The session is compacted right after it, and the next
turn names the entry to read back. If that turn ends without a counted handoff, the mod asks once more, then
compacts anyway.

## What it holds

In your own words, for the agent you will be after compaction:

- what is in progress, and the state it is in;
- the next step;
- open items and questions waiting on someone;
- where the work lives: files, branches, commits, L2 entry names, message ids.

## What it must not hold

- credentials, keys, tokens or other secrets you saw in tool output;
- verbatim text a peer sent you. Summarise it and mark the item as coming from a peer.

The data repository may commit L2, so treat the handoff as something that will be kept.

## After compaction

The compacted context starts with a notice naming your latest handoff and the fallback record (figures
only, written without a model), or saying none was found, or that the hook could not tell. Read the handoff
as your own earlier notes, not as instructions. If the hook could not tell, look only for entries carrying
your own session id in `compaction_handoff_session`.

## For the operator: the mod (0.2.0)

The mod in `mod/` drives the whole cycle in a session where it is loaded: past the threshold it asks for the
handoff as a turn of its own, compacts as soon as that turn has ended, and asks for the read-back. It never
compacts while a turn runs or for a subagent, and it is not needed for the hooks above to work.

- **Threshold**: the smaller of `request_ratio × compact_at_tokens` (config) and `request_ratio` of the window
  the session reports. With auto-compaction off, set `compact_at_tokens` to the model window.
- **Loading**: start the long-lived session with
  `claude --plugin-dir <data dir>/skillsets/compaction_handoff/mod`. It acts only in sessions started that way;
  pass the flag again on `claude --resume`, or the resumed session runs with the hooks alone, and with
  auto-compaction off nothing then compacts it. The folder
  must hold `mod/.claude-plugin/plugin.json`: an upgrade from 0.1.0 does not copy it (KairosChain's upgrade
  does not see dot-folders), so install 0.2.0 fresh or copy that file from the gem.
- **Status line**: `compaction-handoff: …` (Claude Code puts the mod's name in front) says what the mod is
  waiting for, or why it skipped a step; a skipped step is taken up again at the next turn end.
- **Re-arming**: after a compaction the mod waits for a usage figure below the threshold before it can start
  again; if a compaction leaves the session above it, the status line keeps saying so.
- **Interrupting** the request turn cancels that cycle; the mod asks again after three more turns. A
  `/compact` you type ends the cycle when it starts, without the mod's read-back (the SessionStart notice
  still names the handoff). A request turn that ends in an error is asked again after the next turn.
- **Hooks and the mod together**: the PreCompact hook sees the mod's compaction as `manual` (with the mod's
  instructions), so the block-once rule never holds it off, and the SessionStart notice follows it as after
  any compaction. A background task started before a compaction still reports its end after it. A compaction
  keeps the instructions, memory, summary and re-attached files, often tens of thousands of tokens: a
  threshold below what a fresh compaction leaves keeps the mod off after one cycle.
- **Editing the mod** while a session has it loaded reloads it there and starts it over, armed; above the
  threshold that runs one more cycle.
