# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'

# Builds an individual exactly as Kairomone 0.6.1's init left it: the legacy
# slot <data_dir>/kairomone with a schema-1 profile.json and no ledger yet.
# 0.8 never creates a legacy slot (design v0.6 M1) but keeps serving the ones
# that exist (Inv 1), so suites about such individuals start from this.
module KairomoneLegacyFixture
  L0_FILES = %w[skills/kairos.rb skills/kairos.md].freeze

  module_function

  def slot!(host, dot_id:, display_name:)
    root = File.join(host, 'kairomone')
    FileUtils.mkdir_p(root, mode: 0o700)
    File.open(File.join(root, '.lock'), File::RDWR | File::CREAT, 0o600, &:close)
    %w[knowledge context storage backups exports].each { |dir| FileUtils.mkdir_p(File.join(root, dir), mode: 0o700) }
    baseline = L0_FILES.each_with_object({}) do |relative, hashes|
      path = File.join(host, relative)
      hashes[relative] = Digest::SHA256.hexdigest(File.binread(path)) if File.file?(path)
    end
    profile = { 'schema_version' => 1, 'dot_id' => dot_id, 'display_name' => display_name, 'supply_profile' => 'basic',
                'created_at' => Time.now.utc.iso8601, 'host_l0_baseline' => baseline }
    File.write(File.join(root, 'profile.json'), JSON.pretty_generate(profile) + "\n", perm: 0o600)
    Kairomone::Instance.new(host_root: host)
  end
end
