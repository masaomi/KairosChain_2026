---
title: Attestation Home Migration — anchor 係留 chain を Meeting Place から Synoptis(attestation の家)へ
status: FROZEN v0.3（Round 3: persona unanimity gate 3/3 APPROVE・R2 P0 全解消・残 (c) advisory のみ反映）
review_note: R3 subprocess(codex/cursor/CLI) は detached worker crash(heartbeat_stale)×2 で取得不能＝advisory 数値収束は R3 未取得。blocking gate(persona 3/3)通過を根拠に凍結。R2 subprocess は 4/6 APPROVE・唯一の REJECT(codex5.4 移行ウィンドウ)は AHM-9 で対応済。
date: 2026-07-16
supersedes: docs/drafts/attestation_home_migration_design_v0.2_draft.md
inherits:
  - docs/drafts/hestia_anchor_attestation_design_v0.5_draft.md（ANC-1..9・一方向規則 §5 を含む）
  - docs/drafts/unified_deposit_board_design_v0.3_draft.md（BRD-1..4）
related: log/hestia_storage_and_attestation_map_20260716.md（現状の正準マップ）
method: design-by-invariant / anti-enumeration。具体機構(クラス名・フィールド名・スキーマ・スクリプト)は §11 backlog のみ。
scope: 設計フェーズのみ。coding は別フェーズ。§11 は先行 ANC/BRD 設計と同じ backlog 節番号（§6-10 は意図的に欠番）。
disposition: docs/drafts/.attestation_home_migration_r1_disposition.md（R1）/ .attestation_home_migration_r2_disposition.md（R2）
---

# Attestation Home Migration 設計 (v0.3)

## 1. なぜこの移行が必要か（設計意図）

KairosChain は P2P を前提とする構想。attestation は本来**エージェントが自分で持ち運ぶ能力**であって、
Meeting Place サーバー（HestiaChain SkillSet）の持ち物ではない。

現状にはこのズレが実在する。信用 attestation（Synoptis 側）は既にエージェント所有の能力として
Meeting Place 非依存に置かれている（依存は基盤プロトコルのみ）。一方、係留 attestation（外部成果物の
provenance）は Meeting Place サーバーに束ねられ、その**管理境界がサーバー自身の identity に固定**され、
永続化が追記台帳の作法に合っていない。

この移行は、**係留能力をエージェント所有の attestation の家（Synoptis）に寄せ、Meeting Place を「所有者」から
「公開窓(rendezvous)」に格下げし、永続形式を追記専用の作法に是正する**。attestation の意味論
（chain に載るのは観察のみ・判定は導出＝DEE〔Decentralized Evolving Ecosystem〕整合）は一切変えない。
純粋に**所有・場所・形式**の是正である。

**なぜ家は Synoptis か**: 係留 attestation を置くべき家は、(1)エージェント所有で、(2)基盤プロトコルのみに
依存し Meeting Place サーバーに依存しない、という二つの必要条件を満たさねばならない（AHM-1/2a の帰結）。
この二条件を満たす既存の家は Synoptis であり、そこは既に attestation を役割として提供している。したがって、
「core を太らせず既存の attestation の家を再利用する」という KairosChain 命題（新能力＝SkillSet・DNA を単純に）
から、家は Synoptis に確定する。信用(A)と係留(C)は同居するが融合しない（AHM-5）。

## 2. 不変条件（この移行が守るもの）

- **AHM-1（所有）**: attestation chain はエージェント所有の能力。Meeting Place はその所有者ではなく、
  読んで他者に見せる**公開窓**である。

- **AHM-2a（局所独立）**: chain の構築・書き込み・撤回・**局所的な連鎖再計算検証**は、Meeting Place が
  存在しなくても成立する。単独インスタンスが P2P で attest できることが移行の成立条件（既定同梱で全インスタンスが
  この能力を持つ・§11）。

- **AHM-2b（公開検証は Place 媒介）**: 第三者向けの公開検証ビューと、外部に信用される foreign / same-party
  提示は**公開窓（Place）が媒介する公表機能**であって、局所独立の主張ではない。その外部信用は scope Y
  （ANC-4/6）に依存し、本移行の外にある。「独立」は AHM-2a の局所操作に限定した語である。

- **AHM-3（管理境界は per-entry の governing identity で解決する）**: 撤回権限および same-party / foreign 判定は、
  **その entry が committed された時に有効だった governing identity**（entry ごとに確定・以後不変）に対して解決する。
  管理境界の移動とは「以後の新規 entry の governing identity を所有エージェントの canonical identity に切り替える」
  ことであり、**既存 entry の governing identity を書き換えない**。導出は「単一の現行 identity と比較」ではなく
  「各 entry の governing identity と照合」になる（これは意味論を保つための導出の in-scope な変更・AHM-7/§3）。
  既存 entry の governing identity は、その entry の committed 内容（ハッシュ原像 = 正準内容）を**変えないため、
  必ず正準内容の外に記録**する（さもなくば entry_hash が壊れ AHM-4 に反する・記録形式は §11）。

- **AHM-4（引用保存・死守）**: 移行の前後で、既に公開された係留の以下がすべて不変である —
  ①digest ②entry_hash ③chain head ④凍結公開アドレスの解決結果 ⑤その entry の導出 relation ラベル
  （same_party/foreign）⑥その entry への撤回権限の帰属。①〜④は committed 内容と連鎖順の保存で、
  ⑤⑥は AHM-3 の per-entry governing identity と AHM-7 の identity 継続で保証する。entry_hash は committed の
  正準内容のハッシュゆえ、正準内容と順序が保たれれば物理表現が変わっても不変。これは移行完了の検証条件でもある。
  ⑥で不変なのは**権限帰属の構造**（committed depositor による自己撤回＋その entry の governing identity 役の継続）
  であって、operator 役の保持者 identity は所有移動により意図的に旧境界→所有エージェントへ移る（矛盾ではない・AHM-7）。

- **AHM-5（連鎖意味論は基盤非依存・エンジン非融合）**: 保存されるのは**物理形式ではなく連鎖の意味論**
  である — 単一 head・genesis からの再検証・追記撤回・load 時の index 再構築、そして**ハッシュの原像は
  係留自身の正準内容**（宿主 store の native なハッシュ方式ではない）。信用(A)と係留(C)は claim の意味論と
  導出が異なるため、**単一エンジンにもハッシュ関数にも融合しない**。両者が物理的な行形式を共有するか否かは
  §11 の機構決定であって、invariant ではない。

- **AHM-6（先行不変条件・一方向規則・foreign 経路の継承）**: ANC-1〜9・BRD-1〜4 を無改変で継承する。加えて
  ANC v0.5 §5 の**一方向規則**（scope X で作るものは scope Y が破らざるを得ない形にしない）を継承する。
  したがって、Meeting Place の公開窓化（AHM-1）は、将来 scope Y で公開窓を介して再度開く foreign 預け入れ経路を
  **塞がない**形で行う（当該経路は本移行では非活性となるが、それは意図的な保留であって除去ではない）。
  ANC-2 の content containment（書き込みは digest＋inert bounded metadata のみ）は移設先でも保つ。

- **AHM-7（identity 継続）**: 既存 entry の committed 内容（committed された depositor identity を含むハッシュ原像）は
  移行を通じて**不変**である。旧境界 identity の下で committed された entry については、その entry の governing identity
  は旧境界 identity のままであり（AHM-3）、**所有エージェントがその governing identity の権限・same-party 基準を継承する**
  （孤児化させない）。すなわち境界移動は「以後の新規基準の導入」であって「既存記録の再解釈」ではない。

- **AHM-9（移行ウィンドウ整合）**: 複数スライスにまたがる移行の**各スライス境界において、権威ある store は
  常にただ一つ・書き込み経路もただ一つ**である。すなわち (i) 新形式コードは移行完了前の旧形式データを
  後方読み込みできる（さもなくば形式の有効化はデータ移行と同時まで遅延する）、(ii) 既存の write 経路
  （operator script）と凍結公開 route は、それらを取り残す形式・所有変更と**同時に追随する**か、窓の間
  write を凍結する。第二の分岐チェーンや stale store への書き込みが生じてはならない。

## 3. 継ぎ目（不変条件の帰結・性質として）

所有の是正（AHM-1/2a/3）から、能力の分割は性質として決まる:

- **所有・書き込み・連鎖・局所検証**は**エージェント側の能力**に属する（Synoptis）。管理境界は各 entry の
  governing identity で解決する（AHM-3/AHM-7）。
- **公開・待ち合わせ・第三者向け提示**は**公開窓（Place）**に残る。公開窓は所有せず、エージェント所有の
  chain を**読んで見せるだけ**で、書き込み・撤回の権限を持たない（AHM-1/AHM-2b）。
- **永続形式**は追記専用の作法に是正するが、その際 AHM-4/AHM-5 の**ハッシュ原像不変**と、現行の
  **クラッシュ整合性・失敗時ロールバック契約**（失敗と告げた書き込みが黙って復活しない／クラッシュは
  旧完全か新完全のいずれかで、committed entry を黙って欠落させない）を保存する。

移設対象の能力群は Meeting Place 固有の内部に依存しないので、**storage 形式と所有・構築点の移動**は
ロジックの書き換えを伴わない。ただし、AHM-3 の per-entry governing identity 化に伴う**撤回権限・relation 判定の
導出の変更は in-scope の論理変更**であり（「単一の現行 identity と比較」→「各 entry の governing identity と照合」）、
これを storage 移動と混同しない。また公開窓側に残る読み取り部品が移設能力を跨いで参照する結合は実在するため、
その参照・定数解決グラフの整理も移設の一部として扱う（§11）。「挙動不変」は主張でなく検証項目（S1）。

## 4. スライス計画

意味論不変を保ちつつ、所有 → 形式 → 公開窓化 → 本番移行 の順。各段で AHM-4（引用保存）と AHM-9
（ウィンドウ整合）を検証する。「本番接触」は**データ移行の有無**で言う。S1〜S3 は本番データを移さないが、
共有 boot path 上の**実行コードを配備する**（次回 restart で再実行される）ため、「データ移行なし・コード配備あり」
と正直に扱う。

| Slice | 内容 | 本番データ移行 | コード配備（restart 再実行） | 検証 |
|---|---|---|---|---|
| S1 | 係留能力を Synoptis へ移設。**撤回権限・relation 判定を per-entry governing identity 化**（AHM-3/7・in-scope の導出変更）。storage 形式は現行のまま | なし | あり | 参照/定数解決グラフ健全・**relation/権限 不変は per-entry governing identity 解決によって達成**・entry_hash/head 不変（局所） |
| S2 | 永続形式を追記専用に是正（AHM-5）。ハッシュ原像・整合性・ロールバック契約を保存。**新コードは旧形式を後方読み込み**（AHM-9 i） | なし | あり | 変換前後で entry_hash/head 不変・クラッシュ整合性・旧形式後方読み込みテスト |
| S3 | 公開窓化（AHM-1/2b）。所有構築を外し、公開窓は agent 所有 chain を読む配線へ | なし | あり | 公開 verify が移設後 chain を正しく読む・deploy 順序が S4 前提を壊さない |
| S4 | 本番データ移行（既存係留を新形式へ）。**同時に既存 write 経路(operator script)と凍結 route を追随**（AHM-9 ii）。Synoptis の既定同梱（AHM-2a の P2P 既定化）。凍結 URL/digest/entry_hash/relation/権限 不変を e2e 検証 | あり（計画的・要 backup・順序管理） | あり | 凍結アドレス 200・再ハッシュ一致・head/relation/権限 不変・第二チェーン非分岐・窓内 write の単一権威 |

Deferred（本移行外・AHM-6 の下で保留）: scope Y（ANC-3/4/6・federation・foreign 預け入れの公開窓経由再開・
P2P discovery）。A と C の物理形式共通化（§11）。信用度→通信受諾の防壁配線（別トラック）。

## 5. スコープと非目標（§2 と重複させない）

- **意味論を変えない**（§1 の帰結）: chain に判定を書かない・trust は導出・claim 種・TTL/採点は不変。
- **A は S1〜S3 で触らない**: 既に正しい場所・形式。C を隣に置くだけ。共通土台化は将来決定（§11）。
- **foreign 預け入れと P2P discovery は本移行の目標でない**が、AHM-6 により**塞がない**。scope Y で扱う。
- **本番データは勢いで触らない**: データ移行は S4 のみ・backup 前提・順序管理。S1〜S3 のコード配備も
  AHM-9 の単一権威・単一 write 経路を各境界で保つ。

## 11. Backlog（機構の決定は本文でなくここ）

- 移設先の名前空間名。公開窓が「所有しない読み取り」を受け取る参照 API。committed 内容の identity フィールドの
  名称と、各 entry の governing identity の記録形式。
- 撤回権限・relation 判定の per-entry governing identity 化の具体（現行の単一 operator_id 比較を、entry ごとの
  governing identity 照合に変える導出変更。relation の再計算と撤回権限の解決の両方を含む）。旧境界 identity を
  当該 entry の権限主体・same-party 基準として所有エージェントが継承する写像。
- 公開窓側に残る部品が移設能力へ持つ参照・定数（inert 開示定数・安全参照パターン等）の解決経路整理。
- 追記専用形式の物理スキーマ。宿主 store の per-stream 方式と ANC-1 の単一 head・genesis 再検証・追記撤回・
  index を両立させる方法（既存 registry 流用か、係留 Log の追記行化か）。ハッシュ原像は係留の正準内容に固定
  （AHM-5）、整合性・ロールバック契約を保存（AHM-4）。新旧形式の後方読み込み互換（AHM-9 i）の実現方式。
- 本番データ移行スクリプトと、既存 write 経路(inaugural/withdrawal script)・凍結 route の同時追随手順
  （AHM-9 ii の単一権威・単一 write 経路をデプロイ順序で保証）。S4 の四動作（データ移行・script 追随・
  route 追随・既定同梱）のデプロイ順序依存の切り分け。
- 既定同梱の機構（同梱・既定有効の enable 既定値）。
- A と C の物理形式共通土台の抽出可否 — 必要が実証されてから（YAGNI）。
- foreign 預け入れの公開窓経由再開・P2P discovery — scope Y 設計で扱う。
- DEE 頭字語衝突の是正 — ドキュメント整理として別途。
