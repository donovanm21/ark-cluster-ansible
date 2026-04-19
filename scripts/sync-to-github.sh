#!/usr/bin/env bash
# sync-to-github.sh — maintainer tool to push main to the public GitHub
# remote with the dev-only `.gitea/` directory stripped out.
#
# Usage:
#   scripts/sync-to-github.sh              # uses remote named 'github'
#   scripts/sync-to-github.sh myremote     # uses a different remote name
#
# Prereq: add the GitHub remote once —
#   git remote add github git@github.com:OWNER/REPO.git
#
# What it does:
#   1. Spins up a temporary git worktree of current HEAD.
#   2. Removes .gitea/ from that worktree (the dev CI lives there).
#   3. Commits the removal: "strip dev workflows for public release".
#   4. Force-pushes (with lease) to <remote>/main.
#   5. Removes the temp worktree and branch.
#
# Your local main stays pristine — only the public remote sees the strip commit.

set -euo pipefail

REMOTE="${1:-github}"
BRANCH=main

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

git remote | grep -qx "$REMOTE" \
    || die "remote '$REMOTE' not configured. add it: git remote add $REMOTE git@github.com:OWNER/REPO.git"

[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] \
    || die "run from the $BRANCH branch (currently $(git rev-parse --abbrev-ref HEAD))"

git diff --quiet && git diff --cached --quiet \
    || die "working tree is dirty; commit or stash first"

TMP=$(mktemp -d)
WT="$TMP/wt"
cleanup() {
    git worktree remove --force "$WT" 2>/dev/null || true
    git branch -D sync-to-github-tmp 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

git worktree add -b sync-to-github-tmp "$WT" HEAD >/dev/null

(
    cd "$WT"
    if [[ -d .gitea ]]; then
        rm -rf .gitea
        git add -A
        git commit -m "Strip dev-only .gitea/ workflows for public release" >/dev/null
    fi
    git push --force-with-lease "$REMOTE" "sync-to-github-tmp:$BRANCH"
)

printf '\nsynced to %s/%s (without .gitea/)\n' "$REMOTE" "$BRANCH"
