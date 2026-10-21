# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'set'

module KairosMcp
  module SkillSets
    module Agent
      # The operator's own words (design v0.5 INV-5). Records are admitted by
      # producer: only text the operator typed, never hook output, pasted host
      # output, or anything a run produced unless the operator's words name
      # it. The store is append-only JSONL under precedents/raw; one writer at
      # a time (flock on the store's lock file).
      class Precedents
        KINDS = %w[correction typed_answer confirmation ruling prestart].freeze
        RANK = { 'correction' => 3, 'typed_answer' => 2, 'prestart' => 2, 'ruling' => 2, 'confirmation' => 1 }.freeze
        PASTED_HOST_OUTPUT = /^\s*⏺/.freeze

        def initialize(dir)
          @dir = dir
          @raw = File.join(dir, 'raw')
          FileUtils.mkdir_p(@raw)
        end

        def lock(&block)
          File.open(File.join(@dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |f|
            f.flock(File::LOCK_EX)
            block.call
          end
        end

        # Adds operator acts. Each record: source, project, at, kind, question
        # (context the words answered), words. Returns how many were new.
        # A record whose question and words equal a stored record's is the same
        # answer read again from another source (the snapshot, then the live
        # transcript, give it another source and time, so another id); it is
        # dropped. Records of one call are distinct entries and are all kept.
        def add(records, file: 'harvest.jsonl')
          lock do
            stored = all
            known = stored.map { |r| r['id'] }.to_set
            answered = stored.map { |r| Precedents.answer_key(r) }.to_set
            path = File.join(@raw, file)
            added = 0
            File.open(path, 'a') do |f|
              records.each do |r|
                words = Precedents.strip_pasted(r['words'].to_s)
                next if words.strip.empty?
                raise ArgumentError, "unknown kind #{r['kind']}" unless KINDS.include?(r['kind'])

                rec = r.merge('words' => words)
                rec['id'] ||= 'P' + Digest::SHA256.hexdigest([rec['source'], rec['at'], words].join("\0"))[0, 12]
                next if known.include?(rec['id']) || answered.include?(Precedents.answer_key(rec))

                f.puts(JSON.generate(rec))
                known << rec['id']
                added += 1
              end
            end
            added
          end
        end

        # A torn or non-object line is skipped: it holds no record and does not
        # take the others down with it.
        def all
          Dir.glob(File.join(@raw, '*.jsonl')).sort.flat_map do |f|
            File.readlines(f, chomp: true, encoding: 'UTF-8').filter_map do |l|
              h = JSON.parse(l)
              h if h.is_a?(Hash)
            rescue JSON::ParserError
              nil
            end
          end
        end

        def ids
          all.map { |r| r['id'] }.to_set
        end

        # Words most related to the query, weighted by project and rank.
        def retrieve(query, project: nil, k: 12)
          q = Precedents.terms(query)
          return [] if q.empty?

          records = all
          df = Hash.new(0)
          records.each { |r| Precedents.terms("#{r['question']} #{r['words']}").uniq.each { |t| df[t] += 1 } }
          n = records.size.to_f
          scored = records.map do |r|
            t = Precedents.terms("#{r['question']} #{r['words']}")
            overlap = (q & t).sum { |w| Math.log((n + 1) / (df[w] + 1)) + 1 }
            next nil if overlap.zero?

            score = overlap * (1 + 0.15 * RANK.fetch(r['kind'], 1))
            score *= 1.5 if project && Precedents.project_key(r['project']).include?(Precedents.project_key(project))
            [score, r]
          end.compact
          scored.sort_by { |s, r| [-s, r['at'].to_s] }.first(k).map(&:last)
        end

        # Host output the operator pasted is not the operator's words. When a
        # prompt carries the host's output marker (⏺), keep what the operator
        # typed before the first marked line, and a short closing paragraph
        # after the paste only if it carries no table, heading or list.
        def self.strip_pasted(text)
          lines = text.to_s.lines
          first = lines.index { |l| l =~ PASTED_HOST_OUTPUT }
          return text.to_s.strip unless first

          before = lines[0...first].join.strip
          paras = lines[first..].join.split(/\n[ \t]*\n/)
          raw = paras.size > 1 ? paras.last.to_s.sub(/\A\n+/, '').rstrip : ''
          # The host indents what follows its marker; what the operator types
          # after a paste starts at the margin.
          tail_ok = !raw.strip.empty? && raw.length < 400 && raw.lines.all? { |l| l !~ /\A[ \t]/ } &&
                    raw !~ PASTED_HOST_OUTPUT && raw !~ /^\s*(\||#|[-*] |\d+\. |```)/
          [before, (tail_ok ? raw.strip : nil)].compact.reject(&:empty?).join("\n\n")
        end

        # What makes two records the same answer: the question's first 200
        # characters and the words.
        # The same answer to the same question in the same project (a harvest
        # and a snapshot of it); an operator act keeps its own source.
        def self.answer_key(record)
          [record['kind'] == 'typed_answer' ? nil : record['source'], project_key(record['project']),
           record['question'].to_s.strip[0, 200], record['words'].to_s]
        end

        # Project names as the host spells transcript directories
        # (-Users-masa-forback-github-KairosChain-2026) and as a repository's
        # basename (KairosChain_2026) compare equal under this key.
        def self.project_key(name)
          name.to_s.downcase.gsub(/[^a-z0-9]+/, '-')
        end

        # Latin words and CJK character bigrams.
        def self.terms(text)
          s = text.to_s.downcase
          latin = s.scan(/[a-z0-9_]{3,}/)
          cjk = s.scan(/[\p{Han}\p{Hiragana}\p{Katakana}ー]+/).flat_map do |run|
            run.chars.each_cons(2).map(&:join)
          end
          (latin + cjk).uniq
        end
      end
    end
  end
end
