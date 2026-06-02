---
タイトル: plugin_projector — instance mode artifact type の追加 (v4)
状態: round 4 multi-LLM review 用ドラフト
読者: masaomi（review 用）
スタイル: 設計のみ（実装の選択は書かない）
日付: 2026-05-06
著者: Masaomi Hatakeyama (Claude Code, Opus 4.7 起草)
置き換え対象:
  - v2 (round 2): scope 膨張、既存 pipeline を 12 個の invariant で書き直してしまった
  - v3 (round 3): scope は修正したが実装レベルに drift（method 名 / path / marker 文字列 / code-reuse 主張）し、それが矛盾発見の surface を生んで 4 件の P0 を生んだ
実証根拠: .kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/
---

# 何を変えるか

`plugin_projector` に artifact type を 1 つ追加する。新たな artifact type は、アクティブな instance mode 本体（Masa Mode、Tutorial Mode 等）。既存の projection pipeline に、skills / agents / hooks / knowledge meta skill と並ぶ形で配置される。

# なぜ必要か

Theme A 検証ログに記録された 3 つの観察上の欠落:

1. **MCP `instructions` channel は Claude Code harness によって途中で切り捨てられる。** mode 本体の identity 部分（冒頭）は届くが、normative 部分は届かない。記録されている instance constitution と動作している instance constitution が乖離する — Prop 5 違反。

2. **Agent tool sub-agent は project CLAUDE.md は継承するが MCP `instructions` は継承しない。** 本プロジェクトの multi-LLM review で Reviewer 1 を担う Persona Agent team は、アクティブな instance mode を**そもそも一切受け取っていなかった**。これは MCP truncation を直しても解決しない、より大きいギャップ。

3. **CLAUDE.md `@`-import 経路は実証的に privileged である。** parent / `claude -p` subprocess / Agent sub-agent の 3 surface 全てに、107KB まで欠損なく届く。Opus 4.6 と 4.7 で挙動差なし。ただし single-level（深さ 1）のみで、nested `@`-import は再帰展開されない。

# 新しい artifact type が満たすべき性質

新しい artifact type は、既存の全 artifact type と**同じ projection 契約**で扱われる。具体的には:

- **特権的配信（Privileged delivery）.** mode 本体は、MCP truncation cap を実証的に bypass できる経路で model に届く（Theme A）。MCP channel は identity と「記録された本体への pointer」のみを運ぶ。本体そのものは privileged 経路で配信される。
- **契約の対等性（Contract parity）.** 新しい artifact type は、既存の artifact type と同じく、原子的に書かれ、source が変わらなければ冪等で、manifest で track され、source から消えれば cleanup され、監査される。新しい契約も例外的経路も導入しない。
- **単一段階の合成（Single-level composition）.** privileged 経路に渡される本体は self-contained。mode 本体の合成（共通 preamble、include 等）は、本体が projection pipeline に入る前、registry resolution の段階で完了している。
- **scope の継承（Scope inheritance）.** 既存の projection pipeline がサポートする scope（1 プロジェクト 1 working tree、single writer、worktree 分割なし）と同じ scope を、新 artifact type も継承する。広げも狭めもしない。
- **非特権 consumer に対する記録到達性（Recorded reachability）.** CLAUDE.md を読まない consumer（他の MCP client、headless ツール等）も、registry を直接照会することで記録された本体に到達できる。truncation 問題は privileged 経路に対して解決される。他の consumer に対しては誤魔化さない — registry 直接照会で取得する。

# Scope 外（既存 pipeline と同じ）

新 artifact type が新たに導入することも、新たに対応することも要求されない事項:

- 1 プロジェクトに複数の KairosChain インスタンスを共存させる場合の投射
- `.git` を共有する git worktree のトポロジ
- 複数の projector プロセスが同時に動く場合
- privileged 経路が依存する host file が第三者に書き換えられた場合の自動回復
- projector 自身の self-projection（projector レベルでの Prop 1 自己言及性 — 哲学的に open）

これらの制約は既存 artifact type にも等しく適用される。新 artifact type は無修正でこれを継承する。

# 移行

本変更後、アクティブな instance mode は 3 surface（parent / subprocess / sub-agent）に privileged 経路で届く。MCP channel は、registry が「本プロジェクトに対して新 projection regime が有効」と確認した後、identity と pointer のみに縮小される。それまでは MCP channel は今と同じもの（truncated body）を運び続ける — 後方互換のため。

# Open question（真に open なもの。実装選択を open に見せかけたものではない）

1. **本体サイズの policy 閾値.** privileged 経路は 107KB まで実証されている。registry はある閾値を超える本体を refuse すべき（per-turn token cost を予測可能にするため）。閾値そのものは policy 判断。

2. **個人 mode と共有 mode の区別.** 個人 mode（個人憲法を持つ）と共有 mode（Tutorial 等）が混在する。registry record がこの区別を data として持つかどうか、projection pipeline が下流の policy（投射ファイルの gitignore default 等）でこの情報を参照するかどうかは、registry data model の問題で、本変更では決めない。

3. **pointer payload の中身.** 移行後の MCP channel が運ぶ identity と reference の正確な形。最低限は、非特権 consumer が registry から本体を取得するのに足る情報。最大は truncation cap の制約内。具体的な形は open。

# 検証根拠

- **Theme A 検証ログ**: `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`。privileged 経路が parent / subprocess / Agent sub-agent の 3 surface に対して 107KB まで欠損なく配信することを Opus 4.6 / 4.7 両方で実証。single-level のみ。
- **既存 projection 契約**: 本リポジトリの `KairosMcp::PluginProjector`。「contract parity」と書いた性質はすべて実装フェーズで code を直接参照して証明する。設計フェーズでは parity が成立する、とだけ主張する。

# masaomi さんへの review チェックポイント

1. **5 つの性質**（特権的配信 / 契約の対等性 / 単一段階の合成 / scope の継承 / 記録到達性）に過不足ないか。「これも入れるべき」「これは要らない」があれば指摘ください。
2. **Out of scope の 5 項目**に、本来本変更で扱うべきものが混じっていないか。
3. **Open question の 3 件**が「真に open」か「実装選択を open に見せかけた」か。私は前者として書いたつもりですが、どれかが implementation choice の偽装だと感じたら指摘ください。
4. **本文の中に実装レベルの主張**（method 名・path・marker 文字列・code reuse 主張・行番号 ref）が紛れ込んでいないか — v3 で 4 件 P0 を生んだ failure mode を再発させないため、最終チェックです。
