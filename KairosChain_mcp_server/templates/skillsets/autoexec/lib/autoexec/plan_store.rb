# frozen_string_literal: true

module Autoexec
  # Stores task plans, manages hash verification, execution locks, and checkpoints.
  # Plans stored as .kdsl (non-executable DSL text) with .json metadata sidecar.
  class PlanStore
    LOCK_FILE = 'autoexec.lock'

    # --- Plan Storage ---

    def self.save(task_id, plan, source)
      raise ArgumentError, "Invalid task_id: must contain only word characters" unless task_id.to_s.match?(/\A\w+\z/)

      plans_dir = Autoexec.storage_path('plans')
      plan_path = File.join(plans_dir, "#{task_id}.kdsl")
      meta_path = File.join(plans_dir, "#{task_id}.json")
      plan_hash = TaskDsl.compute_hash(source)

      File.write(plan_path, source)
      File.write(meta_path, JSON.pretty_generate({
        task_id: task_id.to_s,
        plan_hash: plan_hash,
        step_count: plan.steps.size,
        risk_summary: RiskClassifier.risk_summary(plan.steps),
        created_at: Time.now.iso8601,
        status: 'planned'
      }))

      plan_hash
    end

    # Save executable plan as canonical JSON (Phase 2)
    def self.save_executable(task_id, plan)
      raise ArgumentError, "Invalid task_id: must contain only word characters" unless task_id.to_s.match?(/\A\w+\z/)

      plans_dir = Autoexec.storage_path('plans')
      plan_path = File.join(plans_dir, "#{task_id}.plan.json")
      meta_path = File.join(plans_dir, "#{task_id}.json")

      canonical = TaskDsl.canonical_plan_json(plan)
      plan_hash = Digest::SHA256.hexdigest(canonical)

      File.write(plan_path, canonical)
      File.write(meta_path, JSON.pretty_generate({
        task_id: task_id.to_s,
        plan_hash: plan_hash,
        step_count: plan.steps.size,
        risk_summary: RiskClassifier.risk_summary(plan.steps),
        executable: true,
        created_at: Time.now.iso8601,
        status: 'planned'
      }))

      plan_hash
    end

    def self.load(task_id)
      plans_dir = Autoexec.storage_path('plans')
      json_plan_path = File.join(plans_dir, "#{task_id}.plan.json")
      kdsl_plan_path = File.join(plans_dir, "#{task_id}.kdsl")
      meta_path = File.join(plans_dir, "#{task_id}.json")

      return nil unless File.exist?(meta_path)
      metadata = JSON.parse(File.read(meta_path), symbolize_names: true)

      if File.exist?(json_plan_path)
        # Executable plan (JSON format)
        json_str = File.read(json_plan_path)
        plan = TaskDsl.from_json(json_str)
        computed_hash = Digest::SHA256.hexdigest(json_str)
        { plan: plan, source: json_str, hash: computed_hash, metadata: metadata }
      elsif File.exist?(kdsl_plan_path)
        # Legacy plan (DSL format)
        source = File.read(kdsl_plan_path)
        plan = TaskDsl.parse(source)
        computed_hash = TaskDsl.compute_hash(source)
        { plan: plan, source: source, hash: computed_hash, metadata: metadata }
      else
        nil
      end
    end

    def self.verify_hash(task_id, expected_hash)
      stored = load(task_id)
      return false unless stored

      stored[:hash] == expected_hash
    end

    def self.list
      plans_dir = Autoexec.storage_path('plans')
      # Only metadata files (exclude .plan.json which are executable plan data)
      Dir.glob(File.join(plans_dir, '*.json')).reject { |p| p.end_with?('.plan.json') }.map do |meta_path|
        JSON.parse(File.read(meta_path), symbolize_names: true)
      rescue JSON::ParserError => e
        warn "[autoexec] Corrupted metadata file: #{meta_path} (#{e.message})"
        nil
      end.compact
    end

    def self.update_status(task_id, status)
      plans_dir = Autoexec.storage_path('plans')
      meta_path = File.join(plans_dir, "#{task_id}.json")
      return unless File.exist?(meta_path)

      metadata = JSON.parse(File.read(meta_path))
      metadata['status'] = status
      metadata['updated_at'] = Time.now.iso8601
      File.write(meta_path, JSON.pretty_generate(metadata))
    end

    # --- Execution Lock (OpenClaw session-write-lock pattern, simplified) ---

    def self.acquire_lock(task_id)
      state_dir = Autoexec.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)

      # Check for existing lock and handle stale/dead locks
      if File.exist?(lock_path)
        lock_data = JSON.parse(File.read(lock_path)) rescue {}
        pid = lock_data['pid']

        pid_alive = begin
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        if pid_alive
          stale_timeout = Autoexec.config.dig('stale_lock_timeout') || 3600
          lock_age = Time.now - Time.parse(lock_data['started_at'])
          if lock_age < stale_timeout
            raise "Execution locked by task '#{lock_data['task_id']}' (PID #{pid}, " \
                  "started #{lock_data['started_at']}). Use autoexec_run to check status."
          end
        end
        # PID dead or stale — remove before atomic create
        File.delete(lock_path) rescue nil
      end

      # Atomic lock creation using CREAT|EXCL (prevents race condition)
      lock_data = JSON.pretty_generate({
        task_id: task_id.to_s,
        pid: Process.pid,
        started_at: Time.now.iso8601
      })
      begin
        fd = File.open(lock_path, File::CREAT | File::EXCL | File::WRONLY)
        fd.write(lock_data)
        fd.close
      rescue Errno::EEXIST
        # Another process acquired the lock between our check and create
        raise "Execution locked by another process (race condition). Retry shortly."
      end
      true
    end

    def self.release_lock
      state_dir = Autoexec.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)
      File.delete(lock_path) if File.exist?(lock_path)
    end

    def self.locked?
      state_dir = Autoexec.storage_path('state')
      lock_path = File.join(state_dir, LOCK_FILE)
      return false unless File.exist?(lock_path)

      lock_data = JSON.parse(File.read(lock_path))
      pid_alive = begin
        Process.kill(0, lock_data['pid'])
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      pid_alive
    rescue StandardError
      false
    end

    # --- Checkpoints ---

    def self.save_checkpoint(task_id, state)
      state_dir = Autoexec.storage_path('state')
      path = File.join(state_dir, "#{task_id}.checkpoint.json")
      File.write(path, JSON.pretty_generate(state))
    end

    def self.load_checkpoint(task_id)
      state_dir = Autoexec.storage_path('state')
      path = File.join(state_dir, "#{task_id}.checkpoint.json")
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    end

    def self.clear_checkpoint(task_id)
      state_dir = Autoexec.storage_path('state')
      path = File.join(state_dir, "#{task_id}.checkpoint.json")
      File.delete(path) if File.exist?(path)
    end
  end
end
