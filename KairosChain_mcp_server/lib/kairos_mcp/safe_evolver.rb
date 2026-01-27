require_relative 'skills_config'
require_relative 'version_manager'
require_relative 'action_log'
require_relative 'skills_dsl'
require_relative 'kairos'
require_relative 'kairos_chain/chain'
require_relative 'kairos_chain/skill_transition'
require_relative 'layer_registry'

module KairosMcp
  class SafeEvolver
    class EvolutionError < StandardError; end
    class LayerViolationError < EvolutionError; end
    
    DSL_PATH = File.expand_path('../../skills/kairos.rb', __dir__)
    
    # Session counter for evolution limits
    @@evolution_count = 0
    
    def self.reset_session!
      @@evolution_count = 0
    end

    def self.evolution_count
      @@evolution_count
    end
    
    def self.propose(skill_id:, new_definition:, reason: nil)
      # Run L0 Auto-Check (defined in approval_workflow skill for Pure Agent Skill compliance)
      auto_check_result = run_l0_auto_check(skill_id: skill_id, definition: new_definition, reason: reason)
      
      # If mechanical checks failed, return immediately with check results
      unless auto_check_result[:mechanical_passed]
        return { 
          success: false, 
          error: auto_check_result[:summary],
          auto_check: auto_check_result
        }
      end
      
      # Additional sandbox validation
      validation = validate_in_sandbox(new_definition)
      return validation unless validation[:success]
      
      { 
        success: true, 
        preview: new_definition,
        message: "Proposal validated. Use 'apply' command with approved=true to apply.",
        auto_check: auto_check_result
      }
    end
    
    # Run the auto-check logic defined in L0 (approval_workflow skill)
    # This keeps the check criteria within L0 for Pure Agent Skill compliance
    def self.run_l0_auto_check(skill_id:, definition:, reason: nil)
      approval_workflow = Kairos.skill(:approval_workflow)
      
      unless approval_workflow&.behavior
        # Fallback if approval_workflow skill not loaded
        return {
          passed: true,
          mechanical_passed: true,
          human_review_needed: 0,
          checks: [],
          summary: "Warning: approval_workflow skill not loaded. Skipping auto-check."
        }
      end
      
      begin
        workflow_data = approval_workflow.behavior.call
        auto_check = workflow_data[:auto_check]
        
        if auto_check
          auto_check.call(skill_id: skill_id, definition: definition, reason: reason)
        else
          {
            passed: true,
            mechanical_passed: true,
            human_review_needed: 0,
            checks: [],
            summary: "Warning: auto_check not available in approval_workflow."
          }
        end
      rescue StandardError => e
        {
          passed: false,
          mechanical_passed: false,
          human_review_needed: 0,
          checks: [],
          summary: "Auto-check error: #{e.message}"
        }
      end
    end
    
    def self.apply(skill_id:, new_definition:, approved: false)
      config = SkillsConfig.load
      
      if config['require_human_approval'] && !approved
        return { 
          success: false, 
          error: "Human approval required. Set approved=true to confirm.",
          pending: true 
        }
      end
      
      unless SkillsConfig.evolution_enabled?
        return { success: false, error: "Evolution is disabled." }
      end

      # Layer validation: Only Kairos meta-skills can be in L0 (skills/kairos.rb)
      layer_check = validate_layer_constraint(skill_id)
      return layer_check unless layer_check[:success]
      
      skill = Kairos.skill(skill_id)
      if skill && skill.evolution_rules
        rules = skill.evolution_rules
        if rules.denied.include?(:all)
          return { success: false, error: "Skill '#{skill_id}' denies all evolution." }
        end
      end
      
      validation = validate_in_sandbox(new_definition)
      return validation unless validation[:success]
      
      snapshot = VersionManager.create_snapshot(reason: "before evolving #{skill_id}")
      prev_content = File.read(DSL_PATH)
      
      begin
        # Apply the change
        new_content = apply_change_to_content(prev_content, skill_id, new_definition)
        File.write(DSL_PATH, new_content)
        
        # Record to Blockchain
        record_transition(skill_id, prev_content, new_content, snapshot)
        
        @@evolution_count += 1
        Kairos.reload!
        
        ActionLog.record(
          action: 'skill_evolved',
          skill_id: skill_id,
          details: { 
            new_definition: new_definition[0, 500],
            snapshot: snapshot,
            evolution_count: @@evolution_count
          }
        )
        
        # Track pending change for state commit
        track_pending_change(layer: 'L0', action: 'update', skill_id: skill_id, reason: "Skill evolved")
        
        { success: true, message: "Skill '#{skill_id}' evolved successfully and recorded on KairosChain. Snapshot: #{snapshot}" }
      rescue => e
        VersionManager.rollback(snapshot)
        Kairos.reload!
        { success: false, error: "Evolution failed and rolled back: #{e.message}" }
      end
    end
    
    def self.add_skill(skill_id:, definition:, approved: false)
      config = SkillsConfig.load
      
      if config['require_human_approval'] && !approved
        return { success: false, error: "Human approval required.", pending: true }
      end
      
      unless SkillsConfig.evolution_enabled?
        return { success: false, error: "Evolution is disabled." }
      end

      # Layer validation: Only Kairos meta-skills can be added to L0 (skills/kairos.rb)
      layer_check = validate_layer_constraint(skill_id)
      return layer_check unless layer_check[:success]
      
      if Kairos.skill(skill_id)
        return { success: false, error: "Skill '#{skill_id}' already exists. Use 'propose' to modify." }
      end
      
      full_definition = "skill :#{skill_id} do\n#{definition}\nend"
      validation = validate_in_sandbox(full_definition)
      return validation unless validation[:success]
      
      snapshot = VersionManager.create_snapshot(reason: "before adding #{skill_id}")
      prev_content = File.read(DSL_PATH)
      
      begin
        File.open(DSL_PATH, 'a') do |f|
          f.puts "\n#{full_definition}"
        end
        
        new_content = File.read(DSL_PATH)
        record_transition(skill_id, prev_content, new_content, snapshot)
        
        @@evolution_count += 1
        Kairos.reload!
        
        ActionLog.record(
          action: 'skill_added',
          skill_id: skill_id,
          details: { snapshot: snapshot }
        )
        
        # Track pending change for state commit
        track_pending_change(layer: 'L0', action: 'create', skill_id: skill_id, reason: "Skill added")
        
        { success: true, message: "Skill '#{skill_id}' added successfully and recorded on KairosChain." }
      rescue => e
        VersionManager.rollback(snapshot)
        Kairos.reload!
        { success: false, error: "Failed to add skill: #{e.message}" }
      end
    end
    
    private

    # Get L0 governance configuration from the l0_governance skill itself
    # This implements the Pure Agent Skill principle: L0 rules are in L0
    # Falls back to config.yml only during bootstrapping
    def self.l0_governance_config
      # Try to get from l0_governance skill first (canonical source)
      governance_skill = Kairos.skill(:l0_governance)
      if governance_skill&.behavior
        begin
          return governance_skill.behavior.call
        rescue StandardError => e
          warn "[SafeEvolver] Failed to evaluate l0_governance behavior: #{e.message}"
        end
      end
      
      # Fallback to config.yml (for bootstrapping or if skill not loaded)
      {
        allowed_skills: SkillsConfig.kairos_meta_skills.map(&:to_sym),
        immutable_skills: (SkillsConfig.load['immutable_skills'] || ['core_safety']).map(&:to_sym),
        require_human_approval: SkillsConfig.load['require_human_approval']
      }
    end

    # Get allowed L0 skills from l0_governance (or fallback)
    def self.allowed_l0_skills
      l0_governance_config[:allowed_skills] || []
    end

    # Get immutable skills from l0_governance (or fallback)
    def self.immutable_l0_skills
      l0_governance_config[:immutable_skills] || [:core_safety]
    end

    # Check if a skill is allowed in L0
    def self.l0_allowed_skill?(skill_id)
      allowed_l0_skills.include?(skill_id.to_sym)
    end

    # Check if a skill is immutable
    def self.l0_immutable_skill?(skill_id)
      immutable_l0_skills.include?(skill_id.to_sym)
    end

    # Validate that a skill can be placed in L0 (skills/kairos.rb)
    # Only Kairos meta-skills are allowed in L0
    # Now reads from l0_governance skill itself (Pure Agent Skill compliance)
    def self.validate_layer_constraint(skill_id)
      unless l0_allowed_skill?(skill_id)
        allowed = allowed_l0_skills.join(', ')
        return {
          success: false,
          error: "Skill '#{skill_id}' is not allowed in L0. " \
                 "Allowed L0 skills (from l0_governance): #{allowed}. " \
                 "To add a new skill type to L0, first evolve the l0_governance skill. " \
                 "For project-specific knowledge, use the L1 knowledge layer (knowledge_update tool)."
        }
      end

      { success: true }
    end

    # Check compatibility with L1 knowledge references (if any)
    def self.check_knowledge_compatibility(definition)
      # Future: Parse definition to find knowledge references and validate
      # For now, just return success
      { success: true }
    end
    
    def self.validate_in_sandbox(definition)
      begin
        RubyVM::AbstractSyntaxTree.parse(definition)
        test_dsl = SkillsDsl.new
        test_dsl.instance_eval(definition)
        { success: true }
      rescue SyntaxError => e
        { success: false, error: "Syntax error: #{e.message}" }
      rescue StandardError => e
        { success: false, error: "Validation error: #{e.message}" }
      end
    end
    
    def self.apply_change_to_content(content, skill_id, new_definition)
      pattern = /skill\s+:#{skill_id}\s+do.*?^end/m
      if content.match?(pattern)
        content.gsub(pattern, new_definition)
      else
        content + "\n#{new_definition}"
      end
    end
    
    def self.record_transition(skill_id, prev_content, new_content, snapshot)
      prev_hash = Digest::SHA256.hexdigest(prev_content)
      next_hash = Digest::SHA256.hexdigest(new_content)
      diff_hash = Digest::SHA256.hexdigest(prev_content + new_content) # Simplified diff hash
      
      transition = KairosChain::SkillTransition.new(
        skill_id: skill_id,
        prev_ast_hash: prev_hash,
        next_ast_hash: next_hash,
        diff_hash: diff_hash,
        reason_ref: snapshot
      )
      
      chain = KairosChain::Chain.new
      chain.add_block([transition.to_json])
    end

    # Track pending change for state commit auto-commit
    def self.track_pending_change(layer:, action:, skill_id:, reason: nil)
      return unless SkillsConfig.state_commit_enabled?

      require_relative 'state_commit/pending_changes'
      require_relative 'state_commit/commit_service'

      StateCommit::PendingChanges.add(
        layer: layer,
        action: action,
        skill_id: skill_id,
        reason: reason
      )

      # Check if auto-commit should be triggered
      if SkillsConfig.state_commit_auto_enabled?
        service = StateCommit::CommitService.new
        service.check_and_auto_commit
      end
    rescue StandardError => e
      # Log but don't fail if state commit tracking fails
      warn "[SafeEvolver] Failed to track pending change: #{e.message}"
    end
  end
end
