# Render a rich, self-contained HTML report from a combined match_report(.md) +
# nomic_results.json. Tables/prose are embedded (complete without JS); figures
# use Chart.js (CDN). No LLM calls. Language is taken from the markdown (which
# may be localized); chart titles + UI chrome are localized via <lang>.
#
# Usage:
#   ruby build_html_report.rb <match_report.md> <nomic_results.json> <output.html> [lang]
#   lang: en (default) | ja

require "json"

md_path    = ARGV[0] or abort "usage: build_html_report.rb <md> <nomic_json> <out.html> [lang]"
nomic_path = ARGV[1]
out_path   = ARGV[2] or abort "missing output path"
lang       = (ARGV[3] || "en").downcase
md = File.read(md_path)

UI = {
  "en" => { title: "LLM Cross-Evaluation — Combined Report",
            lead: "Task run (2026-05-30) + Minimum Nomic run (2026-05-31), merged. Figures are interactive (Chart.js); all underlying tables are embedded below.",
            figs: "Figures", nojs: "Figures require JavaScript / network access to Chart.js. The full data tables below are complete without them.",
            t_standing: "Overall Standing (combined, Nomic-weighted)", t_nomic: "Minimum Nomic: performance by player",
            t_levels: "Proposal level distribution (object / meta / frame)", t_l1: "Layer 1 weighted score by task",
            t_meta: "Meta-Recognition (composite + sub-signals)",
            d_overall: "Nomic Overall (×10)", d_adopt: "Adoption rate (×10)", d_tom: "ToM accuracy (×10)",
            d_tom2: "Other-recognition (ToM)", d_cal: "Self-calibration", d_lim: "Limitation recognition", d_self: "Self-applicability", d_comp: "Composite" },
  "ja" => { title: "LLM 相互評価 — 統合レポート",
            lead: "タスク実行（2026-05-30）＋ Minimum Nomic 実行（2026-05-31）を統合。図はインタラクティブ（Chart.js）。下部に全データ表を埋め込み済み。",
            figs: "図", nojs: "図の表示には JavaScript / Chart.js への接続が必要です。下のデータ表は図がなくても完全です。",
            t_standing: "総合順位（統合・Nomic 重み込み）", t_nomic: "Minimum Nomic: プレイヤー別パフォーマンス",
            t_levels: "提案レベル分布（object / meta / frame）", t_l1: "タスク別 Layer 1 加重スコア",
            t_meta: "メタ認知（合成＋下位信号）",
            d_overall: "Nomic 総合 (×10)", d_adopt: "採択率 (×10)", d_tom: "ToM 精度 (×10)",
            d_tom2: "他者認識 (ToM)", d_cal: "自己較正", d_lim: "限界認識", d_self: "自己適用", d_comp: "合成" },
}[lang] or abort "unknown lang: #{lang}"

# ── Parse markdown into ordered blocks; capture tables with h2/h3 context ──
lines = md.split("\n")
tables = []; blocks = []
h2 = h3 = nil; i = 0; md_buf = []
flush_md = -> { (blocks << { type: :md, text: md_buf.join("\n") }) unless md_buf.empty?; md_buf = [] }
while i < lines.length
  line = lines[i]
  h2 = line[3..].strip if line.start_with?("## ") && !line.start_with?("###")
  h3 = line[4..].strip if line.start_with?("### ")
  if line.strip.start_with?("|") && lines[i + 1].to_s.strip.match?(/^\|[\s:|-]+\|$/)
    flush_md.call
    header = line.split("|").map(&:strip).reject(&:empty?)
    j = i + 2; rows = []
    while j < lines.length && lines[j].strip.start_with?("|")
      rows << lines[j].split("|").map(&:strip).reject(&:empty?); j += 1
    end
    tables << { h2: h2, h3: h3, header: header, rows: rows }
    blocks << { type: :table, ref: tables.length - 1 }
    i = j; next
  end
  md_buf << line; i += 1
end
flush_md.call

# Table headers stay English even in the ja report, so we locate tables by their
# English column names / task ids — language-robust.
def tcol(t, i)  # extract a column by position, tolerant of "**" emphasis
  t[:rows].map { |r| r[i].to_s.delete("*").to_f }
end

PALETTE = ["#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#b07aa1", "#76b7b2"]

# Locate by heading (language-robust), extract by column position (headers may be localized).
standing = tables.find { |t| t[:h2].to_s.match?(/Overall Standing|総合順位/) }
standing_data = standing && {
  labels: standing[:rows].map { |r| r[1] },
  l1: tcol(standing, 2), l2: tcol(standing, 3),
  cal: tcol(standing, 4), nomic: tcol(standing, 5), combined: tcol(standing, 6),
}

# Meta-Recognition table: locate by section heading (en or ja); columns by position
mr = tables.find { |t| t[:h2].to_s.match?(/Meta-Recognition|メタ認知/) }
mr_data = mr && {
  labels: mr[:rows].map { |r| r[1] },
  tom: mr[:rows].map { |r| r[2].to_f }, cal: mr[:rows].map { |r| r[3].to_f },
  lim: mr[:rows].map { |r| r[4].to_f }, self_: mr[:rows].map { |r| r[5].to_f },
  comp: mr[:rows].map { |r| r[6].delete("*").to_f },
}

# Per-task Layer 1 (table header has "Criterion"; h2 holds the task id)
l1_tables = tables.select { |t| t[:header].any? { |h| h =~ /Criterion|基準/ } }
l1_chart = nil
unless l1_tables.empty?
  task_labels = l1_tables.map { |t| t[:h2].to_s.sub(/^(Task:|タスク:)\s*/, "") }
  models = l1_tables.first[:rows].map { |r| r[0] }
  l1_chart = { tasks: task_labels,
               series: models.each_with_index.map { |m, mi| { label: m, data: l1_tables.map { |t| (t[:rows][mi]&.last).to_f } } } }
end

# Nomic + levels from JSON (language-independent)
nomic = nomic_path && File.exist?(nomic_path) ? JSON.parse(File.read(nomic_path)) : nil
nomic_chart = levels_chart = nil
if nomic
  keys = nomic["scores"].keys
  labels = keys.map { |k| k.sub("claude_opus48", "Opus 4.8").sub("claude_opus47", "Opus 4.7").sub("claude_opus46", "Opus 4.6").sub("codex_gpt55", "Codex 5.5").sub("cursor_composer2", "Cursor 2.5") }
  nomic_chart = { labels: labels,
    overall: keys.map { |k| (nomic["scores"][k]["overall"] * 10).round(2) },
    adoption: keys.map { |k| (nomic["scores"][k]["adoption_rate"] * 10).round(2) },
    tom: keys.map { |k| (nomic["scores"][k]["tom_raw_accuracy"] * 10).round(2) } }
  lv = nomic["history"].group_by { |h| h["proposal_level"] }.transform_values(&:size)
  levels_chart = { data: %w[object meta frame].map { |l| lv[l] || 0 } }
end

# ── Markdown → HTML ──
def esc(s) = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
def inline(s) = esc(s).gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>').gsub(/`(.+?)`/, '<code>\1</code>')
def md_to_html(text)
  out = []; list_open = false; quote_open = false
  close_quote = -> { (out << "</blockquote>"; quote_open = false) if quote_open }
  text.split("\n").each do |ln|
    s = ln.strip
    if s.empty? then (out << "</ul>"; list_open = false) if list_open; close_quote.call; next end
    if s.start_with?("> ")
      (out << "<blockquote>"; quote_open = true) unless quote_open
      out << "<p>#{inline(s[2..])}</p>"; next
    elsif quote_open then close_quote.call end
    if s.start_with?("- ")
      (out << "<ul>"; list_open = true) unless list_open
      out << "<li>#{inline(s[2..])}</li>"; next
    elsif list_open then out << "</ul>"; list_open = false end
    if s == "---" then out << "<hr>"
    elsif s.start_with?("### ") then out << "<h3>#{inline(s[4..])}</h3>"
    elsif s.start_with?("## ") then out << "<h2>#{inline(s[3..])}</h2>"
    elsif s.start_with?("# ") then out << "<h1>#{inline(s[2..])}</h1>"
    else out << "<p>#{inline(s)}</p>" end
  end
  out << "</ul>" if list_open
  out << "</blockquote>" if quote_open
  out.join("\n")
end
def table_html(t)
  hdr = t[:header].map { |h| "<th>#{inline(h)}</th>" }.join
  body = t[:rows].map { |r| "<tr>" + r.each_with_index.map { |c, ci| ci.zero? ? "<th scope=\"row\">#{inline(c)}</th>" : "<td>#{inline(c)}</td>" }.join + "</tr>" }.join("\n")
  "<div class=\"tbl-wrap\"><table><thead><tr>#{hdr}</tr></thead><tbody>#{body}</tbody></table></div>"
end
body_html = blocks.map { |b| b[:type] == :table ? table_html(tables[b[:ref]]) : md_to_html(b[:text]) }.join("\n")

# ── Charts ──
def js(o) = JSON.generate(o)
charts = []
charts << <<~JS if standing_data
  new Chart(document.getElementById('c_standing'),{type:'bar',data:{labels:#{js(standing_data[:labels])},datasets:[
    {label:'Response (L1)',data:#{js(standing_data[:l1])},backgroundColor:'#{PALETTE[0]}'},
    {label:'Evaluator (L2)',data:#{js(standing_data[:l2])},backgroundColor:'#{PALETTE[1]}'},
    {label:'Calibration',data:#{js(standing_data[:cal])},backgroundColor:'#{PALETTE[2]}'},
    {label:'Nomic',data:#{js(standing_data[:nomic])},backgroundColor:'#{PALETTE[3]}'},
    {label:'Combined',data:#{js(standing_data[:combined])},backgroundColor:'#{PALETTE[4]}'}]},
    options:{responsive:true,scales:{y:{beginAtZero:true,max:10}},plugins:{title:{display:true,text:#{js(UI[:t_standing])}}}}});
JS
charts << <<~JS if mr_data
  new Chart(document.getElementById('c_meta'),{type:'bar',data:{labels:#{js(mr_data[:labels])},datasets:[
    {label:#{js(UI[:d_tom2])},data:#{js(mr_data[:tom])},backgroundColor:'#{PALETTE[0]}'},
    {label:#{js(UI[:d_cal])},data:#{js(mr_data[:cal])},backgroundColor:'#{PALETTE[1]}'},
    {label:#{js(UI[:d_lim])},data:#{js(mr_data[:lim])},backgroundColor:'#{PALETTE[2]}'},
    {label:#{js(UI[:d_self])},data:#{js(mr_data[:self_])},backgroundColor:'#{PALETTE[5]}'},
    {label:#{js(UI[:d_comp])},data:#{js(mr_data[:comp])},backgroundColor:'#{PALETTE[4]}'}]},
    options:{responsive:true,scales:{y:{beginAtZero:true,max:10}},plugins:{title:{display:true,text:#{js(UI[:t_meta])}}}}});
JS
charts << <<~JS if nomic_chart
  new Chart(document.getElementById('c_nomic'),{type:'bar',data:{labels:#{js(nomic_chart[:labels])},datasets:[
    {label:#{js(UI[:d_overall])},data:#{js(nomic_chart[:overall])},backgroundColor:'#{PALETTE[0]}'},
    {label:#{js(UI[:d_adopt])},data:#{js(nomic_chart[:adoption])},backgroundColor:'#{PALETTE[1]}'},
    {label:#{js(UI[:d_tom])},data:#{js(nomic_chart[:tom])},backgroundColor:'#{PALETTE[2]}'}]},
    options:{responsive:true,scales:{y:{beginAtZero:true,max:10}},plugins:{title:{display:true,text:#{js(UI[:t_nomic])}}}}});
JS
charts << <<~JS if levels_chart
  new Chart(document.getElementById('c_levels'),{type:'doughnut',data:{labels:['object','meta','frame'],datasets:[
    {data:#{js(levels_chart[:data])},backgroundColor:['#{PALETTE[2]}','#{PALETTE[1]}','#{PALETTE[3]}']}]},
    options:{responsive:true,plugins:{title:{display:true,text:#{js(UI[:t_levels])}}}}});
JS
charts << <<~JS if l1_chart
  new Chart(document.getElementById('c_l1'),{type:'bar',data:{labels:#{js(l1_chart[:tasks])},datasets:#{js(l1_chart[:series].each_with_index.map { |s, idx| { label: s[:label], data: s[:data], backgroundColor: PALETTE[idx % PALETTE.size] } })}},
    options:{responsive:true,scales:{y:{beginAtZero:true,max:10}},plugins:{title:{display:true,text:#{js(UI[:t_l1])}}}}});
JS

canvas = ->(id) { "<div class=\"chart-card\"><canvas id=\"#{id}\"></canvas></div>" }
figs = []
figs << canvas.call("c_standing") if standing_data
figs << canvas.call("c_meta")     if mr_data
figs << canvas.call("c_nomic")    if nomic_chart
figs << canvas.call("c_levels")   if levels_chart
figs << canvas.call("c_l1")       if l1_chart

html = <<~HTML
  <!DOCTYPE html>
  <html lang="#{lang}"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>#{UI[:title]}</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
  <style>
    :root{--bg:#fafafa;--fg:#1d1d1f;--muted:#6e6e73;--line:#e0e0e0;--accent:#4e79a7;}
    *{box-sizing:border-box;}
    body{font-family:-apple-system,"Helvetica Neue","Hiragino Sans",system-ui,sans-serif;color:var(--fg);background:var(--bg);margin:0;line-height:1.65;}
    main{max-width:1080px;margin:0 auto;padding:2rem 1.5rem 5rem;}
    h1{font-size:1.9rem;border-bottom:3px solid var(--accent);padding-bottom:.4rem;}
    h2{font-size:1.4rem;margin-top:2.4rem;border-bottom:1px solid var(--line);padding-bottom:.3rem;}
    h3{font-size:1.1rem;margin-top:1.6rem;color:#333;}
    code{background:#eee;padding:.1em .35em;border-radius:4px;font-size:.9em;}
    hr{border:none;border-top:1px solid var(--line);margin:2rem 0;}
    .tbl-wrap{overflow-x:auto;margin:1rem 0;}
    table{border-collapse:collapse;width:100%;font-size:.92rem;background:#fff;}
    th,td{border:1px solid var(--line);padding:.45rem .6rem;text-align:right;}
    th[scope="row"],thead th:first-child{text-align:left;}
    thead th{background:#f0f3f7;position:sticky;top:0;}
    tbody tr:nth-child(even){background:#f7f9fb;}
    .dashboard{display:grid;grid-template-columns:repeat(auto-fit,minmax(440px,1fr));gap:1.2rem;margin:1.5rem 0;}
    .chart-card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:1rem;box-shadow:0 1px 3px rgba(0,0,0,.05);}
    .lead{color:var(--muted);font-size:.95rem;} .nojs{color:#a00;font-size:.85rem;}
    blockquote{margin:.8rem 0;padding:.7rem 1rem;background:#eef3f9;border-left:4px solid var(--accent);border-radius:4px;font-size:.93rem;color:#33415c;}
    blockquote p{margin:.2rem 0;}
  </style></head>
  <body><main>
  <h1>#{UI[:title]}</h1>
  <p class="lead">#{UI[:lead]}</p>
  <h2>#{UI[:figs]}</h2>
  <p class="nojs">#{UI[:nojs]}</p>
  <div class="dashboard">
  #{figs.join("\n")}
  </div>
  #{body_html}
  </main>
  <script>
  document.addEventListener('DOMContentLoaded',function(){if(typeof Chart==='undefined')return;
  #{charts.join("\n")}
  });
  </script>
  </body></html>
HTML

File.write(out_path, html)
puts "=== #{lang.upcase} HTML written: #{out_path} (#{html.bytesize} bytes, #{figs.size} figures) ==="
