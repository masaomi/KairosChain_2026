# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module KairosMcp
  module SkillSets
    module ModelProvenance
      # The KairosChain-owned observation record (design v0.3 INV-2, INV-3).
      #
      # This module knows nothing about Claude Code's transcript format. The
      # hook script writes records here; other SkillSets (multi_llm_review)
      # read them. Records are append-only: each is one file, written whole to
      # a temporary name and renamed into place, so concurrent writers cannot
      # interleave and a reader never sees half a record.
      #
      # Layout: <data dir>/model_provenance/<session_id>/<kind>-<key>-<stamp>.json
      module ObservationStore
        ROOT = 'model_provenance'
        SAFE = /\A[A-Za-z0-9_.\-]{1,128}\z/
        NO_RECORD = 'no record for this binding at collect'
        # Observation records carry the version of the reading rules that made
        # them. Records from earlier rules (0.1.0 during review, which misread
        # Skill bodies as resumes) are kept — the store is append-only — but a
        # binding never resolves to them.
        SCHEMA = 2

        module_function

        def root(data_dir)
          File.join(data_dir, ROOT)
        end

        def session_dir(data_dir, session_id)
          raise ArgumentError, "unsafe session id: #{session_id.inspect}" unless SAFE.match?(session_id.to_s)

          File.join(root(data_dir), session_id.to_s)
        end

        # Monotonic-enough, sortable, and unique across concurrent writers.
        def stamp
          format('%<t>020d-%<r>s', t: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
                                  r: SecureRandom.hex(4))
        end

        # Write one record. Never overwrites: the name carries a fresh stamp.
        def append(data_dir, session_id, kind, key, record)
          raise ArgumentError, "unsafe kind/key: #{kind}/#{key}" unless SAFE.match?(kind.to_s) && SAFE.match?(key.to_s)

          dir = session_dir(data_dir, session_id)
          FileUtils.mkdir_p(dir)
          name = "#{kind}-#{key}-#{stamp}.json"
          tmp = File.join(dir, ".#{name}.tmp")
          File.write(tmp, JSON.generate(record.merge('kind' => kind, 'written_at' => Time.now.utc.iso8601(3))))
          File.rename(tmp, File.join(dir, name))
          name
        end

        # Records of one kind (and key, when given) in a session, oldest first.
        # An unreadable file is returned as such rather than skipped, so a torn
        # or corrupted record surfaces as a cause instead of vanishing.
        def records(data_dir, session_id, kind, key = nil)
          dir = session_dir(data_dir, session_id)
          pattern = key ? "#{kind}-#{key}-*.json" : "#{kind}-*.json"
          Dir.glob(File.join(dir, pattern)).sort.map { |path| load(path) }
        end

        def load(path)
          JSON.parse(File.read(path)).merge('_file' => File.basename(path))
        rescue JSON::ParserError, SystemCallError => e
          { '_file' => File.basename(path), '_unreadable' => "#{e.class}: #{e.message}"[0, 200] }
        end

        # The observation a persona binding resolves to (INV-7): the newest
        # record covering the subagent's latest run, from any session. Agent ids
        # are unique, so the session need not be known here — which matters,
        # because collect cannot know it.
        #
        # Returns a Hash with 'state' => 'observed' | 'unobserved'. The cause of
        # an unobserved result names what this layer saw, never which layer
        # failed (INV-3).
        def resolve_binding(data_dir, agent_id)
          id = agent_id.to_s
          return unobserved('binding malformed') unless SAFE.match?(id)

          # The glob also matches ids that merely begin with this one; the
          # file name is checked exactly, so an unreadable file is attributed too.
          paths = Dir.glob(File.join(root(data_dir), '*', "observation-agent_#{id}-*.json"))
                     .select { |p| id_of(p) == id }
          return unobserved(NO_RECORD) if paths.empty?

          loaded = paths.map { |p| load(p) }.select { |r| r['_unreadable'] || current?(r) }
          return unobserved(NO_RECORD) if loaded.empty?

          unreadable = loaded.select { |r| r['_unreadable'] }
          readable = loaded.reject { |r| r['_unreadable'] }
          # The newest record decides whether the latest state is known. When it
          # cannot be read, an older readable one is not the answer: it may
          # describe an earlier run.
          newest = loaded.max_by { |r| r['_file'].to_s }
          if newest['_unreadable']
            return unobserved("newest record unreadable at collect (#{unreadable.size} of #{loaded.size} unreadable)")
          end

          # A newest record that itself says "unobserved" (e.g. the transcript was
          # absent at SubagentStop) is the latest word; nothing older overrides it.
          return newest.merge('record' => newest['_file']) if newest['state'] == 'unobserved'

          # Within the latest run a complete record outranks an incomplete one,
          # whichever was written last (the Stop backstop and SubagentStop can
          # land in either order).
          best = readable.max_by { |r| [r['run'].to_i, r['complete'] == true ? 1 : 0, r['_file'].to_s] }
          out = best.merge('state' => best['state'] || 'observed', 'record' => best['_file'])
          out['unreadable_records'] = unreadable.size if unreadable.any?
          out
        end

        # "observation-agent_<id>-<20-digit stamp>-<hex>.json" -> "<id>"
        def id_of(path)
          File.basename(path).sub(/\Aobservation-agent_/, '').sub(/-\d{20}-[0-9a-f]+\.json\z/, '')
        end

        def current?(record)
          record['schema'] == SCHEMA
        end

        def unobserved(cause)
          { 'state' => 'unobserved', 'cause' => cause, 'detected_by' => 'kairoschain:observation_store' }
        end
      end
    end
  end
end
