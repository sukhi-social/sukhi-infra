<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-infra

sukhi の**箱が実行するもの**の正本。Podman Quadlet の unit(`*.container` `*.network` `*.volume`)を、環境ごとの差分と一緒に置く。
**この main に入ったものを、箱が 5 分以内に引いて実行する**ので、変更は必ず PR・必須レビュー・署名つきコミットで。

設計は [sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`](https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/OPS_QUADLET_GITOPS.md)。
箱の準備と、引いて適用する同期スクリプトは [sukhi-setup](https://github.com/sukhi-social/sukhi-setup)(**このリポジトリには置かない**。置くと、ここを書き換えた人が検証役ごと書き換えられる)。

## 構成

```
base/                    全環境共通の unit。sukhi の image は {{version}} / {{digest:<name>}} の形
overlays/<env>/          環境ごとの差分: sukhi.version(期待する版)と <unit>.container.d/*.conf
scripts/check.sh         点検(CI と手元で同じ)
scripts/bump-version.sh  sukhi.version の版とダイジェストを書き換える(手でも CI からも)
renovate.json            第三者の image(nats など)だけ Renovate
```

箱は `/etc/sukhi/env` の環境名(`dev` / `prod`)で `overlays/<env>/` を選び、`base/` の上に**重ねて平らに書き出し**、
`sukhi.version` の値で `{{version}}` / `{{digest:*}}` を埋める(埋め方は sukhi-setup の `bin/sukhi-render` の一か所)。
ドロップインは Quadlet の仕組みで、同じキーは後のファイルが勝ち、`Environment=` は足される。

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

- **秘密は置かない。** `podman secret`(`Secret=` で渡す)。`scripts/check.sh` が `Environment=` の秘密らしい名前を弾く。
- 第三者の image(nats)は `<name>:<tag>@sha256:<64桁>`。Renovate が見る。sukhi の image は Renovate の対象外。
- 0 埋めのダイジェストは**仮**。同期スクリプトはこれを適用しない。最初の bump で本物に替わる。
- dev だけ先の版にしたいときは `overlays/dev/sukhi.version` だけを書き換える。prod へ上げるのは prod の `sukhi.version` への PR。

## 点検

```sh
scripts/check.sh                  # 構造・Image= の形・sha の一致・秘密の混入
SUKHI_STRICT=1 scripts/check.sh   # 仮のダイジェストも失敗にする
SUKHI_SETUP=../sukhi-setup SUKHI_COSIGN=1 scripts/check.sh   # 埋めたあとの image に cosign verify(要 cosign と sukhi-setup のチェックアウト)
```

## 未確認

- 箱の Podman の版で `Notify=healthy` / `HealthOnFailure=` / `Secret=...,type=env` が効くか。
- Anubis のヘルスの口、設定ファイルの置き場(image に焼かれている前提のパス)。
- Renovate の Quadlet マネージャで `pinDigests` が効くか。
- `bump-version.sh` の `skopeo inspect` が multi-arch 一覧のダイジェストを返すか(リリースのタグがまだ無いので試せていない)。
