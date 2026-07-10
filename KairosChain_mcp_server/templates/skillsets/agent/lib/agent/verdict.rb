# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'admission'

module KairosMcp
  module SkillSets
    module Agent
      # Verdict — AGT-3/AGT-4/AGT-6 mechanical acceptance for agent cycles
      # (guard track design v0.3.1 FROZEN).
      #
      # Contract (per the frozen loop_validation discipline):
      # - the specification is pinned content-addressed at session start (the
      #   human-approval moment for the mandate's guard material) — before any
      #   cycle runs, so the deciding context never authors what judges it.
      # - the verdict is deterministic and model-free; its evidence is state
      #   the driver observes itself (scratch-area content on disk, the
      #   driver's own execution outcome), never model/executor report.
      # - fail-closed: no spec, unreadable spec, hash mismatch (tamper), or an
      #   unknown check type yields HALT — never a default pass. The referenced
      #   verdict discipline's attended no-spec mode is NOT supported here.
      # - constant-key verdict: { 'verdict', 'checks', 'spec_sha256', 'reason' }.
      module Verdict
        PASS = 'pass'
        FAIL = 'fail'
        HALT = 'halt'

        CHECK_TYPES = %w[file_exists file_contains manifest_not_empty execution_completed].freeze

        SPEC_FILE = 'guard_spec.json'
        SHA_FILE  = 'guard_spec.sha256'

        class SpecError < StandardError; end

        module_function

        # Pin the guard specification at session start. Validates the material
        # fail-closed and fixes it by content hash. Returns the sha256.
        def pin!(session_dir, material)
          raise SpecError, 'guard material is nil' if material.nil?

          acceptance = material['acceptance']
          unless acceptance.is_a?(Array) && !acceptance.empty?
            raise SpecError, 'guard material must declare non-empty acceptance checks (AGT-4: no spec means no gated act)'
          end
          acceptance.each do |check|
            type = check.is_a?(Hash) ? check['type'] : nil
            unless CHECK_TYPES.include?(type)
              raise SpecError, "unknown acceptance check type: #{type.inspect} (allowed: #{CHECK_TYPES.join(', ')})"
            end
          end

          # AGT-5: validate the declared layer surface at pin time — an
          # undeclarable or unknown surface refuses the session, it does not
          # degrade at act time.
          begin
            Admission.validate_surface!(material['layer_surface'] || [])
          rescue Admission::SurfaceError => e
            raise SpecError, e.message
          end

          spec = {
            'acceptance' => acceptance,
            'layer_surface' => material['layer_surface'] || [],
            'act_individuation' => material['act_individuation'] || 'one dispatched ACT task payload = one act'
          }
          json = JSON.generate(spec)
          sha = Digest::SHA256.hexdigest(json)
          File.write(File.join(session_dir, SPEC_FILE), json)
          File.write(File.join(session_dir, SHA_FILE), sha)
          sha
        end

        def pinned?(session_dir)
          File.exist?(File.join(session_dir, SPEC_FILE)) && File.exist?(File.join(session_dir, SHA_FILE))
        end

        # Load and hash-verify the pinned spec. Returns [spec, nil] or [nil, halt_verdict].
        def load_pinned(session_dir)
          spec_path = File.join(session_dir, SPEC_FILE)
          sha_path = File.join(session_dir, SHA_FILE)
          unless File.exist?(spec_path) && File.exist?(sha_path)
            return [nil, halt_verdict('no pinned specification (AGT-6: no spec means no gated act)')]
          end

          json = File.read(spec_path)
          expected = File.read(sha_path).strip
          actual = Digest::SHA256.hexdigest(json)
          if actual != expected
            return [nil, halt_verdict("spec tamper detected: pinned #{expected[0, 12]}… != actual #{actual[0, 12]}…")]
          end

          [JSON.parse(json), nil]
        rescue JSON::ParserError => e
          [nil, halt_verdict("pinned spec unreadable: #{e.message}")]
        end

        # Judge a cycle's act against the pinned spec.
        # evidence keys (all driver-observed):
        #   'scratch_dir' — the act's scratch area (delegated route); file checks
        #                   read from disk here, from boundary position.
        #   'manifest'    — driver-computed list of produced files.
        #   'execution_summary' — the driver's own execution outcome for the
        #                   in-process route ('completed' / 'failed').
        def judge(session_dir, evidence)
          spec, halt = load_pinned(session_dir)
          return halt if halt

          checks = []
          spec['acceptance'].each do |check|
            checks << run_check(check, evidence || {})
            # Unknown types cannot occur for a validly pinned spec, but a halt
            # from run_check (defense in depth) short-circuits fail-closed.
            return halt_verdict(checks.last['detail'], checks: checks) if checks.last['result'] == HALT
          end

          verdict = checks.all? { |c| c['result'] == PASS } ? PASS : FAIL
          {
            'verdict' => verdict,
            'checks' => checks,
            'spec_sha256' => File.read(File.join(session_dir, SHA_FILE)).strip,
            'reason' => verdict == PASS ? 'all acceptance checks passed' : 'one or more acceptance checks failed'
          }
        end

        def run_check(check, evidence)
          type = check['type']
          result, detail =
            case type
            when 'file_exists'
              path = scratch_path(check, evidence)
              if path.nil?
                [FAIL, 'no scratch evidence for file check']
              else
                [File.file?(path) ? PASS : FAIL, path]
              end
            when 'file_contains'
              path = scratch_path(check, evidence)
              if path.nil? || !File.file?(path)
                [FAIL, "file missing: #{check['path']}"]
              else
                ok = File.read(path).include?(check['substring'].to_s)
                [ok ? PASS : FAIL, "substring #{ok ? 'found' : 'absent'} in #{check['path']}"]
              end
            when 'manifest_not_empty'
              m = evidence['manifest']
              [(m.is_a?(Array) && !m.empty?) ? PASS : FAIL, "manifest size: #{m.is_a?(Array) ? m.size : 'absent'}"]
            when 'execution_completed'
              [(evidence['execution_summary'] == 'completed') ? PASS : FAIL,
               "driver-observed execution: #{evidence['execution_summary'].inspect}"]
            else
              [HALT, "unknown check type at judge time: #{type.inspect}"]
            end
          { 'type' => type, 'result' => result, 'detail' => detail }
        end

        # Resolve a check's relative path inside the scratch area — evidence is
        # read from the driver's position on disk, never taken from model text.
        def scratch_path(check, evidence)
          scratch = evidence['scratch_dir']
          rel = check['path'].to_s
          return nil if scratch.nil? || rel.empty? || rel.start_with?('/')

          full = File.expand_path(rel, scratch)
          return nil unless full == scratch || full.start_with?("#{scratch}/")

          full
        end

        def halt_verdict(reason, checks: [])
          { 'verdict' => HALT, 'checks' => checks, 'spec_sha256' => nil, 'reason' => reason }
        end
      end
    end
  end
end
