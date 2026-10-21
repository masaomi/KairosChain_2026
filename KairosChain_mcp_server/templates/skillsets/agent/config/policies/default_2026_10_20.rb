# A sample policy for agent runs: an operator's mandate, shipped with the agent
# SkillSet. It binds no one until an operator adopts it by typing
# "adopt policy default_2026_10_20 <first 8 hex digits of its digest>"; any
# edit changes the digest and needs a new adoption. A changed policy takes a
# new name in its policy line. The stand-in reads this whole file, comments
# included, as part of its instructions.
#
# stand_in may: the decision points the stand-in answers instead of the
#   operator (questions, plan approval and parameters, pinned-test changes).
#   :precedent answers from the operator's own recorded words;
#   :instruction_mode answers from the active instruction mode;
#   :novel_reversible answers a reversible question no recorded word covers,
#   by the model's own judgment (with an empty precedent store, that is most
#   questions). Leaving out :precedent or :instruction_mode while keeping
#   :novel_reversible answers the same questions, labelled novel; leaving out
#   all three sends those decision points to the operator. These classes do
#   not govern the stand-in's readings: it still checks review bundles for
#   personal data, labels review findings and rules on hazards.
# consent review: a run may send its artifacts to the reviewers configured in
#   multi_llm_review. The value and scope are recorded, not enforced.
# free_of_personal_data: projects whose review bundles skip the stand-in's
#   check for personal or third-party data, unless a bundle carries findings
#   from an earlier round. None here.
# spend: review_rounds caps each review, counted apart; at the cap the review
#   waits for the operator. stand_in_calls caps the stand-in's model calls in a
#   run; past it decision points and readings go to the operator, and a hazard
#   cannot be ruled, which ends the run.

policy "default_2026_10_20" do
  stand_in may: [:precedent, :instruction_mode, :novel_reversible]
  consent review: :configured_providers, of: :project_artifacts
  free_of_personal_data projects: []
  spend default: { review_rounds: 10, stand_in_calls: 300 }
end
