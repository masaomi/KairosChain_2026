# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # The journal is the run (design v0.5 INV-6): an append-only JSONL file
      # in which every line carries the SHA-256 of the line before it, so the
      # last line's digest names the whole history. Appends hold an exclusive
      # flock, because the MCP server and the host's hook processes write the
      # same file. Nothing else holds run state; Run replays this file.
      class Journal
        GENESIS = '0' * 64

        attr_reader :path

        def initialize(path)
          @path = path
          FileUtils.mkdir_p(File.dirname(path))
        end

        # Appends one entry and returns it as written (with seq, at, prev). With
        # id_prefix the entry's id is the prefix plus its seq, allocated under
        # the lock, so concurrent writers never share an id.
        def append(kind, data = nil, id_prefix: nil, **fields)
          data = (data || {}).merge(fields)
          File.open(@path, File::RDWR | File::CREAT, 0o600) do |f|
            f.flock(File::LOCK_EX)
            last = last_line(f)
            prev = last ? Digest::SHA256.hexdigest(last) : GENESIS
            seq = last_seq(f) + 1
            entry = { 'seq' => seq, 'at' => Time.now.utc.iso8601(3), 'kind' => kind.to_s,
                      'prev' => prev }.merge(stringify(data))
            entry['id'] = "#{id_prefix}#{seq}" if id_prefix
            line = JSON.generate(entry)
            f.seek(0, IO::SEEK_END)
            # A writer killed mid-line left no newline; the next entry starts
            # on its own line so it is not glued to the torn text.
            if f.size.positive?
              f.seek(-1, IO::SEEK_END)
              torn = f.read(1) != "\n"
              f.seek(0, IO::SEEK_END)
              f.write("\n") if torn
            end
            f.write(line + "\n")
            f.flush
            entry
          end
        end

        # A line a killed writer left torn is skipped here (and makes intact?
        # false); the chain still names it, so nothing is hidden.
        def entries
          lines.filter_map do |l|
            JSON.parse(l)
          rescue JSON::ParserError
            nil
          end
        end

        def digest
          last = lines.last
          last ? Digest::SHA256.hexdigest(last) : GENESIS
        end

        # True when every line names its predecessor's digest.
        def intact?
          prev = GENESIS
          lines.each do |line|
            return false unless JSON.parse(line)['prev'] == prev

            prev = Digest::SHA256.hexdigest(line)
          end
          true
        rescue JSON::ParserError
          false
        end

        # The lines as a writer left them: read under the shared lock.
        def lines
          return [] unless File.exist?(@path)

          File.open(@path, 'r:UTF-8') do |f|
            f.flock(File::LOCK_SH)
            f.each_line.map(&:chomp).reject(&:empty?)
          end
        end

        private

        def last_line(f)
          f.rewind
          last = nil
          f.each_line { |l| last = l.chomp unless l.strip.empty? }
          last
        end

        def last_seq(f)
          f.rewind
          seq = 0
          f.each_line do |l|
            n = (JSON.parse(l)['seq'] rescue nil)
            seq = n if n.is_a?(Integer) && n > seq
          end
          seq
        end

        def stringify(data)
          JSON.parse(JSON.generate(data))
        end
      end
    end
  end
end
