#!/usr/bin/env ruby
# frozen_string_literal: true

# Look at many photos for few tokens.
#
#   ruby survey_photos.rb sample DIR --n 16 --out /tmp/sample      # time-stratified random picks, 1024 px
#   ruby survey_photos.rb sheets DIR --out /tmp/sheets [--per 24]  # labelled contact sheets, ~1550 px wide
#   ruby survey_photos.rb dupes DIR                                # same shot saved twice (e.g. compressed + original)
#
# Reading a full-size photo costs roughly 1,000-1,600 tokens; a contact sheet of 24 labelled thumbnails
# costs about the same, so 150 photos fit in 7 sheets (~10k tokens) instead of 150-240k tokens.
# `sample` is enough for a first lyrics draft; `sheets` shows everything (for the story order);
# `dupes` finds pairs that are the same picture at different sizes, which otherwise look like
# "similar shots" on a contact sheet.
# Labels are the trailing number of the file name (..._007.jpg -> 007) or the running index.
# Time comes from a YYYY-MM-DD_HH-MM-SS name prefix if present, else EXIF DateTimeOriginal, else mtime.
# Requires: Ruby (stdlib only) and ImageMagick 7 (`magick`) on PATH.

require "fileutils"
require "open3"
require "optparse"
require "time"

EXTS = %w[.jpg .jpeg .png .heic .webp].freeze

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort("#{cmd.first} failed: #{err}") unless st.success?
  out
end

# A path made comparable: symlinks resolved on the part that exists, case folded (macOS volumes are
# case-insensitive by default, so "Assets/Photos" and "assets/photos" are one folder).
def canon(path)
  p = File.expand_path(path)
  rest = []
  until File.exist?(p) || p == "/"
    rest.unshift(File.basename(p))
    p = File.dirname(p)
  end
  File.join(File.realpath(p), *rest).downcase
end

def nested?(inner, outer) = (canon(inner) + "/").start_with?(canon(outer) + "/")

def photos(dir)
  Dir.children(dir).select { |f| EXTS.include?(File.extname(f).downcase) && !f.start_with?(".") }.sort
end

def taken_at(dir, f)
  if (m = f.match(/(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})/))
    return Time.parse("#{m[1]} #{m[2]}:#{m[3]}:#{m[4]}")
  end
  exif = run!("magick", "identify", "-format", "%[EXIF:DateTimeOriginal]", File.join(dir, f)).strip
  return Time.strptime(exif, "%Y:%m:%d %H:%M:%S") unless exif.empty?
  File.mtime(File.join(dir, f))
rescue StandardError
  File.mtime(File.join(dir, f))
end

def label(f, i)
  (m = f.match(/_(\d+)\.\w+\z/)) ? m[1] : format("%03d", i)
end

def sample(o)
  fs = photos(o[:dir])
  times = fs.map { |f| [taken_at(o[:dir], f), f] }.sort
  k = [[o[:blocks], times.size].min, 1].max
  rng = Random.new(o[:seed])
  picks = (0...k).flat_map do |i|
    block = times[(i * times.size / k)...((i + 1) * times.size / k)]
    quota = [(o[:n] * block.size.to_f / times.size).round, 1].max
    block.sample([quota, block.size].min, random: rng)
  end
  FileUtils.mkdir_p(o[:out])
  used = {}
  picks.sort.each do |t, f|
    stem = File.basename(f, ".*")
    stem = "#{stem}_#{File.extname(f).delete('.')}" if used[stem.downcase]   # IMG_1.jpg and IMG_1.png both kept
    used[stem.downcase] = true
    run!("magick", "-define", "jpeg:size=2048x2048", File.join(o[:dir], f), "-auto-orient", "-resize", "1024x1024>",
         "-quality", "82", File.join(o[:out], "#{stem}.jpg"))
    puts "#{t.strftime('%Y-%m-%d %H:%M')} #{f}"
  end
  puts "#{picks.size} of #{fs.size} photos -> #{o[:out]}"
end

def sheets(o)
  fs = photos(o[:dir])
  FileUtils.mkdir_p(o[:out])
  fs.each_slice(o[:per]).with_index do |chunk, s|
    args = chunk.each_with_index.flat_map { |f, j| ["-label", label(f, s * o[:per] + j), File.join(o[:dir], f)] }
    path = File.join(o[:out], "sheet_#{s + 1}.jpg")
    run!("magick", "montage", "-define", "jpeg:size=500x500", "-auto-orient", *args, "-tile", "6x#{(o[:per] / 6.0).ceil}",
         "-geometry", "250x250+4+4", "-pointsize", "22", "-background", "#222", "-fill", "white", path)
    puts "#{path} (#{chunk.size} photos)"
  end
end

# 16x16 grey thumbnail per photo; pairs closer than the threshold (mean abs difference, 0-255) are the
# same picture. Same shot at two sizes scores ~1-3; different shots of the same scene usually 15+.
def dupes(o)
  fs = photos(o[:dir])
  sig = fs.to_h do |f|
    raw = run!("magick", "-define", "jpeg:size=256x256", File.join(o[:dir], f), "-auto-orient", "-colorspace", "gray",
               "-resize", "16x16!", "-depth", "8", "gray:-")
    [f, raw.bytes]
  end
  pairs = fs.combination(2).filter_map do |a, b|
    d = sig[a].zip(sig[b]).sum { |x, y| (x - y).abs } / 256.0
    [d, a, b] if d <= o[:threshold]
  end
  pairs.sort.each { |d, a, b| puts format("%5.1f  %s  %s", d, a, b) }
  puts "#{pairs.size} likely duplicate pair(s) among #{fs.size} photos (threshold #{o[:threshold]})"
end

cmd = ARGV.shift
o = { n: 16, blocks: 4, seed: 1, per: 24, threshold: 4.0 }
OptionParser.new do |op|
  op.on("--n N", Integer) { |v| o[:n] = v }
  op.on("--blocks N", Integer, "time blocks to stratify over") { |v| o[:blocks] = v }
  op.on("--seed N", Integer) { |v| o[:seed] = v }
  op.on("--per N", Integer) { |v| o[:per] = v }
  op.on("--out DIR") { |v| o[:out] = v }
  op.on("--threshold D", Float) { |v| o[:threshold] = v }
end.parse!
o[:dir] = ARGV.shift
abort("usage: ruby survey_photos.rb sample|sheets|dupes DIR [--out DIR]") unless o[:dir] && %w[sample sheets dupes].include?(cmd)
abort("#{cmd} needs --out") if cmd != "dupes" && !o[:out]
if o[:out] && (nested?(o[:out], o[:dir]) || nested?(o[:dir], o[:out]))
  abort("--out #{o[:out]} overlaps the photo folder #{o[:dir]}: outputs would overwrite or mix with the originals. " \
        "Use a separate folder, e.g. survey/sample next to the project.")
end
send(cmd, o)
