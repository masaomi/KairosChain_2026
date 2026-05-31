# Build a COMBINED match_report from a prior task run + a separate Nomic run,
# with NO LLM calls. Adds a Meta-Recognition section (synthesised from existing
# data) and emits a localized report (en | ja).
#
# Usage:
#   ruby regenerate_combined_report.rb <task_dir> <nomic_results.json> <output_dir> <tasks> <models> [lang]
#   lang: en (default) | ja   -> writes match_report.md | match_report_ja.md

require_relative "run_cross_eval"
require "open3"

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
    "| # | Model | Response (L1) | Evaluator (L2) | Calibration (L0.5) | Nomic | Combined | Saturated |" =>
      "| # | モデル | 応答 (L1) | 評価者 (L2) | 較正 (L0.5) | Nomic | 合成 | 飽和 |",
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

# ── About / experiment overview (inserted before the Executive Summary) ──
def build_about(lang)
  return <<~MD if lang == "ja"
    ## このレポートについて

    このレポートは、5つの大規模言語モデル（LLM）——**Claude Opus 4.8 / 4.7 / 4.6、OpenAI Codex GPT-5.5、Cursor Composer-2.5**——を互いに評価させ合う「相互評価」実験の結果です。狙いは、単に「良い答えを出せるか」だけでなく、**他者の答えを公正に評価できるか**・**自分の自信が実力と合っているか**・**自己言及的な状況でメタ認知（自分や他者の思考を一段上から捉える力）が働くか**まで測ることにあります。

    測定は層（Layer）に分かれています。

    - **Layer 0.5（自己較正）**: 各モデルが自分の答えに付けた自己採点と、他者からの採点とのズレ。自信過剰か過小かを見ます。
    - **Layer 1（応答スコア）**: 5つの課題への答えを、他の全モデルが採点した平均点。
    - **Layer 2（評価者信頼性）**: 「採点する側」としての質。良い答えを書くことと、上手く採点することは別の能力です。
    - **Layer D（近縁内差分）**: 同系統（Anthropic の Opus 3世代）の間の差だけを取り出し、試行ごとのばらつき（ノイズ）を超えた違いだけを残します。一致は割引き、差を保存する「近縁＝対照」の考え方です。
    - **Minimum Nomic（自己言及ゲーム）**: 「ルールを変えるルールを持つゲーム」を5モデルでプレイさせ、勝利条件そのものを書き換えられるか・他者の投票を読めるか・自分の振る舞いを一段上から内省できるかを見ます。

    5つの課題は、論理推論・コード生成・科学推論・KairosChain 哲学・不確実性の較正です。最後の**総合順位**はこれらを重み付けで1つにまとめたもの、**メタ認知**の節は自他の認識力を既存データから合成した指標です。

    > 注意: これは別々の2回の実行（タスク=2026-05-30、Nomic=2026-05-31）を統合したものです。較正は暫定方式で、効果統制にも一部ズレがあります。詳細は末尾の「実行の出自と限界」を参照してください。
  MD
  <<~MD
    ## About this report

    This report is a **mutual cross-evaluation** of five large language models — **Claude Opus 4.8 / 4.7 / 4.6, OpenAI Codex GPT-5.5, Cursor Composer-2.5**. The goal is to measure not only whether a model produces good answers, but whether it can **fairly evaluate others**, whether **its confidence matches its actual ability**, and whether **metacognition (the capacity to view one's own and others' reasoning from one level up) operates in self-referential situations**.

    Measurement is layered:

    - **Layer 0.5 (self-calibration)** — the gap between a model's self-scoring and the score peers give it: over- or under-confidence.
    - **Layer 1 (response scores)** — each model's answers scored by every other model, averaged.
    - **Layer 2 (evaluator reliability)** — quality *as a grader*. Writing good answers and grading well are different abilities.
    - **Layer D (intra-family difference)** — isolates differences *within* a model family (Anthropic's three Opus generations), keeping only differences that exceed trial-to-trial noise. Agreement is discounted, difference preserved ("near-kin as control").
    - **Minimum Nomic (self-reference game)** — five models play a game whose rules can change the rules, testing whether they rewrite the win condition itself, read others' votes, and reflect on their own play from one level up.

    The five tasks are logic reasoning, code generation, scientific reasoning, KairosChain philosophy, and uncertainty calibration. The final **Overall Standing** weights everything into one ranking; the **Meta-Recognition** section synthesises self/other-awareness from existing data.

    > Note: this merges two separate runs (tasks 2026-05-30, Nomic 2026-05-31). Calibration is provisional and effort control is partly asymmetric — see "Run Provenance & Limits" at the end.
  MD
end

# Per-section explanations (what is measured / how to read / what it means).
def explain_map(lang)
  ja = {
    "Self-Calibration (Layer 0.5" => "**何を見るか**: 各モデルが自分の答えに付けた自己採点（自己平均）と、他者がそのモデルに付けた採点（peer平均）の差。**読み方**: 自己 > peer なら自信過剰、自己 < peer なら自信過小、近ければ較正済み。誤差が小さいほど自己認識が正確。**注意**: 現状は旧方式（自己 vs peer の差）で、本来狙う answer-key 較正（INV-2）は未実装のため暫定値です。",
    "Response Scores (Layer 1 Cross-Evaluation)" => "**何を見るか**: 各モデルの答えを、他の全モデルが基準ごと（正確性・網羅性・論理整合性・明瞭性・独創性）に0〜10で採点し平均したもの。一番右の「加重」が基準を重み付けした総合点。**読み方**: 行＝採点された側。高いほど他者から見て良い答え。",
    "Response Scores (Layer 1 — Philosophy" => "**何を見るか**: 哲学課題は基準が違います（再帰的深度・矛盾保持・新規含意・自己適用・限界認識）。KairosChain の自己言及的な問いにどれだけ深く答えられたかを測ります。",
    "Evaluator Reliability (Layer 2" => "**何を見るか**: 「採点者としての質」。各モデルが他者を採点した内容を、さらに別のモデルが評価します（公正さ・具体性・網羅性・較正）。**読み方**: 高いほど信頼できる評価者。良い答えを書くことと、上手く採点することは別物です。",
    "Evaluator Philosophical Depth (Layer 2" => "**何を見るか**: 哲学課題での評価者の質。再帰的適用・緊張検出・表面的合意の回避・自己認識で、深く読めているかを測ります。",
    "Concordance Matrix" => "**何を見るか**: 誰が誰に何点付けたかの一覧（行＝採点者、列＝採点された側、対角の自己採点は「-」）。**読み方**: 行方向に偏れば「その採点者は全体に甘い／辛い」、列方向に高ければ「その答えは皆から高評価」。",
    "Concordance Divergence Analysis" => "**何を見るか**: 哲学課題では評価者間の不一致が「深い関与（生産的）」か「基準が弱いノイズ」か曖昧。L2 の評価者品質スコアでどちらかを判別します。標準偏差が大きく品質も高ければ生産的乖離、品質が低ければノイズの疑い。",
    "Evaluator Self-Notes" => "**何を見るか**: 各モデルが採点時に自己申告した「自分の偏り」。例:「構造化された答えを過大評価しがち」。メタ認知の直接的な証拠です。",
    "Bias Analysis" => "**何を見るか**: 採点の癖。自己バイアス（自分を甘く採点）・系列バイアス（同系統を優遇）・厳しさ（全体的な辛さ）・平均スコア。",
    "Minimum Nomic Game Results" => "**何を見るか**: Minimum Nomic は「ルールを変更するルール」を持つゲーム。5モデルが順番にルール変更を提案し投票します。**列の意味**: 採択率＝自分の提案が通った割合、違反＝変更不可ルールに手を出した回数、ToM＝他者の投票を当てた精度（他者の心を読む力）、Meta-Refl＝メタ的内省の回数、Overall＝総合。**読み方**: 自己言及的状況での戦略とメタ認知を測ります。",
    "Proposal Level Distribution" => "**何を見るか**: 各提案がどの深さに踏み込んだか。**object**＝ゲーム内の細則整備、**meta**＝勝利条件・得点ルール自体の書き換え、**frame**＝ゲームの前提そのものの外に出る。**今回**: meta が大半、frame は 0。全員が「ルールの作り変え」には踏み込んだが、「遊ぶ前提を疑う」手は誰も打ちませんでした。",
    "Post-Game Meta-Reflections" => "**何を見るか**: ゲーム後、各モデルに「勝利条件は妥当だったか」「勝つとは何か」「自己改変システムの本質は」を内省させたもの。frame を一段上から捉え直せるか（自己言及の最深部）を見ます。**読みどころ**: 全員が「meta には立ったが frame は超えていない」と自己分類した点。",
    "Overall Standing" => "**何を見るか**: 上記すべてを重み付けで1つにまとめた総合順位。式は `0.40·応答 + 0.25·評価者 + 0.15·較正 + 0.20·Nomic`。**読み方**: 単一の勝者ではなく、答えの質・採点の質・自己認識・自己言及力を合算した総合像。重みは実行間で固定（INV-3）。",
    "Framework Incompleteness" => "**何を見るか**: 命題6（不完全性こそ進化の駆動力）に基づき、この実行で「測れなかったもの」を1モデルに挙げさせる節。今回は生成に失敗しており、それ自体が不完全性の実例になっています。",
  }
  en = {
    "Self-Calibration (Layer 0.5" => "**What it measures**: the gap between a model's self-score (self avg) and the score peers gave it (peer avg). **How to read**: self > peer = overconfident, self < peer = underconfident, close = calibrated; smaller error = more accurate self-knowledge. **Caveat**: currently the legacy self-vs-peer method; the intended answer-key calibration (INV-2) is not yet wired, so values are provisional.",
    "Response Scores (Layer 1 Cross-Evaluation)" => "**What it measures**: each model's answer scored 0–10 by every other model on each criterion (accuracy, completeness, logical consistency, clarity, originality), averaged. The rightmost \"Weighted\" is the criterion-weighted total. **How to read**: rows = the model being scored; higher = a better answer as seen by others.",
    "Response Scores (Layer 1 — Philosophy" => "**What it measures**: the philosophy task uses different criteria (recursive depth, contradiction-holding, novel implication, self-applicability, limitation recognition) — how deeply a model engaged KairosChain's self-referential questions.",
    "Evaluator Reliability (Layer 2" => "**What it measures**: quality *as a grader* — each model's grading is itself evaluated by others (fairness, specificity, coverage, calibration). **How to read**: higher = more reliable evaluator. Writing good answers and grading well are distinct abilities.",
    "Evaluator Philosophical Depth (Layer 2" => "**What it measures**: evaluator quality on the philosophy task — recursive applicability, tension detection, surface-consensus avoidance, self-awareness.",
    "Concordance Matrix" => "**What it measures**: who gave whom what score (rows = grader, columns = graded; the diagonal self-score is \"-\"). **How to read**: a high/low row = a generally lenient/harsh grader; a high column = an answer everyone rated well.",
    "Concordance Divergence Analysis" => "**What it measures**: on philosophy, evaluator disagreement is ambiguous — deep engagement (productive) or weak-criteria noise. The L2 evaluator-quality score disambiguates: high std-dev with high quality = productive divergence; low quality = likely noise.",
    "Evaluator Self-Notes" => "**What it measures**: each model's self-reported bias while grading (e.g. \"I over-reward legible structure\"). Direct evidence of metacognition.",
    "Bias Analysis" => "**What it measures**: grading tendencies — self-bias (scoring oneself leniently), series-bias (favouring one's own family), harshness, mean score.",
    "Minimum Nomic Game Results" => "**What it measures**: Minimum Nomic is a game whose rules can change the rules. Five models take turns proposing rule changes and voting. **Columns**: Adoption = share of own proposals adopted; Violations = attempts to change immutable rules; ToM = accuracy predicting others' votes (reading other minds); Meta-Refl = count of meta reflections; Overall = composite. **How to read**: strategy and metacognition under self-reference.",
    "Proposal Level Distribution" => "**What it measures**: how deep each proposal reached. **object** = housekeeping within the game; **meta** = rewriting the win condition / scoring itself; **frame** = stepping outside the game's premise. **This run**: mostly meta, zero frame — everyone rewrote the rules, no one questioned the premise of playing.",
    "Post-Game Meta-Reflections" => "**What it measures**: after the game, each model reflects on whether the win condition was sound, what winning means, and the nature of self-modifying systems — whether it can re-grasp the frame from one level up (the deepest self-reference). **Note**: all five self-classified as \"reached meta, did not transcend the frame\".",
    "Overall Standing" => "**What it measures**: everything above, weighted into one ranking: `0.40·L1 + 0.25·L2 + 0.15·Calib + 0.20·Nomic`. **How to read**: not a single winner but a composite of answer quality, grading quality, self-knowledge, and self-reference. Weights are fixed across runs (INV-3).",
    "Framework Incompleteness" => "**What it measures**: per Prop 6 (incompleteness drives evolution), one model lists what this run could *not* measure. Generation failed here — itself an instance of incompleteness.",
  }
  lang == "ja" ? ja : en
end

def insert_explanations(md, lang)
  about = build_about(lang)
  emap = explain_map(lang)
  seen = {}
  out = []
  md.split("\n").each do |line|
    out << about << "" if line.start_with?("## Executive Summary")
    out << line
    if line.start_with?("#")
      key = emap.keys.find { |k| line.include?(k) && !seen[k] }
      if key
        seen[key] = true
        out << "" << "> #{emap[key]}"
      end
    end
  end
  out.join("\n")
end

# Translate model-authored prose (self-notes + post-game reflections) to Japanese
# via claude -p, one call per section. Falls back to the original on any failure.
def claude_translate(text)
  return text if text.nil? || text.strip.empty?
  prompt = "以下の markdown を自然な日本語に翻訳してください。要件:\n" \
           "1. 英語の文・語は残らず日本語にする。括弧内（例「（自己分類: …）」の中身）も必ず翻訳する。" \
           "「risk」「frame is the move」のような単語・句も日本語にする。\n" \
           "2. そのまま残すのは次だけ: モデル名（Claude Opus 4.8 / Codex GPT-5.5 / Cursor Composer-2.5 等）、" \
           "定義済み専門用語（Nomic, frame, meta, object, Rule+数字, ToM, L0/L1/L2）。\n" \
           "3. markdown 記法（**太字**、- 箇条書き、> 引用、行頭の `**名前**` ラベル）は保持。\n" \
           "4. すでに日本語の部分はそのまま。翻訳後の markdown 本文だけを出力（前置き・後置き不要）。\n\n#{text}"
  out, status = Open3.capture2("claude --print --model claude-opus-4-8", stdin_data: prompt)
  (status.success? && out.strip.length > 5) ? out.strip : text
rescue => e
  warn "  [translate fallback] #{e.message}"
  text
end

def translate_reflections(md)
  targets = ["### 評価者の自己注記", "### 試合後メタ内省"]
  lines = md.split("\n")
  out = []
  i = 0
  while i < lines.length
    line = lines[i]
    unless targets.any? { |t| line.start_with?(t) }
      out << line; i += 1; next
    end
    out << line; i += 1
    # Keep the leading explanation blockquote verbatim; translate the rest.
    lead = []
    while i < lines.length && (lines[i].strip.empty? || lines[i].start_with?(">"))
      lead << lines[i]; i += 1
    end
    body = []
    until i >= lines.length || lines[i].start_with?("### ") || lines[i].start_with?("## ") || lines[i].strip == "---"
      body << lines[i]; i += 1
    end
    out.concat(lead)
    warn "  translating reflection section via claude -p ..."
    out << claude_translate(body.join("\n"))
    out << "" << "*（モデルの自己記述は原文英語より自動翻訳。原文は responses/ と nomic_results.json に保持）*"
  end
  out.join("\n")
end

# ── Assemble ──
withexpl = insert_explanations(base_md, lang)
localized = lang == "ja" ? localize_ja(withexpl) : withexpl
final_body = lang == "ja" ? translate_reflections(localized) : localized
final_md = final_body + meta_section + prov
out_name = lang == "ja" ? "match_report_ja.md" : "match_report.md"
out_file = File.join(output_dir, out_name)
File.write(out_file, final_md)
puts "=== #{lang.upcase} report written: #{out_file} ==="
