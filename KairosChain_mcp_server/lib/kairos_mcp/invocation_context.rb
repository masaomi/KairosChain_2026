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
                :whitelist, :blacklist, :root_invocation_id,
                :mode, :idem_key

    def initialize(depth: 0, caller_tool: nil, mandate_id: nil,
                   token_budget: nil, whitelist: nil, blacklist: nil,
                   root_invocation_id: nil, mode: nil, idem_key: nil)
      @depth = depth
      @caller_tool = caller_tool
      @mandate_id = mandate_id
      @token_budget = token_budget
      @whitelist = whitelist
      @blacklist = blacklist
      @root_invocation_id = root_invocation_id || SecureRandom.hex(8)
      # mode: :direct (default), :daemon, :agent, ... — identifies the
      # top-level runner of the invocation chain.  Kept as a Symbol in
      # Ruby space; serialized as a String in to_h/from_h.
      @mode = mode.nil? ? nil : mode.to_sym
      # idem_key: optional client-supplied key that lets the daemon
      # deduplicate retries of the same logical command.
      @idem_key = idem_key
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
        root_invocation_id: @root_invocation_id,
        mode: @mode,
        idem_key: @idem_key
      )
    end

    # Derive a phase-specific context with an optional whitelist and additional blacklist.
    # Used by agent OODA phases to restrict tool access per phase (e.g., OBSERVE, ORIENT).
    # Invariant: effective set = whitelist ∩ complement(parent_blacklist ∪ blacklist_add)
    # Parent deny always takes precedence — a phase whitelist cannot override a parent blacklist.
    # Does NOT increment depth — child() does that at invoke_tool time.
    def derive_for_phase(whitelist: nil, blacklist_add: [])
      new_blacklist = Array(@blacklist).dup
      blacklist_add.each { |pat| new_blacklist << pat unless new_blacklist.include?(pat) }

      self.class.new(
        depth: @depth,
        caller_tool: @caller_tool,
        mandate_id: @mandate_id,
        token_budget: @token_budget,
        whitelist: whitelist ? whitelist.dup : @whitelist&.dup,
        blacklist: new_blacklist.empty? ? nil : new_blacklist,
        root_invocation_id: @root_invocation_id,
        mode: @mode,
        idem_key: @idem_key
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
        root_invocation_id: @root_invocation_id,
        mode: @mode,
        idem_key: @idem_key
      )
    end

    # Serialize to a plain Hash for passing through tool arguments.
    # Only includes policy-relevant fields (whitelist, blacklist, mandate_id, token_budget).
    def to_h
      {
        'whitelist' => @whitelist,
        'blacklist' => @blacklist,
        'mandate_id' => @mandate_id,
        'token_budget' => @token_budget,
        'mode' => @mode&.to_s,
        'idem_key' => @idem_key
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
        token_budget: hash['token_budget'],
        mode: hash['mode'],
        idem_key: hash['idem_key']
      )
    end

    def self.from_json(json_string)
      require 'json'
      from_h(JSON.parse(json_string))
    end

    # Check if a tool is allowed by whitelist/blacklist policy.
    # Blacklist is checked first (deny wins). Both use fnmatch patterns.
    # For namespaced tools (e.g., "peer1/agent_start"), also checks
    # the bare name ("agent_start") to prevent blacklist bypass via
    # remote proxy tool namespace prefix.
    def allowed?(tool_name)
      names = [tool_name]
      names << tool_name.split('/').last if tool_name.include?('/')

      if @blacklist
        return false if names.any? { |n| @blacklist.any? { |pat| File.fnmatch(pat, n) } }
      end
      if @whitelist
        return names.any? { |n| @whitelist.any? { |pat| File.fnmatch(pat, n) } }
      end
      true
    end

    class DepthExceededError < StandardError; end
    class PolicyDeniedError < StandardError; end
  end
end
