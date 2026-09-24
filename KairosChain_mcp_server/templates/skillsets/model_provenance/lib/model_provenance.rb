# frozen_string_literal: true

# Entry point loaded by the SkillSet manager. It exposes only the
# KairosChain-layer observation store. The transcript reader lives under
# hooks/ and is never required from here (design v0.3 INV-2).
require_relative 'model_provenance/observation_store'
