#!/usr/bin/env ruby
# frozen_string_literal: true

# Find the tempo, the beat grid and the drop of a song, for cutting photos on the beat.
#
#   ruby analyze_audio.rb song.mp3 --out beats.json
#
# Writes {bpm, period, first_beat, drop, drop_beat, duration, alternatives, windows}. Prints a loudness
# table (4 s windows) and the beat-phase offset per 20 s window so a person can sanity-check the grid.
# Requires: Ruby (stdlib only) and ffmpeg on PATH.
#
# Method: ffmpeg splits the song into three bands (kick < 150 Hz, body 150-2000 Hz, hats > 2 kHz);
# per 23 ms hop the log energy of each band is taken and its rises are summed (an onset envelope).
# Autocorrelation gives tempo candidates; each is refined on a 0.02 BPM grid by folding the envelope
# at that period and taking the strongest phase.
#
# Notes
# - Do not trust the BPM you asked the music generator for; measure it (2-3 BPM off is common).
# - Half / double tempo are both plausible; `alternatives` lists them. Rap is usually 80-100 BPM.

require "json"
require "open3"
require "optparse"

SR = 11_025
HOP = 256
FPS = SR.to_f / HOP

def decode_bands(path)
  fc = "[0:a]aformat=channel_layouts=mono,asplit=3[a][b][c];" \
       "[a]lowpass=f=150[l];[b]highpass=f=150,lowpass=f=2000[m];[c]highpass=f=2000[h];" \
       "[l][m][h]amerge=inputs=3,aresample=#{SR}[o]"
  out, err, st = Open3.capture3("ffmpeg", "-v", "error", "-i", path, "-filter_complex", fc, "-map", "[o]",
                                "-f", "f32le", "-", binmode: true)
  abort("ffmpeg failed: #{err}") unless st.success?
  out.unpack("e*")
end

# per hop: log energy of each band, full-band energy, and the onset envelope (summed positive rises)
def envelopes(samples)
  n = samples.size / 3
  frames = n / HOP
  loge = Array.new(frames) { [0.0, 0.0, 0.0] }
  energy = Array.new(frames, 0.0)
  frames.times do |f|
    e0 = e1 = e2 = 0.0
    base = f * HOP * 3
    i = 0
    while i < HOP * 3
      a = samples[base + i]; b = samples[base + i + 1]; c = samples[base + i + 2]
      e0 += a * a; e1 += b * b; e2 += c * c
      i += 3
    end
    loge[f] = [Math.log(1e-10 + e0), Math.log(1e-10 + e1), Math.log(1e-10 + e2)]
    energy[f] = (e0 + e1 + e2) / HOP
  end
  flux = Array.new(frames, 0.0)
  (1...frames).each do |f|
    flux[f] = (0..2).sum { |b| [loge[f][b] - loge[f - 1][b], 0.0].max }
  end
  mean = flux.sum / frames
  sd = Math.sqrt(flux.sum { |v| (v - mean)**2 } / frames)
  [flux.map { |v| (v - mean) / (sd + 1e-9) }, energy]
end

# fold the envelope at `period` over [from, to) seconds; return [score, phase_seconds]
def fold(flux, period, from, to, bins: 64)
  acc = Array.new(bins, 0.0)
  cnt = Array.new(bins, 0)
  f0 = (from * FPS).ceil
  f1 = [(to * FPS).floor, flux.size - 1].min
  (f0..f1).each do |f|
    b = (((f / FPS) % period) / period * bins).floor % bins
    acc[b] += flux[f]
    cnt[b] += 1
  end
  mean = acc.each_with_index.map { |v, i| cnt[i].zero? ? -1e9 : v / cnt[i] }
  k = mean.each_with_index.max_by { |v, _| v }[1]
  l, r = mean[(k - 1) % bins], mean[(k + 1) % bins]
  den = l - 2 * mean[k] + r
  frac = den.abs < 1e-12 ? 0.0 : 0.5 * (l - r) / den
  [mean[k], (((k + 0.5 + frac) / bins) * period) % period]
end

FINE_HOP = 64 # 5.8 ms, for kick timing

# kick-drum onsets (low band only) at fine resolution: [[time, strength], ...]
def kick_onsets(samples)
  n = samples.size / 3
  frames = n / FINE_HOP
  loge = Array.new(frames) do |f|
    e = 0.0
    base = f * FINE_HOP * 3
    j = 0
    while j < FINE_HOP * 3
      v = samples[base + j]
      e += v * v
      j += 3
    end
    Math.log(1e-10 + e)
  end
  rise = (0...frames).map { |f| f.zero? ? 0.0 : [loge[f] - loge[f - 1], 0.0].max }
  mean = rise.sum / frames
  sd = Math.sqrt(rise.sum { |v| (v - mean)**2 } / frames)
  thr = mean + 2 * sd
  gap = (0.15 * SR / FINE_HOP).round
  (1...(frames - 1)).filter_map do |f|
    next unless rise[f] >= thr && rise[f] == rise[[0, f - gap].max..[frames - 1, f + gap].min].max
    [(f + 0.5) * FINE_HOP / SR.to_f, rise[f]]
  end
end

# least-squares fit t = first + k * period over onsets that sit near the grid; returns [period, first, rms, used]
def fit_grid(onsets, period, first, from, to)
  2.times do
    pts = onsets.filter_map do |t, w|
      next unless t >= from && t <= to
      k = ((t - first) / period).round
      r = t - (first + k * period)
      [k, t, w] if r.abs < 0.08
    end
    return [period, first, nil, 0] if pts.size < 8
    sw = pts.sum { |_, _, w| w }
    mk = pts.sum { |k, _, w| w * k } / sw
    mt = pts.sum { |_, t, w| w * t } / sw
    skk = pts.sum { |k, _, w| w * (k - mk)**2 }
    skt = pts.sum { |k, t, w| w * (k - mk) * (t - mt) }
    period = skt / skk
    first = mt - period * mk
  end
  pts = onsets.filter_map do |t, _|
    next unless t >= from && t <= to
    r = t - (first + ((t - first) / period).round * period)
    r if r.abs < 0.08
  end
  [period, first, Math.sqrt(pts.sum { |r| r * r } / pts.size), pts.size]
end

opts = { out: "beats.json", min_bpm: 70.0, max_bpm: 180.0, onset_lag: HOP / 2.0 / SR }
OptionParser.new do |o|
  o.banner = "usage: ruby analyze_audio.rb SONG [--out beats.json]"
  o.on("--out PATH") { |v| opts[:out] = v }
  o.on("--min-bpm N", Float) { |v| opts[:min_bpm] = v }
  o.on("--max-bpm N", Float) { |v| opts[:max_bpm] = v }
  o.on("--onset-lag S", Float, "seconds added to the grid (default: half a hop, the centre of the frame holding the onset)") { |v| opts[:onset_lag] = v }
end.parse!
audio = ARGV.shift or abort("usage: ruby analyze_audio.rb SONG [--out beats.json]")

samples = decode_bands(audio)
duration = samples.size / 3.0 / SR
flux, energy = envelopes(samples)

# loudness per 4 s; the drop is the first window clearly louder (>= 5 dB) than everything before it
db = (0...(duration / 4).ceil).map do |w|
  sl = energy[(w * 4 * FPS).floor...[((w + 1) * 4 * FPS).floor, energy.size].min] || []
  [w * 4.0, 10 * Math.log10(1e-12 + (sl.empty? ? 0 : sl.sum / sl.size))]
end
drop = 0.0
(1...db.size).each do |i|
  if db[i][1] - db[0...i].map(&:last).max >= 5
    drop = db[i][0]
    break
  end
end

# coarse tempo candidates from autocorrelation, refined with phase over the body of the song
lmin = (60 * FPS / opts[:max_bpm]).floor
lmax = (60 * FPS / opts[:min_bpm]).ceil
ac = (lmin..lmax).map do |lag|
  s = 0.0
  (0...(flux.size - lag)).each { |i| s += flux[i] * flux[i + lag] }
  [s, 60 * FPS / lag]
end
coarse = ac.sort_by { |s, _| -s }.first(6).map(&:last)
body = [drop, [duration - 8, drop + 30].max] # the longer the span, the finer the tempo
scored = []
coarse.each do |c|
  bpm = c - 3
  while bpm < c + 3
    score, ph = fold(flux, 60.0 / bpm, *body)
    scored << [score, bpm, ph]
    bpm += 0.02
  end
end
scored.sort_by! { |s, _, _| -s }
# last pass: 0.005 BPM steps around the best coarse value
best = scored.first[1]
fine = (-10..10).map do |i|
  b = best + i * 0.005
  sc, p2 = fold(flux, 60.0 / b, *body)
  [sc, b, p2]
end
_score, bpm, ph = fine.max_by { |sc, _, _| sc }
period = 60.0 / bpm
first = (ph + opts[:onset_lag]) % period
# refine tempo and phase on the kick drum itself (the folded envelope is only 23 ms fine)
period, first, rms, used = fit_grid(kick_onsets(samples), period, first, *body)
first %= period
bpm = 60.0 / period
drop_beat = drop.positive? ? ((drop - first) / period - 0.25).ceil : 0
drop_t = first + drop_beat * period

windows = (0...((duration - 10) / 20).ceil).map do |w|
  s = w * 20.0
  v, p2 = fold(flux, period, s, [duration, s + 20].min)
  off = (p2 + opts[:onset_lag] - first) % period
  { from: s, offset_s: [off, period - off].min.round(3), strength: v.round(2) }
end
alts = scored.first(300).map { |_, b, _| b.round(2) }.reject { |b| (b - bpm).abs <= 2 }.uniq.first(4)

out = { bpm: bpm.round(3), period: period.round(6), first_beat: first.round(4), drop: drop_t.round(4),
        fit_scatter_ms: rms && (rms * 1000).round(1), fit_onsets: used,
        drop_beat: drop_beat, duration: duration.round(3), alternatives: alts, windows: windows }
File.write(opts[:out], JSON.pretty_generate(out))

puts format("duration %.1f s | bpm %.3f | first beat %.3f s | drop %.2f s (beat %d)", duration, bpm, first, drop_t, drop_beat)
puts(rms ? format("grid fitted on %d kick onsets, scatter %.1f ms (under ~20 ms: a steady beat)", used, rms * 1000) : "too few kick onsets to fit; grid from folding only")
puts "loudness (4 s windows):"
db.each { |s, v| puts format("  %6.0fs %6.1f dB %s", s, v, "#" * [0, (v + 60).to_i].max) }
puts "beat-phase offset per 20 s window (near 0 = stable grid; near half a beat = off-beat accents):"
windows.each { |w| puts format("  %6.0fs offset %.3fs strength %.2f", w[:from], w[:offset_s], w[:strength]) }
puts "alternatives: #{alts.join(', ')}" unless alts.empty?
puts "wrote #{opts[:out]}"
