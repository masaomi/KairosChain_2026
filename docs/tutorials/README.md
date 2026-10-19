# Tutorials

## KairosChain + GenomicsChain hands-on tutorial (kairos-chain 3.93.0)

From installing KairosChain for Claude Code to your first recorded knowledge, then the GenomicsChain
SkillSets.

| File | What it is |
|---|---|
| [Slides](https://masaomi.github.io/KairosChain_2026/tutorials/kairoschain_genomicschain_tutorial.html) (`kairoschain_genomicschain_tutorial.html`) | 11 main slides with the commands to type, details pages and an appendix (B7: installing Ruby 3.4.10 with rbenv on macOS and Linux). ← → to move, ↑ to search every page |
| [`kairoschain_genomicschain_quickstart_v0.1.4.md`](kairoschain_genomicschain_quickstart_v0.1.4.md) | The setup guide as an L1 knowledge entry; slide 9 shows how to import it into your KairosChain |
| [`layered_visual_pitch_deck_v0.1.1.zip`](layered_visual_pitch_deck_v0.1.1.zip) | The method and kit the slides were built with: an L1 entry with scripts, not a SkillSet. Import steps in appendix B8 of the slides and in `IMPORT.md` inside the zip |

Review status: two rounds of multi-LLM review (five reviewers each). Round 1 raised 13 blocking
findings; round 2 judged them closed and raised new ones (a working-directory slip in appendix B8,
unmarked output lines, a stale source row, among others), which were fixed after round 2 and have not
been re-reviewed. Commands were checked against kairos-chain 3.93.0 and the GenomicsChain_SkillSets
README; Tier-1/2/3 outputs were not run for the slides.
