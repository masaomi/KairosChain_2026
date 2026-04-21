# frozen_string_literal: true

require_relative 'canonical'

module KairosMcp
  class Daemon
    # TaskDag — dependency-aware, single-threaded task graph for agent cycles.
    #
    # Design (v0.2 §2, P3.1):
    #   A mandate may fan out into multiple concrete tool invocations with
    #   dependencies between them (e.g. "fetch inputs", then "transform",
    #   then "summarize"). TaskDag orders them without introducing
    #   concurrency — #next_runnable returns AT MOST ONE node per call,
    #   chosen from nodes whose dependencies are all :completed.
    #
    # Invariants:
    #   * Graph is acyclic (validated via Kahn's algorithm at construction).
    #   * No self-dependency (depends_on must not contain the node's own id).
    #   * All referenced dependency ids exist in the node set.
    #   * Status transitions are forward-only per node:
    #       :pending  → :running | :completed | :failed | :cancelled
    #       :running  → :completed | :failed | :cancelled
    #       Terminal states (:completed, :failed, :cancelled) are sticky.
    #
    # Failure propagation policies (attached to each node):
    #   :halt             — on failure, cancel ALL remaining :pending nodes
    #   :skip_dependents  — cancel only the transitive dependents of the failed
    #                       node; unrelated siblings are left :pending
    #   :continue         — failure is absorbed locally; other nodes unaffected
    class TaskDag
      # Node represents a single tool invocation within the DAG.
      #
      # `args` is captured verbatim for downstream hashing; the DAG itself
      # never interprets it. `failure_policy` is per-node so different
      # branches of the DAG can have different tolerance semantics.
      Node = Struct.new(
        :id, :tool, :args, :depends_on, :status, :failure_policy,
        :error, keyword_init: true
      ) do
        def pending?;    status == :pending;    end
        def running?;    status == :running;    end
        def completed?;  status == :completed;  end
        def failed?;     status == :failed;     end
        def cancelled?;  status == :cancelled;  end
        def terminal?;   %i[completed failed cancelled].include?(status); end
      end

      VALID_STATUSES = %i[pending running completed failed cancelled].freeze
      VALID_POLICIES = %i[halt skip_dependents continue].freeze

      # Forward-only transition table. Terminal states have no outgoing edges.
      ALLOWED_TRANSITIONS = {
        pending:   %i[running completed failed cancelled],
        running:   %i[completed failed cancelled],
        completed: [],
        failed:    [],
        cancelled: []
      }.freeze

      class CyclicGraphError < StandardError; end
      class InvalidNodeError < StandardError; end
      class InvalidTransitionError < StandardError; end

      # @param nodes [Array<Hash>] each Hash becomes a Node. Required keys:
      #   :id, :tool. Optional: :args (default {}), :depends_on (default []),
      #   :failure_policy (default :halt), :status (default :pending).
      def initialize(nodes)
        @nodes = {}
        Array(nodes).each { |n| add_node(n) }
        validate_references!
        validate_no_self_dep!
        validate_acyclic!
      end

      # Non-destructive read of the current node set, in insertion order.
      def nodes
        @nodes.values
      end

      def node(id)
        @nodes[id.to_s]
      end

      def size
        @nodes.size
      end

      # Return the first :pending node whose every dependency is :completed.
      #
      # Single-threaded by design: the caller executes the returned node,
      # calls #mark, then calls #next_runnable again. Returns nil if no
      # node is currently runnable (either empty, all terminal, or blocked
      # by in-flight :running nodes).
      def next_runnable
        @nodes.each_value do |node|
          next unless node.pending?
          next unless deps_satisfied?(node)

          return node
        end
        nil
      end

      # Transition a node to a new status. Propagates failures according to
      # the node's failure_policy when `status` is :failed.
      #
      # @param id [String]
      # @param status [Symbol] one of VALID_STATUSES.
      # @param error [String, nil] optional error message for :failed.
      # @return [Node] the updated node.
      def mark(id, status, error: nil)
        status = status.to_sym
        raise InvalidNodeError, "unknown node: #{id}" unless @nodes.key?(id.to_s)
        raise InvalidTransitionError, "invalid status: #{status}" unless VALID_STATUSES.include?(status)

        node = @nodes[id.to_s]
        unless ALLOWED_TRANSITIONS[node.status].include?(status)
          raise InvalidTransitionError,
                "node #{id}: #{node.status} -> #{status} not allowed"
        end
        node.status = status
        node.error  = error if error

        propagate_failure!(node) if status == :failed
        node
      end

      # True when every node is in a terminal state (no more work possible).
      def all_completed?
        @nodes.each_value.all?(&:terminal?)
      end

      # Kahn's topological sort. Ties are broken by insertion order, which
      # (given a fixed input) yields a deterministic ordering across runs —
      # important because this ordering is fed into the WAL as step order.
      def topological_order
        in_degree = @nodes.transform_values { |n| n.depends_on.size }
        # Children map: dep_id → [ids that depend on it]
        children = Hash.new { |h, k| h[k] = [] }
        @nodes.each_value do |n|
          n.depends_on.each { |d| children[d] << n.id }
        end

        order = []
        # Seed with zero-in-degree nodes in insertion order.
        ready = @nodes.each_value.select { |n| in_degree[n.id].zero? }.map(&:id)
        until ready.empty?
          id = ready.shift
          order << id
          children[id].each do |child_id|
            in_degree[child_id] -= 1
            ready << child_id if in_degree[child_id].zero?
          end
        end

        raise CyclicGraphError, 'cycle detected' unless order.size == @nodes.size

        order
      end

      # Linearize the DAG into an Array of WAL-step Hashes. Each step has
      # the same shape Planner emits so WalPhaseRecorder / wal.commit_plan
      # can ingest the result unchanged.
      #
      # @param plan_id [String] propagated into per-step params for hashing.
      # @param cycle [Integer]
      def to_plan_steps(plan_id: 'plan_dag', cycle: 1)
        topological_order.each_with_index.map do |id, idx|
          n = @nodes[id]
          params = {
            node_id:    n.id,
            tool:       n.tool,
            args:       n.args,
            depends_on: n.depends_on,
            order:      idx,
            cycle:      cycle,
            plan_id:    plan_id
          }
          {
            step_id:            n.id,
            tool:               n.tool,
            params_hash:        Canonical.sha256_json(params),
            pre_hash:           Canonical.sha256_json({ node: n.id, state: 'pre', cycle: cycle }),
            expected_post_hash: Canonical.sha256_json({ node: n.id, state: 'post', cycle: cycle })
          }
        end
      end

      # ------------------------------------------------------------------ internals

      private

      def add_node(spec)
        raise InvalidNodeError, 'node spec must be a Hash' unless spec.is_a?(Hash)

        id = spec[:id] || spec['id']
        raise InvalidNodeError, 'node id required' if id.nil? || id.to_s.empty?

        id = id.to_s
        raise InvalidNodeError, "duplicate node id: #{id}" if @nodes.key?(id)

        tool = spec[:tool] || spec['tool']
        raise InvalidNodeError, "node #{id}: tool required" if tool.nil? || tool.to_s.empty?

        depends_on = Array(spec[:depends_on] || spec['depends_on']).map(&:to_s)
        policy = (spec[:failure_policy] || spec['failure_policy'] || :halt).to_sym
        unless VALID_POLICIES.include?(policy)
          raise InvalidNodeError, "node #{id}: invalid failure_policy #{policy.inspect}"
        end

        status = (spec[:status] || spec['status'] || :pending).to_sym
        unless VALID_STATUSES.include?(status)
          raise InvalidNodeError, "node #{id}: invalid status #{status.inspect}"
        end

        @nodes[id] = Node.new(
          id:             id,
          tool:           tool.to_s,
          args:           spec[:args] || spec['args'] || {},
          depends_on:     depends_on,
          status:         status,
          failure_policy: policy,
          error:          nil
        )
      end

      def validate_references!
        @nodes.each_value do |n|
          n.depends_on.each do |dep|
            next if @nodes.key?(dep)

            raise InvalidNodeError, "node #{n.id}: depends_on references unknown node #{dep}"
          end
        end
      end

      def validate_no_self_dep!
        @nodes.each_value do |n|
          next unless n.depends_on.include?(n.id)

          raise CyclicGraphError, "node #{n.id}: self-dependency"
        end
      end

      # Kahn's algorithm. If we fail to drain every node, the remaining
      # subgraph contains a cycle.
      def validate_acyclic!
        in_degree = @nodes.transform_values { |n| n.depends_on.size }
        children = Hash.new { |h, k| h[k] = [] }
        @nodes.each_value do |n|
          n.depends_on.each { |d| children[d] << n.id }
        end

        ready = @nodes.each_value.select { |n| in_degree[n.id].zero? }.map(&:id)
        processed_ids = []
        until ready.empty?
          id = ready.shift
          processed_ids << id
          children[id].each do |child_id|
            in_degree[child_id] -= 1
            ready << child_id if in_degree[child_id].zero?
          end
        end

        return if processed_ids.size == @nodes.size

        remaining = @nodes.keys - processed_ids
        raise CyclicGraphError, "cycle detected involving: #{remaining.inspect}"
      end

      # A dependency is satisfied when it is :completed, OR when it is :failed
      # with :continue policy (the failure was explicitly absorbed).
      def deps_satisfied?(node)
        node.depends_on.all? do |d|
          dep = @nodes[d]
          next false unless dep

          dep.completed? || (dep.failed? && dep.failure_policy == :continue)
        end
      end

      # When a node fails, apply its policy. For :halt we sweep all pending
      # nodes; for :skip_dependents we sweep only the transitive closure
      # downstream. :continue is a no-op — unrelated nodes stay runnable.
      def propagate_failure!(failed_node)
        case failed_node.failure_policy
        when :halt
          @nodes.each_value do |n|
            n.status = :cancelled if n.pending?
          end
        when :skip_dependents
          cancel_descendants_of(failed_node.id)
        when :continue
          # no-op — peer nodes remain runnable.
        end
      end

      # BFS over the reverse edges (children) starting at `root_id`,
      # cancelling every :pending descendant. Already-terminal nodes are
      # never resurrected; running nodes are left alone because their
      # execution sits outside TaskDag's control surface.
      def cancel_descendants_of(root_id)
        children = Hash.new { |h, k| h[k] = [] }
        @nodes.each_value do |n|
          n.depends_on.each { |d| children[d] << n.id }
        end

        queue = children[root_id].dup
        visited = {}
        until queue.empty?
          cid = queue.shift
          next if visited[cid]

          visited[cid] = true
          node = @nodes[cid]
          node.status = :cancelled if node&.pending?
          children[cid].each { |gc| queue << gc unless visited[gc] }
        end
      end
    end
  end
end
