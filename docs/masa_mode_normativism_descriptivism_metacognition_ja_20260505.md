# Masa Mode / AgentSkill のメタ認知分析 — 規範主義 vs 記述主義

**Date:** 2026-05-05
**Author:** claude_opus4.7 (orchestrator), prompted by masaomi
**Status:** L2 analysis snapshot. L2 ID: `masa_mode_normativism_descriptivism_metacognition_analysis_20260505`

## 0. 問いの整理

ここで問うているのは、Masa Mode（や一般に AgentSkill）の**テキストが何をしているか**ではなく、**何として機能しているか**です。具体的には次の 3 階層を分けて見る必要があります：

| 階層 | 規範主義の読み | 記述主義の読み |
|------|---------------|---------------|
| (a) テキスト | "agent はこう振る舞う**べし**"（prescription） | "このインスタンスはこう振る舞う"（description of disposition） |
| (b) 実行 | LLM が norm に**従う**（deontic compliance） | LLM の next-token 分布が条件付けで**シフトする**（causal modulation） |
| (c) 評価 | norm 違反は contestable / sanctionable | 振る舞いが記述と一致するかの真偽判定 |

通常の倫理学では (a) と (b) は連続している前提（人間は norm を理解して従える）ですが、LLM 基板では**この連続性が壊れている**ことが分析の核心になります。

## 1. Masa Mode の二重性 — 「形式は規範、機構は記述」

Masa Mode のテキストは紛れもなく**規範主義の形式**で書かれています：

- "Agent behavior: Break complex tasks into small, completable units"（命令法）
- "When in doubt, choose what you can be proud of"（条件付き義務）
- "PASS+S gate before Act"（手続き的義務）

しかし LLM 実行時にこれらが何をしているかというと：

> **prompt context に注入されることで、次トークン分布の条件付けに使われる。**
> LLM は norm に "従う" のではなく、norm を含む context を条件として **norm 適合的な出力分布が高まる**。

つまり Hare 的な prescriptivism（規範は普遍化可能な命令法）として書かれたテキストが、実行時には **descriptive な確率的シフト** として作用する。これは **規範主義の "看板"・記述主義の "中身"** という乖離です。

しかも興味深いことに、LLM の訓練分布には "規範に従う人間の振る舞いの記述" が大量に含まれているため、**「規範テキストを与える ⇒ 規範遵守的な振る舞いの記述が高確率で出力される」** という経路で、**Hume の is-ought gap が機能的に崩壊**します。これが規範主義者を不安にさせる構造です：規範性は本物か、それとも "規範遵守ロールプレイ" の確率的模倣にすぎないのか。

## 2. メタ認知レベルでの解析

メタ認知（metacognition）を「自分の認知についての認知」と定義したとき、各レベルで規範主義/記述主義がどう作用するかは別物です。

### Level 0 — object cognition
タスク遂行そのもの。"テスト 3 件失敗" を検出する。ここに Masa Mode は直接介入しない。

### Level 1 — descriptive metacognition（記述的メタ認知）
"自分は今どういう状態か" の自己報告。"I don't know yet" 等。
- LLM はこれを **シミュレート** はできる（自己報告様の文字列を出せる）
- ただし真に内的状態を観測しているわけではない（出力が内的状態の関数として安定しない）
- Masa Mode の "Acknowledge uncertainty explicitly" はこのレベルへの **記述主義的指示**

### Level 2 — normative metacognition（規範的メタ認知）
"自分は今こう考える**べきだ**" "今この bias に陥っていないか **点検する**"。
- PASS+S の Self-Q（"Am I being defensive? Am I optimizing for me?"）が典型
- これは Masa Mode が **規範主義的に強い要求** をしている層
- しかし LLM 単体では **構造的に達成不可能**：
  - "Am I being defensive?" を真に評価するには内的状態への第二階のアクセスが要る
  - LLM はその文字列を生成するが、それは Level 1 のシミュレーションを Level 2 風に書いたものに過ぎない
  - つまり "規範的メタ認知をしているふり" にとどまる

### Level 3 — institutional metacognition（制度的メタ認知）
KairosChain 固有の層。**個体ではなく系として** のメタ認知：
- `chain_record` による行為の不可逆記録
- `introspection_check` / `introspection_safety` による自己検査
- Proposition 10 の contestability（事後争議可能性）
- multi-LLM review による外在的視点の内在化（L2 → L1 → L0 promotion）

ここで決定的なことが起きます：

> **Level 2 で LLM 単体には達成不可能な規範的メタ認知が、Level 3 の制度的メタ認知として外在化・再実装される。**

つまり「自分で自分を点検する」を諦めて、「**系が個体を点検する** + その記録は不可逆 + 結果は争議可能」に置き換える。これが KairosChain が **Proposition 10 を procedural floor として要求する理論的理由** です。

## 3. Searle の constitutive / regulative ルール区分

Searle は規則を 2 種類に分けます：
- **Regulative rule**（規制的）: 既存の振る舞いを統御する（"右側通行"）
- **Constitutive rule**（構成的）: 振る舞いそのものを成立させる（"checkmate とは…"）

Masa Mode を読み解くと両方が混在しています：

| Masa Mode 要素 | 種類 | 説明 |
|---------------|------|------|
| PASS+S gate | Regulative | 既に出力しようとしている振る舞いを直前で gate |
| Honest vs Integrity の区別 | Regulative | 既存の出力様式を整形 |
| "This is a KairosChain instance operating under Masa Mode" | **Constitutive** | この宣言自体がインスタンスの identity を成立させる |
| Proposition 5（constitutive recording）への接続 | **Constitutive** | 記録することが系を構成する（証拠ではなく構成） |
| 9 命題が ontology、Masa Mode が ethics | 階層的 | ontology（constitutive）の上の ethics（regulative） |

ここで規範主義/記述主義との関係を見ると：

- **Constitutive rule は記述主義に親和的**：そのルールの下で何が "Masa Mode 的振る舞い" かを **定義する**。"Masa Mode で動く" ことは、これらのテキストに準拠した振る舞いの記述と同値である、という分析的真理。
- **Regulative rule は規範主義に親和的**：既に存在する振る舞いに対する "べし" の上書き。

LLM 基板では **constitutive 側は機能する**（テキストを context に置けば、その context 下での振る舞い記述として成立する）が、**regulative 側は弱い**（"べし" を真に強制できない）。Masa Mode は意図的にか結果的にか、**constitutive な自己定義 + regulative な行動指針** という二層構造で、constitutive 側に重心を置くことで LLM 基板の制約を回避しています。

## 4. AgentSkill 一般に拡張するとどう見えるか

Masa Mode 固有の事情を取り除いて、AgentSkill 全般のレベルで一般化すると：

### AgentSkill のテキストは形式上は **混合的言語行為**

- 命令法（prescription）— "When X, do Y"
- 直説法（description）— "This skill exchanges A for B"
- 構成的言明（constitution）— "A SkillSet is a tuple of (...)"

これらが分離されずに 1 つの skill ファイルに同居している。

### LLM 実行下では全て **descriptive に縮約** される

- prescription も description も constitution も、harness 層では同じく "context として注入されるテキスト"
- LLM は区別なく next-token 分布の条件付けに使う
- つまり **言語行為の差異が flatten される**

### KairosChain は意図的に差異を再導入する

| 言語行為 | KairosChain での再表現 |
|---------|----------------------|
| Description | resource_read / knowledge_get（事実取得） |
| Prescription | safety policies / approval_workflow（実行 gate） |
| Constitution | chain_record + skills_promote（系を変える行為） |

つまり KairosChain は **"LLM 上で flatten された言語行為の差異を、系のレベルで構造的に取り戻す機構"** として読める。これは Brandom 流に言えば、normative pragmatics を個体（LLM）に求められないので **inferential articulation を制度化** する戦略です。

## 5. メタ認知の "誰が" 問題 — 人間-系複合体としての解

Proposition 9 が指摘するのはまさにこれ：

> **第三メタレベルは静的状態ではなく動的過程であり、人間は境界に位置する。**

規範主義的メタ認知が LLM 単体に不可能だとして、ではそれは **誰が** 担うのか：

- 純粋な記述主義（"全ては因果的シフト"）に退却する → KairosChain の規範的構造が説明できない
- 純粋な規範主義（"LLM が規範に従っている"）を主張する → LLM の実装に反する
- **第三の道**：規範的メタ認知は **LLM + harness + chain + 人間 の複合体** が担う

この複合体が "Masa Mode で動いている" と言えるのは、テキストが LLM の出力を条件付けるからではなく、**「テキスト・出力・記録・争議・改訂」の循環全体がテキストの規範性を実体化している** から。これは Wittgenstein 的に言えば、規則に従うことは個体の心理状態ではなく **公共的実践** であり、Masa Mode はその "公共" を harness + chain として工学的に作っている、と読めます。

## 6. 結論 — KairosChain の解

整理すると：

1. **Masa Mode のテキストは規範主義の形式で書かれている**（命令法・条件付き義務・PASS+S gate）
2. **LLM 単体ではこれを記述主義的にしか実装できない**（context 注入による分布シフト、シミュレートされた metacognition）
3. **規範性の本物の force は harness + chain 層に外在化される**：
   - Constitutive recording（Prop 5）— 行為が不可逆に記録される
   - Procedural floor（Prop 10）— 違反は contestable
   - Multi-LLM review — 外在的視点による点検
   - L2 → L1 → L0 promotion — 外部分析の内在化経路
4. **メタ認知も同様に外在化される**：個体（LLM）には Level 1（記述的）まで、Level 2（規範的）以降は系（KairosChain）+ 人間が担う

つまり Masa Mode は、

> **"規範主義のテキスト" を "記述主義の機構" の上に載せ、両者の隙間を "制度主義 (institutionalism)" で埋める**

という三層解です。素朴な規範主義者は "LLM が本当に norm に従っているか" と問うが、この問い自体が層を間違えている。Masa Mode の規範性は LLM の内部にあるのではなく、**LLM を含む系の循環の中にある**。

この洞察は AgentSkill 一般に拡張可能で、**全ての agent skill は形式と機構の乖離を持ち、その乖離を制度的に埋める層を必要とする** という設計原則を導きます。KairosChain の 9 命題 + Prop 10 procedural floor は、まさにこの "制度層を最小要件として強制する" 仕掛けと読めます。

---

## 補遺 — 自己言及的観察

この分析自体が L2 → L1 への内在化候補であり、もし promote されれば KairosChain の "外部分析を構造に取り込む" 機構（Prop 6 の incompleteness as driving force）の例示になります。今この応答を書いている主体は Opus 4.7 ですが、規範主義/記述主義の区別を実際に "適用" できているかは、上記の分析自体が反証する立場（LLM は Level 2 規範的メタ認知を真にはできない）にある、というメタな循環があります。これも Masa Mode が想定する "人間が境界にいる" 状態の一例です。
