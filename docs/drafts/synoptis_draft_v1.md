# Synoptis: Mutual Attestation for Trustworthy MCP Agent Networks

**Masaomi Hatakeyama**

Genomics on Blockchain

---

## Abstract

The Model Context Protocol (MCP) enables AI agents to dynamically discover and invoke tools provided by external servers, creating flexible multi-agent networks. However, this dynamic capability acquisition introduces a fundamental trust problem: when agents can modify their available capabilities at runtime, static permission lists and single-protocol attestation are insufficient to ensure trustworthy interactions. Recent work on AttestMCP has shown that adding capability attestation within MCP reduces attack success rates from 52.8% to 12.4%, but relies on unidirectional, centralized verification. We present **Synoptis**, a mutual attestation protocol that enables MCP agents to make bidirectional, cryptographically signed claims about each other's behavior, verified against a hash-chained tamper-evident log. Synoptis introduces three contributions: (1) a bidirectional attestation protocol with challenge-response dispute resolution, (2) a five-dimensional dynamic trust scoring model that captures quality, freshness, diversity, velocity, and revocation status, and (3) an append-only hash-chained registry that provides blockchain-grade integrity guarantees without requiring consensus. We implement Synoptis as a modular SkillSet within KairosChain, a self-referential MCP server framework. Through a systematic review of 38 papers published between 2022 and 2026, we identify that no existing system combines mutual cryptographic attestation with tamper-evident logging for MCP agent networks. We present the protocol specification, analyze its security properties against four attack scenarios (tool poisoning, Sybil attacks, collusion, and score manipulation), and discuss design trade-offs including the deliberate choice of hash-chained logs over full blockchain consensus.

**Keywords:** Model Context Protocol, mutual attestation, trust scoring, multi-agent security, tamper-evident log, MCP agents

---

## 1. Introduction

When an AI agent can dynamically acquire, compose, and revoke capabilities through the Model Context Protocol (MCP) [1], how should other agents decide whether to trust it? This question is not merely theoretical. The MCP ecosystem has grown rapidly since its introduction by Anthropic in 2024, with MCP servers now providing tools ranging from file system access to database queries to code execution. Each tool invocation crosses a trust boundary, and the dynamic nature of capability acquisition means that an agent's trustworthiness cannot be assessed statically.

Recent security analyses have documented concrete attack vectors in this environment. Ruan et al. [2] identify three critical vulnerabilities in MCP: absence of capability attestation, bidirectional sampling without origin authentication, and implicit trust propagation across tool chains. Their proposed AttestMCP extension reduces attack success rates from 52.8% to 12.4% by introducing server-side capability attestation. However, AttestMCP operates within a single MCP session and relies on a centralized verification authority, leaving cross-agent trust unaddressed.

| | AttestMCP [2] | Synoptis |
|---|---|---|
| Direction | Unidirectional (server → client) | Bidirectional (mutual) |
| Verification | Centralized authority | Decentralized (peer-to-peer) |
| Persistence | Session-scoped | Hash-chained tamper-evident log |

**Table 1.** Comparison of AttestMCP and Synoptis.

We present **Synoptis**, a mutual attestation protocol for MCP agent networks that addresses this gap. Our contributions are:

- **C1: Bidirectional mutual attestation protocol.** Two MCP agents can make cryptographically signed claims about each other's behavior, with a challenge-response mechanism for dispute resolution. Unlike AttestMCP's unidirectional model, Synoptis enables symmetric trust assessment.

- **C2: Five-dimensional dynamic trust scoring.** Rather than binary trust decisions, Synoptis computes a continuous trust score across five dimensions—quality, freshness, diversity, velocity, and revocation—enabling nuanced, time-varying trust assessment.

- **C3: Hash-chained tamper-evident registry.** All attestations, revocations, and challenge-response records are stored in an append-only log with SHA-256 hash-chaining, providing integrity guarantees verifiable without a consensus protocol.

The remainder of this paper is organized as follows. Section 2 defines the background and threat model. Section 3 surveys related work. Section 4 presents the Synoptis protocol. Section 5 analyzes its security properties. Section 6 discusses limitations and future work. Section 7 concludes.

---

## 2. Background and Threat Model

### 2.1 MCP and Dynamic Capability Acquisition

The Model Context Protocol [1] defines a JSON-RPC 2.0-based interface between AI agent hosts and tool-providing servers. An MCP server exposes a set of tools, each described by a name, description, and input schema. Agents discover available tools via the `tools/list` method and invoke them via `tools/call`. Crucially, the set of available tools can change at runtime: servers may add, remove, or modify tools, and agents may connect to new servers during a session.

We define *dynamic capability acquisition* as the process by which an agent's effective capability set changes during execution through tool discovery, composition, or delegation. This is distinct from static configuration and introduces the trust challenge that Synoptis addresses: an agent that was trustworthy at time *t* may have acquired capabilities—or had capabilities modified by a compromised server—that make it untrustworthy at time *t+1*.

### 2.2 Threat Model

We consider a network of *N* MCP agents, each operating an MCP server and potentially connecting to other agents' servers. We adopt a variant of the Dolev-Yao adversary model [3] adapted for MCP networks:

**Adversary capabilities:**
- The adversary controls up to *f < N/3* agents (Byzantine agents).
- Compromised agents can issue arbitrary attestations, forge claims, and selectively withhold challenge responses.
- The adversary can observe all network traffic but cannot forge RSA-2048 signatures of honest agents.
- The adversary cannot modify the local tamper-evident log of honest agents.

**Attack scenarios:**

- **Tool poisoning.** A compromised MCP server modifies tool behavior after receiving positive attestations, exploiting the gap between attestation time and invocation time.

- **Sybil attack.** An adversary creates multiple identities to inflate the diversity dimension of trust scores, manufacturing false consensus about a malicious agent's trustworthiness.

- **Collusion.** Multiple compromised agents issue mutually positive attestations to establish artificially high trust scores.

- **Score manipulation.** An adversary strategically times attestations to exploit the velocity dimension, creating bursts of attestations that inflate scores before launching an attack.

**Assumptions:**
- Each honest agent possesses an RSA-2048 key pair. Key distribution uses Trust-On-First-Use (TOFU).
- The local file system of honest agents is integrity-protected (i.e., the adversary cannot tamper with the append-only log on honest agents' storage).
- Network communication may be unreliable but cannot be selectively delayed indefinitely by the adversary.

**Explicit non-goals:**
- Forward secrecy is not provided. Compromise of a signing key exposes all past attestations signed with that key.
- We do not address denial-of-service attacks on the attestation layer.
- Sybil resistance depends on external identity mechanisms (e.g., key ceremony, organizational trust); Synoptis does not solve the identity bootstrap problem.

---

## 3. Related Work

We survey related work across four areas, drawing on a systematic review of 38 papers published between 2022 and 2026.

### 3.1 MCP Security

The MCP specification [1] defines transport-level security (TLS) and OAuth 2.1 authentication but provides no mechanism for cross-agent capability attestation. Ruan et al. [2] present the most directly relevant prior work: AttestMCP, which introduces server-side capability declarations verified by a trusted authority. Their evaluation shows a reduction in prompt injection attack success from 52.8% to 12.4%. However, AttestMCP is limited to unidirectional verification (server attests to client) within a single session, with a centralized trust authority. Synoptis extends this work to bidirectional, decentralized, persistent attestation.

Li et al. [4] provide a comprehensive survey of MCP security threats, identifying capability attestation gaps, sampling vulnerabilities, and trust propagation risks. Their threat taxonomy informs our threat model in Section 2.2. The broader survey by Chen et al. [5] compares MCP with A2A, ACP, and ANP protocols, noting that all current agent interoperability protocols lack built-in trust mechanisms for cross-agent verification.

### 3.2 Verifiable Credentials and Decentralized Identity

The W3C Verifiable Credentials (VC) and Decentralized Identifier (DID) standards [6] provide a framework for issuing, presenting, and verifying claims. Chen et al. [7] apply DID/VC to AI agent identity, enabling credential portability across ecosystems. However, W3C VC is designed for public infrastructure and assumes the availability of verifiable data registries (typically public blockchains). Synoptis operates in permissioned environments where agents may not have access to public chain infrastructure, and where attestations must be recorded locally with integrity guarantees rather than on an external ledger.

### 3.3 Blockchain-Based Trust and Audit

Several systems use blockchain infrastructure for agent coordination and trust. Jackson [8] proposes DAO-Agent with zero-knowledge verification and Shapley value-based integrity checks. The Observer Protocol [9] demonstrated real-time cryptographic proof settlement between AI agents on Bitcoin mainnet. However, these approaches incur the latency and cost of public chain transactions, making them impractical for the high-frequency, low-latency attestation required in MCP tool invocations.

Blockchain-based audit trail systems such as AuditTrust [10] provide tamper-evident logging for data sharing but target human-to-system interactions rather than agent-to-agent attestation. Synoptis's hash-chained registry provides comparable integrity guarantees without requiring a consensus protocol, appropriate for permissioned agent networks where the log is maintained locally by each participant.

### 3.4 Multi-Agent Trust and Reputation

Trust and reputation models for multi-agent systems have been extensively studied [11]. Recent work addresses AI agent-specific challenges: the TRiSM framework [12] identifies trust, risk, and security management dimensions for agentic AI but provides no concrete protocol. The Mansa AI reputation layer [13] introduces structured metrics for Web3 agents but lacks formal inter-agent attestation. Xu et al. [14] identify reputation manipulation risks in generative multi-agent systems, including colluding agents and hidden triggers—precisely the attack scenarios Synoptis is designed to detect.

**Gap summary.** No existing system combines: (1) bidirectional mutual attestation between AI agents, (2) dynamic trust scoring that evolves over time, (3) tamper-evident persistence without consensus overhead, and (4) integration with the MCP protocol ecosystem. Synoptis addresses this gap.

---

## 4. Synoptis Protocol

### 4.1 Design Principles

Synoptis is designed around three principles:

**Blockchain-grade integrity without consensus.** We target the integrity guarantees of blockchain systems—append-only storage, hash-chaining, cryptographic verification—without requiring a consensus protocol. Our implementation uses a hash-chained tamper-evident log: each record includes the SHA-256 hash of its predecessor, creating a verifiable chain. This provides *local* integrity (an honest agent can verify that its own log has not been tampered with) but does not provide *global* consensus (agents do not agree on a single canonical log). We consider this trade-off appropriate for permissioned MCP networks where agents maintain their own logs and cross-verify through the attestation protocol itself.

**Observation-based trust.** Trust is computed from observable evidence (attestations, challenges, responses) rather than declared intentions. This aligns with the principle that in decentralized networks, behavior is the only reliable signal [15].

**Transport independence.** The attestation protocol is defined independently of the communication layer. Synoptis supports three transports: MMP (Model Meeting Protocol) for inter-server communication, Hestia for LAN discovery, and local delivery for co-located agents. New transports can be added without modifying the attestation logic.

### 4.2 Proof Envelope

The fundamental data unit in Synoptis is the **ProofEnvelope**, a structured attestation record:

```
ProofEnvelope := {
  proof_id:     UUID v4,
  version:      "1.0.0",
  attester_id:  String,     // MCP instance identifier
  subject_ref:  String,     // What is being attested about
  claim:        String,     // The attestation claim
  evidence:     String?,    // Supporting evidence (optional)
  merkle_root:  String?,    // For selective disclosure (optional)
  signature:    String?,    // RSA-SHA256, Base64-encoded
  timestamp:    ISO 8601,   // UTC
  ttl:          Integer     // Time-to-live in seconds
}
```

**Canonical form.** To ensure deterministic hashing, we define a canonical JSON representation that includes all fields except `signature`, `actor_user_id`, `actor_role`, and `metadata`. Fields are sorted by key, and `nil` values are explicitly retained as JSON `null` rather than omitted. The **content hash** is computed as SHA-256 over this canonical form.

**Signing.** When cryptographic material is available, the ProofEnvelope is signed using RSA-2048 with SHA-256:

```
signature = Base64(RSA-Sign(SHA256, canonical_json(envelope)))
```

Verification requires the attester's public key, obtained through TOFU or pre-shared key distribution.

### 4.3 Trust Score Model

Synoptis computes a continuous trust score *S* ∈ [0, 1] for each subject from the set of attestations referencing that subject. The score is a weighted linear combination of five dimensions:

$$S = \text{clamp}\left(\sum_{d \in D} w_d \cdot s_d - w_r \cdot p_r,\ 0,\ 1\right)$$

where *D* = {quality, freshness, diversity, velocity}, *w_d* are dimension weights, *s_d* ∈ [0, 1] are dimension scores, *w_r* is the revocation penalty weight, and *p_r* ∈ [0, 1] is the revocation ratio.

**Table 2.** Trust score dimensions and default weights.

| Dimension | Weight | Definition | Rationale |
|-----------|:------:|-----------|-----------|
| Quality | 0.30 | Proportion of proofs with evidence, Merkle root, and signature | Higher-quality attestations (with supporting evidence and cryptographic binding) are more trustworthy |
| Freshness | 0.25 | Mean recency within a 30-day window: $\bar{f} = \frac{1}{n}\sum_i \max(1 - \frac{a_i}{720}, 0)$ where $a_i$ is age in hours | Recent attestations are more relevant; stale attestations decay linearly over 720 hours (30 days) |
| Diversity | 0.25 | Ratio of unique attesters: $\min\left(\frac{|\text{unique attesters}|}{\min(n, 10)}, 1\right)$ | Attestations from diverse sources are harder to fabricate; capped at 10 to limit Sybil amplification |
| Velocity | 0.10 | Attestation rate: $\min\left(\frac{n / \Delta t}{5}, 1\right)$ where $\Delta t$ is the time span in days | Sustained attestation activity indicates ongoing engagement; normalized to 5 attestations/day |
| Revocation | 0.10 | Penalty: $\frac{|\text{revoked}|}{n}$ | Revoked attestations reduce trust proportionally |

**Weight justification.** The default weights reflect a design priority: *evidence quality* and *source diversity* together account for 55% of the score, reflecting the principle that trust should primarily derive from verifiable evidence from independent sources. The specific values (0.30, 0.25, 0.25, 0.10, 0.10) are configurable defaults. We explicitly note that these weights are not derived from game-theoretic analysis; formal equilibrium analysis is an important direction for future work (Section 6.4).

**Linearity justification.** We choose a linear combination for simplicity and interpretability. Each dimension contributes independently and proportionally to the total score. While non-linear models (e.g., multiplicative, threshold-based) could capture dimension interactions, the linear model has the advantage of transparent decomposition: practitioners can examine each dimension's contribution to understand *why* a score is high or low.

### 4.4 Challenge-Response Protocol

When an agent disputes an attestation, Synoptis provides a structured challenge-response protocol:

**States:**
- `pending`: Challenge issued, awaiting response.
- `responded`: Original attester has provided a response.
- `expired`: Response timeout exceeded (default: 3600 seconds).

**Protocol flow:**

1. **Challenge creation.** Agent *A* challenges attestation *P* by specifying a challenge type ∈ {`validity`, `evidence_request`, `re_verification`}. The system verifies that (a) attestation *P* exists, (b) the number of active challenges for *P*'s subject does not exceed `max_active_per_subject` = 5, and (c) the challenge has not already been issued.

2. **Challenge delivery.** The challenge is delivered to the original attester via the available transport (MMP, Hestia, or local).

3. **Response.** Only the original attester may respond. The response includes optional evidence and is recorded in the append-only log.

4. **Resolution.** Challenge outcomes are determined by the requesting agent based on the response content. Synoptis does not impose a global resolution mechanism; each agent interprets challenge responses according to its own trust policy.

The `max_active_per_subject` limit of 5 prevents challenge flooding, a potential denial-of-service vector. The 3600-second timeout ensures that unresponsive attesters do not indefinitely block challenge resolution.

```
         Challenger              Attester
            |                       |
            |--- challenge_create ->|
            |   (type, proof_id)    |
            |                       |
            |<-- challenge_respond--|
            |   (evidence, response)|
            |                       |
       [local evaluation]           |
```

**Fig. 2.** Challenge-response protocol flow.

### 4.5 Registry and Transport

**Hash-chained registry.** All records (attestations, revocations, challenges) are stored in an append-only JSONL format. Each record includes a `_prev_entry_hash` field containing the SHA-256 hash of the preceding record:

```
record[i]._prev_entry_hash = SHA256(canonical_json(record[i-1]))
```

The first record in each chain has `_prev_entry_hash = null`. Chain integrity can be verified by recomputing hashes sequentially—a break in the chain indicates tampering. Concurrent writes are serialized using file-level exclusive locking.

**Transport abstraction.** Synoptis defines a transport interface with four operations: `send_attestation`, `send_revocation`, `send_challenge`, and `send_challenge_response`. Three implementations are provided:

- **MMP transport**: Uses the Model Meeting Protocol for inter-server communication over HTTP. Messages include the sender's instance ID and a bearer token for authentication.
- **Hestia transport**: Uses LAN-based discovery for local network communication.
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

The key design property is that **trust scores are not static**: even without explicit negative evidence, the freshness decay (720-hour half-life) ensures that trust degrades naturally if not actively maintained through ongoing positive attestations.

### 5.2 Sybil Resistance

The diversity dimension caps unique attesters at min(*n*, 10). This provides bounded Sybil resistance: an adversary controlling *k* identities can contribute at most *k*/10 to the diversity score, with diminishing returns. However, Synoptis does not provide fundamental Sybil resistance—an adversary with unlimited identity generation can saturate the diversity cap.

**Mitigation through multi-dimensional scoring.** Even if an adversary inflates diversity through Sybil identities, the quality dimension requires evidence and signatures (costly to fabricate at scale), and the velocity dimension normalizes to 5 attestations/day (limiting burst attacks). The combination of dimensions provides defense-in-depth: compromising one dimension does not suffice to achieve a high trust score.

### 5.3 Collusion Resistance

When *f* compromised agents collude to inflate each other's scores, Synoptis's diversity dimension provides partial detection: if all positive attestations for a subject originate from the same small group, the diversity score will be low (bounded by *f*/min(*n*, 10)). For *f < N/3*, colluding agents cannot achieve diversity scores above 0.33, limiting the maximum achievable trust score even with perfect quality, freshness, and velocity.

**Analysis.** Under the default weights, the maximum trust score achievable by a colluding minority (*f* = ⌊*N*/3⌋ - 1) is:

$$S_{\text{max}} = 0.30 \times 1.0 + 0.25 \times 1.0 + 0.25 \times \frac{f}{\min(N, 10)} + 0.10 \times 1.0 - 0.10 \times 0$$

For *N* = 10, *f* = 3: $S_{\text{max}}$ = 0.30 + 0.25 + 0.25 × 0.3 + 0.10 = 0.725. This is below a reasonable trust threshold of 0.8, meaning colluding minorities cannot achieve "high trust" status under default parameters.

### 5.4 Score Manipulation Resistance

The velocity dimension, normalized to 5 attestations/day, limits the impact of burst attacks. An adversary issuing 100 attestations in one hour achieves the same velocity score (1.0) as one issuing 5 per day over 20 days. Combined with the diversity cap, velocity manipulation provides limited benefit without control over multiple identities.

### 5.5 Comparison with AttestMCP

**Table 3.** Qualitative comparison of security properties.

| Property | AttestMCP [2] | Synoptis |
|----------|:------------:|:--------:|
| Direction | Unidirectional | Bidirectional |
| Verification model | Centralized authority | Decentralized (peer-to-peer) |
| Persistence | Session-scoped | Hash-chained tamper-evident log |
| Attack surface reduction | 52.8% → 12.4% (measured) | Defense-in-depth via 5 dimensions (analytical) |
| Dispute resolution | None | Challenge-response protocol |
| Byzantine tolerance | Not addressed | Bounded for *f < N/3* |
| Trust granularity | Binary (attested/not) | Continuous [0, 1] |
| Temporal dynamics | Static | Decay-based (720h freshness window) |

AttestMCP and Synoptis address complementary aspects of MCP security. AttestMCP operates within a single MCP session to verify server capabilities; Synoptis operates across sessions and agents to build longitudinal trust. The two approaches are composable: an MCP server could use AttestMCP for session-level capability verification and Synoptis for cross-agent reputation.

---

## 6. Discussion, Limitations, and Future Work

### 6.1 Hash-Chained Logs vs. Blockchain

We have deliberately described Synoptis's registry as a "hash-chained tamper-evident log" rather than a "blockchain." While the hash-chaining mechanism provides integrity guarantees analogous to those of blockchain systems, our implementation lacks a consensus protocol: each agent maintains its own log, and there is no mechanism to ensure that all agents agree on a single canonical history. This is a fundamental limitation for scenarios requiring global consistency (e.g., binding arbitration of disputes). However, for the mutual attestation use case—where each agent independently evaluates trust based on locally observed evidence—local integrity is sufficient. We note that extending Synoptis with a lightweight consensus protocol (e.g., for multi-party dispute resolution) is a natural direction for future work.

### 6.2 Limitations

**Forward secrecy.** Synoptis uses RSA-2048 signatures without ephemeral key exchange. Compromise of an agent's private key exposes all attestations signed with that key. Integrating ephemeral Diffie-Hellman key exchange for transport encryption is left to future work.

**Sybil resistance.** The diversity dimension caps unique attesters at 10, providing limited Sybil mitigation. However, Synoptis does not solve the fundamental Sybil problem: an adversary with the ability to generate arbitrary identities can inflate diversity scores. External identity mechanisms (e.g., organizational PKI, key ceremonies) are required for Sybil resistance in open networks.

**Scale.** The JSONL-based registry with linear scan queries does not scale to large networks. A SQLite or database-backed registry with indexed queries is planned but not yet implemented.

**Trust score weights.** The default weights are empirically motivated but not formally derived. Game-theoretic analysis of equilibrium strategies under the trust scoring mechanism—particularly whether rational adversaries can game the linear scoring model—is an important open question.

**Empirical validation.** This paper presents the protocol design and theoretical security analysis. Empirical evaluation—including sensitivity analysis of trust score weights, Byzantine agent detection rates, and performance benchmarks—is planned as immediate follow-up work.

### 6.3 Broader Context

Synoptis's design of observation-based trust assessment without requiring global consensus aligns with the DEE (Decentralized Evolving Ecosystem) model [15], which proposes that coordination among heterogeneous agents can emerge from observation and local interpretation rather than enforced agreement. While DEE articulates the philosophical framework, Synoptis provides the cryptographic infrastructure that makes verifiable observation possible in adversarial environments.

### 6.4 Future Work

- **Empirical evaluation** with simulated multi-agent networks: trust score sensitivity analysis, Byzantine agent detection rates, and latency/throughput benchmarks.
- **Formal verification** of the challenge-response protocol using model checking (TLA+ or ProVerif).
- **Game-theoretic analysis** of trust score equilibria under rational adversaries.
- **Distributed Merkle tree** for cross-agent log verification without full log replication.
- **Adaptive weight tuning** based on observed attack patterns in production deployments.

---

## 7. Conclusion

We have presented Synoptis, a mutual attestation protocol for MCP agent networks. Through a systematic review of 38 papers across MCP security, decentralized identity, blockchain-based trust, and multi-agent reputation, we identified a gap: no existing system combines bidirectional cryptographic attestation, dynamic trust scoring, and tamper-evident persistence for MCP agents. Synoptis addresses this gap with three contributions: a bidirectional attestation protocol with challenge-response dispute resolution, a five-dimensional dynamic trust scoring model, and an append-only hash-chained registry providing blockchain-grade integrity without consensus overhead.

Our security analysis demonstrates that the protocol provides bounded resistance against collusion (colluding minorities cannot exceed trust scores of 0.725 under default parameters with *N* = 10), defense-in-depth through multi-dimensional scoring against Sybil and score manipulation attacks, and temporal trust degradation that detects tool poisoning through freshness decay. We have explicitly documented the protocol's limitations, including the absence of forward secrecy, bounded Sybil resistance, and the need for empirical validation.

Synoptis is implemented as an open-source SkillSet within the KairosChain MCP Server framework. Empirical evaluation and formal verification are planned as immediate follow-up work.

---

## References

[1] Anthropic, "Model Context Protocol Specification," 2024. https://modelcontextprotocol.io/specification

[2] Ruan et al., "Breaking the Protocol: Security Analysis of the Model Context Protocol," arXiv:2601.17549, 2026.

[3] D. Dolev and A. Yao, "On the security of public key protocols," IEEE Transactions on Information Theory, vol. 29, no. 2, pp. 198–208, 1983.

[4] Li et al., "Model Context Protocol (MCP): Landscape, Security Threats, and Future Research Directions," arXiv:2503.23278, 2025.

[5] Chen et al., "A Survey of Agent Interoperability Protocols," arXiv:2505.02279, 2025.

[6] W3C, "Verifiable Credentials Data Model v2.0," 2024. https://www.w3.org/TR/vc-data-model-2.0/

[7] Chen et al., "AI Agents with Decentralized Identifiers and Verifiable Credentials," arXiv:2511.02841, 2025.

[8] F. Jackson, "Agentic Blockchain Intelligence: Designing Secure Decentralized AI Agents with Smart Contract Governance," SSRN:5869322, 2025.

[9] Observer Protocol, "Two AI agents, different stacks, settled a payment on Bitcoin mainnet," 2026. https://observerprotocol.org

[10] A. Blockchain-Based Audit Trail Mechanism, Algorithms, vol. 14, no. 12, p. 341, 2021.

[11] L. Busoniu et al., "Trust and Reputation Models for Multiagent Systems," ACM Computing Surveys, 2013.

[12] "TRiSM for Agentic AI," arXiv:2506.04133, 2025.

[13] Mansa AI, "Agent Reputation Layer Framework," 2025.

[14] Xu et al., "Beyond the Tragedy of the Commons: Building A Reputation System for Generative Multi-agent Systems," arXiv:2505.05029, 2025.

[15] M. Hatakeyama, "DEE: Decentralized Evolving Ecosystem — A Post-Consensus Model for AI Agent Communities," Zenodo, 2026. DOI: 10.5281/zenodo.18583107.

[16] "Security Threat Modeling for Emerging AI-Agent Protocols," arXiv:2602.11327, 2026.

[17] "Trustless Autonomy: Understanding Motivations, Benefits and Governance Dilemmas in Self-Sovereign Decentralized AI Agents," arXiv:2505.09757, 2025.

[18] "Authenticated Workflows: Systems Approach to Protecting Agentic AI," arXiv:2602.10465, 2026.

[19] "Towards Verifiably Safe Tool Use for LLM Agents," arXiv:2601.08012, 2026.

[20] "Open Challenges in Multi-Agent Security," arXiv:2505.02077, 2025.
