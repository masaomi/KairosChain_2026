# frozen_string_literal: true

module Kairomone
  # Each Kairomone keeps its own ledger. Core's FileBackend rewrites the ledger
  # file in place (File.write); a crash in the middle of that write would leave
  # a truncated ledger. This subclass writes a temporary file beside it, syncs
  # it, and renames it over the ledger, so a reader sees the old sequence or
  # the new one and never a half-written file. It is passed through the
  # existing `backend:` hook; core is not patched.
  class AtomicLedgerBackend < KairosMcp::Storage::FileBackend
    def save_all_blocks(blocks)
      FileUtils.mkdir_p(File.dirname(@blockchain_file))
      temp = "#{@blockchain_file}.tmp-#{SecureRandom.hex(8)}"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |io|
          io.write(JSON.pretty_generate(blocks.map { |b| block_to_hash(b) }))
          io.flush
          io.fsync
        end
        File.rename(temp, @blockchain_file)
        sync_directory(File.dirname(@blockchain_file))
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
      true
    rescue StandardError => e
      raise KairosMcp::Storage::Error, "failed to save blocks to #{@blockchain_file}: #{e.message}"
    end

    private

    def sync_directory(dir)
      File.open(dir, File::RDONLY) { |d| d.fsync }
    rescue SystemCallError
      nil # Not every filesystem lets a directory be synced; the rename stands.
    end
  end

  # The records Kairomone appends to an individual's ledger. Existing blocks
  # never change; a record is read back after its append before anything that
  # depends on it is done.
  module Records
    module_function

    # Every parseable record on a readable ledger, in ledger order, each with
    # the index of its block. Unparseable data is skipped here; readers that
    # must not skip a record of their own type check for it themselves.
    def each(ledger)
      return enum_for(:each, ledger) unless block_given?
      return unless ledger.load_state == :readable

      ledger.chain.each do |block|
        Array(block.data).each do |raw|
          record = begin
            JSON.parse(raw) if raw.is_a?(String)
          rescue JSON::ParserError
            nil
          end
          yield record, block.index if record.is_a?(Hash)
        end
      end
    end

    def of_type(ledger, *types)
      each(ledger).select { |record, _index| types.include?(record['type']) }.map(&:first)
    end

    # Appends records in one block and confirms them on a fresh read. Raises
    # Error unless the ledger now ends with exactly these records.
    def append!(ledger, records, reread)
      raise Error, "Cannot record: the ledger is #{ledger.load_state}" unless %i[absent readable].include?(ledger.load_state)

      data = records.map { |r| JSON.generate(r) }
      begin
        ledger.add_block(data)
      rescue StandardError => e
        after = begin
          reread.call
        rescue StandardError
          nil
        end
        return after.latest_block if after&.load_state == :readable && after.latest_block&.data == data

        raise Error, "Could not record on the ledger; nothing that depends on it was done: #{e.message}"
      end
      after = reread.call
      raise Error, 'The ledger record could not be confirmed; nothing that depends on it was done' unless after.load_state == :readable && after.latest_block&.data == data

      after.latest_block
    end
  end
end
