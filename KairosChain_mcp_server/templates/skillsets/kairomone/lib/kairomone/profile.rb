# frozen_string_literal: true

module Kairomone
  # Profile versions (design v0.6 M4): content-addressed files
  # profile/<sha256>.json, schema 2, no identity and no baseline. The current
  # profile is the latest accepted kairomone_profile record whose piece is
  # present; an individual made before 0.8 stands on its schema-1 profile.json
  # until a version is accepted.
  module Profile
    FIELDS = %w[name kind kind_label appearance personality voice interests origin created_at].freeze

    module_function

    # The version kairomone_init writes: the name the owner gave, nothing composed.
    def initial(name:, origin:)
      { 'schema_version' => 2, 'name' => name, 'kind' => 'unknown', 'kind_label' => '', 'appearance' => '',
        'personality' => [], 'voice' => '', 'interests' => [],
        'origin' => { 'kind' => origin, 'material_sha256' => nil }, 'created_at' => Time.now.utc.iso8601 }
    end

    def valid?(value)
      value.is_a?(Hash) && value['schema_version'] == 2 && (value.keys - ['schema_version']).sort == FIELDS.sort &&
        value['name'].is_a?(String) && !value['name'].strip.empty? && value['name'].bytesize <= 256
    end
  end

  class Instance
    # { sha256:, piece: } of the latest accepted profile version whose file is
    # present and well formed, or nil. A version the ledger accepts but the
    # files lack falls back to the one before it (M15).
    def current_profile_piece(ledger = nil)
      return nil unless @root && File.exist?(Paths.checked(root, 'storage/blockchain.json'))

      ledger ||= chain
      Records.of_type(ledger, 'kairomone_profile').reverse_each do |record|
        sha = record['sha256'].to_s
        next unless /\A[0-9a-f]{64}\z/.match?(sha)

        relative = "profile/#{sha}.json"
        next unless File.file?(Paths.checked(root, relative))

        bytes = Paths.read(root, relative, limit: 65_536)
        next unless Digest::SHA256.hexdigest(bytes) == sha

        piece = JSON.parse(bytes) rescue nil
        return { sha256: sha, piece: piece } if Profile.valid?(piece)
      end
      nil
    end
  end
end
