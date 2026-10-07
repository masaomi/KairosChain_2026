# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'securerandom'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # The act route's allow-list (design v0.3, INV-A1 / INV-A2).
      #
      # A step runs on the act route only if its tool is in the effective
      # classification table. Every other step is set aside for the operator,
      # the way a step marked requires_human_cognition is.
      #
      # The table is a norm, so it is in force only by an operator act: the
      # latest attested ruling for the table must name the sha256 of the file's
      # bytes. A missing ruling, a withdrawal, a mismatch, or a table that fails
      # validation all yield the empty table — nothing classified, every step
      # to the operator. This includes the base table shipped with the gem: an
      # upgrade that changes its bytes leaves the act route empty until the
      # operator rules on the new hash.
      #
      # Attestation boundary (INV-D8): a ruling is attested when it was entered
      # at the operator's terminal (see .interactive_rule). Any party that can
      # write the chain or the stores — an MCP caller, the calling session, a
      # shell — could write a block of the same shape. The constrained party is
      # the agent, which cannot: its act route denies record-store writers and
      # protected locations, and the file route is not reachable.
      module ActClassification
        TABLE_ID = 'act_classification'
        RULING_KIND = 'agent_table_ruling'
        BASE_PATH = File.expand_path('act_classification.yml', __dir__)

        # Effect classes a table may admit, and the risk each carries. Anything
        # else (L0, record-store, irreversible, outward) is not admissible.
        EFFECT_RISK = {
          'read_only' => 'low',
          'session_record' => 'low',
          'llm_sandboxed' => 'low',
          'reversible_local' => 'medium'
        }.freeze

        # Effects that land in the live tree. Under the guard those belong to
        # the confined route (AGT-1), which is not wired, so they are set aside.
        # Without the guard they are classified only for a step whose every
        # location lands inside the table's write_roots with one of its
        # write_extensions (design v0.3 §6.5 as ruled 2026-10-06): writes are
        # allowed by place, because refusing by place — naming each location
        # a tool executes — did not close (implementation review R1 found an
        # editor add-on path the name list missed).
        LIVE_TREE_EFFECTS = %w[reversible_local].freeze

        RISK_ORDER = %w[low medium high].freeze

        # Names a table may never admit, whatever their class: the tools the
        # 3.88.2 deny-lists refuse, the L0/L1 store writers, and the file
        # route's tools (classification precedes routing: no route is reachable
        # through a tool this table cannot name).
        def self.forbidden_patterns
          adm = ::KairosMcp::SkillSets::Agent::Admission
          adm::RECORD_STORE_TOOLS + adm::ACT_CONFIG_WRITERS + adm::LAYER_WRITE_TOOLS.values.flatten +
            ::KairosMcp::SkillSets::Agent::MandateAdapter::FILE_TOOL_NAMES
        end

        module_function

        def sha256_of(path)
          Digest::SHA256.hexdigest(File.binread(path))
        end

        # Ruling records in chain order, from blocks whose data is an array of
        # strings. Entries that are not JSON objects of the ruling kind are
        # skipped.
        def rulings_from_blocks(blocks)
          Array(blocks).flat_map do |block|
            data = block.respond_to?(:data) ? block.data : (block['data'] || block[:data])
            Array(data).filter_map do |entry|
              rec = entry.is_a?(String) ? (JSON.parse(entry) rescue nil) : entry
              rec if rec.is_a?(Hash) && rec['kind'] == RULING_KIND
            end
          end
        end

        # Where rulings are read from. nil in production (the instance chain).
        # Tests set a callable returning [rulings, error], built from blocks the
        # real interactive_rule appended to an in-memory chain.
        class << self
          attr_accessor :rulings_source
        end

        # [rulings, nil] from the instance chain, or [[], reason] when the
        # chain cannot be read (which empties the table).
        def chain_rulings
          return ActClassification.rulings_source.call if ActClassification.rulings_source

          require 'kairos_mcp/kairos_chain/chain'
          chain = ::KairosMcp::KairosChain::Chain.new
          state = chain.load_state
          return [[], "chain #{state}"] unless %i[readable absent].include?(state)

          [rulings_from_blocks(chain.chain), nil]
        rescue StandardError, ScriptError => e
          [[], "chain unreadable: #{e.class}: #{e.message[0, 120]}"]
        end

        # The effective table: { 'status', 'sha256', 'ruled_sha256', 'tools', 'detail' }.
        # status is 'in_force' only when every condition holds; otherwise tools
        # is empty and status names the first condition that failed.
        def load_effective(path: BASE_PATH, rulings: nil, rulings_error: nil)
          rulings, rulings_error = chain_rulings if rulings.nil? && rulings_error.nil?
          raw = begin
            File.binread(path)
          rescue StandardError => e
            return empty('table_unreadable', nil, detail: "#{e.class}: #{e.message[0, 120]}")
          end
          sha = Digest::SHA256.hexdigest(raw)
          return empty('chain_unreadable', sha, detail: rulings_error) if rulings_error

          latest = Array(rulings).select { |r| r['table'] == TABLE_ID && r['attested'] == true }.last
          return empty('no_ruling', sha) unless latest
          return empty('withdrawn', sha, ruling: latest) if latest['action'] == 'withdraw'
          return empty('invalid_ruling', sha, ruling: latest) unless latest['action'] == 'activate'
          return empty('hash_mismatch', sha, ruling: latest) unless latest['sha256'] == sha

          table, error = parse_table(raw)
          return empty('invalid', sha, ruling: latest, detail: error) if error

          table.merge('status' => 'in_force', 'sha256' => sha, 'ruled_sha256' => latest['sha256'],
                      'ruled_at' => latest['ruled_at'])
        end

        def empty(status, sha, ruling: nil, detail: nil)
          out = { 'status' => status, 'sha256' => sha, 'tools' => {}, 'write_roots' => [], 'write_extensions' => [],
                  'write_name_prefix' => nil }
          out['ruled_sha256'] = ruling['sha256'] if ruling
          out['detail'] = detail if detail
          out
        end

        # [table, nil] or [nil, error]. table: { 'tools' => { name => { 'effect',
        # 'risk', 'locations' } }, 'write_roots' => [relative dirs],
        # 'write_extensions' => ['.md', ...] }.
        def parse_table(raw)
          doc = YAML.safe_load(raw)
          return [nil, 'not a mapping with a tools mapping'] unless doc.is_a?(Hash) && doc['tools'].is_a?(Hash)

          forbidden = forbidden_patterns
          tools = {}
          doc['tools'].each do |name, row|
            name = name.to_s
            return [nil, "row #{name}: not a mapping"] unless row.is_a?(Hash)

            effect = row['effect'].to_s
            return [nil, "row #{name}: effect #{effect.inspect} is not admissible"] unless EFFECT_RISK.key?(effect)
            if forbidden.any? { |pat| File.fnmatch(pat, name) }
              return [nil, "row #{name}: refused by the act-route deny-lists"]
            end

            locations = row['locations'] || []
            unless locations.is_a?(Array) && locations.all? { |l| l.is_a?(String) && !l.empty? }
              return [nil, "row #{name}: locations must be a list of argument names"]
            end

            tools[name] = { 'effect' => effect, 'risk' => EFFECT_RISK[effect], 'locations' => locations }
          end

          roots = doc['write_roots'] || []
          exts = doc['write_extensions'] || []
          return [nil, 'write_roots must be a list of directories'] unless roots.is_a?(Array) && roots.all?(String)
          return [nil, 'write_extensions must be a list such as .md'] unless exts.is_a?(Array) && exts.all?(String)

          adm = ::KairosMcp::SkillSets::Agent::Admission
          roots = roots.map { |r| r.strip.sub(%r{/+\z}, '') }
          bad_root = roots.find do |r|
            parts = r.split(%r{[/\\]})
            r.empty? || r.match?(/[[:cntrl:]\\]/) || r.start_with?('/', '~') || parts.include?('..') ||
              parts.include?('.') || parts.any?(&:empty?) ||
              adm.protected_name?(r)
          end
          return [nil, "write_roots: #{bad_root.inspect} must be a relative directory inside the project"] if bad_root

          exts = exts.map { |e| e.strip.downcase }
          bad_ext = exts.find { |e| !e.match?(/\A\.[a-z0-9]+\z/) }
          return [nil, "write_extensions: #{bad_ext.inspect} is not an extension such as .md"] if bad_ext

          prefix = doc['write_name_prefix']
          unless prefix.nil? || (prefix.is_a?(String) && prefix.match?(/\A[a-z0-9][a-z0-9_-]*\z/))
            return [nil, "write_name_prefix: #{prefix.inspect} is not a plain prefix such as draft_"]
          end

          if tools.any? { |_, r| LIVE_TREE_EFFECTS.include?(r['effect']) } && (roots.empty? || exts.empty? || prefix.nil?)
            return [nil, 'a reversible_local row needs write_roots, write_extensions and write_name_prefix']
          end

          [{ 'tools' => tools, 'write_roots' => roots, 'write_extensions' => exts,
             'write_name_prefix' => prefix }, nil]
        rescue Psych::Exception => e
          [nil, "YAML: #{e.message[0, 120]}"]
        end

        # The step's tool row, or nil when the step is not classified for this
        # act. A live-tree effect is classified only without the guard and only
        # when write_scope (a callable from the driver, which knows the roots a
        # tool resolves against) accepts the step; no write_scope, no write.
        def row_for(step, effective, guard: false, write_scope: nil)
          return nil unless step.is_a?(Hash)

          row = effective['tools'][step['tool_name'].to_s]
          return nil unless row
          if LIVE_TREE_EFFECTS.include?(row['effect'])
            return nil if guard || write_scope.nil? || !write_scope.call(step)
          end

          row
        end

        # The higher of the table's risk and the plan's own label: the label may
        # raise a step's risk, never lower it. The label is the step's risk, or
        # the plan's risk_default when the step names none; a label that is not
        # one of low / medium / high (in any case) counts as high.
        def resolved_risk(row, step_risk)
          label = step_risk.to_s.downcase
          own = RISK_ORDER.include?(label) ? label : 'high'
          [row['risk'], own].max_by { |r| RISK_ORDER.index(r) }
        end

        # [copy, set_aside]. The copy marks every unclassified step for the
        # operator and carries the resolved risk on classified ones. set_aside
        # lists what the driver marked: [{ 'step_id', 'tool_name' }].
        def apply(task_json, effective, guard: false, write_scope: nil)
          copy = JSON.parse(JSON.generate(task_json || {}))
          set_aside = []
          default_risk = copy['meta'].is_a?(Hash) ? copy['meta']['risk_default'] : nil
          Array(copy['steps']).each do |step|
            next unless step.is_a?(Hash)

            row = row_for(step, effective, guard: guard, write_scope: write_scope)
            if row
              step['risk'] = resolved_risk(row, step['risk'].nil? ? (default_risk || 'low') : step['risk'])
            elsif step['requires_human_cognition'] != true
              step['requires_human_cognition'] = true
              set_aside << { 'step_id' => step['step_id'], 'tool_name' => step['tool_name'] }
            end
          end
          [copy, set_aside]
        end

        # Values of the step's location arguments as the table names them. A
        # step the table does not classify (or no table in force) falls back to
        # the common names, so the signals do not go quiet without a ruling.
        FALLBACK_LOCATIONS = %w[file_path path source destination].freeze

        def location_values(step, effective)
          row = effective && effective['tools'][step['tool_name'].to_s]
          names = row ? row['locations'] : FALLBACK_LOCATIONS
          args = step['tool_arguments'].is_a?(Hash) ? step['tool_arguments'] : {}
          names.filter_map { |n| args[n].is_a?(String) ? args[n] : nil }
        end

        # ---- the terminal ruling (INV-D8) ----

        NONCE_ALPHABET = %w[a c d e f h j k m n p r t u v w x y 3 4 7 9].freeze

        def nonce
          Array.new(6) { NONCE_ALPHABET[SecureRandom.random_number(NONCE_ALPHABET.size)] }.join
        end

        # Shows what is about to be ruled on tty_out, asks for the nonce on
        # tty_in, and appends the ruling to the chain only when the typed nonce
        # matches. action: 'activate' (the file's current bytes) or 'withdraw'.
        # Returns { 'recorded' => bool, ... }.
        def interactive_rule(action:, tty_in:, tty_out:, path: BASE_PATH, chain: nil, nonce_value: nonce)
          raise ArgumentError, "action must be activate or withdraw, not #{action.inspect}" unless %w[activate withdraw].include?(action)

          sha = nil
          if action == 'activate'
            # One read: the hash ruled on is the hash of the bytes shown.
            raw = File.binread(path)
            sha = Digest::SHA256.hexdigest(raw)
            table, error = parse_table(raw)
            if error
              tty_out.puts "Refused: #{path} is not a valid table (#{error})."
              return { 'recorded' => false, 'reason' => 'invalid', 'detail' => error }
            end
            tty_out.puts "Table:  #{TABLE_ID}"
            tty_out.puts "File:   #{path}"
            tty_out.puts "sha256: #{sha}"
            tty_out.puts 'Tools the act route may run once this ruling is recorded:'
            table['tools'].sort.each { |name, row| tty_out.puts "  #{name.ljust(18)} #{row['effect']}" }
            tty_out.puts "Work-tree writes (reversible_local) only inside: #{table['write_roots'].join(', ')}"
            tty_out.puts "  and only for files named #{table['write_name_prefix']}* ending in: #{table['write_extensions'].join(', ')}"
            tty_out.puts '  (with the guard on, work-tree writes are set aside regardless)'
          else
            tty_out.puts "Withdraw table #{TABLE_ID}: the act route will run nothing until a new ruling."
          end
          tty_out.puts
          tty_out.print "Type #{nonce_value} to record this ruling (anything else cancels): "
          tty_out.flush
          typed = tty_in.gets.to_s.strip
          unless typed == nonce_value
            tty_out.puts 'Cancelled. Nothing was recorded.'
            return { 'recorded' => false, 'reason' => 'nonce_mismatch' }
          end

          record = { 'kind' => RULING_KIND, 'table' => TABLE_ID, 'action' => action, 'sha256' => sha,
                     'attested' => true, 'attestation' => 'terminal_nonce',
                     'ruled_at' => Time.now.utc.iso8601 }
          chain ||= begin
            require 'kairos_mcp/kairos_chain/chain'
            ::KairosMcp::KairosChain::Chain.new
          end
          block = chain.add_block([JSON.generate(record)])
          tty_out.puts "Recorded as block ##{block.index}."
          { 'recorded' => true, 'block_index' => block.index, 'record' => record }
        end
      end
    end
  end
end
