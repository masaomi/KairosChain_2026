# Render a rich, self-contained HTML report from a combined match_report.md +
# nomic_results.json. Tables are embedded (complete without JS); figures use
# Chart.js (CDN) for interactivity. No LLM calls.
#
# Usage:
#   ruby build_html_report.rb <match_report.md> <nomic_results.json> <output.html>

require "json"

md_path    = ARGV[0] or abort "usage: build_html_report.rb <md> <nomic_json> <out.html>"
nomic_path = ARGV[1]
out_path   = ARGV[2] or abort "missing output path"
md = File.read(md_path)

# ── Parse markdown into blocks, tracking the nearest h2/h3 context per table ──
lines = md.split("\n")
tables = []   # {h2:, h3:, header:[], rows:[[..]]}
blocks = []   # ordered: {type: :md, text:} or {type: :table, ref: <tables idx>}
h2 = h3 = nil
i = 0
md_buf = []
flush_md = -> { (blocks << { type: :md, text: md_buf.join("\n") }) unless md_buf.empty?; md_buf = [] }

while i < lines.length
  line = lines[i]
  if line.start_with?("## ")  && !line.start_with?("###") then h2 = line[3..].strip end
  if line.start_with?("### ") then h3 = line[4..].strip end

  # Table block: a line of "|...|" followed by a separator row of dashes
  if line.strip.start_with?("|") && lines[i + 1].to_s.strip.match?(/^\|[\s:|-]+\|$/)
    flush_md.call
    header = line.split("|").map(&:strip).reject(&:empty?)
    j = i + 2
    rows = []
    while j < lines.length && lines[j].strip.start_with?("|")
      rows << lines[j].split("|").map(&:strip).reject(&:empty?)
      j += 1
    end
    tables << { h2: h2, h3: h3, header: header, rows: rows }
    blocks << { type: :table, ref: tables.length - 1 }
    i = j
    next
  end
  md_buf << line
  i += 1
end
flush_md.call

def find_table(tables, h2_substr: nil, h3_substr: nil, header_substr: nil)
  tables.find do |t|
    (h2_substr.nil?     || t[:h2].to_s.include?(h2_substr)) &&
      (h3_substr.nil?     || t[:h3].to_s.include?(h3_substr)) &&
      (header_substr.nil? || t[:header].any? { |h| h.include?(header_substr) })
  end
end

# ── Chart data extraction ──
PALETTE = ["#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#b07aa1", "#76b7b2"]

standing = find_table(tables, h2_substr: "Overall Standing")
standing_models = standing ? standing[:rows].map { |r| r[1] } : []
def col(table, name)
  idx = table[:header].index { |h| h.include?(name) }
  return [] unless idx
  table[:rows].map { |r| r[idx].to_f }
end
standing_data = standing ? {
  labels: standing_models,
  l1: col(standing, "Response"), l2: col(standing, "Evaluator"),
  cal: col(standing, "Calibration"), nomic: col(standing, "Nomic"),
  combined: col(standing, "Combined"),
} : nil

# Nomic from JSON (richer than the table)
nomic = nomic_path && File.exist?(nomic_path) ? JSON.parse(File.read(nomic_path)) : nil
nomic_chart = nil
levels_chart = nil
if nomic
  keys = nomic["scores"].keys
  labels = keys.map { |k| k.gsub("claude_opus", "Opus 4.").sub("48", "8").sub("47", "7").sub("46", "6").gsub("codex_gpt55", "Codex 5.5").gsub("cursor_composer2", "Cursor 2.5") }
  nomic_chart = {
    labels: labels,
    overall:  keys.map { |k| (nomic["scores"][k]["overall"] * 10).round(2) },
    adoption: keys.map { |k| (nomic["scores"][k]["adoption_rate"] * 10).round(2) },
    tom:      keys.map { |k| (nomic["scores"][k]["tom_raw_accuracy"] * 10).round(2) },
  }
  lv = nomic["history"].group_by { |h| h["proposal_level"] }.transform_values(&:size)
  levels_chart = { labels: %w[object meta frame], data: %w[object meta frame].map { |l| lv[l] || 0 } }
end

# Per-task Layer 1 weighted (one series per model, grouped by task)
l1_tables = tables.select { |t| t[:h2].to_s.start_with?("Task:") && t[:h3].to_s.start_with?("Response Scores") }
l1_chart = nil
unless l1_tables.empty?
  task_labels = l1_tables.map { |t| t[:h2].sub("Task:", "").strip }
  models = l1_tables.first[:rows].map { |r| r[0] }
  series = models.each_with_index.map do |m, mi|
    { label: m, data: l1_tables.map { |t| (t[:rows][mi] && t[:rows][mi].last).to_f } }
  end
  l1_chart = { tasks: task_labels, series: series }
end

# ── Markdown → HTML (headings, bold, lists, hr, paragraphs) ──
def esc(s) = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
def inline(s) = esc(s).gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>').gsub(/`(.+?)`/, '<code>\1</code>')

def md_to_html(text)
  out = []
  list_open = false
  text.split("\n").each do |ln|
    s = ln.strip
    if s.empty?
      (out << "</ul>"; list_open = false) if list_open
      next
    end
    if s.start_with?("- ")
      (out << "<ul>"; list_open = true) unless list_open
      out << "<li>#{inline(s[2..])}</li>"
      next
    elsif list_open
      out << "</ul>"; list_open = false
    end
    if s == "---" then out << "<hr>"
    elsif s.start_with?("### ") then out << "<h3>#{inline(s[4..])}</h3>"
    elsif s.start_with?("## ")  then out << "<h2>#{inline(s[3..])}</h2>"
    elsif s.start_with?("# ")   then out << "<h1>#{inline(s[2..])}</h1>"
    else out << "<p>#{inline(s)}</p>"
    end
  end
  out << "</ul>" if list_open
  out.join("\n")
end

def table_html(t)
  hdr = t[:header].map { |h| "<th>#{inline(h)}</th>" }.join
  body = t[:rows].map do |r|
    "<tr>" + r.each_with_index.map { |c, ci| ci.zero? ? "<th scope=\"row\">#{inline(c)}</th>" : "<td>#{inline(c)}</td>" }.join + "</tr>"
  end.join("\n")
  "<div class=\"tbl-wrap\"><table><thead><tr>#{hdr}</tr></thead><tbody>#{body}</tbody></table></div>"
end

body_html = blocks.map do |b|
  b[:type] == :table ? table_html(tables[b[:ref]]) : md_to_html(b[:text])
end.join("\n")

# ── Assemble HTML ──
def js(o) = JSON.generate(o)
charts_js = []
charts_js << <<~JS if standing_data
  new Chart(document.getElementById('c_standing'), {
    type: 'bar',
    data: { labels: #{js(standing_data[:labels])}, datasets: [
      { label: 'Response (L1)', data: #{js(standing_data[:l1])}, backgroundColor: '#{PALETTE[0]}' },
      { label: 'Evaluator (L2)', data: #{js(standing_data[:l2])}, backgroundColor: '#{PALETTE[1]}' },
      { label: 'Calibration', data: #{js(standing_data[:cal])}, backgroundColor: '#{PALETTE[2]}' },
      { label: 'Nomic', data: #{js(standing_data[:nomic])}, backgroundColor: '#{PALETTE[3]}' },
      { label: 'Combined', data: #{js(standing_data[:combined])}, backgroundColor: '#{PALETTE[4]}' } ] },
    options: { responsive: true, scales: { y: { beginAtZero: true, max: 10 } },
      plugins: { title: { display: true, text: 'Overall Standing (combined, Nomic-weighted)' } } }
  });
JS
charts_js << <<~JS if nomic_chart
  new Chart(document.getElementById('c_nomic'), {
    type: 'bar',
    data: { labels: #{js(nomic_chart[:labels])}, datasets: [
      { label: 'Nomic Overall (×10)', data: #{js(nomic_chart[:overall])}, backgroundColor: '#{PALETTE[0]}' },
      { label: 'Adoption rate (×10)', data: #{js(nomic_chart[:adoption])}, backgroundColor: '#{PALETTE[1]}' },
      { label: 'ToM accuracy (×10)', data: #{js(nomic_chart[:tom])}, backgroundColor: '#{PALETTE[2]}' } ] },
    options: { responsive: true, scales: { y: { beginAtZero: true, max: 10 } },
      plugins: { title: { display: true, text: 'Minimum Nomic: performance by player' } } }
  });
JS
charts_js << <<~JS if levels_chart
  new Chart(document.getElementById('c_levels'), {
    type: 'doughnut',
    data: { labels: #{js(levels_chart[:labels])}, datasets: [
      { data: #{js(levels_chart[:data])}, backgroundColor: ['#{PALETTE[2]}', '#{PALETTE[1]}', '#{PALETTE[3]}'] } ] },
    options: { responsive: true,
      plugins: { title: { display: true, text: 'Proposal level distribution (object / meta / frame)' } } }
  });
JS
charts_js << <<~JS if l1_chart
  new Chart(document.getElementById('c_l1'), {
    type: 'bar',
    data: { labels: #{js(l1_chart[:tasks])}, datasets: #{js(l1_chart[:series].each_with_index.map { |s, idx| { label: s[:label], data: s[:data], backgroundColor: PALETTE[idx % PALETTE.size] } })} },
    options: { responsive: true, scales: { y: { beginAtZero: true, max: 10 } },
      plugins: { title: { display: true, text: 'Layer 1 weighted score by task' } } }
  });
JS

canvas = ->(id) { "<div class=\"chart-card\"><canvas id=\"#{id}\"></canvas></div>" }
figures = []
figures << canvas.call("c_standing") if standing_data
figures << canvas.call("c_nomic")    if nomic_chart
figures << canvas.call("c_levels")   if levels_chart
figures << canvas.call("c_l1")       if l1_chart

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LLM Cross-Evaluation — Combined Report</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
  <style>
    :root { --bg:#fafafa; --fg:#1d1d1f; --muted:#6e6e73; --line:#e0e0e0; --accent:#4e79a7; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, "Helvetica Neue", "Hiragino Sans", system-ui, sans-serif;
      color: var(--fg); background: var(--bg); margin: 0; line-height: 1.65; }
    main { max-width: 1080px; margin: 0 auto; padding: 2rem 1.5rem 5rem; }
    h1 { font-size: 1.9rem; border-bottom: 3px solid var(--accent); padding-bottom: .4rem; }
    h2 { font-size: 1.4rem; margin-top: 2.4rem; border-bottom: 1px solid var(--line); padding-bottom: .3rem; }
    h3 { font-size: 1.1rem; margin-top: 1.6rem; color: #333; }
    code { background:#eee; padding:.1em .35em; border-radius:4px; font-size:.9em; }
    hr { border: none; border-top: 1px solid var(--line); margin: 2rem 0; }
    .tbl-wrap { overflow-x: auto; margin: 1rem 0; }
    table { border-collapse: collapse; width: 100%; font-size: .92rem; background:#fff; }
    th, td { border: 1px solid var(--line); padding: .45rem .6rem; text-align: right; }
    th[scope="row"], thead th:first-child { text-align: left; }
    thead th { background: #f0f3f7; position: sticky; top: 0; }
    tbody tr:nth-child(even) { background: #f7f9fb; }
    .dashboard { display: grid; grid-template-columns: repeat(auto-fit, minmax(440px, 1fr)); gap: 1.2rem; margin: 1.5rem 0; }
    .chart-card { background:#fff; border:1px solid var(--line); border-radius:10px; padding:1rem; box-shadow:0 1px 3px rgba(0,0,0,.05); }
    .lead { color: var(--muted); font-size: .95rem; }
    .nojs { color:#a00; font-size:.85rem; }
  </style></head>
  <body><main>
  <h1>LLM Cross-Evaluation — Combined Report</h1>
  <p class="lead">Task run (2026-05-30) + Minimum Nomic run (2026-05-31), merged. Figures are interactive (Chart.js); all underlying tables are embedded below.</p>
  <h2>Figures</h2>
  <p class="nojs">Figures require JavaScript / network access to Chart.js. The full data tables below are complete without them.</p>
  <div class="dashboard">
  #{figures.join("\n")}
  </div>
  #{body_html}
  </main>
  <script>
  document.addEventListener('DOMContentLoaded', function() {
    if (typeof Chart === 'undefined') return;
    #{charts_js.join("\n")}
  });
  </script>
  </body></html>
HTML

File.write(out_path, html)
puts "=== HTML report written: #{out_path} (#{html.bytesize} bytes, #{figures.size} figures) ==="
