# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'precedents'
require_relative 'transcript'
require_relative 'run'

module KairosMcp
  module SkillSets
    module Agent
      # Harvest of the operator's own words from host transcripts (INV-5),
      # run apart from runs because the host deletes transcripts after 30
      # days. Admitted: an AskUserQuestion answer the operator gave in the
      # dialog, and a typed prompt that answers a question the assistant left
      # at the end of its turn. Excluded: hook output, peer and task messages,
      # meta entries, pasted host output, and every AskUserQuestion answer in
      # a session that was ever bound to a run, in any instance on this
      # machine — there the stand-in answered, not the operator.
      class Harvest
        QUESTION_END = /(\?|\uFF1F|ますか。?|でしょうか。?|しますか。?|ですか。?)\s*\z/

        def initialize(paths, projects_root: File.expand_path('~/.claude/projects'))
          @paths = paths
          @paths.ensure_ignored
          @projects_root = projects_root
          @store = Precedents.new(paths.precedents_dir)
        end

        def stand_in_tool_use_ids
          Dir.glob(File.join(@paths.runs_dir, '*', 'journal.jsonl')).each_with_object(Set.new) do |f, set|
            File.foreach(f, encoding: 'UTF-8') do |l|
              e = JSON.parse(l) rescue next
              set << e['tool_use_id'] if e['kind'] == 'decision' && e['tool_use_id']
            end
          end
        end

        # Sessions bound to a run here, and in every instance on this machine
        # (the global list survives archived run directories).
        def bound_sessions
          set = Set.new
          Dir.glob(File.join(@paths.runs_dir, '*', 'journal.jsonl')).each do |f|
            File.foreach(f, encoding: 'UTF-8') do |l|
              e = JSON.parse(l) rescue next
              set << e['session_id'] if %w[bound resumed].include?(e['kind']) && e['session_id']
            end
          end
          g = Paths.global_bound_sessions_path
          File.foreach(g, encoding: 'UTF-8') { |l| set << l.strip unless l.strip.empty? } if File.exist?(g)
          set
        end

        def run(since: nil)
          excluded = stand_in_tool_use_ids
          bound = bound_sessions
          records = []
          Dir.glob(File.join(@projects_root, '*', '*.jsonl')).each do |file|
            next if since && File.mtime(file) < since

            records.concat(from_transcript(file, excluded, bound))
          end
          @store.add(records)
        end

        def from_transcript(file, excluded, bound = Set.new)
          project = File.basename(File.dirname(file))
          in_bound_session = bound.include?(File.basename(file, '.jsonl'))
          asks = {}
          last_text = nil
          out = []
          File.foreach(file, encoding: 'UTF-8') do |line|
            d = JSON.parse(line) rescue next
            next if d['isSidechain']

            content = d.dig('message', 'content')
            if d['type'] == 'assistant' && content.is_a?(Array)
              texts = content.select { |c| c.is_a?(Hash) && c['type'] == 'text' }.map { |c| c['text'] }
              last_text = texts.last unless texts.empty?
              content.each do |c|
                next unless c.is_a?(Hash) && c['type'] == 'tool_use'

                last_text = nil
                asks[c['id']] = c['input'] if c['name'] == 'AskUserQuestion'
              end
            elsif d['type'] == 'user'
              if content.is_a?(Array) && (tr = content.find { |c| c.is_a?(Hash) && c['type'] == 'tool_result' && asks.key?(c['tool_use_id']) })
                next if in_bound_session || bound.include?(d['sessionId']) || excluded.include?(tr['tool_use_id'])

                tur = d['toolUseResult']
                answers = tur.is_a?(Hash) ? tur['answers'] : nil
                next unless answers.is_a?(Hash)

                Array(asks[tr['tool_use_id']]['questions']).each do |q|
                  a = answers[q['question']]
                  next unless a

                  out << rec(file, project, d['timestamp'], q['question'], a, options: q['options'])
                end
              elsif Transcript.typed?(d)
                text = Transcript.text_of(d)
                out << rec(file, project, d['timestamp'], last_text.to_s[-1500..] || last_text.to_s, text) if last_text && QUESTION_END.match?(last_text.strip)
                last_text = nil
              end
            end
          end
          out
        end

        # The 2026-10-20 snapshot (taken before 1.0 existed, so no stand-in
        # answered in it): AskUserQuestion pairs and the operator-only prose
        # answers. Transcripts older than 30 days survive only there.
        def import_snapshot(dir)
          records = []
          pairs = File.join(dir, 'askuserquestion_pairs_20261020.json')
          if File.exist?(pairs)
            JSON.parse(File.read(pairs)).each do |p|
              result = p['result'].to_s
              Array(p.dig('input', 'questions')).each do |q|
                m = result.match(/"#{Regexp.escape(q['question'].to_s)}"="(.*?)"(?=\s|\.|,|\z)/m) or next
                records << rec("snapshot:#{p['proj']}", p['proj'], p['ts'], q['question'], m[1], options: q['options'])
              end
            end
          end
          prose = File.join(dir, 'prose_question_answers_20261020_operator_only.json')
          if File.exist?(prose)
            JSON.parse(File.read(prose)).each do |p|
              records << rec(p['source'].to_s, p['project'], p['answered_at'], p['question_tail'], p['answer'])
            end
          end
          @store.add(records)
        end

        private

        def rec(file, project, at, question, words, options: nil)
          q = question.to_s
          q += " | options: #{Array(options).map { |o| o['label'] }.join(' / ')}" if options
          { 'source' => file, 'project' => project, 'at' => at, 'kind' => 'typed_answer', 'question' => q[0, 2000],
            'words' => words.to_s[0, 4000] }
        end
      end
    end
  end
end
