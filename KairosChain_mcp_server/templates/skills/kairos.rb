# KairosChain Meta-Skills Definition
# This file contains L0 (Law layer) meta-skills that govern self-modification.
# Only Kairos meta-skills can be placed here.
#
# IMPORTANT: This file is the canonical source for L0 governance rules.
# The l0_governance skill below defines what can be placed in L0.
# config.yml serves only as a fallback for bootstrapping.

# =============================================================================
# L0 GOVERNANCE - Defines what can exist in L0 (self-referential meta-rule)
# =============================================================================
skill :l0_governance do
  version "1.0"
  title "L0 Governance Rules"
  
  guarantees do
    self_referential
    human_oversight
  end
  
  evolve do
    allow :content           # Documentation can be updated
    deny :behavior           # Governance logic is fixed
    deny :guarantees         # Self-referential guarantee is fixed
  end
  
  behavior do
    # Returns the canonical L0 governance configuration
    # This is the authoritative source; config.yml is fallback only
    {
      allowed_skills: [
        :core_safety,
        :l0_governance,
        :evolution_rules,
        :layer_awareness,
        :approval_workflow,
        :self_inspection,
        :chain_awareness,
        :audit_rules
      ],
      immutable_skills: [:core_safety],
      require_human_approval: true,
      blockchain_mode: :full,
      
      # Pure Agent Skill criteria (from SPEC-010)
      purity_requirements: {
        all_criteria_in_l0: true,
        no_external_justification: true,
        mechanical_verification_preferred: true
      }
    }
  end
  
  content <<~MD
    ## L0 Governance Rules
    
    This skill defines the meta-rules for L0 itself.
    It is self-referential: L0 governance rules govern what can be in L0.
    
    ### Allowed L0 Skills
    
    Only the following skills may exist in L0 (skills/kairos.rb):
    
    | Skill ID | Purpose | Immutable |
    |----------|---------|-----------|
    | core_safety | Immutable safety foundation | Yes |
    | l0_governance | This skill (meta-governance) | No |
    | evolution_rules | How skills can evolve | No |
    | layer_awareness | Layer architecture knowledge | No |
    | approval_workflow | Human approval process | No |
    | self_inspection | Self-examination capability | No |
    | chain_awareness | Blockchain state awareness | No |
    | audit_rules | Knowledge health checks | No |
    
    ### Adding New L0 Skills
    
    To add a new skill type to L0:
    1. The skill must be a Kairos meta-skill (governs KairosChain itself)
    2. This skill's `allowed_skills` list must be evolved first
    3. Human approval is required for both steps
    4. Both changes are recorded on the blockchain
    
    ### Why This Matters (Pure Agent Skill)
    
    Per SPEC-010, all L0 governance criteria must be in L0 itself.
    This skill makes `allowed_skills` part of L0, not external config.
    
    Previously: config.yml defined what could be in L0 (external)
    Now: This skill defines what can be in L0 (self-referential)
  MD
end

# =============================================================================
# CORE SAFETY - The immutable foundation
# =============================================================================
skill :core_safety do
  version "1.1"
  title "Core Safety Rules"
  
  guarantees do
    immutable
    always_enforced
  end
  
  evolve do
    deny :all
  end
  
  content <<~MD
    ## Core Safety Invariants
    
    ### 1. Explicit Enablement
    Evolution is disabled by default.
    `evolution_enabled: true` must be explicitly set in config.
    
    ### 2. Human Approval
    L0 changes require human approval.
    `approved: true` parameter confirms human consent.
    
    ### 3. Blockchain Recording
    All changes are recorded with:
    - skill_id
    - prev_ast_hash / next_ast_hash
    - timestamp
    - reason_ref
    
    ### 4. Immutability
    This skill cannot be modified (evolve deny :all).
    The safety foundation must never change.
  MD
end

# =============================================================================
# EVOLUTION RULES - Governs how skills can evolve
# =============================================================================
skill :evolution_rules do
  version "1.0"
  title "Evolution Rules"
  
  evolve do
    allow :content
    deny :guarantees, :evolve, :behavior
  end
  
  behavior do
    # Returns list of skills that can be evolved
    Kairos.skills.select { |s| s.can_evolve?(:content) }.map do |skill|
      {
        id: skill.id,
        version: skill.version,
        evolvable_fields: [:content].select { |f| skill.can_evolve?(f) }
      }
    end
  end
  
  content <<~MD
    ## Evolution Constraints
    
    ### Prerequisites
    1. `evolution_enabled: true` in config
    2. Session evolution count < max_evolutions_per_session
    3. Skill not in immutable_skills list
    4. Skill's evolve rules allow the change
    
    ### Workflow
    1. **Propose**: Validate syntax and constraints
    2. **Review**: Human reviews (if require_human_approval)
    3. **Apply**: Execute with approved=true
    4. **Record**: Create blockchain record
    5. **Reload**: Update in-memory state
    
    ### Immutable Skills
    Skills with `evolve deny :all` cannot be modified.
    Currently: core_safety
    
    ### Field-Level Control
    Skills can allow/deny evolution per field:
    - `allow :content` - Content can change
    - `deny :behavior` - Behavior is fixed
    - `deny :evolve` - Evolution rules are fixed
  MD
end

# =============================================================================
# LAYER AWARENESS - Understands the layer architecture
# =============================================================================
skill :layer_awareness do
  version "1.0"
  title "Layer Awareness"
  
  evolve do
    allow :content
    deny :behavior
  end
  
  behavior do
    # Returns current layer configuration
    KairosMcp::LayerRegistry.summary
  end
  
  content <<~MD
    ## Layer Structure
    
    ### L0: Kairos Core (this file)
    - Path: skills/kairos.rb, skills/kairos.md
    - Blockchain: Full transaction record
    - Approval: Human required
    - Content: Meta-skills only
    
    ### L1: Knowledge
    - Path: knowledge/
    - Blockchain: Hash reference only
    - Approval: Not required
    - Content: Project knowledge (Anthropic format)
    
    ### L2: Context
    - Path: context/
    - Blockchain: None
    - Approval: Not required
    - Content: Temporary hypotheses (Anthropic format)
    
    ## Placement Rules
    - Only Kairos meta-skills in L0
    - Project knowledge → L1
    - Temporary work → L2
    
    ## Meta-Skills (L0 only)
    - core_safety
    - evolution_rules
    - layer_awareness
    - approval_workflow
    - self_inspection
    - chain_awareness
    - audit_rules
  MD
end

# =============================================================================
# APPROVAL WORKFLOW - Manages the approval process
# =============================================================================
skill :approval_workflow do
  version "1.1"
  title "Approval Workflow"
  
  evolve do
    allow :content
    deny :behavior
  end
  
  behavior do
    # L0 Auto-Check Logic (defined within L0 for Pure Agent Skill compliance)
    # This logic lives in L0 so that the checking criteria are self-referential
    
    # Auto-check a proposed L0 change
    # Returns { passed: bool, checks: [...], summary: string }
    auto_check = lambda do |skill_id:, definition:, reason: nil|
      checks = []
      l0_gov = Kairos.skill(:l0_governance)&.behavior&.call || {}
      allowed_skills = l0_gov[:allowed_skills] || []
      immutable_skills = l0_gov[:immutable_skills] || []
      
      # === 1. CONSISTENCY CHECKS (Mechanical) ===
      
      # 1.1 Is skill_id in allowed_skills?
      in_allowed = allowed_skills.include?(skill_id.to_sym)
      checks << {
        category: 'Consistency',
        item: 'Skill in allowed_skills',
        passed: in_allowed,
        detail: in_allowed ? "#{skill_id} is in allowed_skills" : "#{skill_id} is NOT in allowed_skills. Update l0_governance first."
      }
      
      # 1.2 Is skill_id NOT in immutable_skills?
      not_immutable = !immutable_skills.include?(skill_id.to_sym)
      checks << {
        category: 'Consistency',
        item: 'Skill not immutable',
        passed: not_immutable,
        detail: not_immutable ? "#{skill_id} is not immutable" : "#{skill_id} is IMMUTABLE and cannot be modified."
      }
      
      # 1.3 Syntax validation
      syntax_ok = begin
        RubyVM::AbstractSyntaxTree.parse(definition)
        true
      rescue SyntaxError => e
        e.message
      end
      checks << {
        category: 'Consistency',
        item: 'Ruby syntax valid',
        passed: syntax_ok == true,
        detail: syntax_ok == true ? "Syntax is valid" : "Syntax error: #{syntax_ok}"
      }
      
      # 1.4 Evolve rules check (if skill exists)
      existing_skill = Kairos.skill(skill_id)
      if existing_skill && existing_skill.evolution_rules
        rules = existing_skill.evolution_rules
        evolve_allowed = !rules.denied.include?(:all)
        checks << {
          category: 'Consistency',
          item: 'Evolve rules permit change',
          passed: evolve_allowed,
          detail: evolve_allowed ? "Skill's evolve rules allow modification" : "Skill's evolve rules deny :all modifications"
        }
      else
        checks << {
          category: 'Consistency',
          item: 'Evolve rules permit change',
          passed: true,
          detail: existing_skill ? "No evolve restrictions" : "New skill (no existing rules)"
        }
      end
      
      # === 2. AUTHORITY CHECKS (Mechanical) ===
      
      # 2.1 evolution_enabled?
      evolution_enabled = KairosMcp::SkillsConfig.evolution_enabled?
      checks << {
        category: 'Authority',
        item: 'Evolution enabled',
        passed: evolution_enabled,
        detail: evolution_enabled ? "evolution_enabled: true in config" : "evolution_enabled: false. Enable in config.yml first."
      }
      
      # 2.2 Session limit not exceeded
      config = KairosMcp::SkillsConfig.load
      max_evolutions = config['max_evolutions_per_session'] || 3
      current_count = KairosMcp::SafeEvolver.evolution_count
      within_limit = current_count < max_evolutions
      checks << {
        category: 'Authority',
        item: 'Within session limit',
        passed: within_limit,
        detail: within_limit ? "#{current_count}/#{max_evolutions} evolutions used" : "Session limit reached (#{current_count}/#{max_evolutions}). Use reset command."
      }
      
      # === 3. SCOPE CHECKS (Mechanical) ===
      
      # 3.1 Rollback possible (versions directory exists)
      # Derive path from SafeEvolver::DSL_PATH which points to skills/kairos.rb
      dsl_dir = File.dirname(KairosMcp::SafeEvolver::DSL_PATH)
      versions_dir = File.join(dsl_dir, 'versions')
      rollback_possible = Dir.exist?(versions_dir)
      checks << {
        category: 'Scope',
        item: 'Rollback possible',
        passed: rollback_possible,
        detail: rollback_possible ? "Version snapshots directory exists" : "Warning: versions directory not found"
      }
      
      # === 4. TRACEABILITY CHECKS (Human judgment needed) ===
      
      reason_provided = reason && !reason.strip.empty?
      checks << {
        category: 'Traceability',
        item: 'Reason documented',
        passed: reason_provided,
        detail: reason_provided ? "Reason: #{reason}" : "⚠️ HUMAN CHECK: No reason provided. Verify justification before approving.",
        requires_human: !reason_provided
      }
      
      checks << {
        category: 'Traceability',
        item: 'Traceable to L0 rule',
        passed: :unknown,
        detail: "⚠️ HUMAN CHECK: Verify this change can be traced to an explicit L0 rule.",
        requires_human: true
      }
      
      # === 5. PURE AGENT COMPLIANCE (Human judgment needed) ===
      
      checks << {
        category: 'Pure Compliance',
        item: 'No external dependencies',
        passed: :unknown,
        detail: "⚠️ HUMAN CHECK: Verify the change doesn't introduce external dependencies for its meaning.",
        requires_human: true
      }
      
      checks << {
        category: 'Pure Compliance',
        item: 'LLM-independent semantics',
        passed: :unknown,
        detail: "⚠️ HUMAN CHECK: Would different LLMs interpret this change the same way?",
        requires_human: true
      }
      
      # === SUMMARY ===
      
      mechanical_checks = checks.select { |c| c[:passed] != :unknown }
      human_checks = checks.select { |c| c[:requires_human] }
      mechanical_passed = mechanical_checks.all? { |c| c[:passed] == true }
      mechanical_failed = mechanical_checks.select { |c| c[:passed] == false }
      
      {
        passed: mechanical_passed,
        mechanical_passed: mechanical_passed,
        mechanical_failed_count: mechanical_failed.size,
        human_review_needed: human_checks.size,
        checks: checks,
        summary: mechanical_passed ? 
          "✅ All #{mechanical_checks.size} mechanical checks PASSED. #{human_checks.size} items require human verification." :
          "❌ #{mechanical_failed.size} mechanical check(s) FAILED. Fix these before proceeding."
      }
    end
    
    # Return both config and the auto_check function
    config = KairosMcp::SkillsConfig.load
    {
      evolution_enabled: KairosMcp::SkillsConfig.evolution_enabled?,
      require_human_approval: config['require_human_approval'],
      evolution_count: KairosMcp::SafeEvolver.evolution_count,
      max_per_session: config['max_evolutions_per_session'],
      immutable_skills: config['immutable_skills'],
      auto_check: auto_check
    }
  end
  
  content <<~MD
    ## Approval Workflow
    
    ### Stages
    1. **Propose**: AI suggests a change via skills_evolve
       - Syntax validation
       - Constraint checking
       - **L0 Auto-Check runs automatically**
       - Preview generation
    
    2. **Review**: Human reviews the proposal
       - Only when require_human_approval: true
       - **Review Auto-Check report (mechanical checks)**
       - **Verify human-required items (⚠️ marked)**
       - Examine preview and reason
    
    3. **Apply**: Execute with approved=true
       - Creates version snapshot
       - Applies change to file
       - Records to blockchain
    
    4. **Verify**: Confirm success
       - Check chain_history
       - Verify with skills_dsl_get
    
    ---
    
    ## L0 Auto-Check (Automated Verification)
    
    When you run `skills_evolve command="propose"`, the system automatically
    runs the following mechanical checks (defined in this skill's behavior):
    
    | Category | Check | Type |
    |----------|-------|------|
    | Consistency | Skill in allowed_skills | ✅ Auto |
    | Consistency | Skill not immutable | ✅ Auto |
    | Consistency | Ruby syntax valid | ✅ Auto |
    | Consistency | Evolve rules permit change | ✅ Auto |
    | Authority | Evolution enabled | ✅ Auto |
    | Authority | Within session limit | ✅ Auto |
    | Scope | Rollback possible | ✅ Auto |
    | Traceability | Reason documented | ✅ Auto |
    | Traceability | Traceable to L0 rule | ⚠️ Human |
    | Pure Compliance | No external dependencies | ⚠️ Human |
    | Pure Compliance | LLM-independent semantics | ⚠️ Human |
    
    **Usage:** Include `reason` parameter for better traceability:
    ```
    skills_evolve command="propose" skill_id="..." definition="..." reason="Why this change"
    ```
    
    ---
    
    ## L0 Change Approval Checklist (SPEC-010 Compliance)
    
    The full 15-item checklist. Items marked with ✅ are auto-checked.
    Items marked with ⚠️ require human verification:
    
    ### 1. Traceability
    - [✅] Is the justification documented (reason parameter)?
    - [⚠️] Can I trace this change back to an explicit L0 rule?
    - [⚠️] Would an independent reviewer reach the same conclusion?
    
    ### 2. Consistency
    - [✅] Is skill_id in allowed_skills (l0_governance)?
    - [✅] Is skill_id NOT in immutable_skills?
    - [✅] Is Ruby syntax valid?
    - [✅] Do evolve rules permit this change?
    
    ### 3. Scope
    - [⚠️] Is this change minimal (smallest change that achieves the goal)?
    - [⚠️] Are side effects understood and documented?
    - [✅] Is rollback possible (versions directory exists)?
    
    ### 4. Authority
    - [✅] Is evolution_enabled: true in config?
    - [✅] Is session evolution count within limit?
    - [⚠️] Am I authorized to approve this type of change?
    
    ### 5. Pure Agent Compliance
    - [⚠️] Does this change introduce any external dependencies for its meaning?
    - [⚠️] Would different LLMs interpret this change the same way?
    - [⚠️] Is the change's semantics time-independent?
    
    ---
    
    ### If Any Checkbox is Unchecked
    
    **Do NOT approve.** Instead:
    1. Request clarification on the failing criteria
    2. Ask for the proposal to be revised
    3. Document why approval was denied
    
    ### Configuration (skills/config.yml)
    ```yaml
    evolution_enabled: false      # Must be true to evolve
    require_human_approval: true  # Human must approve L0 changes
    max_evolutions_per_session: 3 # Limit per session
    ```
    
    Note: `immutable_skills` and `allowed_skills` are now defined in
    the `l0_governance` skill (this file), not in config.yml.
    
    ### Session Reset
    Use `skills_evolve command=reset` to reset session counter.
  MD
end

# =============================================================================
# SELF INSPECTION - Ability to examine own state
# =============================================================================
skill :self_inspection do
  version "1.1"
  title "Self Inspection"
  
  evolve do
    allow :content
    deny :behavior
  end
  
  behavior do
    # Returns summary of all loaded skills
    Kairos.skills.map do |skill|
      {
        id: skill.id,
        version: skill.version,
        title: skill.title,
        has_behavior: !skill.behavior.nil?,
        evolution_rules: skill.evolution_rules&.to_h,
        guarantees: skill.guarantees
      }
    end
  end
  
  content <<~MD
    ## Self Inspection
    
    The ability to examine one's own capabilities and state.
    
    ### What Can Be Inspected
    - All loaded skills and their metadata
    - Version information
    - Evolution rules per skill
    - Guarantees and constraints
    
    ### Usage
    Call this skill's behavior to get a full inventory of capabilities.
    
    ### Kairos Module Methods
    - `Kairos.skills` - All loaded skills
    - `Kairos.skill(id)` - Get specific skill
    - `Kairos.config` - Current configuration
    - `Kairos.evolution_enabled?` - Check if evolution is on
  MD
end

# =============================================================================
# CHAIN AWARENESS - Understands blockchain state
# =============================================================================
skill :chain_awareness do
  version "1.1"
  title "Chain Awareness"
  
  evolve do
    allow :content
    deny :behavior
  end
  
  behavior do
    # Returns blockchain status
    chain = KairosChain::Chain.new
    blocks = chain.blocks
    {
      block_count: blocks.size,
      is_valid: chain.valid?,
      latest_hash: blocks.last&.hash,
      genesis_timestamp: blocks.first&.timestamp
    }
  end
  
  content <<~MD
    ## Chain Awareness
    
    The ability to understand blockchain state.
    
    ### What Can Be Observed
    - **block_count**: Number of blocks in chain
    - **is_valid**: Whether chain passes integrity check
    - **latest_hash**: Hash of most recent block
    - **genesis_timestamp**: When chain was created
    
    ### Chain Tools
    - `chain_status` - Get current status
    - `chain_verify` - Verify integrity
    - `chain_history` - View block history
    
    ### Recording Behavior
    - L0 changes: Full transaction (skill_id, hashes, timestamp, reason)
    - L1 changes: Hash reference only (content_hash, timestamp)
    - L2 changes: Not recorded
  MD
end

# =============================================================================
# AUDIT RULES - Governs knowledge health checks and archiving (L0-B)
# =============================================================================
skill :audit_rules do
  version "1.0"
  title "Audit Rules"
  
  evolve do
    allow :content          # Rules can be adjusted
    deny :behavior          # Logic is fixed
    deny :guarantees        # Human oversight guarantee is fixed
  end
  
  guarantees do
    human_oversight
  end
  
  behavior do
    # Returns audit configuration
    {
      require_human_approval: {
        archive: true,
        unarchive: true,
        bulk_cleanup: true
      },
      auto_allowed: {
        check: true,
        conflicts: true,
        stale: true,
        dangerous: true,
        recommend: true
      },
      staleness_thresholds: {
        l0: { check_date: false },
        l1: { check_date: true, days: 180 },
        l2: { check_date: true, days: 14 }
      },
      assembly_defaults: {
        mode: 'oneshot',
        facilitator: 'kairos',
        max_rounds: 3,
        consensus_threshold: 0.6
      }
    }
  end
  
  content <<~MD
    ## Audit Rules
    
    Rules governing knowledge health checks, archiving, and promotion recommendations.
    
    ### Core Principle
    
    **Audit functions are advisory only and do not have authority to execute changes.**
    
    All modification actions require human confirmation and approval.
    
    ### Permission Matrix
    
    | Action | Auto-Execute | Human Approval |
    |--------|-------------|----------------|
    | check | OK | - |
    | conflicts | OK | - |
    | stale | OK | - |
    | dangerous | OK | - |
    | recommend | OK | - |
    | archive | - | Required |
    | unarchive | - | Required |
    | bulk_cleanup | - | Required |
    
    ### Staleness Thresholds (Configurable)
    
    | Layer | Threshold | Date Check |
    |-------|-----------|------------|
    | L0 | N/A | No (stability is valued) |
    | L1 | 180 days | Yes |
    | L2 | 14 days | Yes |
    
    ### L0 Staleness Policy
    
    L0 skills are intentionally stable and rarely modified.
    Age indicates maturity, not staleness.
    
    L0 checks instead:
    - External reference validity
    - Internal consistency with L1
    - Deprecated pattern detection
    
    ### Why L0-B?
    
    This rule is important but may need adjustment based on team or situation:
    - Threshold adjustments (90 days vs 180 days)
    - Expansion/reduction of auto-execution scope
    - Addition of new check items
    
    However, changes require human approval and all changes are recorded to blockchain.
    
    ### Modifying These Rules
    
    Use `skills_evolve` to modify the content of this skill:
    
    ```
    skills_evolve(
      command: "propose",
      skill_id: "audit_rules",
      definition: "...",
      approved: true  # After human review
    )
    ```
    
    ### Assembly Modes
    
    Persona Assembly supports two modes for different use cases:
    
    | Mode | Default | Use Case |
    |------|---------|----------|
    | oneshot | Yes | Routine checks, simple decisions |
    | discussion | No | Important decisions, deep analysis |
    
    ### Discussion Mode Settings (Configurable)
    
    | Setting | Default | Description |
    |---------|---------|-------------|
    | facilitator | kairos | Discussion moderator persona |
    | max_rounds | 3 | Maximum discussion rounds |
    | consensus_threshold | 0.6 | Early termination threshold (60%) |
    
    ### When to Use Discussion Mode
    
    - L1 to L0 promotion (important meta-rule changes)
    - Conflict resolution between knowledge items
    - Archive decisions for widely-used knowledge
    - Any decision with significant impact
    
    For routine checks, oneshot mode is recommended for efficiency.
  MD
end
