#!/usr/bin/env ruby
# frozen_string_literal: true

# Bundle what the MV page needs into one script file it can load from disk (a page opened as file:// cannot
# fetch JSON): lyric lines with word times, the asset manifest, and the beat grid.
#
#   ruby mv_data.rb --lyrics lyrics_timed.json --manifest assets/manifest.json --beats beats.json --out assets/data.js
#
# lyrics_timed.json comes from align_lyrics.rb (it carries `words`), beats.json from analyze_audio.rb,
# manifest.json from mv_assets.rb. Requires: Ruby (stdlib only).

require "json"
require "optparse"

o = { lyrics: "lyrics_timed.json", manifest: "assets/manifest.json", beats: "beats.json", out: "assets/data.js" }
OptionParser.new do |op|
  op.on("--lyrics PATH") { |v| o[:lyrics] = v }
  op.on("--manifest PATH") { |v| o[:manifest] = v }
  op.on("--beats PATH") { |v| o[:beats] = v }
  op.on("--out PATH") { |v| o[:out] = v }
end.parse!

lines = JSON.parse(File.read(o[:lyrics]))
abort("#{o[:lyrics]} has no word times; re-run align_lyrics.rb (it writes `words` per line)") unless lines.all? { |l| l["words"] }
lines = lines.each_with_index.map do |l, i|
  l.merge("next" => i + 1 < lines.size ? lines[i + 1]["start"] : (l["end"] + 4).round(3)).slice("text", "start", "end", "next", "words")
end
beats = JSON.parse(File.read(o[:beats]))
data = { "lyrics" => lines, "assets" => JSON.parse(File.read(o[:manifest])),
         "beat" => { "period" => beats.fetch("period"), "first" => beats.fetch("first_beat") } }
File.write(o[:out], "window.MV_DATA = #{JSON.generate(data)};\n")
puts "#{lines.size} lyric lines, #{data['assets'].values.sum(&:size)} assets -> #{o[:out]}"
