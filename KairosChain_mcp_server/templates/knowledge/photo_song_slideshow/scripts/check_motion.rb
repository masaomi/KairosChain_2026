#!/usr/bin/env ruby
# frozen_string_literal: true

# Measure whether a slideshow MP4 moves smoothly (no shaking) around given times.
#
#   ruby check_motion.rb slideshow.mp4 --at 25 60 120 [--row 0.6]
#
# For each time it decodes 14 consecutive frames in ONE ffmpeg call, keeps one horizontal strip
# (default 60 % down, 12-32 % across) and tracks it with sub-pixel cross-correlation.
# The strip is off-centre on purpose: a zoom barely moves the centre of the frame, so a central strip
# measures only noise. A smooth slow zoom gives steady steps of one sign; shaking shows as steps that
# change sign. Steps under 0.1 px count as standing still. Exit 1 if any time is shaky.
#
# Why one call: `ffmpeg -ss <f/fps>` per frame, with the time rounded, lands just before some frames and
# returns the previous one: a fake 0.00 step every third frame that looks like a defect but is not.
# Why `-fps_mode passthrough`: without it ffmpeg repeats the first decoded frame (another fake 0.00 step).
# Requires: Ruby (stdlib only), ffmpeg/ffprobe on PATH.

require "json"
require "open3"
require "optparse"

def probe(path)
  out, err, st = Open3.capture3("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "stream=width,height,r_frame_rate", "-of", "json", path)
  abort("ffprobe failed: #{err}") unless st.success?
  s = JSON.parse(out)["streams"][0]
  num, den = s["r_frame_rate"].split("/").map(&:to_f)
  [s["width"], s["height"], num / den]
end

def strip_rows(path, t, n, w, h, fps, row)
  x0 = (w * 0.12).to_i
  sw = (w * 0.20).to_i
  y = (h * row).to_i
  out, err, st = Open3.capture3("ffmpeg", "-v", "error", "-ss", format("%.5f", [0.0, t - 0.5 / fps].max), "-i", path,
                                "-fps_mode", "passthrough", "-frames:v", n.to_s, "-vf", "format=gray,crop=#{sw}:1:#{x0}:#{y}",
                                "-f", "rawvideo", "-pix_fmt", "gray", "-", binmode: true)
  abort("ffmpeg failed: #{err}") unless st.success?
  out.bytes.each_slice(sw).map { |r| r.map(&:to_f) }
end

# shift of b relative to a, in pixels, sub-pixel by a parabola through the correlation peak
def shift(a, b, max_lag = 20)
  ma = a.sum / a.size
  mb = b.sum / b.size
  a = a.map { |v| v - ma }
  b = b.map { |v| v - mb }
  c = (-max_lag..max_lag).map do |lag|
    s = 0.0
    a.each_index do |i|
      j = i + lag
      s += a[i] * b[j] if j >= 0 && j < b.size
    end
    s
  end
  k = c.each_with_index.max_by { |v, _| v }[1]
  return (k - max_lag).to_f if k.zero? || k == c.size - 1
  den = c[k - 1] - 2 * c[k] + c[k + 1]
  k - max_lag + (den.zero? ? 0.0 : 0.5 * (c[k - 1] - c[k + 1]) / den)
end

opts = { row: 0.6, n: 14, at: [] }
OptionParser.new do |o|
  o.banner = "usage: ruby check_motion.rb VIDEO --at T [T ...]"
  o.on("--at T", Float) { |v| opts[:at] << v }
  o.on("--row F", Float, "strip height as a fraction of the frame (default 0.6)") { |v| opts[:row] = v }
end.parse!
video = ARGV.shift or abort("usage: ruby check_motion.rb VIDEO --at T [T ...]")
opts[:at] += ARGV.map(&:to_f) # allow `--at 25 60 120`
abort("give at least one time with --at") if opts[:at].empty?

w, h, fps = probe(video)
shaky = false
opts[:at].each do |t|
  rows = strip_rows(video, t, opts[:n], w, h, fps, opts[:row])
  steps = rows.each_cons(2).map { |a, b| shift(a, b) }
  moving = steps.select { |s| s.abs >= 0.1 }
  sign = moving.empty? ? 0 : (moving.sort[moving.size / 2] <=> 0)
  back = moving.count { |s| (s <=> 0) != sign }
  mean = steps.sum / steps.size
  spread = Math.sqrt(steps.sum { |s| (s - mean)**2 } / steps.size)
  bad = back.positive? || spread > 0.3
  shaky ||= bad
  puts format("t=%7.2fs steps %s | spread %.2f px | backward %d/%d %s", t, steps.map { |s| format("%+.2f", s) }.join(" "),
              spread, back, steps.size, bad ? "SHAKY" : "ok")
end
puts "note: a cut or crossfade inside the 14 frames also breaks the pattern; pick times mid-slide"
exit(shaky ? 1 : 0)
