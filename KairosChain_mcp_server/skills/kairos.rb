# KairosChain Meta-Skills Definition
# This file contains L0 (Law layer) meta-skills that govern self-modification.
# Only Kairos meta-skills can be placed here.

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
  MD
end

# =============================================================================
# APPROVAL WORKFLOW - Manages the approval process
# =============================================================================
skill :approval_workflow do
  version "1.0"
  title "Approval Workflow"
  
  evolve do
    allow :content
    deny :behavior
  end
  
  behavior do
    # Returns current approval configuration
    config = KairosMcp::SkillsConfig.load
    {
      evolution_enabled: KairosMcp::SkillsConfig.evolution_enabled?,
      require_human_approval: config['require_human_approval'],
      evolution_count: KairosMcp::SafeEvolver.evolution_count,
      max_per_session: config['max_evolutions_per_session'],
      immutable_skills: config['immutable_skills']
    }
  end
  
  content <<~MD
    ## Approval Workflow
    
    ### Stages
    1. **Propose**: AI suggests a change via skills_evolve
       - Syntax validation
       - Constraint checking
       - Preview generation
    
    2. **Review**: Human reviews the proposal
       - Only when require_human_approval: true
       - Examine preview and reason
    
    3. **Apply**: Execute with approved=true
       - Creates version snapshot
       - Applies change to file
       - Records to blockchain
    
    4. **Verify**: Confirm success
       - Check chain_history
       - Verify with skills_dsl_get
    
    ### Configuration (skills/config.yml)
    ```yaml
    evolution_enabled: false      # Must be true to evolve
    require_human_approval: true  # Human must approve L0 changes
    max_evolutions_per_session: 3 # Limit per session
    immutable_skills: [core_safety]
    ```
    
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
