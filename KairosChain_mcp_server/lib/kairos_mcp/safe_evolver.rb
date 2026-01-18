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
    
    def self.propose(skill_id:, new_definition:)
      unless SkillsConfig.evolution_enabled?
        return { success: false, error: "Evolution is disabled. Set 'evolution_enabled: true' in config." }
      end

      # Layer validation: Only Kairos meta-skills can be in L0 (skills/kairos.rb)
      layer_check = validate_layer_constraint(skill_id)
      return layer_check unless layer_check[:success]
      
      skill = Kairos.skill(skill_id)
      if skill && skill.evolution_rules
        rules = skill.evolution_rules
        if rules.denied.include?(:all) || (rules.denied.include?(:behavior) && rules.denied.include?(:content))
          return { success: false, error: "Skill '#{skill_id}' has evolution rules that deny modification." }
        end
      end
      
      immutable = SkillsConfig.load['immutable_skills'] || []
      if immutable.include?(skill_id.to_s)
        return { success: false, error: "Skill '#{skill_id}' is immutable and cannot be modified." }
      end
      
      max_evolutions = SkillsConfig.load['max_evolutions_per_session'] || 3
      if @@evolution_count >= max_evolutions
        return { success: false, error: "Evolution limit reached (#{max_evolutions}/session). Reset required." }
      end
      
      validation = validate_in_sandbox(new_definition)
      return validation unless validation[:success]
      
      { 
        success: true, 
        preview: new_definition,
        message: "Proposal validated. Use 'apply' command with approved=true to apply."
      }
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
        
        { success: true, message: "Skill '#{skill_id}' added successfully and recorded on KairosChain." }
      rescue => e
        VersionManager.rollback(snapshot)
        Kairos.reload!
        { success: false, error: "Failed to add skill: #{e.message}" }
      end
    end
    
    private

    # Validate that a skill can be placed in L0 (skills/kairos.rb)
    # Only Kairos meta-skills are allowed in L0
    def self.validate_layer_constraint(skill_id)
      unless SkillsConfig.kairos_meta_skill?(skill_id)
        meta_skills = SkillsConfig.kairos_meta_skills.join(', ')
        return {
          success: false,
          error: "Skill '#{skill_id}' is not a Kairos meta-skill. " \
                 "Only the following skills can be placed in L0 (skills/kairos.rb): #{meta_skills}. " \
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
  end
end
