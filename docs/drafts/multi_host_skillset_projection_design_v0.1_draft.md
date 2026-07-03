# Multi-Host SkillSet Projection — 大雑把な統合設計 (v0.1 draft)

- **Status**: rough design / implementation deferred（実装は別機会）
- **Author**: Masaomi Hatakeyama
- **Date**: 2026-07-02
- **関連 L2**: `mcp_sep2640_skills_extension_vs_kairoschain_20260702`
- **関連 resume**: `resume_plugin_projector_v325`, `resume_kairos_hook_projector`

---

## 1. Context（なぜこの設計が要るか）

KairosChain は現在、SkillSet を Claude Code の `.claude/` 配下へ投影する経路（plugin projection）だけを持つ。目標は、Claude Code に依存せず、複数の coding agent（Codex CLI、Gemini CLI、Cursor、GitHub Copilot、OpenCode）へも SkillSet の知識・手順層を届けられるようにすること。

当初の想定は「MCP の SEP-2640（`skill://` 配信）に先回り対応する」だった。しかし調査（2026-07-02）で前提が覆った。

- 5つの host はいずれも SEP-2640 の `skill://` を消費しない。全員が agentskills.io の `SKILL.md` 形式を、**ファイルシステム上のディレクトリ探索**で読む。
- `skill://` を MCP 経由で消費する host は現状ほぼ存在しない（Claude Code は内部プロトタイプ・未公開、他はコミュニティ plugin 止まり）。

結論として、この設計が担うべきは「新プロトコルへの先回り」ではなく、「**一つの正本から複数 host へ投影する適応層**を先に持つこと」である。SEP-2640 は将来の一経路として設計に組み込むが、主経路はファイルシステム投影になる。

## 2. 何を届け、何を届けないか

KairosChain の SkillSet は「実行される tool（Ruby）＋ DSL ＋ knowledge/手順」の束である。host に届けられるのはこのうち **knowledge/手順（指示テキスト）だけ**。

実行される tool は KairosChain の MCP サーバーに留まり、各 host は MCP client として別途 KairosChain に接続してそれを呼ぶ。投影された `SKILL.md` は「この作業をするなら KairosChain MCP のこの能力を使え」と指し示すのみで、tool 実体を焼き込まない。これは SEP-2640 が「MCP 由来 skill にホスト側の権限拡張を焼き込むな」と定めた安全規約とも整合する。

## 3. 設計不変条件（Invariants）

この設計は以下の性質を満たす形でのみ正しい。手段の選択は §7 の backlog に送る。

- **INV-1 単一の正本**: KairosChain 内の SkillSet 知識層が唯一の正本。各 host への配信はその投影であり、正本を複製・分岐させない。host 側の投影物は常に導出物であって、権威を持たない。

- **INV-2 配信は変換、能力は据え置き**: host に届くのは指示テキスト（`SKILL.md` 形式）のみ。実行される能力は KairosChain MCP に留まる。skill に tool 実体・権限拡張を焼き込まない。

- **INV-3 transport 非依存の適応層**: 配信経路（ファイルシステム投影／将来の `skill://` MCP）は adapter で抽象化され、host の追加は adapter の追加で閉じる。core は個別 host の知識を持たない。この adapter 群自体を SkillSet として表現できること（＝ plugin projection の一般化）。ここに KairosChain の自己言及性（命題1）が効く。

- **INV-4 出所の不可分**: 投影された skill には必ず出所（KairosChain instance 識別・SkillSet version・digest）が付随し、host 側で剥がれない形にする。SEP-2640 の「出所をモデルに必ず示す」要件と一致させる。

- **INV-5 信頼は正本側が担保**: host が受け取る digest は SEP-2640 同様「一貫性の確認」にとどまり、信頼境界にはならない。信頼は KairosChain の attestation と構成的記録（命題5）が正本側で担保し、投影物にはその参照を埋め込む。ここが標準に対する KairosChain の付加価値。

- **INV-6 承認なしに実行を投影しない**: script を同梱しうる host があっても、既定では指示テキストのみ投影する。実行を伴う投影はユーザー承認を要する（Prop 10 の手続き的下限・masa mode の安全最小限）。

## 4. 二つの配信レーン

正本は一つ、届け方は二経路。INV-3 により両者は同じ適応層の下に並ぶ。

### レーンA — ファイルシステム投影（今すぐ効く・主経路）

各 host が監視する skill ディレクトリへ `SKILL.md` ディレクトリを投影する。5 host 全部が今日これを消費できる。既存の plugin projection（`.claude/` 向け）を一般化したもの。

### レーンB — `skill://` MCP 配信（将来・SEP-2640）

KairosChain の MCP サーバーが SkillSet の知識層を `skill://` resource として直接出す。host 側が SEP-2640 に対応した時点で、投影せずに配れる。現時点では消費側が居ないため保留。ただし INV-3 のもとで後付けの一 adapter として組み込めるよう、設計の座席だけ確保しておく。

## 5. host 適応表（2026-07-02 時点、要再確認）

| host | 読む skill ディレクトリ（例） | `skill://` MCP 消費 | 備考 |
|------|------------------------------|--------------------|------|
| Claude Code | `.claude/skills/` | 内部prototype・未公開 | 既存の投影先 |
| Codex CLI | `.codex/skills/`, `~/.codex/skills/` | なし（filesystem） | `openai.yaml` で MCP tool 依存を宣言可・独自 |
| Gemini CLI | `~/.agents/skills/`（→ `~/.gemini/skills/` symlink） | なし（filesystem） | 中央ライブラリ `~/.agents/skills/` 起点 |
| Cursor | `.cursor/skills/`, `~/.cursor/skills/` | なし（filesystem） | 2.4+ で安定化・他エコシステムの skill も拾う |
| GitHub Copilot | `.github/skills`, `.claude/skills`, `.agents/skills` | なし（filesystem） | `.claude/skills` を自動で拾う |
| OpenCode | `.opencode/skills/`, `.claude/skills/`, `.agents/skills/` | なし（filesystem）＋ plugin で MCP skill 可 | global に `~/.claude/skills/`, `~/.agents/skills/` も |

### 収束の観察（投影コストを下げる鍵）

- `.agents/skills/` を読む host: Gemini CLI、Copilot、OpenCode。
- `.claude/skills/` を読む host: Claude Code、Copilot、OpenCode。

→ **`.agents/skills/` が事実上のクロスエージェント共通ディレクトリになりつつある。** ここへ一度投影すれば複数 host を同時にカバーできる。残る Codex・Cursor は固有パスへの追加投影で拾う。つまり adapter は「共通ディレクトリ投影 1 系統＋host 固有パス投影 N 系統」で足り、host ごとにフル実装を N 本持つ必要はない。

## 6. 全体像（概念スケッチ）

```
KairosChain SkillSet（正本: tools + DSL + knowledge/手順）
        │
        │  知識/手順層のみ抽出（INV-2）＋ 出所・digest・attestation参照を付与（INV-4/5）
        ▼
   投影適応層（transport 非依存・INV-3、それ自体 SkillSet 化可能）
        ├─ レーンA: filesystem 投影
        │     ├─ 共通:  .agents/skills/ , .claude/skills/
        │     └─ 固有:  .codex/skills/ , .cursor/skills/ , .github/skills ...
        └─ レーンB(将来): skill:// MCP resource（SEP-2640 対応 host 向け）

   ※ 実行能力は投影されず、各 host は MCP client として KairosChain に別途接続して tool を呼ぶ
```

## 7. Backlog（手段の選択は実装時に決める・今は決めない）

- 共通ディレクトリ（`.agents/skills/`）投影と host 固有投影の重複をどう解決するか（同名 skill の優先順位・symlink か実体コピーか）。
- 投影の鮮度管理（正本更新の検知と再投影のトリガ、digest 比較によるキャッシュ無効化）。
- 出所・attestation 参照を `SKILL.md` frontmatter のどこに載せるか（各 host が未知フィールドを無視する前提の活用）。
- レーンB を起こす条件（どの host が SEP-2640 に対応したら座席を実装に変えるか）。
- host 適応表の自動追随（host 側のディレクトリ規約変更をどう検知・更新するか）。
- 実行を伴う投影（script 同梱 host）を許す場合の承認フロー（INV-6 の具体化）。

## 8. 明示的な非対象（この段階でやらないこと）

- 実装。本 draft は骨子のみ。実装は別機会。
- SEP-2640 レーンBの先行実装（消費側 host が現れるまで座席確保に留める）。
- 実行能力（Ruby tool）の投影。据え置きが既定。
- 全 host の完全パリティ。共通ディレクトリ収束を使い、カバレッジは段階的に広げる。

## 9. 次の一歩（実装セッションを始めるとき）

1. 既存 plugin projection の投影ロジックを「host adapter」抽象へ一般化できるか点検（core に host 知識が漏れていないか）。
2. `.agents/skills/` 共通投影の PoC を 1 host（Gemini CLI か OpenCode）で試し、収束仮説を実地検証。
3. 出所・digest・attestation 参照の frontmatter 埋め込み方式を確定（INV-4/5 の具体化）。
4. multi-LLM review にかける（design-by-invariant で本 draft を正式設計へ昇格させる段で）。
