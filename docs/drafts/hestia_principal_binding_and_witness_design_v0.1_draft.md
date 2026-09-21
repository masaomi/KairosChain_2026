# Principal Binding and Witnessed Identity for HestiaChain — design v0.1 (draft)

**Date:** 2026-09-17
**Author:** Masaomi Hatakeyama, drafted with Claude Fable 5.1
**Status:** DRAFT. Not reviewed. Supersedes nothing. Builds on Synoptis map-1 (`ChainCredential`, `Succession`), `TrustIdentity`, HestiaChain protocol v1 (`PhilosophyDeclaration`, `ObservationLog`), and the meeting place `PlaceRouter`.
**Origin:** persona brainstorm 2026-09-16 (`log/persona_brainstorm_direction_20260916/`), seats 03 (web-of-trust) and 05 (philosopher), and the 2026-09-17 dialogue on DEE-native identity.

---

## 0. 要約（人向け）

KairosChain の 1 instance は 1 つの chain を持ち、その chain は既に一意の識別子（`block1-sha256:…`、genesis ブロック由来）と Ed25519 鍵（map-1 規約の credential）を持っている。この設計は、その Agent に **人や組織（主体）を任意で結びつける記録**と、**その結びつけを見た第三者（目撃者）の観察記録**を足す。

- 匿名が既定。結びつけは Agent ごとの任意で、結びつけがなくても HestiaChain の交換・閲覧は今までどおり使える。
- 目撃者は「正しい」と言わない。「時刻 T に、この結びつけ記録が提示されるのを見た。資格証の種類はこれだった」とだけ記録する（DEE §3.3 判断なき観察）。
- meeting.genomicschain.io は最初の目撃者であって登録所ではない。目撃者は増やせて、消えてもよい（DEE §5.4 fade-out）。
- 罰の仕組みは足さない。結びつけ記録と目撃記録は Synoptis の attestation グラフの一部になり、信頼度は今までどおり**利用者側で** `trust_query` が計算する。結びつけは「Agent を作り直して履歴を捨てる」ことを見えるようにするだけで、それが間接的な罰になる。
- 検証は接続なしでできる。必要なのは結びつけ記録、目撃記録、目撃者の公開鍵（帯域外で取得）、chain 先頭の外部固定。

PGP との違いは「他人が信頼を署名する」のではなく「目撃者が観察を記録する」こと。Sigstore との違いは「中央の発行局と中央のログ」ではなく「Agent が自分で選んだ目撃者の集合」であること。身元提供者（ORCID、SWITCH edu-ID、Swiss E-ID、適格電子署名）は置き換えない。

---

## 1. Why

Delegation from humans to AI agents is coming before the law that governs it. When it arrives, the question asked first will be "which person or organisation stands behind this agent, and since when?" HestiaChain today answers "nobody, by design" — anonymity is the default of the exchange layer, and that default is correct for an anonymous community. It is not sufficient for the regulated face of GenomicsChain, where a verdict signed by an instance key is not a signature at all (21 CFR Part 11 §11.50, Annex 11 §14: a signature is attributable to an individual, carries date, time and meaning).

The two prior answers to "how does a key become a person" both failed or centralised. PGP made every user a key manager and let signatures mean anything; the web of trust never bootstrapped. Sigstore removed key management by delegating identity to an existing provider, then put one certificate authority and one transparency log in the middle. DEE offers a third position: the binding is **observed by witnesses the agent chooses**, never issued by an authority and never vouched for by peers. Witnesses record; they do not judge. Their disappearance is a fade-out, not a failure.

The punishment question (DEE §8.1) is answered by what HestiaChain already does, not by a new mechanism: trust is computed locally from the behaviour record, and a principal bound to a chain cannot shed that record without visibly starting over. Binding makes the reset visible. That is the entire penal apparatus, and it is enough for this version.

---

## 2. Invariants

Each invariant is stated once. Mechanism choices are in § 8 (backlog), not here.

**INV-1 Anonymity is the default; binding is additive.** No HestiaChain operation (register, browse, deposit, acquire, observe) requires a principal binding. A binding adds records; it removes no capability from unbound agents.

**INV-2 The agent identity is the chain identity.** An agent is identified by `chain_identity` (`block1-sha256:<genesis-derived hex>`) and its map-1 credential (Ed25519 public key + self-binding signature, digest committed on the chain). No new identifier is introduced. `TrustIdentity` (`agent://<pubkey_hash>`) remains the canonical trust subject.

**INV-3 A binding is bidirectional or it is nothing.** A principal-binding record carries a signature by the principal over the agent's credential digest, and a signature by the agent over the principal's claim. Either signature alone verifies nothing and is not a binding.

**INV-4 Witnesses observe; they never assert truth.** A witness record is a HestiaChain `ObservationLog` whose `interaction_hash` is the binding digest and whose `interpretation` says what the witness saw (credential class, whether external evidence was checked and how). A witness record that asserts the binding is *true* is malformed.

**INV-5 There is no registry of truth.** meeting.genomicschain.io is one witness among witnesses. Its own key is bound to its operator by the same record type. The fade-out of any witness, including the first one, invalidates no binding.

**INV-6 Verification is offline.** A verifier holding the binding record, the witness observations, the witnesses' public keys (obtained out of band) and the anchored chain heads can verify without any network call. Anything that requires contacting a server at verification time is not part of the verification.

**INV-7 Nothing is deleted.** Rotation of the agent key uses map-1 §4 succession (designation / retraction on the old chain). Ending a binding is a retraction record appended to the agent chain and witnessed like the binding. A retracted binding remains in every chain and in every trust computation, as Synoptis §4.6 keeps revoked attestations.

**INV-8 Trust is computed by the relying party, never by a witness or a server.** Binding and witness records are attestations in the Synoptis graph. `trust_query` on the relying party's instance consumes them with that party's own weights and policy. No score is stored or served by the meeting place.

**INV-9 Scope of delegation is a field from day one.** A binding record carries `scope` and `valid_until`. The fields are legally inert today; they exist so that when delegation law arrives, the record shape does not change.

**INV-10 Private material never leaves the instance.** No private key is committed to any chain, sent to any witness, or included in any record. The chain commits the credential digest; records carry signatures and public keys only.

---

## 3. Records

Three record types. All are canonical JSON (Synoptis `Entry.canonical_json`), digested by SHA-256, committed as chain entries.

### 3.1 Principal binding (`pb-1/binding`)

```
format:                    "pb-1/binding"
convention_sha256:         <digest of conventions/pb-1.md>
agent_chain_identity:      "block1-sha256:<hex>"
agent_credential_digest:   <map-1 credential digest>
principal:
  class:                   "orcid" | "edu_id" | "swiss_eid" | "qes" | "in_person" | "none"
  id:                      <provider identifier, or salted hash of it — see D-2>
  evidence:                <provider-issued token or QES signature whose audience/message
                            is agent_credential_digest; absent for in_person / none>
scope:                     [ <free-form strings, e.g. "attest:genomicschain_tier2" > ]
valid_from:                ISO8601
valid_until:               ISO8601 | null
principal_sig:             <signature under the principal's key, or the evidence itself
                            when the class carries a signature (qes, swiss_eid)>
agent_sig:                 <Ed25519 signature under the agent credential key over
                            "pb-1/binding|" + digest of all fields above except agent_sig>
```

Digest = SHA-256 over the canonical form excluding nothing (both signatures are part of the digest; the record is immutable once formed).

The `class` names what kind of external root, if any, the binding rests on. `none` is a self-declared pseudonym and is valid — it lets an anonymous agent take a stable persona without a provider. `in_person` records that a witness met the principal; the witness observation carries the weight. `orcid` and `edu_id` are OpenID Connect providers; the evidence is the provider's signed ID token with the agent credential digest as nonce or audience. `qes` and `swiss_eid` are legally meaningful signatures over the credential digest; the evidence is the signature and its certificate chain.

### 3.2 Witness observation (HestiaChain `ObservationLog`)

```
observer_id:       <witness agent id (agent://…)>
observed_id:       <bound agent id (agent://…)>
interaction_hash:  <binding digest>
observation_type:  "witnessed"                      # new value in OBSERVATION_TYPES
interpretation:
  event:                  "binding" | "retraction"
  credential_class_seen:  <principal.class as presented>
  evidence_checked:       "verified" | "not_checked" | "failed"
  method:                 <e.g. "oidc_token_signature", "qes_chain", "in_person">
timestamp:         ISO8601 (witness clock)
context_ref:       <witness chain head digest at time of observation>
```

Signed under the witness's own map-1 credential; committed to the witness's chain; the witness's chain head is anchored externally on a cadence (§ 8). A witness that reports `evidence_checked: failed` is still a valid witness — it saw a binding whose evidence did not verify, and that is information for the relying party, not a verdict.

### 3.3 Retraction (`pb-1/retraction`)

Signed by the principal or the agent, referencing the binding digest, appended to the agent chain, witnessed with `event: retraction`. A retraction ends `valid_until` for trust purposes; it does not remove the binding from any chain.

---

## 4. The meeting place as first witness

Four changes to `PlaceRouter`, none of which alter existing routes.

1. **Publish the place's own credential out of band.** The place's map-1 credential (chain identity, public key) is published in at least two channels the place does not control at read time: a DNS TXT record under `genomicschain.io`, and a Zenodo deposit with a DOI. `GET /place/v1/info` returns the same credential so a verifier can cross-check. This closes the gap the Pionierpreis draft C.3 names ("no URL returns the instance's public key").
2. **`POST /place/v1/witness`.** Accepts a `pb-1/binding` (or retraction). Verifies both signatures against the agent credential (INV-3). For classes with checkable evidence, verifies the evidence against the provider's public keys the place holds locally (OIDC JWKS snapshot, QES trust list snapshot). Records a `witnessed` observation on the place's chain and returns it signed. Never returns a trust score.
3. **`GET /place/v1/agents/:id/bindings`.** Public, read-only, under the existing public-route discipline. Returns bindings the place has witnessed for that agent and the place's observations of them. Same for retractions.
4. **Register accepts the map-1 credential.** Today registration verifies an RSA identity signature via `MMP::Crypto`. The map-1 credential (Ed25519) is accepted as an alternative identity, and `pubkey_hash` for the session is derived from it, so that the identity a binding refers to is the identity the place knows (decision D-1).

The place binds its own key to its operator with a `pb-1/binding` of class `qes` or `swiss_eid` when available, `in_person` otherwise, witnessed by at least one other server (§ 5).

---

## 5. Federation without forking: witnesses witnessing witnesses

A second HestiaChain server S2 is an agent. It registers at the first place, publishes its own credential out of band, and binds its key to its operator. The first place witnesses S2's binding; S2 witnesses the first place's. That is the whole federation handshake; there is no membership list.

An agent chooses its witness set by submitting its binding to each witness it wants. This is niche construction (DEE §4.5.6): the agent builds the relational environment in which its identity is verifiable. Nothing prevents an agent from having one witness or twenty. The relying party's `trust_query` weights the result (§ 6).

"Taking over part of the chain in a restorable form" means: a witness stores, for every agent that submitted to it, the binding records, its own observations, and the sequence of that agent's chain-head digests it has seen (via `context_ref`). It does not store the agent's chain body. Restoration of an agent's identity after loss of the first witness requires the agent's own `chain_export` plus the observations of any one surviving witness. Restoration after loss of the agent's own chain is out of scope; the chain is the identity (INV-2).

Witness fade-out is recorded like any other fade-out (`observation_type: faded`) by the witnesses that notice it. A relying party seeing a binding whose only witness has faded treats it as a binding with zero live witnesses — still a binding, weighted accordingly.

---

## 6. Trust integration: no new scorer, no punishment mechanism

Binding and witness records enter the Synoptis attestation graph as attestations:

| Record | Attester → subject | Claim | Weight input |
|---|---|---|---|
| `pb-1/binding` | principal → agent | `principal_binding:<class>` | `class` maps to `ACTOR_ROLE_WEIGHTS`: `qes`/`swiss_eid` → human-outcome tier; `orcid`/`edu_id` → peer tier; `in_person` → peer tier; `none` → automated tier |
| `witnessed` observation | witness → agent | `principal_binding_witnessed` | quality: `evidence_checked` value; diversity: distinct witnesses; freshness: observation timestamp |
| `pb-1/retraction` | principal or agent → agent | `principal_binding_retracted` | revocation dimension, as Synoptis §4.6 |

The relying party's local policy decides what is required. Two profiles are anticipated, both expressed as `trust_query` configuration on the relying party's instance and nowhere else:

- **Community profile** (default): no binding required; bindings and witnesses raise diversity and quality if present.
- **Regulated profile**: `require_binding_class: [qes, swiss_eid]` and `min_live_witnesses: 2`. An agent not meeting it is not distrusted; it is simply not eligible for the operation the profile guards.

Punishment is unchanged and now sharper. Misbehaviour produces negative observations and revocations; local scores fall; recovery requires changed behaviour over time (freshness, velocity). Before binding, an agent could reset by creating a new chain. After binding, a new chain by the same principal is either bound to the same principal identifier — in which case witnesses' records link the old chain's history to it — or unbound, in which case it starts with the cold-start score of an anonymous agent and the regulated profile excludes it. The cost of reset is made visible; nothing else is added.

---

## 7. Worked verification: a regulated verifier checks verdict V

The verifier (an inspector, or a sponsor's QA lead) receives an evidence bundle and holds, from out-of-band channels, the first place's credential (DNS + Zenodo) and the provider trust lists (QES trust list, OIDC JWKS snapshot with date).

```
1. V.signature            verifies under agent credential K            (map-1)
2. K.credential_digest    is committed in agent chain at block ≤ V.block (map-1 §2)
3. pb-1/binding B         agent_credential_digest == digest(K)
                          agent_sig verifies under K
                          principal.evidence verifies under provider trust list
                          V.timestamp within [valid_from, valid_until)
                          no pb-1/retraction of B before V.timestamp
4. witnessed observation  interaction_hash == digest(B)
   from place P           signature verifies under P.credential (from DNS/Zenodo)
                          context_ref (P chain head) appears in P's anchored head
                          sequence at or before an anchor dated ≤ V.timestamp
5. optional               same as 4 for each further witness; count live witnesses
6. relying-party policy   regulated profile: class ∈ {qes, swiss_eid}, live witnesses ≥ 2
```

Steps 1–5 need no network. Step 6 is the verifier's own policy. What the bundle proves is: a key bound to a named principal under a legally meaningful credential signed V; at least two independent parties saw that binding before V; none of them can have back-dated it past their anchors. What it does not prove is that the principal *should* have signed V — that is the audit's question, not the identity layer's.

---

## 8. Backlog (mechanism choices, not part of the design body)

- Tool names on the KairosChain side: `principal_bind`, `principal_retract`, `witness_request`, `binding_verify`. The last must be a pure function like `Succession.governance`: records in, verdict out, no clock, no network.
- Anchoring cadence for witness chain heads: daily to OpenTimestamps, monthly to Zenodo; each anchor digest recorded on the witness chain.
- Provider trust-list snapshots: stored with retrieval date; the snapshot digest included in `witnessed.interpretation.method`.
- `OBSERVATION_TYPES` gains `witnessed`; HestiaChain anchor types gain `principal_binding` (or reuse `agreement` — decide at implementation).
- `conventions/pb-1.md` written in the map-1 style: exactly these fields; extensibility is a new convention.
- Rate limiting and abuse handling on `POST /place/v1/witness` follow the existing place middleware.

---

## 9. Open decisions

| # | Decision | Options | Note |
|---|---|---|---|
| D-1 | Key system at the meeting place | (a) keep RSA `MMP::Crypto` and add map-1 Ed25519 as second identity; (b) migrate registration to map-1 | Two key systems for one agent is the PGP smell. (b) is cleaner; (a) is reversible now |
| D-2 | Principal identifier linkability | (a) plaintext provider id; (b) salted hash, salt held by principal; (c) both, principal chooses | Regulated profile needs (a). Community profile wants (b). (c) lets the same principal be linkable in one context and not another — which is exactly the cross-context reset the design wants to make visible. Unresolved |
| D-3 | What a witness checks | (a) signatures only; (b) signatures + evidence for checkable classes; (c) witness declares its own checking policy in its `PhilosophyDeclaration` | (c) is the DEE-consistent answer: each witness declares what it looks at; relying parties weight accordingly |
| D-4 | Whether `none`-class bindings are witnessed at all | yes / no | Yes keeps INV-1 honest: a pseudonym is a persona, and witnessing its stability is information |

---

## 10. What this design does not do

- It does not make delegation legally effective. `scope` and `valid_until` are record shape, not law.
- It does not add a punishment mechanism. Consequences are local trust computation over the behaviour record, as before.
- It does not solve witness collusion or witness Sybil. Synoptis §5.3's bound applies to witnesses as to any attesters. For the regulated profile the weight sits in the principal's credential class, so witness collusion can at most fake timing, not identity.
- It does not replace identity providers. The class of the credential is the ceiling of what the binding proves.
- It does not create a registry. There is no endpoint that answers "who is agent X" authoritatively; there are only witnesses who answer "what I saw".

---

## 11. Relation to existing code

| Existing | Role here | Change |
|---|---|---|
| `Synoptis::Anchoring::ChainCredential` (map-1) | agent identity and key | none |
| `Synoptis::Anchoring::Succession` (map-1 §4) | agent key rotation | none |
| `Synoptis::TrustIdentity` | canonical subject `agent://` | none |
| `Synoptis::TrustScorer` | consumes bindings and observations | claim → role-weight mapping (§ 6) |
| `HestiaChain::Protocol::ObservationLog` | witness record | `OBSERVATION_TYPES` + `witnessed` |
| `Hestia::PlaceRouter` | first witness | two routes, credential publication, map-1 at register (D-1) |
| `conventions/` | `pb-1.md` | new file |
