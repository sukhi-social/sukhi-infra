<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-infra

sukhi の**箱が実行するもの**の正本。Podman Quadlet の unit(`*.container` `*.network` `*.volume`)を、環境ごとの差分と一緒に置く。
**この main に入ったものを、箱が 5 分以内に引いて実行する**ので、変更は必ず PR・必須レビュー・署名つきコミットで。

設計は [sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`](https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/OPS_QUADLET_GITOPS.md)。
箱の準備と、引いて適用する同期スクリプトは [sukhi-setup](https://github.com/sukhi-social/sukhi-setup)(**このリポジトリには置かない**。置くと、ここを書き換えた人が検証役ごと書き換えられる)。

## 構成

```
base/                    全環境共通の unit。sukhi の image は {{version}} / {{digest:<name>}} の形
base/instance.json       非秘密の instance config の既定値
overlays/<env>/          環境ごとの差分: instance.json、sukhi.version(期待する版)、<unit>.container.d/*.conf
scripts/check.rb         点検(Ruby。標準ライブラリだけ)(CI と手元で同じ)
scripts/bump-version.rb  (Ruby)sukhi.version の版とダイジェストを書き換える(手でも CI からも)
renovate.json            第三者の image(nats など)だけ Renovate
```

箱は `/etc/sukhi/env` の環境名(`dev` / `prod`)で `overlays/<env>/` を選び、`base/` の上に**重ねて平らに書き出し**、
`sukhi.version` の値で `{{version}}` / `{{digest:*}}` を埋める(埋め方は sukhi-setup の `bin/sukhi-render` の一か所)。
ドロップインは Quadlet の仕組みで、同じキーは後のファイルが勝ち、`Environment=` は足される。

`instance.json` は sukhi-fedi と共有する非秘密の契約で、`frontend`、`upstreams`、`routes`、`domain`、
`site.name` / `site.logo` / `site.icon` を明示する。gateway は完成したファイルを
`/etc/sukhi/instance.json` として read-only mount し、`SUKHI_INSTANCE_CONFIG` でパスを渡す。
秘密は引き続き `Secret=` のままにする。

## 版(sukhi.version)

```
requires-sync: 1                  # この形式を読める同期スクリプトの版。古い箱は適用せず通知する
version: 1.0.0                    # prod はリリースの semver、dev は main の sha-<commit>
digest.combined: sha256:<64桁>    # {{digest:combined}} に入る。web-next / web-simple / web-board / anubis も同じ
```

- **版を上げる = このファイルを書き換える PR。** sukhi の 5 つの image が同じ版で揃う(タグを 1 回打てば 5 つに付く)。
- prod は**リリースの版**(`v1.0.0` のタグで `release.yml` が付ける `1.0.0`)。`v1` や `latest` のような動くタグは書かない。
- unit ごとの変化は、埋めたあとの `Image=` の差で見る。`digest.combined` だけ変われば gateway だけ再起動する。

## ルール

- **秘密は置かない。** `podman secret`(`Secret=` で渡す)。`scripts/check.rb` が `Environment=` の秘密らしい名前を弾く。
- 第三者の image(nats)は `<name>:<tag>@sha256:<64桁>`。Renovate が見る。sukhi の image は Renovate の対象外。
- 0 埋めのダイジェストは**仮**。同期スクリプトはこれを適用しない。最初の bump で本物に替わる。
- dev だけ先の版にしたいときは `overlays/dev/sukhi.version` だけを書き換える。prod へ上げるのは prod の `sukhi.version` への PR。

## 点検

```sh
ruby scripts/check.rb              # 構造・instance.json・Image= の形・sha の一致・秘密の混入
SUKHI_STRICT=1 ruby scripts/check.rb   # 仮のダイジェストも失敗にする
SUKHI_SETUP=../sukhi-setup SUKHI_COSIGN=1 ruby scripts/check.rb   # 埋めたあとの image に cosign verify(要 cosign と sukhi-setup のチェックアウト)
```

## 未確認

- 箱の Podman の版で `Notify=healthy` / `HealthOnFailure=` / `Secret=...,type=env` が効くか。
- Anubis のヘルスの口、設定ファイルの置き場(image に焼かれている前提のパス)。
- Renovate の Quadlet マネージャで `pinDigests` が効くか。
- `bump-version.rb` の `skopeo inspect` が multi-arch 一覧のダイジェストを返すか(リリースのタグがまだ無いので試せていない)。

## 版を上げる(bump-prod / bump-dev)

Actions の **bump-prod**(リリースの版 `1.2.3`)か **bump-dev**(sukhi-fedi main のコミット sha)を「Run workflow」で流す。

1. **plan**: `scripts/bump-version.rb` で image のダイジェストを引き、`scripts/check.rb`(構造・描画・cosign)で署名を確かめる。差分(版と digest の行)をジョブの要約に出す。何も書き込まない。
2. **承認**: environment `bump-prod` / `bump-dev` の required reviewers が、要約の差分を見て「Approve」を押す。
3. **apply**: main が plan のときから動いていないことを確かめ、`overlays/<env>/sukhi.version` だけを contents API で 1 コミットにする。
   API で作ったコミットは GitHub が署名するので、箱の gpg 検証(web-flow の鍵)を通る。箱は次の同期で拾い、ヘルス確認と戻しは同期スクリプトがやる。

### 先に設定が要るもの(リポジトリ設定。コードでは入れられない)

- Settings > Environments に **`bump-prod`**(required reviewers: ひなた)と **`bump-dev`**(同じでも、無しでもよい)を作る。承認の関所はこれ。
- main のブランチ保護が PR を必須にしているなら、`github-actions` を bypass に入れる(入れないと apply が弾かれる)。
  入れたくなければ apply を「PR を作って自動マージ」に変える。
- Settings > Actions > General の Workflow permissions は、読み取りが既定のままでよい(apply のジョブだけが `contents: write` を要求する)。

### 未確認

- contents API のコミットが、`GITHUB_TOKEN` でも GitHub に署名されること(最初の bump で `git log --show-signature` を見る)。
- `skopeo` が ubuntu-24.04 の runner に入っていること(digest は `inspect --raw` の生データから計算するので、arm64 だけの image でも通るはず)。
- 呼び出し側の `permissions: contents: write` と、reusable workflow の environment の組み合わせ(最初に流して確かめる)。
