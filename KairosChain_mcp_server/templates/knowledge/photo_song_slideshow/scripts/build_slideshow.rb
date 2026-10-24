#!/usr/bin/env ruby
# frozen_string_literal: true

# Beat-synced photo slideshow with timed lyrics, from one project file. One timeline drives both outputs,
# so the HTML player and the MP4 show the same thing.
#
#   ruby build_slideshow.rb project.json check          # timeline summary; fails if the photos overflow the song
#   ruby build_slideshow.rb project.json html           # self-contained HTML player (photos referenced by path)
#   ruby build_slideshow.rb project.json frames 12 60   # still frames through the same path as the MP4
#   ruby build_slideshow.rb project.json mp4            # MP4: H.264 + AAC from the song
#
# MP4 path: ImageMagick composes one still per slide (blurred background + the photo, or title / card text);
# ffmpeg zooms each still with the `perspective` filter evaluated per frame (sub-pixel, so no shaking),
# cross-fades into the next, draws captions and lyrics from an ASS subtitle file (libass), and writes one
# short segment per slide; the segments are joined without re-encoding and the song is muxed in.
# Intermediate files go to work_dir (default: slideshow_work/ next to the project file) and are reused
# when nothing they depend on changed.
# Requires: Ruby (stdlib only), ImageMagick 7 (`magick`), ffmpeg built with libass and libx264.
# See assets/project.example.json for the project format.

require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"

module Slideshow
  module_function

  IM_FONTS = [
    { "heavy" => "Avenir-Next-Heavy", "demi" => "Avenir-Next-Demi-Bold", "medium" => "Avenir-Next-Medium", "regular" => "Avenir-Next-Regular" },
    { "heavy" => "Helvetica-Bold", "demi" => "Helvetica-Bold", "medium" => "Helvetica", "regular" => "Helvetica" },
    { "heavy" => "DejaVu-Sans-Bold", "demi" => "DejaVu-Sans-Bold", "medium" => "DejaVu-Sans", "regular" => "DejaVu-Sans" }
  ].freeze
  ASS_FONTS = { "Avenir-Next" => { "heavy" => "Avenir Next Heavy", "demi" => "Avenir Next Demi Bold", "medium" => "Avenir Next Medium", "regular" => "Avenir Next" },
                "Helvetica" => { "heavy" => "Helvetica", "demi" => "Helvetica", "medium" => "Helvetica", "regular" => "Helvetica" },
                "DejaVu" => { "heavy" => "DejaVu Sans", "demi" => "DejaVu Sans", "medium" => "DejaVu Sans", "regular" => "DejaVu Sans" } }.freeze
  ASS_SCALE = 1.33 # ASS font size is a line height; CSS / ImageMagick size is an em

  def run!(*cmd, chdir: nil)
    opts = chdir ? { chdir: chdir } : {}
    out, err, st = Open3.capture3(*cmd, **opts)
    abort("#{cmd.first} failed:\n#{err[-1500..] || err}") unless st.success?
    out
  end

  # ---------------------------------------------------------------- project + timeline

  def load_project(path)
    base = File.dirname(File.expand_path(path))
    p = JSON.parse(File.read(path))
    rel = ->(x) { x.nil? || x.start_with?("/") ? x : File.expand_path(x, base) }
    p["_base"] = base
    p["photo_dir"] = rel.(p.fetch("photo_dir", "."))
    %w[audio beats lyrics out_html out_mp4 work_dir].each { |k| p[k] = rel.(p[k]) if p[k] }
    p["out_html"] ||= File.join(base, "slideshow.html")
    p["out_mp4"] ||= File.join(base, "slideshow.mp4")
    p["work_dir"] ||= File.join(base, "slideshow_work")
    { "size" => [1920, 1080], "fps" => 30, "zoom" => 0.06, "fade_in" => 1.0, "fade_out" => 2.5,
      "caption_seconds" => 3.5, "intro" => [], "crf" => 20 }.each { |k, v| p[k] = v unless p.key?(k) }
    p
  end

  def photo_path(p, f) = f.start_with?("/") ? f : File.join(p["photo_dir"], f)

  def parse_photos(p)
    p.fetch("photos").map do |item|
      if item.is_a?(String) # "file.jpg" or "file.jpg:2"
        f, b = item.include?(":") ? item.split(/:(?=\d+\z)/) : [item, "2"]
        item = { "file" => f, "beats" => (b || 2).to_i }
      end
      { "beats" => 2 }.merge(item)
    end
  end

  def image_size(src)
    run!("magick", src, "-auto-orient", "-format", "%w %h", "info:").split.map(&:to_i)
  end

  def card_geometry(src, crop, w, h)
    iw, ih = image_size(src)
    x0, y0, x1, y1 = crop || [0, 0, iw, ih]
    hd = h * 0.84
    sc = hd / (y1 - y0)
    u = w / 100.0
    { "crop" => [x0, y0, x1, y1], "cardW" => (x1 - x0) * sc / u, "cardH" => hd / u,
      "bgW" => iw * sc / u, "bgX" => -x0 * sc / u, "bgY" => -y0 * sc / u, "imgW" => iw, "imgH" => ih }
  end

  def timeline(p)
    beats = JSON.parse(File.read(p.fetch("beats")))
    period, first, duration = beats.values_at("period", "first_beat", "duration")
    beat_t = ->(k) { first + k * period }
    w, h = p["size"]
    slides = []
    captions = []
    k = 0
    p["intro"].each do |card|
      kind = card.fetch("kind", "title")
      s = { "kind" => kind, "src" => photo_path(p, card.fetch("image")), "start" => (k.zero? ? 0.0 : beat_t.(k)).round(4),
            "end" => beat_t.(k + card.fetch("beats")).round(4), "xf" => 0.8, "zoom" => slides.size.even? ? 1 : -1,
            "lines" => card.fetch("lines", []) }
      s.merge!(card_geometry(s["src"], card["crop"], w, h)) if kind == "card"
      slides << s
      k += card["beats"]
    end
    photos = parse_photos(p)
    missing = photos.map { |x| x["file"] }.reject { |f| File.exist?(photo_path(p, f)) }
    abort("missing photos: #{missing.first(5)}#{missing.size > 5 ? ' ...' : ''}") unless missing.empty?
    photos.each_with_index do |ph, n|
      start = beat_t.(k)
      stop = n == photos.size - 1 ? duration : beat_t.(k + ph["beats"])
      slides << { "kind" => "photo", "src" => photo_path(p, ph["file"]), "start" => start.round(4), "end" => stop.round(4),
                  "xf" => ph["beats"] == 1 ? 0.1 : 0.3, "zoom" => slides.size.even? ? 1 : -1, "lines" => [] }
      if ph["caption"]
        secs = ph.fetch("caption_seconds", p["caption_seconds"])
        captions << { "text" => ph["caption"], "start" => start.round(4), "end" => (start + secs).round(4) }
      end
      k += ph["beats"]
    end
    slides.each_with_index do |s, i| # fade in centred on the start, stay under the next slide's fade
      nxt = i + 1 < slides.size ? slides[i + 1]["xf"] : 0
      s["vs"] = [0.0, s["start"] - s["xf"] / 2].max.round(4)
      s["ve"] = [duration, s["end"] + nxt / 2.0].min.round(4)
    end
    lyrics = p["lyrics"] ? lyric_track(p["lyrics"]) : []
    endc = p["end"] || {}
    { "duration" => duration, "size" => [w, h], "fps" => p["fps"], "audio" => p.fetch("audio"), "zoom" => p["zoom"],
      "fadeIn" => p["fade_in"], "fadeOut" => p["fade_out"], "slides" => slides, "captions" => captions,
      "lyrics" => lyrics, "lyricSpans" => lyric_spans(lyrics), "endLines" => endc.fetch("lines", []),
      "endSeconds" => endc.fetch("seconds", 6.0), "lastPhotoBeats" => ((duration - slides.last["start"]) / period).round(2),
      "introBeats" => p["intro"].sum { |c| c["beats"] }, "dropBeat" => beats["drop_beat"] }
  end

  # our own lyric text, timed by alignment; a line stays until just before the next one shows
  def lyric_track(path)
    rows = JSON.parse(File.read(path))
    rows.each_with_index do |r, i| # first words not recognised (spoken numbers): start where the previous ended
      next if i.zero? || r.fetch("firstHeard", true)
      gap = r["start"] - rows[i - 1]["end"]
      r["start"] = rows[i - 1]["end"] if gap >= 0 && gap < 1.5
    end
    rows.each_with_index.map do |r, i|
      nxt = i + 1 < rows.size ? rows[i + 1]["start"] : r["end"] + 1.5
      { "text" => r["text"], "show" => (r["start"] - 0.15).round(3), "hide" => [nxt - 0.15, r["end"] + 1.2].min.round(3) }
    end
  end

  def lyric_spans(lyrics, join: 2.0)
    lyrics.each_with_object([]) do |l, spans|
      if !spans.empty? && l["show"] - spans.last[1] < join
        spans.last[1] = l["hide"]
      else
        spans << [l["show"], l["hide"]]
      end
    end
  end

  def check(tl)
    puts "slides #{tl['slides'].size} (intro #{tl['slides'].count { |s| s['kind'] != 'photo' }}), captions #{tl['captions'].size}, " \
         "lyric lines #{tl['lyrics'].size}, duration #{tl['duration'].round(1)} s"
    if tl["dropBeat"] && tl["introBeats"] != tl["dropBeat"]
      puts "note: intro cards take #{tl['introBeats']} beats, the drop is at beat #{tl['dropBeat']}"
    end
    over = tl["lyrics"].each_cons(2).count { |a, b| a["hide"] > b["show"] }
    puts "lyric overlaps: #{over}" if over.positive?
    puts "last photo holds #{tl['lastPhotoBeats']} beats"
    abort("too many beats for the song: give some photos 1 beat or drop near-duplicates") if tl["lastPhotoBeats"] < 4
  end

  # ---------------------------------------------------------------- HTML

  HTML = <<~'HTML'
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>__TITLE__</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
      body { display: flex; align-items: center; justify-content: center;
             font-family: "Avenir Next", "Helvetica Neue", Helvetica, Arial, sans-serif; color: #fff; }
      #stage { position: relative; width: min(100vw, 177.78vh); aspect-ratio: 16 / 9;
               overflow: hidden; background: #000; container-type: size; }
      #slides { position: absolute; inset: 0; isolation: isolate; z-index: 0; }
      .slide { position: absolute; inset: 0; opacity: 0; will-change: opacity; overflow: hidden; }
      .zoom { position: absolute; inset: 0; will-change: transform; }
      .bg { position: absolute; inset: -6%; background-size: cover; background-position: center;
            filter: blur(2.2cqw) brightness(0.5); }
      .fg { position: absolute; left: 50%; top: 50%; max-width: 100%; max-height: 100%; transform: translate(-50%, -50%); }
      .cover { width: 100%; height: 100%; object-fit: cover; max-width: none; max-height: none; }
      .title .shade { position: absolute; inset: 0; background: rgba(0,0,0,.42); }
      .card .bg { filter: blur(2.2cqw) brightness(0.3); }
      .cardimg { position: absolute; top: 45%; left: 30%; transform: translate(-50%, -50%); box-shadow: 0 0 2cqw rgba(0,0,0,.6); }
      .text { position: absolute; text-shadow: 0 0 .6cqw rgba(0,0,0,.85), 0 .1cqw .3cqw rgba(0,0,0,.9);
              line-height: 1.15; pointer-events: none; }
      .center { inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; gap: .9cqw; }
      .cardtext { left: 50%; right: 4%; top: 0; bottom: 0; display: flex; flex-direction: column; justify-content: center; gap: 1.2cqw; }
      .heavy { font-weight: 800; } .demi { font-weight: 600; } .medium { font-weight: 500; } .regular { font-weight: 400; }
      #endtext { opacity: 0; justify-content: flex-start; padding-top: calc(80cqh - 6cqw); z-index: 2; }
      #endtext .dim { position: absolute; inset: 0; z-index: -1;
                      background: linear-gradient(to bottom, rgba(0,0,0,0) 42%, rgba(0,0,0,.7) 82%); }
      #lyricband { position: absolute; z-index: 2; left: 0; right: 0; bottom: 0; height: 8.85cqw; opacity: 0;
                   background: linear-gradient(to bottom, rgba(0,0,0,0), rgba(0,0,0,.5)); pointer-events: none; }
      #lyric { position: absolute; z-index: 3; left: 0; right: 0; bottom: 2.2cqw; text-align: center;
               font-weight: 500; font-size: 1.875cqw; color: rgba(255,255,255,.85); opacity: 0;
               text-shadow: 0 0 .5cqw rgba(0,0,0,.85), 0 .1cqw .25cqw rgba(0,0,0,.9); }
      #caption { position: absolute; z-index: 3; left: 4.7cqw; top: 3.6cqw; font-weight: 600; font-size: 2.7cqw;
                 opacity: 0; text-shadow: 0 0 .6cqw rgba(0,0,0,.85), 0 .1cqw .3cqw rgba(0,0,0,.9); }
      #black { position: absolute; inset: 0; background: #000; pointer-events: none; z-index: 4; }
      #play { position: absolute; inset: 0; display: flex; align-items: flex-end; justify-content: center;
              padding-bottom: 9cqh; box-sizing: border-box; background: rgba(0,0,0,.35); cursor: pointer; z-index: 10; }
      #play span { font-size: 2.4cqw; font-weight: 600; padding: 1.2cqw 2.6cqw; border: .15cqw solid #fff;
                   border-radius: 4cqw; background: rgba(0,0,0,.4); }
      #bar { position: absolute; left: 0; bottom: 0; height: .35cqw; background: rgba(255,255,255,.7); width: 0; z-index: 9; }
      #help { position: absolute; right: 1.5cqw; bottom: 1.2cqw; font-size: 1cqw; opacity: 0; transition: opacity .4s; z-index: 9; }
      #stage.ui #help { opacity: .7; }
    </style>
    </head>
    <body>
    <div id="stage">
      <div id="slides"></div>
      <div id="endtext" class="text center"><div class="dim"></div></div>
      <div id="caption"></div>
      <div id="lyricband"></div>
      <div id="lyric"></div>
      <div id="black"></div>
      <div id="bar"></div>
      <div id="help">space: play/pause &nbsp; &larr;/&rarr;: 5 s &nbsp; f: fullscreen</div>
      <div id="play"><span>&#9654;&nbsp; Play</span></div>
    </div>
    <audio id="audio" preload="auto"></audio>
    <script>
    const TL = __TIMELINE__;
    const $ = id => document.getElementById(id);
    const stage = $('stage'), host = $('slides'), audio = $('audio'), caption = $('caption'), lyric = $('lyric'),
          lyricband = $('lyricband'), endtext = $('endtext'), black = $('black'), bar = $('bar'), playBtn = $('play');
    const u = px => (px / (TL.size[0] / 100)) + 'cqw';           // design pixels -> stage units
    // every path segment percent-encoded, plus the characters encodeURIComponent leaves alone ('()*!): a file name with
    // #, ?, % or an apostrophe must not end the URL or the single-quoted CSS string
    const href = src => src.split('/').map(p => encodeURIComponent(p).replace(/['()*!]/g, ch => '%' + ch.charCodeAt(0).toString(16).toUpperCase())).join('/');
    const url = src => "url('" + href(src) + "')";          // single quotes: the attribute uses double
    audio.src = href(TL.audio);
    const esc = s => s.replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
    const textBlock = lines => lines.map(([t, w, size]) => `<div class="${w}" style="font-size:${u(size)}">${esc(t)}</div>`).join('');
    endtext.insertAdjacentHTML('beforeend', textBlock(TL.endLines));
    const live = new Map();
    function build(i) {
      const s = TL.slides[i];
      const el = document.createElement('div');
      el.className = 'slide ' + s.kind;
      el.style.zIndex = i;
      let inner = `<div class="bg" style="background-image:${url(s.src)}"></div>`;
      if (s.kind === 'card') {
        inner += `<div class="cardimg" style="background-image:${url(s.src)};width:${s.cardW}cqw;height:${s.cardH}cqw;` +
                 `background-size:${s.bgW}cqw auto;background-position:${s.bgX}cqw ${s.bgY}cqw"></div>` +
                 `<div class="text cardtext">${textBlock(s.lines)}</div>`;
      } else {
        inner += `<img class="fg${s.kind === 'title' ? ' cover' : ''}" src="${href(s.src)}" decoding="async">`;
        if (s.kind === 'title') inner += `<div class="shade"></div><div class="text center">${textBlock(s.lines)}</div>`;
      }
      el.innerHTML = `<div class="zoom">${inner}</div>`;   // the whole slide zooms, as in the MP4
      host.appendChild(el);
      return el;
    }
    const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
    const fade = (t, a, b, f) => Math.min(clamp((t - a) / f, 0, 1), clamp((b - t) / f, 0, 1));
    function render(t) {
      const want = new Set();  // visible now plus a few seconds ahead (preload)
      TL.slides.forEach((s, i) => { if (t >= s.vs - 3 && t < s.ve + 0.5) want.add(i); });
      for (const [i, el] of live) if (!want.has(i)) { el.remove(); live.delete(i); }
      for (const i of want) if (!live.has(i)) live.set(i, build(i));
      for (const [i, el] of live) {
        const s = TL.slides[i];
        el.style.opacity = (t >= s.vs && t < s.ve) ? clamp((t - s.vs) / s.xf, 0, 1) : 0;
        const p = clamp((t - s.vs) / (s.ve - s.vs), 0, 1);
        el.firstChild.style.transform = `scale(${1 + TL.zoom * (s.zoom > 0 ? p : 1 - p)})`;
      }
      const c = TL.captions.find(c => t >= c.start && t < c.end);
      caption.style.opacity = c ? fade(t, c.start, c.end, 0.4) : 0;
      if (c && caption.textContent !== c.text) caption.textContent = c.text;
      const ly = TL.lyrics.find(l => t >= l.show && t < l.hide);
      lyric.style.opacity = ly ? fade(t, ly.show, ly.hide, 0.15) : 0;
      if (ly && lyric.textContent !== ly.text) lyric.textContent = ly.text;
      const sp = TL.lyricSpans.find(([a, b]) => t >= a - 0.6 && t < b + 0.6);
      lyricband.style.opacity = sp ? fade(t, sp[0] - 0.6, sp[1] + 0.6, 0.6) : 0;
      endtext.style.opacity = TL.endLines.length ? clamp((t - (TL.duration - TL.endSeconds)) / 1.0, 0, 1) : 0;
      black.style.opacity = Math.max(1 - clamp(t / TL.fadeIn, 0, 1), clamp((t - (TL.duration - TL.fadeOut)) / TL.fadeOut, 0, 1));
      bar.style.width = (100 * t / TL.duration) + '%';
    }
    function loop() { render(audio.currentTime); requestAnimationFrame(loop); }
    function toggle() {
      if (audio.paused) { audio.play(); playBtn.style.display = 'none'; }
      else { audio.pause(); playBtn.style.display = 'flex'; playBtn.firstElementChild.innerHTML = '&#9654;&nbsp; Resume'; }
    }
    playBtn.addEventListener('click', toggle);
    document.addEventListener('keydown', e => {
      if (e.key === ' ') { e.preventDefault(); toggle(); }
      else if (e.key === 'ArrowRight') audio.currentTime = Math.min(TL.duration, audio.currentTime + 5);
      else if (e.key === 'ArrowLeft') audio.currentTime = Math.max(0, audio.currentTime - 5);
      else if (e.key === 'f') (document.fullscreenElement ? document.exitFullscreen() : stage.requestFullscreen());
    });
    audio.addEventListener('ended', () => { playBtn.style.display = 'flex';
      playBtn.firstElementChild.innerHTML = '&#8635;&nbsp; Replay'; audio.currentTime = 0; });
    let hideUi;
    document.addEventListener('mousemove', () => { stage.classList.add('ui'); clearTimeout(hideUi);
      hideUi = setTimeout(() => stage.classList.remove('ui'), 1500); });
    // #t=60 in the URL opens the show paused at that second (for checking a scene, e.g. in headless Chrome)
    const seek = parseFloat((location.hash.match(/t=([\d.]+)/) || [])[1]);
    const t0 = isNaN(seek) ? TL.fadeIn + 0.5 : seek;
    if (!isNaN(seek)) audio.currentTime = seek;
    render(t0);
    audio.addEventListener('play', () => requestAnimationFrame(loop), { once: true });
    </script>
    </body>
    </html>
  HTML

  def relpath(target, dir)
    t = File.expand_path(target).split("/")
    d = File.expand_path(dir).split("/")
    common = t.zip(d).take_while { |a, b| a == b }.size
    ([".."] * (d.size - common) + t[common..]).join("/")
  end

  def write_html(p, tl)
    out = p["out_html"]
    dir = File.dirname(File.expand_path(out))
    page = JSON.parse(JSON.generate(tl)) # paths relative to the HTML file
    page["audio"] = relpath(tl["audio"], dir)
    page["slides"].each { |s| s["src"] = relpath(s["src"], dir) }
    title = p["title"] || File.basename(out, ".*")
    esc = title.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    File.write(out, HTML.sub("__TITLE__") { esc }.sub("__TIMELINE__") { JSON.generate(page).gsub("</", "<\\/") })
    puts "wrote #{out}"
  end

  # ---------------------------------------------------------------- MP4: stills (ImageMagick)

  def im_fonts(p)
    return p["im_fonts"] if p["im_fonts"]
    @im_fonts ||= begin
      have = run!("magick", "-list", "font").scan(/^\s*Font: (\S+)/).flatten
      IM_FONTS.find { |set| set.values.all? { |f| have.include?(f) } } || IM_FONTS.last
    end
  end

  def ass_fonts(p)
    p["ass_fonts"] || ASS_FONTS.find { |k, _| im_fonts(p)["medium"].start_with?(k) }&.last || ASS_FONTS["Helvetica"]
  end

  def im_text(s) = s.gsub("\\", "\\\\\\\\").gsub("%", "%%").sub(/\A@/, "\\@")

  # a block of lines with a soft shadow, as an ImageMagick sub-sequence; align :center or :west
  def text_block_args(p, lines, align)
    gravity = align == :west ? "West" : "Center"
    seq = lines.each_with_index.flat_map do |(t, w, size), i|
      lab = ["-font", im_fonts(p).fetch(w, im_fonts(p)["medium"]), "-pointsize", size.to_s, "label:#{im_text(t)}"]
      i.zero? ? lab : ["(", *lab, "-gravity", "North", "-background", "none", "-splice", "0x18", ")"]
    end
    ["(", "-background", "none", "-fill", "white", "-density", "72", *seq, "-gravity", gravity, "-background", "none", "-append",
     "(", "+clone", "-background", "black", "-shadow", "85x7+0+3", ")", "+swap", "-background", "none", "-layers", "merge", "+repage", ")"]
  end

  def blurred_bg_args(w, h, darken)
    ["(", "+clone", "-resize", "#{w / 8}x#{h / 8}^", "-gravity", "center", "-extent", "#{w / 8}x#{h / 8}", "-blur", "0x4",
     "-resize", "#{w}x#{h}!", "-fill", "black", "-colorize", darken.to_s, ")"]
  end

  def still_args(p, s, out)
    w, h = p["size"]
    # jpeg:size speeds up decoding large photos, but libjpeg may also decode a small image up to 2x larger,
    # which would break the card's crop coordinates (given in original pixels): not used for cards
    src = [*(s["kind"] == "card" ? [] : ["-define", "jpeg:size=#{w * 2}x#{h * 2}"]), s["src"], "-auto-orient"]
    case s["kind"]
    when "title"
      [*src, "-resize", "#{w}x#{h}^", "-gravity", "center", "-extent", "#{w}x#{h}", "-fill", "black", "-colorize", "42",
       *(s["lines"].empty? ? [] : [*text_block_args(p, s["lines"], :center), "-gravity", "center", "-composite"]), "-quality", "93", out]
    when "card"
      x0, y0, x1, y1 = s["crop"]
      ch = (h * 0.84).round
      cw = ((x1 - x0) * ch.to_f / (y1 - y0)).round
      px = (w * 0.30 - cw / 2.0).round
      py = (h * 0.45 - ch / 2.0).round
      # +gravity: the background's `-gravity center` would otherwise make the crop offset count from the centre
      [*src, *blurred_bg_args(w, h, 70), "(", "-clone", "0", "+gravity", "-crop", "#{x1 - x0}x#{y1 - y0}+#{x0}+#{y0}", "+repage",
       "-resize", "#{cw}x#{ch}!", ")", "-delete", "0", "-gravity", "NorthWest", "-geometry", "+#{px}+#{py}", "-composite",
       *(s["lines"].empty? ? [] : [*text_block_args(p, s["lines"], :west), "-gravity", "West", "-geometry", "+#{w / 2}+0", "-composite"]),
       "-quality", "93", out]
    else
      [*src, *blurred_bg_args(w, h, 50), "(", "-clone", "0", "-resize", "#{w}x#{h}", ")", "-delete", "0",
       "-gravity", "center", "-composite", "-quality", "93", out]
    end
  end

  def key(*parts) = Digest::SHA256.hexdigest(JSON.generate(parts))[0, 12]

  def parallel(items, workers)
    q = Queue.new
    items.each { |i| q << i }
    errors = Queue.new
    Array.new([workers, 1].max) do
      Thread.new do
        until q.empty?
          item = begin
            q.pop(true)
          rescue ThreadError
            break
          end
          begin
            yield item
          rescue SystemExit, StandardError => e
            errors << e
          end
        end
      end
    end.each(&:join)
    raise errors.pop unless errors.empty?
  end

  def make_stills(p, tl)
    FileUtils.mkdir_p(p["work_dir"])
    # cache key = the exact ImageMagick command + the source's mtime, so a change in how stills are made rebuilds them
    tl["slides"].each_with_index do |s, i|
      s["still"] = File.join(p["work_dir"], format("still_%04d_%s.jpg", i, key(still_args(p, s, "OUT"), File.mtime(s["src"]).to_f)))
    end
    todo = tl["slides"].reject { |s| File.exist?(s["still"]) }
    parallel(todo, Etc.nprocessors - 1) { |s| run!("magick", *still_args(p, s, s["still"])) }
  end

  # ---------------------------------------------------------------- MP4: subtitles (ASS / libass)

  def ass_time(t)
    t = [t, 0.0].max
    cs = (t * 100).round
    format("%d:%02d:%02d.%02d", cs / 360_000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
  end

  def ass_text(s) = s.tr("{}", "()").gsub("\\", "/")

  def stacked_shade(w, top, bottom, layers, total_alpha)
    q = 1 - (1 - total_alpha)**(1.0 / layers) # each layer's opacity so that the stack reaches total_alpha
    a = format("%02X", (255 * (1 - q)).round)
    (0...layers).map do |i|
      y = (top + (bottom - top) * i / layers.to_f).round
      "{\\an7\\pos(0,#{y})\\1a&H#{a}&\\blur18\\p1}m 0 0 l #{w} 0 #{w} #{bottom - y + 40} 0 #{bottom - y + 40}{\\p0}"
    end
  end

  def write_ass(p, tl)
    w, h = p["size"]
    f = ass_fonts(p)
    sc = w / 1920.0
    sz = ->(px) { (px * sc * ASS_SCALE).round }
    lines = []
    lines << "[Script Info]" << "ScriptType: v4.00+" << "PlayResX: #{w}" << "PlayResY: #{h}" << "WrapStyle: 2" << "ScaledBorderAndShadow: yes" << ""
    lines << "[V4+ Styles]"
    lines << "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, " \
             "StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
    lines << "Style: Lyric,#{f['medium']},#{sz.(36)},&H26FFFFFF,&H26FFFFFF,&H70000000,&H70000000,0,0,0,0,100,100,0,0,1,#{(2 * sc).round(1)},#{(1.5 * sc).round(1)},2,0,0,#{(46 * sc).round},1"
    lines << "Style: Caption,#{f['demi']},#{sz.(52)},&H00FFFFFF,&H00FFFFFF,&H60000000,&H60000000,0,0,0,0,100,100,0,0,1,#{(2.5 * sc).round(1)},#{(2 * sc).round(1)},7,#{(90 * sc).round},0,#{(70 * sc).round},1"
    lines << "Style: Shade,#{f['regular']},20,&H00000000,&H00000000,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1"
    lines << "Style: End,#{f['demi']},#{sz.(52)},&H00FFFFFF,&H00FFFFFF,&H60000000,&H60000000,0,0,0,0,100,100,0,0,1,#{(2.5 * sc).round(1)},#{(2 * sc).round(1)},8,0,0,0,1"
    lines << "" << "[Events]" << "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
    ev = ->(layer, a, b, style, text) { lines << "Dialogue: #{layer},#{ass_time(a)},#{ass_time(b)},#{style},,0,0,0,,#{text}" }
    tl["lyricSpans"].each do |a, b| # faint band under the lyrics while singing
      stacked_shade(w, h - (170 * sc).round, h, 5, 0.5).each { |d| ev.(0, a - 0.6, b + 0.6, "Shade", "{\\fad(600,600)}#{d}") }
    end
    tl["lyrics"].each { |l| ev.(2, l["show"], l["hide"], "Lyric", "{\\fad(150,150)\\blur3}#{ass_text(l['text'])}") }
    tl["captions"].each { |c| ev.(2, c["start"], c["end"], "Caption", "{\\fad(400,400)\\blur4}#{ass_text(c['text'])}") }
    unless tl["endLines"].empty? # closing text in the bottom third, darkening only the lower part (faces stay visible)
      e0 = tl["duration"] - tl["endSeconds"]
      stacked_shade(w, (h * 0.42).round, h, 6, 0.7).each { |d| ev.(1, e0, tl["duration"] + 1, "Shade", "{\\fad(1000,0)}#{d}") }
      heights = tl["endLines"].map { |_, _, s| (s * sc * 1.2).round }
      y = (h * 0.80 - (heights.sum + 18 * sc * (heights.size - 1)) / 2.0).round
      tl["endLines"].each_with_index do |(t, wt, s), i|
        ev.(3, e0, tl["duration"] + 1, "End", "{\\fad(1000,0)\\blur4\\an8\\pos(#{w / 2},#{y})\\fn#{f.fetch(wt, f['demi'])}\\fs#{sz.(s)}}#{ass_text(t)}")
        y += heights[i] + (18 * sc).round
      end
    end
    path = File.join(p["work_dir"], "subs.ass")
    File.write(path, lines.join("\n") + "\n")
    path
  end

  # ---------------------------------------------------------------- MP4: segments (ffmpeg)

  # zoom about the frame centre, evaluated per frame (sub-pixel): source quad that fills the output
  def zoom_filter(s, f0, fps, zoom)
    prog = "clip(((#{f0}+in)/#{fps}-#{s['vs']})/#{(s['ve'] - s['vs']).round(6)},0,1)"
    z = s["zoom"].positive? ? "(1+#{zoom}*#{prog})" : "(1+#{zoom}*(1-#{prog}))"
    xa, xb, ya, yb = "W/2-W/2/#{z}", "W/2+W/2/#{z}", "H/2-H/2/#{z}", "H/2+H/2/#{z}"
    "perspective=x0='#{xa}':y0='#{ya}':x1='#{xb}':y1='#{ya}':x2='#{xa}':y2='#{yb}':x3='#{xb}':y3='#{yb}':interpolation=cubic:eval=frame"
  end

  def segment_cmd(p, tl, k, f0, n, out)
    fps = tl["fps"]
    t0 = f0.to_f / fps
    top = tl["slides"][k]
    inputs = []
    chains = []
    shift = "setpts=PTS+#{t0}/TB"
    if k.positive?
      under = tl["slides"][k - 1]
      inputs += ["-loop", "1", "-framerate", fps.to_s, "-t", ((n + 2).to_f / fps).to_s, "-i", under["still"]]
      chains << "[0:v]#{zoom_filter(under, f0, fps, tl['zoom'])},format=yuv420p,#{shift}[u]"
    end
    i = k.positive? ? 1 : 0
    inputs += ["-loop", "1", "-framerate", fps.to_s, "-t", ((n + 2).to_f / fps).to_s, "-i", top["still"]]
    if k.positive?
      chains << "[#{i}:v]#{zoom_filter(top, f0, fps, tl['zoom'])},format=yuva420p,#{shift},fade=t=in:st=#{top['vs']}:d=#{top['xf']}:alpha=1[t]"
      chains << "[u][t]overlay=eof_action=pass,format=yuv420p[m]"
    else
      chains << "[#{i}:v]#{zoom_filter(top, f0, fps, tl['zoom'])},format=yuv420p,#{shift}[m]"
    end
    d = tl["duration"]
    chains << "[m]subtitles=subs.ass,fade=t=in:st=0:d=#{tl['fadeIn']},fade=t=out:st=#{(d - tl['fadeOut']).round(4)}:d=#{tl['fadeOut']}," \
              "setpts=PTS-STARTPTS,format=yuv420p[v]"
    ["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", chains.join(";"), "-map", "[v]", "-frames:v", n.to_s,
     *(out.end_with?(".mp4") ? ["-c:v", "libx264", "-preset", "medium", "-crf", p["crf"].to_s, "-pix_fmt", "yuv420p", "-r", fps.to_s] : ["-q:v", "3"]),
     out]
  end

  def segment_bounds(tl)
    fps = tl["fps"]
    total = (tl["duration"] * fps).round
    starts = tl["slides"].each_with_index.map { |s, i| i.zero? ? 0 : (s["vs"] * fps).round }
    starts.each_with_index.map { |f, i| [f, (i + 1 < starts.size ? starts[i + 1] : total) - f] }
  end

  def write_mp4(p, tl)
    make_stills(p, tl)
    ass = write_ass(p, tl)
    ass_key = Digest::SHA256.file(ass).hexdigest[0, 12]
    segs = segment_bounds(tl).each_with_index.map do |(f0, n), k|
      out = File.join(p["work_dir"], format("seg_%04d.mp4", k))
      cmd = segment_cmd(p, tl, k, f0, n, out)
      tag = "#{out}.#{key(cmd, ass_key)}"
      [k, cmd, out, tag]
    end
    todo = segs.reject { |_, _, out, tag| File.exist?(out) && File.exist?(tag) }
    puts "slides #{segs.size}, segments to render #{todo.size} (others unchanged)"
    done = 0
    lock = Mutex.new
    parallel(todo, [Etc.nprocessors / 2, 2].max) do |_k, cmd, out, tag|
      Dir.glob("#{File.basename(out)}.*", base: File.dirname(out)).each { |f| File.delete(File.join(File.dirname(out), f)) }
      run!(*cmd, chdir: p["work_dir"])
      File.write(tag, "")
      lock.synchronize { done += 1; puts "  #{done}/#{todo.size}" if (done % 20).zero? || done == todo.size }
    end
    list = File.join(p["work_dir"], "segments.txt")
    File.write(list, segs.map { |_, _, out, _| "file '#{File.basename(out)}'" }.join("\n") + "\n")
    run!("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-i", tl["audio"], "-map", "0:v", "-map", "1:a",
         "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", p["out_mp4"])
    puts "wrote #{p['out_mp4']}"
  end

  def write_frames(p, tl, times)
    make_stills(p, tl)
    write_ass(p, tl)
    dir = p["frames_dir"] ? File.expand_path(p["frames_dir"], p["_base"]) : File.join(p["_base"], "frames")
    FileUtils.mkdir_p(dir)
    bounds = segment_bounds(tl)
    times.each do |t|
      f = (t * tl["fps"]).round
      k = bounds.rindex { |f0, _| f0 <= f } || 0
      out = File.join(dir, "frame_#{t}.jpg")
      run!(*segment_cmd(p, tl, k, f, 1, out), chdir: p["work_dir"])
      puts "saved #{out}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  doc = File.read(__FILE__).lines.drop(3).take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  abort(doc) if ARGV.size < 2
  p = Slideshow.load_project(ARGV[0])
  tl = Slideshow.timeline(p)
  case ARGV[1]
  when "check" then Slideshow.check(tl)
  when "html" then Slideshow.check(tl); Slideshow.write_html(p, tl)
  when "mp4" then Slideshow.check(tl); Slideshow.write_mp4(p, tl)
  when "frames" then Slideshow.write_frames(p, tl, ARGV[2..].map(&:to_f))
  else abort("unknown command #{ARGV[1].inspect}\n#{doc}")
  end
end
