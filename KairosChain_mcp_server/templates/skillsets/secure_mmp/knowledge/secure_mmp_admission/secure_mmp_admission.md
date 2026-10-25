---
name: secure_mmp_admission
description: How secure MMP v1 decides who may talk to this instance in MMP direct mode — the --admission launch flag, signed pin records on the chain, the pinned decider, knocks, and what MMP does not do (it carries no execution authority)
version: 0.1.0
public: false
tags: [mmp, p2p, admission, security, pin, meeting_only]
---

# Secure MMP v1 — admission

## 人向けの要約

MMP の direct モードで「誰と話すか」を、受け口を起動するときの引数で決める。`--admission pinned` で
起動した受け口は、運用者が `kairos-chain peer pin add` で許可した鍵にだけ通行証（セッション）を出す。
許可は chain の署名つきの記録そのもので、記録が読めない・署名が合わないときは誰も入れない。
MMP は通信の通り道であって、相手の道具や Claude Code を動かす権限は運ばない。届いた依頼をどうするかは、
受け取った側の harness が自分の権限で決める。

## Invariants

1. Admission is declared by how the listener starts. Without `--admission` a listener behaves as before
   (open). With `--admission pinned` a direct-mode session exists only for a key the pin records admit,
   presented with a fresh, single-use proof (`kairos-mmp-direct/1`) addressed to one of the listener's
   origins, and every request is decided again.
2. Pins are signed chain records (`mmp_admission_pin`) forming their own sequence: each names the one
   before it, so a copied earlier record counts for nothing. Core verifies them with this instance's MMP key.
3. Adding a pin is an operator command; the `peer_pin` tool can list, revoke and handle knocks only.
4. A refused introduce leaves a knock: key hash, instance id, remote address, times, a count and up to
   64 ASCII characters of the name the key claimed — unverified, never a chain block, at most 20 kept.
5. Whatever arrives through MMP is data for the receiving side's harness; no MMP component executes it.

## Operator commands

```
kairos-chain peer pin add <alias> <key_sha256> --url http://HOST:PORT   # admit
kairos-chain peer pin revoke <alias|key_sha256>                        # stop admitting
kairos-chain peer pin list                                             # what is admitted
kairos-chain --http --meeting-only --admission pinned --host <address> --data-dir <dir>
```

`key_sha256` is SHA-256 of the peer's public key DER. The url must be the origin the peer's listener
answers for (its `--host` and port, or one of its `--origin` values).
