# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'

# Stub out BaseTool so the tool file loads in isolation (same stub as
# test_multi_llm_review.rb).
module KairosMcp
  module Tools
    class BaseTool
      def text_content(s); [{ text: s }]; end
    end
  end unless defined?(KairosMcp::Tools::BaseTool)
end

require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../lib/multi_llm_review/provenance_binding'
require_relative '../tools/multi_llm_review_collect'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # model_provenance design v0.3 INV-7: a persona seat bound to its
      # subagents records the observed model; without bindings, nothing changes.
      class TestProvenanceBinding < Minitest::Test
        O55 = 'claude-opus-5-5'
        O5 = 'claude-opus-5'

        # Duck-typed stand-in for model_provenance's ObservationStore.
        class FakeReader
          def initialize(map)
            @map = map
          end

          def resolve_binding(_data_dir, id)
            v = @map.fetch(id) { return { 'state' => 'unobserved', 'cause' => 'no record for this binding at collect' } }
            raise v if v.is_a?(Class)

            v
          end
        end

        def reviews(*ids)
          ids.each_with_index.map do |id, i|
            r = { 'persona' => "p#{i}", 'verdict' => 'APPROVE', 'reasoning' => 'fine', 'findings' => [] }
            r['agent_id'] = id if id
            r
          end
        end

        def observed(models, complete: true)
          { 'state' => 'observed', 'models' => models, 'complete' => complete, 'run' => 1, 'record' => 'r.json' }
        end

        def seat(revs, reader)
          PersonaAssembly.assemble(revs, O55, observations: ProvenanceBinding.resolve(revs, data_dir: '/x', reader: reader))
        end

        def test_without_bindings_the_entry_is_exactly_as_before
          revs = reviews(nil, nil)
          before = PersonaAssembly.assemble(revs, O55)
          after = PersonaAssembly.assemble(revs, O55, observations: ProvenanceBinding.resolve(revs, data_dir: '/x',
                                                                                                  reader: FakeReader.new({})))
          assert_nil ProvenanceBinding.resolve(revs, data_dir: '/x', reader: FakeReader.new({}))
          assert_equal before, after
          assert_equal 'declared', after[:model_source]
          refute after.key?(:binding)
        end

        def test_all_personas_observed_on_the_declared_model_is_an_observed_matching_seat
          e = seat(reviews('a1', 'a2'), FakeReader.new('a1' => observed({ O55 => 3 }), 'a2' => observed({ O55 => 2 })))
          assert_equal 'observed', e[:model_source]
          assert_equal false, e[:model_divergence]
          assert_equal O55, e[:model_observed]
          assert_equal 'caller_declared', e[:binding]
          assert_equal true, e[:synthetic]
          assert_equal %w[matching matching], e[:persona_rows].map { |r| r['model_observation']['persona_state'] }
        end

        # A persona that ran wholly on another model is divergent though no
        # fallback marker was involved (R1-01).
        def test_a_persona_run_wholly_on_another_model_is_divergent
          e = seat(reviews('a1', 'a2'), FakeReader.new('a1' => observed({ O5 => 4 }), 'a2' => observed({ O55 => 2 })))
          assert_equal true, e[:model_divergence]
          assert_equal 'observed', e[:model_source]
          assert_equal [O5], e[:persona_rows][0]['model_observation']['divergent_models']
        end

        def test_divergence_outranks_unobserved_and_the_seat_stays_declared
          e = seat(reviews('a1', 'zz'), FakeReader.new('a1' => observed({ O55 => 1, O5 => 5 })))
          assert_equal true, e[:model_divergence]
          assert_equal 'declared', e[:model_source]
          assert_equal 'unobserved', e[:persona_rows][1]['model_observation']['persona_state']
        end

        # G1: an incomplete read that saw no divergence is not "matching".
        def test_an_incomplete_read_with_no_divergence_is_unobserved
          e = seat(reviews('a1'), FakeReader.new('a1' => observed({ O55 => 2 }, complete: false)))
          assert_nil e[:model_divergence]
          assert_equal 'declared', e[:model_source]
          assert_match(/incomplete/, e[:persona_rows][0]['model_observation']['cause'])
        end

        def test_an_incomplete_read_that_saw_divergence_stays_divergent
          e = seat(reviews('a1'), FakeReader.new('a1' => observed({ O55 => 1, O5 => 1 }, complete: false)))
          assert_equal true, e[:model_divergence]
          # INV-7: observed only when every persona's observation is complete.
          assert_equal 'declared', e[:model_source]
        end

        def test_a_partly_bound_seat_marks_the_unbound_persona_unobserved
          e = seat(reviews('a1', nil), FakeReader.new('a1' => observed({ O55 => 1 })))
          assert_nil e[:model_divergence]
          assert_equal 'no binding supplied for this persona', e[:persona_rows][1]['model_observation']['cause']
        end

        def test_nothing_can_refuse_the_submission
          revs = reviews('a1', 'bad id!', 'a3')
          obs = ProvenanceBinding.resolve(revs, data_dir: '/x', reader: FakeReader.new('a1' => RuntimeError))
          assert_equal ['binding resolution failed at collect (RuntimeError)', 'binding malformed',
                        'no record for this binding at collect'], obs.map { |o| o['cause'] }
          obs = ProvenanceBinding.resolve(reviews('a1'), data_dir: '/x', reader: nil)
          assert_equal 'observation reader not loaded at collect', obs.first['cause']
        end

        # Seam with the real observation store, when model_provenance is a
        # sibling SkillSet (gem templates, or an instance that installed it).
        def test_seam_with_the_real_observation_store_when_installed
          path = File.expand_path('../../model_provenance/lib/model_provenance.rb', __dir__)
          skip 'model_provenance not installed beside this SkillSet' unless File.file?(path)

          require path
          store = KairosMcp::SkillSets::ModelProvenance::ObservationStore
          Dir.mktmpdir do |dir|
            store.append(dir, 'sess', 'observation', 'agent_real1',
                         'schema' => store::SCHEMA, 'state' => 'observed', 'run' => 1,
                         'models' => { O5 => 3 }, 'complete' => true)
            e = PersonaAssembly.assemble(reviews('real1'), O55,
                                         observations: ProvenanceBinding.resolve(reviews('real1'), data_dir: dir,
                                                                                                  reader: store))
            assert_equal true, e[:model_divergence]
            assert_match(/\Aobservation-agent_real1-/, e[:persona_rows][0]['model_observation']['record'])
          end
        end
      end

      # Through the collect tool, as an orchestrator calls it.
      class TestCollectWithBindings < Minitest::Test
        O55 = 'claude-opus-5-5'
        O5 = 'claude-opus-5'

        def setup
          @tmp = Dir.mktmpdir('mlr-binding-')
          @orig_cwd = Dir.pwd
          Dir.chdir(@tmp)
          @collect = Tools::MultiLlmReviewCollect.new
          @orig_reader = ProvenanceBinding.method(:default_reader)
          reader = TestProvenanceBinding::FakeReader.new(
            'agentA' => { 'state' => 'observed', 'models' => { O5 => 4 }, 'complete' => true, 'run' => 1 }
          )
          ProvenanceBinding.define_singleton_method(:default_reader) { reader }
        end

        def teardown
          orig = @orig_reader
          ProvenanceBinding.define_singleton_method(:default_reader) { orig.call }
          Dir.chdir(@orig_cwd)
          FileUtils.rm_rf(@tmp)
        end

        def write_state(token)
          PendingState.write(token, {
            'token' => token, 'created_at' => Time.now.iso8601,
            'collect_deadline' => (Time.now + 600).iso8601, 'review_type' => 'design',
            'artifact_name' => 'test', 'review_round' => 1, 'complexity' => 'high',
            'orchestrator_model' => O55, 'convergence_rule' => '3/4 APPROVE', 'min_quorum' => 2,
            'collected' => false,
            'subprocess_results' => [
              { 'role_label' => 'codex', 'provider' => 'codex', 'model' => 'codex-default',
                'raw_text' => "**Overall Verdict**: APPROVE\n\n" + ('Walked the path; nothing to raise. ' * 4),
                'elapsed_seconds' => 1, 'error' => nil, 'status' => 'success' }
            ]
          })
        end

        def personas(bound)
          [{ 'persona' => 'architect', 'verdict' => 'APPROVE', 'reasoning' => 'fine', 'findings' => [] }
             .merge(bound ? { 'agent_id' => 'agentA' } : {})]
        end

        def collect(token, bound)
          JSON.parse(@collect.call('collect_token' => token, 'orchestrator_reviews' => personas(bound)).first[:text])
        end

        def team_row(payload)
          payload['reviews'].find { |r| r['role_label'] == "claude_team_#{O55}" }
        end

        def test_a_bound_persona_that_ran_elsewhere_marks_the_seat_divergent_in_the_record
          token = PendingState.generate_token
          write_state(token)
          payload = collect(token, true)
          assert_equal 'ok', payload['status']
          row = team_row(payload)
          assert_equal true, row['model_divergence']
          assert_equal 'caller_declared', row['binding']
          assert_equal 'divergent', row['persona_rows'][0]['model_observation']['persona_state']
          assert_equal 1, payload['vote_tally']['excluding_divergent']['successful_count']
        end

        def test_unbound_collect_is_unchanged_and_replay_says_bindings_are_read_once
          token = PendingState.generate_token
          write_state(token)
          row = team_row(collect(token, false))
          assert_equal 'declared', row['model_source']
          refute row.key?('binding')
          replay = collect(token, true)
          assert_equal true, replay['idempotent_replay']
          assert_match(/read once/, replay['bindings_not_read_on_replay'])
        end
      end
    end
  end
end
