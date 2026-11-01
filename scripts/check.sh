#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-infra の点検(CI と手元で同じものを回す)。何も変えない。
#   scripts/check.sh                       # 構造・sukhi.version・Image= の形・秘密の混入
#   SUKHI_STRICT=1 scripts/check.sh        # 0 埋めの仮ダイジェストも失敗にする
#   SUKHI_SETUP=../sukhi-setup SUKHI_COSIGN=1 scripts/check.sh   # 埋めたあとの image に cosign verify(要 cosign)
# {{version}} / {{digest:*}} を埋めるのは sukhi-setup の bin/sukhi-render(埋め方の唯一の場所)。ここでは再実装しない。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNER_RE='^https://github\.com/sukhi-social/sukhi-fedi/\.github/workflows/(release\.yml@refs/tags/v.+|combined-sha\.yml@refs/heads/main)$'
ZERO=$(printf '0%.0s' $(seq 64))
fail=0
err()  { echo "error: $*" >&2; fail=1; }
warn() { echo "warn: $*" >&2; }

# 1. sukhi の image は {{version}} / {{digest:<name>}} の形だけ。ほかは <name>:<tag>@sha256:<64桁>。Image= は base にだけ。
while IFS= read -r f; do err "$f: Image= は base/ の本体にだけ置く(overlay の Image= は版の manifest の外になる)"; done \
  < <(grep -rl '^Image=' overlays 2>/dev/null || true)
names=()
for f in base/*.container; do
  img=$(sed -n 's/^Image=//p' "$f" | head -1)
  [ -n "$img" ] || { err "$f: Image= がない"; continue; }
  if [[ "$img" =~ ^ghcr\.io/sukhi-social/sukhi-fedi-([a-z0-9-]+):\{\{version\}\}@\{\{digest:([a-z0-9-]+)\}\}$ ]]; then
    [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || err "$f: image 名と {{digest:*}} の名前が違う: $img"
    names+=("${BASH_REMATCH[1]}")
  elif [[ "$img" == ghcr.io/sukhi-social/* ]]; then
    err "$f: sukhi の image は ghcr.io/sukhi-social/sukhi-fedi-<name>:{{version}}@{{digest:<name>}} の形にする: $img"
  elif [[ "$img" =~ ^[^@{}]+:[^@:/{}]+@sha256:[0-9a-f]{64}$ ]]; then
    if [[ "$img" == *"@sha256:$ZERO" ]]; then
      if [ "${SUKHI_STRICT:-0}" = 1 ]; then err "$f: 仮のダイジェスト(0 埋め)"; else warn "$f: 仮のダイジェスト(0 埋め)。同期スクリプトは適用しない"; fi
    fi
  else
    err "$f: Image= の形が違う: $img"
  fi
done

# 2. 環境ごとの sukhi.version
for d in overlays/*; do [ -d "$d" ] || continue
  e=$(basename "$d"); m="$d/sukhi.version"
  [ -f "$m" ] || { err "$m がない"; continue; }
  get() { sed -n "s/^$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$m" | head -1; }
  req=$(get requires-sync); ver=$(get version)
  [[ "$req" =~ ^[0-9]+$ ]] || err "$m: requires-sync(整数)がない"
  case "$e" in
    prod) [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "$m: prod の version はリリースの semver(例 1.0.0): '$ver'" ;;
    *)    [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+|sha-[0-9a-f]{7,40})$ ]] || err "$m: version は semver か sha-<commit>: '$ver'" ;;
  esac
  for n in $(printf '%s\n' "${names[@]}" | sort -u); do
    dg=$(get "digest.$n")
    [[ "$dg" =~ ^sha256:[0-9a-f]{64}$ ]] || { err "$m: digest.$n が sha256:<64桁> でない: '$dg'"; continue; }
    if [ "$dg" = "sha256:$ZERO" ]; then
      if [ "${SUKHI_STRICT:-0}" = 1 ]; then err "$m: digest.$n が仮(0 埋め)"; else warn "$m: digest.$n が仮(0 埋め)。同期スクリプトは適用しない"; fi
    fi
  done
  # base が使わない digest は置かない(古い行が残るのを防ぐ)
  while IFS= read -r k; do
    n=${k#digest.}; printf '%s\n' "${names[@]}" | grep -qx "$n" || err "$m: $k は base のどの unit も使っていない"
  done < <(sed -n 's/^\(digest\.[A-Za-z0-9._-]*\):.*/\1/p' "$m")
done

# 3. 秘密を値で書いていないか(Secret= か podman secret で渡す)
if grep -rEn '^(Environment|EnvironmentFile)=[A-Z_]*(SECRET|PASSWORD|TOKEN|PRIVATE_KEY|ERLANG_COOKIE)[A-Z_]*=' base overlays 2>/dev/null; then
  err "秘密らしい値が Environment= にある。podman secret を使う"
fi

# 4. overlay は存在する unit にだけ当てる
for d in overlays/*/*.d; do
  [ -d "$d" ] || continue
  [ -f "base/$(basename "$d" .d)" ] || err "$d: base/$(basename "$d" .d) が無い"
done

# 5. 埋めたあとの確認(sukhi-setup の bin/sukhi-render が要る)
if [ -n "${SUKHI_SETUP:-}" ]; then
  render="$SUKHI_SETUP/bin/sukhi-render"; [ -x "$render" ] || err "$render がない"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  for d in overlays/*; do [ -d "$d" ] || continue
    e=$(basename "$d"); mkdir -p "$tmp/$e"; cp -a base/. "$tmp/$e/"; cp -a "$d/." "$tmp/$e/"; rm -f "$tmp/$e/sukhi.version"
    "$render" "$d/sukhi.version" "$tmp/$e" || { err "$e: sukhi-render が失敗"; continue; }
    grep -rn '{{' "$tmp/$e" && err "$e: 埋まっていない {{ }} が残っている"
    if [ "${SUKHI_COSIGN:-0}" = 1 ]; then
      while IFS= read -r img; do
        case "$img" in ghcr.io/sukhi-social/*) ;; *) continue ;; esac
        [[ "$img" == *"@sha256:$ZERO" ]] && continue
        ref="${img%@*}"; ref="${ref%:*}@${img##*@}"
        cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
          --certificate-identity-regexp "$SIGNER_RE" "$ref" >/dev/null || err "$e: 署名を確認できない: $ref"
      done < <(sed -n 's/^Image=//p' "$tmp/$e"/*.container | sort -u)
    fi
  done
elif [ "${SUKHI_COSIGN:-0}" = 1 ]; then
  err "SUKHI_COSIGN=1 には SUKHI_SETUP(sukhi-setup のチェックアウト)が要る"
fi

[ "$fail" = 0 ] && echo "ok" || exit 1
