# Implementation review: multi_llm_review SkillSet 0.9.1 -> 0.10.0

Your seat may have no file-system or tool access. Review the diff text below on
its own; mark claims you cannot verify as [INFERRED], and put your verdict line
first.

## Change intent (3 fixes, one SkillSet)

1. Finding weight axis: the reviewer prompt contract now REQUIRES a
   "[consequence: who is harmed, and how, if this is never fixed]" clause on
   every P0 finding. Aggregation (consensus.rb) copies the clause into its own
   field; a P0 with no clause (or an empty one) is recorded at P2, keeping
   severity_stated=P0 and severity_demoted=consequence_missing on the row.
   Only PRESENCE is checked mechanically; triviality judgment stays with the
   human orchestrator. The dedup key strips the clause so two reviewers naming
   one defect still merge.
2. Reviewer incentive: the reviewer prompt no longer names the round number
   ("Round: R2" line removed). The companion L1 workflow doc (not in this
   diff; reviewed separately) gains the orchestrator-side rule: never tell
   reviewers that finding counts, round numbers, or prior verdicts are
   compared; reviewers receive artifact, criteria, and prior findings only.
3. Worker-death recovery: the detached worker persists each seat's reply the
   moment it arrives (partial_results.json, atomic tmp+rename, worker is the
   file's single writer). collect's crash AND timeout branches recover
   completed seats from that file; seats the worker never reached enter the
   denominator as skip rows with reason worker_crashed_seat_lost, and
   payload.worker_failure names the death and the recovered/lost seat labels.
   With no partial file, no readable roster (request.json), or zero completed
   seats, behavior is unchanged (total-loss report as before).

Review focus: correctness of the demotion/dedup interaction, the recovery
path's failure modes (idempotent replay, denominator honesty), the worker's
write path (atomicity, single-writer), and test adequacy.

## Diff (12 files, 12 skillset files; the L1 doc change is excluded)

diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/bin/dispatch_worker.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/bin/dispatch_worker.rb
index d92fb98..66d2527 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/bin/dispatch_worker.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/bin/dispatch_worker.rb
@@ -259,12 +259,29 @@ begin
   # and on between-reviewer progress (counter advances when result arrives).
   # v0.3.0 PR3 pushes MainState ticks via a per-result hook below.
 
+  # Per-seat persistence: each reply is written the moment it arrives, so a
+  # worker death with one seat stuck leaves the finished seats recoverable
+  # (collect's crash/timeout recovery reads partial_results.json). Runs on
+  # the dispatch collecting thread — the worker stays this file's single
+  # writer (§6.3). subprocess_results.json still supersedes it on clean exit.
+  partial_by_index = {}
+  on_result = lambda do |idx, result|
+    partial_by_index[idx.to_s] = MLR::ReviewSerializer.serialize(result)
+    PS.write_partial_results(token, {
+      'schema_version' => 1,
+      'token' => token,
+      'updated_at' => Time.now.iso8601,
+      'results_by_index' => partial_by_index
+    })
+  end
+
   results = dispatcher.dispatch(
     (request['reviewers'] || []).map { |r| r.transform_keys(&:to_sym) },
     request['messages'] || [],
     request['system_prompt'] || '',
     context: nil,
-    review_context: request['review_context'] || 'independent'
+    review_context: request['review_context'] || 'independent',
+    on_result: on_result
   )
 
   # v3.24.3: counter-only signal (no enter_call!/exit_call! pair). bump_counter!
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/consensus.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/consensus.rb
index 3e34b73..e1b0443 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/consensus.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/consensus.rb
@@ -601,6 +601,15 @@ module KairosMcp
           end
         end
 
+        # The consequence clause a finding carries, when it carries one. The
+        # severity axis says what KIND of defect this is; the consequence
+        # clause is the WEIGHT axis — who is harmed, and how, if it is never
+        # fixed. Measured 2026-08-06 (project_orientation_report checker,
+        # R5): of 7 P0s, 3 were factually correct findings that cost nobody
+        # anything, and the two kinds landed at the same severity because the
+        # record had nowhere to say the difference.
+        CONSEQUENCE_RE = /\[\s*consequence:\s*([^\]]*)\]/i
+
         # Collect severity-tagged findings from all successful reviews.
         # Deduplicates by first 80 chars (case-insensitive).
         def self.aggregate_findings(parsed_verdicts)
@@ -611,23 +620,7 @@ module KairosMcp
 
             # Extract "P0: ...", "P1-1: ...", "**P0**:", etc.
             text.scan(/\*{0,2}(P[0-3])\*{0,2}[-\s]*\d*[.:]\s*(.+?)(?=\n\s*\n|\n\s*\*{0,2}P[0-3]|\z)/mi) do |sev, issue|
-              all_findings << {
-                severity: sev.upcase,
-                # This used to be `[0..200]`, an inclusive Range, so every
-                # finding longer than 201 characters lost its tail — the quoted
-                # line, the file:line, the failure condition — before anything
-                # downstream could bound it on purpose.
-                #
-                # It is bounded here rather than nowhere, and here rather than
-                # further upstream, because this is the point where both costs
-                # are decided at once: what gets stored, and what the sanitizer
-                # is about to normalise character by character. A bound placed
-                # on the reply instead was measured not to work, since NFKC runs
-                # between the two and expands by up to 11x. The bound is in
-                # bytes for the same reason — bytes are what is spent.
-                issue: Sanitizer.clamp_finding_bytes(issue.strip),
-                cited_by: [r[:role_label]]
-              }
+              all_findings << build_finding(sev, issue, r[:role_label])
             end
           end
 
@@ -659,7 +652,7 @@ module KairosMcp
           # (`issue_variants_omitted`), because a silently shortened list
           # reads as "this is all there was" — the failure this whole change
           # exists to remove.
-          grouped = all_findings.group_by { |f| f[:issue][0..79].downcase }
+          grouped = all_findings.group_by { |f| dedup_key(f[:issue]) }
           grouped.map do |_key, findings|
             merged_severity = findings.map { |f| f[:severity] }.min # P0 < P1 < P2
             # `.min` over a non-empty group returns one of its own members, so
@@ -672,6 +665,17 @@ module KairosMcp
               issue: representative[:issue],
               cited_by: findings.flat_map { |f| f[:cited_by] }.uniq
             }
+            # The representative's wording and its weight travel together, like
+            # its severity does. When the representative states no consequence,
+            # another member's is carried rather than none: a group where ONE
+            # reviewer said who is harmed is a finding whose harm is known.
+            consequence = representative[:consequence] ||
+                          findings.map { |f| f[:consequence] }.compact.first
+            row[:consequence] = consequence if consequence
+            if representative[:severity_stated]
+              row[:severity_stated] = representative[:severity_stated]
+              row[:severity_demoted] = representative[:severity_demoted]
+            end
             if variants.size > 1
               row[:issue_variants] = variants.first(MAX_ISSUE_VARIANTS)
               omitted = variants.size - MAX_ISSUE_VARIANTS
@@ -680,6 +684,59 @@ module KairosMcp
             row
           end.sort_by { |f| f[:severity] }
         end
+
+        # The dedup key is the issue WITHOUT its consequence clause. The clause
+        # stays in the issue text (display, replay), but two reviewers naming
+        # one defect — one saying who is harmed, one not — are still one
+        # finding, and the merge is what lets the stated consequence carry the
+        # row's severity for both. Keyed on the raw text instead, the clause
+        # lands inside the first 80 characters of any short issue and splits
+        # the group, moving the finding count and the convergence denominator.
+        # Whitespace is normalised for the same reason: removing the clause
+        # must not leave a gap that fails the comparison it was removed for.
+        def self.dedup_key(issue)
+          issue.gsub(CONSEQUENCE_RE, ' ').gsub(/\s+/, ' ').strip[0..79].downcase
+        end
+
+        # One extracted finding, weight axis applied at the point of entry.
+        #
+        # A P0 that does not say who is harmed is recorded at P2, with the
+        # stated severity and the demotion reason kept beside it — the record
+        # says what the reviewer wrote AND what the rule did with it. Only
+        # PRESENCE is checked, mechanically, by construction: whether a stated
+        # consequence is real or trivial is a judgment call, and it belongs to
+        # the orchestrator reading the record, not to a heuristic here — the
+        # same division of labour as the substance rule above, which asks
+        # "said anything?" and never "said anything good?".
+        #
+        # The clause is copied into its own field but NOT stripped from the
+        # issue text: the issue line is what dedup keys on, what the display
+        # shows, and what a later round's prompt replays, and the consequence
+        # should survive in all three.
+        def self.build_finding(sev, issue, role_label)
+          # Bounded in BYTES at the point of extraction — this is the clamp
+          # that bounds the sanitizer's input, and the reasoning for bytes
+          # (NFKC expands up to 11x downstream) is at clamp_finding_bytes.
+          # This used to be `[0..200]`, an inclusive Range, so every finding
+          # longer than 201 characters lost its tail before anything
+          # downstream could bound it on purpose.
+          issue_text = Sanitizer.clamp_finding_bytes(issue.strip)
+          finding = {
+            severity: sev.upcase,
+            issue: issue_text,
+            cited_by: [role_label]
+          }
+          m = CONSEQUENCE_RE.match(issue_text)
+          consequence = m && m[1].strip
+          if consequence && !consequence.empty?
+            finding[:consequence] = consequence
+          elsif finding[:severity] == 'P0'
+            finding[:severity] = 'P2'
+            finding[:severity_stated] = 'P0'
+            finding[:severity_demoted] = 'consequence_missing'
+          end
+          finding
+        end
       end
     end
   end
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/dispatcher.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/dispatcher.rb
index bfa0e38..602838b 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/dispatcher.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/dispatcher.rb
@@ -33,9 +33,16 @@ module KairosMcp
         # @param system_prompt [String] system prompt for llm_call
         # @param context [InvocationContext] for invoke_tool
         # @param review_context [String] 'independent' or 'project_aware'
+        # @param on_result [#call, nil] called with (index, result) as each
+        #   reviewer's reply ARRIVES — not for the timeout-skips synthesized
+        #   at the deadline, which never carried a reply to lose. The caller
+        #   uses this to persist each seat as it completes, so a worker death
+        #   with one seat stuck does not discard the finished seats. Runs on
+        #   the collecting thread; a hook failure is logged and never fails
+        #   the dispatch.
         # @return [Array<Hash>] results indexed by reviewer position
         def dispatch(reviewers, messages, system_prompt, context:,
-                     review_context: 'independent')
+                     review_context: 'independent', on_result: nil)
           dispatch_id = SecureRandom.hex(8)
           deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
           results = Array.new(reviewers.size)
@@ -94,6 +101,7 @@ module KairosMcp
                 i, result = entry
                 results[i] = result
                 collected += 1
+                notify_result(on_result, i, result)
               end
               # Mark uncollected as timed out
               reviewers.each_with_index do |r, i|
@@ -111,6 +119,7 @@ module KairosMcp
             i, result = entry
             results[i] = result
             collected += 1
+            notify_result(on_result, i, result)
           end
 
           # Kill in-flight subprocesses from this dispatch
@@ -136,6 +145,15 @@ module KairosMcp
 
         private
 
+        # A hook failure must not fail the dispatch: the hook exists to save
+        # replies from a dying worker, and a hook that could kill the dispatch
+        # would create the loss it guards against.
+        def notify_result(on_result, idx, result)
+          on_result&.call(idx, result)
+        rescue StandardError => e
+          warn "[multi_llm_review::Dispatcher] on_result hook failed: #{e.class}: #{e.message}"
+        end
+
         def bump_main_state_counter
           return unless defined?(KairosMcp::SkillSets::MultiLlmReview::MainState)
           # v3.24.3: counter-only bump. exit_call! is private; bump_counter!
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/pending_state.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/pending_state.rb
index 8696eb4..aa39f4f 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/pending_state.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/pending_state.rb
@@ -72,6 +72,12 @@ module KairosMcp
         def gc_eligible_path(token);        File.join(token_dir(token), 'gc.eligible'); end
         def request_path(token);            File.join(token_dir(token), 'request.json'); end
         def subprocess_results_path(token); File.join(token_dir(token), 'subprocess_results.json'); end
+        # Per-seat results written as each seat completes, so a worker that
+        # dies with one seat stuck does not take the finished seats' replies
+        # with it (R3 2026-08-06 lost three completed external seats to one
+        # stale heartbeat). Superseded by subprocess_results.json on a clean
+        # exit; read by collect's crash/timeout recovery path only.
+        def partial_results_path(token);    File.join(token_dir(token), 'partial_results.json'); end
         def worker_pid_path(token);         File.join(token_dir(token), 'worker.pid'); end
         def worker_heartbeat_path(token);   File.join(token_dir(token), 'worker.heartbeat'); end
         def worker_tick_path(token);        File.join(token_dir(token), 'worker.tick'); end
@@ -105,6 +111,7 @@ module KairosMcp
         def write_collected(token, data);          atomic_write_json(collected_path(token), data); end
         def write_request(token, data);            atomic_write_json(request_path(token), data); end
         def write_subprocess_results(token, data); atomic_write_json(subprocess_results_path(token), data); end
+        def write_partial_results(token, data);    atomic_write_json(partial_results_path(token), data); end
         def write_worker_pid(token, data);         atomic_write_json(worker_pid_path(token), data); end
         def write_marker(token, data);             atomic_write_json(marker_path(token), data); end
         def write_completed(token, data);          atomic_write_json(completed_path(token), data); end
@@ -172,6 +179,7 @@ module KairosMcp
         def load_collected(token);          load_json_transient(collected_path(token)); end
         def load_request(token);            load_json_transient(request_path(token)); end
         def load_subprocess_results(token); load_json_transient(subprocess_results_path(token)); end
+        def load_partial_results(token);    load_json_transient(partial_results_path(token)); end
         def load_worker_pid(token);         load_json_transient(worker_pid_path(token)); end
 
         # Mutate state.json under a read-modify-write block, serialized
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/prompt_builder.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/prompt_builder.rb
index 455eeb7..d32bd9d 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/prompt_builder.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/prompt_builder.rb
@@ -77,7 +77,13 @@ module KairosMcp
           parts << "<task>"
           parts << "Review the provided artifact for #{review_type} correctness."
           parts << "Target: #{artifact_name}"
-          parts << "Round: R#{review_round}"
+          # The round number is deliberately NOT given to the reviewer
+          # (2026-08-06). Telling a reviewer which round it is in — like
+          # telling it its finding count is compared across rounds — turns the
+          # count into something the reviewer performs, and selects for
+          # finding-production over finding-weight. Convergence is measured by
+          # the orchestrator from the record; the reviewer needs the artifact,
+          # the criteria, and the prior findings to verify, nothing else.
           if review_round > 1 && prior_findings && !prior_findings.empty?
             parts << "Scope: Review the revisions addressing prior findings."
             parts << ""
@@ -161,14 +167,21 @@ module KairosMcp
             line one is read.
 
             For each finding, use this single-line format (one finding per line):
-            P0: <issue description> [location: file:line]
-            P1: <issue description> [location: file:line]
+            P0: <issue description> [consequence: <who is harmed, and how, if this is never fixed>] [location: file:line]
+            P1: <issue description> [consequence: ...] [location: file:line]
             P2: <issue description> [location: file:line]
             P3: <issue description> [location: file:line]
 
+            The consequence clause is REQUIRED for P0. A finding can be
+            factually correct and still cost nobody anything; the consequence
+            clause is where you say who hits the defect and what happens to
+            them. A P0 with no consequence clause, or an empty one, is
+            recorded at P2. Do not restate the issue as its own consequence —
+            name the person or process that is harmed.
+
             Example:
-            P0: Missing input validation in dispatcher timeout path [location: dispatcher.rb:120]
-            P1: Thread safety issue with shared counter [location: consensus.rb:45]
+            P0: Missing input validation in dispatcher timeout path [consequence: a caller passing a negative timeout crashes the worker and the whole round's reviews are lost] [location: dispatcher.rb:120]
+            P1: Thread safety issue with shared counter [consequence: concurrent collects double-count usage] [location: consensus.rb:45]
 
             If no issues found, state "No findings" and verdict APPROVE.
             </structured_output_contract>
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/sanitizer.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/sanitizer.rb
index 15daa93..ddb174a 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/sanitizer.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/lib/multi_llm_review/sanitizer.rb
@@ -157,7 +157,8 @@ module KairosMcp
         # reaches the payload by the same path.
         #
         # @param findings [Array<Hash>] finding rows with String keys
-        # @return [Array<Hash>] the same rows, 'issue' and 'issue_variants' bound
+        # @return [Array<Hash>] the same rows, 'issue', 'consequence' and
+        #   'issue_variants' bound
         def self.bound_findings_for_record(findings)
           findings.map do |f|
             row = f.merge(
@@ -165,6 +166,15 @@ module KairosMcp
                 sanitize_finding_text(f['issue'], max_len: FINDING_RECORD_MAX_LEN)
               )
             )
+            if row['consequence']
+              # Reviewer text like the issue it was extracted from; it reaches
+              # the record by the same path.
+              row = row.merge(
+                'consequence' => clamp_finding_bytes(
+                  sanitize_finding_text(f['consequence'], max_len: FINDING_RECORD_MAX_LEN)
+                )
+              )
+            end
             if row['issue_variants']
               row = row.merge(
                 'issue_variants' => Array(row['issue_variants']).map do |v|
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/skillset.json b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/skillset.json
index 82f046e..8f7d345 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/skillset.json
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/skillset.json
@@ -1,7 +1,7 @@
 {
   "name": "multi_llm_review",
-  "version": "0.9.1",
-  "description": "v0.9.1 (seat access, frozen 2026-08-06 after a one-round review): reviewer prompts carry a <seat_access> block beside the inline artifact — a seat that cannot read the repository must not attempt tool calls and must not open by saying it will read files; it reviews the artifact text alone, marks unverifiable claims [INFERRED], and still opens with its verdict line. The wording is conditional because seats differ (codex runs --sandbox read-only and can read the repository), and the block is not emitted for by_reference delivery, whose existing cannot-read instruction it would contradict. Root cause fixed: the claude subprocess seat runs with tools disabled in an empty working directory, and on implementation artifacts citing file paths it opened with pseudo-tool-call markup or a cannot-access preamble instead of its verdict line, leaving four consecutive rounds as no_verdict while counting every round on design artifacts. v0.9.0 (evidence fidelity, frozen 2026-08-06 after six review rounds): a finding reaches the record whole. It used to be cut at 201 bytes by an inclusive Range in aggregation and bounded again by the 500-character display limit, so a downstream instance measured 18 of 21 findings arriving at exactly 201 bytes with reviews[].raw_text empty on every row. Findings are now bounded in BYTES at FINDING_RECORD_MAX_LEN = 8000 for the record, with DEFAULT_MAX_LEN = 500 still applied by every path that takes a finding into a prompt. Deduplication still keys on the first 80 characters — widening it would stop two reviewers describing one defect from merging, moving the finding count and the convergence denominator — but the surviving text is no longer arbitrary: issue comes from a member whose severity equals the merged severity, distinct texts survive in issue_variants (capped at MAX_ISSUE_VARIANTS = 8, with issue_variants_omitted naming what the cap dropped). Every row now carries raw_text_excerpt unconditionally (4096 bytes) and the reviewer's reply in raw_text on request (include_raw_text, 65536 bytes). Both are SANITISED TRANSCRIPTIONS, not verbatim records, and both tool schemas say so: the text is byte-clamped, NFKC-normalised, stripped of invisible characters, tag-escaped, then byte-clamped again. No field states whether they hold the whole reply, because nothing in this SkillSet can know — a completeness flag was implemented, measured wrong in both directions, and removed. On delegated runs the pending-state record keeps each subprocess reply as it arrived; on single-phase runs the returned payload is the only form there is. Findings carried into a later round's prompt are sanitised and folded to one line, a path that previously took reviewer text into a prompt with no sanitisation at all. v0.8.0 (v0.7 record schema, design frozen 2026-08-01): the verdict vocabulary is the three canonical words plus tense forms only (INV-R1); the ratio and threshold are recorded reference values, not the run's conclusion — the top-level verdict field became reference_verdict and the run is closed by the operator's declaration outside the record (INV-R2); the persona team occupies one seat, its derivation rule is recorded, and a submission smaller than convened — including empty — is accepted with the shortfall on the record (INV-R3/R4); every run writes an existence marker at dispatch, completed records are never garbage-collected, and expired runs are reduced to a minimal trace instead of erased (INV-R4); a divergence-excluded tally is carried beside the main one (INV-R5); the record names its pre-declared spec and carries transport diagnostics as state tags (INV-R6); artifact delivery is a per-seat attribute (inline | by_reference) and an unreachable delivery is refused rather than dispatched (INV-R7). Parallel multi-LLM review orchestration. Dispatches review prompts to N LLM backends via llm_client, collects verdicts, and computes consensus. v0.6.0: reserve observers (escalate) and a declarable persona execution model; the observer set is built in one pass with explicit precedence (ObserverSet); every slot must name its model and role_label, and duplicate names — including the persona team's own — are refused. A reply's verdict is no longer inferred from its prose: it is read from a declared field, from the header the reply opens with when that header carries a verdict name and nothing else, or not at all, in which case the reply leaves the denominator with no_verdict recorded beside its name. The record says why every observer did or did not count (denominator_composition, five skip_reason values, observers_reporting), and the per-reviewer row is written by one mapping rather than two. v0.5.2: the cursor reviewer pins model composer-2.5 instead of inheriting the cursor CLI default, which is operator-editable and had silently become an Anthropic model. v0.5.1: Fable 5 retired from the roster (five consecutive silent returns), convergence 3/5; orchestrator_model description now states the bare-ID rule so a caller does not review its own output. v0.5.0: adds multi_llm_review_wait (Phase 1.5) for explicit subprocess completion gating with next_action recovery hints, and Path A/B doc disambiguation. v0.4.0 (Phase 12): feedback_text + schema_version, sanitization contract for prompt-injection defense, and multi_llm_review_bundle tool for human-handoff paths without dispatch.",
+  "version": "0.10.0",
+  "description": "v0.10.0 (finding weight axis + worker-death recovery, 2026-08-06): findings gain a consequence axis beside the severity axis — the prompt contract requires a [consequence: who is harmed, and how, if this is never fixed] clause on every P0, and aggregation records a P0 without one at P2, keeping the stated severity and the demotion reason on the row (severity_stated / severity_demoted: consequence_missing). Only PRESENCE is checked, mechanically; whether a stated consequence is real or trivial stays the orchestrator's call. The dedup key strips the clause so two reviewers naming one defect still merge, and a group where one member states the harm carries it for the row. Motivating measurement (project_orientation_report checker, R5): 3 of 7 P0s were factually correct findings that cost nobody anything. Reviewer prompts also stop naming the round number — telling a reviewer which round it is in (like telling it its counts are compared) selects for finding-production over finding-weight; the L1 workflow v3.10.0 Reviewer incentive rule states the orchestrator-side half. And a worker death no longer discards completed seats: the worker persists each reply as it arrives (partial_results.json), and collect's crash/timeout branches recover the finished seats, entering every unreached seat in the denominator as a skip row (worker_crashed_seat_lost) with the death named in payload.worker_failure — R3 2026-08-06 lost three completed external seats to one stale heartbeat because the only exit was total loss. v0.9.1 (seat access, frozen 2026-08-06 after a one-round review): reviewer prompts carry a <seat_access> block beside the inline artifact — a seat that cannot read the repository must not attempt tool calls and must not open by saying it will read files; it reviews the artifact text alone, marks unverifiable claims [INFERRED], and still opens with its verdict line. The wording is conditional because seats differ (codex runs --sandbox read-only and can read the repository), and the block is not emitted for by_reference delivery, whose existing cannot-read instruction it would contradict. Root cause fixed: the claude subprocess seat runs with tools disabled in an empty working directory, and on implementation artifacts citing file paths it opened with pseudo-tool-call markup or a cannot-access preamble instead of its verdict line, leaving four consecutive rounds as no_verdict while counting every round on design artifacts. v0.9.0 (evidence fidelity, frozen 2026-08-06 after six review rounds): a finding reaches the record whole. It used to be cut at 201 bytes by an inclusive Range in aggregation and bounded again by the 500-character display limit, so a downstream instance measured 18 of 21 findings arriving at exactly 201 bytes with reviews[].raw_text empty on every row. Findings are now bounded in BYTES at FINDING_RECORD_MAX_LEN = 8000 for the record, with DEFAULT_MAX_LEN = 500 still applied by every path that takes a finding into a prompt. Deduplication still keys on the first 80 characters — widening it would stop two reviewers describing one defect from merging, moving the finding count and the convergence denominator — but the surviving text is no longer arbitrary: issue comes from a member whose severity equals the merged severity, distinct texts survive in issue_variants (capped at MAX_ISSUE_VARIANTS = 8, with issue_variants_omitted naming what the cap dropped). Every row now carries raw_text_excerpt unconditionally (4096 bytes) and the reviewer's reply in raw_text on request (include_raw_text, 65536 bytes). Both are SANITISED TRANSCRIPTIONS, not verbatim records, and both tool schemas say so: the text is byte-clamped, NFKC-normalised, stripped of invisible characters, tag-escaped, then byte-clamped again. No field states whether they hold the whole reply, because nothing in this SkillSet can know — a completeness flag was implemented, measured wrong in both directions, and removed. On delegated runs the pending-state record keeps each subprocess reply as it arrived; on single-phase runs the returned payload is the only form there is. Findings carried into a later round's prompt are sanitised and folded to one line, a path that previously took reviewer text into a prompt with no sanitisation at all. v0.8.0 (v0.7 record schema, design frozen 2026-08-01): the verdict vocabulary is the three canonical words plus tense forms only (INV-R1); the ratio and threshold are recorded reference values, not the run's conclusion — the top-level verdict field became reference_verdict and the run is closed by the operator's declaration outside the record (INV-R2); the persona team occupies one seat, its derivation rule is recorded, and a submission smaller than convened — including empty — is accepted with the shortfall on the record (INV-R3/R4); every run writes an existence marker at dispatch, completed records are never garbage-collected, and expired runs are reduced to a minimal trace instead of erased (INV-R4); a divergence-excluded tally is carried beside the main one (INV-R5); the record names its pre-declared spec and carries transport diagnostics as state tags (INV-R6); artifact delivery is a per-seat attribute (inline | by_reference) and an unreachable delivery is refused rather than dispatched (INV-R7). Parallel multi-LLM review orchestration. Dispatches review prompts to N LLM backends via llm_client, collects verdicts, and computes consensus. v0.6.0: reserve observers (escalate) and a declarable persona execution model; the observer set is built in one pass with explicit precedence (ObserverSet); every slot must name its model and role_label, and duplicate names — including the persona team's own — are refused. A reply's verdict is no longer inferred from its prose: it is read from a declared field, from the header the reply opens with when that header carries a verdict name and nothing else, or not at all, in which case the reply leaves the denominator with no_verdict recorded beside its name. The record says why every observer did or did not count (denominator_composition, five skip_reason values, observers_reporting), and the per-reviewer row is written by one mapping rather than two. v0.5.2: the cursor reviewer pins model composer-2.5 instead of inheriting the cursor CLI default, which is operator-editable and had silently become an Anthropic model. v0.5.1: Fable 5 retired from the roster (five consecutive silent returns), convergence 3/5; orchestrator_model description now states the bare-ID rule so a caller does not review its own output. v0.5.0: adds multi_llm_review_wait (Phase 1.5) for explicit subprocess completion gating with next_action recovery hints, and Path A/B doc disambiguation. v0.4.0 (Phase 12): feedback_text + schema_version, sanitization contract for prompt-injection defense, and multi_llm_review_bundle tool for human-handoff paths without dispatch.",
   "author": "Masaomi Hatakeyama",
   "layer": "L1",
   "depends_on": [
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_dispatcher_usage.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_dispatcher_usage.rb
index f5ac4b1..db9fe2b 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_dispatcher_usage.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_dispatcher_usage.rb
@@ -31,6 +31,47 @@ module KairosMcp
           assert_nil result[:usage]
         end
       end
+
+      # Per-seat persistence hook (2026-08-06). One stuck seat killed the
+      # worker via stale heartbeat and took three COMPLETED external seats
+      # with it, because nothing left the worker's memory until every seat
+      # was done. The hook fires as each reply arrives so the caller can
+      # persist it; a failing hook must not fail the dispatch it guards.
+      class TestDispatcherOnResultHook < Minitest::Test
+        class StubInvoker
+          def invoke_tool(_name, args, context: nil)
+            [{ text: JSON.generate({
+              'status' => 'ok',
+              'provider' => args['provider_override'],
+              'response' => { 'content' => "**Overall Verdict**: APPROVE\n\nfine" }
+            }) }]
+          end
+        end
+
+        def reviewers
+          [{ provider: 'a', model: 'm-a', role_label: 'seat_a' },
+           { provider: 'b', model: 'm-b', role_label: 'seat_b' }]
+        end
+
+        def test_on_result_fires_once_per_arrived_reply_with_its_index
+          seen = []
+          d = Dispatcher.new(StubInvoker.new, timeout_seconds: 30, max_concurrent: 2)
+          results = d.dispatch(reviewers, [], '', context: nil,
+                               on_result: ->(idx, r) { seen << [idx, r[:role_label]] })
+          assert_equal 2, results.size
+          assert_equal [[0, 'seat_a'], [1, 'seat_b']], seen.sort
+        end
+
+        def test_a_failing_hook_does_not_fail_the_dispatch
+          d = Dispatcher.new(StubInvoker.new, timeout_seconds: 30, max_concurrent: 2)
+          results = capture_io do
+            @results = d.dispatch(reviewers, [], '', context: nil,
+                                  on_result: ->(_i, _r) { raise 'disk full' })
+          end && @results
+          assert_equal 2, results.size
+          assert(results.all? { |r| r[:status] == :success })
+        end
+      end
     end
   end
 end
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_evidence_fidelity.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_evidence_fidelity.rb
index f3d096d..31e0bcd 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_evidence_fidelity.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_evidence_fidelity.rb
@@ -49,16 +49,18 @@ module KairosMcp
         # 1. D1. Aggregation used `issue.strip[0..200]` — an inclusive Range, so
         # 201 characters — and everything past that was gone before any
         # destination-aware bound could be applied.
+        # P1, not P0: a P0 with no consequence clause is demoted (the weight
+        # axis, 2026-08-06), and this test is about length, not weight.
         def test_finding_longer_than_201_chars_survives_aggregation
           issue = long_issue(700)
           reviews = [
-            { role_label: 'r1', raw_text: finding_body('REJECT', 'P0', issue), status: :success },
+            { role_label: 'r1', raw_text: finding_body('REJECT', 'P1', issue), status: :success },
             { role_label: 'r2', raw_text: prose_body('APPROVE'), status: :success }
           ]
           result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 1)
 
-          row = result[:aggregated_findings].find { |f| f[:severity] == 'P0' }
-          refute_nil row, 'the P0 finding never reached aggregated_findings'
+          row = result[:aggregated_findings].find { |f| f[:severity] == 'P1' }
+          refute_nil row, 'the P1 finding never reached aggregated_findings'
           assert_equal 700, row[:issue].length
           assert_equal issue, row[:issue]
           refute row.key?(:issue_variants), 'a single-member group carries no issue_variants key'
@@ -91,7 +93,10 @@ module KairosMcp
         def test_colliding_findings_keep_every_variant_and_a_matching_severity
           shared = 'The dispatcher drops the reviewer model provenance before the record is written'
           issue_a = "#{shared}, and the collect path repeats that mapping a fourth time."
-          issue_b = "#{shared}, but only when the persona seat was convened by the caller."
+          # The P0 states its consequence — without one it would be demoted
+          # (the weight axis, 2026-08-06) and could not be the severer member.
+          issue_b = "#{shared}, but only when the persona seat was convened by the caller. " \
+                    '[consequence: the record misattributes a verdict to the wrong model]'
 
           reviews = [
             { role_label: 'r1', raw_text: finding_body('REJECT', 'P2', issue_a), status: :success },
@@ -369,16 +374,18 @@ module KairosMcp
         #
         # The ASCII prefix is load-bearing: a reply of nothing but U+3316 is
         # dropped by aggregation before it becomes a finding.
+        # P1, not P0: a P0 with no consequence clause is demoted (the weight
+        # axis, 2026-08-06), and this test is about bytes, not weight.
         def test_the_record_bound_holds_in_bytes_after_nfkc_expansion
           issue = 'the record bound must hold in bytes: ' + ('㌖' * 4000)
           reviews = [
-            { role_label: 'r1', raw_text: finding_body('REJECT', 'P0', issue), status: :success },
+            { role_label: 'r1', raw_text: finding_body('REJECT', 'P1', issue), status: :success },
             { role_label: 'r2', raw_text: prose_body('APPROVE'), status: :success }
           ]
           result = Consensus.aggregate(reviews, '2/3 APPROVE', min_quorum: 1)
 
-          row = result[:aggregated_findings].find { |f| f[:severity] == 'P0' }
-          refute_nil row, 'the P0 finding never reached aggregated_findings'
+          row = result[:aggregated_findings].find { |f| f[:severity] == 'P1' }
+          refute_nil row, 'the P1 finding never reached aggregated_findings'
           assert_operator row[:issue].bytesize, :<=, Sanitizer::FINDING_RECORD_MAX_LEN,
                           'extraction already clamps in bytes; the expansion comes later'
 
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_multi_llm_review.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_multi_llm_review.rb
index f135080..008918a 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_multi_llm_review.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_multi_llm_review.rb
@@ -148,8 +148,8 @@ module KairosMcp
         def test_aggregate_findings_dedup
           # Simulate already-parsed verdicts (after extract_verdict)
           parsed = [
-            { role_label: 'r1', raw_text: "P0: Missing error handling in dispatcher\n\nP1: Thread safety concern", status: :success, verdict: 'REJECT' },
-            { role_label: 'r2', raw_text: "P0: Missing error handling in dispatcher timeout path", status: :success, verdict: 'REJECT' }
+            { role_label: 'r1', raw_text: "P0: Missing error handling in dispatcher [consequence: a timeout kills the round]\n\nP1: Thread safety concern", status: :success, verdict: 'REJECT' },
+            { role_label: 'r2', raw_text: "P0: Missing error handling in dispatcher timeout path [consequence: a timeout kills the round]", status: :success, verdict: 'REJECT' }
           ]
           findings = Consensus.aggregate_findings(parsed)
 
@@ -160,6 +160,65 @@ module KairosMcp
           assert findings.size <= 3, "Expected dedup to reduce findings, got #{findings.size}"
         end
 
+        # The weight axis (2026-08-06). The severity axis says what kind of
+        # defect a finding is; the consequence clause says who is harmed if it
+        # is never fixed. Measured on project_orientation_report R5: 3 of 7
+        # P0s were factually correct and cost nobody anything, and both kinds
+        # landed at P0 because the record had no second axis.
+        def test_p0_without_consequence_is_recorded_at_p2
+          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
+                      raw_text: "P0: declared cap justification is inconsistent" }]
+          f = Consensus.aggregate_findings(parsed).first
+          assert_equal 'P2', f[:severity]
+          assert_equal 'P0', f[:severity_stated]
+          assert_equal 'consequence_missing', f[:severity_demoted]
+        end
+
+        def test_p0_with_empty_consequence_is_recorded_at_p2
+          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
+                      raw_text: "P0: declared cap justification is inconsistent [consequence:  ]" }]
+          f = Consensus.aggregate_findings(parsed).first
+          assert_equal 'P2', f[:severity]
+          assert_equal 'P0', f[:severity_stated]
+        end
+
+        def test_p0_with_consequence_stays_p0_and_carries_it
+          parsed = [{ role_label: 'r1', status: :success, verdict: 'REJECT',
+                      raw_text: "P0: rect frame disables overflow detection [consequence: broken figures ship undetected in published reports]" }]
+          f = Consensus.aggregate_findings(parsed).first
+          assert_equal 'P0', f[:severity]
+          assert_equal 'broken figures ship undetected in published reports', f[:consequence]
+          assert_nil f[:severity_stated]
+        end
+
+        # Only presence is checked, and only P0 is demoted: the rule is
+        # mechanical by construction, like the substance rule — whether a
+        # stated consequence is real or trivial is the orchestrator's call.
+        def test_p1_without_consequence_is_not_demoted
+          parsed = [{ role_label: 'r1', status: :success, verdict: 'REVISE',
+                      raw_text: "P1: thread safety concern in counter" }]
+          f = Consensus.aggregate_findings(parsed).first
+          assert_equal 'P1', f[:severity]
+        end
+
+        # One reviewer states the harm, one does not: still one finding — the
+        # dedup key strips the clause — and the stated consequence carries the
+        # merged row's severity for both.
+        def test_consequence_clause_does_not_split_the_dedup_group
+          parsed = [
+            { role_label: 'r1', status: :success, verdict: 'REJECT',
+              raw_text: "P0: the reaper can signal its own group [consequence: the orchestrator is killed with the worker]" },
+            { role_label: 'r2', status: :success, verdict: 'REVISE',
+              raw_text: "P0: the reaper can signal its own group" }
+          ]
+          findings = Consensus.aggregate_findings(parsed)
+          assert_equal 1, findings.size
+          f = findings.first
+          assert_equal 'P0', f[:severity]
+          assert_equal %w[r1 r2].sort, f[:cited_by].sort
+          assert_equal 'the orchestrator is killed with the worker', f[:consequence]
+        end
+
         def test_parse_threshold_ratio
           assert_equal 3, Consensus.parse_threshold('3/4 APPROVE', 4)
           assert_equal 2, Consensus.parse_threshold('3/4 APPROVE', 2)
@@ -458,10 +517,23 @@ module KairosMcp
             prior_findings: prior
           )
           content = messages[0]['content']
-          assert_includes content, 'R2'
+          # The round number is orchestrator-side bookkeeping (2026-08-06):
+          # telling a reviewer which round it is in frames counts as compared,
+          # and selects for finding-production over finding-weight.
+          refute_includes content, 'R2'
+          refute_includes content, 'Round:'
           assert_includes content, 'Missing validation'
           assert_includes content, 'r1, r2'
         end
+
+        # The weight axis (2026-08-06): the contract demands a consequence
+        # clause for P0 and says what happens without one, so the demotion in
+        # aggregation is a rule the reviewer was told, not a silent rewrite.
+        def test_contract_requires_consequence_for_p0
+          contract = PromptBuilder.structured_output_contract
+          assert_includes contract, '[consequence:'
+          assert_includes contract, 'recorded at P2'
+        end
       end
 
       # TestOrchestratorExclusion was removed with the helpers it exercised.
@@ -1375,6 +1447,121 @@ module KairosMcp
         end
       end
 
+      # Worker-death recovery (2026-08-06, R3): a stale heartbeat on ONE stuck
+      # seat used to discard every completed seat's reply, because the only
+      # exit from the crash branch was total loss. The worker now persists
+      # each seat as it completes (partial_results.json), and collect reads
+      # that file back: finished seats count, unreached seats enter the
+      # denominator as skip rows naming the loss.
+      class TestCollectWorkerCrashRecovery < Minitest::Test
+        def setup
+          @tmp = Dir.mktmpdir('mlr-crash-')
+          @orig_cwd = Dir.pwd
+          Dir.chdir(@tmp)
+          @collect = Tools::MultiLlmReviewCollect.new
+          @token = PendingState.generate_token
+          PendingState.create_token_dir!(@token)
+          PendingState.write_state(@token, {
+            'token' => @token,
+            'created_at' => Time.now.iso8601,
+            'collect_deadline' => (Time.now + 600).iso8601,
+            'review_type' => 'design',
+            'artifact_name' => 'test',
+            'review_round' => 1,
+            'complexity' => 'high',
+            'orchestrator_model' => 'claude-opus-5',
+            'convergence_rule' => '3/4 APPROVE',
+            'min_quorum' => 2,
+            'parallel' => true,
+            'subprocess_status' => 'crashed',
+            'crash_reason' => 'heartbeat_stale'
+          })
+          PendingState.write_request(@token, {
+            'reviewers' => [
+              { 'provider' => 'codex', 'model' => 'gpt-5.5', 'role_label' => 'codex_gpt5.5' },
+              { 'provider' => 'cursor', 'model' => 'composer-2.5', 'role_label' => 'cursor' }
+            ]
+          })
+        end
+
+        def teardown
+          Dir.chdir(@orig_cwd)
+          FileUtils.rm_rf(@tmp)
+        end
+
+        def persona_reviews
+          [
+            { 'persona' => 'architect', 'verdict' => 'APPROVE',
+              'reasoning' => 'walked the layering; holds together', 'findings' => [] },
+            { 'persona' => 'security', 'verdict' => 'APPROVE',
+              'reasoning' => 'no exposure found on the seams', 'findings' => [] }
+          ]
+        end
+
+        def write_partial_for_seat_zero
+          PendingState.write_partial_results(@token, {
+            'schema_version' => 1,
+            'token' => @token,
+            'updated_at' => Time.now.iso8601,
+            'results_by_index' => {
+              '0' => {
+                'role_label' => 'codex_gpt5.5', 'provider' => 'codex',
+                'model' => 'gpt-5.5',
+                'raw_text' => "**Overall Verdict**: APPROVE\n\n" \
+                              'Checked the dispatch path and the pending-state ' \
+                              'contract; nothing to raise.',
+                'elapsed_seconds' => 12, 'error' => nil, 'status' => 'success'
+              }
+            }
+          })
+        end
+
+        def test_completed_seats_survive_a_worker_crash
+          write_partial_for_seat_zero
+          payload = JSON.parse(@collect.call({
+            'collect_token' => @token,
+            'orchestrator_reviews' => persona_reviews
+          }).first[:text])
+
+          assert_equal 'ok', payload['status'], payload.inspect
+          failure = payload['worker_failure']
+          assert failure, 'the record must say the denominator survived a worker death'
+          assert_equal 'subprocess_worker_crashed', failure['outcome']
+          assert_equal 'heartbeat_stale', failure['reason']
+          assert_equal ['codex_gpt5.5'], failure['recovered_seats']
+          assert_equal ['cursor'], failure['lost_seats']
+
+          observers = payload.dig('convergence', 'denominator_composition', 'observers')
+          lost = observers.find { |o| o['role_label'] == 'cursor' }
+          refute lost['counted']
+          assert_equal 'worker_crashed_seat_lost', lost['reason']
+          counted = observers.find { |o| o['role_label'] == 'codex_gpt5.5' }
+          assert counted['counted'], 'the recovered seat counts'
+        end
+
+        def test_crash_with_no_partial_results_reports_the_death_as_before
+          payload = JSON.parse(@collect.call({
+            'collect_token' => @token,
+            'orchestrator_reviews' => persona_reviews
+          }).first[:text])
+          assert_equal 'subprocess_worker_crashed', payload['status']
+          assert_equal 'heartbeat_stale', payload['reason']
+        end
+
+        # No roster, no recovery: a denominator that cannot name its missing
+        # seats would shrink silently, which is the loss shape INV-E4 exists
+        # to prevent.
+        def test_partial_results_without_a_readable_roster_fall_back_to_crash_report
+          write_partial_for_seat_zero
+          File.delete(PendingState.request_path(@token))
+          payload = JSON.parse(@collect.call({
+            'collect_token' => @token,
+            'orchestrator_reviews' => persona_reviews
+          }).first[:text])
+          assert_equal 'subprocess_worker_crashed', payload['status']
+        end
+      end
+
       class TestCollectTool < Minitest::Test
         def setup
           @tmp = Dir.mktmpdir('mlr-collect-')
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_mutation_survivors.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_mutation_survivors.rb
index 64af463..45bf82d 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_mutation_survivors.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/test/test_mutation_survivors.rb
@@ -453,8 +453,11 @@ module KairosMcp
         end
 
         def test_a_finding_two_reviewers_cite_keeps_the_severer_tag
+          # The P0 carries a consequence clause because a P0 without one is
+          # recorded at P2 (the weight axis, 2026-08-06) — this test is about
+          # the merge keeping the severer tag, not about the demotion rule.
           out = aggregated(
-            "**Overall Verdict**: REJECT\n\nP0: the reaper can signal its own group",
+            "**Overall Verdict**: REJECT\n\nP0: the reaper can signal its own group [consequence: the orchestrator dies with the worker]",
             "**Overall Verdict**: REVISE\n\nP2: the reaper can signal its own group"
           )
 
@@ -484,7 +487,7 @@ module KairosMcp
         end
 
         def test_a_lower_case_severity_marker_names_a_finding
-          out = aggregated("**Overall Verdict**: REJECT\n\np0: the reaper can signal its own group")
+          out = aggregated("**Overall Verdict**: REJECT\n\np0: the reaper can signal its own group [consequence: the orchestrator dies with the worker]")
 
           assert_equal 1, out.size
           assert_equal 'P0', out.first[:severity]
diff --git a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/tools/multi_llm_review_collect.rb b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/tools/multi_llm_review_collect.rb
index 9cd8db8..557fa4f 100644
--- a/KairosChain_mcp_server/templates/skillsets/multi_llm_review/tools/multi_llm_review_collect.rb
+++ b/KairosChain_mcp_server/templates/skillsets/multi_llm_review/tools/multi_llm_review_collect.rb
@@ -287,6 +287,12 @@ module KairosMcp
             parallel = false if parallel.nil?      # legacy default (R1-K)
 
             subprocess_entries = nil
+            # Set when the worker died but finished seats were recovered from
+            # partial_results.json; carried into the final payload so the
+            # record says the denominator survived a worker death, not a
+            # clean round (R3 2026-08-06: one stale seat cost three completed
+            # external seats because the only exit here was total loss).
+            worker_failure = nil
             if parallel == false
               subprocess_entries = (state['subprocess_results'] || []).map do |r|
                 deserialize_review(r)
@@ -303,14 +309,24 @@ module KairosMcp
               when :ready
                 subprocess_entries = outcome[:results].map { |r| deserialize_review(r) }
               when :crashed
-                return text_content(JSON.generate({
-                  'status' => 'subprocess_worker_crashed',
-                  'collect_token' => token,
+                recovered = recover_partial_entries(token)
+                unless recovered
+                  return text_content(JSON.generate({
+                    'status' => 'subprocess_worker_crashed',
+                    'collect_token' => token,
+                    'reason' => outcome[:reason],
+                    'pid' => outcome[:pid],
+                    'heartbeat_age' => outcome[:heartbeat_age],
+                    'log_tail' => outcome[:log_tail].to_s
+                  }))
+                end
+                subprocess_entries = recovered[:entries]
+                worker_failure = {
+                  'outcome' => 'subprocess_worker_crashed',
                   'reason' => outcome[:reason],
-                  'pid' => outcome[:pid],
-                  'heartbeat_age' => outcome[:heartbeat_age],
-                  'log_tail' => outcome[:log_tail].to_s
-                }))
+                  'recovered_seats' => recovered[:recovered_labels],
+                  'lost_seats' => recovered[:lost_labels]
+                }
               when :timeout
                 reaper_outcome = WorkerReaper.terminate!(token, outcome[:pid], outcome[:pgid])
                 if %i[terminated killed already_dead].include?(reaper_outcome)
@@ -323,14 +339,29 @@ module KairosMcp
                     warn "[multi_llm_review_collect] gc.eligible write: #{e.class}: #{e.message}"
                   end
                 end
-                return text_content(JSON.generate({
-                  'status' => 'worker_timeout',
-                  'collect_token' => token,
+                # The reaper has already run, so what the partial file holds
+                # is final — the same recovery as the crash branch, after the
+                # same kind of death (a timeout here IS the worker dying, by
+                # this tool's hand instead of its own).
+                recovered = recover_partial_entries(token)
+                unless recovered
+                  return text_content(JSON.generate({
+                    'status' => 'worker_timeout',
+                    'collect_token' => token,
+                    'waited_seconds' => outcome[:waited_seconds],
+                    'pid' => outcome[:pid],
+                    'reaper_outcome' => reaper_outcome.to_s,
+                    'log_tail' => outcome[:log_tail].to_s
+                  }))
+                end
+                subprocess_entries = recovered[:entries]
+                worker_failure = {
+                  'outcome' => 'worker_timeout',
                   'waited_seconds' => outcome[:waited_seconds],
-                  'pid' => outcome[:pid],
                   'reaper_outcome' => reaper_outcome.to_s,
-                  'log_tail' => outcome[:log_tail].to_s
-                }))
+                  'recovered_seats' => recovered[:recovered_labels],
+                  'lost_seats' => recovered[:lost_labels]
+                }
               end
             end
 
@@ -404,6 +435,10 @@ module KairosMcp
               'persona_model' => state['persona_model'],
               'run_token' => token
             }
+            # The worker died and finished seats were recovered; the lost
+            # seats are in the denominator composition as skip rows, and this
+            # names the death they were lost to.
+            payload['worker_failure'] = worker_failure if worker_failure
             # INV-R6: what the run intended to pass, when it was declared.
             payload['review_spec'] = state['review_spec'] if state['review_spec']
             # INV-R3/R4: the declared convened count beside the submitted one
@@ -507,6 +542,69 @@ module KairosMcp
             ReviewSerializer.deserialize(h)
           end
 
+          # What can be saved from a worker that died: the seats whose replies
+          # it persisted before dying (partial_results.json, written per-seat
+          # by the worker as each reply arrived), with every seat it did not
+          # reach entered as a skip row so the denominator composition names
+          # the loss instead of shrinking silently. The roster comes from
+          # request.json — the same file the worker dispatched from.
+          #
+          # Returns nil — meaning "nothing to save, report the death as
+          # before" — when no partial file exists (pre-recovery worker, or
+          # death before the first reply), when the roster cannot be read
+          # (a denominator that cannot name its missing seats would shrink
+          # silently), or when the file holds no completed seat.
+          def recover_partial_entries(token)
+            partial = PendingState.load_partial_results(token)
+            by_index = partial.is_a?(Hash) ? partial['results_by_index'] : nil
+            return nil unless by_index.is_a?(Hash) && !by_index.empty?
+
+            request = PendingState.load_request(token)
+            reviewers = request.is_a?(Hash) ? request['reviewers'] : nil
+            return nil unless reviewers.is_a?(Array) && !reviewers.empty?
+
+            entries = []
+            recovered_labels = []
+            lost_labels = []
+            reviewers.each_with_index do |reviewer, idx|
+              row = by_index[idx.to_s]
+              label = (reviewer.is_a?(Hash) &&
+                       (reviewer['role_label'] || reviewer['provider'])) || "seat_#{idx}"
+              if row.is_a?(Hash)
+                entries << deserialize_review(row)
+                recovered_labels << label
+              else
+                entries << lost_seat_entry(reviewer, label)
+                lost_labels << label
+              end
+            end
+            return nil if recovered_labels.empty?
+
+            { entries: entries,
+              recovered_labels: recovered_labels,
+              lost_labels: lost_labels }
+          end
+
+          # The row a seat leaves behind when the worker died before its reply
+          # was persisted. Shaped like Dispatcher#build_skip so Consensus reads
+          # it on the path every skip takes: status :skip with a declared
+          # reason token, which lands in the denominator composition as
+          # `worker_crashed_seat_lost` beside the seat's name.
+          def lost_seat_entry(reviewer, label)
+            reviewer = {} unless reviewer.is_a?(Hash)
+            {
+              role_label: label,
+              provider: reviewer['provider'],
+              model: reviewer['model'],
+              model_declared: reviewer['model'],
+              model_source: 'declared',
+              artifact_delivery: reviewer['artifact_delivery'] || 'inline',
+              elapsed_seconds: 0,
+              error: { 'type' => 'skip', 'message' => 'worker_crashed_seat_lost' },
+              status: :skip
+            }
+          end
+
           # Pending state is JSON, so the slots that never ran come back with
           # string keys; Consensus reads them symbolised like everything else.
           def symbolize_excluded(entries)
