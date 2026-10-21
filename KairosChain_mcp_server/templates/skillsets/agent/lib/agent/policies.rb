# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'fileutils'
require_relative 'dsl'
require_relative 'transcript'
require_relative 'precedents'

module KairosMcp
  module SkillSets
    module Agent
      # The operator's policies (the mandate, design v0.5.1 §2). A policy
      # version binds only when the operator's own typed words adopt it by
      # name and digest; agent_start pins only an adopted digest.
      class Policies
        DIGEST_PREFIX = 8

        def initialize(paths)
          @paths = paths
        end

        def files
          Dir.glob(File.join(@paths.policies_dir, '*.rb')).sort
        end

        # Every policy file that parses; one broken file does not take the
        # others (or the guard) down with it.
        def all
          files.filter_map do |f|
            DSL.parse_policy(File.read(f))
          rescue StandardError, ScriptError
            nil
          end
        end

        def find(name)
          all.find { |p| p.name == name.to_s }
        end

        # A torn or garbled line is skipped: it adopts nothing and does not
        # take the other adoptions down with it.
        def adoptions
          return [] unless File.exist?(@paths.adoptions_path)

          File.readlines(@paths.adoptions_path, chomp: true, encoding: 'UTF-8').filter_map do |l|
            h = JSON.parse(l)
            h if h.is_a?(Hash)
          rescue JSON::ParserError
            nil
          end
        end

        # The adopted policy: the latest adoption whose digest still matches
        # a policy file's bytes. A changed file is not adopted.
        def adopted
          latest = adoptions.last
          return nil unless latest

          p = find(latest['name'])
          p && p.digest == latest['digest'] ? p : nil
        end

        # Full-width marks are spelled as escapes (\uFF0E ．, \uFF01 ！, \uFF1F ？)
        # so that normalising the source cannot change what they match.
        SENTENCE_BREAK = /(?<=[\u3002\uFF0E\uFF01\uFF1F!?\r\n])|(?<=\.)(?=\s)/
        QUESTION = /[?\uFF1F]|(ですか|ますか|でしょうか|かな|のか|か)\s*[\u3002.]?\z|\A\s*(what|how|why|does|do|should|is|can|would)\b/i
        ADOPTING = /採用|adopt/i
        NEGATION = /\b(?:not|never|cancel|revoke|reject)\b|n['\u2019]t\b|cannot|ない|ません|不採用|やめ|取り?消|却下|まだ|保留|待って|後で|あとで/i
        # Words that take an adoption back or put it off, in any sentence.
        RETRACTION = /やっぱり|やめ(て|る|よう)|取り?消|撤回|保留|待って|後で|あとで|まだ(決め|採用)|\b(wait|hold on|later|cancel|never ?mind)\b/i
        # Stands in for the adopting phrase while its text is read by sentence,
        # so a name or digest never ends a sentence or reads as a negation.
        PHRASE_MARK = "\u0001"

        # The operator's adopting sentence must say "adopt policy <name>
        # <first eight hex digits of its digest>" in their own part of a prompt
        # they typed (pasted host output is set aside), and must be found as
        # typed in that session's transcript. Read by sentence, no sentence of
        # their own part that speaks of adopting may negate it or ask about
        # it ("…とタイプすれば採用になるの？今はまだ採用しない"); other
        # sentences may carry ordinary clauses such as "以後は質問しないで".
        def adopt(name, words:, transcript_path:, prompt_id: nil, record: nil)
          policy = find(name) or raise ArgumentError, "no policy #{name}"
          text = words.to_s
          own = Precedents.strip_pasted(text)
          said = "adopt policy #{policy.name} #{policy.digest[0, DIGEST_PREFIX]}"
          phrase = /adopt\s+policy\s+#{Regexp.escape(policy.name)}\s+#{policy.digest[0, DIGEST_PREFIX]}/i
          raise ArgumentError, "the operator's words must say: #{said}" unless own.match?(phrase)

          about = own.gsub(phrase, PHRASE_MARK).split(SENTENCE_BREAK).map(&:strip)
                     .select { |s| s.include?(PHRASE_MARK) || s.match?(ADOPTING) }
          if (s = about.find { |x| x.delete(PHRASE_MARK).match?(NEGATION) })
            raise ArgumentError, "the operator's words negate the adoption: #{s.gsub(PHRASE_MARK, said)}"
          end
          if (s = own.gsub(phrase, PHRASE_MARK).split(SENTENCE_BREAK).map(&:strip).find { |x| x.match?(RETRACTION) })
            raise ArgumentError, "the operator's words take the adoption back or put it off: #{s.gsub(PHRASE_MARK, said)}"
          end
          if (s = about.find { |x| x.match?(QUESTION) })
            raise ArgumentError, "the operator's words ask about the adoption, not adopt: #{s.gsub(PHRASE_MARK, said)}"
          end
          unless Transcript.typed_prompt?(transcript_path, prompt_id: prompt_id, text: text)
            raise ArgumentError, 'those words are not a prompt the operator typed in that session'
          end

          entry = { 'name' => policy.name, 'digest' => policy.digest, 'at' => Time.now.utc.iso8601,
                    'words_sha256' => Digest::SHA256.hexdigest(text), 'transcript_path' => transcript_path }
          entry['chain_ref'] = record&.call(entry)
          @paths.ensure_ignored
          FileUtils.mkdir_p(File.dirname(@paths.adoptions_path))
          File.open(@paths.adoptions_path, 'a') { |f| f.puts(JSON.generate(entry)) }
          policy
        end
      end

      # The active instruction mode, read from the data directory. The stand-in
      # receives the sections that bear on judgment, not the whole body.
      module InstructionMode
        SECTIONS = ['Rule Hierarchy', 'Process and Speed', 'Ten Principles', 'Scope-broadening bias',
                    'LLM Bias Awareness', 'Integrity: Situated, Not Softened'].freeze
        LIMIT = 24_000

        module_function

        def load(data_dir)
          manifest = File.join(data_dir, 'instruction_mode_manifest.json')
          name = File.exist?(manifest) ? JSON.parse(File.read(manifest))['mode_name'] : nil
          path = name && File.join(data_dir, 'skills', "#{name}.md")
          return '' unless path && File.exist?(path)

          excerpt(File.read(path))
        end

        def excerpt(text)
          chunks = SECTIONS.filter_map { |s| section(text, s) }
          out = chunks.empty? ? text : chunks.join("\n\n")
          out[0, LIMIT]
        end

        def section(text, title)
          lines = text.lines
          i = lines.index { |l| l =~ /\A(\#{2,3})\s.*#{Regexp.escape(title)}/ }
          return nil unless i

          level = lines[i][/\A#+/].size
          j = ((i + 1)...lines.size).find { |k| lines[k] =~ /\A\#{1,#{level}}\s/ } || lines.size
          lines[i...j].join
        end
      end
    end
  end
end
