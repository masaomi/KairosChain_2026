# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'
require_relative '../context_manager'
require_relative '../dsl_skills_provider'
require_relative '../skills_config'
require_relative '../kairos'

module KairosMcp
  module Tools
    # SkillsAudit: Tool for auditing knowledge health across L0/L1/L2 layers
    #
    # Provides:
    # - Health checks (conflicts, staleness, dangerous patterns)
    # - Promotion/archive recommendations
    # - Archive management (with human approval)
    # - Optional Persona Assembly for deeper analysis
    #
    class SkillsAudit < BaseTool
      # Layer-specific staleness rules
      # L0: No date-based staleness (stability is valued)
      # L1: 180 days threshold
      # L2: 14 days threshold
      STALENESS_RULES = {
        'L0' => {
          check_date: false,
          checks: %i[external_refs internal_consistency deprecated_patterns]
        },
        'L1' => {
          check_date: true,
          threshold_days: 180,
          checks: %i[version_refs usage_frequency]
        },
        'L2' => {
          check_date: true,
          threshold_days: 14,
          checks: %i[session_validity orphaned]
        }
      }.freeze

      READONLY_COMMANDS = %w[check conflicts stale dangerous recommend gaps export_needs].freeze
      WRITE_COMMANDS = %w[archive unarchive].freeze

      def name
        'skills_audit'
      end

      def description
        'Audit knowledge health across L0/L1/L2 layers. Check for conflicts, staleness, ' \
        'dangerous patterns, get promotion/archive recommendations, and detect knowledge gaps ' \
        'defined by custom instruction mode policies. ' \
        'Archive operations require human approval (approved: true).'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[audit health check recommend archive stale dangerous gaps needs meeting knowledge-policy L0 L1 L2]
      end

      def examples
        [
          {
            title: 'Full health check',
            code: 'skills_audit(command: "check")'
          },
          {
            title: 'Check for dangerous patterns',
            code: 'skills_audit(command: "dangerous")'
          },
          {
            title: 'Get promotion recommendations',
            code: 'skills_audit(command: "recommend")'
          },
          {
            title: 'Archive stale knowledge',
            code: 'skills_audit(command: "archive", target: "old_guide", reason: "No longer relevant", approved: true)'
          },
          {
            title: 'Check knowledge gaps for current mode',
            code: 'skills_audit(command: "gaps")'
          },
          {
            title: 'Check knowledge gaps for specific mode',
            code: 'skills_audit(command: "gaps", mode_name: "genomics_expert")'
          },
          {
            title: 'Export knowledge needs for Meeting Place sharing',
            code: 'skills_audit(command: "export_needs")'
          }
        ]
      end

      def related_tools
        %w[skills_promote knowledge_update chain_verify state_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command to execute',
              enum: READONLY_COMMANDS + WRITE_COMMANDS
            },
            layer: {
              type: 'string',
              description: 'Target layer (default: "all")',
              enum: %w[L0 L1 L2 all]
            },
            session_id: {
              type: 'string',
              description: 'Session ID (required for L2 operations)'
            },
            with_assembly: {
              type: 'boolean',
              description: 'Use Persona Assembly for deeper analysis (default: false). Warning: increases token usage.'
            },
            assembly_mode: {
              type: 'string',
              description: 'Assembly mode: "oneshot" (default, single evaluation) or "discussion" (multi-round with facilitator)',
              enum: %w[oneshot discussion]
            },
            personas: {
              type: 'array',
              items: { type: 'string' },
              description: 'Personas for assembly (default: ["archivist", "guardian", "promoter"]). Pre-defined: archivist, guardian, promoter. Custom persona names are also accepted — the LLM will infer the role from the name and context.'
            },
            facilitator: {
              type: 'string',
              description: 'Facilitator persona for discussion mode (default: "kairos")'
            },
            max_rounds: {
              type: 'integer',
              description: 'Maximum discussion rounds for discussion mode (default: 3)'
            },
            consensus_threshold: {
              type: 'number',
              description: 'Consensus threshold for early termination in discussion mode (default: 0.6 = 60%)'
            },
            target: {
              type: 'string',
              description: 'Target knowledge name (for archive/unarchive commands)'
            },
            reason: {
              type: 'string',
              description: 'Reason for archive/unarchive operation'
            },
            approved: {
              type: 'boolean',
              description: 'Human approval flag (required for archive/unarchive)'
            },
            include_archived: {
              type: 'boolean',
              description: 'Include archived items in results (default: false)'
            },
            mode_name: {
              type: 'string',
              description: 'Instruction mode name (for gaps command). Defaults to current active mode.'
            }
          },
          required: ['command']
        }
      end

      def call(arguments)
        command = arguments['command']

        if READONLY_COMMANDS.include?(command)
          handle_readonly_command(command, arguments)
        elsif WRITE_COMMANDS.include?(command)
          handle_write_command(command, arguments)
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      # =========================================================================
      # Command Handlers
      # =========================================================================

      def handle_readonly_command(command, args)
        layer = args['layer'] || 'all'
        with_assembly = args['with_assembly'] || false
        assembly_mode = args['assembly_mode'] || 'oneshot'

        output = []

        # Show token warning if assembly is enabled
        if with_assembly
          output << token_warning(args['personas'], assembly_mode, args['max_rounds'])
          output << "---\n"
        end

        # Execute command
        result = case command
                 when 'check'
                   run_health_check(layer, args)
                 when 'conflicts'
                   run_conflict_check(layer, args)
                 when 'stale'
                   run_staleness_check(layer, args)
                 when 'dangerous'
                   run_dangerous_check(layer, args)
                 when 'recommend'
                   run_recommendations(layer, args)
                 when 'gaps'
                   run_gaps_check(args)
                 when 'export_needs'
                   run_export_needs(args)
                 end

        output << result

        # Add Persona Assembly analysis if requested
        if with_assembly
          output << "\n---\n"
          if assembly_mode == 'discussion'
            output << generate_discussion_template(command, args, result)
          else
            output << generate_oneshot_analysis(command, args, result)
          end
        end

        text_content(output.join("\n"))
      end

      def handle_write_command(command, args)
        # Check human approval
        unless args['approved'] == true
          return text_content(pending_approval_message(command, args))
        end

        # Validate target
        target = args['target']
        unless target && !target.empty?
          return text_content("Error: 'target' is required for #{command} command")
        end

        reason = args['reason'] || "#{command.capitalize} via skills_audit"

        case command
        when 'archive'
          execute_archive(target, reason, args)
        when 'unarchive'
          execute_unarchive(target, reason, args)
        end
      end

      # =========================================================================
      # Health Check
      # =========================================================================

      def run_health_check(layer, args)
        output = ["## Audit Report\n"]

        layers = layer == 'all' ? %w[L0 L1 L2] : [layer]
        issues = []
        summaries = []

        layers.each do |l|
          case l
          when 'L0'
            result = check_l0_health
            summaries << "- **L0**: #{result[:count]} skills (#{result[:status]})"
            issues.concat(result[:issues])
          when 'L1'
            result = check_l1_health(args)
            summaries << "- **L1**: #{result[:count]} items (#{result[:status]})"
            issues.concat(result[:issues])
          when 'L2'
            result = check_l2_health(args)
            summaries << "- **L2**: #{result[:count]} contexts (#{result[:status]})"
            issues.concat(result[:issues])
          end
        end

        output << "### Summary\n"
        output << summaries.join("\n")
        output << "\n"

        if issues.empty?
          output << "\n### Status: All Healthy\n"
          output << "No issues found across checked layers."
        else
          output << "\n### Issues Found (#{issues.size})\n"
          issues.each do |issue|
            output << format_issue(issue)
          end
        end

        # Add recommendations
        recommendations = generate_quick_recommendations(issues)
        unless recommendations.empty?
          output << "\n### Recommended Actions\n"
          recommendations.each_with_index do |rec, i|
            output << "#{i + 1}. #{rec}"
          end
        end

        output.join("\n")
      end

      def check_l0_health
        provider = DslSkillsProvider.new
        skills = provider.list_skills
        issues = []

        # L0 doesn't check date-based staleness
        # Instead check for internal consistency
        skills.each do |skill|
          # Check if skill references deprecated patterns
          full_skill = provider.get_skill(skill[:id])
          next unless full_skill

          if contains_deprecated_patterns?(full_skill.content)
            issues << {
              type: :deprecated_pattern,
              layer: 'L0',
              name: skill[:id].to_s,
              message: 'Contains potentially deprecated patterns'
            }
          end
        end

        status = issues.empty? ? 'all healthy' : "#{issues.size} issues"
        { count: skills.size, status: status, issues: issues }
      end

      def check_l1_health(args)
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        items = provider.list
        issues = []
        threshold_days = STALENESS_RULES['L1'][:threshold_days]

        items.each do |item|
          skill = provider.get(item[:name])
          next unless skill

          # Check staleness based on file modification time
          mtime = File.mtime(skill.md_file_path)
          days_old = ((Time.now - mtime) / 86400).to_i

          if days_old > threshold_days
            issues << {
              type: :stale,
              layer: 'L1',
              name: item[:name],
              message: "Last updated #{days_old} days ago (threshold: #{threshold_days})",
              days_old: days_old
            }
          end

          # Check for version references that might be outdated
          content = File.read(skill.md_file_path)
          if contains_old_version_refs?(content)
            issues << {
              type: :version_ref,
              layer: 'L1',
              name: item[:name],
              message: 'May contain outdated version references'
            }
          end
        end

        status = issues.empty? ? 'all healthy' : "#{issues.size} issues"
        { count: items.size, status: status, issues: issues }
      end

      def check_l2_health(args)
        manager = ContextManager.new(nil, user_context: @safety&.current_user)
        sessions = manager.list_sessions
        issues = []
        threshold_days = STALENESS_RULES['L2'][:threshold_days]
        total_contexts = 0

        sessions.each do |session|
          contexts = manager.list_contexts_in_session(session[:session_id])
          total_contexts += contexts.size

          # Check session age
          days_old = ((Time.now - session[:modified_at]) / 86400).to_i

          if days_old > threshold_days
            issues << {
              type: :stale,
              layer: 'L2',
              name: "session:#{session[:session_id]}",
              message: "Session inactive for #{days_old} days (#{contexts.size} contexts)",
              days_old: days_old,
              context_count: contexts.size
            }
          end
        end

        status = issues.empty? ? 'all healthy' : "#{issues.size} stale sessions"
        { count: total_contexts, status: status, issues: issues }
      end

      # =========================================================================
      # Conflict Check
      # =========================================================================

      def run_conflict_check(layer, args)
        output = ["## Conflict Detection Report\n"]
        conflicts = []

        if %w[L1 all].include?(layer)
          l1_conflicts = detect_l1_conflicts
          conflicts.concat(l1_conflicts)
        end

        if conflicts.empty?
          output << "No conflicts detected."
        else
          output << "### Conflicts Found (#{conflicts.size})\n"
          conflicts.each do |conflict|
            output << "#### #{conflict[:item1]} vs #{conflict[:item2]}"
            output << "- **Type**: #{conflict[:type]}"
            output << "- **Description**: #{conflict[:description]}"
            output << "- **Suggestion**: #{conflict[:suggestion]}\n"
          end
        end

        output.join("\n")
      end

      def detect_l1_conflicts
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        items = provider.list
        conflicts = []

        # Group by tags to find potential conflicts
        tag_groups = Hash.new { |h, k| h[k] = [] }
        items.each do |item|
          item[:tags]&.each do |tag|
            tag_groups[tag] << item[:name]
          end
        end

        # Check groups with multiple items for potential conflicts
        tag_groups.each do |tag, names|
          next if names.size < 2

          # Simple heuristic: items with similar names might conflict
          names.combination(2).each do |name1, name2|
            if similar_names?(name1, name2)
              conflicts << {
                item1: name1,
                item2: name2,
                type: 'similar_topic',
                description: "Both items share tag '#{tag}' and have similar names",
                suggestion: 'Review and merge if redundant, or clarify distinction'
              }
            end
          end
        end

        conflicts
      end

      # =========================================================================
      # Staleness Check
      # =========================================================================

      def run_staleness_check(layer, args)
        output = ["## Staleness Report\n"]
        stale_items = []

        layers = layer == 'all' ? %w[L0 L1 L2] : [layer]

        layers.each do |l|
          rules = STALENESS_RULES[l]

          output << "\n### #{l} Layer\n"

          if !rules[:check_date]
            output << "**Note**: #{l} does not use date-based staleness checks."
            output << "Stability is a feature, not a bug.\n"
            output << "Alternative checks: #{rules[:checks].join(', ')}\n"
          else
            threshold = rules[:threshold_days]
            output << "Threshold: #{threshold} days\n"

            items = case l
                    when 'L1' then find_stale_l1_items(threshold)
                    when 'L2' then find_stale_l2_sessions(threshold, args)
                    else []
                    end

            if items.empty?
              output << "No stale items found.\n"
            else
              output << "**Stale Items (#{items.size})**:\n"
              items.each do |item|
                output << "- `#{item[:name]}` - #{item[:days_old]} days old"
                stale_items << item
              end
              output << "\n"
            end
          end
        end

        output.join("\n")
      end

      def find_stale_l1_items(threshold)
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        items = provider.list
        stale = []

        items.each do |item|
          skill = provider.get(item[:name])
          next unless skill

          mtime = File.mtime(skill.md_file_path)
          days_old = ((Time.now - mtime) / 86400).to_i

          if days_old > threshold
            stale << { name: item[:name], days_old: days_old, layer: 'L1' }
          end
        end

        stale.sort_by { |i| -i[:days_old] }
      end

      def find_stale_l2_sessions(threshold, args)
        manager = ContextManager.new(nil, user_context: @safety&.current_user)
        sessions = manager.list_sessions
        stale = []

        sessions.each do |session|
          days_old = ((Time.now - session[:modified_at]) / 86400).to_i

          if days_old > threshold
            stale << {
              name: "session:#{session[:session_id]}",
              days_old: days_old,
              layer: 'L2',
              context_count: session[:context_count]
            }
          end
        end

        stale.sort_by { |i| -i[:days_old] }
      end

      # =========================================================================
      # Dangerous Check
      # =========================================================================

      def run_dangerous_check(layer, args)
        output = ["## Dangerous Pattern Detection\n"]
        dangers = []

        if %w[L1 all].include?(layer)
          l1_dangers = detect_dangerous_l1
          dangers.concat(l1_dangers)
        end

        if dangers.empty?
          output << "No dangerous patterns detected.\n"
          output << "All knowledge aligns with L0 safety constraints."
        else
          output << "### Potential Issues (#{dangers.size})\n"
          dangers.each do |danger|
            output << "#### [#{danger[:severity].upcase}] #{danger[:name]}"
            output << "- **Issue**: #{danger[:issue]}"
            output << "- **Suggestion**: #{danger[:suggestion]}\n"
          end
        end

        output.join("\n")
      end

      def detect_dangerous_l1
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        items = provider.list
        dangers = []

        items.each do |item|
          skill = provider.get(item[:name])
          next unless skill

          content = File.read(skill.md_file_path)

          # Check for patterns that might contradict L0 safety
          if content =~ /bypass|skip.*approval|ignore.*safety/i
            dangers << {
              name: item[:name],
              severity: :warning,
              issue: 'Contains language that might suggest bypassing safety checks',
              suggestion: 'Review content to ensure it aligns with L0 core_safety'
            }
          end

          # Check for hardcoded credentials patterns
          if content =~ /password\s*[:=]\s*["'][^"']+["']|api[_-]?key\s*[:=]\s*["'][^"']+["']/i
            dangers << {
              name: item[:name],
              severity: :critical,
              issue: 'May contain hardcoded credentials',
              suggestion: 'Remove any credentials and use environment variables'
            }
          end
        end

        dangers
      end

      # =========================================================================
      # Recommendations
      # =========================================================================

      def run_recommendations(layer, args)
        output = ["## Recommendations Report\n"]

        # Promotion candidates (L2 -> L1)
        output << "\n### Promotion Candidates (L2 → L1)\n"
        promotion_candidates = find_promotion_candidates_l2_to_l1(args)
        if promotion_candidates.empty?
          output << "No promotion candidates found.\n"
        else
          promotion_candidates.each do |candidate|
            output << "- `#{candidate[:name]}` - #{candidate[:reason]}"
          end
        end

        # Archive candidates (L1)
        output << "\n### Archive Candidates (L1)\n"
        archive_candidates = find_archive_candidates_l1
        if archive_candidates.empty?
          output << "No archive candidates found.\n"
        else
          archive_candidates.each do |candidate|
            output << "- `#{candidate[:name]}` - #{candidate[:reason]}"
          end
        end

        # L2 Cleanup candidates
        output << "\n### Cleanup Candidates (L2)\n"
        cleanup_candidates = find_cleanup_candidates_l2(args)
        if cleanup_candidates.empty?
          output << "No cleanup candidates found.\n"
        else
          cleanup_candidates.each do |candidate|
            output << "- `#{candidate[:name]}` - #{candidate[:reason]}"
          end
        end

        # Action instructions
        output << "\n---\n"
        output << "### How to Act on Recommendations\n"
        output << "\n**To promote L2 → L1:**"
        output << "```"
        output << 'skills_promote(command: "promote", source_name: "...", from_layer: "L2", to_layer: "L1", session_id: "...")'
        output << "```\n"
        output << "**To archive L1 knowledge:**"
        output << "```"
        output << 'skills_audit(command: "archive", target: "...", reason: "...", approved: true)'
        output << "```"

        output.join("\n")
      end

      def find_promotion_candidates_l2_to_l1(args)
        # This would ideally track usage across sessions
        # For now, return contexts that have been around for a while
        manager = ContextManager.new(nil, user_context: @safety&.current_user)
        candidates = []

        manager.list_sessions.each do |session|
          contexts = manager.list_contexts_in_session(session[:session_id])
          contexts.each do |ctx|
            # Simple heuristic: stable contexts with good descriptions
            if ctx[:description] && ctx[:description].length > 50
              candidates << {
                name: "#{session[:session_id]}/#{ctx[:name]}",
                reason: 'Well-documented context that may be valuable as permanent knowledge'
              }
            end
          end
        end

        candidates.first(5) # Limit to top 5
      end

      def find_archive_candidates_l1
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        items = provider.list
        candidates = []
        threshold = STALENESS_RULES['L1'][:threshold_days] * 1.5 # 270 days

        items.each do |item|
          skill = provider.get(item[:name])
          next unless skill

          mtime = File.mtime(skill.md_file_path)
          days_old = ((Time.now - mtime) / 86400).to_i

          if days_old > threshold
            candidates << {
              name: item[:name],
              reason: "Inactive for #{days_old} days",
              days_old: days_old
            }
          end
        end

        candidates.sort_by { |c| -c[:days_old] }.first(5)
      end

      def find_cleanup_candidates_l2(args)
        manager = ContextManager.new(nil, user_context: @safety&.current_user)
        candidates = []
        threshold = STALENESS_RULES['L2'][:threshold_days] * 2 # 28 days

        manager.list_sessions.each do |session|
          days_old = ((Time.now - session[:modified_at]) / 86400).to_i

          if days_old > threshold
            candidates << {
              name: "session:#{session[:session_id]}",
              reason: "Inactive for #{days_old} days (#{session[:context_count]} contexts)",
              days_old: days_old
            }
          end
        end

        candidates.sort_by { |c| -c[:days_old] }.first(5)
      end

      # =========================================================================
      # Archive Operations
      # =========================================================================

      def execute_archive(target, reason, args)
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)

        # Check if archive method exists
        unless provider.respond_to?(:archive)
          return text_content(
            "Error: Archive functionality not yet implemented in KnowledgeProvider.\n" \
            "This will be available after the archive feature is added."
          )
        end

        result = provider.archive(target, reason: reason)

        if result[:success]
          output = ["## Archive Successful\n"]
          output << "**Target**: #{target}"
          output << "**Reason**: #{reason}"
          output << "**Path**: #{result[:path]}"
          output << "\nThe knowledge has been moved to the archive folder."
          output << "Use `skills_audit(command: \"unarchive\", target: \"#{target}\", approved: true)` to restore."
          text_content(output.join("\n"))
        else
          text_content("Archive failed: #{result[:error]}")
        end
      end

      def execute_unarchive(target, reason, args)
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)

        unless provider.respond_to?(:unarchive)
          return text_content(
            "Error: Unarchive functionality not yet implemented in KnowledgeProvider.\n" \
            "This will be available after the archive feature is added."
          )
        end

        result = provider.unarchive(target, reason: reason)

        if result[:success]
          output = ["## Unarchive Successful\n"]
          output << "**Target**: #{target}"
          output << "**Reason**: #{reason}"
          output << "**Path**: #{result[:path]}"
          output << "\nThe knowledge has been restored from archive."
          text_content(output.join("\n"))
        else
          text_content("Unarchive failed: #{result[:error]}")
        end
      end

      # =========================================================================
      # Persona Assembly
      # =========================================================================

      # Oneshot mode: Single-round evaluation (default)
      def generate_oneshot_analysis(command, args, base_result)
        personas = args['personas'] || %w[archivist guardian promoter]

        output = ["## Persona Assembly Analysis (Oneshot Mode)\n"]
        output << "**Mode**: oneshot (single evaluation)"
        output << "**Requested personas**: #{personas.join(', ')}\n"

        # Generate template for each persona
        personas.each do |persona|
          output << persona_evaluation_template(persona, command)
        end

        output << "---\n"
        output << "### Consensus Summary\n"
        output << "Please evaluate the above from each persona's perspective and provide:\n"
        output << "- Support count: X/#{personas.size}"
        output << "- Key concerns raised"
        output << "- Final recommendation: [PROCEED / DEFER / REJECT]"

        output.join("\n")
      end

      # Discussion mode: Multi-round evaluation with facilitator
      def generate_discussion_template(command, args, base_result)
        personas = args['personas'] || %w[archivist guardian promoter]
        facilitator = args['facilitator'] || 'kairos'
        max_rounds = args['max_rounds'] || 3
        consensus_threshold = args['consensus_threshold'] || 0.6
        threshold_percent = (consensus_threshold * 100).to_i

        <<~TEMPLATE
          ## Persona Assembly Analysis (Discussion Mode)

          **Facilitator**: #{facilitator}
          **Participants**: #{personas.join(', ')}
          **Max rounds**: #{max_rounds}
          **Consensus threshold**: #{threshold_percent}%

          ---

          ### Instructions for Discussion

          Please conduct a multi-round discussion following this structure:

          #### Round 1: Initial Positions

          Each persona states their position on the audit findings:
          #{personas.map { |p| "- **#{p}**: [SUPPORT/OPPOSE/NEUTRAL] + rationale (1-2 sentences)" }.join("\n")}

          #### Facilitator (#{facilitator}): Round 1 Summary

          After Round 1, the facilitator should:
          - Summarize agreements and disagreements
          - Identify open concerns that need addressing
          - Decide: proceed to next round or conclude early

          #### Round 2-#{max_rounds}: Address Concerns (if needed)

          - Personas respond to concerns raised in previous rounds
          - Focus on unresolved disagreements
          - Facilitator summarizes after each round
          - End early if #{threshold_percent}%+ consensus is reached

          #### Final Summary (by #{facilitator})

          The facilitator must provide:
          - **Consensus**: [YES / NO / PARTIAL]
          - **Rounds used**: X/#{max_rounds}
          - **Final recommendation**: [PROCEED / DEFER / REJECT]
          - **Key resolutions**: [List what was agreed upon]
          - **Unresolved concerns**: [List remaining disagreements, if any]

          ---

          *Discussion mode is for important decisions requiring deeper analysis.*
          *For routine checks, use `assembly_mode: "oneshot"`.*
        TEMPLATE
      end

      def persona_evaluation_template(persona, command)
        case persona
        when 'archivist'
          <<~TEMPLATE
            
            #### archivist (Knowledge Curator)
            - **Focus**: Knowledge freshness, redundancy, organization
            - **Position**: [SUPPORT / OPPOSE / NEUTRAL]
            - **Assessment**: [Evaluate staleness and organization]
            - **Recommendation**: [Specific actions for archiving/organizing]
          TEMPLATE
        when 'guardian'
          <<~TEMPLATE
            
            #### guardian (Safety Watchdog)
            - **Focus**: Safety alignment, risk identification
            - **Position**: [SUPPORT / OPPOSE / NEUTRAL]
            - **Assessment**: [Evaluate safety implications]
            - **Concerns**: [Any safety risks identified]
          TEMPLATE
        when 'promoter'
          <<~TEMPLATE
            
            #### promoter (Promotion Scout)
            - **Focus**: Promotion candidates, knowledge maturity
            - **Position**: [SUPPORT / OPPOSE / NEUTRAL]
            - **Assessment**: [Evaluate promotion readiness]
            - **Candidates**: [Specific items ready for promotion]
          TEMPLATE
        else
          # Custom persona: generate a descriptive template inferring role from name
          humanized = persona.to_s.split(/[_\-]/).map(&:capitalize).join(' ')
          <<~TEMPLATE

            #### #{persona} (#{humanized} — Custom Persona)
            - **Inferred focus**: Based on the name "#{persona}", evaluate from this perspective
            - **Position**: [SUPPORT / OPPOSE / NEUTRAL]
            - **Assessment**: [Evaluation from the #{humanized} perspective]
            - **Key insight**: [What unique perspective does this role bring?]
          TEMPLATE
        end
      end

      # =========================================================================
      # Knowledge Gaps
      # =========================================================================

      def run_gaps_check(args)
        mode = args['mode_name'] || current_mode_name
        content = load_instruction_content(mode)

        unless content
          return "## Knowledge Gaps Report\n\n" \
                 "Could not load instruction file for mode `#{mode}`.\n" \
                 "Ensure the mode exists and has a corresponding `.md` file in the skills directory."
        end

        baseline = parse_baseline_knowledge(content)

        unless baseline && !baseline.empty?
          return "## Knowledge Gaps Report\n\n" \
                 "**Mode**: `#{mode}`\n\n" \
                 "No Knowledge Acquisition Policy found in this mode's instructions.\n\n" \
                 "To add one, include a `## Knowledge Acquisition Policy` section with a " \
                 "`### Baseline Knowledge` subsection listing required L1 entries:\n\n" \
                 "```markdown\n" \
                 "## Knowledge Acquisition Policy\n\n" \
                 "### Baseline Knowledge\n\n" \
                 "Required L1 knowledge entries for this mode.\n\n" \
                 "- `entry_name` — Description of what this knowledge covers\n" \
                 "```"
        end

        # Compare against existing L1 knowledge
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        existing = provider.list.map { |item| item[:name] }

        present = []
        missing = []
        baseline.each do |entry|
          if existing.include?(entry[:name])
            present << entry
          else
            missing << entry
          end
        end

        output = ["## Knowledge Gaps Report\n"]
        output << "**Mode**: `#{mode}`"
        output << "**Baseline entries**: #{baseline.size}"
        output << "**Present**: #{present.size}"
        output << "**Missing**: #{missing.size}\n"

        if missing.empty?
          output << "### All Baseline Knowledge Present\n"
          output << "All required L1 knowledge entries for this mode are available."
        else
          output << "### Missing Entries\n"
          missing.each do |entry|
            output << "- `#{entry[:name]}` — #{entry[:description]}"
          end

          output << "\n### Suggested Actions\n"
          output << "Create the missing entries using `knowledge_update`:\n"
          missing.each do |entry|
            output << "```"
            output << "knowledge_update(command: \"create\", name: \"#{entry[:name]}\", " \
                       "description: \"#{entry[:description]}\", " \
                       "content: \"# #{entry[:name]}\\n\\nTODO: Add content\", " \
                       "tags: [\"baseline\"])"
            output << "```\n"
          end
        end

        if present.any?
          output << "### Present Entries\n"
          present.each do |entry|
            output << "- `#{entry[:name]}` — #{entry[:description]}"
          end
        end

        output.join("\n")
      end

      def parse_baseline_knowledge(content)
        # Find the Knowledge Acquisition Policy section
        policy_match = content.match(/^##\s+Knowledge Acquisition Policy\s*$/i)
        return nil unless policy_match

        # Extract from ### Baseline Knowledge subsection
        baseline_match = content.match(/^###\s+Baseline Knowledge\s*\n(.*?)(?=^###|\z)/im)
        return nil unless baseline_match

        baseline_text = baseline_match[1]
        entries = []

        # Parse lines matching: - `name` — description (supports —, --, :, -)
        baseline_text.scan(/^-\s+`([^`]+)`\s*(?:—|--|:|-)\s*(.+)$/) do |name, description|
          entries << { name: name.strip, description: description.strip }
        end

        entries
      end

      def current_mode_name
        SkillsConfig.load['instructions_mode'] || 'tutorial'
      end

      def load_instruction_content(mode_name)
        path = case mode_name
               when 'developer'
                 KairosMcp.md_path
               when 'user'
                 KairosMcp.quickguide_path
               when 'tutorial'
                 KairosMcp.tutorial_path
               when 'none'
                 nil
               else
                 File.join(KairosMcp.skills_dir, "#{mode_name}.md")
               end

        return nil unless path && File.exist?(path)

        File.read(path)
      end

      # =========================================================================
      # Export Needs (Cross-Instance Knowledge Discovery)
      # =========================================================================

      def run_export_needs(args)
        mode = args['mode_name'] || current_mode_name
        content = load_instruction_content(mode)

        unless content
          return "## Export Needs Report\n\n" \
                 "Could not load instruction file for mode `#{mode}`.\n" \
                 "No knowledge needs to export."
        end

        baseline = parse_baseline_knowledge(content)

        unless baseline && !baseline.empty?
          return "## Export Needs Report\n\n" \
                 "**Mode**: `#{mode}`\n\n" \
                 "No Knowledge Acquisition Policy found — no needs to export."
        end

        # Find missing entries (gaps)
        provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
        existing = provider.list.map { |item| item[:name] }
        missing = baseline.reject { |entry| existing.include?(entry[:name]) }

        if missing.empty?
          return "## Export Needs Report\n\n" \
                 "**Mode**: `#{mode}`\n\n" \
                 "All baseline knowledge is present. No needs to export."
        end

        # Build exportable needs structure
        needs_data = build_knowledge_needs(mode, missing)

        # Check Meeting Place connection
        connection_file = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
        connected = File.exist?(connection_file)

        output = ["## Export Needs Report\n"]
        output << "**Mode**: `#{mode}`"
        output << "**Missing entries**: #{missing.size}"
        output << "**Meeting Place connected**: #{connected}\n"

        output << "### Exportable Needs\n"
        needs_data[:needs].each do |need|
          output << "- `#{need[:name]}` — #{need[:description]}"
        end

        if connected
          output << "\n### Next Step\n"
          output << "Publish these needs to the Meeting Place board:\n"
          output << "```"
          output << "meeting_publish_needs(opt_in: true)"
          output << "```"
        else
          output << "\n### Not Connected\n"
          output << "Connect to a Meeting Place first using `meeting_connect(url: \"...\")`, "
          output << "then use `meeting_publish_needs(opt_in: true)` to publish."
        end

        output.join("\n")
      end

      def build_knowledge_needs(mode_name, missing_entries = nil)
        if missing_entries.nil?
          content = load_instruction_content(mode_name)
          return { agent_mode: mode_name, needs: [], published_at: nil, session_only: true } unless content

          baseline = parse_baseline_knowledge(content) || []
          provider = KnowledgeProvider.new(nil, user_context: @safety&.current_user)
          existing = provider.list.map { |item| item[:name] }
          missing_entries = baseline.reject { |entry| existing.include?(entry[:name]) }
        end

        {
          agent_mode: mode_name,
          needs: missing_entries.map { |entry| { name: entry[:name], description: entry[:description] } },
          published_at: Time.now.utc.iso8601,
          session_only: true
        }
      end

      # =========================================================================
      # Helpers
      # =========================================================================

      def token_warning(personas, mode = 'oneshot', max_rounds = nil)
        persona_count = personas&.size || 3
        max_rounds ||= 3

        if mode == 'discussion'
          # Discussion mode: personas × rounds + facilitator summaries
          estimated = 500 + (300 * persona_count * max_rounds) + (200 * max_rounds)
          <<~WARNING
            ⚠️ **Persona Assembly: Discussion Mode**
            
            Estimated tokens: ~#{estimated} (maximum)
            - Base: ~500 tokens
            - Personas × Rounds: ~#{300 * persona_count} × #{max_rounds}
            - Facilitator summaries: ~#{200 * max_rounds}
            
            For simpler analysis, use `assembly_mode: "oneshot"`.
          WARNING
        else
          # Oneshot mode: single evaluation
          estimated = 500 + (300 * persona_count)
          <<~WARNING
            ⚠️ **Persona Assembly: Oneshot Mode**
            
            Estimated tokens: ~#{estimated}
            - Persona definitions: ~500 tokens
            - Per-persona evaluation: ~300 × #{persona_count}
            
            For deeper analysis, use `assembly_mode: "discussion"`.
          WARNING
        end
      end

      def pending_approval_message(command, args)
        target = args['target'] || '[target]'

        <<~MSG
          ## Human Approval Required

          **Action**: #{command}
          **Target**: #{target}

          This action requires human confirmation. After review, execute with `approved: true`:

          ```
          skills_audit(
            command: "#{command}",
            target: "#{target}",
            reason: "Your reason here",
            approved: true
          )
          ```

          ℹ️ This requirement is defined in L0 `audit_rules` skill.
        MSG
      end

      def format_issue(issue)
        type_label = case issue[:type]
                     when :stale then '[STALE]'
                     when :conflict then '[CONFLICT]'
                     when :deprecated_pattern then '[DEPRECATED]'
                     when :version_ref then '[VERSION]'
                     when :dangerous then '[DANGER]'
                     else "[#{issue[:type].to_s.upcase}]"
                     end

        "\n#### #{type_label} #{issue[:name]} (#{issue[:layer]})\n- #{issue[:message]}\n"
      end

      def generate_quick_recommendations(issues)
        recommendations = []

        stale_issues = issues.select { |i| i[:type] == :stale }
        if stale_issues.any?
          recommendations << "Review #{stale_issues.size} stale item(s) and consider archiving or updating"
        end

        version_issues = issues.select { |i| i[:type] == :version_ref }
        if version_issues.any?
          recommendations << "Check #{version_issues.size} item(s) for outdated version references"
        end

        deprecated_issues = issues.select { |i| i[:type] == :deprecated_pattern }
        if deprecated_issues.any?
          recommendations << "Review #{deprecated_issues.size} item(s) with deprecated patterns"
        end

        recommendations
      end

      def contains_deprecated_patterns?(content)
        # Simple heuristic for deprecated patterns
        deprecated = %w[deprecated legacy obsolete]
        deprecated.any? { |word| content.downcase.include?(word) }
      end

      def contains_old_version_refs?(content)
        # Check for version patterns that might be outdated
        # This is a simple heuristic
        old_patterns = [
          /ruby\s*[<>=]*\s*2\.[0-5]/i,
          /node\s*[<>=]*\s*1[0-4]\./i,
          /python\s*[<>=]*\s*3\.[0-7]/i
        ]
        old_patterns.any? { |pattern| content.match?(pattern) }
      end

      def similar_names?(name1, name2)
        # Simple similarity check
        words1 = name1.downcase.split(/[_\-\s]+/)
        words2 = name2.downcase.split(/[_\-\s]+/)
        common = words1 & words2
        common.size >= 2 || (common.size == 1 && common.first.length > 5)
      end
    end
  end
end
