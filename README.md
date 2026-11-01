<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-infra

sukhi の**箱が実行するもの**の正本。Podman Quadlet の unit(`*.container` `*.network` `*.volume`)を、環境ごとの差分と一緒に置く。
**この main に入ったものを、箱が 5 分以内に引いて実行する**ので、変更は必ず PR・必須レビュー・署名つきコミットで。

設計は [sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`](https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/OPS_QUADLET_GITOPS.md)。
箱の準備と、引いて適用する同期スクリプトは [sukhi-setup](https://github.com/sukhi-social/sukhi-setup)(**このリポジトリには置かない**。置くと、ここを書き換えた人が検証役ごと書き換えられる)。

## 構成

```
base/                    全環境共通の unit。Image= はここだけ
overlays/<env>/          環境ごとの差分(<unit>.container.d/*.conf)。dev / prod
scripts/check.sh         点検(CI と手元で同じ)
renovate.json            第三者の image(nats など)だけ Renovate。sukhi の image は無効
```

箱は `/etc/sukhi/env` の環境名(`dev` / `prod`)で `overlays/<env>/` を選び、`base/` の上に**重ねて平らに書き出す**。
ドロップインは Quadlet の仕組みで、同じキーは後のファイルが勝ち、`Environment=` は足される。

## ルール

- **秘密は置かない。** `podman secret`(`Secret=` で渡す)。`scripts/check.sh` が `Environment=` の秘密らしい名前を弾く。
- **`Image=` は `base/` の本体にだけ**、`<name>:<tag>@sha256:<64桁>` の形で。ドロップインに置くと Renovate と bump が見ない。
- **sukhi の 5 つの image(combined / web-next / web-simple / web-board / anubis)は、同じ `sha-<commit>` に揃える。** sukhi-fedi の CI が 1 つの PR で書き換える(nats など第三者の image は Renovate)。
- 0 埋めのダイジェストは**仮**。同期スクリプトはこれを適用しない。最初の bump で本物に替わる。
- dev だけ先の sha にしたいときは overlay に `Image=` を置けるが、bump の対象外。prod へ上げるのは base への PR。

## 点検

```sh
scripts/check.sh                  # 構造・Image= の形・sha の一致・秘密の混入
SUKHI_STRICT=1 scripts/check.sh   # 仮のダイジェストも失敗にする
SUKHI_COSIGN=1 scripts/check.sh   # sukhi の image に cosign verify(要 cosign)
```

## 未確認

- 箱の Podman の版で `Notify=healthy` / `HealthOnFailure=` / `Secret=...,type=env` が効くか。
- Anubis のヘルスの口、設定ファイルの置き場(image に焼かれている前提のパス)。
- Renovate の Quadlet マネージャで `pinDigests` が効くか。
