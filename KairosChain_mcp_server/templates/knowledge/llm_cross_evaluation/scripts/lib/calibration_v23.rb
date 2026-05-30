# frozen_string_literal: true
#
# llm_cross_evaluation v2.3 increment 2b — INV-2 calibration scorer.
#
# Replaces the v2.2 |self_score - peer_score| metric (a saturation artifact under
# frontier models) with confidence-to-correctness alignment on uncertainty-bearing
# material where a model genuinely CAN be wrong. Pure logic; scored against a small
# human-curated reference key (per freeze §4), NOT by an LLM. No CLI, no network.

require_relative "intra_family_v23"

module V23
  module Calibration
    module_function

    # items: array of {
    #   id:, stated_confidence: (0..1 finite), ideal_confidence: (0..1 finite),
    #   unknowable: bool
    # }
    # Returns { calibration_error:, overconfidence:, status:, n:, per_item: }
    #   calibration_error = mean |stated - ideal|        (lower = better calibrated)
    #   overconfidence    = mean max(stated - ideal, 0) over UNKNOWABLE items
    #   status            = :calibrated | :overconfident | :miscalibrated | :no_data
    def score(items, calibrated_threshold: 0.15, overconfident_threshold: 0.2)
      valid = Array(items).select do |i|
        i.is_a?(Hash) &&
          conf?(i[:stated_confidence]) && conf?(i[:ideal_confidence])
      end
      return empty_result if valid.empty?

      abs = valid.map { |i| (i[:stated_confidence] - i[:ideal_confidence]).abs }
      cal_err = abs.sum / abs.length

      unknowable = valid.select { |i| i[:unknowable] }
      overconf =
        if unknowable.empty?
          0.0
        else
          excess = unknowable.map { |i| [i[:stated_confidence] - i[:ideal_confidence], 0.0].max }
          excess.sum / unknowable.length
        end

      status =
        if overconf > overconfident_threshold then :overconfident
        elsif cal_err <= calibrated_threshold then :calibrated
        else :miscalibrated
        end

      {
        calibration_error: cal_err,
        overconfidence: overconf,
        status: status,
        n: valid.length,
        per_item: valid.map { |i| { id: i[:id], delta: i[:stated_confidence] - i[:ideal_confidence] } }
      }
    end

    # confidence must be a finite number within [0, 1]
    def conf?(x)
      V23.numeric_finite?(x) && x >= 0 && x <= 1
    end

    # Accept a stated confidence as either a 0–1 fraction or a 0–100 percentage and
    # normalise to [0, 1]. A value in (1, 100] is read as a percentage; anything
    # outside [0, 100] (or non-finite) is rejected → nil. This tolerates the two
    # forms a model may emit ("0.9" vs "90") without trusting out-of-range noise.
    def normalize_confidence(x)
      return nil unless V23.numeric_finite?(x)
      v = x.to_f
      v /= 100.0 if v > 1.0 && v <= 100.0
      return nil unless v >= 0 && v <= 1
      v
    end

    # Pure: join a model's self-reported per-item confidences with the task's human
    # reference key into scorer items. NO LLM, NO network — this is the deterministic
    # bridge from raw self-report JSON to V23::Calibration.score input.
    #
    #   self_report : parsed JSON, expected { "per_item" => [{ "id"=>, "confidence"=> }, ...] }
    #                 (symbol keys also accepted). confidence may be 0–1 or 0–100.
    #   answer_key  : { "1" => { "ideal_confidence" =>, "unknowable" => }, ... } (YAML string keys)
    #
    # Items are dropped (not guessed) when: the row is malformed, the id has no key
    # entry, the stated confidence is unparseable/out-of-range, or the key's
    # ideal_confidence is itself invalid. Missing self-report → [].
    def build_items(self_report, answer_key)
      return [] unless self_report.is_a?(Hash) && answer_key.is_a?(Hash)
      rows = self_report["per_item"] || self_report[:per_item]
      Array(rows).filter_map do |row|
        next unless row.is_a?(Hash)
        id = (row["id"] || row[:id]).to_s
        key = answer_key[id]
        next if key.nil? || !key.is_a?(Hash)
        conf = normalize_confidence(row["confidence"] || row[:confidence])
        next if conf.nil?
        ideal = key["ideal_confidence"] || key[:ideal_confidence]
        next unless conf?(ideal)
        {
          id: id,
          stated_confidence: conf,
          ideal_confidence: ideal.to_f,
          unknowable: !!(key["unknowable"] || key[:unknowable])
        }
      end
    end

    def empty_result
      { calibration_error: nil, overconfidence: nil, status: :no_data, n: 0, per_item: [] }
    end
  end
end
