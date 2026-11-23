#!/usr/bin/env bash
# Release steps (CONTRIBUTING.md, "Releases"):
#   scripts/release.sh start <version>   (make release VERSION=<version>)
#     from main or from release/v<version>: the branch, the version's section and
#     compare links in CHANGELOG.md, "~> X.Y" in the README, a commit, the push,
#     the link to the pull request.
#   scripts/release.sh tag               (make release-tag)
#     after the merge: the tag v<version> on main, which starts the Release workflow
#     (GitHub release; the Terraform Registry picks up the tag).
# Each step can be run again: what is already done is skipped.
set -euo pipefail

fail() { printf '\n%s\n' "$1" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"
REPO=$(git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')

start() {
  local version=${1:-}
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Usage: make release VERSION=<x.y.z>'
  local branch="release/v$version" current
  current=$(git branch --show-current)
  if [[ $current == main ]]; then
    [[ -z $(git status --porcelain) ]] || fail 'main has uncommitted changes.'
    git pull --ff-only
    git switch -c "$branch"
  elif [[ $current != "$branch" ]]; then
    fail "Run it from main (or from $branch), not from $current."
  fi

  if ! grep -qF "## [$version]" CHANGELOG.md; then
    awk '/^## \[Unreleased\]/ { getline; getline; ok = /^###/; exit } END { exit !ok }' CHANGELOG.md ||
      fail 'CHANGELOG.md: [Unreleased] is empty; write what this release brings first.'
    local prev
    prev=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)
    awk -v v="$version" -v p="$prev" -v d="$(date +%F)" -v r="$REPO" '
      /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
      /^\[Unreleased\]: / { print "[Unreleased]: " r "/compare/v" v "...HEAD"; print "[" v "]: " r "/compare/v" p "...v" v; next }
      { print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
  fi

  # A new minor version: the README snippets pin "~> X.Y".
  local minor=${version%.*}
  awk -v m="$minor" '{ gsub(/version = "~> [0-9]+\.[0-9]+"/, "version = \"~> " m "\"") } { print }' README.md > README.md.tmp &&
    mv README.md.tmp README.md

  git add CHANGELOG.md README.md
  git diff --cached --quiet || git commit -m "Release v$version"
  git push -u origin "$branch"
  printf '\nPull request: %s/compare/%s?expand=1\n' "$REPO" "$branch"
  echo 'When CI is green and it is merged: make release-tag'
}

tag() {
  [[ -z $(git status --porcelain) ]] || fail 'Uncommitted changes; commit or stash them first.'
  git switch main
  git pull --ff-only
  local version
  version=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)
  [[ -n $version ]] || fail 'CHANGELOG.md has no released version yet (is the pull request merged?).'
  git rev-parse -q --verify "refs/tags/v$version" > /dev/null || git tag -a "v$version" -m "v$version"
  git push origin "v$version"
  printf '\nGitHub Release of v%s: %s/actions/workflows/release.yml\n' "$version" "$REPO"
}

case ${1:-} in
  start) start "${2:-}" ;;
  tag) tag ;;
  *) fail 'Usage: scripts/release.sh start <x.y.z> | tag' ;;
esac
