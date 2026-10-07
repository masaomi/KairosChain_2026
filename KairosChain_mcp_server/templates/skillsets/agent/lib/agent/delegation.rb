# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # The delegation table (design v0.3, INV-A2 / INV-D2 / INV-D3).
      #
      # Which approval points a delegate judges beside the operator. Phase 1
      # has one approver kind (judge) and one mode (shadow), and the loader
      # refuses a table that names anything else, so with or without a table
      # every point returns to the operator.
      #
      # In force by the rule the classification table follows: the latest
      # attested agent_table_ruling for table 'delegation' names this file's
      # sha256. That ruling also pins what the judge reads (judge_reads) by
      # path and sha256, so the material the judge decides by is material the
      # operator ruled on (INV-D1); a changed file takes the table out of
      # force until the operator rules again.
      module Delegation
        TABLE_ID = 'delegation'
        BASE_PATH = File.expand_path('delegation_table.yml', __dir__)

        # The two points a row may name (design v0.3 §1): plan approval in a
        # manual session, and the scheduled end-of-cycle checkpoint.
        POINTS = %w[plan_proposed cycle_checkpoint].freeze

        # The driver's signals that it computes from the plan's structure
        # (steps, tools, location arguments). The other two are the plan's own
        # claims: design_scope is read from DECIDE's summary, and high_risk
        # from a risk label the plan may raise (INV-P: declared, never
        # observed). Rows are matched, and precedents chosen, by these alone,
        # so the summary's wording and the plan's labels choose neither
        # (INV-D1). The structure is still the plan's own: a plan can add a
        # signal (a sixth step, a read under lib/). For rows that only adds to
        # the floor (INV-D3) — it can keep a point from being judged, never
        # make one judged; for precedents it selects the rulings that carried
        # the same signal.
        OBSERVED_SIGNALS = %w[many_steps l0_change core_files multi_file state_mutation].freeze
        MATCHABLE_SIGNALS = OBSERVED_SIGNALS

        # What a table may give the judge to read, by symbolic name.
        READABLE = %w[instruction_mode].freeze

        TOP_KEYS = %w[version judge_reads precedents rows].freeze
        ROW_KEYS = %w[id point signals_absent approver mode].freeze
        MAX_PRECEDENTS = 10

        # The judge (design v0.3 §4, operator decision §6.2). No fallback
        # provider: a judge that cannot be reached as this does not answer.
        JUDGE = { 'provider' => 'claude_code', 'model' => 'claude-opus-5-5', 'effort' => 'xhigh' }.freeze

        class << self
          # Test seam: a callable name -> [absolute_path, nil] | [nil, reason].
          # nil in production (resolve_read).
          attr_accessor :read_resolver
        end

        module_function

        # [table, nil] or [nil, error]. table: { 'judge_reads' => [names],
        # 'precedents_max' => Integer, 'rows' => [row] }.
        def parse_table(raw)
          doc = YAML.safe_load(raw)
          return [nil, 'not a mapping'] unless doc.is_a?(Hash)

          extra = doc.keys.map(&:to_s) - TOP_KEYS
          return [nil, "unknown keys: #{extra.join(', ')}"] unless extra.empty?
          return [nil, 'version must be 1'] unless doc.fetch('version', 1) == 1

          reads = doc['judge_reads'] || []
          return [nil, 'judge_reads must be a list of names'] unless reads.is_a?(Array) && reads.all?(String)

          bad = reads - READABLE
          return [nil, "judge_reads: #{bad.join(', ')} cannot be read (readable: #{READABLE.join(', ')})"] unless bad.empty?

          prec = doc['precedents'] || {}
          return [nil, 'precedents must be a mapping with max'] unless prec.is_a?(Hash) && (prec.keys.map(&:to_s) - %w[max]).empty?

          max = prec.fetch('max', 0)
          unless max.is_a?(Integer) && max.between?(0, MAX_PRECEDENTS)
            return [nil, "precedents.max must be an integer from 0 to #{MAX_PRECEDENTS}"]
          end

          rows = doc['rows']
          return [nil, 'rows must be a list'] unless rows.is_a?(Array)

          ids = []
          parsed = rows.each_with_index.map do |row, i|
            label = "row #{i + 1}"
            return [nil, "#{label}: not a mapping"] unless row.is_a?(Hash)

            extra = row.keys.map(&:to_s) - ROW_KEYS
            return [nil, "#{label}: unknown keys: #{extra.join(', ')}"] unless extra.empty?

            id = row['id']
            return [nil, "#{label}: id must be a name such as cycle_checkpoint"] unless id.is_a?(String) && id.match?(/\A[a-z0-9_]+\z/)
            return [nil, "row #{id}: the id is used twice"] if ids.include?(id)

            ids << id
            return [nil, "row #{id}: point must be one of #{POINTS.join(', ')}"] unless POINTS.include?(row['point'])
            if row['approver'] == 'mlr'
              return [nil, "row #{id}: approver mlr is not available in phase 1 (its verdict is a vote ratio, " \
                           'which the project has declared non-conclusive)']
            end
            return [nil, "row #{id}: approver must be judge"] unless row['approver'] == 'judge'
            unless row['mode'] == 'shadow'
              return [nil, "row #{id}: mode #{row['mode'].inspect} is refused; phase 1 runs shadow rows only"]
            end

            absent = row['signals_absent'] || []
            return [nil, "row #{id}: signals_absent must be a list"] unless absent.is_a?(Array) && absent.all?(String)

            bad = absent - MATCHABLE_SIGNALS
            unless bad.empty?
              return [nil, "row #{id}: signals_absent may name only #{MATCHABLE_SIGNALS.join(', ')} (not #{bad.join(', ')})"]
            end

            { 'id' => id, 'point' => row['point'], 'signals_absent' => absent, 'approver' => 'judge', 'mode' => 'shadow' }
          end

          [{ 'judge_reads' => reads, 'precedents_max' => max, 'rows' => parsed }, nil]
        rescue Psych::Exception => e
          [nil, "YAML: #{e.message[0, 120]}"]
        end

        # [absolute_path, nil] or [nil, reason]: the file the server reads for
        # a readable name. instruction_mode follows the server's own resolution
        # of the active mode (Protocol#load_instructions).
        def resolve_read(name)
          return Delegation.read_resolver.call(name) if Delegation.read_resolver
          return [nil, "#{name} cannot be read"] unless name == 'instruction_mode'

          require 'kairos_mcp/skills_config'
          mode = ::KairosMcp::SkillsConfig.load['instructions_mode'] || 'tutorial'
          path = case mode
                 when 'developer' then ::KairosMcp.md_path
                 when 'user' then ::KairosMcp.quickguide_path
                 when 'tutorial' then ::KairosMcp.tutorial_path
                 when 'none' then nil
                 else File.join(::KairosMcp.skills_dir, "#{mode}.md")
                 end
          return [nil, 'no instruction mode is active'] unless path
          return [nil, "#{path} is not readable"] unless File.file?(path)

          [File.expand_path(path), nil]
        rescue StandardError, ScriptError => e
          [nil, "#{e.class}: #{e.message[0, 120]}"]
        end

        # [[{ 'name', 'path', 'bytes', 'sha256' }], nil] or [nil, reason]. One
        # read per file: the hash is of the bytes counted.
        def read_pins(names)
          pins = names.map do |name|
            path, error = resolve_read(name)
            return [nil, "#{name}: #{error}"] if error

            raw = File.binread(path)
            { 'name' => name, 'path' => path, 'bytes' => raw.bytesize, 'sha256' => Digest::SHA256.hexdigest(raw) }
          end
          [pins, nil]
        rescue StandardError => e
          [nil, "#{e.class}: #{e.message[0, 120]}"]
        end

        # Names whose path or bytes differ from the ruling's pins, or that one
        # side has and the other does not.
        def changed_reads(pins, ruled)
          ruled = Array(ruled).select { |r| r.is_a?(Hash) }
          names = (pins.map { |p| p['name'] } + ruled.map { |r| r['name'] }).uniq
          names.reject do |n|
            now = pins.find { |p| p['name'] == n }
            then_ = ruled.find { |r| r['name'] == n }
            now && then_ && now['path'] == then_['path'] && now['sha256'] == then_['sha256']
          end
        end

        # The effective table: { 'status', 'sha256', 'rows', 'judge_reads',
        # 'precedents_max', 'reads' (pins), 'detail' }. status is 'in_force'
        # only when every condition holds; otherwise rows is empty.
        def load_effective(path: BASE_PATH, rulings: nil, rulings_error: nil)
          ac = ::KairosMcp::SkillSets::Agent::ActClassification
          rulings, rulings_error = ac.chain_rulings if rulings.nil? && rulings_error.nil?
          raw = begin
            File.binread(path)
          rescue StandardError => e
            return empty('table_unreadable', nil, detail: "#{e.class}: #{e.message[0, 120]}")
          end
          sha = Digest::SHA256.hexdigest(raw)
          return empty('chain_unreadable', sha, detail: rulings_error) if rulings_error

          latest = Array(rulings).select { |r| r['table'] == TABLE_ID && r['attested'] == true }.last
          return empty('no_ruling', sha) unless latest
          return empty('withdrawn', sha) if latest['action'] == 'withdraw'
          return empty('invalid_ruling', sha) unless latest['action'] == 'activate'
          return empty('hash_mismatch', sha) unless latest['sha256'] == sha

          table, error = parse_table(raw)
          return empty('invalid', sha, detail: error) if error

          pins, error = read_pins(table['judge_reads'])
          return empty('reads_unresolvable', sha, detail: error) if error

          changed = changed_reads(pins, latest['reads'])
          unless changed.empty?
            return empty('reads_changed', sha,
                         detail: "#{changed.join(', ')} changed since the ruling; the judge reads only what was ruled on")
          end

          table.merge('status' => 'in_force', 'sha256' => sha, 'reads' => pins, 'ruled_at' => latest['ruled_at'])
        end

        def empty(status, sha, detail: nil)
          out = { 'status' => status, 'sha256' => sha, 'rows' => [], 'judge_reads' => [], 'precedents_max' => 0,
                  'reads' => [] }
          out['detail'] = detail if detail
          out
        end

        # The first row, in file order, for this point whose absent signals
        # are all absent. nil when none matches.
        def match(effective, point, signals)
          Array(effective['rows']).find do |row|
            row['point'] == point && (row['signals_absent'] & Array(signals)).empty?
          end
        end

        # ---- the terminal ruling (INV-A2 / INV-D8) ----

        # As ActClassification.interactive_rule, for this table: shows the
        # rows and what the judge will read, asks for the nonce, and records a
        # ruling that names the table's sha256 and pins every read.
        def interactive_rule(action:, tty_in:, tty_out:, path: BASE_PATH, chain: nil,
                             nonce_value: ::KairosMcp::SkillSets::Agent::ActClassification.nonce)
          raise ArgumentError, "action must be activate or withdraw, not #{action.inspect}" unless %w[activate withdraw].include?(action)

          sha = nil
          pins = nil
          if action == 'activate'
            raw = File.binread(path)
            sha = Digest::SHA256.hexdigest(raw)
            table, error = parse_table(raw)
            pins, error = read_pins(table['judge_reads']) unless error
            if error
              tty_out.puts "Refused: #{path} cannot be ruled into force (#{error})."
              return { 'recorded' => false, 'reason' => 'invalid', 'detail' => error }
            end
            tty_out.puts "Table:  #{TABLE_ID}"
            tty_out.puts "File:   #{path}"
            tty_out.puts "sha256: #{sha}"
            tty_out.puts "Phase 1: every row is shadow. A judge (#{JUDGE['model']}, effort #{JUDGE['effort']}, " \
                         "through #{JUDGE['provider']}) answers beside you at these points; its verdict is sealed " \
                         'before your answer, shown after it, and changes nothing.'
            table['rows'].each do |row|
              absent = row['signals_absent'].empty? ? '' : " unless the driver sees #{row['signals_absent'].join(', ')}"
              tty_out.puts "  #{row['id'].ljust(22)} at #{row['point']}#{absent}"
            end
            tty_out.puts 'The judge reads (pinned by this ruling; a change takes the table out of force):'
            pins.each { |p| tty_out.puts "  #{p['name']}: #{p['path']} (#{p['bytes']} bytes, sha256 #{p['sha256']})" }
            tty_out.puts "and up to #{table['precedents_max']} of your earlier terminal answers at the same stop " \
                         'with the same signals.'
          else
            tty_out.puts "Withdraw table #{TABLE_ID}: no judge runs until a new ruling."
          end
          tty_out.puts
          tty_out.print "Type #{nonce_value} to record this ruling (anything else cancels): "
          tty_out.flush
          unless tty_in.gets.to_s.strip == nonce_value
            tty_out.puts 'Cancelled. Nothing was recorded.'
            return { 'recorded' => false, 'reason' => 'nonce_mismatch' }
          end

          record = { 'kind' => ::KairosMcp::SkillSets::Agent::ActClassification::RULING_KIND, 'table' => TABLE_ID,
                     'action' => action, 'sha256' => sha, 'attested' => true, 'attestation' => 'terminal_nonce',
                     'ruled_at' => Time.now.utc.iso8601 }
          record['reads'] = pins.map { |p| p.slice('name', 'path', 'sha256') } if pins
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
