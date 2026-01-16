# KairosChain: Pure Agent Skills with Self-Amendment for Auditable AI Evolution

**Masaomi Hatakeyama**  
Genomics on Blockchain  
16 January 2026

---

## Abstract

The evolution of AI agent capabilities remains fundamentally opaque. When an AI system improves, changes behavior, or potentially becomes dangerous, the causal process of its capability formation cannot be verified by third parties. This paper introduces KairosChain, a meta ledger that records the evolution of AI skills on a private blockchain. KairosChain combines Pure Agent Skills—executable skill definitions using Ruby DSL and Abstract Syntax Trees (AST)—with the Minimum-Nomic principle, where rules can be amended but the amendment history cannot be erased. By recording every skill state transition (who changed what, when, and how) on an immutable chain, KairosChain provides a novel approach to AI explainability: explaining not whether a result is correct, but how the intelligence that produced it was formed.

**Keywords:** AI explainability, agent skills, self-amendment, blockchain, audit trail, Minimum-Nomic

---

## 1. Introduction

Large Language Model (LLM) agents and AI coding assistants have become increasingly capable, yet their capability formation process remains a black box. Prompts are volatile, tool call histories are fragmented, and the evolution of skills—their redefinition, synthesis, and deletion—leaves no trace. As a result, even when AI agents become more capable, change their behavior, or exhibit potentially harmful properties, the causal process leading to their current state cannot be independently verified.

Current approaches to AI skill management, such as skills.md files, treat skills as static text documents. This approach suffers from fundamental limitations: skill interdependencies remain unverified, contradictions between skills go undetected, and the rationale for changes becomes untraceable. This situation resembles the anti-pattern of unlimited global variables in software engineering—initially convenient, but increasingly chaotic as the system grows.

This opacity poses significant challenges for AI governance and accountability [1]. Frameworks for evaluating AI skill composition have been proposed [2], yet these approaches focus on static snapshots rather than the dynamic evolution of capabilities over time.

KairosChain addresses this gap by providing an auditable record of AI skill evolution. Drawing on the concept of Minimum Nomic—a self-amendment game where rules can change but the change history is permanent [3]—KairosChain creates a meta ledger that answers the question: "How was this intelligence formed?"

---

## 2. Related Work

### 2.1 Agent Skills and Capability Modularization

Anthropic's Claude Agent Skills [4] introduced a paradigm for reusable, domain-specific expertise modules. Skills consist of metadata (always loaded), instructions (loaded on task invocation), and resources (loaded on demand), enabling efficient context window utilization while maintaining specialization. This three-layer architecture influences KairosChain's Pure Agent Skills design.

Yu et al. [2] proposed Skill-Mix, a framework for evaluating how AI models combine multiple skills to address complex tasks. While such frameworks assess skill composition at inference time, KairosChain focuses on making skill definitions themselves auditable and versioned over time.

### 2.2 Self-Amendment and Rule Dynamics

Hatakeyama and Hashimoto [3] proposed Minimum Nomic as a model for studying rule dynamics. Derived from Suber's original Nomic game [5], Minimum Nomic preserves the essence of self-amendment while promoting evolvability. The key insight is that rules can change, but the change process itself must be observable and recordable. KairosChain applies this principle to AI skill definitions: skills may evolve, but the evolution history is immutable.

### 2.3 AI Governance and Accountability

Priyanshu et al. [1] analyzed AI governance challenges using Claude as a case study, highlighting the need for transparency and accountability mechanisms. As AI agents become more autonomous, tracking how their objectives and capabilities evolve over time becomes essential. KairosChain provides infrastructure for such tracking at the skill definition level.

---

## 3. System Design

### 3.1 Pure Agent Skills

KairosChain defines skills not as documentation but as executable structures using Ruby DSL. The term "Pure" draws an analogy to pure functions in functional programming: skills that constrain their own modification through explicit rules, minimize side effects, and maintain referential transparency. In this sense, Pure Agent Skills form an *Evolvable Internal Language*—a self-describing, self-constraining system of capability definitions.

```ruby
skill :core_safety do
  version "1.0"
  guarantees { immutable; always_enforced }
  evolve { deny :all }
  content <<~MD
    ## Core Safety Invariants
    1. Evolution requires explicit enablement
    2. Human approval required by default
    3. All changes create blockchain records
  MD
end
```

Each skill definition is parsed into an Abstract Syntax Tree (AST), enabling semantic differencing. When a skill changes, KairosChain computes the AST diff and records the hash of both the previous and new states.

### 3.2 The Minimum-Nomic Principle

KairosChain implements what we term the Minimum-Nomic principle for AI systems:

- **Amendable rules**: Skills (capabilities, behaviors, constraints) can be modified
- **Immutable history**: Who changed what, when, and how is permanently recorded
- **Controlled evolution**: Changes require explicit enablement and, by default, human approval

This avoids two extremes: completely fixed rules (no adaptation) and unrestricted self-modification (chaos). The result is an evolvable but auditable system.

### 3.3 Blockchain as Meta Ledger

The minimal on-chain data structure is the SkillStateTransition:

| Field | Description |
|-------|-------------|
| skill_id | Skill identifier |
| prev_ast_hash | SHA-256 hash of previous AST |
| next_ast_hash | SHA-256 hash of new AST |
| diff_hash | SHA-256 hash of the AST diff |
| actor | "Human" / "AI" / "System" |
| agent_id | Agent identifier |
| timestamp | ISO 8601 timestamp |
| reason_ref | Off-chain reference to change rationale |

AST content and detailed diffs are stored off-chain; only hashes appear on-chain, balancing auditability with storage efficiency.

---

## 4. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    MCP Client (AI Agent)                         │
│                   Cursor / Claude Code / etc.                    │
└─────────────────────────────┬────────────────────────────────────┘
                              │ JSON-RPC (STDIO)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                    KairosChain MCP Server                        │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                     Skills Layer                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │  │
│  │  │ kairos.rb   │  │    Safe     │  │   Kairos Module     │ │  │
│  │  │ (Ruby DSL)  │─>│   Evolver   │─>│  (Self-Reference)   │ │  │
│  │  │   + AST     │  │ (Approval)  │  │                     │ │  │
│  │  └─────────────┘  └──────┬──────┘  └─────────────────────┘ │  │
│  └──────────────────────────│─────────────────────────────────┘  │
│                             │ commit                             │
│  ┌──────────────────────────▼─────────────────────────────────┐  │
│  │                   Blockchain Layer                         │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │  │
│  │  │    Block    │  │    Chain    │  │    Merkle Tree      │ │  │
│  │  │  (SHA-256)  │─>│ (Immutable) │─>│     (Proofs)        │ │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

Figure 1: KairosChain System Architecture
```

The architecture consists of two primary layers:

1. **Skills Layer**: Manages skill definitions (Ruby DSL), enforces evolution rules through the Safe Evolver, and provides self-referential capabilities via the Kairos Module, allowing AI agents to inspect their own skill definitions.

2. **Blockchain Layer**: Records skill state transitions immutably. Each block contains a Merkle root of transactions, enabling efficient verification of historical states.

KairosChain is implemented as a Model Context Protocol (MCP) server, allowing seamless integration with MCP-compatible AI agents such as Claude Code and Cursor.

---

## 5. Discussion

### 5.1 Transparency and Evolvability

KairosChain demonstrates that transparency and evolvability need not be mutually exclusive. By recording the history of changes rather than preventing changes, the system allows AI capabilities to grow while maintaining auditability. This aligns with the Minimum-Nomic principle: the game (AI operation) can evolve, but its evolution is always observable.

### 5.2 Limitations

Current limitations include: (1) reliance on off-chain storage for detailed AST data, (2) single-node operation in the initial implementation, and (3) the assumption that skill definitions adequately capture agent capabilities. Future work will address these through periodic anchoring to public blockchains, multi-agent federation, and richer capability representations.

### 5.3 Future Directions

Planned extensions include: Ethereum hash anchoring for public verifiability, multi-agent support via agent_id tracking, zero-knowledge proofs for privacy-preserving verification, and a web dashboard for visualizing skill evolution history.

---

## 6. Conclusion

KairosChain provides a novel approach to AI explainability by focusing not on whether AI outputs are correct, but on how the AI's capabilities were formed. By combining Pure Agent Skills (executable DSL definitions) with the Minimum-Nomic principle (amendable rules with immutable history), KairosChain creates an auditable trail of AI skill evolution.

As AI systems become increasingly autonomous and capable, the ability to verify the causal process of their capability formation becomes essential. KairosChain offers a concrete step toward this goal: a meta ledger that answers the question, "How was this intelligence formed?"

Ultimately, KairosChain aims to provide a minimal yet verifiable institutional design for the co-evolution of humans and AI systems.

---

## References

[1] Priyanshu, S. Maurya, and J. Hong, "AI Governance and Accountability: An Analysis of Anthropic's Claude," *arXiv preprint arXiv:2407.01557*, 2024.

[2] D. Yu, S. Kaur, A. Gupta, J. Brown-Cohen, A. Goyal, and S. Arora, "Skill-Mix: A Flexible and Expandable Family of Evaluations for AI Models," *arXiv preprint arXiv:2310.17567*, 2023.

[3] M. Hatakeyama and T. Hashimoto, "Minimum Nomic: A Tool for Studying Rule Dynamics," *Artificial Life and Robotics*, vol. 13, no. 2, pp. 500–503, 2009. DOI: 10.1007/s10015-008-0605-6

[4] Anthropic, "Agent Skills," *Claude Documentation*, 2025. [Online]. Available: https://docs.claude.com/en/docs/agents-and-tools/agent-skills

[5] P. Suber, *The Paradox of Self-Amendment: A Study of Logic, Law, Omnipotence, and Change*. New York: Peter Lang, 1990.

---

*Version 1.0 — 16 January 2026*
