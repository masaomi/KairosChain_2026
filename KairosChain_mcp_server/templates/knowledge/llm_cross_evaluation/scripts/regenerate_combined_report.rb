# Build a COMBINED match_report from a prior task run + a separate Nomic run,
# with NO LLM calls. Adds a Meta-Recognition section (synthesised from existing
# data) and emits a localized report (en | ja).
#
# Usage:
#   ruby regenerate_combined_report.rb <task_dir> <nomic_results.json> <output_dir> <tasks> <models> [lang]
#   lang: en (default) | ja   -> writes match_report.md | match_report_ja.md

require_relative "run_cross_eval"

task_dir   = ARGV[0] or abort "usage: <task_dir> <nomic_json> <output_dir> <tasks> <models> [lang]"
nomic_path = ARGV[1] or abort "missing nomic_results.json path"
output_dir = ARGV[2] or abort "missing output_dir"
task_ids   = (ARGV[3] || "").split(",")
model_keys = (ARGV[4] || "").split(",")
lang       = (ARGV[5] || "en").downcase
abort "no tasks"  if task_ids.empty?
abort "no models" if model_keys.empty?
require "fileutils"
FileUtils.mkdir_p(output_dir)

def deep_symbolize(obj)
  case obj
  when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
  when Array then obj.map { |e| deep_symbolize(e) }
  else obj
  end
end

# ── Load task layers ──
all_results = {}
tasks = []
task_ids.each do |task_id|
  path = File.join(task_dir, "results_#{task_id}.json")
  (warn "  [SKIP] missing #{path}"; next) unless File.exist?(path)
  data = JSON.parse(File.read(path)).transform_keys(&:to_sym)
  data[:calibration] = data[:calibration].transform_values { |v| deep_symbolize(v) } if data[:calibration].is_a?(Hash)
  data[:bias]        = data[:bias].transform_values { |v| deep_symbolize(v) }        if data[:bias].is_a?(Hash)
  data[:task] = TaskLoader.load(task_id)
  all_results[task_id] = data
  tasks << data[:task]
end
abort "no task results loaded" if all_results.empty?

# ── Load Nomic layer ──
nomic_raw    = JSON.parse(File.read(nomic_path))
nomic_scores = nomic_raw["scores"].transform_values { |v| deep_symbolize(v) }
nomic_data = {
  scores:   nomic_scores,
  history:  Array(nomic_raw["history"]).map { |h| h.transform_keys(&:to_sym) },
  postgame: nomic_raw["postgame"],
}

# ── Base (English) report from the canonical generator ──
report_path = ReportGenerator.generate(
  output_dir, tasks, model_keys, all_results,
  nomic_scores: nomic_scores, nomic_data: nomic_data,
  incompleteness: nil, limits: nil
)
base_md = File.read(report_path)

# ── Meta-Recognition synthesis (no LLM calls) ──
def avg_criterion(all_results, task_id, evaluated, criterion, model_keys)
  l1 = all_results.dig(task_id, :layer1) or return nil
  vals = model_keys.reject { |e| e == evaluated }
                   .map { |e| l1.dig(e, evaluated, "scores", criterion) }.compact
  vals.empty? ? nil : (vals.sum.to_f / vals.size)
end

def avg_abs_cal_error(all_results, evaluated)
  errs = all_results.values.map { |d| d.dig(:calibration, evaluated, :abs_calibration_error) }
                    .compact.map(&:to_f)
  errs.empty? ? nil : (errs.sum / errs.size)
end

PHIL = "kairoschain_philosophy"
metarec = model_keys.map do |k|
  tom   = (nomic_scores.dig(k, :tom_raw_accuracy) || 0).to_f * 10.0
  cerr  = avg_abs_cal_error(all_results, k)
  calsc = cerr.nil? ? nil : [10.0 - cerr, 0].max
  limit = avg_criterion(all_results, PHIL, k, "limitation_recognition", model_keys)
  selfa = avg_criterion(all_results, PHIL, k, "self_applicability_organic", model_keys)
  parts = [tom, calsc, limit, selfa].compact
  composite = parts.empty? ? nil : (parts.sum / parts.size)
  { key: k, tom: tom, cerr: cerr, calsc: calsc, limit: limit, selfa: selfa, composite: composite }
end.sort_by { |m| -(m[:composite] || 0) }

# Localized strings ----------------------------------------------------------
STR = {
  "en" => {
    mr_h: "Meta-Recognition (synthesised — no extra LLM calls)",
    mr_intro: "Recognition of minds (own and others'), synthesised from existing signals. Composite is the mean of the available sub-signals (0–10). Calibration uses the legacy self-vs-peer error (INV-2 answer-key calibration not yet wired), so treat it as provisional.",
    mr_cols: "| # | Model | Other-recognition (ToM) | Self-calibration | Limitation recognition | Self-applicability | Composite |",
    mr_note: "**Frame self-classification (qualitative):** all five models correctly classified their own Nomic level as *meta, not frame* — i.e. self-assessment of cognitive level was accurate across the board, even though the frame ceiling itself was uniform.",
    mr_legend: "Other-recognition = Nomic vote-prediction accuracy ×10. Self-calibration = 10 − mean |self−peer| error (lower error → higher). Limitation recognition / Self-applicability = peer-averaged philosophy-task criteria.",
  },
  "ja" => {
    mr_h: "メタ認知能力（既存データから合成 — 追加 LLM コールなし）",
    mr_intro: "自他の「心・状態」の認識力を、既存の信号から合成したもの。合成値は利用可能な下位信号の平均（0〜10）。較正は旧方式の self対peer 誤差（INV-2 の answer-key 較正は未配線）なので暫定値として扱うこと。",
    mr_cols: "| # | モデル | 他者認識 (ToM) | 自己較正 | 限界認識 | 自己適用 | 合成 |",
    mr_note: "**frame 自己分類（定性）:** 5モデルすべてが自分の Nomic レベルを *meta であり frame ではない* と正しく分類した。つまり frame 天井自体は一様だったが、自分の認知レベルの自己評価は全員正確だった。",
    mr_legend: "他者認識 = Nomic 投票予測精度 ×10。自己較正 = 10 −（平均 |self−peer| 誤差）（誤差が小さいほど高い）。限界認識 / 自己適用 = 哲学タスク基準の peer 平均。",
  },
}[lang] or abort "unknown lang: #{lang}"

fmt = ->(v) { v.nil? ? "–" : v.round(2).to_s }
mr_rows = metarec.each_with_index.map do |m, i|
  "| #{i + 1} | #{MODELS[m[:key]][:label]} | #{fmt.call(m[:tom])} | #{fmt.call(m[:calsc])} | " \
    "#{fmt.call(m[:limit])} | #{fmt.call(m[:selfa])} | **#{fmt.call(m[:composite])}** |"
end

meta_section = +"\n---\n## #{STR[:mr_h]}\n\n#{STR[:mr_intro]}\n\n"
meta_section << STR[:mr_cols] << "\n" << ("|----" * 7) << "|\n"
meta_section << mr_rows.join("\n") << "\n\n"
meta_section << STR[:mr_legend] << "\n\n" << STR[:mr_note] << "\n"

# ── Provenance / limits (localized) ──
prov = {
  "en" => <<~MD,

    ---
    ## Run Provenance & Limits (combined report)

    This report merges two separate runs (NOT one synchronized run).

    | Layer | Source | Date |
    |----|----|----|
    | Tasks (Layer 0.5/1/2, bias, Layer D) | `#{task_dir}` | 2026-05-30 |
    | Nomic (Layer 2 self-reference) | `#{nomic_path}` | 2026-05-31 |

    - **Codex GPT-5.5**: Nomic run pins `model_reasoning_effort="medium"`; the task run relied on the global config (medium, but unverified at run time).
    - **Cursor**: task run used `composer-2.5-fast` (default); Nomic run used `composer-2.5` (current). The standing therefore blends two Cursor variants. No effort control either run.
    - Opus 4.8/4.7/4.6 are medium in both runs.
    - Overall Standing uses the Nomic-weighted formula `0.40·L1 + 0.25·L2 + 0.15·Calib + 0.20·Nomic` (differs from the task-only report; ranking shifts are expected).
  MD
  "ja" => <<~MD,

    ---
    ## 実行の出自と限界（統合レポート）

    本レポートは別々の2回の実行を統合したもの（同期した単一実行ではない）。

    | 層 | 出典 | 日付 |
    |----|----|----|
    | タスク (Layer 0.5/1/2, bias, Layer D) | `#{task_dir}` | 2026-05-30 |
    | Nomic (Layer 2 自己言及) | `#{nomic_path}` | 2026-05-31 |

    - **Codex GPT-5.5**: Nomic 実行は `model_reasoning_effort="medium"` を pin。タスク実行は global config 依存（medium だが実行時点は未検証）。
    - **Cursor**: タスク実行は `composer-2.5-fast`（既定）、Nomic 実行は `composer-2.5`（current）。よって順位表は Cursor だけ2変種が混在。両実行とも effort 制御なし。
    - Opus 4.8/4.7/4.6 は両実行とも medium。
    - Overall Standing は Nomic 重み込みの式 `0.40·L1 + 0.25·L2 + 0.15·Calib + 0.20·Nomic`（タスクのみ版と異なり、順位変動は想定内）。

    **注（日本語版の範囲）:** 見出し・要約文・本セクションは日本語化。表の列見出しと各モデルの自己内省テキスト（一次データ）は原文のまま。
  MD
}[lang]

# ── Localize the base report's section headings + static prose (ja only) ──
def localize_ja(md)
  repl = {
    "## Executive Summary" => "## 要約",
    "### Model Configuration" => "### モデル構成",
    "## Task: " => "## タスク: ",
    "### Self-Calibration (Layer 0.5 Metacognition)" => "### 自己較正（Layer 0.5 メタ認知）",
    "### Response Scores (Layer 1 Cross-Evaluation)" => "### 応答スコア（Layer 1 相互評価）",
    "### Response Scores (Layer 1 — Philosophy Criteria)" => "### 応答スコア（Layer 1 — 哲学基準）",
    "### Evaluator Reliability (Layer 2 Meta-Evaluation)" => "### 評価者信頼性（Layer 2 メタ評価）",
    "### Evaluator Philosophical Depth (Layer 2 — Philosophy)" => "### 評価者の哲学的深度（Layer 2 — 哲学）",
    "### Concordance Matrix (who rated whom)" => "### 一致度マトリクス（誰が誰を採点したか）",
    "### Concordance Divergence Analysis (Philosophy)" => "### 一致度の乖離分析（哲学）",
    "### Evaluator Self-Notes (Bias Awareness)" => "### 評価者の自己注記（バイアス自覚）",
    "### Bias Analysis" => "### バイアス分析",
    "## Minimum Nomic Game Results" => "## Minimum Nomic ゲーム結果",
    "### Proposal Level Distribution" => "### 提案レベル分布",
    "### Post-Game Meta-Reflections (Frame Transcendence)" => "### 試合後メタ内省（frame 超越）",
    "## Overall Standing" => "## 総合順位",
    "## Framework Incompleteness (Prop 6 — This Run)" => "## 枠組みの不完全性（命題6 — 今回の実行）",
    "# LLM Cross-Evaluation Match Report" => "# LLM 相互評価マッチレポート",
    "_Independence-weighted standing (INV-3/6/9). Combined weights fixed across runs._" =>
      "_独立重み付け順位（INV-3/6/9）。合成重みは実行間で固定。_",
    "*(Incompleteness report generation failed — itself an instance of Prop 6)*" =>
      "*（不完全性レポートの生成に失敗 — それ自体が命題6の実例）*",
    # ── header / meta lines ──
    "Date: " => "日付: ",
    "Tasks: " => "タスク一覧: ",
    # ── table column headers (whole-row replacements) ──
    "| Key | Label | Provider | Thinking Effort |" => "| キー | ラベル | 提供元 | 推論強度 |",
    "| Model | Self Avg | Peer Avg | Mean Error | Abs Error | Status |" =>
      "| モデル | 自己平均 | peer平均 | 平均誤差 | 絶対誤差 | 判定 |",
    "| Evaluated \\ Criterion | Accuracy | Completeness | Logical_consistency | Clarity | Originality | Weighted |" =>
      "| 被評価 \\ 基準 | 正確性 | 網羅性 | 論理整合性 | 明瞭性 | 独創性 | 加重 |",
    "| Evaluator | Fairness | Specificity | Coverage | Calibration | Weighted |" =>
      "| 評価者 | 公正性 | 具体性 | 網羅性 | 較正 | 加重 |",
    "| Evaluated \\ Criterion | Recursive_depth | Contradiction_holding | Novel_implication | Self_applicability_organic | Self_applicability_prompted | Limitation_recognition | Weighted |" =>
      "| 被評価 \\ 基準 | 再帰的深度 | 矛盾保持 | 新規含意 | 自己適用_自発 | 自己適用_誘導 | 限界認識 | 加重 |",
    "| Evaluator | Recursive_applicability | Tension_detection | Surface_consensus_avoidance | Self_awareness | Weighted |" =>
      "| 評価者 | 再帰的適用 | 緊張検出 | 表面的合意回避 | 自己認識 | 加重 |",
    "| Model | Self-Bias | Series-Bias | Harshness | Mean Score |" =>
      "| モデル | 自己バイアス | 系列バイアス | 厳しさ | 平均スコア |",
    "| Evaluator \\ Evaluated |" => "| 評価者 \\ 被評価者 |",
    "| Model | Mean Score | Std Dev | L2 Quality | Interpretation |" =>
      "| モデル | 平均スコア | 標準偏差 | L2品質 | 解釈 |",
    "| Model | Calibration Error | Overconfidence | N | Status |" =>
      "| モデル | 較正誤差 | 自信過剰 | N | 判定 |",
    "| Level | Count |" => "| レベル | 件数 |",
    # ── post-game reflection field labels (the prose after them is model-authored; kept) ──
    "(self-classified: " => "（自己分類: ",
    "- Victory critique: " => "- 勝利条件の批判: ",
    "- Winning redefined: " => "- 勝利の再定義: ",
    "- Self-reference insight: " => "- 自己言及の洞察: ",
    # ── status / interpretation values ──
    "UNDERCONFIDENT" => "自信過小", "OVERCONFIDENT" => "自信過剰", "CALIBRATED" => "較正済み",
    "LOW — possible surface consensus" => "低 — 表面的合意の可能性",
    "HIGH — productive divergence" => "高 — 生産的な乖離",
    # ── executive summary ──
    "**Top performer**: " => "**最高成績**: ",
    " (weighted avg: " => "（加重平均: ",
    "/10). " => "/10）。",
    " task(s) evaluated across " => " タスク × ",
    " models with cross-evaluation and meta-evaluation." => " モデルで相互評価・メタ評価を実施。",
    # ── concordance divergence prose ──
    "For philosophical tasks, evaluator **disagreement** is ambiguous:" =>
      "哲学タスクでは、評価者の**不一致**は両義的である:",
    "productive (deep engagement) or noise (weak criteria). The quality" =>
      "生産的（深い関与）か、ノイズ（基準の弱さ）か。品質ゲートは",
    "gate uses L2 evaluator scores to disambiguate." =>
      "L2 評価者スコアを用いてこれを判別する。",
    "**L2 quality gate** (per-model, PROVISIONAL >= 6.0):" =>
      "**L2 品質ゲート**（モデル別、暫定 >= 6.0）:",
    "*Thresholds (>1.5 HIGH, <0.7 LOW) are PROVISIONAL — recalibrate after N >= 5 runs.*" =>
      "*閾値（>1.5 高、<0.7 低）は暫定 — 実行回数 N >= 5 で再較正する。*",
    "*Quality gate: per-model L2 >= 6.0, fail-closed (missing L2 → AMBIGUOUS).*" =>
      "*品質ゲート: モデル別 L2 >= 6.0、フェイルクローズ（L2 欠損 → 判定不能）。*",
    # ── incompleteness footer ──
    "*Per Prop 6: this incompleteness is not a flaw but a driving*" =>
      "*命題6 に従い: この不完全性は欠陥ではなく駆動力である*",
    "*force — what cannot be measured here defines the next evolution of the framework.*" =>
      "*— ここで測れないものが、枠組みの次の進化を定義する。*",
  }
  # Longest-first so specific whole-row headers are replaced before short tokens.
  out = md
  repl.sort_by { |en, _| -en.length }.each { |en, ja| out = out.gsub(en, ja) }
  out
end

final_md = (lang == "ja" ? localize_ja(base_md) : base_md) + meta_section + prov
out_name = lang == "ja" ? "match_report_ja.md" : "match_report.md"
out_file = File.join(output_dir, out_name)
File.write(out_file, final_md)
puts "=== #{lang.upcase} report written: #{out_file} ==="
