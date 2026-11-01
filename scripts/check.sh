#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-infra の点検(CI と手元で同じものを回す)。何も変えない。
#   scripts/check.sh            # 構造・Image= の形・sha の一致
#   SUKHI_STRICT=1 scripts/check.sh   # 0 埋めの仮ダイジェストも失敗にする
#   SUKHI_COSIGN=1 scripts/check.sh   # ghcr.io/sukhi-social/* に cosign verify(要 cosign・ネットワーク)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNER_RE='^https://github\.com/sukhi-social/sukhi-fedi/\.github/workflows/(release\.yml@refs/tags/v.+|combined-sha\.yml@refs/heads/main)$'
ZERO=$(printf '0%.0s' $(seq 64))
fail=0
err()  { echo "error: $*" >&2; fail=1; }
warn() { echo "warn: $*" >&2; }

# 1. Image= は base の .container にだけ(Renovate / bump が見るのは本体。ドロップインには置かない)
while IFS= read -r f; do
  err "$f: Image= は base/ の本体にだけ置く(ドロップインや overlay の Image= は bump の対象外)"
done < <(grep -rl '^Image=' overlays 2>/dev/null || true)

# 2. 各 Image= は タグ + ダイジェスト、秘密らしきものは置かない
shas=()
for f in base/*.container; do
  img=$(sed -n 's/^Image=//p' "$f" | head -1)
  [ -n "$img" ] || { err "$f: Image= がない"; continue; }
  if [[ ! "$img" =~ ^[^@]+:[^@:/]+@sha256:[0-9a-f]{64}$ ]]; then err "$f: Image= は <name>:<tag>@sha256:<64桁> の形にする: $img"; continue; fi
  if [[ "$img" == *"@sha256:$ZERO" ]]; then
    if [ "${SUKHI_STRICT:-0}" = 1 ]; then err "$f: 仮のダイジェスト(0 埋め)"; else warn "$f: 仮のダイジェスト(0 埋め)。同期スクリプトはこれを適用しない"; fi
  fi
  case "$img" in ghcr.io/sukhi-social/sukhi-fedi-*) shas+=("$(sed -E 's/.*:(sha-[^@]+)@.*/\1/' <<<"$img")") ;; esac
done

# 3. sukhi の image は全部同じ sha-タグ(「どこも同じ sha」の約束)
if [ "${#shas[@]}" -gt 0 ] && [ "$(printf '%s\n' "${shas[@]}" | sort -u | wc -l)" -ne 1 ]; then
  err "sukhi の image の sha-タグがそろっていない: $(printf '%s\n' "${shas[@]}" | sort -u | tr '\n' ' ')"
fi

# 4. 秘密を値で書いていないか(Secret= か podman secret で渡す)
if grep -rEn '^(Environment|EnvironmentFile)=.*[A-Z_]*(SECRET|PASSWORD|TOKEN|PRIVATE_KEY|ERLANG_COOKIE)[A-Z_]*=' base overlays 2>/dev/null; then
  err "秘密らしい値が Environment= にある。podman secret を使う"
fi

# 5. overlay は存在する unit にだけ当てる
for d in overlays/*/*.d; do
  [ -d "$d" ] || continue
  u=$(basename "$d" .d)
  [ -f "base/$u" ] || err "$d: base/$u が無い"
done

# 6. 署名(任意)
if [ "${SUKHI_COSIGN:-0}" = 1 ]; then
  while IFS= read -r img; do
    case "$img" in ghcr.io/sukhi-social/*) ;; *) continue ;; esac
    [[ "$img" == *"@sha256:$ZERO" ]] && continue
    ref="${img%@*}"; ref="${ref%:*}@${img##*@}"
    cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp "$SIGNER_RE" "$ref" >/dev/null || err "署名を確認できない: $ref"
  done < <(sed -n 's/^Image=//p' base/*.container)
fi

[ "$fail" = 0 ] && echo "ok" || exit 1
