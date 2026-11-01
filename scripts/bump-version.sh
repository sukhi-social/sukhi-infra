#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# overlays/<env>/sukhi.version の版とダイジェストを書き換える(手でも CI からも同じもの)。
#   scripts/bump-version.sh prod 1.0.0       # リリースの版(semver)
#   scripts/bump-version.sh dev sha-abc1234  # main の sha
# 各 image のダイジェストを skopeo で解決する(multi-arch の一覧のダイジェストが返ること。未確認)。
# 署名の検証は scripts/check.sh(SUKHI_COSIGN=1)と、箱の同期スクリプトがやる。ここでは確かめない。
set -euo pipefail
cd "$(dirname "$0")/.."
env="${1:?usage: $0 <env> <version>}"; ver="${2:?usage: $0 <env> <version>}"
m="overlays/$env/sukhi.version"; [ -f "$m" ] || { echo "no $m" >&2; exit 1; }
if [ "$env" = prod ]; then [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "prod needs a semver version" >&2; exit 1; }
else [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+|sha-[0-9a-f]{7,40})$ ]] || { echo "version must be semver or sha-<commit>" >&2; exit 1; }; fi
command -v skopeo >/dev/null || { echo "skopeo not found" >&2; exit 1; }
owner="${SUKHI_OWNER:-sukhi-social}"

names=$(sed -n 's/^\(digest\.[A-Za-z0-9._-]*\):.*/\1/p' "$m" | sed 's/^digest\.//')
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
# 先に全部解決する(1 つでも失敗したら、何も書き換えない)
declare -A dg
for n in $names; do
  d=$(skopeo inspect --no-tags --format '{{.Digest}}' "docker://ghcr.io/$owner/sukhi-fedi-$n:$ver") || { echo "cannot resolve $n:$ver" >&2; exit 1; }
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "unexpected digest for $n: $d" >&2; exit 1; }
  dg[$n]=$d
done
awk -v ver="$ver" '
  /^version:/ { sub(/^version:[ \t]*[^ \t#]*/, "version: " ver) }
  { print }' "$m" >"$tmp"
for n in $names; do
  sed -i -E "s#^(digest\\.$n:[[:space:]]*)sha256:[0-9a-f]{64}#\\1${dg[$n]}#" "$tmp"
done
cat "$tmp" >"$m"
echo "updated $m: version=$ver"; sed -n '/^digest\./p' "$m"
