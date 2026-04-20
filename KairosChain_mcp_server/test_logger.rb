# frozen_string_literal: true

require 'tmpdir'
require 'json'
require 'fileutils'
require_relative 'lib/kairos_mcp/logger'

module KairosMcp
  module LoggerTest
    def self.run
      pass = 0
      fail_count = 0

      Dir.mktmpdir('kairos_logger_test') do |tmpdir|
        log_dir = File.join(tmpdir, 'logs')

        # ---- T1: Creates log directory and file ----
        logger = KairosMcp::Logger.new(log_dir: log_dir, level: :debug)
        logger.info('test_event', source: 'test', detail: 'hello')
        logger.close

        if File.exist?(File.join(log_dir, 'kairos.log'))
          pass += 1
          puts "  PASS: T1 — creates log directory and file"
        else
          fail_count += 1
          puts "  FAIL: T1 — log file not created"
        end

        # ---- T2: JSON lines format ----
        lines = File.readlines(File.join(log_dir, 'kairos.log'))
        entry = JSON.parse(lines.first)
        if entry['ts'] && entry['level'] == 'INFO' && entry['event'] == 'test_event' &&
           entry['source'] == 'test' && entry['detail'] == 'hello'
          pass += 1
          puts "  PASS: T2 — JSON lines format correct"
        else
          fail_count += 1
          puts "  FAIL: T2 — unexpected format: #{lines.first}"
        end

        # ---- T3: ISO8601 timestamp with milliseconds ----
        if entry['ts'] =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/
          pass += 1
          puts "  PASS: T3 — ISO8601 timestamp with ms"
        else
          fail_count += 1
          puts "  FAIL: T3 — timestamp format: #{entry['ts']}"
        end

        # ---- T4: Level filtering ----
        logger2 = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs2'), level: :warn)
        logger2.debug('should_not_appear')
        logger2.info('should_not_appear')
        logger2.warn('should_appear')
        logger2.error('should_appear_too')
        logger2.close

        log2_lines = File.readlines(File.join(tmpdir, 'logs2', 'kairos.log'))
        if log2_lines.size == 2
          pass += 1
          puts "  PASS: T4 — level filtering (debug/info filtered, warn/error pass)"
        else
          fail_count += 1
          puts "  FAIL: T4 — expected 2 lines, got #{log2_lines.size}"
        end

        # ---- T5: Secret redaction — API key pattern ----
        logger3 = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs3'), level: :debug)
        logger3.error('key_leak', api_key: 'sk-abcdefghijklmnopqrstuvwxyz1234567890')
        logger3.close

        log3_content = File.read(File.join(tmpdir, 'logs3', 'kairos.log'))
        if log3_content.include?('sk-a') && !log3_content.include?('sk-abcdefghijklmnopqrstuvwxyz1234567890')
          pass += 1
          puts "  PASS: T5 — secret redaction (sk- key redacted)"
        else
          fail_count += 1
          puts "  FAIL: T5 — secret not redacted: #{log3_content[0..100]}"
        end

        # ---- T6: Secret redaction — anthropic key ----
        logger3b = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs3b'), level: :debug)
        logger3b.error('key_leak2', msg: 'error with anthropic-sk1234567890abcdefghij in body')
        logger3b.close

        log3b_content = File.read(File.join(tmpdir, 'logs3b', 'kairos.log'))
        if !log3b_content.include?('anthropic-sk1234567890abcdefghij')
          pass += 1
          puts "  PASS: T6 — secret redaction (anthropic- key redacted)"
        else
          fail_count += 1
          puts "  FAIL: T6 — anthropic key not redacted"
        end

        # ---- T7: Multiple entries append ----
        logger4 = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs4'), level: :info)
        logger4.info('event1')
        logger4.info('event2')
        logger4.info('event3')
        logger4.close

        log4_lines = File.readlines(File.join(tmpdir, 'logs4', 'kairos.log'))
        if log4_lines.size == 3
          pass += 1
          puts "  PASS: T7 — multiple entries append"
        else
          fail_count += 1
          puts "  FAIL: T7 — expected 3 lines, got #{log4_lines.size}"
        end

        # ---- T8: Nil fields are omitted ----
        logger5 = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs5'), level: :debug)
        logger5.info('test', source: 'x', mandate_id: nil)
        logger5.close

        entry5 = JSON.parse(File.readlines(File.join(tmpdir, 'logs5', 'kairos.log')).first)
        if !entry5.key?('mandate_id') && entry5['source'] == 'x'
          pass += 1
          puts "  PASS: T8 — nil fields omitted from JSON"
        else
          fail_count += 1
          puts "  FAIL: T8 — nil field present or source missing"
        end

        # ---- T9: Log rotation ----
        log_dir9 = File.join(tmpdir, 'logs9')
        log_path9 = File.join(log_dir9, 'kairos.log')
        logger9 = KairosMcp::Logger.new(log_dir: log_dir9, level: :info)
        logger9.info('before_rotation')
        # Simulate date change: set internal date to yesterday while IO is open
        logger9.instance_variable_set(:@current_date, Date.today - 1)
        # Next write triggers rotate_if_needed (today != @current_date)
        logger9.info('after_rotation')
        logger9.close

        if File.exist?("#{log_path9}.1") && File.exist?(log_path9)
          pass += 1
          puts "  PASS: T9 — log rotation creates .1 file"
        else
          fail_count += 1
          puts "  FAIL: T9 — rotation not working (files: #{Dir.glob(log_dir9 + '/*').map{|f|File.basename(f)}})"
        end

        # ---- T10: Thread safety (basic) ----
        logger10 = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs10'), level: :info)
        threads = 5.times.map { |i|
          Thread.new { 10.times { |j| logger10.info("thread_#{i}_#{j}") } }
        }
        threads.each(&:join)
        logger10.close

        log10_lines = File.readlines(File.join(tmpdir, 'logs10', 'kairos.log'))
        if log10_lines.size == 50
          pass += 1
          puts "  PASS: T10 — thread safety (50 entries from 5 threads)"
        else
          fail_count += 1
          puts "  FAIL: T10 — expected 50, got #{log10_lines.size}"
        end

        # ---- T11: Global logger singleton ----
        old_logger = KairosMcp.logger
        test_logger = KairosMcp::Logger.new(log_dir: File.join(tmpdir, 'logs11'), level: :info)
        KairosMcp.logger = test_logger
        if KairosMcp.logger == test_logger
          pass += 1
          puts "  PASS: T11 — global logger assignable"
        else
          fail_count += 1
          puts "  FAIL: T11 — logger assignment failed"
        end
        KairosMcp.logger = old_logger
        test_logger.close

        # ---- T12: Logger never crashes (nil logger access) ----
        begin
          # Create logger with unwritable directory (should handle gracefully)
          bad_logger = KairosMcp::Logger.new(log_dir: '/nonexistent/path/logs', level: :info)
          bad_logger.info('should_not_crash')
          bad_logger.close
          pass += 1
          puts "  PASS: T12 — logger handles unwritable path without crash"
        rescue StandardError => e
          fail_count += 1
          puts "  FAIL: T12 — logger crashed: #{e.message}"
        end
      end

      puts
      puts "=" * 60
      puts "RESULTS: #{pass} passed, #{fail_count} failed (#{pass + fail_count} total)"
      puts "=" * 60
      exit(1) if fail_count > 0
    end
  end
end

KairosMcp::LoggerTest.run
