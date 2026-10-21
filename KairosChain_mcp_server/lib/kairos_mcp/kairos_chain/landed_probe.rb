# frozen_string_literal: true

require 'json'
require_relative 'chain'

module KairosMcp
  module KairosChain
    # Answers "did this exact entry reach the ledger?" after an append did not
    # return normally.
    #
    # Chain#add_block raises Storage::Error when it cannot tell whether the
    # write landed, and a thread can be interrupted after the write but before
    # add_block returns. Either way the caller holds a change it must keep
    # (the record is on the chain) or undo (it is not). Looking only at the last
    # block answers wrongly once anything else has been appended since, so the
    # caller takes a mark before appending and the probe scans every block after
    # that mark for an entry equal to the one the caller tried to append.
    module LandedProbe
      # The ledger length now, i.e. the index from which the caller's block can
      # appear. nil when the ledger cannot be read; every later status is then
      # :unknown.
      def self.mark(storage_backend: nil)
        chain = Chain.new(storage_backend: storage_backend)
        case chain.load_state
        when :readable then chain.chain.length
        when :absent then 0
        end
      rescue StandardError
        nil
      end

      # :landed  -- a block after the mark carries an entry equal to entry_json
      # :absent  -- the ledger is readable (or absent) and no such entry is there
      # :unknown -- the mark or the ledger could not be read
      #
      # Equality is on the parsed entry, so a backend that re-serialises the JSON
      # still matches. Only StandardError is absorbed: an interrupt during the
      # probe propagates, and callers run their undo in an ensure for that case.
      def self.status(mark, entry_json, storage_backend: nil)
        return :unknown if mark.nil?

        expected = JSON.parse(entry_json)
        chain = Chain.new(storage_backend: storage_backend)
        return :absent if chain.load_state == :absent
        return :unknown unless chain.load_state == :readable

        found = chain.chain.drop(mark).any? do |block|
          Array(block.data).any? do |raw|
            begin
              JSON.parse(raw.to_s) == expected
            rescue JSON::ParserError
              false
            end
          end
        end
        found ? :landed : :absent
      rescue StandardError
        :unknown
      end
    end
  end
end
