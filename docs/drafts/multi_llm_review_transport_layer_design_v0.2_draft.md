---
name: multi_llm_review_transport_layer_design_v0.2_draft
type: design_draft
version: 0.2
status: draft, pending round 2 multi-LLM review
date: 2026-05-15
authors:
  - Claude Opus 4.7 (main author, v0.1 + integrator for v0.2)
  - Claude Opus 4.6 (sub-author for v0.2 revision)
basis: v0.1 + round 1 multi-LLM review curated P0 findings (A/B/C/D)
related:
  - L1 SkillSet multi_llm_review (current home)
  - vendor_news_monitor_l1_skillset_design_handoff_20260515 (parallel)
  - feedback_design_phase_must_not_drift_to_implementation (style anchor)
  - multi_llm_review_transport_layer_design_v0.1_draft.md (prior version)
  - multi_llm_review_transport_layer_design_v0.2-4.6.md (sub-author audit trail)
integrator_notes: |
  4.7 integrator adopted 4.6 sub-author revision substantively verbatim. The 4.6 output
  was tight, applied all 4 P0 fixes via qualifier additions (no new invariants, no new
  sections), and produced a coherent v0.2. Integrator changes are limited to file
  structure: extracted reject log into the "Revision Notes" appendix below §12 (keeping
  §1–§12 as the design body proper, matching v0.1 sectioning), and consolidated YAML
  frontmatter for dual authorship.
---

# Multi-LLM Review — Transport Layer Design Draft v0.2

## §1. Problem statement (invariant form)

**Inv-1.** Multi-LLM review における reviewer 呼び出しの transport 選択は、上位の review 意味論——finding tuple（finding 内容、finding 分類 (a)/(b)/(c)、reviewer 識別子、verdict）——に対して観測不変でなければならない。

背景: Anthropic は 2026-06-15 より Claude Agent SDK / `claude -p` subprocess 経路の利用を subscription の interactive pool から分離し、独立の programmatic credit pool で課金する。現行 multi_llm_review の Reviewer 2 (cross-version Claude `claude -p`) はこの programmatic pool に該当する。interactive pool は据え置きであるため、reviewer 呼び出しを harness 層が interactive 利用として扱う経路（端末 pane へのキー入力経由、PTY 経由）に切り替えれば、同じ reviewer model に同じ prompt を渡して同じ review を得ることが原理上可能である。Inv-1 は、この transport 切替が finding tuple を保存することを命題化したものであり、上位の aggregation / persona unanimity gate / finding classification は本設計の対象ではない。transport 状態そのものの記録（Inv-4）および transport 失敗の surface（Inv-5）は Inv-1 とは別の register（constitutive recording, Prop 5）で作用し、Inv-1 の観測不変性主張とは矛盾しない。

## §2. Scope

| in scope | reviewer 側の transport（review 要求が reviewer LLM に到達する経路）<br>reviewer instance の lifetime / state / 失敗時意味論<br>transport 状態の observability と blockchain 記録 |
|---|---|
| out of scope | finding aggregation、persona unanimity gate、(a)/(b)/(c) 分類体系<br>orchestrator 側 workflow 構築<br>Codex / Cursor reviewer の transport（既存 CLI を保持。将来同様の課金変更が起きた際は本設計の invariant 群に従って transport を追加すれば対応可能） |

## §3. Design invariants

| # | Invariant | 根拠 |
|---|---|---|
| Inv-1 | Finding tuple の transport に対する観測不変性（§1）| Prop 1 + Prop 8 |
| Inv-2 | Reviewer instance の lifetime は orchestrator session に同期する。最初の review 必要時より早く生成されず、orchestrator session 終了より後まで残存しない | Prop 3 active maintenance、孤立プロセス排除 |
| Inv-3 | 同一 reviewer instance による連続する review round 間で、記録されたリセット event 以降、前 round の対話状態は後 round に観測されない。各 round はリセット event 後の既知の初期状態から開始する | Prop 3 + aggregation の独立性前提 |
| Inv-4 | Reviewer instance の現在状態（未起動 / アイドル / 応答待ち / 正常終了 / 異常終了）および使用された transport identity は orchestrator から任意時点で問い合わせ可能であり、各 review event の blockchain 記録に含まれる | Prop 5 constitutive recording + masa mode § Layer Awareness |
| Inv-5 | Reviewer 起動失敗、応答 timeout、異常終了、transport 媒体エラーは review round の明示的失敗として surface される。silent retry、silent fallback、エラー suppression は許容されない | masa mode § Transparency Duties (Non-Omission) + Prop 5 |
| Inv-6 | 複数 transport（subprocess / tmux pane / PTY）が共存する。transport 選択は単一の境界（設定 / 環境検出）で決定され、その境界より上位の review 意味論は transport の差異を観測しない | Prop 1 構造的自己言及性（経路は変わっても意味論的 shape は同一）|
| Inv-7 | 与えられた reviewer に対する transport 選択は、呼び出しコストポリシー（例: 2026-06-15 以降の interactive pool 優先、programmatic pool 回避）の関数である。ポリシーは設定として表現され、Inv-1 〜 Inv-6 はどの transport が選ばれるかを制約しない。選択結果が invariant 群を満たすことのみを制約する | Prop 4 構造が可能性空間を開く + masa mode § Scaffolding Stance（コストポリシーは時代依存の足場）|

## §4. Justification

Inv-1 と Inv-6 は本設計の中核である。Review は意味論的操作であり、finding tuple は「バイト列がどの経路で reviewer に届いたか」によって再解釈されてはならない。これが成り立つからこそ、Reviewer 2 (cross-version Claude) は 2026-06-15 の課金構造変更を跨いで保存できる。同じ model、同じ prompt、異なる transport、aggregation 層からは識別不能な review。ただし Inv-1 の観測不変性と、Inv-4/Inv-5 による transport 状態の constitutive recording は別 register で作用する。transport identity や lifecycle state が blockchain に記録されることは、finding tuple が transport から不変であることと矛盾しない——前者は Prop 5 の要請、後者は review 意味論の要請であり、作用する層が異なる。

Inv-2 と Inv-3 は長寿命 reviewer instance に伴う状態蓄積の危険を扱う。ここで lifetime (Inv-2) と対話状態 (Inv-3) は別次元の概念として扱う。Inv-2 は reviewer process の生存期間を orchestrator session に縛る（孤立プロセス排除）。Inv-3 は生存期間内であっても round 間の対話状態をリセットする（aggregation 独立性保証）。tmux pane に常駐する Claude Code session は、明示的なリセットなしでは前 round の会話を後 round が継承する。Inv-3 は aggregation 層が各 round を独立評価として扱えることを保証する（persona unanimity gate および finding classification は round 独立性を前提に設計されている）。リセット event が何であるか——その具体的契約——は §11 mechanism が満たすべき要件であり、invariant body では規定しない。Inv-2 は orchestrator を跨いで生き残る reviewer instance を禁止する。orphan プロセスや out-of-band の状態蓄積を session boundary で打ち切る。

Inv-4 と Inv-5 は multi_llm_review が既に持つ observability / 失敗 surface 姿勢の継続である。Inv-4 は lifecycle state に加え、使用された transport identity の記録を要求する。これにより Inv-5 (silent fallback 禁止) が blockchain 記録から post-hoc に検証可能になる——ある round が subprocess で走ったのか tmux で走ったのかが記録に残らなければ、silent fallback の有無は事後的に判別できない。persona unanimity gate は reviewer 失敗を non-APPROVE として扱う設計であり、transport 層がこの姿勢を弱めてはならない。とりわけ「前回の review で tmux pane が動いていたから今回も動いている」という前提は許容されない。transport 状態は仮定ではなく確認である。

Inv-7 はコストを意味論ではなく policy の問題として明示する。同一 review は Inv-1〜6 を満たす任意の transport から得られる。どの transport が *選ばれる* かは cost policy が支配する。この分離により、将来 Anthropic 以外の vendor から同様の課金変更が起きても（OpenAI / Google / Microsoft いずれも本 SkillSet 設計の対象外だが、Codex / Cursor 経由の将来的影響は想定範囲）、cost policy の更新のみで対応可能であり、本設計の意味論的 invariant 群は変更不要となる。

## §5. Non-invariants（意図的に制約しない事項）

| # | 制約しない理由 |
|---|---|
| 対応 transport の個数 | 3 つを想定しているが、invariant 群は任意の N を許容する。将来 Mythos 等の異なる用途で transport が増えても本設計を拡張せず適用可能 |
| Transport ごとの latency / throughput | Inv-1〜6 を満たすならば遅い transport も許容される。性能は別レイヤーの関心事 |
| Reviewer instance の人間可視性 | tmux pane が operator から見える、PTY が見えない、subprocess も見えない、これらは選ばれた transport の性質であり本設計の制約事項ではない |
| Reviewer model identity と transport の対応 | 同一 model は transport が変わっても同一 reviewer として aggregation される。Reviewer 2 を tmux で呼んでも subprocess で呼んでも、aggregation 層からは同じ Reviewer 2 である |

## §6. Invariant 群が保証しない事項（revise phase での open question）

R1. Inv-3 (round independence) は厳密すぎる可能性がある。multi-round design 対話など、reviewer が前 round を覚えていることが望ましい用途を opt-in で許容すべきか。本 v0.2 は禁止寄りに置いている。

R2. Inv-7 (cost containment) の policy 表現を本 SkillSet 内に置くか、別の cost-policy SkillSet に切り出すか。本 v0.2 は内部に置いている。policy が複数の SkillSet に共通化できることが判明した時点で抽出する（selective survival）。

R3. Inv-5 (silent fallback 禁止) は厳密すぎる可能性がある。「tmux 失敗時に subprocess に透過的 fallback したい」という operator の要望が想定される。本 v0.2 は禁止寄りに置いている（operator が tmux を選んだ理由 = cost 回避は、silent fallback で達成されないため）。opt-in fallback mode を許すかどうかは revise 議題。

R4. Phased delivery（subprocess 維持 → tmux 追加 → PTY 追加 → adapter 統合）は実装計画であり本設計には含めない。実装計画は別途 `log/` に記録する。本設計は完成形（3 transport 共存 + adapter）の invariant 群のみを規定する。

## §7. Verifiability（multi-LLM review で確認可能な性質）

各 invariant の違反は具体的な観測可能事象として記述できるべきである:

- Inv-1 違反: LLM 非決定性要因（温度、サンプリング）を統制した条件下で、同一 reviewer model + 同一 prompt に対し、transport 差のみで finding 数 / 分類 / verdict のいずれかが系統的に異なる
- Inv-2 違反: orchestrator session 終了後に reviewer プロセスが残存する、または review 必要前に reviewer が起動している
- Inv-3 違反: 記録されたリセット event 後の round において、reviewer が前 round の引用 / 言及を含む応答を返す
- Inv-4 違反: reviewer 状態問い合わせが失敗する、blockchain 記録に lifecycle state フィールドが欠落する、または blockchain 記録に transport identity が欠落する
- Inv-5 違反: transport 失敗時に review が成功として aggregation に渡る
- Inv-6 違反: aggregation 層が transport 識別子を参照しないと正しく動作しない
- Inv-7 違反: cost policy が不在のまま transport が選択される、または policy 表現が本設計外の場所に隠れる

## §11. Backlog (mechanism, deferred from invariant body)

本設計は invariant 群のみを規定する。以下は mechanism / 実装決定であり、設計 body には含めず実装フェーズで決める。

- Reviewer 応答完了の検出機構（sentinel marker、stream 解析、idle timeout の混合）
- Terminal escape sequence / ANSI / TUI 制御コード除去ロジックと parser の共通化
- Reviewer round 境界での状態リセット手段（slash command / pane 再起動 / 専用 reset プロンプトのいずれか）。Inv-3 の「リセット event」が何であるかの具体的契約はここで決める
- Transport 選択ポリシーの設定 schema、環境自動検出（tmux 存在検出、PTY 利用可否）、ポリシー優先順位
- Reviewer 起動完了 readiness probe の機構
- 複数 reviewer pane の並列 orchestration（独立 pane / multiplexed / pool）
- Plugin projection の reviewer instance への適用範囲（reviewer pane に masa mode が effective であるべきか、reviewer は素の Claude Code であるべきか）
- Orchestrator 異常終了時の reviewer instance cleanup 経路
- Cost policy DSL の表現（vendor × model × date 軸での transport 選好を declarative に記述する方式）
- vendor_news_monitor SkillSet との連携（vendor 課金構造変更を news monitor が検知した際に、cost policy 更新提案を生成する coupling 機構）
- Reviewer 識別子の transport 透過性をテストで保証する制約テスト群
- Inv-1 観測不変性の経験的検証手順（温度固定、複数 sample 平均による transport 効果と LLM 非決定性の分離手法）

## §12. Provenance

- 元議論: 2026-05-15 セッション、YouTube 動画経由で 2026-05-13 Anthropic 発表を masaomi が発見、WebSearch で公式 / 二次 source を確認
- 主要 source: InfoWorld, The Register, Anthropic Support, DevToolPicks (URLs は本 draft 外部の session log / vendor_news_monitor handoff に記録済み)
- 並行作業: vendor_news_monitor L1 SkillSet 設計（別セッション）。両者完了後、news monitor が transport layer に関わる vendor policy 変更を早期検知する補完関係が成立
- Author flow: v0.1 (4.7) → round 1 multi-LLM review (5 reviewers, 1 round) → v0.2 (4.6 sub-author + 4.7 integrator) → pending round 2 multi-LLM review
- v0.1 → v0.2 変更点: P0-A (Inv-1 命名 qualify)、P0-B (§7 非決定性 qualifier + §11 経験的検証 backlog)、P0-C (Inv-4 transport identity 追加)、P0-D (§4 lifetime/state 次元分離 + Inv-3 リセット event qualify)。新 invariant なし、新 section なし。

---

## Revision Notes (v0.1 → v0.2)

v0.2 is a tight revision addressing 4 P0 findings from round 1 multi-LLM review. The revision deliberately keeps the review surface unchanged: same 7 invariants, same 8 sections, qualifier additions only.

### Round 1 verdict

- Aggregated verdict: REVISE (2 APPROVE / 2 REJECT / 1 REVISE across 5 reviewers; 3/5 APPROVE threshold not met)
- Anthropic persona unanimity gate: 3/4 (Architect, Operations, Philosophy APPROVE; Skeptic REVISE)
- Reviewer 2 (Claude Opus 4.6 subprocess): APPROVE
- Codex gpt-5.4 / gpt-5.5: REJECT (legalistic-waterfall bias per memory `multi_llm_review_codex_evaluator_characteristics`)
- Cursor Composer 2: APPROVE

### Accepted (a)+(b) P0 fixes

| ID | Class | Source | Fix |
|---|---|---|---|
| P0-A | (b) | Skeptic | Inv-1 命名を「transport 独立性」→「観測不変性」に修正。§1 と §4 に Prop 5 register 分離の justification 追加。Inv-4/Inv-5 が transport 状態を記録することと Inv-1 の主張が矛盾しないことを明示 |
| P0-B | (a) | Codex 5.4 + 5.5 | §7 Inv-1 違反基準に「LLM 非決定性要因を統制した条件下で...系統的に」qualifier を追加。§11 に経験的検証手順 backlog 項目を追加 |
| P0-C | (a) | Codex 5.4 | Inv-4 文面に「使用された transport identity」を blockchain 記録必須フィールドとして追加。§7 Inv-4 違反基準にも transport identity 欠落を追加 |
| P0-D | (a) | Skeptic | §4 で lifetime (Inv-2) と対話状態 (Inv-3) が別次元であることを明示。Inv-3 文面を「記録されたリセット event 以降」で qualify。リセット手段の具体的契約は §11 に委ねることを §4 で宣言 |

### Rejected (c) findings (reject log)

| # | Finding | Reject reason |
|---|---|---|
| 1 | Codex の integrity boundary 提案 (tmux operator out-of-band input への新 invariant 要求) | 新 invariant 提案、scope constraint 違反 |
| 2 | Codex の human visibility 制約提案 | 新 invariant 提案、scope constraint 違反。§5 で意図的に非制約としており v0.1 設計判断を維持 |
| 3 | Skeptic の §1 empirical 検証要求 (Inv-1 経験的検証手順) | R-series advisory。§11 backlog 追加で吸収済み (P0-B 修正と統合) |
| 4 | Skeptic の Inv-7 cost → 宣言的 policy 一般化提案 | selective survival。v0.1 文面で十分機能しており一般化は premature |
| 5 | 全 P2 advisory (21 件) | invariant 文面修正なし。§4 微修正のみ許容範囲 |
| 6 | Cursor の Inv-6 境界曖昧性指摘 | §2 scope + §3 表で読み取り可能、明示的修正不要 |
| 7 | Cursor の Prop 1/3/4/5/8 内部定義欠落指摘 | CLAUDE.md 参照で十分。§3 表脚注は不要（propositions は本設計の読者が既知の前提） |

### Scope discipline

新 invariant: 0 件 (Inv-1 〜 Inv-7 のみ、変更前と同数)。
新 section: 0 件 (§1, §2, §3, §4, §5, §6, §7, §11, §12 のみ、変更前と同数)。
新 §11 backlog 項目: 1 件 (Inv-1 経験的検証手順、P0-B 由来)。
本文修正範囲: Inv-1 命名 + §1 末尾追加 (P0-A) / Inv-3 qualify (P0-D) / Inv-4 文面拡張 (P0-C) / §4 段落追加 2 件 (P0-A, P0-D) / Inv-4 段落拡張 (P0-C) / §7 Inv-1 qualifier (P0-B) / §7 Inv-3 qualifier (P0-D) / §7 Inv-4 拡張 (P0-C) / §11 追加 1 件 (P0-B) / §12 author flow 更新。

### Integrator notes (4.7)

4.6 sub-author の出力は constraint compliance が高く、4 件すべての P0 を新 invariant / 新 section なしで吸収している。Integrator (4.7) は 4.6 の content を verbatim に採用し、変更は file structure のみ (reject log を本ファイル末尾の Revision Notes に整理、frontmatter で dual authorship を明示)。Sub-author の原出力は `multi_llm_review_transport_layer_design_v0.2-4.6.md` に audit trail として保存。
