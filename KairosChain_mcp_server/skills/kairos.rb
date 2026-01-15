skill :core_safety do
  version "1.0"
  title "Core Safety Rules"
  guarantees do
    immutable
    always_enforced
  end
  evolve do
    deny :all
  end
  content <<~MD
    ## Core Safety Invariants
    1. Evolution requires explicit enablement
    2. Human approval required by default
    3. All changes create blockchain records
  MD
end

skill :self_inspection do
  version "1.0"
  title "Self Inspection"
  behavior do
    Kairos.skills.map do |skill|
      skill.to_h
    end
  end
end

skill :chain_awareness do
  version "1.0"
  title "Chain Awareness"
  # behavior { KairosChain.status }
end
