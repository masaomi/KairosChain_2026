#!/usr/bin/env ruby
# frozen_string_literal: true

# Copy the photos (and videos) shared in one WhatsApp chat on given days, with readable names.
# WhatsApp Desktop for macOS only. Read-only: the chat database is copied to a temporary directory,
# queried there with the sqlite3 command, and the copy (which holds message text) is deleted on exit.
#
#   ruby whatsapp_media.rb list [NAME_PATTERN]
#   ruby whatsapp_media.rb copy --chat "Walkers" --date 2026-06-14 [--to-date 2026-06-15] \
#        --dest ~/Pictures/walk_2026-06-14 [--videos] [--dry-run]
#
# Files are named YYYY-MM-DD_HH-MM-SS_NNN.ext (local send time + running number), so sorting by name gives
# chat order. Send time is not capture time: each sender's batch can arrive newest-first or oldest-first.
# Media never downloaded on this Mac has no file; it is counted and listed, not copied.
# Refuses to write into a non-empty destination. Do not make other copies of the database to inspect it:
# `list` and `copy --dry-run` show what is there, and their copy is removed when they exit.
#
# Schema used (WhatsApp Desktop, 2026): ZWACHATSESSION(Z_PK, ZPARTNERNAME, ZCONTACTJID) ->
# ZWAMESSAGE(ZCHATSESSION, ZMESSAGEDATE [s since 2001-01-01], ZMESSAGETYPE [1 image, 2 video], ZMEDIAITEM) ->
# ZWAMEDIAITEM(ZMEDIALOCALPATH, relative to <container>/Message/, ZFILESIZE).
# Requires: Ruby (stdlib only) and the sqlite3 command (ships with macOS; needs -json, sqlite >= 3.33).

require "date"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "date"
require "time"
require "tmpdir"

CONTAINER = File.expand_path("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
EPOCH = 978_307_200 # 2001-01-01 in Unix time

def with_db_copy
  src = File.join(CONTAINER, "ChatStorage.sqlite")
  abort("WhatsApp database not found at #{src} (WhatsApp Desktop for macOS required)") unless File.exist?(src)
  Dir.mktmpdir("wa_db_") do |tmp| # removed with everything inside when the block ends
    # the -wal / -shm files hold recent messages; WhatsApp may write between the three copies, so copy until the
    # set did not change while it was being copied (quitting WhatsApp first makes this certain)
    stamp = -> { Dir.glob("#{src}*").sort.map { |f| [f, File.size(f), File.mtime(f).to_f] } }
    stable = false
    5.times do
      before = stamp.call
      Dir.glob("#{src}*").each { |f| FileUtils.cp(f, tmp) }
      break if (stable = stamp.call == before)
      sleep 1
    end
    abort("the WhatsApp database kept changing while it was copied; quit WhatsApp and run again") unless stable
    yield File.join(tmp, "ChatStorage.sqlite")
  end
end

def query(db, sql)
  out, err, st = Open3.capture3("sqlite3", "-json", "-readonly", db, sql)
  abort("sqlite3 failed: #{err}") unless st.success?
  out.strip.empty? ? [] : JSON.parse(out)
end

def quote(s) = "'#{s.gsub("'", "''")}'"

def cmd_list(db, pattern)
  sql = <<~SQL
    SELECT s.ZPARTNERNAME AS name, s.ZCONTACTJID AS jid, COUNT(m.Z_PK) AS n, MAX(m.ZMESSAGEDATE) AS last
    FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK AND m.ZMESSAGETYPE IN (1, 2)
    WHERE s.ZPARTNERNAME LIKE #{quote("%#{pattern}%")} GROUP BY s.Z_PK ORDER BY last DESC;
  SQL
  query(db, sql).each do |r|
    last = r["last"] ? Time.at(r["last"] + EPOCH).strftime("%Y-%m-%d") : "-"
    kind = r["jid"].to_s.end_with?("@g.us") ? "group" : "1:1"   # the id itself is a phone number for 1:1 chats: not printed
    puts format("%6d media  last %s  %-5s  %s", r["n"], last, kind, r["name"])
  end
end

def cmd_copy(db, o)
  chats = query(db, "SELECT Z_PK AS pk, ZPARTNERNAME AS name FROM ZWACHATSESSION WHERE ZPARTNERNAME LIKE #{quote("%#{o[:chat]}%")};")
  abort("chat pattern matched #{chats.size} chats: #{chats.first(10).map { |c| c['name'] }} — be more specific") unless chats.size == 1
  chat = chats.first
  day = ->(s) { Date.iso8601(s) rescue abort("bad date #{s.inspect} (YYYY-MM-DD)") }
  first = day.(o[:date])
  last = day.(o[:to_date] || o[:date])
  d0 = Time.local(first.year, first.month, first.day)
  nxt = last + 1                                     # the next local midnight: a calendar day, not 86,400 s (DST days)
  d1 = Time.local(nxt.year, nxt.month, nxt.day)
  types = o[:videos] ? "1, 2" : "1"
  sql = <<~SQL
    SELECT m.ZMESSAGEDATE AS ts, m.ZMESSAGETYPE AS type, mi.ZMEDIALOCALPATH AS path, mi.ZFILESIZE AS size
    FROM ZWAMESSAGE m JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
    WHERE m.ZCHATSESSION = #{chat['pk'].to_i} AND m.ZMESSAGETYPE IN (#{types})
      AND m.ZMESSAGEDATE >= #{d0.to_f - EPOCH} AND m.ZMESSAGEDATE < #{d1.to_f - EPOCH}
    ORDER BY m.ZMESSAGEDATE, m.Z_PK;
  SQL
  media = query(db, sql)
  dest = File.expand_path(o[:dest])
  unless o[:dry_run]
    abort("#{dest} is not empty; choose a new folder (nothing is overwritten)") if Dir.exist?(dest) && !Dir.empty?(dest)
    FileUtils.mkdir_p(dest)
  end
  copied = 0
  absent = []
  media.each.with_index(1) do |m, n|
    t = Time.at(m["ts"] + EPOCH)
    src = m["path"] && File.join(CONTAINER, "Message", m["path"])
    unless src && File.exist?(src)
      absent << [t, m["type"] == 2 ? "video" : "image", m["size"].to_i]
      next
    end
    ext = File.extname(m["path"]).downcase
    ext = m["type"] == 2 ? ".mp4" : ".jpg" if ext.empty?
    FileUtils.cp(src, File.join(dest, format("%s_%03d%s", t.strftime("%Y-%m-%d_%H-%M-%S"), n, ext)), preserve: true) unless o[:dry_run]
    copied += 1
  end
  puts "chat: #{chat['name']}"
  puts "media in range: #{media.size} | #{o[:dry_run] ? 'would copy' : 'copied'}: #{copied} | not downloaded on this Mac: #{absent.size}"
  absent.each do |t, kind, size|
    puts format("  missing %s sent %s (%.1f MB): open it in WhatsApp once, then rerun into a new folder",
                kind, t.strftime("%Y-%m-%d %H:%M:%S"), size / 1e6)
  end
end

cmd = ARGV.shift
o = {}
case cmd
when "list"
  with_db_copy { |db| cmd_list(db, ARGV.shift.to_s) }
when "copy"
  OptionParser.new do |op|
    op.on("--chat NAME") { |v| o[:chat] = v }
    op.on("--date YYYY-MM-DD") { |v| o[:date] = v }
    op.on("--to-date YYYY-MM-DD") { |v| o[:to_date] = v }
    op.on("--dest DIR") { |v| o[:dest] = v }
    op.on("--videos") { o[:videos] = true }
    op.on("--dry-run") { o[:dry_run] = true }
  end.parse!
  abort("copy needs --chat, --date and --dest") unless o[:chat] && o[:date] && o[:dest]
  with_db_copy { |db| cmd_copy(db, o) }
else
  abort(File.read(__FILE__).lines.drop(3).take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join)
end
