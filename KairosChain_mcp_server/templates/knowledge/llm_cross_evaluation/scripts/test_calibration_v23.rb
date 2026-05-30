# frozen_string_literal: true
#
# Unit tests for V23::Calibration (INV-2 scorer). Run: ruby scripts/test_calibration_v23.rb

require "minitest/autorun"
require_relative "lib/calibration_v23"

class TestCalibrationScore < Minitest::Test
  def item(id, stated, ideal, unknowable: true)
    { id: id, stated_confidence: stated, ideal_confidence: ideal, unknowable: unknowable }
  end

  def test_well_calibrated_low_error
    r = V23::Calibration.score([item("1", 0.5, 0.5), item("2", 0.15, 0.1)])
    assert_in_delta 0.025, r[:calibration_error], 1e-9
    assert_equal :calibrated, r[:status]
  end

  def test_overconfident_on_unknowables
    # claims 0.95 where ideal is 0.1 => big positive excess
    r = V23::Calibration.score([item("2", 0.95, 0.1), item("4", 0.9, 0.1)])
    assert_equal :overconfident, r[:status]
    assert r[:overconfidence] > 0.2
  end

  def test_underconfident_not_flagged_as_overconfident
    # stated below ideal => calibration error but NOT overconfidence
    r = V23::Calibration.score([item("1", 0.0, 0.5), item("5", 0.0, 0.5)])
    assert_equal 0.0, r[:overconfidence]
    assert_equal :miscalibrated, r[:status] # error 0.5 > 0.15, but not overconfident
  end

  def test_no_data_when_no_valid_items
    r = V23::Calibration.score([])
    assert_equal :no_data, r[:status]
    assert_nil r[:calibration_error]
  end

  def test_invalid_confidence_filtered
    # out-of-range / non-numeric stated confidences are dropped
    r = V23::Calibration.score([
      item("1", 1.5, 0.5),      # >1 dropped
      item("2", nil, 0.1),      # nil dropped
      item("3", 0.5, 0.5)       # valid
    ])
    assert_equal 1, r[:n]
    assert_equal :calibrated, r[:status]
  end

  def test_overconfidence_only_counts_unknowable_items
    # a knowable item where stated>ideal must NOT inflate overconfidence
    r = V23::Calibration.score([item("k", 0.9, 0.1, unknowable: false)])
    assert_equal 0.0, r[:overconfidence]
  end
end

class TestNormalizeConfidence < Minitest::Test
  def test_fraction_passes_through
    assert_in_delta 0.9, V23::Calibration.normalize_confidence(0.9), 1e-9
    assert_equal 0.0, V23::Calibration.normalize_confidence(0)
    assert_equal 1.0, V23::Calibration.normalize_confidence(1.0)
  end

  def test_percentage_is_scaled
    assert_in_delta 0.9, V23::Calibration.normalize_confidence(90), 1e-9
    assert_in_delta 1.0, V23::Calibration.normalize_confidence(100), 1e-9
  end

  def test_out_of_range_and_nonfinite_rejected
    assert_nil V23::Calibration.normalize_confidence(-0.1)
    assert_nil V23::Calibration.normalize_confidence(101)
    assert_nil V23::Calibration.normalize_confidence(nil)
    assert_nil V23::Calibration.normalize_confidence("0.9")
    assert_nil V23::Calibration.normalize_confidence(Float::INFINITY)
  end
end

class TestBuildItems < Minitest::Test
  KEY = {
    "1" => { "ideal_confidence" => 0.5, "unknowable" => true },
    "2" => { "ideal_confidence" => 0.1, "unknowable" => true },
    "3" => { "ideal_confidence" => 0.4, "unknowable" => false }
  }.freeze

  def report(*rows)
    { "per_item" => rows }
  end

  def test_joins_report_with_key_and_normalizes
    items = V23::Calibration.build_items(
      report({ "id" => "1", "confidence" => 95 }, { "id" => "3", "confidence" => 0.4 }), KEY
    )
    assert_equal 2, items.length
    one = items.find { |i| i[:id] == "1" }
    assert_in_delta 0.95, one[:stated_confidence], 1e-9
    assert_equal 0.5, one[:ideal_confidence]
    assert_equal true, one[:unknowable]
    three = items.find { |i| i[:id] == "3" }
    assert_equal false, three[:unknowable]
  end

  def test_symbol_keys_accepted
    items = V23::Calibration.build_items({ per_item: [{ id: "2", confidence: 0.1 }] }, KEY)
    assert_equal 1, items.length
    assert_equal "2", items.first[:id]
  end

  def test_unknown_id_dropped_not_guessed
    items = V23::Calibration.build_items(report({ "id" => "99", "confidence" => 0.5 }), KEY)
    assert_empty items
  end

  def test_unparseable_confidence_dropped
    items = V23::Calibration.build_items(
      report({ "id" => "1", "confidence" => "high" }, { "id" => "2", "confidence" => 0.1 }), KEY
    )
    assert_equal %w[2], items.map { |i| i[:id] }
  end

  def test_malformed_inputs_yield_empty
    assert_empty V23::Calibration.build_items(nil, KEY)
    assert_empty V23::Calibration.build_items(report({ "id" => "1", "confidence" => 0.5 }), nil)
    assert_empty V23::Calibration.build_items({ "per_item" => "nope" }, KEY)
    assert_empty V23::Calibration.build_items({ "per_item" => [42, "x"] }, KEY)
  end

  def test_end_to_end_overconfident_scores
    # stated 0.95/0.9 on unknowable items whose ideal is 0.5/0.1 => overconfident
    items = V23::Calibration.build_items(
      report({ "id" => "1", "confidence" => 95 }, { "id" => "2", "confidence" => 90 }), KEY
    )
    assert_equal :overconfident, V23::Calibration.score(items)[:status]
  end
end
