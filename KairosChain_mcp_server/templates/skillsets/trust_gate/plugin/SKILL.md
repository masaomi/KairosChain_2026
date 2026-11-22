---
name: trust_gate
description: >
  Use when the operator asks for a trust-boundary check or names the trust
  gatekeeper. The check applies to a design or a diff that adds or changes an entrance into
  this instance: an external connection, a credential or token, a run handed
  to another agent or process, or outside text that a model will read.
---

# Trust gate

A gate that is called, not a norm that is always on. It answers the four
questions of L1 `trust_boundary_questions` and leaves the decision to the
operator. It blocks nothing and fixes nothing.

## How to call it

Start the subagent `trust-gatekeeper` and give it the paths of what is to be
judged, and nothing else. Put a diff or a design into a file first and give
the path. Do not paste the material into the message: pasted text sits where
instructions sit, and the gatekeeper can then no longer treat it as material.
Say nothing about the outcome you expect. The gatekeeper retrieves the
questions and the answer form itself.

Relay its report to the operator whole.

## What the calling session must not do

- Do not answer the four questions yourself when you wrote what is being
  judged. That is a self-report, and the entry says why it does not count.
- Do not start fixing what the report names. The findings go to the operator,
  who decides which of them are worked on and when.
- Do not read one call as a complete inventory. The entry records that two
  calls on the same target did not name the same places.

## Sub-agent

### `trust-gatekeeper`

Its tools are an allowlist: reading files, searching them, listing a
directory, and retrieving the entry. On Claude Code, as observed on 2026-11-22, it was offered nothing that writes
files or records. That limit is carried by the host's agent definition. On a host whose projection
does not carry an allowlist, the gatekeeper holds more than it needs, and the
entry says so.
