# KairosChainとClaude Code Skills：哲学的立場と読み取り互換性

**日付**: 2026-02-16  
**著者**: Masaomi Hatakeyama

---

## 1. 二つの異なる哲学

### Claude Code Skills：実行指向の知識

Claude CodeのSkillsシステムは**即座の実用性**を中心に設計されています。Skills、Commands、Agents、Hooksはすべて作業を遂行するためのツールです：

| コンポーネント | 目的 | 形式 |
|-----------|---------|--------|
| **Skills** (SKILL.md) | AIが自動参照する知識 | Markdown |
| **Commands** | ユーザーが呼び出すプロンプト (`/name`) | Markdown |
| **Agents** | 専門サブエージェント | Markdown |
| **Hooks** | イベント駆動の自動処理 | JSON + シェルスクリプト |

主な特徴：
- **フラット構造**：すべてのSkillは等価で、階層やレイヤーがない
- **変更追跡なし**：修正の監査証跡が残らない
- **制約なし**：どのSkillでもいつでも自由に変更可能
- **即時コンテキスト**：関連する時にロードされ、使用後は破棄される

Claude Code Skillsが答える問い：**「AIが今必要とする知識は何か？」**

### KairosChain：進化指向のメタレッジャー

KairosChainは**監査可能な能力進化**を中心に設計されています。変更そのものを第一級市民として扱います：

| レイヤー | 法的アナロジー | 変更制約 | 記録 |
|-------|---------------|-------------------|-----------|
| **L0**（憲法/法律） | 憲法 | 人間の承認が必須 | ブロックチェーン完全記録 |
| **L1**（条例） | 条例 | 自由（AI変更可） | ハッシュ参照 |
| **L2**（指令） | メモ | 自由 | 個別操作の記録なし |

主な特徴：
- **階層構造**：知識に異なるレベルの保護がある
- **変更追跡**：すべてのL0/L1の変更がプライベートブロックチェーンに記録
- **自己参照的制約**：L0スキルが自身の変更に関するルールを定義
- **ライフサイクル管理**：陳腐化検出、アーカイブ、レイヤー間の昇格

KairosChainが答える問い：**「この知能はどのように形成され、それを検証できるか？」**

### 本質的な違い

```
Claude Code Skills:  「便利な知識文書」
KairosChain:         「知識進化の監査可能な台帳」
```

これらは**直交する関心事**であり、競合するアプローチではありません。Claude Codeはどの知識を使うかを管理し、KairosChainは知識がどう変化するかを管理します。

---

## 2. KairosChainがCommands、Agents、Hooksを複製すべきでない理由

### 関心の分離

| 責務 | 担当 |
|----------------|-------|
| 何を実行するか（Commands, Agents, Hooks） | Claude Code |
| 知識がどう進化するか（レイヤー、制約、監査） | KairosChain |

KairosChainはClaude Codeの実行コンポーネントの**上位のメタレイヤー**として機能します。Commands、Agents、Hooksが参照する知識を管理するのであって、実行ロジック自体を管理するのではありません。

アナロジー：

- Claude Code Commands/Agents/Hooks = **法律を適用する裁判官や警察**
- KairosChain = **法律を起草・改正・記録する立法機関**

立法機関が警察活動や裁判を行う必要はありません。

### Hooksは知識ではない

CommandsとAgentsはMarkdownベースであり、理論的にはL1知識として保存可能です。しかし、Hooksは根本的に異なります — OSレベルのイベントでシェルコマンドをトリガーするJSON設定です。これは実行の関心事であり、知識の関心事ではなく、KairosChainのスコープ外です。

### Minimum-Nomic原則

KairosChainはMinimum-Nomic原則に従います：ルールは変更可能だが、最小限の必要な制約が適用される。実行レイヤーの関心事（Commands, Agents, Hooks）をKairosChainに追加することは、制約を知識管理から実行管理に拡大することになり、この原則に反します。

---

## 3. 読み取り互換性：L1知識をClaude Code Skillsとして

KairosChainはClaude Codeの実行コンポーネントを複製すべきではありませんが、L1知識を**Claude Code Skillsとして読み取り可能にする**ことには大きな価値があります。これは一方向の互換性です：

```
KairosChain L1 知識  ──読み取り──▶  Claude Code Skills
                      （OK：監査のバイパスなし）

Claude Code  ──書き込み──▶  KairosChain L1 知識
                      （NG：ブロックチェーン記録をバイパス）
```

### 読み取り互換性が有効な理由

1. **KairosChainなしでの知識共有**：KairosChainを使わないチームや個人でも、十分に整備されたL1知識を標準的なClaude Code Skillsとして活用できる。

2. **GitHubベースの知識配布**：成熟したL1知識をGitHubリポジトリで共有可能。他のユーザーはリポジトリをクローンし、RubyやKairosChain MCPサーバーなしで知識をClaude Code Skillsとして参照できる。

3. **段階的な導入**：新規ユーザーはL1知識をプレーンなSkillsとして使い始め、後からKairosChainを導入して変更追跡とライフサイクル管理を得ることができる。

4. **プラグインエコシステムへの参加**：KairosChainの知識資産がClaude Codeプラグインマーケットプレースで発見可能になる。

### 仕組み

KairosChain L1知識はすでにYAML frontmatter + Markdown形式を使用しており、Claude Code Skillsと互換性があります。主な違いは：

| フィールド | KairosChain L1 | Claude Code Skills | 互換性 |
|-------|----------------|-------------------|---------------|
| `name` | `snake_case` | `kebab-case` | 命名規則が異なる |
| `description` | あり | あり | **互換** |
| `version` | あり | 使用なし | Claude Codeが無視 |
| `layer` | あり | 使用なし | Claude Codeが無視 |
| `tags` | あり | 使用なし | Claude Codeが無視 |

Claude Codeは未知のfrontmatterフィールドを無視するため、**KairosChain L1ファイルはそのまま**Claude Codeで読み取れます。調整が必要なのはディレクトリ構造のみです：

```
KairosChain L1:           knowledge/my_knowledge/my_knowledge.md
Claude Code Skills:       skills/my-knowledge/SKILL.md
```

### 実装アプローチ

#### アプローチA：シンボリックリンクまたはコピー（手動）

L1知識をClaude Code Skillsとして使いたいユーザーはシンボリックリンクを作成できます：

```bash
# L1知識をClaude Code Skillsディレクトリにシンボリックリンク
ln -s /path/to/knowledge/my_knowledge/ ~/.claude/skills/my-knowledge
```

#### アプローチB：プラグイン配布

プラグインの `skills/` ディレクトリにL1知識を含める。現在のKairosChainプラグインは既に `skills/kairos-chain/SKILL.md` でこれを行っています。

#### アプローチC：エクスポートツール（将来）

`knowledge_export` MCPツールにより、選択したL1知識をClaude Code Skills形式にエクスポートし、命名規則やディレクトリ構造を自動調整する機能。

### 重要なルール：書き込みはKairosChain経由で

読み取り互換性は書き込み互換性を意味しません。L1知識へのすべての変更はKairosChainの `knowledge_update` ツール経由で行う必要があります：

- ハッシュ参照がブロックチェーンに記録される
- 変更履歴が維持される
- ライフサイクル管理（陳腐化検出、アーカイブ）が継続して機能する

KairosChainの外部から直接 `.md` ファイルを編集すると、ブロックチェーン記録との整合性が失われます。これは設計上の意図です — KairosChainの価値は監査証跡にあります。

---

## 4. ユースケース：成熟したL1知識のGitHub共有

確立されたL1知識を共有するための実践的ワークフロー：

```
ステップ1：知識がKairosChainのL2 → L1昇格を通じて成熟
           （ブロックチェーンに完全な監査証跡とともに記録）

ステップ2：安定したL1知識をパブリックGitHubリポジトリにコミット
           （例：「my-coding-conventions」や「genomics-analysis-patterns」）

ステップ3：他のユーザーが二つの方法で知識を利用：

           オプションA（KairosChainあり）：
           - リポジトリをclone/subtree
           - 完全な監査付きのL1として追跡

           オプションB（KairosChainなし）：
           - リポジトリをclone
           - .mdファイルをClaude Code Skillsとして参照
           - 監査証跡なし、だが知識は即座に利用可能
```

このアプローチはKairosChainの哲学と完全に整合します：

- **進化可能**：知識は階層化されたシステムを通じて進化する
- **監査可能**：進化プロセスが記録される
- **共有可能**：結果は普遍的に読み取り可能な形式で共有される
- **非強制的**：受領者が自身のガバナンスレベルを選択できる

---

## 5. まとめ

| 観点 | 立場 |
|--------|----------|
| KairosChainがCommands、Agents、Hooksを複製すべきか？ | **No** — これらは実行の関心事であり、知識の関心事ではない |
| L1知識をClaude Code Skillsとして読み取り可能にすべきか？ | **Yes** — 読み取り専用の互換性により、KairosChain導入を強制せずに知識共有が可能 |
| Claude Codeが直接L1に書き込めるべきか？ | **No** — 監査証跡を維持するため、書き込みはKairosChain経由で行う必要がある |
| KairosChainの哲学と整合するか？ | **Yes** — 知識の進化は監査可能であるべきだが、消費は自由であるべきという原則に従う |

> *「KairosChainが答えるのは『この結果は正しいか？』ではなく『この知能はどう形成されたか？』である」*
>
> 読み取り互換性は、知能がどう形成されたかを知った上で、それを自由に共有できることを保証する。
