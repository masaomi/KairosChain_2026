---
name: handoff
description: >
  Write this session's handoff to L2 and record it against the session, in one
  step. Use when the operator types /handoff, asks for a handoff, says the
  session is ending or pausing, or asks to leave the work so it can be picked
  up later. 引き継ぎ、handoff を残す、セッションを終える、中断する、続きは後日。
---

# Handoff

One command for the end of a session or a pause in it. The handoff itself goes
to L2. A script then ties it to this Claude Code session, and writes the
instance's log file when the instance has named one.

Text typed after `/handoff` is a hint for the topic or the emphasis.

## Steps

1. **Save the handoff to L2** with `context_save`.
   - Name: `handoff_<topic>_<YYYYMMDD>`, lowercase letters, digits and underscores.
   - Frontmatter: `type: handoff`, `status: pending`, `date`, `tags`, and your
     estimate of the priority of what is left to do:
     - `importance`: integer 1 (low) to 5 (high). How much the remaining work
       matters to what the operator has said they are working toward.
     - `urgency`: integer 1 (low) to 5 (high). How soon it has to move: a
       deadline, someone waiting, something that breaks or expires if left.
     - `priority_basis`: one line naming what in the session each number rests
       on (a date, the operator's words, a dependency).
     These are your reading of the session, not the operator's ruling. Leave a
     number out when the session gives no ground for it; do not fill in a
     middle value. The script copies the numbers from this frontmatter, so they
     are written once, here.
   - Write for a reader who has none of this session's context and may be a
     different model. The least a handoff carries:
     - the state in one line (what is done, what is not);
     - what the operator asked for and decided, in the operator's own words, quoted;
     - what was changed and where: paths, branches, commits, and whether pushed;
     - what was checked and how, and what was not checked;
     - the first action of the next session;
     - the decisions that are still the operator's.
   - When this instance has its own convention for handoffs (an L1 entry, its
     instruction mode, its memory), that convention wins over this list.

2. **Record it.** Run, with the name you saved and the L2 session id that
   `context_save` returned:

   ```
   ruby <data dir>/skillsets/handoff/scripts/record.rb --name <name> --session <L2 session id>
   ```

   `<data dir>` is `.kairos` under the project root unless `KAIROS_DATA_DIR`
   says otherwise. Use an absolute path. The script checks that the saved file
   exists, ties it to this Claude Code session, and appends a block to the log
   file when one is configured. It prints what it did.

3. **Report** to the operator: the L2 name and session, the importance and
   urgency you gave with their basis, and what the script printed. The operator
   can correct the numbers; then change the frontmatter with `context_save` and
   run the script again. Then do the other end-of-session duties this instance's own
   instructions list, if any.

## What not to do

- Do not write the log file yourself. The script and the session-end hook are
  its only writers, so that its blocks keep one shape.
- Do not report the handoff as recorded when the script failed. Give its error.
- Do not write the session-end block. The hook writes it when the session
  ends, from the conversation record.

## What happens at session end

When a log file is configured, the SessionEnd hook appends the last turn as
comment lines, the handoffs this session saved (or that it saved none), and the
resume command. A session that ends without `/handoff` is therefore still
findable, and visibly without a handoff.
