# frozen_string_literal: true

module Kairomone
  # The host L0 baseline in force is derived, never stored twice: the
  # fingerprints recorded at init, replaced in ledger order by each owner
  # ruling on the dedicated ledger. profile.json stays create-only, and a
  # backup carries every ruling because it carries the ledger.
  #
  # A ruling is reachable only through a terminal (/dev/tty, a nonce typed
  # back), which keeps MCP calls off this path. It does not prove a person
  # typed: any process that can start programs can open a pseudo-terminal,
  # read the nonce and type it back, and a process that can run arbitrary
  # Ruby can write the ledger directly. 'attestation' records the path the
  # ruling came by, not who was at the keyboard; what keeps an assistant off
  # it is its standing rule, not this mechanism.
  class Instance
    REBASELINE_TYPE = 'kairomone_l0_rebaseline'
    REBASELINE_KEYS = %w[type schema_version dot_id previous next reason host_kairos_chain_version attested attestation ruled_at].freeze
    DEFAULT_REBASELINE_REASON = 'No reason given at the terminal'
    NONCE_ALPHABET = %w[a c d e f h j k m n p r t u v w x y 3 4 7 9].freeze

    def self.rebaseline_nonce
      Array.new(6) { NONCE_ALPHABET[SecureRandom.random_number(NONCE_ALPHABET.size)] }.join
    end

    # => { baseline: {path => sha256}, source: {'kind' => 'init'} or
    #      {'kind' => 'ruling', 'block' => index, 'ruled_at' => time} }
    # Raises Error when the baseline in force cannot be known: an unreadable
    # ledger, or a ruling that is malformed or does not follow its predecessor.
    def effective_l0_baseline(ledger = chain)
      value = profile
      baseline = value['host_l0_baseline']
      source = { 'kind' => 'init' }
      case ledger.load_state
      when :absent then return { baseline: baseline, source: source }
      when :readable then nil
      else raise Error, "L0 baseline unavailable: dedicated ledger is #{ledger.load_state}"
      end
      ledger.chain.each do |block|
        Array(block.data).each do |data|
          event = begin
            JSON.parse(data) if data.is_a?(String)
          rescue JSON::ParserError
            nil
          end
          unless event.is_a?(Hash)
            # A ruling that cannot be read is not absent: refuse rather than skip it.
            raise Error, "L0 baseline unavailable: unreadable re-baseline ruling in block #{block.index}" if data.to_s.include?(REBASELINE_TYPE)
            next
          end
          next unless event['type'] == REBASELINE_TYPE
          validate_rebaseline_event!(event, value['dot_id'])
          raise Error, "L0 baseline unavailable: the ruling in block #{block.index} does not follow the baseline in force" unless event['previous'] == baseline
          baseline = event['next']
          source = { 'kind' => 'ruling', 'block' => block.index, 'ruled_at' => event['ruled_at'] }
        end
      end
      { baseline: baseline, source: source }
    end

    # Shows the transition on tty_out, asks for the nonce on tty_in, and
    # records the ruling only when the typed nonce matches and nothing shown
    # has changed meanwhile. Every line goes through tty_safe: stored text
    # (name, reason, timestamps, paths) must not redraw what is being accepted.
    def rebaseline_l0_interactive(tty_in:, tty_out:, reason: DEFAULT_REBASELINE_REASON, nonce: self.class.rebaseline_nonce)
      raise Error, 'Restored targets are read-only; re-baseline the active instance' if @restored
      reason = text!(reason, 'reason', 512)
      ensure_initialized!
      value = profile
      effective = effective_l0_baseline
      current = l0_fingerprints
      say = ->(line) { tty_out.puts tty_safe(line) }
      say.call "Dot:      #{value['dot_id']} (#{value['display_name']})"
      say.call "Instance: #{root}"
      say.call "Baseline in force: #{baseline_source_label(effective[:source], value)}"
      (effective[:baseline].keys | current.keys).sort.each do |path|
        was, now = effective[:baseline][path], current[path]
        change = if was.nil? then 'appeared' elsif now.nil? then 'absent now' elsif was == now then 'same' else 'changed' end
        say.call "  #{path.ljust(16)} #{short_hash(was)} -> #{short_hash(now)}  #{change}"
      end
      raise Error, 'No host L0 file is present; there is nothing to accept as a baseline' if current.empty?
      if current == effective[:baseline]
        say.call 'Nothing to re-baseline: host L0 matches the baseline in force. Nothing was recorded.'
        return { success: true, recorded: false, reason: 'unchanged', baseline: current }
      end
      growth = autonomy.status
      budget = growth['configured'] ? "#{growth['used_cycles']} of #{growth['max_cycles']} attempts used, #{growth['stopped'] ? 'stopped' : 'not stopped'}" : 'not configured'
      say.call "Host:     kairos-chain #{host_version}"
      say.call "Growth:   #{budget}. A re-baseline changes neither the budget nor the stop state."
      say.call "Reason:   #{reason}"
      say.call 'This records, on this dot\'s own ledger, that you accept the host L0 above as its reference.'
      say.call 'It does not copy, install or change any L0 file.'
      tty_out.print "Type #{nonce} to record this ruling (anything else cancels): "
      tty_out.flush
      unless tty_in.gets.to_s.strip == nonce
        say.call 'Cancelled. Nothing was recorded.'
        return { success: false, recorded: false, reason: 'nonce_mismatch' }
      end
      block = autonomy.send(:record_rebaseline, expected_previous: effective[:baseline], expected_next: current, reason: reason)
      say.call "Recorded as block ##{block.index} on the dedicated Kairomone ledger."
      { success: true, recorded: true, block: block.index, previous: effective[:baseline], next: current }
    end

    private

    # Called by Autonomy under the growth lock, after a live claim was refused.
    def append_rebaseline(expected_previous:, expected_next:, reason:)
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        ledger = chain
        raise Error, "Cannot record: dedicated ledger is #{ledger.load_state}" unless %i[absent readable].include?(ledger.load_state)
        effective = effective_l0_baseline(ledger)
        current = l0_fingerprints
        raise Error, 'The baseline in force changed after it was shown; nothing was recorded' unless effective[:baseline] == expected_previous
        raise Error, 'Host L0 changed after it was shown; nothing was recorded' unless current == expected_next
        raise Error, 'No host L0 file is present; there is nothing to accept as a baseline' if current.empty?
        raise Error, 'Nothing to re-baseline: host L0 matches the baseline in force' if current == effective[:baseline]
        dot_id = profile['dot_id']
        event = { 'type' => REBASELINE_TYPE, 'schema_version' => 1, 'dot_id' => dot_id,
                  'previous' => effective[:baseline], 'next' => current, 'reason' => reason,
                  'host_kairos_chain_version' => host_version, 'attested' => true,
                  'attestation' => 'terminal_nonce', 'ruled_at' => Time.now.utc.iso8601 }
        validate_rebaseline_event!(event, dot_id)
        block = ledger.add_block([JSON.generate(event)])
        # Never infer the ruling from the append's return: read the ledger again.
        after = effective_l0_baseline(chain)
        raise Error, 'The ruling could not be verified on the dedicated ledger; inspect status before retrying' unless after[:baseline] == current && after[:source]['block'] == block.index
        block
      end
    end

    def validate_rebaseline_event!(event, dot_id)
      valid = event.keys.sort == REBASELINE_KEYS.sort && event['schema_version'] == 1 && event['dot_id'] == dot_id &&
              event['attested'] == true && event['attestation'] == 'terminal_nonce' &&
              baseline_map?(event['previous'], allow_empty: true) && baseline_map?(event['next'], allow_empty: false) &&
              event['reason'].is_a?(String) && event['reason'].valid_encoding? && !event['reason'].strip.empty? && event['reason'].bytesize <= 512 &&
              event['host_kairos_chain_version'].is_a?(String) && event['host_kairos_chain_version'].bytesize.between?(1, 64)
      Time.iso8601(event['ruled_at'].to_s)
      raise Error, 'L0 baseline unavailable: malformed re-baseline ruling on the dedicated ledger' unless valid
    rescue ArgumentError
      raise Error, 'L0 baseline unavailable: malformed re-baseline ruling on the dedicated ledger'
    end

    def baseline_map?(value, allow_empty:)
      value.is_a?(Hash) && (allow_empty || !value.empty?) && (value.keys - L0_FILES).empty? &&
        value.values.all? { |v| v.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(v) }
    end

    def baseline_source_label(source, value)
      return "recorded at kairomone_init (#{value['created_at']})" if source['kind'] == 'init'
      "ruling in ledger block ##{source['block']} (#{source['ruled_at']})"
    end

    def host_version
      defined?(KairosMcp::VERSION) ? KairosMcp::VERSION.to_s[0, 64] : 'unknown'
    end

    def short_hash(value) = value ? "#{value[0, 12]}…" : '(absent)'.ljust(13)

    # Stored text goes to a terminal: control, format (bidi) and line-separator
    # characters would let it redraw or reorder what the owner is accepting.
    def tty_safe(text) = text.to_s.gsub(/[\p{Cc}\p{Cf}\u2028\u2029]/) { |c| format('\\u%04x', c.ord) }
  end
end
