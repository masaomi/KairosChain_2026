#!/usr/bin/env ruby
# frozen_string_literal: true

# Prepare the pictures, cut-out characters and video clips an MV page draws (MV mode of photo_song_slideshow).
#
#   ruby mv_assets.rb mv_project.json            # writes <out>/ and <out>/manifest.json
#
# mv_project.json (paths relative to the file; see assets/mv/mv_project.example.json):
#   out          output folder, e.g. "assets"
#   photos       folders or files of photos (jpg/jpeg/png/heic); each becomes key = file name without extension
#   skip         file names, or paths, to leave out (sticker sheets are skipped automatically)
#   backgrounds  { "dir": folder, "replace": { "1": "file" } }  -> bg1..bgN: every png/jpg in name order, minus `skip`;
#                "replace" puts a named file at a position (the replaced file is not used)
#   stickers     { "name": sheet } -> name_01, name_02 ... one per character, white background removed
#   videos       [{ "key", "src", "from", "dur" }]  -> H.264 clips, rotation applied, frequent keyframes
#   stills       [{ "key", "src", "at" }]          -> one frame of a video as a photo
#
# Never writes inside a source folder, and calls ImageMagick once per file with the output named last:
# piping a file list into `magick montage ... OUT` through xargs once made the last photo the output and
# destroyed it.
# Requires: Ruby (stdlib only), ImageMagick 7 (`magick`), ffmpeg/ffprobe.

require "json"
require "open3"
require "fileutils"

def run!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort("#{cmd.first(3).join(' ')} failed: #{err[-600..] || err}") unless st.success?
  out
end

def size_of(path) = run!("magick", "identify", "-format", "%w %h", "#{path}[0]").split.map(&:to_i)

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

# Key = file name without extension, reduced to letters, digits, "_", "-", "." so it is safe in a URL and a file name.
def key_for(path) = File.basename(path, ".*").gsub(/[^\p{L}\p{N}_.-]/, "_")

cfg_path = ARGV[0] or abort("usage: ruby mv_assets.rb mv_project.json")
base = File.dirname(File.expand_path(cfg_path))
cfg = JSON.parse(File.read(cfg_path))
abs = ->(p) { File.expand_path(p, base) }
out = abs.(cfg.fetch("out", "assets"))
# Source folders must not nest with out either way (out inside one mixes outputs into what is read; one inside out
# gets overwritten); a single source file must not lie inside out.
folders = (cfg["photos"] || []).map(&abs).select { |x| File.directory?(x) } + [cfg.dig("backgrounds", "dir")].compact.map(&abs)
files = (cfg["photos"] || []).map(&abs).reject { |x| File.directory?(x) } + (cfg["stickers"] || {}).values.map(&abs) +
        ((cfg["videos"] || []) + (cfg["stills"] || [])).map { |v| abs.(v["src"]) }
folders.each { |d| abort("output #{out} and source folder #{d} overlap; choose an 'out' outside every source") if nested?(out, d) || nested?(d, out) }
files.each { |f| abort("source file #{f} is inside output #{out}; choose another 'out'") if nested?(f, out) }
%w[photos blur bg stickers video].each { |d| FileUtils.mkdir_p(File.join(out, d)) }
# an output subfolder that is a link into a source folder would write there: check each one as it now resolves
%w[photos blur bg stickers video].each do |d|
  sub = File.join(out, d)
  folders.each { |f| abort("#{sub} resolves into source folder #{f}; remove that link") if nested?(sub, f) || nested?(f, sub) }
end
# keys written by hand (stills, videos) become file names: same characters as the automatic ones, nothing else
((cfg["stills"] || []) + (cfg["videos"] || [])).each do |v|
  abort("key #{v['key'].inspect} may use only letters, digits, _ - . and must not start with .") unless v["key"].to_s.match?(/\A[\p{L}\p{N}_-][\p{L}\p{N}_.-]*\z/)
end
manifest = { "photos" => {}, "bg" => {}, "stickers" => {}, "videos" => {} }
rel = ->(p) { p.sub("#{File.dirname(out)}/", "") }

def picture(src, dst, blur_dst, long_edge)
  run!("magick", src, "-auto-orient", "-resize", "#{long_edge}x#{long_edge}>", "-quality", "88", "-interlace", "Plane", dst)
  run!("magick", dst, "-resize", "480x480", "-blur", "0x12", "-quality", "80", blur_dst)
  size_of(dst)
end

# ---- photos and stills
sheets = (cfg["stickers"] || {}).values.map { |p| File.basename(p) }
skip = (cfg["skip"] || []) + sheets
files = (cfg["photos"] || []).flat_map do |p|
  a = abs.(p)
  File.directory?(a) ? Dir.children(a).sort.map { |f| File.join(a, f) } : [a]
end
skipped = ->(f) { skip.include?(File.basename(f)) || skip.map(&abs).include?(f) }   # by file name, or by path
pics = files.select { |f| f.match?(/\.(jpe?g|png|heic)\z/i) && !skipped.(f) }
# Two sources with one key would overwrite each other's output and the later one would silently win.
# one name space, compared case-insensitively (the disk is): photos, stills, backgrounds share the image map and blur/
n_bg = cfg["backgrounds"] ? Dir.children(abs.(cfg["backgrounds"]["dir"])).count { |f| f.match?(/\.(png|jpe?g)\z/i) && !skip.include?(f) } : 0
taken = (pics.map { |f| [key_for(f), f] } + (cfg["stills"] || []).map { |s| [s["key"], "still of #{s['src']}"] } +
         (1..n_bg).map { |i| ["bg#{i}", "background #{i}"] }).group_by { |k, _| k.downcase }
vids = (cfg["videos"] || []).group_by { |v| v["key"].downcase }.select { |_, v| v.size > 1 }
abort("two videos share the key #{vids.keys.join(', ')}") unless vids.empty?
clash = taken.select { |_, v| v.size > 1 }
unless clash.empty?
  abort("these sources share a key (file name without extension, letter case ignored). Do not rename the user's file: " \
        "list one path in \"skip\", or copy it elsewhere under a new name (ask first) and use the copy:\n" +
        clash.map { |k, v| "  #{k}: #{v.map(&:last).join(', ')}" }.join("\n"))
end
pics.each do |f|
  key = key_for(f)
  dst = File.join(out, "photos", "#{key}.jpg"), File.join(out, "blur", "#{key}.jpg")
  w, h = picture(f, *dst, 2400)
  manifest["photos"][key] = { "src" => rel.(dst[0]), "blur" => rel.(dst[1]), "w" => w, "h" => h }
end
(cfg["stills"] || []).each do |s|
  tmp = File.join(out, "photos", "#{s['key']}.src.jpg")
  run!("ffmpeg", "-v", "error", "-y", "-ss", s["at"].to_s, "-i", abs.(s["src"]), "-frames:v", "1", "-q:v", "2", tmp)
  dst = File.join(out, "photos", "#{s['key']}.jpg"), File.join(out, "blur", "#{s['key']}.jpg")
  w, h = picture(tmp, *dst, 2400)
  File.delete(tmp)
  manifest["photos"][s["key"]] = { "src" => rel.(dst[0]), "blur" => rel.(dst[1]), "w" => w, "h" => h }
end

# ---- backgrounds: bg1..bgN in name order, with explicit replacements
if (bgc = cfg["backgrounds"])
  dir = abs.(bgc["dir"])
  list = Dir.children(dir).select { |f| f.match?(/\.(png|jpe?g)\z/i) && !skip.include?(f) }.sort.map { |f| File.join(dir, f) }
  reps = (bgc["replace"] || {}).to_h { |n, f| [n.to_i, File.join(dir, f)] }
  list -= reps.values                       # a replacement file takes its stated position only
  reps.each { |n, f| list[n - 1] = f }
  list.each_with_index do |f, i|
    key = "bg#{i + 1}"
    dst = File.join(out, "bg", "#{key}.jpg"), File.join(out, "blur", "#{key}.jpg")
    w, h = picture(f, *dst, 4000)
    manifest["bg"][key] = { "src" => rel.(dst[0]), "blur" => rel.(dst[1]), "w" => w, "h" => h, "from" => File.basename(f) }
  end
end

# ---- stickers: flood the white background away from the border, then one crop per connected figure
(cfg["stickers"] || {}).each do |name, sheet|
  src = abs.(sheet)
  cut = File.join(out, "stickers", "_#{name}_cut.png")
  run!("magick", src, "-alpha", "set", "-bordercolor", "white", "-border", "1", "-fuzz", "6%", "-fill", "none",
       "-draw", "color 0,0 floodfill", "-shave", "1x1", "-channel", "A", "-morphology", "Erode", "Disk:1", "+channel", cut)
  sw, sh = size_of(cut)
  min_area = (sw * sh * 0.004).round
  figures = ["-alpha", "extract", "-threshold", "50%", "-morphology", "Dilate", "Disk:2"]
  info = run!("magick", cut, *figures, "-define", "connected-components:verbose=true",
              "-define", "connected-components:area-threshold=#{min_area}", "-connected-components", "8", "null:")
  boxes = info.lines.filter_map do |l|
    m = l.match(/^\s*(\d+): (\d+)x(\d+)\+(\d+)\+(\d+) \S+ (\d+) (?:gray|srgb)\((255|100%)/) or next
    id, w, h, x, y, area = m.captures.first(6).map(&:to_i)
    [x, y, w, h, area, id]
  end
  biggest = boxes.map { |b| b[4] }.max || 0
  boxes = boxes.select { |b| b[4] > 0.15 * biggest }
  # rows: figures whose vertical centres are within half a typical height of each other, top row first
  half = (boxes.map { |b| b[3] }.sort[boxes.size / 2] || 1) / 2.0
  rows = []
  boxes.sort_by { |b| b[1] + b[3] / 2.0 }.each do |b|
    cy = b[1] + b[3] / 2.0
    (rows.last && (cy - rows.last[:cy]).abs <= half) ? rows.last[:items] << b : rows << { cy: cy, items: [b] }
  end
  boxes = rows.flat_map { |r| r[:items].sort_by(&:first) }
  boxes.each_with_index do |(x, y, w, h, _, id), i|
    key = format("%s_%02d", name, i + 1)
    pad = 6
    x0, y0 = [x - pad, 0].max, [y - pad, 0].max
    w1, h1 = [w + 2 * pad, sw - x0].min, [h + 2 * pad, sh - y0].min
    dst = File.join(out, "stickers", "#{key}.png")
    # keep only this figure's pixels: a neighbour reaching into the margin would otherwise come along
    run!("magick", cut, "(", cut, *figures, "-define", "connected-components:keep-ids=#{id}",
         "-define", "connected-components:mean-color=true", "-connected-components", "8", "-alpha", "copy", ")",
         "-compose", "DstIn", "-composite", "-crop", "#{w1}x#{h1}+#{x0}+#{y0}", "+repage", dst)
    manifest["stickers"][key] = { "src" => rel.(dst), "w" => w1, "h" => h1 }
  end
  File.delete(cut)
  puts "#{name}: #{boxes.size} stickers"
end

# ---- video clips
(cfg["videos"] || []).each do |v|
  src = abs.(v["src"])
  w, h = run!("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:stream_side_data=rotation",
              "-of", "json", src).then { |j| JSON.parse(j)["streams"][0] }.then do |s|
    rot = (s["side_data_list"] || []).map { |d| d["rotation"].to_i.abs }.max.to_i
    rot == 90 ? [s["height"], s["width"]] : [s["width"], s["height"]]
  end
  scale = w >= h ? "scale=1280:-2" : "scale=-2:1080"
  dst = File.join(out, "video", "#{v['key']}.mp4")
  run!("ffmpeg", "-v", "error", "-y", "-ss", v.fetch("from", 0).to_s, "-t", v["dur"].to_s, "-i", src, "-vf", "#{scale},fps=30",
       "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-g", "6", "-pix_fmt", "yuv420p", "-an", "-movflags", "+faststart", dst)
  dur = run!("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dst).to_f
  manifest["videos"][v["key"]] = { "src" => rel.(dst), "dur" => dur.round(3) }
end

File.write(File.join(out, "manifest.json"), JSON.pretty_generate(manifest))
puts "photos #{manifest['photos'].size}, backgrounds #{manifest['bg'].size}, stickers #{manifest['stickers'].size}, videos #{manifest['videos'].size}"
puts "wrote #{File.join(out, 'manifest.json')}"
