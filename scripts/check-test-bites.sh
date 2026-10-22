#!/usr/bin/env bash
# check-test-bites.sh: prove that the server tests a change adds or edits
# actually test that change.
#
# Each changed server test file (server/src/**/*.test.ts) is run twice:
#   1. on BASE's source, with the HEAD version of the test copied in: must FAIL
#      (a test for code that does not exist yet fails to import; that counts);
#   2. on HEAD: must PASS.
# A test that passes on BASE is decorative: it passes with or without the change.
#
# iOS tests (App/Tests/**) are not checked: that needs two xcodebuild runs on a
# macOS runner per PR. They are listed so the omission is visible.
#
# Usage: scripts/check-test-bites.sh [--base <ref>] [--head <ref>]
#   --base defaults to origin/main; the merge-base with HEAD is what is used.
#   Needs server/node_modules installed (npm ci in server/) in this checkout.
# Exit: 0 every changed server test bites (or none changed), 1 decorative or red
#       at HEAD, 2 could not check.
set -euo pipefail

base_ref=origin/main
head_ref=HEAD
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base_ref="${2:?--base needs a ref}"; shift 2 ;;
    --head) head_ref="${2:?--head needs a ref}"; shift 2 ;;
    *) echo "usage: $0 [--base <ref>] [--head <ref>]" >&2; exit 2 ;;
  esac
done

root="$(git rev-parse --show-toplevel)"
cd "$root"
head_sha="$(git rev-parse --verify "$head_ref^{commit}")"
base_sha="$(git merge-base "$base_ref" "$head_sha")" || {
  echo "Could not check: no merge-base between $base_ref and $head_ref." >&2
  exit 2
}

changed="$(git diff --name-only --diff-filter=AM "$base_sha" "$head_sha")"
tests="$(printf '%s\n' "$changed" | grep -E '^server/src/.*\.test\.ts$' || true)"
ios="$(printf '%s\n' "$changed" | grep -E '^App/Tests/' || true)"
[ -z "$ios" ] || printf 'Not checked (iOS bite check is not automated):\n%s\n' "$ios" >&2

if [ -z "$tests" ]; then
  echo "No changed server test files between ${base_sha:0:12} and ${head_sha:0:12}."
  exit 0
fi
if [ ! -d server/node_modules ]; then
  echo "Could not check: server/node_modules missing; run 'npm ci' in server/ first." >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-bites.XXXXXX")"
# shellcheck disable=SC2329 # invoked by the trap below
cleanup() {
  git worktree remove --force "$tmp/base" >/dev/null 2>&1 || true
  git worktree remove --force "$tmp/head" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

git worktree add -q --detach "$tmp/base" "$base_sha"
git worktree add -q --detach "$tmp/head" "$head_sha"
for wt in "$tmp/base" "$tmp/head"; do
  mkdir -p "$wt/server"
  ln -s "$root/server/node_modules" "$wt/server/node_modules"
done

run_test() { # $1 worktree, $2 repo-relative test path
  (cd "$1/server" && node --test "${2#server/}") >"$tmp/log" 2>&1
}

bad=0
while IFS= read -r t; do
  mkdir -p "$tmp/base/$(dirname "$t")"
  git show "$head_sha:$t" >"$tmp/base/$t"
  if run_test "$tmp/base" "$t"; then
    echo "DECORATIVE: $t passes on base ${base_sha:0:12} without this change. Make it test the new behaviour." >&2
    bad=1
  elif ! run_test "$tmp/head" "$t"; then
    echo "RED AT HEAD: $t fails on ${head_sha:0:12}:" >&2
    tail -n 40 "$tmp/log" >&2
    bad=1
  else
    echo "bites: $t (fails on base, passes on head)"
  fi
done <<<"$tests"
exit "$bad"
