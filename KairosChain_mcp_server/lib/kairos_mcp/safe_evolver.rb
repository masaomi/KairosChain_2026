require_relative 'skills_config'
require_relative 'version_manager'
require_relative 'action_log'
require_relative 'skills_dsl'
require_relative 'kairos'
require_relative 'kairos_chain/chain'
require_relative 'kairos_chain/skill_transition'
require_relative 'kairos_chain/landed_probe'
require_relative 'layer_registry'
require_relative 'l0_proposal_store'
require_relative '../kairos_mcp'

module KairosMcp
  class SafeEvolver
    class EvolutionError < StandardError; end
    class LayerViolationError < EvolutionError; end
    
    # Session counter for evolution limits
    @@evolution_count = 0
    
    def self.reset_session!
      @@evolution_count = 0
    end

    def self.evolution_count
      @@evolution_count
    end
    
    def self.propose(skill_id:, new_definition:, reason: nil)
      # Stores the proposal once the L0 auto-check admits it. Nothing is
      # evaluated and L0 is not touched.
      stored = store_proposal(skill_id: skill_id, kind: 'evolve', definition: new_definition, reason: reason)
      return stored unless stored[:success]

      stored.merge(preview: new_definition)
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
    
    def self.apply(skill_id: nil, new_definition: nil, approved: false, proposal_id: nil, reason: nil)
      config = SkillsConfig.load

      if config['require_human_approval'] && !approved
        # Unapproved: store a pending proposal, evaluate nothing, write nothing.
        if proposal_id.nil? && skill_id && new_definition
          stored = store_proposal(skill_id: skill_id, kind: 'evolve', definition: new_definition, reason: reason)
          return stored unless stored[:success]

          proposal_id = stored[:proposal_id]
        end

        return {
          success: false,
          error: proposal_id ? "Human approval required. Re-run with proposal_id=#{proposal_id} and approved=true." : "Human approval required. Set approved=true to confirm.",
          proposal_id: proposal_id,
          pending: true
        }
      end

      unless SkillsConfig.evolution_enabled?
        return { success: false, error: "Evolution is disabled." }
      end

      if proposal_id
        proposal = L0ProposalStore.load(proposal_id)
        return { success: false, error: "No such proposal: '#{proposal_id}'." } unless proposal
      else
        unless skill_id && new_definition
          return { success: false, error: "proposal_id, or skill_id and new_definition, are required." }
        end

        # propose-then-apply in one call
        stored = store_proposal(skill_id: skill_id, kind: 'evolve', definition: new_definition, reason: reason)
        return stored unless stored[:success]

        proposal = L0ProposalStore.load(stored[:proposal_id])
      end

      target_id = proposal['skill_id']

      # A return goes back to content that was already in force in L0, so the
      # layer and deny checks below do not apply to it. The gate and the stale
      # check above do, and are untouched.
      return commit_proposal(proposal) if proposal['kind'] == 'restore'

      # Layer validation: Only Kairos meta-skills can be in L0 (skills/kairos.rb)
      layer_check = validate_layer_constraint(target_id)
      return layer_check unless layer_check[:success]

      # Checked against the L0 currently in force, at apply time.
      skill = Kairos.skill(target_id)
      if skill && skill.evolution_rules
        rules = skill.evolution_rules
        if rules.denied.include?(:all)
          return { success: false, error: "Skill '#{target_id}' denies all evolution." }
        end
      end

      commit_proposal(proposal)
    end
    
    def self.add_skill(skill_id:, definition:, approved: false, reason: nil)
      config = SkillsConfig.load
      full_definition = "skill :#{skill_id} do\n#{definition}\nend"

      if config['require_human_approval'] && !approved
        # Unapproved: store a pending proposal, evaluate nothing, write nothing.
        stored = store_proposal(skill_id: skill_id, kind: 'add', definition: full_definition, reason: reason)
        return stored unless stored[:success]

        return {
          success: false,
          error: "Human approval required. Re-run apply with proposal_id=#{stored[:proposal_id]} and approved=true.",
          proposal_id: stored[:proposal_id],
          pending: true
        }
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

      stored = store_proposal(skill_id: skill_id, kind: 'add', definition: full_definition, reason: reason)
      return stored unless stored[:success]

      commit_proposal(L0ProposalStore.load(stored[:proposal_id]))
    end
    
    # Propose returning L0 to the content of a stored snapshot. Nothing is
    # written here: the write goes through apply (gate + stale check + load check).
    def self.propose_restore(version:, reason: nil)
      path = VersionManager.version_path(version)
      current = File.read(KairosMcp.dsl_path)
      bytes = File.read(path)

      if bytes == current
        return { success: false, error: "Snapshot #{version} is identical to the current content" }
      end

      base = Digest::SHA256.hexdigest(current)
      result = Digest::SHA256.hexdigest(bytes)

      # F2a: a snapshot is a return to a definition that was once in force only
      # when its own bytes appear in a recorded transition. A file that merely
      # sits in the versions directory proves nothing — it may have been written
      # there by hand, in which case restoring it is an unreviewed change and
      # has to go through the ordinary evolution path instead. Nothing is stored
      # on this refusal.
      unless recorded_l0_hash?(result)
        return {
          success: false,
          error: "Snapshot #{version} (sha256 #{result}) does not appear in any recorded transition, " \
                 "so it was never in force. Submit this content through skills_evolve instead."
        }
      end

      id = L0ProposalStore.save(skill_id: 'kairos.rb', kind: 'restore',
                                base: base, result: result, content: bytes,
                                reason: "snapshot #{version}#{reason ? ": #{reason}" : ''}",
                                snapshot: version)

      {
        success: true,
        proposal_id: id,
        base: base,
        result: result,
        pending: true,
        snapshot: version,
        message: "Restore proposal #{id} created from snapshot #{version}. Approval required to apply."
      }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # True when the given sha256 appears as either side of a recorded transition
    # of the core definition. Each block carries `data` as an array of JSON
    # strings; an entry counts as such a transition when the parsed Hash has a
    # `prev_ast_hash` and its `skill_id` is not an instruction-mode record.
    def self.recorded_l0_hash?(hash)
      blocks = begin
        KairosChain::Chain.new.chain
      rescue StandardError
        return false
      end

      blocks.each do |block|
        entries = block.data
        next unless entries.is_a?(Array)

        entries.each do |entry|
          parsed = begin
            JSON.parse(entry.to_s)
          rescue StandardError
            next
          end
          next unless parsed.is_a?(Hash)
          next unless parsed.key?('prev_ast_hash')
          next if parsed['skill_id'].to_s.start_with?('instructions:')

          return true if parsed['prev_ast_hash'] == hash || parsed['next_ast_hash'] == hash
        end
      end

      false
    end
    private_class_method :recorded_l0_hash?

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
    
    # Parse only. Submitting a proposal never evaluates its code; the first
    # evaluation happens past the approval gate, when commit_proposal loads
    # the written L0.
    def self.validate_in_sandbox(definition)
      begin
        RubyVM::AbstractSyntaxTree.parse(definition)
        { success: true }
      rescue SyntaxError => e
        { success: false, error: "Syntax error: #{e.message}" }
      rescue StandardError => e
        { success: false, error: "Validation error: #{e.message}" }
      end
    end

    def self.pending_proposals
      L0ProposalStore.pending
    end

    # Computes the complete resulting L0 bytes and stores them as a pending
    # proposal keyed by (base, result).
    def self.store_proposal(skill_id:, kind:, definition:, reason: nil)
      validation = validate_in_sandbox(definition)
      return validation unless validation[:success]

      # Admissibility is judged by the L0 in force, reading the proposal as
      # data: the approval_workflow auto-check (defined in L0 for Pure Agent
      # Skill compliance), the layer constraint, and for an addition that the
      # skill does not exist yet. Only an admissible proposal is stored.
      auto_check_result = run_l0_auto_check(skill_id: skill_id, definition: definition, reason: reason)
      unless auto_check_result[:mechanical_passed]
        return { success: false, error: auto_check_result[:summary], auto_check: auto_check_result }
      end

      layer_check = validate_layer_constraint(skill_id)
      return layer_check unless layer_check[:success]

      if kind == 'add' && Kairos.skill(skill_id)
        return { success: false, error: "Skill '#{skill_id}' already exists. Use 'propose' to modify." }
      end

      current = File.read(KairosMcp.dsl_path)
      resulting =
        if kind == 'add'
          # Matches the previous append: a blank line, the definition, a newline.
          "#{current}\n#{definition}\n"
        else
          apply_change_to_content(current, skill_id, definition)
        end

      base = Digest::SHA256.hexdigest(current)
      result = Digest::SHA256.hexdigest(resulting)
      id = L0ProposalStore.save(
        skill_id: skill_id,
        kind: kind,
        base: base,
        result: result,
        content: resulting,
        reason: reason
      )

      {
        success: true,
        proposal_id: id,
        base: base,
        result: result,
        pending: true,
        auto_check: auto_check_result,
        message: "Proposal '#{id}' stored and pending. Apply with command=apply, proposal_id=#{id}, approved=true."
      }
    end

    # Writes a stored proposal to L0. The transition is recorded only after the
    # written file has actually loaded and carries the target skill.
    def self.commit_proposal(proposal)
      adding = proposal['kind'] == 'add'
      skill_id = proposal['skill_id']

      if proposal['applied_at']
        return { success: false, proposal_id: proposal['id'],
                 error: "Proposal '#{proposal['id']}' was already applied." }
      end

      # One exclusive lock covers the base check, the write, the load and the
      # chain record, so two applies computed on the same base cannot both pass
      # their own base check. The lock file is opened fresh on every call on
      # purpose: flock is held by the open file description, not by the thread,
      # so a cached handle would make the lock a no-op for two threads in one
      # process.
      lock_path = File.join(KairosMcp.storage_dir, 'l0_apply.lock')
      FileUtils.mkdir_p(KairosMcp.storage_dir)

      snapshot = nil
      outcome = nil

      File.open(lock_path, File::CREAT | File::RDWR, 0o644) do |lock|
        lock.flock(File::LOCK_EX)

        # Read the base inside the lock. A read taken before the lock could
        # observe bytes that another apply is about to replace.
        prev_content = File.read(KairosMcp.dsl_path)
        prev_hash = Digest::SHA256.hexdigest(prev_content)

        unless prev_hash == proposal['base']
          outcome = { success: false, stale: true, proposal_id: proposal['id'],
                      error: "Proposal '#{proposal['id']}' is stale: L0 has changed since it was computed. Submit a new proposal." }
          next
        end

        new_content = proposal['content']
        unless new_content.is_a?(String) && Digest::SHA256.hexdigest(new_content) == proposal['result']
          outcome = { success: false, proposal_id: proposal['id'],
                      error: "Proposal '#{proposal['id']}' content does not hash to its result. Nothing was written." }
          next
        end

        # A restore skips the layer, deny and auto checks because it returns to
        # content that was already in force. That exemption rests on the result
        # appearing in a recorded transition, so it is decided here, inside the
        # lock, from the chain -- never from the `kind` a stored file claims.
        if proposal['kind'] == 'restore' && !recorded_l0_hash?(proposal['result'])
          outcome = { success: false, proposal_id: proposal['id'],
                      error: "Restore proposal '#{proposal['id']}' targets #{proposal['result']}, which appears in no recorded transition. Nothing was written." }
          next
        end

        snapshot = VersionManager.create_snapshot(reason: "before #{adding ? 'adding' : 'evolving'} #{skill_id}")
        reason_ref = if proposal['kind'] == 'restore'
                       "restore: returned to content of hash #{proposal['result']} (#{proposal['reason']})"
                     else
                       snapshot
                     end
        entry = transition_entry(skill_id, prev_content, new_content, reason_ref)
        mark = nil
        attempted = false
        landed = nil # memo of the probe's answer, so it is asked at most once
        probe = -> { landed ||= KairosChain::LandedProbe.status(mark, entry) }
        recorded = false
        failure = nil

        begin
          File.write(KairosMcp.dsl_path, new_content)
          unless Digest::SHA256.hexdigest(File.read(KairosMcp.dsl_path)) == proposal['result']
            raise 'written bytes do not hash to the proposed result'
          end

          loaded = SkillsDsl.load(KairosMcp.dsl_path)
          if proposal['kind'] != 'restore' && loaded.none? { |s| s.id.to_s == skill_id.to_s }
            raise "skill '#{skill_id}' is not present in the loaded L0"
          end

          mark = KairosChain::LandedProbe.mark
          attempted = true
          begin
            record_transition(entry)
          rescue StandardError => e
            # The append did not return normally. Ask the chain whether this
            # transition is on it rather than assume either way; a record that
            # landed must not be reverted.
            raise e unless probe.call == :landed
          end
          recorded = true

          Kairos.reload!
          outcome = :committed
        rescue StandardError, ScriptError => e
          failure = e
        ensure
          # The revert lives in ensure, not rescue: Thread#kill and Thread.exit
          # unwind through ensure only, and SystemExit, SystemStackError or a
          # signal must not leave an unrecorded L0 on disk either. Those still
          # propagate after the revert. The revert is skipped once the record is
          # known to have landed; an unknown answer counts as not landed.
          unless recorded
            begin
              recorded = attempted && probe.call == :landed
            ensure
              unless recorded
                File.write(KairosMcp.dsl_path, prev_content)
                begin
                  Kairos.reload!
                rescue StandardError, ScriptError => re
                  warn "[SafeEvolver] L0 reverted; reload after revert failed: #{re.message}"
                end
              end
            end
          end
        end

        if failure
          outcome = { success: false, proposal_id: proposal['id'],
                      error: recorded ? "Evolution was recorded but did not complete: #{failure.message}" : "Evolution failed and reverted: #{failure.message}" }
        end
      end

      return outcome unless outcome == :committed

      # finish_commit runs after the lock is released.
      finish_commit(proposal, adding, skill_id, snapshot)
    end

    # Bookkeeping after a recorded transition. A failure here is reported but
    # never reverts the L0 that the chain already records as in force.
    def self.finish_commit(proposal, adding, skill_id, snapshot)
      begin
        L0ProposalStore.mark_applied(proposal['id'])
        @@evolution_count += 1

        ActionLog.record(
          action: proposal['kind'] == 'restore' ? 'l0_restored' : (adding ? 'skill_added' : 'skill_evolved'),
          skill_id: skill_id,
          details: {
            proposal_id: proposal['id'],
            base: proposal['base'],
            result: proposal['result'],
            snapshot: snapshot,
            evolution_count: @@evolution_count
          }
        )

        # Track pending change for state commit
        track_pending_change(
          layer: 'L0',
          action: adding ? 'create' : 'update',
          skill_id: skill_id,
          reason: adding ? "Skill added" : "Skill evolved"
        )
      rescue StandardError => e
        warn "[SafeEvolver] Transition recorded; bookkeeping failed: #{e.message}"
      end

      {
        success: true,
        proposal_id: proposal['id'],
        message: proposal['kind'] == 'restore' ?
          "L0 restored to #{proposal['result']} and recorded on KairosChain. Snapshot: #{snapshot}" :
          "Skill '#{skill_id}' #{adding ? 'added' : 'evolved'} successfully and recorded on KairosChain. Snapshot: #{snapshot}"
      }
    end

    def self.apply_change_to_content(content, skill_id, new_definition)
      pattern = /skill\s+:#{Regexp.escape(skill_id.to_s)}\s+do.*?^end/m
      match = pattern.match(content)
      return "#{content}\n#{new_definition}" unless match

      # Literal splice over the matched byte range. The definition is never a
      # gsub/sub replacement string, which would expand \0, \&, \\ and \'.
      "#{content[0, match.begin(0)]}#{new_definition}#{content[match.end(0)..]}"
    end

    # The transition entry is built before the append so that, if the append
    # does not return normally, the chain can be searched for this exact entry.
    def self.transition_entry(skill_id, prev_content, new_content, reason_ref)
      prev_hash = Digest::SHA256.hexdigest(prev_content)
      next_hash = Digest::SHA256.hexdigest(new_content)
      diff_hash = Digest::SHA256.hexdigest(prev_content + new_content) # Simplified diff hash

      KairosChain::SkillTransition.new(
        skill_id: skill_id,
        prev_ast_hash: prev_hash,
        next_ast_hash: next_hash,
        diff_hash: diff_hash,
        reason_ref: reason_ref
      ).to_json
    end

    def self.record_transition(entry)
      KairosChain::Chain.new.add_block([entry])
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
        service = StateCommit::CommitService.new(user_context: Thread.current[:kairos_user_context])
        service.check_and_auto_commit
      end
    rescue StandardError => e
      # Log but don't fail if state commit tracking fails
      warn "[SafeEvolver] Failed to track pending change: #{e.message}"
    end
  end
end
