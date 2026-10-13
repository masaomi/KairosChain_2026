# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

require_relative 'distiller'

module KairosMcp; module SkillSets; module Agent
  # One distillation run: single-flight (R1), bounded before the model call (R2),
  # never raising (R3), draft files only ever paired with a chain record (R4).
  module DistillRun
    STATE_FILE = 'state.json'
    LOCK_FILE = 'distill.lock'
    RECORD_KIND = 'agent_distill_draft'

    module_function

    # Always returns a Hash carrying 'status'. Never raises.
    def run(dir:, delegation_status:, records:, facts:, reason:, edits:, llm:, chain:, judge:, prompts:,
            manual: false, now: Time.now.utc)
      FileUtils.mkdir_p(File.join(dir, 'drafts'))
      # R1: the whole run holds the lock; closing the handle (incl. process death) releases it.
      File.open(File.join(dir, LOCK_FILE), 'a') do |lock|
        return { 'status' => 'busy' } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        attempt(dir: dir, delegation_status: delegation_status, records: records, facts: facts,
                reason: reason, edits: edits, llm: llm, chain: chain, judge: judge,
                prompts: prompts, manual: manual, now: now)
      end
    rescue StandardError => e
      # R3 backstop: a failure before the lock cannot reliably write state.json.
      { 'status' => 'failed', 'reason' => "internal_error: #{detail(e)}" }
    end

    # => Hash; {} when state.json is absent, unreadable, or not a Hash.
    def state(dir)
      parsed = JSON.parse(File.read(File.join(dir, STATE_FILE)))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    # => [{ 'stamp', 'path', 'edit_path', 'manifest' }], newest first; unreadable manifests skipped.
    def drafts(dir)
      base = File.join(dir, 'drafts')
      Dir.glob(File.join(base, '*.json')).map do |file|
        begin
          manifest = JSON.parse(File.read(file))
          next nil unless manifest.is_a?(Hash)

          stamp = (manifest['stamp'] || File.basename(file, '.json')).to_s
          { 'stamp' => stamp, 'path' => File.join(base, "#{stamp}.md"),
            'edit_path' => File.join(base, "#{stamp}.edit.md"), 'manifest' => manifest }
        rescue StandardError
          nil
        end
      end.compact.sort_by { |d| d['stamp'] }.reverse
    end

    # --- internals (module functions; not part of the API) ---

    # Steps 2..11, under the lock.
    def attempt(dir:, delegation_status:, records:, facts:, reason:, edits:, llm:, chain:, judge:,
                prompts:, manual:, now:)
      st = state(dir)
      hw = st['high_water'].to_i
      at = now.iso8601

      return { 'status' => 'table_not_in_force' } unless delegation_status == 'in_force'

      n = Distiller.count_new(records, high_water: hw)
      return { 'status' => 'below_threshold', 'count' => n } unless manual || n >= Distiller::THRESHOLD

      answers = Distiller.inputs(records, facts: facts, reason: reason)
      return { 'status' => 'no_answers' } if answers.nil? || answers.empty?

      # R2: the water mark and last.status = 'running' land BEFORE the model is called,
      # so a crash or a refusal waits for ten more answers (or a manual run).
      new_hw = answers.map { |a| a['block'].to_i }.max
      kept_hw = [hw, new_hw].max
      write_state(dir, { 'high_water' => kept_hw,
                         'last' => { 'status' => 'running', 'at' => at, 'count' => n } })

      begin
        resp = llm.call(system: prompts.system_prompt, user: prompts.user_prompt(answers, edits),
                        model: judge['model'], effort: judge['effort'], provider: judge['provider'])
      rescue StandardError => e
        return failed(dir, kept_hw, "llm_error: #{detail(e)}", at)
      end

      observed = resp['model_observed']
      return failed(dir, kept_hw, 'provider_mismatch', at) unless resp['provider'] == judge['provider']
      return failed(dir, kept_hw, 'model_unobserved', at) if observed.nil?
      unless observed.sub(/\[[^\]]*\]\z/, '') == judge['model']
        return failed(dir, kept_hw, 'model_mismatch', at)
      end

      statements, err = Distiller.parse_draft(resp['content'], answers)
      return failed(dir, kept_hw, "parse_failure: #{err}", at) if err

      stamp = free_stamp(dir, now.strftime('%Y%m%dT%H%M%SZ'))
      body = Distiller.render(statements, answers, { 'version' => stamp })
      draft_sha = sha256(body)
      # Built once and hashed as written, so manifest_sha256 covers the exact bytes on disk.
      manifest = JSON.pretty_generate(
        'stamp' => stamp,
        'input_blocks' => answers.map { |a| a['block'] },
        'high_water' => new_hw,
        'prompt_sha256' => prompts.sha256,
        'requested_model' => judge['model'],
        'observed_model' => observed,
        'requested_effort' => judge['effort'],
        'draft_sha256' => draft_sha,
        'statements' => statements.size,
        'drafted_at' => at
      )
      path = File.join(dir, 'drafts', "#{stamp}.md")

      begin
        write_atomic(path, body)
        write_atomic(File.join(dir, 'drafts', "#{stamp}.edit.md"), body)
        write_atomic(File.join(dir, 'drafts', "#{stamp}.json"), manifest)
      rescue StandardError => e
        return failed(dir, kept_hw, "write_failed: #{detail(e)}", at)
      end

      # R4: the record comes after the files; a refusal leaves them unrecorded, and adoption refuses them.
      begin
        block = chain.add_block([JSON.generate(
          'kind' => RECORD_KIND,
          'stamp' => stamp,
          'draft_sha256' => draft_sha,
          'manifest_sha256' => sha256(manifest),
          'high_water' => new_hw,
          'inputs' => answers.size,
          'prompt_sha256' => prompts.sha256,
          'requested_model' => judge['model'],
          'observed_model' => observed,
          'requested_effort' => judge['effort'],
          'drafted_at' => at
        )])
        index = block.index
      rescue StandardError => e
        # The one failure that leaves draft files on disk: say why.
        return failed(dir, kept_hw, "chain_refused: #{detail(e)}", at)
      end

      write_state(dir, { 'high_water' => kept_hw,
                         'last' => { 'status' => 'drafted', 'stamp' => stamp, 'block' => index, 'at' => at } })
      { 'status' => 'drafted', 'stamp' => stamp, 'path' => path, 'block' => index }
    end

    # Records the failure and returns it; the water mark is kept.
    def failed(dir, high_water, reason, at)
      write_state(dir, { 'high_water' => high_water,
                         'last' => { 'status' => 'failed', 'reason' => reason, 'at' => at } })
      { 'status' => 'failed', 'reason' => reason }
    rescue StandardError
      { 'status' => 'failed', 'reason' => reason }
    end

    # A stamp no draft file uses yet: a recorded draft and the operator's edit
    # copy are never written over (a clock stepped back, two runs in a second).
    def free_stamp(dir, base)
      stamp = base
      n = 1
      while %w[.md .edit.md .json].any? { |ext| File.exist?(File.join(dir, 'drafts', "#{stamp}#{ext}")) }
        n += 1
        stamp = "#{base}-#{n}"
      end
      stamp
    end

    def write_state(dir, st)
      write_atomic(File.join(dir, STATE_FILE), JSON.pretty_generate(st))
    end

    # tmp + rename; the tmp is created 0600 so the rename carries that mode over.
    def write_atomic(path, content)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1 << 32).to_s(16)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(content) }
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end

    def sha256(str)
      Digest::SHA256.hexdigest(str)
    end

    def detail(err)
      "#{err.class}: #{err.message.to_s[0, 200]}"
    end
  end
end; end; end
