#!/usr/bin/env ruby
# frozen_string_literal: true

# Render an MV page (assets/mv/mv_template.html + mv_engine.js + scenes.js) frame by frame in headless Chrome and
# encode it, so the MP4 is exactly what the browser preview shows.
#
#   ruby mv_render.rb stills mv.html 12 60.5 229            # frames/frame_<t, 2 decimals>.jpg, to look at single moments
#   ruby mv_render.rb sheet  mv.html 4                      # frames/sheet.jpg: one still every 4 s, 6 per row
#   ruby mv_render.rb mp4    mv.html --audio song.mp3 --out mv.mp4 [--from 0 --to 314.4] [--light]
#        [--keep-outside 218,223]
#
# mp4 renders 20-second segments into render_work/<key>/ and reuses a segment that already exists there, so an
# interrupted run resumes. The key covers mv.html, mv_engine.js, scenes.js, assets/data.js and the size and time of
# every file under assets/, so editing the page or re-making the pictures starts afresh.
# --keep-outside A,B: you state that only A..B seconds changed; segments not touching A..B are copied from the
# render that produced the last finished MP4. Wrong if the edit reaches further (a crossfade, a moved cut) — then omit it.
# --light also writes <out>_1080p.mp4 (crf 22) and <out>_720p.mp4 (crf 24): grain makes the master large
# (a 5-minute master was 1.7 GB; the light copies were 495 MB and 68 MB).
#
# Talks to Chrome over the DevTools protocol through the small WebSocket client below (Ruby stdlib has none).
# Requires: Ruby (stdlib only; no bundled gems such as base64), Google Chrome (or --chrome PATH / $CHROME), ffmpeg, ImageMagick for `sheet`.

require "json"
require "socket"
require "net/http"
require "securerandom"
require "digest"
require "fileutils"
require "tmpdir"
require "open3"
require "optparse"

CHROME_DEFAULT = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

class MiniWebSocket # RFC 6455 client: text frames out (masked), text/continuation/ping/close in
  READ_TIMEOUT = 120 # seconds without any data from Chrome before giving up (a frame normally takes < 1 s)

  def initialize(url)
    m = url.match(%r{\Aws://([^/:]+):(\d+)(/.*)\z}) or raise "bad ws url #{url}"
    @s = TCPSocket.new(m[1], m[2].to_i)
    key = [SecureRandom.random_bytes(16)].pack("m0")
    @s.write("GET #{m[3]} HTTP/1.1\r\nHost: #{m[1]}:#{m[2]}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
             "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    head = +""
    head << read_exact(1) until head.end_with?("\r\n\r\n")
    raise "websocket handshake failed: #{head.lines.first}" unless head.start_with?("HTTP/1.1 101")
  end

  def send_text(str) = frame(0x1, str.b)

  def frame(op, data)
    hdr = [0x80 | op].pack("C")
    n = data.bytesize
    hdr << (n < 126 ? [0x80 | n].pack("C") : n < 65_536 ? [0x80 | 126, n].pack("Cn") : [0x80 | 127, n].pack("CQ>"))
    mask = SecureRandom.random_bytes(4)
    mb = mask.bytes
    body = data.bytes.each_with_index.map { |b, i| b ^ mb[i & 3] }.pack("C*")
    @s.write(hdr + mask + body)
  end

  def read_exact(n)
    buf = +"".b
    while buf.bytesize < n
      raise "Chrome stopped answering (no data for #{READ_TIMEOUT} s)" unless IO.select([@s], nil, nil, READ_TIMEOUT)
      chunk = @s.read_nonblock(n - buf.bytesize, exception: false)
      next if chunk == :wait_readable
      raise "websocket closed by Chrome" if chunk.nil?
      buf << chunk
    end
    buf
  end

  def recv
    msg = +"".b
    loop do
      b0, b1 = read_exact(2).unpack("CC")
      op = b0 & 0x0f
      n = b1 & 0x7f
      n = read_exact(2).unpack1("n") if n == 126
      n = read_exact(8).unpack1("Q>") if n == 127
      payload = n.positive? ? read_exact(n) : +"".b
      case op
      when 0x9 then frame(0xA, payload); next
      when 0x8 then raise "websocket closed by Chrome"
      when 0xA then next
      end
      msg << payload
      return msg.force_encoding("UTF-8") if (b0 & 0x80) != 0
    end
  end

  def close = @s.close
end

class Chrome
  def initialize(page_path, chrome)
    @prof = Dir.mktmpdir("mv_chrome_")
    # port 0: Chrome picks a free port and writes it to DevToolsActivePort, so we never talk to someone else's browser
    @pid = spawn(chrome, "--headless=new", "--remote-debugging-port=0", "--window-size=1920,1080", "--hide-scrollbars",
                 "--mute-audio", "--allow-file-access-from-files", "--autoplay-policy=no-user-gesture-required",
                 "--force-device-scale-factor=1", "--user-data-dir=#{@prof}", "about:blank", %i[out err] => File::NULL)
    start(page_path, chrome)
  rescue Exception # rubocop:disable Lint/RescueException -- also Ctrl-C: never leave a headless Chrome behind
    close
    raise
  end

  def start(page_path, chrome)
    port_file = File.join(@prof, "DevToolsActivePort")
    100.times { break if File.size?(port_file); sleep 0.15 }
    @port = File.size?(port_file) ? File.read(port_file).lines.first.to_i : 0
    raise "Chrome did not start (#{chrome})" unless @port.positive?
    list = nil
    100.times do
      list = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{@port}/json/list"))) rescue nil
      break if list&.any? { |x| x["type"] == "page" }
      sleep 0.15
    end
    page = list&.find { |x| x["type"] == "page" } or raise "Chrome did not open a page (#{chrome})"
    @ws = MiniWebSocket.new(page["webSocketDebuggerUrl"])
    @id = 0
    call("Page.enable"); call("Runtime.enable")
    call("Emulation.setDeviceMetricsOverride", width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false)
    call("Page.navigate", url: "#{file_url(File.expand_path(page_path))}?render=1")
    v = nil
    600.times do
      v = eval_js("window.__ready === true ? 'ok' : (document.getElementById('load')||{}).textContent")
      break if v == "ok"
      raise "page error: #{v}" if v.to_s.start_with?("error")
      sleep 0.2
    end
    raise "page did not finish loading in 120 s (it says: #{v.inspect}); a missing or unreadable file in assets/?" unless v == "ok"
  end

  def call(method, **params)
    id = (@id += 1)
    @ws.send_text(JSON.generate(id: id, method: method, params: params))
    loop do
      m = JSON.parse(@ws.recv)
      next unless m["id"] == id
      raise "#{method}: #{m['error']}" if m["error"]
      return m["result"]
    end
  end

  def eval_js(expr, await: false)
    r = call("Runtime.evaluate", expression: expr, awaitPromise: await, returnByValue: true)
    raise "page exception: #{r['exceptionDetails'].to_s[0, 600]}" if r["exceptionDetails"]
    r.dig("result", "value")
  end

  def frame(t, n)
    eval_js("window.renderFrame(#{t}, #{n})", await: true)
    call("Page.captureScreenshot", format: "jpeg", quality: 93,
                                                   clip: { x: 0, y: 0, width: 1920, height: 1080, scale: 1 })["data"].unpack1("m")
  end

  # each path segment percent-encoded: a "#", "?" or "%" in a folder name must stay part of the path
  def file_url(path)
    "file://" + path.split("/", -1).map { |seg| seg.b.gsub(/[^A-Za-z0-9._~-]/n) { |c| format("%%%02X", c.ord) } }.join("/")
  end

  def close
    @ws&.close rescue nil
    if @pid
      Process.kill("TERM", @pid) rescue nil
      50.times { break if (Process.wait(@pid, Process::WNOHANG) rescue true); sleep 0.1 }   # up to 5 s, then force
      (Process.kill("KILL", @pid) rescue nil) && (Process.wait(@pid) rescue nil) if (Process.kill(0, @pid) rescue false)
    end
    FileUtils.rm_rf(@prof)
  end
end

def run!(*cmd, **opts)
  _, err, st = Open3.capture3(*cmd, **opts)
  abort("#{cmd.first} failed: #{err[-800..] || err}") unless st.success?
end

mode, page = ARGV.shift(2)
abort("usage: ruby mv_render.rb stills|sheet|mp4 mv.html ...") unless %w[stills sheet mp4].include?(mode) && page && File.exist?(page)
o = { fps: 30, from: 0.0, out: "mv.mp4", chrome: ENV["CHROME"] || CHROME_DEFAULT }
OptionParser.new do |op|
  op.on("--audio PATH") { |v| o[:audio] = v }
  op.on("--out PATH") { |v| o[:out] = v }
  op.on("--from SEC", Float) { |v| o[:from] = v }
  op.on("--to SEC", Float) { |v| o[:to] = v }
  op.on("--fps N", Integer) { |v| o[:fps] = v }
  op.on("--light") { o[:light] = true }
  op.on("--keep-outside A,B") { |v| o[:keep] = v.split(",").map(&:to_f) }
  op.on("--chrome PATH") { |v| o[:chrome] = v }
  op.on("--frames DIR", "where stills and the sheet go (default frames/ beside the page)") { |v| o[:frames] = v }
end.parse!
root = File.dirname(File.expand_path(page))
frames_dir = o[:frames] ? File.expand_path(o[:frames]) : File.join(root, "frames")

case mode
when "stills", "sheet"
  FileUtils.mkdir_p(frames_dir)
  ch = Chrome.new(page, o[:chrome])   # cleans up after itself if it cannot start
  begin
    times = if mode == "stills" then ARGV.map(&:to_f)
            else
              step = (ARGV[0] || 4).to_f
              dur = ch.eval_js("window.MV_DURATION || 0").to_f
              (0...(dur / step).floor).map { |i| (i * step + step / 2).round(1) }
            end
    files = times.map do |t|
      f = File.join(frames_dir, format("frame_%.2f.jpg", t))
      File.binwrite(f, ch.frame(t, (t * o[:fps]).round))
      puts "wrote #{f.sub("#{root}/", '')}" if mode == "stills"
      f
    end
    if mode == "sheet"
      out = File.join(frames_dir, "sheet.jpg")
      run!("magick", "montage", "-label", "%t", *files, "-geometry", "480x270+3+3", "-tile", "6x", "-pointsize", "14", out)
      puts "wrote #{out.sub("#{root}/", '')} (#{files.size} stills)"
    end
  ensure
    ch.close
  end
when "mp4"
  abort("--audio is required for mp4") unless o[:audio] && File.exist?(o[:audio])
  dur = Open3.capture3("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", o[:audio]).first.to_f
  abort("could not read the length of #{o[:audio]}") unless dur.positive?
  to = o[:to] || dur
  key = Digest::SHA1.new
  key << "fps=#{o[:fps]};"   # segment names count frames, so frames of another rate must never be reused
  %w[mv_engine.js scenes.js assets/data.js].map { |f| File.join(root, f) }.unshift(File.expand_path(page))
                                         .each { |f| key << File.binread(f) if File.exist?(f) }
  adir = File.join(root, "assets")   # base: keeps glob characters in the project path from being read as a pattern
  Dir.glob("**/*", base: adir).sort.map { |r| File.join(adir, r) }.each { |f| key << "#{f}:#{File.size(f)}:#{File.mtime(f).to_f}" if File.file?(f) }
  base = File.join(root, "render_work")
  work = File.join(base, key.hexdigest[0, 12])
  FileUtils.mkdir_p(work)
  seg = 20 * o[:fps]
  n0 = (o[:from] * o[:fps]).round
  n1 = (to * o[:fps]).round
  segments = (n0 / seg...((n1 + seg - 1) / seg)).map { |s| [[n0, s * seg].max, [n1, (s + 1) * seg].min, s] }
  if o[:keep]
    # copy only from the render that made the MP4 now on disk; "newest folder" would bring back a reverted edit
    last = File.join(base, "last_output.txt")
    prev = File.exist?(last) && File.join(base, File.read(last).strip)
    abort("--keep-outside needs an earlier finished render to copy from; render once without it") unless prev && File.directory?(prev)
    a, b = o[:keep].map { |x| (x * o[:fps]).round }
    segments.each do |s0, s1, s|
      name = format("seg_%03d_%d_%d.mp4", s, s0, s1)
      src = prev && File.join(prev, name)
      FileUtils.cp(src, File.join(work, name)) if src && File.exist?(src) && (s1 <= a || s0 >= b) && !File.exist?(File.join(work, name))
    end
  end
  ch = nil
  started = Time.now
  begin
    segments.each do |s0, s1, s|
      file = File.join(work, format("seg_%03d_%d_%d.mp4", s, s0, s1))
      next puts("reuse #{File.basename(file)}") if File.exist?(file) && File.size(file) > 1000
      ch ||= Chrome.new(page, o[:chrome])
      part = "#{file}.part.mp4"
      IO.popen(["ffmpeg", "-v", "error", "-y", "-f", "image2pipe", "-framerate", o[:fps].to_s, "-c:v", "mjpeg", "-i", "-",
                "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", "-r", o[:fps].to_s, part], "wb") do |io|
        (s0...s1).each { |n| io.write(ch.frame(n.to_f / o[:fps], n)) }
      end
      abort("ffmpeg failed on segment #{s}") unless $?.success?
      File.rename(part, file)
      puts format("segment %d (frames %d-%d) done, %.0f s elapsed", s, s0, s1, Time.now - started)
    end
  ensure
    ch&.close
  end
  list = File.join(work, "list.txt")
  # names relative to the list file: an absolute path would break on an apostrophe in the project path
  File.write(list, segments.map { |s0, s1, s| "file '#{format('seg_%03d_%d_%d.mp4', s, s0, s1)}'\n" }.join)
  out = File.expand_path(o[:out])   # relative to where you run it, like --audio
  # run inside the work folder with the list named relatively: ffmpeg resolves the names in a list against the list's
  # path read as a URL, so a "#" or "?" in the project path would cut it
  run!("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", "list.txt", "-ss", o[:from].to_s, "-t", (to - o[:from]).to_s,
       "-i", File.expand_path(o[:audio]), "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-shortest",
       "-movflags", "+faststart", out, chdir: work)
  # only a whole-song render can be copied from later; a trial stretch (--from/--to) would leave nothing to reuse
  File.write(File.join(base, "last_output.txt"), File.basename(work)) if o[:from].zero? && to >= dur - 0.01
  puts "wrote #{out} (#{(File.size(out) / 1e6).round} MB)"
  if o[:light]
    stem = out.sub(/\.mp4\z/, "")
    run!("ffmpeg", "-v", "error", "-y", "-i", out, "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-pix_fmt", "yuv420p",
         "-c:a", "copy", "-movflags", "+faststart", "#{stem}_1080p.mp4")
    run!("ffmpeg", "-v", "error", "-y", "-i", out, "-vf", "scale=1280:720:flags=lanczos", "-c:v", "libx264", "-preset", "slow",
         "-crf", "24", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "#{stem}_720p.mp4")
    %w[_1080p _720p].each { |x| puts "wrote #{stem}#{x}.mp4 (#{(File.size("#{stem}#{x}.mp4") / 1e6).round} MB)" }
  end
end
