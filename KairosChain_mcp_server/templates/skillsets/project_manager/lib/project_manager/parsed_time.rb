# frozen_string_literal: true

require 'time'

module ProjectManager
  # Every timestamp in the store is a caller-supplied string: pm_item writes both
  # `due` and `touched_at` through with no validation beyond a JSON type. Nothing
  # that reads one may assume Time.parse succeeds, and any exception it raises,
  # from a bucket or a filter, takes the whole call down — and keeps taking it
  # down on every later call, because the value stays in the store. It is
  # repairable: an ordinary pm_item update rewrites the field and restamps the
  # marker. But the reading agent has to notice, and what it sees is an error
  # object where a report should be, with no indication which item caused it.
  #
  # Three exception classes are reachable, and enumerating two of them is how the
  # earlier version of this guard was still broken: ArgumentError for a malformed
  # String, TypeError for a non-String, and RangeError from Date._parse whenever
  # a numeric field exceeds C int range — "2026-01-01T00:00:3000000000" and
  # "2147483648pm" both reach it, and both are writable through pm_item today.
  #
  # An unreadable value is treated as absent. Concretely that means each reader
  # does what it would do for a missing value: dormancy says not dormant, the
  # deadline filter and the due bucket exclude the item, and days-since is nil.
  # Excluding it from a deadline filter is not the same as hiding it — the item
  # stays in the store, in an unfiltered pm_query, and in uncovered_count, which
  # is what makes this the safe direction rather than a silent loss.
  #
  # Note what an unreadable marker does NOT put an item into. Dormancy is false
  # for it, and uncovered_stale selects on dormancy, so such an item never
  # appears in uncovered_stale. Where it does appear depends on the rest of the
  # record: with an open gate, or a deadline that is both readable and inside the
  # horizon, it is named in that bucket, carrying its raw touched_at so the reader
  # can say the marker is unreadable; otherwise — including with a readable
  # deadline further out than the horizon — it falls to uncovered_count. Either
  # way it is visible, and the qualifier matters: an earlier draft of this comment
  # said "a readable deadline" and was wrong for exactly the far-future case. What it
  # is never given is a place in a list ordered by days untouched, which would
  # mean calling a marker nobody can read a duration.
  #
  # This lives here, once, because at the base commit four call sites parsed a
  # stored timestamp without a guard, and fixing them one at a time took four
  # review rounds — each round's fix left the next site standing. A guard at a
  # call site is re-acquired by the next caller.
  def self.parse_time(value)
    return nil if value.nil?

    Time.parse(value)
  rescue ArgumentError, TypeError, RangeError
    nil
  end

  # The same discipline for a caller-supplied number. Day windows and thresholds
  # reach arithmetic rather than Time.parse, and an unusable one is answered the
  # same way: nil, so the reader falls back rather than failing.
  #
  # Base 10 is explicit because Integer("014") is 12 without it, and a quoted
  # threshold is exactly what this accepts. RangeError is listed because
  # Integer() raises FloatDomainError for the `.inf` and `.nan` that YAML writes
  # — the surface pm.yml is edited on. JSON reaches Infinity only through float
  # overflow such as 1e400, and rejects a bare NaN outright, so the YAML path is
  # the one that motivates it.
  #
  # This absorbs what the store's two writing surfaces, YAML and JSON, can
  # deliver. It is not a closed set over every Ruby object: a String in an
  # ASCII-incompatible encoding such as UTF-16 raises Encoding::CompatibilityError
  # — ISO-8859-1 and Shift_JIS do not — and an object whose to_i raises
  # propagates that. Neither is reachable from a parsed document, and
  # widening the rescue to swallow arbitrary failures would hide a caller bug
  # rather than an operator typo.
  def self.whole_number(value)
    return nil if value.nil?

    value.is_a?(String) ? Integer(value, 10) : Integer(value)
  rescue ArgumentError, TypeError, RangeError
    nil
  end
end
