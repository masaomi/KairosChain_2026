#!/usr/bin/env ruby
# frozen_string_literal: true

# Time each lyric line against the recording. The displayed text is always YOUR lyrics, never the
# recogniser's: speech recognition is used only to find when each line is sung.
#
#   ruby align_lyrics.rb song.mp3 lyrics.txt --out lyrics_timed.json [--language en] [--words words.json]
#        [--recognizer whisper-cpp --model ~/models/ggml-large-v3-turbo.bin]
#        [--recognizer mlx --bin /path/to/mlx_whisper]
#
# lyrics.txt is the text pasted into the music generator: `[Section]` headers and lines that are only a
# parenthesised ad-lib, e.g. `(yeah, yeah...)`, are not displayed; every other line is one display line.
# Split a long line in the file first if it is sung as two phrases.
#
# Recogniser (an external program; installing one is an environment change: ask the user first):
#   whisper-cpp  `whisper-cli` from whisper.cpp (e.g. Homebrew `whisper-cpp`) + a ggml model file (--model)
#   mlx          the `mlx_whisper` command (Apple Silicon); model name via --model
#                (default mlx-community/whisper-large-v3-turbo, ~1.6 GB on first use)
# `--words words.json` saves the recognised words and reuses them on later runs.
# `--extra-pass 178,208` (repeatable) recognises that stretch again on its own and replaces the words heard
# there: a whispered or quiet passage can be missed in the whole-song pass and found when cut out.
# Each output line carries `words: [{w, t}]` (display word and the time it is sung) for word-by-word display.
# If under 30 % of the lyric words are heard, the recording is probably not the song these lyrics belong to.
# No initial prompt is passed: a prompt was once echoed back as a made-up line over an instrumental part,
# and a plain single pass timed every line.
#
# Alignment: global sequence alignment (Needleman-Wunsch) of lyric tokens to recognised words, fuzzy match
# by Ratcliff-Obershelp similarity (>= 0.6). Lines with no matched word get times from their neighbours
# (`filled: true`). Spoken numbers ("nine-thirty" heard as "9.30") rarely match; `firstHeard: false`
# marks such lines so the slideshow can start them where the previous line ended.
# Scripts written without spaces (Japanese, Chinese, Korean) are matched character by character.
# Requires: Ruby (stdlib only), ffmpeg, and one recogniser.

require "digest"
require "json"
require "open3"
require "optparse"
require "tmpdir"

CJK = /[぀-ヿ㐀-鿿가-힯]/

def norm(w)
  w.downcase.tr("’", "'").sub(/in'\z/, "ing").gsub(/[^\p{L}\p{N}]/, "")
end

def split_cjk(t) = t.match?(CJK) ? t.chars : [t]

def tokens(text)
  text.split(/[\s\-—–,.!?…"()、。！？「」]+/).map { |x| norm(x) }.reject(&:empty?).flat_map { |t| split_cjk(t) }
end

def display_lines(path)
  File.readlines(path, chomp: true).map(&:strip).reject do |l|
    l.empty? || (l.start_with?("[") && l.end_with?("]")) || (l.start_with?("(") && l.end_with?(")")) ||
      l.match?(/\A(title|style|lyrics)\s*:/i)
  end
end

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort("#{cmd.first} failed: #{err[-800..] || err}") unless st.success?
  out
end

def which(cmd) = ENV["PATH"].split(File::PATH_SEPARATOR).map { |d| File.join(d, cmd) }.find { |p| File.executable?(p) }

def transcribe(audio, o, condition: false)
  kind = o[:recognizer]
  kind = (which("whisper-cli") && o[:model]&.end_with?(".bin")) ? "whisper-cpp" : "mlx" if kind == "auto"
  Dir.mktmpdir("lyrics_") do |tmp|
    case kind
    when "whisper-cpp"
      bin = o[:bin] || which("whisper-cli") || abort("whisper-cli not found (whisper.cpp)")
      abort("--model must point to a ggml model file for whisper.cpp") unless o[:model] && File.exist?(o[:model])
      wav = File.join(tmp, "a.wav")
      run!("ffmpeg", "-v", "error", "-i", audio, "-ar", "16000", "-ac", "1", wav)
      run!(bin, "-m", o[:model], "-f", wav, "-l", o[:language], "-ml", "1", "-sow", "-oj", "-of", File.join(tmp, "w"))
      JSON.parse(File.read(File.join(tmp, "w.json")))["transcription"].map do |s|
        { "word" => s["text"], "start" => s["offsets"]["from"] / 1000.0, "end" => s["offsets"]["to"] / 1000.0 }
      end
    when "mlx"
      bin = o[:bin] || which("mlx_whisper") || abort("mlx_whisper not found; pass --bin or use --recognizer whisper-cpp")
      model = o[:model] || "mlx-community/whisper-large-v3-turbo"
      run!(bin, audio, "--model", model, "--language", o[:language], "--word-timestamps", "True",
           "--condition-on-previous-text", condition ? "True" : "False", "--output-format", "json", "--output-dir", tmp, "--output-name", "w")
      JSON.parse(File.read(File.join(tmp, "w.json")))["segments"].flat_map { |s| s["words"] || [] }
          .map { |w| { "word" => w["word"], "start" => w["start"].to_f, "end" => w["end"].to_f } }
    else
      abort("unknown --recognizer #{kind}")
    end
  end
end

# Ratcliff-Obershelp matching characters (longest common block, then recurse on both sides);
# ratio = 2 * matches / (len a + len b). Kinder to sung-word mishearings than edit distance.
def ro_matches(a, b)
  return 0 if a.empty? || b.empty?
  best_len = best_i = best_j = 0
  a.size.times do |i|
    b.size.times do |j|
      k = 0
      k += 1 while i + k < a.size && j + k < b.size && a[i + k] == b[j + k]
      if k > best_len
        best_len, best_i, best_j = k, i, j
      end
    end
  end
  return 0 if best_len.zero?
  best_len + ro_matches(a[0...best_i], b[0...best_j]) + ro_matches(a[(best_i + best_len)..], b[(best_j + best_len)..])
end

def sim(a, b)
  return 1.0 if a == b
  r = 2.0 * ro_matches(a, b) / (a.size + b.size)
  r >= 0.6 ? r : -0.6
end

def align(lines, heard, gap: -0.35)
  h = heard.flat_map { |w| split_cjk(norm(w["word"])).reject(&:empty?).map { |c| [c, w["start"], w["end"]] } }
  l = lines.each_with_index.flat_map { |text, li| text.split(/\s+/).each_with_index.flat_map { |w, wi| tokens(w).map { |t| [t, li, wi] } } }
  n, m = l.size, h.size
  s = Array.new(n + 1) { Array.new(m + 1, 0.0) }
  pt = Array.new(n + 1) { Array.new(m + 1, nil) }
  (1..n).each { |i| s[i][0] = s[i - 1][0] + gap; pt[i][0] = :u }
  (1..m).each { |j| s[0][j] = s[0][j - 1] + gap; pt[0][j] = :l }
  sims = {}
  (1..n).each do |i|
    (1..m).each do |j|
      key = [l[i - 1][0], h[j - 1][0]]
      d = s[i - 1][j - 1] + (sims[key] ||= sim(*key))
      u = s[i - 1][j] + gap
      lf = s[i][j - 1] + gap
      if d >= u && d >= lf then s[i][j] = d; pt[i][j] = :d
      elsif u >= lf then s[i][j] = u; pt[i][j] = :u
      else s[i][j] = lf; pt[i][j] = :l
      end
    end
  end
  match = {}
  i, j = n, m
  while i.positive? && j.positive?
    case pt[i][j]
    when :d
      match[i - 1] = j - 1 if sims[[l[i - 1][0], h[j - 1][0]]].positive?
      i -= 1; j -= 1
    when :u then i -= 1
    else j -= 1
    end
  end
  out = lines.each_with_index.map do |text, li|
    idx = l.each_index.select { |k| l[k][1] == li }
    hit = idx.filter_map { |k| match[k] }
    { "text" => text, "start" => hit.empty? ? nil : h[hit.min][1], "end" => hit.empty? ? nil : h[hit.max][2],
      "matched" => "#{hit.size}/#{idx.size}", "firstHeard" => !idx.empty? && match.key?(idx.first) }
  end
  out.each_with_index do |o, k| # nothing recognised: place the line between its neighbours
    next unless o["start"].nil?
    prev = out[0...k].reverse.find { |x| x["end"] }&.dig("end") || 0.0
    nxt = out[(k + 1)..].find { |x| x["start"] }&.dig("start") || prev + 2.0
    o.merge!("start" => prev, "end" => nxt, "filled" => true)
  end
  out.each_with_index do |o, li| # time of each display word: its first heard token, else interpolated
    words = lines[li].split(/\s+/)
    times = words.each_index.map do |wi|
      k = l.each_index.find { |x| l[x][1] == li && l[x][2] == wi && match.key?(x) }
      k && h[match[k]][1]
    end
    # first word not heard (a spoken number, a misheard name): the line began before its first heard word, so the
    # unheard leading words get about 0.4 s each, but never before the previous line ended
    lead = times.index { |tm| tm } || words.size
    anchor = o["start"]
    anchor = [li.positive? ? out[li - 1]["end"] : 0.0, o["start"] - 0.4 * lead].max if lead.positive? && times.any?
    known = [[-1, anchor]] + times.each_with_index.filter_map { |tm, i| [i, tm] if tm } + [[words.size, o["end"]]]
    known.each_cons(2) { |(i0, t0), (i1, t1)| ((i0 + 1)...i1).each { |i| times[i] = t0 + (t1 - t0) * (i - i0) / (i1 - i0).to_f } }
    o["words"] = words.zip(times).map { |w, tm| { "w" => w, "t" => [tm, anchor].max.round(3) } }
  end
  out.each { |o| o["start"] = o["start"].round(3); o["end"] = o["end"].round(3) }
end

o = { out: "lyrics_timed.json", language: "en", recognizer: "auto" }
OptionParser.new do |op|
  op.banner = "usage: ruby align_lyrics.rb SONG LYRICS [--out lyrics_timed.json]"
  op.on("--out PATH") { |v| o[:out] = v }
  op.on("--language CODE") { |v| o[:language] = v }
  op.on("--recognizer KIND", "auto | whisper-cpp | mlx") { |v| o[:recognizer] = v }
  op.on("--model NAME_OR_PATH") { |v| o[:model] = v }
  op.on("--bin PATH", "path to whisper-cli or mlx_whisper") { |v| o[:bin] = v }
  op.on("--words PATH", "saved transcript; written if absent, reused if present") { |v| o[:words] = v }
  op.on("--extra-pass FROM,TO", "recognise this stretch (seconds) again on its own; repeatable") { |v| (o[:extra] ||= []) << v.split(",").map(&:to_f) }
end.parse!
audio, lyrics = ARGV
abort("usage: ruby align_lyrics.rb SONG LYRICS [--out lyrics_timed.json]") unless audio && lyrics

# A saved transcript is reused only for the same recording (sha256 of the whole file);
# a replaced song, even another take of the same lyrics, is recognised again.
fingerprint = { "size" => File.size(audio), "sha256" => Digest::SHA256.file(audio).hexdigest }
load_cache = lambda do |path|
  next nil unless path && File.exist?(path)
  c = JSON.parse(File.read(path))
  next c["words"] if c.is_a?(Hash) && c["audio"] == fingerprint
  puts "#{path} was made from another recording (or an older version of this script); recognising again"
  nil
end
heard = load_cache.(o[:words])
if heard.nil?
  heard = transcribe(audio, o)
  File.write(o[:words], JSON.generate("audio" => fingerprint, "words" => heard)) if o[:words]
end
(o[:extra] || []).each do |from, to|
  cache = o[:words] && o[:words].sub(/\.json\z/, "") + format(".extra_%.1f_%.1f.json", from, to)
  part = load_cache.(cache)
  unless part
    Dir.mktmpdir("lyrics_extra_") do |tmp|
      cut = File.join(tmp, "cut.wav")
      run!("ffmpeg", "-v", "error", "-ss", from.to_s, "-to", to.to_s, "-i", audio, "-ar", "16000", "-ac", "1", cut)
      part = transcribe(cut, o, condition: true).map { |w| w.merge("start" => w["start"] + from, "end" => w["end"] + from) }
    end
    File.write(cache, JSON.generate("audio" => fingerprint, "words" => part)) if cache
  end
  heard = heard.reject { |w| w["start"] >= from && w["start"] < to } + part
  heard.sort_by! { |w| w["start"] }
  puts format("extra pass %.1f-%.1f s: %d words", from, to, part.size)
end
result = align(display_lines(lyrics), heard)
File.write(o[:out], JSON.pretty_generate(result))
weak = 0
result.each do |r|
  got, tot = r["matched"].split("/").map(&:to_i)
  flag = r["filled"] ? "FILLED " : (tot.positive? && got.to_f / tot < 0.5 ? "weak   " : "")
  weak += 1 unless flag.empty?
  puts format("%7.2f %7.2f %6s %s%s", r["start"], r["end"], r["matched"], flag, r["text"])
end
puts "#{result.size} lines, #{weak} filled or weakly matched -> ask the user to listen to those lines; wrote #{o[:out]}"
got = result.sum { |r| r["matched"].split("/").first.to_i }
tot = result.sum { |r| r["matched"].split("/").last.to_i }
if tot.positive? && got < 0.3 * tot
  title, = Open3.capture3("ffprobe", "-v", "error", "-show_entries", "format_tags=title", "-of", "default=nw=1:nk=1", audio)
  title = title.strip
  warn "WARNING: only #{got}/#{tot} lyric words were heard. This recording is probably not the song these lyrics " \
       "belong to (its title tag: #{title.empty? ? '(none)' : title.inspect}). Ask before going on."
end
