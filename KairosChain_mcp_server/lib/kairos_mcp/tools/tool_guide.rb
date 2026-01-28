# frozen_string_literal: true

require 'yaml'
require_relative 'base_tool'

module KairosMcp
  module Tools
    # ToolGuide: Dynamic tool discovery and guidance system
    #
    # Provides:
    # - catalog: Category-based tool listing
    # - search: Keyword/tag-based search
    # - recommend: Goal-based tool recommendations
    # - detail: Detailed tool information
    # - workflow: Common workflow patterns
    # - suggest: Auto-infer metadata from tool definition (for LLM)
    # - apply_metadata: Apply metadata with human approval
    # - validate: Validate metadata structure
    #
    class ToolGuide < BaseTool
      METADATA_FILE = File.expand_path('../../config/tool_metadata.yml', __dir__)

      # Predefined workflow patterns
      WORKFLOWS = {
        'knowledge_lifecycle' => {
          title: 'Knowledge Lifecycle',
          description: 'Save temporary ideas, validate, then promote to permanent knowledge',
          steps: [
            { tool: 'context_save', desc: 'Save hypothesis in L2', params: 'name: "my_idea", content: "..."' },
            { tool: 'skills_audit', desc: 'Check promotion candidates', params: 'command: "recommend"' },
            { tool: 'skills_promote', desc: 'Promote to L1', params: 'from_layer: "L2", to_layer: "L1"' }
          ]
        },
        'health_check' => {
          title: 'System Health Check',
          description: 'Verify blockchain integrity and layer health',
          steps: [
            { tool: 'chain_status', desc: 'Check blockchain status', params: '' },
            { tool: 'chain_verify', desc: 'Verify integrity', params: '' },
            { tool: 'skills_audit', desc: 'Check layer health', params: 'command: "check"' },
            { tool: 'state_status', desc: 'Check uncommitted changes', params: '' }
          ]
        },
        'skill_evolution' => {
          title: 'L0 Skill Evolution',
          description: 'Safely modify L0 meta-skills with backup and recording',
          steps: [
            { tool: 'skills_dsl_list', desc: 'List current skills', params: '' },
            { tool: 'skills_rollback', desc: 'Create backup snapshot', params: 'action: "snapshot"' },
            { tool: 'skills_evolve', desc: 'Propose changes', params: 'skill_id: "...", changes: {...}' },
            { tool: 'chain_history', desc: 'Verify recording', params: '' }
          ]
        },
        'tool_onboarding' => {
          title: 'New Tool Onboarding',
          description: 'Add metadata for a new tool (LLM workflow)',
          steps: [
            { tool: 'tool_guide', desc: 'Auto-suggest metadata', params: 'command: "suggest", tool_name: "new_tool"' },
            { tool: 'tool_guide', desc: 'Validate metadata', params: 'command: "validate", metadata: {...}' },
            { tool: 'tool_guide', desc: 'Apply with approval', params: 'command: "apply_metadata", approved: true' }
          ]
        }
      }.freeze

      # Category definitions with display info
      CATEGORIES = {
        chain: { label: 'Blockchain', description: 'Blockchain operations and verification' },
        knowledge: { label: 'Knowledge (L1)', description: 'Project knowledge management' },
        context: { label: 'Context (L2)', description: 'Temporary context management' },
        skills: { label: 'Skills (L0)', description: 'Meta-skill management' },
        resource: { label: 'Resource', description: 'Unified resource access' },
        state: { label: 'State', description: 'State commit and snapshot management' },
        guide: { label: 'Guide', description: 'Help and discovery tools' },
        utility: { label: 'Utility', description: 'General utility tools' }
      }.freeze

      READONLY_COMMANDS = %w[catalog search recommend detail workflow suggest validate].freeze
      WRITE_COMMANDS = %w[apply_metadata].freeze

      def name
        'tool_guide'
      end

      def description
        'Dynamic tool discovery and guidance. List tools by category, search by tags, ' \
        'get recommendations based on goals, view detailed tool info, and manage tool metadata. ' \
        'Also supports LLM workflow: suggest metadata, validate, and apply with human approval.'
      end

      def category
        :guide
      end

      def usecase_tags
        %w[help discovery catalog search recommend guide metadata]
      end

      def examples
        [
          { title: 'List all tools by category', code: 'tool_guide(command: "catalog")' },
          { title: 'Search for save-related tools', code: 'tool_guide(command: "search", query: "save")' },
          { title: 'Get tool recommendation', code: 'tool_guide(command: "recommend", goal: "save project conventions")' },
          { title: 'View tool details', code: 'tool_guide(command: "detail", tool_name: "knowledge_update")' },
          { title: 'Suggest metadata for new tool', code: 'tool_guide(command: "suggest", tool_name: "my_new_tool")' }
        ]
      end

      def related_tools
        %w[hello_world skills_list knowledge_list]
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
            query: {
              type: 'string',
              description: 'Search query (for search command)'
            },
            goal: {
              type: 'string',
              description: 'User goal for recommendations (for recommend command)'
            },
            tool_name: {
              type: 'string',
              description: 'Tool name (for detail, suggest, apply_metadata commands)'
            },
            workflow_name: {
              type: 'string',
              description: 'Workflow name (for workflow command)',
              enum: WORKFLOWS.keys
            },
            metadata: {
              type: 'object',
              description: 'Metadata to apply (for apply_metadata command)',
              properties: {
                category: { type: 'string' },
                usecase_tags: { type: 'array', items: { type: 'string' } },
                examples: { type: 'array' },
                related_tools: { type: 'array', items: { type: 'string' } }
              }
            },
            approved: {
              type: 'boolean',
              description: 'Human approval flag (required for apply_metadata)'
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
        case command
        when 'catalog'
          build_catalog
        when 'search'
          search_tools(args['query'])
        when 'recommend'
          recommend_tools(args['goal'])
        when 'detail'
          tool_detail(args['tool_name'])
        when 'workflow'
          workflow_guide(args['workflow_name'])
        when 'suggest'
          suggest_metadata(args['tool_name'])
        when 'validate'
          validate_metadata(args['metadata'])
        end
      end

      def handle_write_command(command, args)
        case command
        when 'apply_metadata'
          apply_metadata(args['tool_name'], args['metadata'], args['approved'])
        end
      end

      # =========================================================================
      # Catalog Command
      # =========================================================================

      def build_catalog
        tools = collect_all_tools
        grouped = tools.group_by { |t| t[:category] }

        output = ["# KairosChain Tool Catalog\n"]
        output << "Total: #{tools.size} tools\n"

        CATEGORIES.each do |cat_sym, cat_info|
          cat_tools = grouped[cat_sym] || []
          next if cat_tools.empty?

          output << "\n## #{cat_info[:label]} (#{cat_tools.size})\n"
          output << "_#{cat_info[:description]}_\n"

          cat_tools.each do |tool|
            tags = tool[:usecase_tags].empty? ? '' : " `#{tool[:usecase_tags].first(3).join('` `')}`"
            output << "- **#{tool[:name]}**: #{truncate(tool[:description], 80)}#{tags}"
          end
        end

        output << "\n---"
        output << "\n**Usage:** `tool_guide(command: \"detail\", tool_name: \"<name>\")` for more info"

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Search Command
      # =========================================================================

      def search_tools(query)
        return text_content("Error: query is required for search") unless query && !query.empty?

        tools = collect_all_tools
        query_lower = query.downcase
        keywords = query_lower.split(/\s+/)

        matches = tools.select do |tool|
          searchable = [
            tool[:name],
            tool[:description],
            tool[:usecase_tags].join(' ')
          ].join(' ').downcase

          keywords.all? { |kw| searchable.include?(kw) }
        end

        if matches.empty?
          return text_content("No tools found matching: \"#{query}\"\n\nTry broader terms or use `catalog` to see all tools.")
        end

        output = ["## Search Results for \"#{query}\"\n"]
        output << "Found #{matches.size} tool(s):\n"

        matches.each do |tool|
          output << "### #{tool[:name]}"
          output << "_Category: #{CATEGORIES[tool[:category]]&.dig(:label) || tool[:category]}_"
          output << tool[:description]
          unless tool[:usecase_tags].empty?
            output << "**Tags:** `#{tool[:usecase_tags].join('` `')}`"
          end
          output << ""
        end

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Recommend Command
      # =========================================================================

      def recommend_tools(goal)
        return text_content("Error: goal is required for recommend") unless goal && !goal.empty?

        tools = collect_all_tools
        goal_lower = goal.downcase

        # Simple keyword matching for recommendations
        scored = tools.map do |tool|
          score = 0
          searchable = [tool[:description], tool[:usecase_tags].join(' ')].join(' ').downcase

          # Score based on keyword matches
          goal_lower.split(/\s+/).each do |word|
            score += 2 if searchable.include?(word)
            score += 1 if tool[:name].include?(word)
          end

          # Boost for specific patterns
          score += 3 if goal_lower.include?('save') && tool[:usecase_tags].any? { |t| t.include?('save') || t.include?('保存') }
          score += 3 if goal_lower.include?('check') && tool[:usecase_tags].any? { |t| t.include?('check') || t.include?('検証') }
          score += 3 if goal_lower.include?('list') && tool[:name].include?('list')

          { tool: tool, score: score }
        end

        recommendations = scored.select { |s| s[:score] > 0 }
                                .sort_by { |s| -s[:score] }
                                .first(5)

        if recommendations.empty?
          return text_content(
            "No specific recommendations for: \"#{goal}\"\n\n" \
            "Try:\n- `tool_guide(command: \"catalog\")` to browse all tools\n" \
            "- `tool_guide(command: \"search\", query: \"<keyword>\")` to search"
          )
        end

        output = ["## Recommendations for: \"#{goal}\"\n"]

        recommendations.each_with_index do |rec, i|
          tool = rec[:tool]
          output << "### #{i + 1}. #{tool[:name]}"
          output << tool[:description]

          unless tool[:examples].empty?
            output << "\n**Example:**"
            output << "```"
            output << tool[:examples].first[:code]
            output << "```"
          end

          output << ""
        end

        # Suggest workflow if applicable
        workflow = suggest_workflow_for_goal(goal_lower)
        if workflow
          output << "---"
          output << "\n**Suggested Workflow:** `tool_guide(command: \"workflow\", workflow_name: \"#{workflow}\")`"
        end

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Detail Command
      # =========================================================================

      def tool_detail(tool_name)
        return text_content("Error: tool_name is required") unless tool_name && !tool_name.empty?

        tools = collect_all_tools
        tool = tools.find { |t| t[:name] == tool_name }

        unless tool
          return text_content(
            "Tool not found: #{tool_name}\n\n" \
            "Use `tool_guide(command: \"catalog\")` to see available tools."
          )
        end

        output = ["# #{tool[:name]}\n"]
        output << "_Category: #{CATEGORIES[tool[:category]]&.dig(:label) || tool[:category]}_\n"
        output << "## Description\n"
        output << tool[:description]
        output << ""

        # Tags
        unless tool[:usecase_tags].empty?
          output << "## Tags"
          output << "`#{tool[:usecase_tags].join('` `')}`"
          output << ""
        end

        # Input Schema
        if tool[:input_schema] && !tool[:input_schema][:properties].empty?
          output << "## Parameters"
          tool[:input_schema][:properties].each do |param, spec|
            required = tool[:input_schema][:required]&.include?(param.to_s) ? ' **(required)**' : ''
            output << "- **#{param}**#{required}: #{spec[:description] || spec['description'] || 'No description'}"
          end
          output << ""
        end

        # Examples
        unless tool[:examples].empty?
          output << "## Examples"
          tool[:examples].each do |ex|
            output << "### #{ex[:title] || ex['title']}"
            output << "```"
            output << (ex[:code] || ex['code'])
            output << "```"
          end
          output << ""
        end

        # Related Tools
        unless tool[:related_tools].empty?
          output << "## Related Tools"
          output << tool[:related_tools].map { |t| "`#{t}`" }.join(', ')
        end

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Workflow Command
      # =========================================================================

      def workflow_guide(workflow_name)
        if workflow_name.nil? || workflow_name.empty?
          # List all workflows
          output = ["# Available Workflows\n"]
          WORKFLOWS.each do |name, wf|
            output << "## #{wf[:title]}"
            output << "_#{wf[:description]}_"
            output << "```"
            output << "tool_guide(command: \"workflow\", workflow_name: \"#{name}\")"
            output << "```"
            output << ""
          end
          return text_content(output.join("\n"))
        end

        workflow = WORKFLOWS[workflow_name]
        unless workflow
          return text_content(
            "Workflow not found: #{workflow_name}\n\n" \
            "Available workflows: #{WORKFLOWS.keys.join(', ')}"
          )
        end

        output = ["# Workflow: #{workflow[:title]}\n"]
        output << "_#{workflow[:description]}_\n"
        output << "## Steps\n"

        workflow[:steps].each_with_index do |step, i|
          output << "### Step #{i + 1}: #{step[:desc]}"
          output << "```"
          params_str = step[:params].empty? ? '' : ", #{step[:params]}"
          output << "#{step[:tool]}(#{params_str.sub(/^, /, '')})"
          output << "```"
          output << ""
        end

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Suggest Command (LLM Metadata Inference)
      # =========================================================================

      def suggest_metadata(tool_name)
        return text_content("Error: tool_name is required") unless tool_name && !tool_name.empty?

        tool = find_tool_by_name(tool_name)
        unless tool
          return text_content("Tool not found: #{tool_name}")
        end

        # Infer category from tool name prefix
        category = infer_category(tool_name)

        # Infer usecase_tags from description
        tags = infer_usecase_tags(tool[:description], tool[:input_schema])

        # Infer related tools
        related = infer_related_tools(tool_name, category)

        # Generate examples from input_schema
        examples = generate_examples(tool_name, tool[:input_schema])

        output = ["# Suggested Metadata for: #{tool_name}\n"]
        output << "## Inferred Values\n"
        output << "```yaml"
        output << "category: #{category}"
        output << "usecase_tags:"
        tags.each { |t| output << "  - #{t}" }
        output << "examples:"
        examples.each do |ex|
          output << "  - title: \"#{ex[:title]}\""
          output << "    code: '#{ex[:code]}'"
        end
        output << "related_tools:"
        related.each { |r| output << "  - #{r}" }
        output << "```\n"

        output << "## Reasoning\n"
        output << "- **Category**: Inferred from tool name prefix `#{tool_name.split('_').first}_*` → `:#{category}`"
        output << "- **Tags**: Extracted from description keywords"
        output << "- **Examples**: Generated from input_schema structure"
        output << "- **Related**: Tools in same category with similar purpose\n"

        output << "---\n"
        output << "## Next Steps\n"
        output << "1. Review and adjust the suggested metadata"
        output << "2. Apply with human approval:\n"
        output << "```"
        output << "tool_guide("
        output << "  command: \"apply_metadata\","
        output << "  tool_name: \"#{tool_name}\","
        output << "  metadata: {"
        output << "    category: \"#{category}\","
        output << "    usecase_tags: #{tags.inspect},"
        output << "    examples: [...],"
        output << "    related_tools: #{related.inspect}"
        output << "  },"
        output << "  approved: true"
        output << ")"
        output << "```"

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Validate Command
      # =========================================================================

      def validate_metadata(metadata)
        return text_content("Error: metadata is required") unless metadata

        errors = []
        warnings = []

        # Validate category
        if metadata['category'] || metadata[:category]
          cat = (metadata['category'] || metadata[:category]).to_sym
          unless CATEGORIES.key?(cat)
            errors << "Invalid category: #{cat}. Valid: #{CATEGORIES.keys.join(', ')}"
          end
        else
          warnings << "Missing category (will default to :utility)"
        end

        # Validate usecase_tags
        tags = metadata['usecase_tags'] || metadata[:usecase_tags]
        if tags
          unless tags.is_a?(Array)
            errors << "usecase_tags must be an array"
          end
        else
          warnings << "Missing usecase_tags (will default to empty)"
        end

        # Validate examples
        examples = metadata['examples'] || metadata[:examples]
        if examples
          unless examples.is_a?(Array)
            errors << "examples must be an array"
          else
            examples.each_with_index do |ex, i|
              unless (ex[:title] || ex['title']) && (ex[:code] || ex['code'])
                errors << "Example #{i} missing title or code"
              end
            end
          end
        end

        # Validate related_tools
        related = metadata['related_tools'] || metadata[:related_tools]
        if related
          unless related.is_a?(Array)
            errors << "related_tools must be an array"
          end
        end

        # Build result
        output = ["# Metadata Validation Result\n"]

        if errors.empty?
          output << "## Status: VALID\n"
        else
          output << "## Status: INVALID\n"
          output << "### Errors"
          errors.each { |e| output << "- #{e}" }
          output << ""
        end

        unless warnings.empty?
          output << "### Warnings"
          warnings.each { |w| output << "- #{w}" }
        end

        if errors.empty?
          output << "\nMetadata is valid and ready to apply with `apply_metadata` command."
        end

        text_content(output.join("\n"))
      end

      # =========================================================================
      # Apply Metadata Command (Write Operation)
      # =========================================================================

      def apply_metadata(tool_name, metadata, approved)
        return text_content("Error: tool_name is required") unless tool_name && !tool_name.empty?
        return text_content("Error: metadata is required") unless metadata

        # Check human approval
        unless approved == true
          return text_content(pending_approval_message(tool_name, metadata))
        end

        # Validate first
        validation = validate_metadata_internal(metadata)
        unless validation[:valid]
          return text_content("Validation failed:\n#{validation[:errors].join("\n")}")
        end

        # Store metadata
        result = store_metadata(tool_name, metadata)

        if result[:success]
          output = ["# Metadata Applied Successfully\n"]
          output << "**Tool:** #{tool_name}"
          output << "**Category:** #{metadata['category'] || metadata[:category]}"
          output << "**Tags:** #{(metadata['usecase_tags'] || metadata[:usecase_tags] || []).join(', ')}"
          output << ""
          output << "The metadata has been saved to `config/tool_metadata.yml`"
          output << "This tool is now discoverable via `tool_guide(command: \"catalog\")`"
          text_content(output.join("\n"))
        else
          text_content("Failed to apply metadata: #{result[:error]}")
        end
      end

      # =========================================================================
      # Helper Methods
      # =========================================================================

      def collect_all_tools
        # Get tools from registry
        registry = ToolRegistry.new
        stored_metadata = load_stored_metadata

        registry.list_tools.map do |schema|
          tool_name = schema[:name]
          stored = stored_metadata[tool_name] || {}

          # Merge stored metadata with tool's own metadata
          {
            name: tool_name,
            description: schema[:description],
            input_schema: schema[:inputSchema],
            category: (stored['category'] || stored[:category] || infer_category(tool_name)).to_sym,
            usecase_tags: stored['usecase_tags'] || stored[:usecase_tags] || [],
            examples: stored['examples'] || stored[:examples] || [],
            related_tools: stored['related_tools'] || stored[:related_tools] || []
          }
        end
      end

      def find_tool_by_name(tool_name)
        registry = ToolRegistry.new
        schema = registry.list_tools.find { |t| t[:name] == tool_name }
        return nil unless schema

        {
          name: schema[:name],
          description: schema[:description],
          input_schema: schema[:inputSchema]
        }
      end

      def load_stored_metadata
        return {} unless File.exist?(METADATA_FILE)

        YAML.load_file(METADATA_FILE) || {}
      rescue StandardError => e
        $stderr.puts "[WARN] Failed to load tool metadata: #{e.message}"
        {}
      end

      def store_metadata(tool_name, metadata)
        # Ensure directory exists
        dir = File.dirname(METADATA_FILE)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)

        # Load existing
        existing = load_stored_metadata

        # Normalize metadata keys to strings
        normalized = {
          'category' => (metadata['category'] || metadata[:category]).to_s,
          'usecase_tags' => metadata['usecase_tags'] || metadata[:usecase_tags] || [],
          'examples' => (metadata['examples'] || metadata[:examples] || []).map do |ex|
            { 'title' => ex[:title] || ex['title'], 'code' => ex[:code] || ex['code'] }
          end,
          'related_tools' => metadata['related_tools'] || metadata[:related_tools] || []
        }

        # Update
        existing[tool_name] = normalized

        # Save
        File.write(METADATA_FILE, existing.to_yaml)

        { success: true }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def validate_metadata_internal(metadata)
        errors = []

        cat = metadata['category'] || metadata[:category]
        if cat && !CATEGORIES.key?(cat.to_sym)
          errors << "Invalid category: #{cat}"
        end

        tags = metadata['usecase_tags'] || metadata[:usecase_tags]
        if tags && !tags.is_a?(Array)
          errors << "usecase_tags must be an array"
        end

        { valid: errors.empty?, errors: errors }
      end

      def infer_category(tool_name)
        case tool_name
        when /^chain_/ then :chain
        when /^knowledge_/ then :knowledge
        when /^context_/ then :context
        when /^skills_/ then :skills
        when /^resource_/ then :resource
        when /^state_/ then :state
        when /^tool_guide|^hello/ then :guide
        else :utility
        end
      end

      def infer_usecase_tags(description, input_schema)
        tags = []
        desc_lower = description.downcase

        # Action-based tags
        tags << 'save' if desc_lower =~ /save|create|write/
        tags << 'update' if desc_lower =~ /update|modify|change/
        tags << 'delete' if desc_lower =~ /delete|remove/
        tags << 'list' if desc_lower =~ /list|all|available/
        tags << 'get' if desc_lower =~ /get|read|fetch/
        tags << 'verify' if desc_lower =~ /verify|validate|check/
        tags << 'search' if desc_lower =~ /search|find|query/
        tags << 'export' if desc_lower =~ /export/
        tags << 'import' if desc_lower =~ /import/

        # Layer tags
        tags << 'L0' if desc_lower =~ /l0|skill|meta-?rule/
        tags << 'L1' if desc_lower =~ /l1|knowledge/
        tags << 'L2' if desc_lower =~ /l2|context|temporary/

        # Domain tags
        tags << 'blockchain' if desc_lower =~ /blockchain|chain/
        tags << 'audit' if desc_lower =~ /audit|health/

        tags.uniq
      end

      def infer_related_tools(tool_name, category)
        # Find other tools in same category
        registry = ToolRegistry.new
        all_tools = registry.list_tools

        related = all_tools
                  .select { |t| t[:name] != tool_name && infer_category(t[:name]) == category }
                  .map { |t| t[:name] }
                  .first(4)

        related
      end

      def generate_examples(tool_name, input_schema)
        examples = []
        props = input_schema[:properties] || input_schema['properties'] || {}

        if props['command']
          commands = props['command'][:enum] || props['command']['enum'] || []
          commands.first(2).each do |cmd|
            examples << {
              title: "#{cmd.capitalize} command",
              code: "#{tool_name}(command: \"#{cmd}\", ...)"
            }
          end
        else
          examples << {
            title: 'Basic usage',
            code: "#{tool_name}(...)"
          }
        end

        examples
      end

      def suggest_workflow_for_goal(goal)
        return 'knowledge_lifecycle' if goal =~ /save|knowledge|promote|l1|l2/
        return 'health_check' if goal =~ /check|verify|health|status/
        return 'skill_evolution' if goal =~ /evolve|l0|skill|modify/
        return 'tool_onboarding' if goal =~ /metadata|new tool|onboard/

        nil
      end

      def pending_approval_message(tool_name, metadata)
        <<~MSG
          ## Human Approval Required

          **Tool:** #{tool_name}

          ### Proposed Metadata
          ```yaml
          category: #{metadata['category'] || metadata[:category]}
          usecase_tags: #{(metadata['usecase_tags'] || metadata[:usecase_tags] || []).inspect}
          examples: #{(metadata['examples'] || metadata[:examples] || []).size} item(s)
          related_tools: #{(metadata['related_tools'] || metadata[:related_tools] || []).inspect}
          ```

          After review, execute with `approved: true`:

          ```
          tool_guide(
            command: "apply_metadata",
            tool_name: "#{tool_name}",
            metadata: #{metadata.inspect},
            approved: true
          )
          ```
        MSG
      end

      def truncate(text, length)
        return text if text.length <= length

        text[0...length] + '...'
      end
    end
  end
end
