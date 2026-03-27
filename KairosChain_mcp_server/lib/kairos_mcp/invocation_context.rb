# frozen_string_literal: true

require 'securerandom'

module KairosMcp
  # Tracks invocation chain metadata for internal tool-to-tool calls.
  # Carries depth, caller, mandate, and policy (whitelist/blacklist) through
  # the entire invocation chain. Created by BaseTool#invoke_tool, threaded
  # through ToolRegistry#call_tool.
  class InvocationContext
    MAX_DEPTH = 10

    attr_reader :depth, :caller_tool, :mandate_id, :token_budget,
                :whitelist, :blacklist, :root_invocation_id

    def initialize(depth: 0, caller_tool: nil, mandate_id: nil,
                   token_budget: nil, whitelist: nil, blacklist: nil,
                   root_invocation_id: nil)
      @depth = depth
      @caller_tool = caller_tool
      @mandate_id = mandate_id
      @token_budget = token_budget
      @whitelist = whitelist
      @blacklist = blacklist
      @root_invocation_id = root_invocation_id || SecureRandom.hex(8)
    end

    # Create a child context for a nested invocation.
    # Inherits all policy from the parent; increments depth.
    def child(caller_tool:)
      raise DepthExceededError, "Max invocation depth (#{MAX_DEPTH}) exceeded" if @depth >= MAX_DEPTH

      self.class.new(
        depth: @depth + 1,
        caller_tool: caller_tool,
        mandate_id: @mandate_id,
        token_budget: @token_budget,
        whitelist: @whitelist&.dup,
        blacklist: @blacklist&.dup,
        root_invocation_id: @root_invocation_id
      )
    end

    # Derive a new context with modified blacklist, preserving all other fields.
    # Used by agent ACT phase to selectively unblock autoexec tools.
    # Does NOT increment depth — child() does that at invoke_tool time.
    def derive(blacklist_remove: [], blacklist_add: [])
      new_blacklist = Array(@blacklist).dup
      blacklist_remove.each { |pat| new_blacklist.delete(pat) }
      blacklist_add.each { |pat| new_blacklist << pat unless new_blacklist.include?(pat) }

      self.class.new(
        depth: @depth,
        caller_tool: @caller_tool,
        mandate_id: @mandate_id,
        token_budget: @token_budget,
        whitelist: @whitelist&.dup,
        blacklist: new_blacklist.empty? ? nil : new_blacklist,
        root_invocation_id: @root_invocation_id
      )
    end

    # Serialize to a plain Hash for passing through tool arguments.
    # Only includes policy-relevant fields (whitelist, blacklist, mandate_id, token_budget).
    def to_h
      {
        'whitelist' => @whitelist,
        'blacklist' => @blacklist,
        'mandate_id' => @mandate_id,
        'token_budget' => @token_budget
      }
    end

    def to_json(*args)
      require 'json'
      to_h.to_json(*args)
    end

    # Reconstruct policy from a Hash (e.g., parsed from tool arguments).
    # Only restores policy fields — depth and caller are not transferred.
    def self.from_h(hash)
      return nil if hash.nil?

      new(
        whitelist: hash['whitelist'],
        blacklist: hash['blacklist'],
        mandate_id: hash['mandate_id'],
        token_budget: hash['token_budget']
      )
    end

    def self.from_json(json_string)
      require 'json'
      from_h(JSON.parse(json_string))
    end

    # Check if a tool is allowed by whitelist/blacklist policy.
    # Blacklist is checked first (deny wins). Both use fnmatch patterns.
    def allowed?(tool_name)
      if @blacklist&.any? { |pat| File.fnmatch(pat, tool_name) }
        return false
      end
      if @whitelist
        return @whitelist.any? { |pat| File.fnmatch(pat, tool_name) }
      end
      true
    end

    class DepthExceededError < StandardError; end
    class PolicyDeniedError < StandardError; end
  end
end
