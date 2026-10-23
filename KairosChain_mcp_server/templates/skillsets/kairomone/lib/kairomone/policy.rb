# frozen_string_literal: true

module Kairomone
  class PolicyRefusal < Error; end

  # The operator's growth limit, counted for the whole host (design v0.6
  # Inv 2, M6). Kairomone_Core ships no policy: absent means unlimited. A
  # policy file that is present but unreadable refuses every claim. The claim
  # count lives outside every individual, so no restore, import, fusion or edit
  # of an individual lowers it, and Kairomone never lowers it either.
  class Policy
    DIR = 'kairomone-policy'
    POLICY = 'kairomone-policy/policy.json'
    COUNTER = 'kairomone-policy/counter.json'
    LOCK = 'kairomone-policy/.lock'
    WINDOWS = %w[month lifetime].freeze

    def initialize(host_root:, clock: -> { Time.now.utc })
      @host_root = host_root
      @clock = clock
    end

    # Admits one claim: refuses when the policy is unreadable or its window is
    # used up, and otherwise increments the counter. Called last among a
    # claim's checks, because the count it adds is never taken back.
    def admit!
      with_lock do
        policy = read_policy
        counts = read_counter
        now = @clock.call.utc
        if policy
          used = counts.fetch(key(policy['window'], now), 0)
          if used >= policy['max_claims']
            raise PolicyRefusal, "The operator policy admits #{policy['max_claims']} claims per #{policy['window']} on this host; " \
                                 "#{used} are used"
          end
        end
        counts['lifetime'] = counts.fetch('lifetime', 0) + 1
        month = key('month', now)
        counts[month] = counts.fetch(month, 0) + 1
        Paths.write(@host_root, COUNTER, JSON.pretty_generate('schema_version' => 1, 'counts' => counts) + "\n", replace: true)
        { counted: true, window_used: policy ? counts[key(policy['window'], now)] : nil }
      end
    end

    def status
      policy = begin
        read_policy
      rescue PolicyRefusal => e
        return { declared: true, readable: false, error: e.message }
      end
      counts = begin
        read_counter
      rescue PolicyRefusal => e
        return { declared: !policy.nil?, readable: false, error: e.message }
      end
      now = @clock.call.utc
      return { declared: false, limit: nil, note: 'No operator policy: Kairomone_Core sets no limit on growth cycles.', claims_counted: counts.fetch('lifetime', 0) } unless policy

      used = counts.fetch(key(policy['window'], now), 0)
      { declared: true, readable: true, max_claims: policy['max_claims'], window: policy['window'], used: used,
        remaining: [policy['max_claims'] - used, 0].max }
    end

    private

    def key(window, now) = window == 'month' ? now.strftime('%Y-%m') : 'lifetime'

    def read_policy
      path = Paths.checked(@host_root, POLICY)
      return nil unless File.exist?(path) || File.symlink?(path)

      value = JSON.parse(Paths.read(@host_root, POLICY, limit: 4096))
      valid = value.is_a?(Hash) && (value.keys - ['schema_version']).sort == %w[max_claims window] &&
              value['max_claims'].is_a?(Integer) && value['max_claims'] >= 0 && WINDOWS.include?(value['window'])
      raise PolicyRefusal, 'The operator policy file is present but not readable as {max_claims, window: month|lifetime}; every claim is refused' unless valid

      value
    rescue JSON::ParserError, Error => e
      raise e if e.is_a?(PolicyRefusal)

      raise PolicyRefusal, "The operator policy file is present but unreadable (#{e.message}); every claim is refused"
    end

    def read_counter
      path = Paths.checked(@host_root, COUNTER)
      return {} unless File.exist?(path) || File.symlink?(path)

      value = JSON.parse(Paths.read(@host_root, COUNTER, limit: 65_536))
      counts = value['counts'] if value.is_a?(Hash) && value['schema_version'] == 1
      valid = counts.is_a?(Hash) && counts.all? { |k, v| (k == 'lifetime' || /\A\d{4}-\d{2}\z/.match?(k)) && v.is_a?(Integer) && v >= 0 }
      raise PolicyRefusal, 'The host claim counter is unreadable; claims are refused until the operator repairs it' unless valid

      counts
    rescue JSON::ParserError, Error => e
      raise e if e.is_a?(PolicyRefusal)

      raise PolicyRefusal, "The host claim counter is unreadable (#{e.message}); claims are refused until the operator repairs it"
    end

    def with_lock
      Paths.mkdir(@host_root, DIR)
      lock = Paths.checked(@host_root, LOCK)
      Paths.regular_file!(lock, optional: true, limit: 1024)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |io|
        io.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
