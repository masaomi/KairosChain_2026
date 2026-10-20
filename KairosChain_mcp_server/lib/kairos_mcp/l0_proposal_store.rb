# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'digest'
require_relative '../kairos_mcp'

module KairosMcp
  # Pending L0 proposals, identified by (base, result).
  #   base   = sha256 of the L0 bytes the proposal was computed against
  #   result = sha256 of the complete resulting L0 bytes stored here
  # The stored content is data: nothing in this module evaluates it.
  module L0ProposalStore
    def self.dir
      File.join(KairosMcp.storage_dir, 'l0_proposals')
    end

    def self.path_for(id)
      File.join(dir, "#{id}.json")
    end

    # Returns the new proposal id. `snapshot` names the version file a restore
    # was built from; it is a label for display, the result hash is what binds.
    def self.save(skill_id:, kind:, base:, result:, content:, reason: nil, snapshot: nil)
      FileUtils.mkdir_p(dir)
      id = SecureRandom.hex(8)
      record = {
        'id' => id,
        'skill_id' => skill_id.to_s,
        'kind' => kind,
        'base' => base,
        'result' => result,
        'content' => content,
        'reason' => reason,
        'snapshot' => snapshot,
        'created_at' => now,
        'applied_at' => nil
      }
      File.write(path_for(id), JSON.pretty_generate(record))
      id
    end

    def self.load(id)
      return nil unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8,64}\z/)

      path = path_for(id)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def self.pending
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.json')).sort.filter_map do |path|
        record = begin
          JSON.parse(File.read(path))
        rescue StandardError
          nil
        end
        record if record.is_a?(Hash) && record['applied_at'].nil?
      end
    end

    # Applied proposals are kept; they only drop out of the pending listing.
    def self.mark_applied(id)
      record = load(id)
      return false unless record

      record['applied_at'] = now
      File.write(path_for(id), JSON.pretty_generate(record))
      true
    end

    def self.now
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    end
  end
end
