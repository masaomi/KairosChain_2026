# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

module KairosMcp
  module SkillSets
    module Dream
      # DigestEvents — the generation and check events of dream_digest (design v0.13, I7).
      #
      # One append-only log per topic, kept apart from the digest artifact: the artifact is
      # derived and may be deleted or regenerated without losing an event. An event is one
      # line. The store, not the caller, sets what orders and identifies it: `seq`, `prev`
      # (the id of the event before it), `recorded_at`, and `id`, the hash of everything else
      # in the line. A log in which any line fails that chain is not read at all.
      #
      # This class has no method that changes or removes an event. It cannot stop a process
      # with write access to the data directory from replacing the file; the chain makes a
      # partial rewrite detectable, and the id anchored on the instance's blockchain by the
      # tool makes a whole one detectable by audit. Labels do not consult the anchor.
      class DigestEvents
        class CorruptError < StandardError; end

        # A verified log, oldest event first.
        class Log
          attr_reader :events

          def initialize(events)
            @events = events
          end

          # The latest generation event recorded for the topic: the same event for every reader.
          def current_generation
            @events.reverse_each.find { |e| e['kind'] == 'generation' }
          end

          def generation(id)
            @events.find { |e| e['kind'] == 'generation' && e['id'] == id }
          end

          def checks_naming(generation_id)
            @events.select { |e| e['kind'] == 'check' && e['generation'] == generation_id }
          end
        end

        def initialize(base_dir)
          @base_dir = base_dir
        end

        # Topic slugs that have a log.
        def slugs
          return [] unless Dir.exist?(@base_dir)

          Dir.children(@base_dir).filter_map { |f| f[/\A([a-z0-9_]+)\.jsonl\z/, 1] }.sort
        end

        # @return [Log] empty when the topic has no log
        # @raise [CorruptError] when the log does not verify
        def load(slug)
          path = path_for(slug)
          return Log.new([]) unless File.exist?(path)

          Log.new(verified(complete_lines(File.read(path))))
        end

        # Append one event. The block receives the verified log as it stands under the lock and
        # returns the event's fields; raising in the block appends nothing.
        #
        # @return [Hash] the event as recorded
        def append(slug)
          FileUtils.mkdir_p(@base_dir)
          File.open(path_for(slug), File::RDWR | File::CREAT, 0o600) do |f|
            f.flock(File::LOCK_EX)
            lines = complete_lines(f.read)
            events = verified(lines)
            fields = yield Log.new(events)

            event = seal(fields, seq: events.size + 1, prev: events.last && events.last['id'])
            # A fragment left by an append that never completed was never an event; the next
            # event starts where the last complete one ends.
            kept = lines.sum { |l| l.bytesize + 1 }
            f.truncate(kept)
            f.seek(kept)
            f.write("#{JSON.generate(event)}\n")
            f.flush
            f.fsync
            event
          end
        end

        private

        def path_for(slug)
          raise ArgumentError, "not a topic slug: #{slug.inspect}" unless slug.to_s.match?(/\A[a-z0-9_]+\z/)

          File.join(@base_dir, "#{slug}.jsonl")
        end

        # Lines terminated by a newline. Bytes after the last newline are an append that did
        # not complete.
        def complete_lines(raw)
          raw = raw.to_s
          cut = raw.rindex("\n")
          cut ? raw[0..cut].split("\n") : []
        end

        def verified(lines)
          prev = nil
          lines.each_with_index.map do |line, i|
            event = begin
              JSON.parse(line)
            rescue JSON::ParserError
              raise CorruptError, "event #{i + 1} is not a record"
            end
            ok = event.is_a?(Hash) && event['seq'] == i + 1 && event['prev'] == prev &&
                 event['id'] == event_id(event)
            raise CorruptError, "event #{i + 1} does not verify" unless ok

            prev = event['id']
            event
          end
        end

        def seal(fields, seq:, prev:)
          event = stringify(fields)
          %w[id seq prev recorded_at].each { |k| event.delete(k) }
          event['seq'] = seq
          event['prev'] = prev
          event['recorded_at'] = Time.now.utc.iso8601(6)
          event['id'] = event_id(event)
          event
        end

        def event_id(event)
          Digest::SHA256.hexdigest("dream_digest.event\0#{canonical(event.reject { |k, _| k == 'id' })}")
        end

        # JSON with keys in sorted order at every depth: one byte sequence per event content.
        def canonical(value)
          case value
          when Hash then "{#{value.sort_by { |k, _| k.to_s }.map { |k, v| "#{JSON.generate(k.to_s)}:#{canonical(v)}" }.join(',')}}"
          when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
          else JSON.generate(value)
          end
        end

        def stringify(value)
          case value
          when Hash then value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
          when Array then value.map { |v| stringify(v) }
          when Symbol then value.to_s
          else value
          end
        end
      end
    end
  end
end
