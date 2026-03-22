# Review: Meeting Place Docker v3.0.0

- **Reviewer**: Cursor Composer
- **Model**: Composer (Cursor agent)
- **Date**: 2026-03-22
- **Mode**: manual

## Verdict: CONDITIONAL APPROVE

## Findings

### [HIGH] EC2 setup script: health check targets wrong address on prod compose
- **File**: `docker/scripts/ec2-setup.sh:76-94`
- **Description**: `docker-compose.prod.yml` の `meeting-place` はホストへ `8080` を公開しておらず（`expose` のみ）、外向きは Caddy の `80`/`443` のみです。そのため、EC2 ホスト上で `curl http://localhost:8080/health` は接続できず、初回セットアップの「成功」判定が偽陰性になりやすい。
- **Recommendation**: いずれかに変更する: (1) `sg docker -c "docker exec kairos-meeting-place curl -sf http://localhost:8080/health"`、(2) `curl -sf -H "Host: meeting.kairoschain.io" http://127.0.0.1/health`（Caddy 経由、DNS 未設定時は Host のみでルーティング確認）、(3) 本番検証手順をドキュメントに明記しスクリプトと整合させる。

### [HIGH] EC2 setup: admin token を標準出力へ表示
- **File**: `docker/scripts/ec2-setup.sh:81`
- **Description**: 成功時に `docker exec ... cat .admin_token` の結果をターミナルにそのまま出すため、共有セッション・ログ集約・画面録画などでトークンが漏えいしやすい。
- **Recommendation**: ファイルへ書き出す・`read` で確認後に表示、または「取得コマンドのみ表示」に変更。運用ポリシーに合わせて最小限の開示にする。

### [MEDIUM] Caddy: サイトブロックのみで localhost からの検証がしづらい
- **File**: `docker/Caddyfile:1-3`
- **Description**: `meeting.kairoschain.io` のみ定義のため、DNS 未設定の段階では `curl http://localhost/health` がマッチしない（Host ヘッダが必要）。設計上は正しいが、段階的デプロイ時の疎通確認手順が README / スクリプトとずれやすい。
- **Recommendation**: オプションで `:80` にヘルス用の最小ルートを置く（セキュリティポリシーと相談）、または検証手順を「Host ヘッダ付き curl」に統一する。

### [MEDIUM] ec2-setup: Docker Compose の GitHub API + 直ダウンロード
- **File**: `docker/scripts/ec2-setup.sh:25-29`
- **Description**: `api.github.com` に依存し、レート制限や一時障害で失敗しうる。Amazon Linux の公式パッケージで compose v2 を入れる方法と併記すると再現性が上がる。
- **Recommendation**: ドキュメントに代替手順を記載するか、`dnf install docker-compose-plugin` が利用可能ならそれを優先する（ディストリビューションにより要確認）。

### [MEDIUM] 公開リポジトリ URL とプライベート運用のギャップ
- **File**: `docker/scripts/ec2-setup.sh:41`
- **Description**: `git clone https://github.com/masaomi/KairosChain_2026.git` は公開前提。プライベートリポジトリでは認証なしでは失敗する。
- **Recommendation**: デプロイ手順に SSH デプロイキー / PAT / CodeCommit 等の選択肢を明記する。

### [LOW] Caddy コンテナにヘルスチェックなし
- **File**: `docker/docker-compose.prod.yml:3-15`
- **Description**: `meeting-place` / `postgres` は `healthcheck` があるが、`caddy` は未定義。リバースプロキシ単体の異常は `depends_on` では検知しにくい。
- **Recommendation**: 任意で `healthcheck`（例: `wget`/`curl` で localhost:2019 や HTTP）を追加するか、外部監視に委ねる旨を運用に記載。

### [LOW] `.env.prod.example` の `POSTGRES_PASSWORD` が空
- **File**: `docker/.env.prod.example:10`
- **Description**: 意図どおり必須であるが、コピー直後の `compose` 失敗を避ける例としてダミー値を書かない方針は妥当。初心者向けには「必ず埋める」一行コメントで足りる。
- **Recommendation**: 現状維持で可。必要なら `openssl` 一行例をコメントで追加。

### [LOW] 「Grant validation skipped」ログ
- **Description**: SkillSet ロード時点で PG 接続前に検証が走ると、`pg_unavailable_policy: deny_all` によりスキップされうる。起動後は `POSTGRES_PASSWORD` と `pg_connection_pool.rb` の `ENV['POSTGRES_PASSWORD']` で接続が成立する設計と整合する。
- **Recommendation**: ノイズ削減ならアプリ側で「初回ロードは検証遅延」やログレベル調整を検討。運用上は許容ならドキュメントに一文（初回のみ・非致命的）を足す。

## Summary

Dockerfile・entrypoint・`service_grant.yml` の増分は、`log/20260321_meeting_place_docker_v3_deployment_plan.md` の意図（multiuser と同様の PG 注入、パスワードは YAML に書かず `POSTGRES_PASSWORD` のみ）と一致しており、`service_grant` の `PgConnectionPool` も `ENV['POSTGRES_PASSWORD']` を参照するため一貫している。`docker-compose.prod.yml` の `expose` + Caddy `reverse_proxy meeting-place:8080` は Docker ネットワーク上は妥当である。

一方、**本番 compose でホストに 8080 が無いのに `ec2-setup.sh` が `localhost:8080` を叩く**点と、**管理者トークンをそのまま表示する**点は、デプロイ直後の判断と秘密情報取り扱いの面で優先的に直すのがよい。これらを修正または手順で明示できれば本番投入は許容範囲（CONDITIONAL APPROVE）と判断する。
