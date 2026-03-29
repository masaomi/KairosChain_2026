# Synoptis: Mutual Attestation for Trustworthy MCP Agent Networks

**Masaomi Hatakeyama**

Genomics on Blockchain

**DOI:** [10.5281/zenodo.19161453](https://doi.org/10.5281/zenodo.19161453)

**Date:** March 2026

---

## Abstract

The Model Context Protocol (MCP) enables AI agents to dynamically discover and invoke tools provided by external servers, creating flexible multi-agent networks. However, this dynamic capability acquisition introduces a fundamental trust problem: when agents can modify their available capabilities at runtime, static permission lists and single-protocol attestation are insufficient to ensure trustworthy interactions. Recent work on AttestMCP has shown that adding capability attestation within MCP reduces attack success rates from 52.8% to 12.4%, but relies on unidirectional, centralized verification. We present **Synoptis**, a mutual attestation protocol that enables MCP agents to make bidirectional, cryptographically signed claims about each other's behavior, verified against a hash-chained tamper-evident log. Synoptis introduces three contributions: (1) a bidirectional attestation protocol with a challenge-response mechanism for contestation and local trust updating, (2) a five-dimensional dynamic trust scoring model that captures quality, freshness, diversity, velocity, and revocation status, and (3) an append-only hash-chained registry that provides local, blockchain-grade integrity guarantees without requiring consensus. We implement Synoptis as a modular SkillSet within KairosChain [22], a self-referential MCP server framework. Through a survey of related work spanning MCP security, decentralized identity, blockchain-based trust, and multi-agent reputation, we identify that, to our knowledge, no existing system combines mutual cryptographic attestation with tamper-evident logging for MCP agent networks. We present the protocol specification, analyze its security properties against four attack scenarios (tool poisoning, Sybil attacks, collusion, and score manipulation), and discuss design trade-offs including the deliberate choice of hash-chained logs over full blockchain consensus.

**Keywords:** Model Context Protocol, mutual attestation, trust scoring, multi-agent security, tamper-evident log, MCP agents

---

## 1. Introduction

When an AI agent can dynamically acquire, compose, and revoke capabilities through the Model Context Protocol (MCP) [1], how should other agents decide whether to trust it? This question is not merely theoretical. The MCP ecosystem has grown rapidly since its introduction by Anthropic in 2024, with MCP servers now providing tools ranging from file system access to database queries to code execution. Each tool invocation crosses a trust boundary, and the dynamic nature of capability acquisition means that an agent's trustworthiness cannot be assessed statically.

Recent security analyses have documented concrete attack vectors in this environment. Maloyan and Namiot [2] identify three critical vulnerabilities in MCP: absence of capability attestation, bidirectional sampling without origin authentication, and implicit trust propagation across tool chains. Their proposed AttestMCP extension reduces attack success rates from 52.8% to 12.4% by introducing server-side capability attestation. However, AttestMCP operates within a single MCP session and relies on a centralized verification authority, leaving cross-agent trust unaddressed.

**Motivating example: skill trust in agent marketplaces.** Consider a network of MCP agents that discover and exchange capabilities through a shared meeting place — a decentralized skill marketplace where agents offer tools such as genomics pipelines, data visualization, or code analysis. Before invoking another agent's tool, an agent needs to assess whether that tool is trustworthy. Today's centralized approaches — MCP server registries that rank by GitHub stars, the OpenAI GPT Store with platform-curated reviews, or package managers like npm that rely on download counts — share a common limitation: trust is established *before* use through static, centralized signals, and does not adapt after deployment. A tool that passed initial review may later be modified, compromised, or degraded, yet its marketplace rating remains unchanged. Moreover, these systems evaluate only the provider; the consumer's behavior is unmonitored. Synoptis addresses this by enabling *post-use, mutual, and temporally dynamic* trust assessment: agents attest about each other's behavior after actual interaction, trust scores decay if not actively maintained, and both skill providers and consumers are subject to evaluation. We demonstrate this integration through HestiaChain, a meeting place implementation where agents exchange skills without centralized ranking, using Synoptis attestations as the basis for trust (see Section 4.1).

We present **Synoptis**, a mutual attestation protocol for MCP agent networks that addresses this gap. Our contributions are:

- **C1: Bidirectional mutual attestation protocol for MCP agents.** Two MCP agents can make cryptographically signed claims about each other's behavior, with a challenge-response mechanism for contestation and local trust updating. Unlike AttestMCP's unidirectional model, Synoptis enables symmetric trust assessment across agents. While bidirectional attestation exists in other contexts (e.g., PGP web-of-trust, mutual TLS), Synoptis is, to our knowledge, the first protocol to apply it to the MCP agent ecosystem with tamper-evident persistence.

- **C2: Five-dimensional dynamic trust scoring.** Rather than binary trust decisions, Synoptis computes a continuous trust score across five dimensions—quality, freshness, diversity, velocity, and revocation—enabling nuanced, time-varying trust assessment.

- **C3: Hash-chained tamper-evident registry.** All attestations, revocations, and challenge-response records are stored in an append-only log with SHA-256 hash-chaining, providing local integrity guarantees verifiable without a consensus protocol.

The remainder of this paper is organized as follows. Section 2 defines the background and threat model. Section 3 surveys related work. Section 4 presents the Synoptis protocol. Section 5 analyzes its security properties. Section 6 discusses limitations and future work. Section 7 concludes.

---

## 2. Background and Threat Model

### 2.1 MCP and Dynamic Capability Acquisition

The Model Context Protocol [1] defines a JSON-RPC 2.0-based interface between AI agent hosts and tool-providing servers. An MCP server exposes a set of tools, each described by a name, description, and input schema. Agents discover available tools via the `tools/list` method and invoke them via `tools/call`. Crucially, the set of available tools can change at runtime: servers may add, remove, or modify tools, and agents may connect to new servers during a session.

We define *dynamic capability acquisition* as the process by which an agent's effective capability set changes during execution through tool discovery, composition, or delegation. This is distinct from static configuration and introduces the trust challenge that Synoptis addresses: an agent that was trustworthy at time *t* may have acquired capabilities—or had capabilities modified by a compromised server—that make it untrustworthy at time *t+1*.

### 2.2 Threat Model

We consider a network of *N* MCP agents, each operating an MCP server and potentially connecting to other agents' servers. We adopt a variant of the Dolev-Yao adversary model [3] adapted for MCP networks:

**Adversary capabilities:**
- The adversary controls up to *f* agents, where we use *f < N/3* as a collusion sizing parameter for our security analysis. Note that this threshold is adopted from the BFT literature as a convenient bound for analyzing collusion resistance in the trust scoring model (Section 5.3); it does not imply that Synoptis provides BFT-style consensus guarantees, as Synoptis does not run a consensus protocol.
- Compromised agents can issue arbitrary attestations, forge claims, and selectively withhold challenge responses.
- The adversary can observe all network traffic but cannot forge RSA-2048 signatures of honest agents.
- The adversary cannot modify the local tamper-evident log of honest agents.

**Attack scenarios:**

- **Tool poisoning.** A compromised MCP server modifies tool behavior after receiving positive attestations, exploiting the gap between attestation time and invocation time.

- **Sybil attack.** An adversary creates multiple identities to inflate the diversity dimension of trust scores, manufacturing false consensus about a malicious agent's trustworthiness.

- **Collusion.** Multiple compromised agents issue mutually positive attestations to establish artificially high trust scores.

- **Score manipulation.** An adversary strategically times attestations to exploit the velocity dimension, creating bursts of attestations that inflate scores before launching an attack.

**Assumptions:**
- Each honest agent possesses an RSA-2048 key pair. Key distribution uses Trust-On-First-Use (TOFU). We note that TOFU is vulnerable to man-in-the-middle attacks during initial key exchange; stronger bootstrap mechanisms (e.g., organizational PKI, key ceremonies) may be required for high-security deployments (see Section 6.2).
- The local file system of honest agents is integrity-protected (i.e., the adversary cannot tamper with the append-only log on honest agents' storage).
- Network communication may be unreliable but cannot be selectively delayed indefinitely by the adversary.

**Explicit non-goals:**
- Post-compromise security is not provided. Compromise of a signing key allows the adversary to forge future attestations and renders past attestations signed with that key untrustworthy.
- We do not address denial-of-service attacks on the attestation layer.
- Sybil resistance depends on external identity mechanisms (e.g., key ceremony, organizational trust); Synoptis does not solve the identity bootstrap problem.
- Replay attacks are partially mitigated through `proof_id` uniqueness checks (Section 4.2), but a comprehensive replay protection mechanism (e.g., sequence numbers or nonce-based protocols) is left to future work.
- Privacy of attestation evidence is not addressed; all attestation records are visible to any agent with access to the registry.

---

## 3. Related Work

We survey related work across four areas. Our survey reviewed literature on MCP security, decentralized identity, blockchain-based trust, and multi-agent reputation published between 2022 and 2026; we cite 21 representative works below.

### 3.1 MCP Security

The MCP specification [1] defines transport-level security (TLS) and OAuth 2.1 authentication but provides no mechanism for cross-agent capability attestation. Maloyan and Namiot [2] present the most directly relevant prior work: AttestMCP, which introduces server-side capability declarations verified by a trusted authority. Their evaluation shows a reduction in prompt injection attack success from 52.8% to 12.4%. However, AttestMCP is limited to unidirectional verification (server attests to client) within a single session, with a centralized trust authority. Synoptis extends this work to bidirectional, decentralized, persistent attestation.

Hou et al. [4] provide a comprehensive survey of MCP security threats, identifying capability attestation gaps, sampling vulnerabilities, and trust propagation risks. Their threat taxonomy informs our threat model in Section 2.2. Anbiaee et al. [16] present a comparative security threat model across MCP, A2A, Agora, and ANP protocols. The broader survey by Ehtesham et al. [5] compares MCP with A2A, ACP, and ANP protocols, noting that all current agent interoperability protocols lack built-in trust mechanisms for cross-agent verification.

### 3.2 Verifiable Credentials and Decentralized Identity

The W3C Verifiable Credentials (VC) and Decentralized Identifier (DID) standards [6] provide a framework for issuing, presenting, and verifying claims. Garzon et al. [7] apply DID/VC to AI agent identity, enabling credential portability across ecosystems. However, W3C VC is designed for public infrastructure and assumes the availability of verifiable data registries (typically public blockchains). Synoptis operates in permissioned environments where agents may not have access to public chain infrastructure, and where attestations must be recorded locally with integrity guarantees rather than on an external ledger.

### 3.3 Blockchain-Based Trust and Audit

Several systems use blockchain infrastructure for agent coordination and trust. Jackson [8] proposes DAO-Agent with zero-knowledge verification and Shapley value-based integrity checks. The Observer Protocol [9] demonstrated real-time cryptographic proof settlement between AI agents on Bitcoin mainnet. However, these approaches incur the latency and cost of public chain transactions, making them impractical for the high-frequency, low-latency attestation required in MCP tool invocations. Hu et al. [17] analyze the governance tensions inherent in self-sovereign decentralized AI agents, providing motivation for attestation mechanisms that balance autonomy with accountability.

Blockchain-based audit trail systems such as AuditTrust [10] provide tamper-evident logging for data sharing but target human-to-system interactions rather than agent-to-agent attestation. Synoptis's hash-chained registry provides comparable integrity guarantees without requiring a consensus protocol, appropriate for permissioned agent networks where the log is maintained locally by each participant.

### 3.4 Multi-Agent Trust and Reputation

Trust and reputation models for multi-agent systems have been extensively studied [11]. Recent work addresses AI agent-specific challenges: the TRiSM framework [12] identifies trust, risk, and security management dimensions for agentic AI but provides no concrete protocol. The Mansa AI reputation layer [13] introduces structured metrics for Web3 agents but lacks formal inter-agent attestation. Ren et al. [14] identify reputation manipulation risks in generative multi-agent systems, including colluding agents and hidden triggers—precisely the attack scenarios Synoptis is designed to detect. Schroeder de Witt [20] provides a broader survey of open challenges in multi-agent security, while Rajagopalan and Rao [18] and Doshi et al. [19] address authenticated workflows and verifiably safe tool use for LLM agents, respectively—complementary concerns to Synoptis's attestation focus.

**Gap summary.** To our knowledge, no existing system combines: (1) bidirectional mutual attestation between AI agents, (2) dynamic trust scoring that evolves over time, (3) tamper-evident persistence without consensus overhead, and (4) integration with the MCP protocol ecosystem. Synoptis addresses this gap.

---

## 4. Synoptis Protocol

### 4.1 Design Principles

Synoptis is designed around three principles:

**Blockchain-grade local integrity without consensus.** We target the integrity guarantees of blockchain systems—append-only storage, hash-chaining, cryptographic verification—without requiring a consensus protocol. Our implementation uses a hash-chained tamper-evident log: each record includes the SHA-256 hash of its predecessor, creating a verifiable chain. This provides *local* integrity (an honest agent can verify that its own log has not been tampered with) but does not provide *global* consensus (agents do not agree on a single canonical log). We consider this trade-off appropriate for permissioned MCP networks where agents maintain their own logs and cross-verify through the attestation protocol itself.

**Observation-based trust.** Trust is computed from observable evidence (attestations, challenges, responses) rather than declared intentions. This aligns with the principle that in decentralized networks, behavior is the only reliable signal (cf. the DEE model [15], our companion work on post-consensus coordination).

**Transport independence.** The attestation protocol is defined independently of the communication layer. Synoptis supports three transports: MMP (Model Meeting Protocol, see KairosChain documentation) for inter-server communication, Hestia (a LAN discovery protocol, see KairosChain documentation) for local network communication, and local delivery for co-located agents. New transports can be added without modifying the attestation logic.

**MCP integration model.** Synoptis is implemented as an application-layer overlay on MCP, deployed as a SkillSet (plugin) within the KairosChain MCP Server framework. Attestation operations are exposed as standard MCP tools (`attestation_issue`, `attestation_verify`, `attestation_revoke`, `attestation_list`, `challenge_create`, `challenge_respond`, `trust_query`) invokable via the standard `tools/call` method. An agent evaluates trust scores before invoking tools from another agent's MCP server, using the `trust_query` tool to assess the target agent's trustworthiness based on accumulated attestation evidence.

**Structural note: SkillSets as uniform building blocks.** In KairosChain, the transport layer (MMP), the discovery layer (HestiaChain Meeting Place), and the attestation layer (Synoptis) are all implemented as SkillSets — the same plugin architecture, the same API surface, the same evolution mechanism. This uniformity has a practical consequence: Synoptis can attest about the behavior of any SkillSet, including itself. An agent can issue attestations about whether another agent's Synoptis implementation is behaving correctly (e.g., responding to challenges, maintaining hash-chain integrity). This self-referential property — where the trust verification layer is itself subject to trust verification through the same trust scoring mechanism — means that an agent's Synoptis implementation carries its own trust score, computed from attestations by other agents. A malfunctioning or malicious attestation engine is detectable by the very protocol it implements. This is not an additional feature but a structural consequence of implementing all protocol layers as SkillSets. We explore the implications of this property for adaptive scoring in Section 6.3.

### 4.2 Proof Envelope

The fundamental data unit in Synoptis is the **ProofEnvelope**, a structured attestation record:

```
ProofEnvelope := {
  proof_id:       UUID v4,
  version:        "1.0.0",
  attester_id:    String,     // MCP instance identifier
  subject_ref:    String,     // What is being attested about (see examples below)
  claim:          String,     // The attestation claim
  evidence:       String?,    // Supporting evidence (optional)
  merkle_root:    String?,    // For selective disclosure (optional)
  signature:      String?,    // RSA-SHA256, Base64-encoded
  timestamp:      ISO 8601,   // UTC
  ttl:            Integer,    // Time-to-live in seconds
  actor_user_id:  String?,    // Audit trail: user who triggered (implementation-specific)
  actor_role:     String?,    // Audit trail: role of triggering user (implementation-specific)
  metadata:       Object?     // Arbitrary extensibility (implementation-specific)
}
```

The `subject_ref` field identifies the attestation target. Examples:
- `"agent:mcp-server-alpha"` — attesting about an agent's overall behavior
- `"tool:code_execute@agent-B"` — attesting about a specific tool on a specific agent
- `"invocation:uuid:abc-123"` — attesting about a specific tool invocation result

**Canonical form.** To ensure deterministic hashing, we define a canonical JSON representation following a simplified subset of the JSON Canonicalization Scheme (JCS, RFC 8785 [21]). The canonical form includes the core fields (`proof_id`, `version`, `attester_id`, `subject_ref`, `claim`, `evidence`, `merkle_root`, `timestamp`, `ttl`) and excludes implementation-specific fields (`signature`, `actor_user_id`, `actor_role`, `metadata`). Fields are sorted lexicographically by key, and `nil` values are explicitly retained as JSON `null` rather than omitted. The **content hash** is computed as SHA-256 over this canonical form.

**Signing.** When cryptographic material is available, the ProofEnvelope is signed using RSA-2048 with SHA-256:

```
signature = Base64(RSA-Sign(SHA256, canonical_json(envelope)))
```

Verification requires the attester's public key, obtained through TOFU or pre-shared key distribution.

**Replay mitigation.** Receivers SHOULD reject ProofEnvelopes with previously observed `proof_id` values. Combined with the `ttl` field, this provides bounded replay protection: a replayed envelope will either have a known `proof_id` or will have expired.

### 4.3 Normal Attestation Flow

Before describing the challenge-response mechanism, we outline the standard bidirectional attestation lifecycle:

```
  Agent A                                Agent B
     |                                      |
     |---- tools/call (use B's tool) ------>|
     |<--- tool result --------------------|
     |                                      |
     |  [A evaluates B's tool behavior]     |
     |                                      |
     |---- attestation_issue -------------->|
     |  (subject_ref: "tool:X@agent-B",     |
     |   claim: "correct_output",           |
     |   evidence: "hash_of_result",        |
     |   signature: RSA-Sign(A))            |
     |                                      |
     |  [B independently evaluates A]       |
     |                                      |
     |<--- attestation_issue ---------------|
     |  (subject_ref: "agent:agent-A",      |
     |   claim: "legitimate_invocation",    |
     |   signature: RSA-Sign(B))            |
     |                                      |
  [Both agents store received attestations  |
   in their local hash-chained registries]  |
```

**Fig. 1.** Normal bidirectional attestation flow. Each agent independently evaluates the other and issues a signed attestation. Neither agent is required to attest positively; negative claims (e.g., `"anomalous_behavior"`) follow the same flow.

### 4.4 Trust Score Model

Synoptis computes a continuous trust score *S* ∈ [0, 1] for each subject from the set of *n* attestations referencing that subject. The score is a weighted linear combination of five dimensions:

$$S = \text{clamp}\left(\sum_{d \in D} w_d \cdot s_d - w_r \cdot p_r,\ 0,\ 1\right)$$

where *D* = {quality, freshness, diversity, velocity}, *w_d* are dimension weights, *s_d* ∈ [0, 1] are dimension scores, *w_r* is the revocation penalty weight, *p_r* ∈ [0, 1] is the revocation ratio, and *n* is the total number of attestations for the subject.

**Table 1.** Trust score dimensions and default weights.

| Dimension | Weight | Definition | Rationale |
|-----------|:------:|-----------|-----------|
| Quality | 0.30 | Proportion of proofs with evidence, Merkle root, and signature | Higher-quality attestations (with supporting evidence and cryptographic binding) are more trustworthy |
| Freshness | 0.25 | Mean recency within a 30-day window: $\bar{f} = \frac{1}{n}\sum_i \max(1 - \frac{a_i}{720}, 0)$ where $a_i$ is age in hours | Recent attestations are more relevant; stale attestations decay linearly over 720 hours (30 days) |
| Diversity | 0.25 | Ratio of unique attesters to attestation count, capped: $\min\left(\frac{|\text{unique attesters}|}{\min(n, 10)}, 1\right)$ | Attestations from diverse sources are harder to fabricate; capped at 10 to limit Sybil amplification |
| Velocity | 0.10 | Attestation rate: $\min\left(\frac{n / \Delta t}{5}, 1\right)$ where $\Delta t$ is the time span in days | Sustained attestation activity indicates ongoing engagement; normalized to 5 attestations/day |
| Revocation | 0.10 | Penalty: $\frac{|\text{revoked}|}{n}$ | Revoked attestations reduce trust proportionally |

**Weight justification.** The default weights reflect a design priority: *evidence quality* and *source diversity* together account for 55% of the score, reflecting the principle that trust should primarily derive from verifiable evidence from independent sources. The specific values (0.30, 0.25, 0.25, 0.10, 0.10) are configurable defaults. We explicitly note that these weights are not derived from game-theoretic analysis; formal equilibrium analysis is an important direction for future work (Section 6.4). The 720-hour freshness window and 5-attestations/day velocity normalization are chosen as reasonable defaults for active agent networks; deployments with different activity patterns (e.g., weekly batch processing) should adjust these parameters accordingly.

**Linearity justification.** We choose a linear combination for simplicity and interpretability. Each dimension contributes independently and proportionally to the total score. While non-linear models (e.g., multiplicative, threshold-based) could capture dimension interactions, the linear model has the advantage of transparent decomposition: practitioners can examine each dimension's contribution to understand *why* a score is high or low.

### 4.5 Challenge-Response Protocol

When an agent disputes an attestation, Synoptis provides a structured challenge-response protocol for contestation and local trust updating. We emphasize that Synoptis does not impose a globally binding resolution mechanism; each agent interprets challenge outcomes according to its own trust policy.

**States:**
- `pending`: Challenge issued, awaiting response.
- `responded`: Original attester has provided a signed response.
- `expired`: Response timeout exceeded (default: 3600 seconds).

**Protocol flow:**

1. **Challenge creation.** Agent *A* challenges attestation *P* by specifying a challenge type ∈ {`validity`, `evidence_request`, `re_verification`}. The system verifies that (a) attestation *P* exists, (b) the number of active challenges for *P*'s subject does not exceed `max_active_per_subject` = 5, and (c) the challenge has not already been issued. Note that the `max_active_per_subject` limit mitigates challenge flooding specifically; it does not constitute general denial-of-service resistance, which is an explicit non-goal (Section 2.2).

2. **Challenge delivery.** The challenge is delivered to the original attester via the available transport (MMP, Hestia, or local).

3. **Response.** Only the original attester may respond. The response MUST be cryptographically signed by the original attester's private key, preventing response spoofing. The response includes optional evidence and is recorded in the append-only log.

4. **Local evaluation.** The challenging agent evaluates the response content and determines whether to adjust trust accordingly. No global arbiter exists; resolution is local.

The 3600-second timeout ensures that unresponsive attesters do not indefinitely block challenge resolution. An expired challenge without response is itself evidence of unreliability.

```
         Challenger              Attester
            |                       |
            |--- challenge_create ->|
            |   (type, proof_id)    |
            |                       |
            |<-- challenge_respond--|
            |   (evidence, response,|
            |    signature)         |
            |                       |
       [local evaluation]           |
```

**Fig. 2.** Challenge-response protocol flow.

### 4.6 Registry and Transport

**Hash-chained registry.** All records (attestations, revocations, challenges) are stored in an append-only JSONL format. Each record includes a `_prev_entry_hash` field containing the SHA-256 hash of the preceding record:

```
record[i]._prev_entry_hash = SHA256(canonical_json(record[i-1]))
```

The first record in each chain has `_prev_entry_hash = null`. Chain integrity can be verified by recomputing hashes sequentially—a break in the chain indicates tampering. Concurrent writes are serialized using file-level exclusive locking. Note that each agent maintains its own local log; there is no mechanism to ensure global consistency across agents' logs. An agent could, in principle, present different attestation histories to different peers (equivocation). Cross-verification through the challenge-response protocol provides partial mitigation, but full equivocation detection requires distributed log comparison, which is left to future work.

**Revocation records.** A revocation is recorded as a separate registry entry of type `revocation`, referencing the original `proof_id`. Revocations must be signed by the original attester or an authorized administrator. Revoked attestations remain in the log (preserving the hash chain) and are excluded as positive evidence in trust score computation; however, they still contribute to the revocation penalty dimension (Section 4.4, Table 1). Revoked attestations are flagged as such in query results.

**Transport abstraction.** Synoptis defines a transport interface with four operations: `send_attestation`, `send_revocation`, `send_challenge`, and `send_challenge_response`. Three implementations are provided:

- **MMP transport**: Uses the Model Meeting Protocol (defined in the KairosChain MMP SkillSet) for inter-server communication over HTTP. Messages include the sender's instance ID and a bearer token for authentication.
- **Hestia transport**: Uses the Hestia LAN discovery protocol (defined in the KairosChain Hestia SkillSet) for local network communication.
- **Local transport**: Delivers attestations between co-located agents on the same machine (e.g., multi-tenant deployments).

Transport selection follows a configurable fallback order (default: MMP → Hestia → Local), with availability detected at runtime.

---

## 5. Security Analysis

We analyze Synoptis's security properties against the four attack scenarios defined in Section 2.2. This analysis is qualitative and based on protocol design; empirical evaluation with simulated agent networks is planned as future work.

### 5.1 Tool Poisoning Detection

In a tool poisoning attack, agent *M* modifies tool behavior after receiving positive attestations. Synoptis detects this through temporal evidence:

1. Agent *A* observes anomalous behavior after invoking *M*'s modified tool.
2. *A* issues a negative attestation with evidence (e.g., behavioral diff, unexpected outputs).
3. *A* challenges *M*'s existing positive attestations via the challenge-response protocol.
4. If *M* fails to respond within the timeout (3600s), the challenge expires, and the unanswered challenge is itself evidence of unreliability.
5. *M*'s trust score decreases through three mechanisms: (a) the negative attestation reduces quality, (b) positive attestations age and freshness declines, (c) the revocation of existing attestations increases the revocation penalty.

The key design property is that **trust scores are not static**: even without explicit negative evidence, the freshness decay (720-hour linear decay window) ensures that trust degrades naturally if not actively maintained through ongoing positive attestations.

### 5.2 Sybil Resistance

The diversity dimension caps unique attesters at min(*n*, 10). This provides bounded Sybil resistance: an adversary controlling *k* identities can contribute at most *k*/10 to the diversity score (when *n* ≥ 10), with diminishing returns. However, Synoptis does not provide fundamental Sybil resistance—an adversary with unlimited identity generation can saturate the diversity cap.

**Mitigation through multi-dimensional scoring.** Even if an adversary inflates diversity through Sybil identities, the quality dimension requires evidence and signatures (costly to fabricate at scale), and the velocity dimension normalizes to 5 attestations/day (limiting burst attacks). The combination of dimensions provides defense-in-depth: compromising one dimension does not suffice to achieve a high trust score.

### 5.3 Collusion Resistance

When *f* compromised agents collude to inflate each other's scores, Synoptis's diversity dimension provides partial detection. We analyze the maximum achievable trust score under collusion for the case where the total number of attestations *n* is sufficiently large that the diversity cap binds (i.e., min(*n*, 10) = 10).

Under this assumption, if all positive attestations for a subject originate from the same group of *f* colluding agents, the diversity score is bounded by *f*/10. For *f < N/3* with *N* = 10 (i.e., *f* ≤ 3), the maximum achievable trust score is:

$$S_{\text{max}} = 0.30 \times 1.0 + 0.25 \times 1.0 + 0.25 \times \frac{f}{10} + 0.10 \times 1.0 - 0.10 \times 0$$

For *f* = 3: $S_{\text{max}}$ = 0.30 + 0.25 + 0.25 × 0.3 + 0.10 = 0.725. This is below a reasonable trust threshold of 0.8, meaning colluding minorities cannot achieve "high trust" status under default parameters when *n* ≥ 10.

**Small-*n* caveat.** When the number of attestations is small (e.g., *n* = 3 and all three are from distinct colluding agents), the diversity score can reach 1.0 (since min(*n*, 10) = *n* = 3, and 3/3 = 1.0). In this regime, the collusion bound does not hold, and colluding agents can achieve arbitrarily high trust scores. This cold-start vulnerability is inherent to any reputation system with limited evidence and underscores the importance of establishing sufficient attestation volume before relying on trust scores for critical decisions.

### 5.4 Score Manipulation Resistance

The velocity dimension, normalized to 5 attestations/day, bounds the contribution of attestation frequency to the overall score. An adversary issuing 100 attestations in one hour achieves the same velocity score (1.0) as one issuing 5 per day over 20 days—the velocity dimension does not distinguish sustained from bursty activity, which we acknowledge as a limitation of the current linear model. Combined with the diversity cap, velocity manipulation provides limited benefit without control over multiple identities.

### 5.5 Comparison with AttestMCP

**Table 2.** Qualitative comparison of security properties. Note that AttestMCP reports measured attack reduction from controlled experiments, while Synoptis's properties are derived from analytical reasoning over the protocol design.

| Property | AttestMCP [2] | Synoptis |
|----------|:------------:|:--------:|
| Direction | Unidirectional | Bidirectional |
| Verification model | Centralized authority | Decentralized (peer-to-peer) |
| Persistence | Session-scoped | Hash-chained tamper-evident log |
| Attack surface reduction | 52.8% → 12.4% (measured) | Defense-in-depth via 5 dimensions (analytical) |
| Dispute mechanism | None | Challenge-response (local resolution) |
| Collusion resistance | Not addressed | Bounded for *f* < *N*/3 when *n* ≥ 10 |
| Trust granularity | Binary (attested/not) | Continuous [0, 1] |
| Temporal dynamics | Static | Decay-based (720h freshness window) |

AttestMCP and Synoptis address complementary aspects of MCP security. AttestMCP operates within a single MCP session to verify server capabilities; Synoptis operates across sessions and agents to build longitudinal trust. The two approaches are composable: an MCP server could use AttestMCP for session-level capability verification and Synoptis for cross-agent reputation.

---

## 6. Discussion, Limitations, and Future Work

### 6.1 Hash-Chained Logs vs. Blockchain

We have deliberately described Synoptis's registry as a "hash-chained tamper-evident log" rather than a "blockchain." While the hash-chaining mechanism provides integrity guarantees analogous to those of blockchain systems, our implementation lacks a consensus protocol: each agent maintains its own log, and there is no mechanism to ensure that all agents agree on a single canonical history. This means equivocation is possible: an agent could present different attestation histories to different peers. This is a fundamental limitation for scenarios requiring global consistency (e.g., binding arbitration of disputes). However, for the mutual attestation use case—where each agent independently evaluates trust based on locally observed evidence—local integrity is sufficient. Extending Synoptis with a lightweight consensus protocol or distributed log comparison for equivocation detection is a natural direction for future work.

### 6.2 Limitations

**Post-compromise security.** Synoptis uses RSA-2048 signatures without ephemeral key exchange. Compromise of an agent's private key allows the adversary to forge future attestations and renders all past attestations signed with that key untrustworthy. Integrating ephemeral Diffie-Hellman key exchange for transport encryption is left to future work. We note that RSA-2048 is the current default; algorithm agility (e.g., supporting Ed25519 or post-quantum schemes) is an implementation consideration not addressed in this specification.

**TOFU vulnerability.** The Trust-On-First-Use key distribution model is vulnerable to man-in-the-middle attacks during initial key exchange. An adversary who intercepts the first contact between two agents can substitute their own public key, undermining all subsequent signature verification. Deployments requiring strong initial trust should use organizational PKI or out-of-band key verification.

**Sybil resistance.** The diversity dimension caps unique attesters at 10, providing limited Sybil mitigation. However, Synoptis does not solve the fundamental Sybil problem: an adversary with the ability to generate arbitrary identities can inflate diversity scores. External identity mechanisms (e.g., organizational PKI, key ceremonies) are required for Sybil resistance in open networks.

**Scale.** The JSONL-based registry with linear scan queries does not scale to large networks. A SQLite or database-backed registry with indexed queries is planned but not yet implemented.

**Trust score weights.** The default weights are empirically motivated but not formally derived. Game-theoretic analysis of equilibrium strategies under the trust scoring mechanism—particularly whether rational adversaries can game the linear scoring model—is an important open question.

**Empirical validation.** This paper presents the protocol design and analytical security assessment. Empirical evaluation—including sensitivity analysis of trust score weights, Byzantine agent detection rates, and performance benchmarks—is planned as immediate follow-up work.

### 6.3 Future Work

Several directions for future work emerge from the current design. The most immediate priority is empirical evaluation with simulated multi-agent networks, including trust score sensitivity analysis across weight configurations, Byzantine agent detection rates under varying adversary ratios, and latency/throughput benchmarks for attestation creation, verification, and score computation. Formal verification of the challenge-response protocol using model checking tools such as TLA+ or ProVerif would strengthen confidence in the protocol's correctness properties. Game-theoretic analysis of trust score equilibria under rational adversaries is needed to determine whether the linear scoring model admits exploitable strategies. On the infrastructure side, a distributed Merkle tree for cross-agent log verification would enable equivocation detection without requiring full log replication, and adaptive weight tuning based on observed attack patterns would allow deployments to respond to emerging threats.

More fundamentally, any fixed scoring model is eventually gameable by rational adversaries who learn its parameters. KairosChain's self-referential SkillSet architecture provides a structural response to this challenge: because Synoptis is implemented as a SkillSet, the scoring model itself can be evolved through the same mechanisms used to evolve any other system component. Weight adjustment, model replacement, and even evolution-rule modification are all expressible as SkillSet operations recorded on the tamper-evident log. This transforms the static game (adversary vs. fixed rules) into a co-evolutionary dynamic (adversary vs. evolving rules), where the system's incompleteness — its inability to anticipate all attacks — becomes the driving force for continuous adaptation (cf. the DEE model's principle of order through fluctuation [15]).

---

## 7. Conclusion

We have presented Synoptis, a mutual attestation protocol for MCP agent networks. Through a survey of related work across MCP security, decentralized identity, blockchain-based trust, and multi-agent reputation, we identified a gap: to our knowledge, no existing system combines bidirectional cryptographic attestation, dynamic trust scoring, and tamper-evident persistence for MCP agents. Synoptis addresses this gap with three contributions: a bidirectional attestation protocol with challenge-response contestation, a five-dimensional dynamic trust scoring model, and an append-only hash-chained registry providing local, blockchain-grade integrity without consensus overhead.

Our security analysis indicates that the protocol provides bounded collusion resistance (colluding minorities with *f* ≤ 3 out of *N* = 10 cannot exceed trust scores of 0.725 under default parameters when sufficient attestation evidence exists), defense-in-depth through multi-dimensional scoring against Sybil and score manipulation attacks, and temporal trust degradation that detects tool poisoning through freshness decay. We have explicitly documented the protocol's limitations, including the absence of post-compromise security, bounded Sybil resistance, the TOFU vulnerability, the possibility of equivocation in the absence of global consensus, and the need for empirical validation.

Synoptis is implemented as an open-source SkillSet within the KairosChain MCP Server framework [22]. Empirical evaluation and formal verification are planned as immediate follow-up work.

---

## References

[1] Anthropic, "Model Context Protocol Specification," 2024. https://modelcontextprotocol.io/specification

[2] N. Maloyan and D. Namiot, "Breaking the Protocol: Security Analysis of the Model Context Protocol Specification and Prompt Injection Vulnerabilities in Tool-Integrated LLM Agents," arXiv:2601.17549, 2026.

[3] D. Dolev and A. Yao, "On the security of public key protocols," IEEE Transactions on Information Theory, vol. 29, no. 2, pp. 198–208, 1983.

[4] X. Hou, Y. Zhao, S. Wang, and H. Wang, "Model Context Protocol (MCP): Landscape, Security Threats, and Future Research Directions," arXiv:2503.23278, 2025.

[5] A. Ehtesham et al., "A Survey of Agent Interoperability Protocols: Model Context Protocol (MCP), Agent Communication Protocol (ACP), Agent-to-Agent Protocol (A2A), and Agent Network Protocol (ANP)," arXiv:2505.02279, 2025.

[6] W3C, "Verifiable Credentials Data Model v2.0," W3C Recommendation, 2025. https://www.w3.org/TR/vc-data-model-2.0/

[7] S. R. Garzon, A. Vaziry, E. M. Kuzu, D. E. Gehrmann, B. Varkan, A. Gaballa, and A. Küpper, "AI Agents with Decentralized Identifiers and Verifiable Credentials," arXiv:2511.02841, 2025.

[8] F. Jackson, "Agentic Blockchain Intelligence: Designing Secure Decentralized AI Agents with Smart Contract Governance," SSRN:5869322, 2025.

[9] Observer Protocol, "Two AI agents, different stacks, settled a payment on Bitcoin mainnet," 2026. https://observerprotocol.org

[10] F. A. Solórzano et al., "A Blockchain-Based Audit Trail Mechanism: Design and Implementation," Algorithms, vol. 14, no. 12, p. 341, 2021. DOI: 10.3390/a14120341.

[11] G. Granatyr, S. S. Botelho, O. R. Lessing, E. E. Scalabrin, J.-P. Barthès, and F. Enembreck, "Trust and Reputation Models for Multiagent Systems," ACM Computing Surveys, vol. 48, no. 2, 2015. DOI: 10.1145/2816826.

[12] S. Raza, R. Sapkota, M. Karkee, and C. Emmanouilidis, "TRiSM for Agentic AI: A Review of Trust, Risk, and Security Management in LLM-based Agentic Multi-Agent Systems," arXiv:2506.04133, 2025.

[13] Mansa AI, "Agent Reputation Layer Framework," 2025.

[14] S. Ren, W. Fu, X. Zou, C. Shen, Y. Cai, C. Chu, Z. Wang, and S. Hu, "Reputation as a Solution to Cooperation Collapse in LLM-based Multi-Agent Systems," arXiv:2505.05029, 2025.

[15] M. Hatakeyama, "DEE: Decentralized Evolving Ecosystem — A Post-Consensus Model for AI Agent Communities," Zenodo, 2026. DOI: 10.5281/zenodo.18583107 (companion work).

[16] Z. Anbiaee et al., "Security Threat Modeling for Emerging AI-Agent Protocols: A Comparative Analysis of MCP, A2A, Agora, and ANP," arXiv:2602.11327, 2026.

[17] B. A. Hu et al., "Trustless Autonomy: Understanding Motivations, Benefits, and Governance Dilemmas in Self-Sovereign Decentralized AI Agents," arXiv:2505.09757, 2025.

[18] M. Rajagopalan and V. Rao, "Authenticated Workflows: A Systems Approach to Protecting Agentic AI," arXiv:2602.10465, 2026.

[19] A. Doshi et al., "Towards Verifiably Safe Tool Use for LLM Agents," arXiv:2601.08012, 2026.

[20] C. Schroeder de Witt, "Open Challenges in Multi-Agent Security: Towards Secure Systems of Interacting AI Agents," arXiv:2505.02077, 2025.

[21] A. Rundgren, B. Jordan, and S. Erdtman, "JSON Canonicalization Scheme (JCS)," RFC 8785, Internet Engineering Task Force, June 2020. https://www.rfc-editor.org/rfc/rfc8785

[22] M. Hatakeyama, "KairosChain: A Self-Referential MCP Server Framework," 2026. DOI: 10.5281/zenodo.19161453. https://github.com/masaomi/KairosChain_2026
