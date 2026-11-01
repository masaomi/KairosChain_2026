# frozen_string_literal: true

require 'json'

# The usage figure (design §3): the context size at the latest main-thread
# assistant response recorded at or after the cycle's offset in the
# transcript. Claude Code layer only (INV-9). The usage fields are observed,
# not documented (§2): input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens of message.usage.
module CompactionHandoffHook
  module UsageReader
    TAIL_BYTES = 1024 * 1024

    module_function

    # { tokens:, offset:, source: } or nil when no such response exists after
    # `from` (the cycle is then below the request point) or the transcript
    # cannot be read. Only the last TAIL_BYTES are read; a record cut by that
    # window or still being written is skipped.
    def read(path, from: 0)
      return nil unless path.is_a?(String) && File.file?(path)

      size = File.size(path)
      start = [size - TAIL_BYTES, from.to_i, 0].max
      return nil if start >= size

      chunk = File.open(path, 'rb') do |f|
        f.seek(start)
        f.read(size - start)
      end
      offset = start
      found = nil
      chunk.each_line do |line|
        here = offset
        offset += line.bytesize
        next unless line.end_with?("\n")

        tokens = usage_of(line)
        found = { tokens: tokens, offset: here, source: 'transcript_usage' } if tokens
      end
      found
    rescue SystemCallError, IOError
      nil
    end

    def usage_of(line)
      return nil unless line.include?('"usage"')

      rec = JSON.parse(line)
      return nil unless rec.is_a?(Hash) && rec['type'] == 'assistant' && rec['isSidechain'] != true

      u = rec.dig('message', 'usage')
      return nil unless u.is_a?(Hash)

      parts = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens].map { |k| u[k] }
      return nil unless parts.all? { |v| v.nil? || v.is_a?(Integer) } && parts.any?(Integer)

      parts.sum(&:to_i)
    rescue JSON::ParserError
      nil
    end
  end
end
