# SkillSet Plugin Projection: 自己言及的システム設計のケーススタディ

**著者**: Masaomi Hatakeyama, Claude Opus 4.6
**日付**: 2026-04-12
**所属**: チューリッヒ大学, Functional Genomics Center Zurich
**状態**: ドラフト（Zenodo 投稿前）

---

## 概要

本稿では、KairosChain（自己修正 MCP サーバーフレームワーク）が内部の SkillSet 定義を Claude Code プラグインアーティファクトに投影する機構「SkillSet Plugin Projection」を提示する。この投影はデュアルモードの橋渡しを実現する：SkillSet は MCP ツール（コア機能）と Claude Code ネイティブの skills、agents、hooks（UX レイヤー）として同時に機能する。自己言及的な SkillSet（`plugin_projector`）は自身の記述を投影し、構造的不完全性に境界づけられた再帰的自己投影を実証する。本稿では、鶏と卵問題に対するコンパイラ式ブートストラップ、Phase 0 実験的検証、3-LLM 実装レビュー（Claude Opus 4.6 + Codex GPT-5.4 + Cursor Composer-2）を含む設計プロセスを文書化する。分析にはデュアルボキャブラリ（システム工学用語と KairosChain の九命題）を用いる。

---

## 1. 導入

### 1.1 問題

現代の AI エージェントフレームワークは Model Context Protocol（MCP）を通じて動作し、LLM クライアントが呼び出せるツールを提供する。しかし、LLM クライアント環境（Claude Code、Cursor、Codex）は MCP 単独では提供できないネイティブ機能（skills、サブエージェント、ライフサイクルフック）を持つ。「MCP サーバーが提供するもの」と「クライアント環境ができること」のギャップが UX の制約を生む：ユーザーは MCP ツールを補完するクライアント側機能を手動で設定しなければならない。

### 1.2 アプローチ

KairosChain はプラグインアーティファクトを内部 SkillSet 定義の投影として扱うことでこのギャップに対処する。MCP ツールとクライアント側設定を別々に管理するのではなく、単一の SkillSet 定義が両方を生成する：

- **MCP ツール**（`tools/*.rb`）— MCP プロトコル経由のコア機能
- **プラグインアーティファクト**（`plugin/SKILL.md`、`plugin/agents/*.md`、`plugin/hooks.json`）— Claude Code ネイティブ UX

`PluginProjector` クラスは有効な SkillSet を読み取り、そのプラグインアーティファクトを適切なクライアント側の場所に書き出す。プロジェクトレベル（`.claude/`）とプラグインレベル（ルート）のデュアルモードをサポートする。

### 1.3 貢献

1. MCP サーバーと Claude Code プラグインを橋渡しするデュアルモード投影アーキテクチャ
2. 初期化順序問題に対するコンパイラ式ブートストラップ機構
3. 自身のインターフェースを投影する自己言及的 SkillSet
4. 設計と実装の両方に適用される 3-LLM レビュー方法論
5. 設計修正を導いた実験的検証（Phase 0）

---

## 2. アーキテクチャ

### 2.1 デュアルボキャブラリ

| システム工学用語 | 哲学用語（KairosChain） | 説明 |
|--------------|---------------------|------|
| 投影 | 部分的同一性（命題1） | 同一ソース、二つの表現 |
| ブートストラップ | 自己言及性の時間的展開 | Seed → 投影 → 認識 |
| ダイジェストベース no-op | 構成的記録（命題5） | コンテンツハッシュによる変更検知 |
| 古いアーティファクトのクリーンアップ | オートポイエティックな境界維持（命題2） | ソースを失ったアーティファクトの除去 |
| `_projected_by` タグ | 来歴記録 | 投影されたフックとユーザー作成フックの区別 |
| デュアルモード（project/plugin） | 構造が可能性を開く（命題4） | 単一メカニズム、複数の出力先 |
| settings.json マージ | 非対称的構造的カップリング（命題8） | ホストの設定空間へのゲスト統合 |
| Ruby イントロスペクション | メタ認知的自己言及性（命題7） | 実行時に自身の能力を記述するシステム |

### 2.2 三つの実行パス

```
パス A: MCP（既存、変更なし）
  Claude Code → MCP プロトコル → KairosChain → SkillSet ツール

パス B: Claude Code ネイティブ（新規、補完的）
  Claude Code → .claude/skills/{name}/SKILL.md → ワークフローガイド
              → .claude/settings.json hooks → ライフサイクル自動化
              → .claude/agents/{name}.md → 専用サブエージェント

パス C: Knowledge メタ Skill（新規、間接参照）
  Claude Code → .claude/skills/kairos-knowledge/SKILL.md → L1 knowledge カタログ
              → MCP knowledge_get → オンデマンドコンテンツアクセス
```

パス A がコア機能を提供する。パス B は MCP では提供できない Claude Code ネイティブ機能（agents、hooks、skill discovery）を提供する。パス C は L1 knowledge 層を Claude Code の skill 可視性に橋渡しする。B と C は A を補完するが、置き換えない。

### 2.3 MCP が既に提供するものと Plugin が追加するもの

| 機能 | MCP（既存） | Plugin（新規） |
|------|-----------|--------------|
| ツール実行 | あり | — |
| ツール使用ガイド | あり（instructions, tool_guide） | あり（SKILL.md、補完的） |
| L1 knowledge アクセス | あり（knowledge_get/list） | あり（kairos-knowledge メタ skill、カタログのみ） |
| カスタムサブエージェント | なし | あり（agents/*.md） |
| ライフサイクル自動化 | なし | あり（settings.json の hooks） |
| ユーザー発見性 | なし（ツール名を知る必要） | あり（/help, /skill-name） |
| ワンステップ配布 | なし（.mcp.json 手動設定） | あり（--plugin-dir） |

プラグインの本質的な価値は「Claude にツールの使い方を教える」こと（MCP が既に行っている）ではなく、MCP では提供できない Claude Code ネイティブ機能との統合にある。

---

## 3. ブートストラップ：鶏と卵問題の解決

### 3.1 問題

Claude Code はセッション開始時に skills と hooks を読み込み、その後 MCP サーバーを起動する。PluginProjector は MCP の `handle_initialize` で実行される。したがって、投影された skills は初回投影をトリガーするセッション中には利用できない。

### 3.2 コンパイラのアナロジー

```
GCC ブートストラップ:
  Stage 0: 既存コンパイラで最小版 GCC をビルド
  Stage 1: Stage 0 で完全版 GCC をビルド
  Stage 2: Stage 1 で GCC を再ビルド（検証）

KairosChain ブートストラップ:
  Stage 0: Seed（plugin.json + .mcp.json + seed SKILL.md）— リポジトリにコミット
  Stage 1: MCP initialize → PluginProjector.project! — skills/, agents/, hooks を書き出し
  Stage 2: /reload-plugins → Claude Code が新しいアーティファクトを認識
```

### 3.3 セッションタイムライン

```
[セッション 1 — 初回使用]
  1. Claude Code 起動 → seed SKILL.md（最小ガイド）を読み込み
  2. MCP サーバー起動 → handle_initialize → PluginProjector が全アーティファクトを投影
  3. ユーザーが MCP ツールを呼び出し → PostToolUse hook（設定済みなら）→ no-op（投影済み）
  4. ユーザーが /reload-plugins を実行 → per-SkillSet skills が可視化
  5. 完全なプラグイン機能が利用可能

[セッション 2+ — 以降の使用]
  1. Claude Code 起動 → 前回投影済みの skills（ディスク上の完全セット）を読み込み
  2. MCP サーバー起動 → handle_initialize → project_if_changed! → no-op（ダイジェスト一致）
  3. 完全なプラグイン機能が最初から利用可能
```

### 3.4 Phase 0 検証

ブートストラップ設計は実装前に実験的に検証された：

| テスト | 結果 | 設計への影響 |
|--------|------|------------|
| 複数の `.claude/skills/` が共存 | PASS | per-SkillSet 投影が実行可能であることを確認 |
| 追加 frontmatter フィールドが無視される | PASS | `_projected_by` 来歴情報が安全 |
| Hooks は settings.json に記述（hooks.json ではない） | PASS | Project モードは settings.json に書き出し |
| PostToolUse stdout → Claude | **FAIL** | `additionalContext` JSON に再設計 |
| /reload-plugins が新しい skills を認識 | PASS | ブートストラップ Stage 2 を確認 |
| settings 変更時の hooks 自動リロード | PASS | /reload-plugins なしで hooks が有効 |

Phase 0 の失敗（stdout が Claude に届かない）は重大な設計修正をもたらした：hook 出力は stdout ではなく `additionalContext` JSON を使用し、設計はこれを Claude Code ハーネスへの依存として明示的に文書化している（Non-Claim #6）。

---

## 4. 自己言及ループ

### 4.1 構造

`plugin_projector` SkillSet は `plugin/` ディレクトリを持つ SkillSet そのものである：

```
plugin_projector/
├── tools/plugin_project.rb     → MCP ツール:「投影を実行」
├── plugin/SKILL.md             → 「投影の使い方」+ <!-- AUTO_TOOLS -->
└── plugin/hooks.json           → 「Skill 変化を監視」
```

`PluginProjector.project!` が実行されると、`plugin_projector` 自身を含む全ての有効な SkillSet を処理する：

1. `plugin_projector/plugin/SKILL.md` を読み取り
2. Ruby リフレクションで `PluginProject` ツールクラスをイントロスペクション
3. `input_schema` からツールドキュメントを生成
4. `.claude/skills/plugin_projector/SKILL.md` に書き出し
5. `plugin_projector/plugin/hooks.json` を `.claude/settings.json` にマージ

投影された hooks は `skills_promote`、`skills_evolve` 等を監視する。これらのツールが発火すると、hooks が再投影をトリガーし、hooks 自体が更新される — 自己言及ループが閉じる。

### 4.2 哲学的分析

**命題1（自己言及性）**: プラグインアーティファクトのガバナンスは SkillSet のガバナンスと同一である。同じブロックチェーン記録、アテステーション、交換メカニズムが適用される。これは真正な構造的自己言及性である：プラグインを統治する主体がプラグインとして投影される主体そのものである。

**精度に関する注記**: 自己投影は再帰的ファイル生成であり、ゲーデル的自己言及ではない。真のゲーデル的瞬間は、複数の SkillSet が同時に hooks を寄与する際の投影結果の予測不可能性にある — 他の SkillSet の hooks が自身と相互作用するため、投影者はマージされた `settings.json` を完全には予測できない。

**命題2（部分的オートポイエーシス）**: ブートストラップループ（seed → 投影 → hooks → 再投影）は部分的なオートポイエティック閉合を達成する。閉合が部分的である理由：
- Stage 2 が Claude Code の `/reload-plugins` に依存（ハーネス依存）
- 投影は Claude Code の設定空間にゲストとして書き込む
- システムは自身の実行基盤（Ruby VM、ファイルシステム）を変更できない

**命題4（構造が可能性を開く）**: SkillSet フォーマット拡張（`plugin/` ディレクトリ）が「Claude Code ネイティブ統合」の可能性空間を開く。デュアルモードアーキテクチャ（project/plugin）はさらにこの空間を複数のデプロイ先に拡張する。

**命題6（不完全性が駆動力）**: 投影は不可逆（lossy）である — `tools/*.rb` の実行コードは投影されず、メタデータ記述のみ。投影結果から元の SkillSet を復元することもできない。この三重の不完全性（lossy、予測不可能、不可逆）が永続的な進化を駆動する：各投影は現在のシステム状態の新たな解釈である。

**命題8（共依存的存在論）**: KairosChain と Claude Code の関係は非対称的構造的カップリングである。KairosChain は Claude Code の仕様（settings.json 形式、skill 発見パス、hooks セマンティクス）に適応するが、Claude Code は KairosChain に適応しない。これは相互依存というより片利共生に近い。カップリングは settings.json — 両システムが読み書きする共有テキスト — を通じて深化する。

### 4.3 Non-Claims（主張しないこと）

1. 完全なオートポイエティック閉合は達成していない — 外部ハーネスに依存
2. Hooks の実行は構造的に保証されない — Claude Code ハーネスの管轄
3. 投影はスナップショットであり、リアルタイム同期ではない
4. 「Plugin IS MCP Server」は完全な同一性ではない — MCP がコア、Plugin は UX レイヤー
5. クライアント実行ガバナンスは提供しない — sandbox、cache、reload はハーネスの管轄
6. ブートストラップ Stage 2 は `/reload-plugins` に依存 — 自動呼び出しは保証されない
7. 初回セッションでは per-SkillSet skills は限定的 — seed ガイドのみ即座に利用可能
8. Self-hosting は達成していない — ブートストラップは人間によるシーディング + ハーネス依存
9. 投影は不可逆（lossy）— プラグインアーティファクトから SkillSet を復元できない
10. 投影は部分情報のみを含む — 実装コードは投影されない
11. Knowledge メタ skill はカタログのみ — コンテンツは MCP 経由でオンデマンドアクセス
12. settings.json マージは Claude Code 仕様への依存 — `.claude/hooks/` がサポートされれば陳腐化する可能性がある

---

## 5. 3-LLM レビュー方法論

### 5.1 プロセス

実装は各フェーズでマルチ LLM レビューを受けた：

| フェーズ | レビュー種別 | LLM | 主要発見 |
|---------|-----------|------|---------|
| 設計 v2.2 | Persona Assembly（6ペルソナ） | Claude Opus 4.6 | P1×5: ダイジェスト統一、イントロスペクションフォールバック、ユーザー hooks 保全 |
| 設計 v2.2r1 | Persona Assembly | Claude Opus 4.6 | P1×5: atomic write、JSON パースエラー、additionalContext テスト |
| Phase 2 | 集中 Persona Assembly | Claude Opus 4.6 | P1×3: agent-monitor ワークフロー、Bash 禁止、scaffold 更新 |
| Phase 3 | 集中 Persona Assembly | Claude Opus 4.6 | P1×2: knowledge 重複、seed フォールバック内容 |
| Phase 4 | 実装レビュー | Claude + Codex + Cursor | P0/P1×7: CLI typo、パストラバーサル、cleanup 安全性、hook インジェクション |

### 5.2 収束パターン

Phase 4 の 3 つの LLM は全て独立して同じトップイシューを特定した：

| イシュー | Claude | Codex | Cursor |
|---------|--------|-------|--------|
| CLI `SkillsetManager` typo | P0 | P1 | P0 |
| `cleanup_stale!` パス安全性 | P1 | P0 | P0 |
| `ss.name` パストラバーサル | P1 | P0 | P0 |
| CLI knowledge 重複 | P0 | P1 | P1 |

同じイシューに対する 3/3 の収束は、これらが偽陽性ではなく真正な問題であるという高い信頼性を提供する。

### 5.3 観察された LLM 特性

- **Claude Opus 4.6**: 哲学的整合性と自己言及性分析に最も強い。ゲーデル的精度の問題を特定。
- **Codex GPT-5.4**: 最も深いセキュリティ分析。hook コマンドインジェクションと knowledge ダイジェストの不完全性を特定。
- **Cursor Composer-2**: モード検出の不整合とクロスプラットフォームの懸念に最も徹底的。

### 5.4 設計レビューと実装レビューのバグカテゴリ

設計レビュー（Phase 2-3）はアーキテクチャ上の問題を発見した：エージェントワークフローの仕様不足、hooks トリガースコープ、scaffold の一貫性。実装レビュー（Phase 4）はコードレベルのバグを発見した：クラス名の typo、パス安全性、レースコンディション。これらのカテゴリは補完的である — 設計レビューだけでは CLI の NameError は発見できず、実装レビューだけでは agent-monitor の仕様不足は発見できなかった。

---

## 6. 実装サマリー

### 6.1 メトリクス

| メトリクス | 値 |
|----------|-----|
| 新規コード（plugin_projector.rb） | 約430行 |
| 変更ファイル | 10 |
| 新規 SkillSet テンプレート | 4（agent, exchange, creator, plugin_projector） |
| テスト数 | 30（Phase 1）+ 18（Phase 2）+ 13（Phase 3）= 61 |
| テスト失敗 | 0 |
| レビューラウンド | 6（設計）+ 1（実装）= 7 |
| P0/P1 発見（合計） | 22 |
| P0/P1 解決済み | 22 |

### 6.2 主要な実装決定

| 決定 | 根拠 |
|------|------|
| Atomic write（Tempfile + rename） | settings.json の auto-reload が部分的 JSON を読む可能性 |
| `_projected_by` タグによる hook 所有権 | ユーザー設定への最小限の介入 |
| `SAFE_NAME_PATTERN` バリデーション | 悪意ある SkillSet 名からのパストラバーサル防止 |
| `safe_path?` 境界チェック | cleanup_stale! の多層防御 |
| ダイジェストに description/tags を含む | knowledge メタデータ変更の検知（Codex の発見） |
| `ALLOWED_HOOK_COMMANDS` 警告 | 非標準コマンドへのアラート（ブロックせずに警告） |

---

## 7. 結論

SkillSet Plugin Projection は、MCP サーバーフレームワークが自己言及的投影を通じてクライアントプラグインエコシステムに拡張できることを実証した。メカニズムは構造的不完全性（lossy 投影、ハーネス依存、非対称カップリング）に境界づけられるが、真正な再帰的自己投影を達成した：PluginProjector SkillSet は自身のインターフェース記述を投影する。

実験的検証アプローチ（Phase 0）は不可欠であった — Claude Code の hooks が settings.json を使用すること（別の hooks.json ではなく）、PostToolUse の stdout がモデルに届かないことの発見は、理論的分析だけでは捕捉できなかった重大な設計修正をもたらした。

3-LLM レビュー方法論は補完的な視点を提供する：設計レビューがアーキテクチャのギャップを捕捉し、実装レビューがコードレベルのバグを捕捉し、LLM 間の収束が発見への信頼性を提供する。

---

## 参考文献

- KairosChain 九命題: `CLAUDE.md`
- KairosChain 哲学（3レベル）: `docs/KairosChain_3levels_self-referentiality_en_20260221.md`
- 設計文書: `log/skillset_plugin_projection_design_v2.2_20260404.md`
- Phase 4 レビュー: `log/skillset_plugin_projection_phase4_implementation_review_20260412.md`, `log/phase4_review_codex_gpt5.4_20260412.md`, `log/phase4_review_cursor_composer2_20260412.md`
- Claude Code Plugin 仕様: https://code.claude.com/docs/en/plugins
