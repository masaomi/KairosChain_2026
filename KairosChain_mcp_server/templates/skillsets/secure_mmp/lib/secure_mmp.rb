# frozen_string_literal: true

require_relative 'secure_mmp/knocks'

# Secure MMP v1 — the 'pinned' admission policy.
#
# A listener started with `--admission pinned` asks this decider about every
# direct-mode introduce and every authenticated request. A key is admitted
# when core's signed pin records admit it (KairosMcp::AdmissionRecords); any
# state the records cannot vouch for admits nothing. A refused introduce
# leaves a bounded, fixed-shape knock — never a chain block.
module SecureMmp
  VERSION = '0.1.0'
  POLICY = 'pinned'

  class << self
    def decide(candidate)
      require 'kairos_mcp/admission_records'
      records = KairosMcp::AdmissionRecords.for_data_dir
      state = records.state
      return { admit: false, unavailable: true, reason: "records #{state.status}" } unless state.ok?

      as = records.admitted_alias(candidate[:key_sha256].to_s, state)
      return { admit: true, as: as } if as

      Knocks.record(candidate) if candidate[:phase] == :introduce
      { admit: false, reason: 'not pinned' }
    end

    # Idempotent; called when the lib loads.
    def register!
      return false unless defined?(::MMP::Admission)
      return true if ::MMP::Admission.registered?(POLICY)

      ::MMP::Admission.register(POLICY) { |candidate| decide(candidate) }
      true
    end
  end
end

SecureMmp.register!
