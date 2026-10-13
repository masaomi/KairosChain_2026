# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require_relative 'act_classification'
require_relative 'answer_ruling'
require_relative 'delegation'
require_relative 'distiller'
require_relative 'distill_run'

module KairosMcp
  module SkillSets
    module Agent
      # Adopting a distilled draft as the judgment precedents the shadow
      # judge reads (distillation design v0.2, INV-K3 / §6 item 11).
      #
      # The only path that pins new precedents. It offers a draft only when
      # the draft's bytes match the record the distiller worker put on the
      # chain, a write no agent path can make; it shows the operator every
      # change between that draft and what is adopted, and between the entry
      # in force and what is adopted; it takes the terminal nonce; it writes
      # the entry and records one delegation ruling that pins it, with an
      # 'adoption' field naming the draft. A ruling that cannot be recorded
      # puts the previous entry back.
      module Adoption
        # Session states between two stops: a table changes only between runs
        # (v0.3 INV-D5).
        MID_RUN = %w[orienting deciding acting reflecting autonomous_cycling].freeze

        class << self
          # Test seam: a callable returning [draft records, error].
          attr_accessor :records_source
        end

        module_function

        # [records, nil] or [[], reason]: the distiller's draft records, each
        # with its block index.
        def draft_records
          return Adoption.records_source.call if Adoption.records_source

          require 'kairos_mcp/kairos_chain/chain'
          chain = ::KairosMcp::KairosChain::Chain.new
          state = chain.load_state
          return [[], "chain #{state}"] unless %i[readable absent].include?(state)

          recs = chain.chain.flat_map do |block|
            Array(block.data).filter_map do |entry|
              rec = entry.is_a?(String) ? (JSON.parse(entry) rescue nil) : entry
              rec.merge('block' => block.index) if rec.is_a?(Hash) && rec['kind'] == DistillRun::RECORD_KIND
            end
          end
          [recs, nil]
        rescue StandardError, ScriptError => e
          [[], "chain unreadable: #{e.class}: #{e.message[0, 120]}"]
        end

        # Session ids whose state is between two stops.
        def sessions_mid_run(sessions_dir)
          Dir.glob(File.join(sessions_dir, '*', 'session.json')).filter_map do |f|
            s = JSON.parse(File.read(f))
            s['session_id'] || File.basename(File.dirname(f)) if s.is_a?(Hash) && MID_RUN.include?(s['state'])
          rescue StandardError
            nil
          end
        end

        # The draft offered: [draft, record, base_bytes, nil] or [nil, nil, nil, reason].
        def offered(dir, stamp, records)
          list = DistillRun.drafts(dir)
          draft = stamp ? list.find { |d| d['stamp'] == stamp } : list.first
          return [nil, nil, nil, stamp ? "no draft #{stamp}" : 'no draft yet'] unless draft

          base = File.binread(draft['path'])
          sha = Digest::SHA256.hexdigest(base)
          rec = Array(records).reverse.find { |r| r['stamp'] == draft['stamp'] && r['draft_sha256'] == sha }
          unless rec
            return [nil, nil, nil, "draft #{draft['stamp']} matches no record the distiller made " \
                                   "(sha256 #{sha}); it is not offered"]
          end

          [draft, rec, base, nil]
        rescue StandardError => e
          [nil, nil, nil, "the draft could not be read (#{e.class}: #{e.message[0, 120]})"]
        end

        LOCK_FILE = 'adopt.lock'

        # Shows, asks, writes, records. Returns { 'recorded' => bool, ... }.
        # One adoption at a time: the whole act holds an exclusive lock, so
        # two terminals cannot interleave their writes, pins and restores.
        def interactive_adopt(dir:, sessions_dir:, tty_in:, tty_out:, **opts)
          FileUtils.mkdir_p(dir)
          File.open(File.join(dir, LOCK_FILE), 'a') do |lock|
            unless lock.flock(File::LOCK_EX | File::LOCK_NB)
              tty_out.puts 'Refused: another adoption is in progress.'
              return { 'recorded' => false, 'reason' => 'busy', 'detail' => 'another adoption is in progress' }
            end

            adopt_locked(dir: dir, sessions_dir: sessions_dir, tty_in: tty_in, tty_out: tty_out, **opts)
          end
        end

        # [table, nil] or [nil, [reason, detail]]: the table an adoption may
        # pin into. In force; or out of line only because the precedents
        # entry differs from its last pin (an interrupted adoption, a hand
        # edit), which only an adoption may put right.
        def adoptable_table(rulings)
          dl = Delegation
          table = dl.load_effective(rulings: rulings)
          unless table['status'] == 'in_force' || table['status'] == 'reads_changed'
            return [nil, ['table_not_in_force',
                          "the delegation table is #{table['status']}; adoption never brings it into force. " \
                          'Rule it first: ruby .kairos/skillsets/agent/bin/agent_rule.rb activate --table delegation']]
          end
          return [table, nil] if table['status'] == 'in_force'

          raw = File.binread(dl::BASE_PATH)
          # The bytes read here must be the bytes the ruling covers; a write
          # since load_effective verified them is a table nobody ruled on.
          unless Digest::SHA256.hexdigest(raw) == table['sha256']
            return [nil, ['table_changed', 'the delegation table file changed while adoption read it; run adopt again']]
          end
          parsed, error = dl.parse_table(raw)
          pins, error = dl.read_pins(parsed['judge_reads']) unless error
          latest = latest_ruling(rulings)
          changed = error ? nil : dl.changed_reads(pins, latest['reads'])
          unless changed == ['judgment_precedents']
            return [nil, ['table_not_in_force',
                          "the delegation table is reads_changed (#{table['detail']}); rule it again first: " \
                          'ruby .kairos/skillsets/agent/bin/agent_rule.rb activate --table delegation']]
          end

          [parsed.merge('status' => 'precedents_out_of_line', 'sha256' => Digest::SHA256.hexdigest(raw),
                        'reads' => pins), nil]
        end

        def latest_ruling(rulings)
          table_rulings(rulings).last
        end

        def table_rulings(rulings)
          Array(rulings).select { |r| r['table'] == Delegation::TABLE_ID && r['attested'] == true }
        end

        def adopt_locked(dir:, sessions_dir:, tty_in:, tty_out:, stamp: nil, chain: nil, rulings: nil,
                         records: nil, nonce_value: ActClassification.nonce)
          dl = Delegation
          refuse = lambda do |reason, detail|
            tty_out.puts "Refused: #{detail}."
            { 'recorded' => false, 'reason' => reason, 'detail' => detail }
          end
          given_rulings = rulings
          rulings, rulings_error = ActClassification.chain_rulings if rulings.nil?
          return refuse.call('chain_unreadable', "the chain could not be read (#{rulings_error})") if rulings_error

          table, why_not = adoptable_table(rulings)
          return refuse.call(*why_not) unless table
          unless table['judge_reads'].include?('judgment_precedents')
            return refuse.call('not_read', 'the delegation table in force does not give the judge judgment_precedents to read')
          end
          ruled = latest_ruling(rulings)
          ruled_count = table_rulings(rulings).size

          busy = sessions_mid_run(sessions_dir)
          unless busy.empty?
            return refuse.call('session_mid_run', "#{busy.size} session(s) are mid-run (#{busy.first(3).join(', ')}); " \
                                                  'adopt between runs')
          end

          if records.nil?
            records, records_error = draft_records
            return refuse.call('chain_unreadable', "the chain could not be read (#{records_error})") if records_error
          end
          draft, rec, base, why = offered(dir, stamp, records)
          return refuse.call('no_draft', why) unless draft

          adopted = begin
            File.binread(draft['edit_path'])
          rescue StandardError => e
            return refuse.call('no_edit_copy', "#{draft['edit_path']} cannot be read (#{e.class})")
          end
          path = dl.precedents_path
          current = File.exist?(path) ? File.binread(path) : nil
          # Out of line, the bytes at the path may be the very ones an
          # interrupted adoption left there; pinning them is the way back.
          if current == adopted && table['status'] == 'in_force'
            return refuse.call('unchanged', 'the edited copy is the entry already in force; nothing to adopt')
          end

          changes = Distiller.line_diff(text(base), text(adopted))
          edited = adopted != base
          tty_out.puts "Draft:  #{draft['stamp']} (chain block ##{rec['block']}, #{rec['inputs']} answers, " \
                       "model #{rec['observed_model']})"
          tty_out.puts "Adopt:  #{draft['edit_path']}"
          tty_out.puts "Into:   #{path}"
          if table['status'] == 'precedents_out_of_line'
            tty_out.puts 'Note:   the entry at that path is not the one last pinned (an interrupted adoption or a ' \
                         'hand edit); the judge is stopped until this adoption or a restore.'
          end
          tty_out.puts
          tty_out.puts 'Your changes to the draft:'
          show(tty_out, changes, edited ? '(bytes differ, but no line differs: line endings or invalid bytes)' :
                                          '(none: adopting the draft as the distiller wrote it)')
          tty_out.puts
          tty_out.puts(if current then 'What the judge will read, against the entry at that path now:'
                       elsif table['status'] == 'in_force' then 'What the judge will read (nothing is in force yet):'
                       else 'What the judge will read (the pinned entry is missing from that path):'
                       end)
          show(tty_out, Distiller.line_diff(text(current.to_s), text(adopted)), '(no difference)')
          tty_out.puts
          tty_out.puts 'The judge reads this from its next point on, beside the instruction mode and your latest ' \
                       'answers. The agent can read it too (it is an L1 entry).'
          tty_out.print "Type #{nonce_value} to adopt and record this ruling (anything else cancels): "
          tty_out.flush
          unless tty_in.gets.to_s.strip == nonce_value
            tty_out.puts 'Cancelled. Nothing was written or recorded.'
            return { 'recorded' => false, 'reason' => 'nonce_mismatch' }
          end

          # What was shown must still hold now that it is confirmed: the table
          # ruled as it was, and no session started a run meanwhile.
          if given_rulings.nil?
            now_rulings, now_error = ActClassification.chain_rulings
            return refuse.call('chain_unreadable', "the chain could not be read (#{now_error})") if now_error
            # Any new ruling counts, even one identical to the last (a re-ruling
            # within the same second carries the same bytes).
            unless table_rulings(now_rulings).size == ruled_count && latest_ruling(now_rulings) == ruled
              return refuse.call('table_changed', 'the delegation table was ruled while you confirmed; run adopt again')
            end
          end
          busy = sessions_mid_run(sessions_dir)
          unless busy.empty?
            return refuse.call('session_mid_run', "a session started a run while you confirmed (#{busy.first}); " \
                                                  'adopt between runs')
          end

          adopted_sha = Digest::SHA256.hexdigest(adopted)
          block = nil
          record = nil
          begin
            write_entry(path, adopted)
            pins, error = dl.read_pins(table['judge_reads'])
            raise "a read could not be resolved (#{error})" if error

            pinned = pins.find { |p| p['name'] == 'judgment_precedents' }
            raise 'the entry on disk is not the bytes adopted' unless pinned && pinned['sha256'] == adopted_sha

            moved = dl.changed_reads(pins, ruled['reads']) - ['judgment_precedents']
            raise "#{moved.join(', ')} changed while adopting" unless moved.empty?

            record = { 'kind' => ActClassification::RULING_KIND, 'table' => dl::TABLE_ID, 'action' => 'activate',
                       'sha256' => table['sha256'], 'attested' => true, 'attestation' => 'terminal_nonce',
                       'ruled_at' => Time.now.utc.iso8601, 'reads' => pins.map { |p| dl.pin_record(p) },
                       'adoption' => { 'stamp' => draft['stamp'], 'draft_block' => rec['block'],
                                       'draft_sha256' => rec['draft_sha256'], 'adopted_sha256' => adopted_sha,
                                       'edited' => edited } }
            chain ||= begin
              require 'kairos_mcp/kairos_chain/chain'
              ::KairosMcp::KairosChain::Chain.new
            end
            # Interrupts wait until the block is known: once it is written,
            # the rescue below must not put the old bytes back under it.
            Thread.handle_interrupt(Object => :never) { block = chain.add_block([JSON.generate(record)]) }
          rescue Exception => e # rubocop:disable Lint/RescueException -- an interrupt must not leave unpinned bytes
            if block
              tty_out.puts "Adopted and recorded as block ##{block.index}, then interrupted before your changes were saved."
              raise
            end
            back = restore(path, current)
            unless e.is_a?(StandardError)
              tty_out.puts "Interrupted; nothing was recorded. " +
                           (back ? 'The entry that was there before was put back.' : "#{path} could NOT be put back.")
              raise
            end

            tty_out.puts "Not recorded (#{e.class}: #{e.message[0, 160]}); " +
                         (back ? 'the entry that was there before was put back.' :
                                 "the entry could NOT be put back; #{path} now differs from its pin and the judge is " \
                                 'stopped until you adopt again or restore it.')
            return { 'recorded' => false, 'reason' => 'record_failed', 'detail' => e.message[0, 160], 'restored' => back }
          end

          saved = save_changes(dir, block.index, draft, rec, changes)
          tty_out.puts "Adopted and recorded as block ##{block.index}."
          if saved
            tty_out.puts "Your changes were kept for the next draft (#{saved})."
          elsif !changes.empty?
            tty_out.puts "WARNING: your changes could not be saved under #{File.join(dir, 'adoptions')}; the next " \
                         'draft will not see them. The adoption itself stands.'
          end
          { 'recorded' => true, 'block_index' => block.index, 'record' => record }
        end

        def text(bytes)
          bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?')
        end

        def show(out, diff, empty)
          return out.puts("  #{empty}") if diff.empty?

          diff.each_line { |l| out.puts "  #{AnswerRuling.printable(l.chomp)}" }
        end

        # tmp + rename in the entry's directory.
        def write_entry(path, bytes)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.tmp.#{Process.pid}"
          File.binwrite(tmp, bytes)
          File.rename(tmp, path)
        ensure
          File.unlink(tmp) if tmp && File.exist?(tmp)
        end

        # true when the bytes that were at path (or nothing) are back.
        def restore(path, previous)
          previous.nil? ? FileUtils.rm_f(path) : write_entry(path, previous)
          previous.nil? ? !File.exist?(path) : File.binread(path) == previous
        rescue StandardError
          false
        end

        # The operator's changes, which the next draft reads (INV-K1). The
        # adoption stands without them; a failure is said by the caller.
        def save_changes(dir, block_index, draft, rec, changes)
          d = File.join(dir, 'adoptions')
          FileUtils.mkdir_p(d)
          path = File.join(d, "#{block_index}.json")
          write_entry(path, JSON.pretty_generate({ 'adopted_block' => block_index, 'stamp' => draft['stamp'],
                                                   'draft_block' => rec['block'], 'changes' => changes }))
          path
        rescue StandardError
          nil
        end
      end
    end
  end
end
