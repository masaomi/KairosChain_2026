# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative '../lib/model_provenance'

class TestObservationStore < Minitest::Test
  S = KairosMcp::SkillSets::ModelProvenance::ObservationStore

  def test_append_never_overwrites_and_leaves_no_temporary_file
    Dir.mktmpdir do |dir|
      a = S.append(dir, 'sess1', 'observation', 'agent_x', 'schema' => S::SCHEMA, 'run' => 1)
      b = S.append(dir, 'sess1', 'observation', 'agent_x', 'schema' => S::SCHEMA, 'run' => 1)
      refute_equal a, b
      files = Dir.children(File.join(dir, 'model_provenance', 'sess1'))
      assert_equal 2, files.size
      assert(files.none? { |f| f.end_with?('.tmp') })
    end
  end

  def test_binding_resolves_to_the_newest_record_of_the_latest_run
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_ab12', 'schema' => S::SCHEMA, 'run' => 2, 'models' => { 'm' => 1 }, 'tag' => 'r2-old')
      S.append(dir, 'sess1', 'observation', 'agent_ab12', 'schema' => S::SCHEMA, 'run' => 1, 'tag' => 'r1-late')
      S.append(dir, 'sess2', 'observation', 'agent_ab12', 'schema' => S::SCHEMA, 'run' => 2, 'tag' => 'r2-new')
      got = S.resolve_binding(dir, 'ab12')
      assert_equal 'r2-new', got['tag']
      assert_equal 'observed', got['state']
      assert got['record']
    end
  end

  def test_no_record_and_malformed_bindings_are_unobserved_with_the_cause_collect_saw
    Dir.mktmpdir do |dir|
      assert_equal S::NO_RECORD, S.resolve_binding(dir, 'nothere')['cause']
      bad = S.resolve_binding(dir, '../../etc')
      assert_equal 'unobserved', bad['state']
      assert_equal 'binding malformed', bad['cause']
    end
  end

  def test_an_unreadable_record_surfaces_as_a_cause_not_silence
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_cd34', 'schema' => S::SCHEMA, 'run' => 1)
      path = Dir.glob(File.join(dir, 'model_provenance', 'sess1', '*.json')).first
      File.write(path, '{torn')
      got = S.resolve_binding(dir, 'cd34')
      assert_equal 'unobserved', got['state']
      assert_match(/record unreadable at collect/, got['cause'])
    end
  end

  # C4: when the newest record cannot be read, an older readable one is not
  # the answer.
  def test_an_unreadable_newest_record_is_unobserved_not_a_fallback_to_an_older_run
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_ef56', 'schema' => S::SCHEMA, 'run' => 1, 'models' => { 'm' => 3 })
      sleep 0.001
      S.append(dir, 'sess1', 'observation', 'agent_ef56', 'schema' => S::SCHEMA, 'run' => 2, 'models' => { 'm' => 1 })
      newest = Dir.glob(File.join(dir, 'model_provenance', 'sess1', '*.json')).max
      File.write(newest, '{"state":"obs')
      got = S.resolve_binding(dir, 'ef56')
      assert_equal 'unobserved', got['state']
      assert_match(/newest record unreadable/, got['cause'])
    end
  end

  def test_an_older_unreadable_record_is_counted_beside_the_answer
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_gh78', 'schema' => S::SCHEMA, 'run' => 1)
      sleep 0.001
      S.append(dir, 'sess1', 'observation', 'agent_gh78', 'schema' => S::SCHEMA, 'run' => 2, 'tag' => 'latest')
      oldest = Dir.glob(File.join(dir, 'model_provenance', 'sess1', '*.json')).min
      File.write(oldest, '{torn')
      got = S.resolve_binding(dir, 'gh78')
      assert_equal 'latest', got['tag']
      assert_equal 1, got['unreadable_records']
    end
  end

  def test_an_id_that_merely_begins_with_another_is_not_matched
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_ab-cd', 'schema' => S::SCHEMA, 'run' => 1)
      assert_equal S::NO_RECORD, S.resolve_binding(dir, 'ab')['cause']
    end
  end

  def test_a_complete_record_outranks_a_newer_incomplete_one_in_the_same_run
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_kk11', 'schema' => S::SCHEMA, 'run' => 1, 'complete' => true, 'tag' => 'backstop')
      sleep 0.001
      S.append(dir, 'sess1', 'observation', 'agent_kk11', 'schema' => S::SCHEMA, 'run' => 1, 'complete' => false, 'tag' => 'late')
      assert_equal 'backstop', S.resolve_binding(dir, 'kk11')['tag']
    end
  end

  def test_a_newest_unobserved_record_is_the_answer
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_ll22', 'schema' => S::SCHEMA, 'run' => 1, 'state' => 'observed', 'complete' => true)
      sleep 0.001
      S.append(dir, 'sess1', 'observation', 'agent_ll22', 'schema' => S::SCHEMA, 'state' => 'unobserved', 'cause' => 'absent')
      got = S.resolve_binding(dir, 'll22')
      assert_equal %w[unobserved absent], [got['state'], got['cause']]
    end
  end

  def test_records_from_earlier_reading_rules_are_never_resolved
    Dir.mktmpdir do |dir|
      S.append(dir, 'sess1', 'observation', 'agent_pp44', 'run' => 2, 'complete' => true, 'tag' => 'old rules')
      assert_equal S::NO_RECORD, S.resolve_binding(dir, 'pp44')['cause']
      S.append(dir, 'sess1', 'observation', 'agent_pp44', 'schema' => S::SCHEMA, 'run' => 1, 'complete' => true, 'tag' => 'current')
      assert_equal 'current', S.resolve_binding(dir, 'pp44')['tag']
    end
  end

  def test_unsafe_session_ids_are_refused
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) { S.append(dir, '../x', 'live', 'session', {}) }
    end
  end

  # INV-2: the KairosChain-layer entry point must not reach the transcript reader.
  def test_lib_does_not_load_the_transcript_reader
    lib = File.expand_path('../lib', __dir__)
    Dir.glob(File.join(lib, '**', '*.rb')).each do |f|
      refute_match(/transcript_reader/, File.read(f).lines.reject { |l| l.strip.start_with?('#') }.join, f)
    end
    # In a fresh process, so other test files loaded alongside cannot mask it.
    out = IO.popen([RbConfig.ruby, '-e', "require #{File.join(lib, 'model_provenance.rb').inspect}; " \
                                        'print defined?(ModelProvenanceHook).inspect'], &:read)
    assert_equal 'nil', out, 'loading lib/ defined the hook-side reader'
  end
end
