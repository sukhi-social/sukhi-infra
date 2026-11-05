#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-fedi の main の先頭が image まで揃っていたら、dev の版を上げる PR を「ひとつ」出す(あれば更新する)。
# マージは人がする。ここは提案を作るだけで、main には何も書かない。
# 設計: sukhi-fedi の docs/OPS_UPDATE_PROPOSAL.ja.md §3.3 / 2c。
#
# 要るもの: gh(GH_TOKEN。contents / pull-requests / actions の write)、skopeo、ruby、cosign(check.rb 用)。
# DRY_RUN=1 なら、書き込み(branch・PR)の手前で止まる。
set -euo pipefail
cd "$(dirname "$0")/.."

repo="${GITHUB_REPOSITORY:-sukhi-social/sukhi-infra}"
fedi="${FEDI_REPOSITORY:-sukhi-social/sukhi-fedi}"
branch="${BUMP_BRANCH:-auto/bump-dev}"
path="overlays/dev/sukhi.version"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
say() { echo "$*"; echo "$*" >>"$summary"; }

full="$(gh api "repos/$fedi/commits/main" --jq .sha)"
[[ "$full" =~ ^[0-9a-f]{40}$ ]] || { echo "unexpected sha: $full" >&2; exit 1; }
ver="sha-${full:0:7}"
cur="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$path")"

if [ "$ver" = "$cur" ]; then say "up to date ($cur)"; exit 0; fi

# image が揃うまで(ビルド中)は何もしない。次の回で拾う。
for n in $(sed -n 's/^digest\.\([A-Za-z0-9._-]*\):.*/\1/p' "$path"); do
  if ! skopeo inspect --raw "docker://ghcr.io/${repo%%/*}/sukhi-fedi-$n:$ver" >/dev/null 2>&1; then
    say "sukhi-fedi-$n:$ver is not there yet (still building?). Next run will retry."
    exit 0
  fi
done

# すでに同じ版の PR が開いていれば、何もしない。
open="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,title --jq '.[0] // empty')"
if [ -n "$open" ] && [ "$(jq -r .title <<<"$open")" = "dev: bump to $ver" ]; then
  say "PR #$(jq -r .number <<<"$open") already proposes $ver"
  exit 0
fi

ruby scripts/bump-version.rb dev "$ver"
SUKHI_SETUP="${SUKHI_SETUP:-.setup}" SUKHI_COSIGN=1 ruby scripts/check.rb
# 変わっていいのは、版とダイジェストの行だけ
if git diff -U0 -- "$path" | grep '^[+-][^+-]' | grep -Ev '^[+-](version|digest\.[A-Za-z0-9._-]+):'; then
  echo "unexpected lines changed in $path" >&2; exit 1
fi

diff="$(git diff -U0 -- "$path" | grep '^[+-][^+-]')"
body="$(cat <<BODY
sukhi-fedi の main(\`$full\`)の image が揃ったので、dev の版を上げます。
[sukhi-fedi の変更: \`${cur#sha-}...${full:0:7}\`](https://github.com/$fedi/compare/${cur#sha-}...$full)

\`\`\`diff
$diff
\`\`\`

- ダイジェストの解決と cosign の検証は、この PR を作る前に通っています。
- **マージは人がします。** マージされると、箱が引いて管理画面に「更新が来ています」と出ます。入れる時機は管理画面の「いま入れる」で決めます。
- 次の main が来たら、この PR は同じ branch の上で更新されます(PR は常にひとつ)。

_自動で作りました(\`scripts/propose-dev-bump.sh\`)_
BODY
)"

if [ "${DRY_RUN:-0}" = 1 ]; then
  say "DRY_RUN: would propose $cur -> $ver"; echo "$body"; git checkout -q -- "$path"; exit 0
fi

# branch を main の先頭に置き直して、版のファイルを 1 コミット(contents API なので GitHub が署名する)
base="$(git rev-parse HEAD)"
if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$base" -F force=true >/dev/null
else
  gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$base" >/dev/null
fi
gh api -X PUT "repos/$repo/contents/$path" \
  -f message="dev: bump to $ver" \
  -f content="$(base64 <"$path" | tr -d '\n')" \
  -f sha="$(git rev-parse "HEAD:$path")" \
  -f branch="$branch" >/dev/null

# GITHUB_TOKEN が作った push は check を起こさないので、手で起こす(PR の最新コミットに付く)
gh workflow run check.yml --repo "$repo" --ref "$branch" >/dev/null 2>&1 || say "could not start check.yml on $branch"

if [ -n "$open" ]; then
  gh pr edit "$(jq -r .number <<<"$open")" --repo "$repo" --title "dev: bump to $ver" --body "$body" >/dev/null
  say "updated PR #$(jq -r .number <<<"$open") -> $ver"
elif url="$(gh pr create --repo "$repo" --base main --head "$branch" --title "dev: bump to $ver" --body "$body" 2>&1)"; then
  say "opened $url"
else
  # リポジトリの「Actions が PR を作る」が off のとき。branch は出来ているので、人が開く。
  say "branch \`$branch\` is ready, but a PR could not be created: $url"
  say "open it: https://github.com/$repo/compare/main...$branch?expand=1"
  echo "::warning::could not create the PR (Settings > Actions > General > 'Allow GitHub Actions to create and approve pull requests')"
fi
