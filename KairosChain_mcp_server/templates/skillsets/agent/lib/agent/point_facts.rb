# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # Append-only point facts for judge distillation (INV-K1).
      #
      # F1: a step's tool name is recorded only when that step was classified.
      #     An unclassified step is counted, never named -- its name is the
      #     agent's own text and is written nowhere.
      # F2: every value written comes from the arguments; nothing is read from
      #     the plan beyond 'steps', each step's 'tool_name' (classified only)
      #     and 'requires_human_cognition'.
      # F3: the store is append-only JSON lines; reading skips blank, malformed
      #     and non-object lines and never raises on content.
      # F4: record_answer covers every plan classified between the previous
      #     answer and the moment this answer was given, so one answer after
      #     several cycles covers all their plans and none it caused.
      module PointFacts
        FILE = 'point_facts.jsonl'

        module_function

        # Facts about one plan. rows is aligned with task_json['steps'];
        # rows[i] is nil (step i not classified) or a row Hash. Only 'effect'
        # is used from the row.
        def facts_for(task_json, rows)
          steps = task_json.is_a?(Hash) ? task_json['steps'] : nil
          steps = nil unless steps.is_a?(Array)
          rows = [] unless rows.is_a?(Array)

          classified = []
          unclassified = 0
          marked = 0

          (steps || []).each_with_index do |step, i|
            # Counted for classified and unclassified steps alike.
            marked += 1 if step.is_a?(Hash) && step['requires_human_cognition'] == true

            row = rows[i]
            tool = step.is_a?(Hash) ? step['tool_name'] : nil
            if row.is_a?(Hash) && tool.is_a?(String)
              classified << { 'tool' => tool, 'effect' => row['effect'] }
            else
              unclassified += 1 # F1: no name leaves this branch.
            end
          end

          {
            'steps' => classified,
            'unclassified' => unclassified,
            'marked_for_person' => marked,
            'step_count' => steps ? steps.length : 0
          }
        end

        # Append one 'plan' line. Creates session_dir and the file if missing.
        def append_plan(session_dir, cycle:, plan_sha256:, act_table_sha256:, facts:)
          entry = {
            'kind' => 'plan',
            'cycle' => cycle,
            'plan_sha256' => plan_sha256,
            'act_table_sha256' => act_table_sha256,
            'facts' => facts,
            'at' => Time.now.utc.iso8601
          }
          with_lock(session_dir, 'a') { |f| f.write(JSON.generate(entry) + "\n") }
          entry
        end

        # The number of lines in the store now: the boundary an answer's window
        # ends at. Taken when the operator's answer is reconciled, before the
        # advance runs anything, so plans the answer itself causes (the next
        # cycles of an autonomous run) fall in the next answer's window.
        # Raises when the store exists but cannot be read: a boundary that is
        # not known is not 0.
        def line_count(session_dir)
          path = file_path(session_dir)
          File.file?(path) ? File.read(path).lines.size : 0
        end

        # Append one 'answer' line covering every plan in its window (F4): from
        # the previous answer's boundary (its 'through', or the line after it
        # when it has none) up to through, the line count taken before the
        # advance ran (all lines when nil). current is nil or { 'cycle',
        # 'plan_sha256', 'act_table_sha256', 'facts' }; it is appended unless a
        # gathered plan carries the same plan_sha256. A plan recorded twice in
        # one cycle (a reattempted act) is gathered once; the same plan in two
        # cycles is two. unavailable: the facts of this answer could not be
        # observed; the line still closes the window, with plans null, so
        # its plans are no other answer's. Gather and append happen under one
        # exclusive lock. Returns the SHA256 of the written line, without the
        # newline.
        def record_answer(session_dir, anchor:, point:, cycle:, current:, through: nil, unavailable: false)
          line = nil

          with_lock(session_dir, 'a+') do |f|
            f.rewind
            raws = f.read.lines
            stop = through.is_a?(Integer) ? [through, raws.size].min : raws.size
            plans = []
            window(raws, stop).each do |e|
              next if plans.any? { |p| p['cycle'] == e['cycle'] && p['plan_sha256'] == e['plan_sha256'] }

              plans << plan_view(e)
            end

            if current.is_a?(Hash) &&
               plans.none? { |p| p['plan_sha256'] == current['plan_sha256'] }
              plans << plan_view(current)
            end

            entry = {
              'kind' => 'answer',
              'anchor' => anchor,
              'point' => point,
              'cycle' => cycle,
              'plans' => unavailable ? nil : plans,
              'through' => stop,
              'at' => Time.now.utc.iso8601
            }
            line = JSON.generate(entry)
            f.write(line + "\n") # 'a+' appends regardless of the rewind above.
          end

          Digest::SHA256.hexdigest(line)
        end

        # The last answer line for this anchor, as [entry, sha256_of_line].
        # nil when there is no such line and when there is no file.
        def answer_facts(session_dir, anchor)
          path = file_path(session_dir)
          return nil unless File.file?(path)

          found = nil
          raw_lines(path).each do |raw|
            obj = parse_line(raw)
            next unless obj.is_a?(Hash)
            next unless obj['kind'] == 'answer' && obj['anchor'] == anchor

            found = [obj, Digest::SHA256.hexdigest(raw.chomp("\n"))]
          end
          found
        end

        # Parsed Hash objects in file order; [] when there is no file.
        def entries(session_dir)
          path = file_path(session_dir)
          return [] unless File.file?(path)

          parse_lines(raw_lines(path))
        end

        # --- internals -----------------------------------------------------

        def file_path(session_dir)
          File.join(session_dir.to_s, FILE)
        end

        # mkdir_p because 'a'/'a+' create the file but not the directory.
        def with_lock(session_dir, mode)
          FileUtils.mkdir_p(session_dir.to_s)
          File.open(file_path(session_dir), mode) do |f|
            f.flock(File::LOCK_EX)
            yield f
          end
        end

        def raw_lines(path)
          File.read(path).lines
        rescue StandardError
          []
        end

        def parse_lines(lines)
          lines.filter_map { |raw| parse_line(raw) }
        end

        # F3: blank, malformed and non-object lines are skipped, not raised on.
        def parse_line(raw)
          text = raw.to_s.strip
          return nil if text.empty?

          obj = JSON.parse(text)
          obj.is_a?(Hash) ? obj : nil
        rescue StandardError
          nil
        end

        # The 'plan' entries in an answer's window, by raw line index: from the
        # last answer's boundary up to stop. The boundary is that answer's
        # 'through' when it carries one; a line written without one (before
        # windows were bounded) ends at itself.
        def window(raws, stop)
          start = 0
          raws.each_with_index do |raw, i|
            break if i >= stop

            obj = parse_line(raw)
            next unless obj.is_a?(Hash) && obj['kind'] == 'answer'

            start = obj['through'].is_a?(Integer) ? obj['through'] : i + 1
          end
          (start...stop).filter_map do |i|
            obj = parse_line(raws[i])
            obj if obj.is_a?(Hash) && obj['kind'] == 'plan'
          end
        end

        # Exactly the four carried keys, for gathered plans and for current
        # alike (F2: extra keys are not propagated).
        def plan_view(entry)
          {
            'cycle' => entry['cycle'],
            'plan_sha256' => entry['plan_sha256'],
            'act_table_sha256' => entry['act_table_sha256'],
            'facts' => entry['facts']
          }
        end

        private_class_method :file_path, :with_lock, :raw_lines, :parse_lines,
                             :parse_line, :window, :plan_view
      end
    end
  end
end
