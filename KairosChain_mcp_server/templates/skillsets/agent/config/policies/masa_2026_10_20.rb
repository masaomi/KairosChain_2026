# The operator's policy — the mandate for agent runs (design v0.5.1 §2).
# A transcription of the operator's ruling of 2026-10-20 (L2
# ruling_agent_skillset_rebuild_premise_20261020): reduce questions to the
# minimum by judging autonomously from past logs and the instruction mode;
# follow the operator's past decisions rather than default recommendations;
# occasional mistakes are acceptable; claude -p from a host session; never
# unattended. It binds only after the operator adopts this file's digest in
# their own typed words; any edit changes the digest and needs a new adoption.

policy "masa_2026_10_20" do
  stand_in may: [:precedent, :instruction_mode, :novel_reversible]
  consent review: :configured_providers, of: :project_artifacts
  free_of_personal_data projects: []
  # Review rounds for each review, counted apart: the only cap on a review,
  # which closes only when no P0 is open; at the cap it waits for the operator.
  spend default: { review_rounds: 10, stand_in_calls: 300 }
end
