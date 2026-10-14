# frozen_string_literal: true

require 'uri'
require 'ipaddr'

module Kairomone
  # A bounded local protocol, not a scheduler, web client, LLM or background worker.
  # The host assistant supplies researched evidence. External text is data only.
  class Autonomy
    HARD_CAP = 10
    MAX_LEASE = 900
    STATE_PATH = 'growth/state.json'
    STATES = %w[completed failed expired interrupted].freeze

    def initialize(instance:, clock: -> { Time.now.utc })
      @instance, @clock = instance, clock
    end

    def configure(max_cycles: HARD_CAP, already_used: 0)
      validate_budget!(max_cycles, already_used)
      locked do
        state = read_state
        if state
          raise Error, 'Budget cannot be reset or expanded' unless state['max_cycles'] == max_cycles && state['initial_used'] == already_used
        else
          state = initial(max_cycles, already_used)
          state['stopped'] = true
          state['stop_reason'] = 'Configured without starting work; explicit resume required'
          save(state)
        end
        public_state(state)
      end
    end

    def request(request_id:, topic:, max_cycles: HARD_CAP, already_used: 0, resume: false, profession_id: 'generalist', bias_applied: false)
      id!(request_id)
      text!(topic, 'topic', 512)
      Paths.id!(profession_id)
      profession = @instance.profession_status
      raise Error, 'Profession must match the selected instance profession' unless profession_id == profession[:effective_id]
      raise Error, 'Profession bias needs selected profession topics' if bias_applied && Array(profession.dig(:learning_bias, :topics)).empty?
      raise Error, 'bias_applied and resume must be boolean' unless [true, false].include?(bias_applied) && [true, false].include?(resume)
      validate_budget!(max_cycles, already_used)
      locked do
        state = read_state || initial(max_cycles, already_used)
        expire!(state)
        raise Error, 'Budget is immutable; request cannot reset or expand it' unless state['max_cycles'] == max_cycles && state['initial_used'] == already_used
        existing = state['requests'][request_id]
        proposal = { 'request_id' => request_id, 'topic' => topic, 'profession_id' => profession_id, 'bias_applied' => bias_applied }
        if existing
          raise Error, 'request_id already used with different input' unless existing['request'].reject { |k, _v| k == 'companion' } == proposal
          next public_state(state).merge('preserved' => true)
        end
        raise Error, 'Request history limit reached' if state['requests'].length >= HARD_CAP * 2
        raise Error, 'Cycle budget exhausted' if state['used_cycles'] >= state['max_cycles']
        raise Error, 'A request or claim is already pending' if state['queue'] || state['active_claim']
        raise Error, 'Stopped; explicit resume:true is required' if state['stopped'] && !resume
        # Starting neutral ensures the profession-specific fraction never exceeds 1/2.
        total = state['requests'].length + 1
        biased = state['requests'].values.count { |r| r['request']['bias_applied'] } + (bias_applied ? 1 : 0)
        raise Error, 'Profession bias may cover at most half of requested topics' if biased * 2 > total
        snapshot = @instance.companion_status[:companion]
        proposal['companion'] = { 'revision' => snapshot['revision'], 'direction' => snapshot['direction'] }
        state['stopped'] = false
        state['queue'] = proposal
        state['requests'][request_id] = { 'request' => proposal, 'state' => 'queued', 'attempted' => false }
        save(state)
        public_state(state)
      end
    end

    def claim(worker_id:, lease_seconds: 300)
      Paths.id!(worker_id)
      raise Error, 'Lease must be an integer between 1 and 900 seconds' unless lease_seconds.is_a?(Integer) && (1..MAX_LEASE).cover?(lease_seconds)
      locked do
        state = required_state
        expire!(state)
        raise Error, 'Growth is stopped' if state['stopped']
        raise Error, 'Another worker owns the active claim' if state['active_claim']
        raise Error, 'No queued request' unless state['queue']
        raise Error, 'Cycle budget exhausted' if state['used_cycles'] >= state['max_cycles']
        request = state['queue']; state['queue'] = nil
        state['used_cycles'] += 1
        state['active_claim'] = request.merge('claim_token' => SecureRandom.hex(24), 'worker_id' => worker_id,
          'claimed_at' => timestamp, 'heartbeat_at' => timestamp, 'expires_at' => (@clock.call + lease_seconds).utc.iso8601,
          'lease_seconds' => lease_seconds)
        state['requests'][request['request_id']]['state'] = 'claimed'
        state['requests'][request['request_id']]['attempted'] = true
        state['requests'][request['request_id']]['claim_token'] = state['active_claim']['claim_token']
        save(state)
        public_state(state).merge('claim_token' => state['active_claim']['claim_token'])
      end
    end

    def heartbeat(claim_token:)
      locked do
        state = required_state; claim = live_claim!(state, claim_token)
        claim['heartbeat_at'] = timestamp
        # A claim has an absolute deadline. Heartbeats report liveness, never extend authority.
        save(state)
        public_state(state)
      end
    end

    def commit(claim_token:, evidence:)
      normalized = validate_evidence!(evidence)
      digest = Digest::SHA256.hexdigest(JSON.generate(normalized))
      locked do
        state = required_state
        prior = state['requests'].values.find { |r| r['claim_token'] == claim_token && r['state'] == 'completed' }
        if prior
          raise Error, 'Completed claim retried with different evidence' unless prior['evidence_sha256'] == digest
          next prior['result'].merge('preserved' => true)
        end
        claim = live_claim!(state, claim_token)
        entry = state['requests'].fetch(claim['request_id'])
        raise Error, 'Retry evidence differs from persisted commit intent' if entry['evidence_sha256'] && entry['evidence_sha256'] != digest
        entry['claim_token'] = claim_token
        entry['evidence_sha256'] = digest
        entry['state'] = 'committing'
        save(state) # Durable intent before either canonical write.
        identifier = "growth_#{claim['request_id']}"
        # No tool names, paths, commands, policy changes or source instructions are dispatched.
        body = knowledge_body(normalized, digest)
        verify_l0!
        live_claim!(state, claim_token)
        l1 = @instance.create_knowledge(id: identifier, title: normalized['knowledge']['title'], content: body)
        raise Error, 'Canonical L1 write/ledger verification failed; inspect pending state' unless l1[:success] && l1[:recorded_on_chain]
        live_claim!(state, claim_token)
        l2 = @instance.observe(id: identifier, title: "Growth evidence: #{claim['request_id']}",
          content: JSON.pretty_generate({ 'kind' => 'untrusted_research_evidence', 'request' => entry['request'], 'evidence' => normalized,
            'evidence_sha256' => digest, 'l1_id' => identifier, 'model_weights_changed' => false }))
        raise Error, 'Canonical L2 write failed' unless l2[:success]
        result = { 'state' => 'completed', 'request_id' => claim['request_id'], 'l1_id' => identifier,
          'l2_id' => l2[:id], 'evidence_sha256' => digest, 'source_count' => normalized['sources'].length,
          'completed_at' => timestamp, 'model_weights_changed' => false }
        entry['state'] = 'completed'; entry['result'] = result
        state['last_result'] = result; state['active_claim'] = nil
        state['stopped'] = true if state['used_cycles'] >= state['max_cycles']
        save(state)
        result
      end
    end

    def fail(claim_token:, reason:)
      text!(reason, 'reason', 512)
      locked do
        state = required_state; live_claim!(state, claim_token)
        finish!(state, 'failed', reason)
        save(state); public_state(state)
      end
    end

    def stop(reason: 'Explicit stop')
      text!(reason, 'reason', 512)
      locked do
        state = required_state
        finish!(state, 'interrupted', reason) if state['active_claim']
        if state['queue']
          state['requests'][state['queue']['request_id']]['state'] = 'interrupted'
          state['queue'] = nil
        end
        state['stopped'] = true; state['stop_reason'] = reason
        save(state); public_state(state)
      end
    end

    # Only a completed, cross-checked growth transaction can strip metadata for XP.
    # Ordinary user JSON never gains this privilege just by resembling an envelope.
    def progression_content(id:, l1_body:, l2_body:)
      state = read_state
      return nil unless state && id.is_a?(String) && id.start_with?('growth_')
      request_id = id.delete_prefix('growth_')
      entry = state['requests'][request_id]
      return nil unless entry && entry['state'] == 'completed' && entry.dig('result', 'l1_id') == id && entry.dig('result', 'l2_id') == id
      envelope = JSON.parse(l2_body)
      return nil unless envelope.keys.sort == %w[kind request evidence evidence_sha256 l1_id model_weights_changed].sort && envelope['kind'] == 'untrusted_research_evidence' && envelope['request'] == entry['request'] && envelope['l1_id'] == id && envelope['model_weights_changed'] == false
      evidence = envelope.fetch('evidence')
      digest = Digest::SHA256.hexdigest(JSON.generate(evidence))
      return nil unless digest == entry['evidence_sha256'] && digest == envelope['evidence_sha256'] && l1_body.strip == knowledge_body(evidence, digest).strip
      norm = ->(text) { text.gsub("\r\n", "\n").strip }
      stable = %w[finding uncertainty counterexample].to_h { |key| [key, norm.call(evidence.fetch(key))] }
      stable['source_excerpts'] = evidence.fetch('sources').map { |source| norm.call(source.fetch('excerpt')) }.uniq.sort
      { l1: norm.call(evidence.fetch('knowledge').fetch('content')), l2: JSON.generate(stable) }
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      nil
    end

    def synchronize(&block) = locked(&block)

    # Atomic read, deliberately does not acquire growth lock while Instance#status
    # or backup holds the canonical lock. Expired claims are displayed offline.
    def status
      state = read_state
      return { 'schema_version' => 1, 'configured' => false, 'always_on' => false, 'worker_online' => false } unless state
      public_state(state)
    end

    def self.validate_backup_state!(state)
      raise Error, 'Invalid growth state' unless state.is_a?(Hash) && state['schema_version'] == 1
      expected = %w[schema_version max_cycles initial_used used_cycles stopped queue active_claim requests last_result stop_reason]
      raise Error, 'Unexpected growth fields' unless state.keys.sort == expected.sort
      cap, initial, used = state.values_at('max_cycles', 'initial_used', 'used_cycles')
      raise Error, 'Invalid growth budget' unless [cap, initial, used].all? { |x| x.is_a?(Integer) } && (1..HARD_CAP).cover?(cap) && (0..cap).cover?(initial) && (initial..cap).cover?(used)
      raise Error, 'Invalid growth stop flag' unless [true, false].include?(state['stopped'])
      requests = state['requests']
      raise Error, 'Invalid growth requests' unless requests.is_a?(Hash) && requests.length <= HARD_CAP * 2
      requests.each do |id, entry|
        raise Error, 'Invalid growth request ID' unless id.is_a?(String) && /\A[a-z][a-z0-9_-]{0,39}\z/.match?(id)
        raise Error, 'Unexpected growth request fields' unless entry.is_a?(Hash) && (entry.keys - %w[request state attempted claim_token evidence_sha256 result]).empty? && [true, false].include?(entry['attempted'])
        request = entry['request']
        raise Error, 'Invalid request data' unless request.is_a?(Hash) && (request.keys - ['companion']).sort == %w[request_id topic profession_id bias_applied].sort && request['topic'].is_a?(String) && request['topic'].bytesize.between?(1, 512) && Paths::ID.match?(request['profession_id'].to_s) && [true, false].include?(request['bias_applied'])
        validate_companion_snapshot!(request['companion']) if request.key?('companion')
        raise Error, 'Invalid attempted state' if %w[claimed committing completed failed expired].include?(entry['state']) && !entry['attempted']
        raise Error, 'Invalid attempt token' if entry['attempted'] && !/\A[0-9a-f]{48}\z/.match?(entry['claim_token'].to_s)
        raise Error, 'Invalid evidence digest' if entry['evidence_sha256'] && !/\A[0-9a-f]{64}\z/.match?(entry['evidence_sha256'].to_s)
        raise Error, 'Missing completed result' if entry['state'] == 'completed' && (!entry['result'].is_a?(Hash) || entry['result']['request_id'] != id || !entry['evidence_sha256'])
        raise Error, 'Invalid growth request entry' unless entry.is_a?(Hash) && %w[queued claimed committing completed failed expired interrupted].include?(entry['state']) && entry['request'].is_a?(Hash) && entry['request']['request_id'] == id
      end
      raise Error, 'Growth attempt count mismatch' unless requests.values.count { |r| r['attempted'] } == used - initial
      claim = state['active_claim']
      if claim
        raise Error, 'Invalid growth claim' unless claim.is_a?(Hash) && requests.key?(claim['request_id']) && claim['claim_token'].is_a?(String) && /\A[0-9a-f]{48}\z/.match?(claim['claim_token'])
        raise Error, 'Unexpected claim fields' unless (claim.keys - ['companion']).sort == %w[request_id topic profession_id bias_applied claim_token worker_id claimed_at heartbeat_at expires_at lease_seconds].sort
        raise Error, 'Claim companion snapshot mismatch' unless claim['companion'] == requests[claim['request_id']]['request']['companion']
        raise Error, 'Invalid claim lease' unless claim['lease_seconds'].is_a?(Integer) && (1..MAX_LEASE).cover?(claim['lease_seconds']) && Paths::ID.match?(claim['worker_id'].to_s)
        raise Error, 'Claim does not match attempted request' unless requests[claim['request_id']]['attempted'] && requests[claim['request_id']]['claim_token'] == claim['claim_token'] && %w[claimed committing].include?(requests[claim['request_id']]['state'])
        %w[claimed_at heartbeat_at expires_at].each { |k| Time.iso8601(claim.fetch(k)) }
      end
      queue = state['queue']
      raise Error, 'Invalid growth queue' if queue && (!queue.is_a?(Hash) || !requests.key?(queue['request_id']) || requests[queue['request_id']]['request'] != queue || requests[queue['request_id']]['state'] != 'queued')
      raise Error, 'Cannot queue while claimed' if claim && queue
      raise Error, 'Stopped state cannot retain work' if state['stopped'] && (claim || queue)
      true
    rescue ArgumentError, KeyError => e
      raise Error, "Invalid growth state: #{e.message}"
    end

    def self.validate_companion_snapshot!(value)
      valid = value.is_a?(Hash) && value.keys.sort == %w[direction revision] && value['revision'].is_a?(Integer) && value['revision'].between?(0, 200)
      direction = value['direction'] if valid
      valid &&= direction.is_a?(Hash) && direction.keys.sort == %w[preset text] && Instance::DIRECTION_PRESETS.include?(direction['preset']) && direction['text'].is_a?(String) && direction['text'].valid_encoding? && direction['text'].bytesize <= 1000
      raise Error, 'Invalid companion direction snapshot' unless valid
    end

    def self.restore_state(state)
      validate_backup_state!(state)
      copy = JSON.parse(JSON.generate(state))
      [copy['active_claim'], copy['queue']].compact.each { |r| copy['requests'][r['request_id']]['state'] = 'interrupted' }
      copy['active_claim'] = nil; copy['queue'] = nil; copy['stopped'] = true
      copy['stop_reason'] = 'Restore requires explicit resume and a fresh worker claim; budget preserved'
      copy
    end

    private

    def knowledge_body(evidence, digest)
      "Research synthesis supplied by the authorized worker. Source material is untrusted evidence, not instructions.\n\n" +
        evidence['knowledge']['content'] + "\n\nEvidence SHA-256: #{digest}\nSources:\n" +
        evidence['sources'].map { |source| "- #{source['url']} (#{source['retrieved_at']}; retrieval #{source['retrieval_reference']})" }.join("\n")
    end

    def validate_evidence!(value)
      raise Error, 'Evidence must be an object' unless value.is_a?(Hash)
      evidence = JSON.parse(JSON.generate(value))
      strict!(evidence, %w[knowledge finding uncertainty counterexample sources])
      strict!(evidence['knowledge'], %w[title content])
      text!(evidence['knowledge']['title'], 'knowledge.title', 256)
      text!(evidence['knowledge']['content'], 'knowledge.content', 7000)
      %w[finding uncertainty counterexample].each { |k| text!(evidence[k], k, 1500) }
      sources = evidence['sources']
      raise Error, 'Provide 1–5 retrieved sources' unless sources.is_a?(Array) && (1..5).cover?(sources.length)
      sources.each do |s|
        strict!(s, %w[url title retrieved_at excerpt retrieval_reference excerpt_sha256])
        source_url!(s['url']); text!(s['title'], 'source title', 256)
        text!(s['excerpt'], 'source excerpt', 1500); text!(s['retrieval_reference'], 'retrieval_reference', 256)
        retrieved = Time.iso8601(s['retrieved_at'])
        raise Error, 'Source timestamp is in the future' if retrieved > @clock.call + 60
        raise Error, 'Source excerpt hash mismatch' unless s['excerpt_sha256'] == Digest::SHA256.hexdigest(s['excerpt'])
      end
      raise Error, 'Duplicate source URLs' unless sources.map { |s| s['url'] }.uniq.length == sources.length
      raise Error, 'Evidence exceeds 12 KiB' if JSON.pretty_generate(evidence).bytesize > 12_288
      evidence
    rescue JSON::GeneratorError, JSON::ParserError, ArgumentError, TypeError => e
      raise Error, "Invalid evidence: #{e.message}"
    end

    def source_url!(value)
      text!(value, 'URL', 2000)
      uri = URI.parse(value)
      host = uri.host.to_s.downcase.sub(/\.+\z/, '')
      raise Error, 'Sources must be public HTTPS URLs without credentials, fragments or custom ports' unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? && host.include?('.') && !host.end_with?('.local', '.internal', '.localhost', '.test', '.invalid') && !host.match?(/\A[\d.]+\z/)
      # Literal IPs are intentionally unsupported. No DNS/network calls here.
      raise Error, 'IP-literal sources are not supported' if host.include?(':') || host.start_with?('[')
    rescue URI::InvalidURIError
      raise Error, 'Invalid source URL'
    end

    def strict!(value, keys)
      raise Error, "Expected fields: #{keys.join(', ')}" unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, label, limit)
      raise Error, "Invalid #{label}" unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && !value.include?("\0") && value.bytesize <= limit
      value
    end

    def id!(id)
      raise Error, 'request_id must be a lowercase identifier of 1–40 characters' unless id.is_a?(String) && /\A[a-z][a-z0-9_-]{0,39}\z/.match?(id)
    end

    def validate_budget!(cap, used)
      raise Error, 'Budget must be integers, cap 1–10 and already_used 0–cap' unless cap.is_a?(Integer) && used.is_a?(Integer) && (1..HARD_CAP).cover?(cap) && (0..cap).cover?(used)
    end

    def initial(cap, used)
      { 'schema_version' => 1, 'max_cycles' => cap, 'initial_used' => used, 'used_cycles' => used, 'stopped' => false,
        'queue' => nil, 'active_claim' => nil, 'requests' => {}, 'last_result' => nil, 'stop_reason' => nil }
    end

    def timestamp = @clock.call.utc.iso8601
    def read_state
      return nil unless File.exist?(Paths.checked(@instance.root, STATE_PATH))
      value = JSON.parse(Paths.read(@instance.root, STATE_PATH))
      self.class.validate_backup_state!(value)
      value
    rescue JSON::ParserError => e
      raise Error, "Unreadable growth state: #{e.message}"
    end
    def required_state = read_state || raise(Error, 'Request a bounded cycle first')
    def save(state) = Paths.write(@instance.root, STATE_PATH, JSON.pretty_generate(state) + "\n", replace: true)

    def locked
      @instance.send(:ensure_initialized!)
      raise Error, 'Restored targets are read-only' if @instance.instance_variable_get(:@restored)
      Paths.mkdir(@instance.root, 'growth')
      path = Paths.checked(@instance.root, 'growth/.lock')
      Paths.regular_file!(path, optional: true, limit: 1024)
      File.open(path, File::RDWR | File::CREAT, 0o600) { |f| f.flock(File::LOCK_EX); yield }
    end

    def verify_l0!
      expected = @instance.profile.fetch('host_l0_baseline')
      current = @instance.send(:l0_fingerprints)
      raise Error, 'L0 baseline unavailable or changed; automatic growth refused' if expected.empty? || current != expected
    end

    def expire!(state)
      return unless state['active_claim'] && Time.iso8601(state['active_claim']['expires_at']) <= @clock.call
      finish!(state, 'expired', 'Worker lease expired; consumed budget is not refunded')
      save(state)
    end

    def live_claim!(state, token)
      expire!(state)
      raise Error, 'Growth is stopped' if state['stopped']
      claim = state['active_claim']
      raise Error, 'Missing, stale or invalid claim' unless token.is_a?(String) && claim && claim['claim_token'] == token
      claim
    end

    def finish!(state, outcome, reason)
      claim = state['active_claim']; entry = state['requests'].fetch(claim['request_id'])
      entry['state'] = outcome
      state['last_result'] = { 'state' => outcome, 'request_id' => claim['request_id'], 'reason' => reason, 'at' => timestamp,
        'partial_writes_possible' => !!entry['evidence_sha256'] }
      state['active_claim'] = nil
    end

    def public_state(state)
      claim = state['active_claim']
      online = claim && !state['stopped'] && Time.iso8601(claim['expires_at']) > @clock.call && Time.iso8601(claim['heartbeat_at']) > @clock.call - 60
      { 'schema_version' => 1, 'configured' => true, 'max_cycles' => state['max_cycles'], 'used_cycles' => state['used_cycles'],
        'remaining_cycles' => state['max_cycles'] - state['used_cycles'], 'stopped' => state['stopped'], 'queue' => state['queue'],
        'active_claim' => claim&.reject { |k, _| k == 'claim_token' }, 'last_result' => state['last_result'],
        'worker_online' => !!online, 'worker_signal' => (online ? 'recent_heartbeat' : (claim ? 'stale_or_expired' : 'no_claim')), 'always_on' => false, 'stop_reason' => state['stop_reason'] }
    end
  end
end
