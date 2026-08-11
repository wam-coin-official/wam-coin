#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  publish_site.sh -- push site/ to the gh-pages branch
# ===========================================================================
#
#      bash scripts/publish_site.sh
#
#  GitHub Pages serves the root of a branch, but the site lives in site/ on
#  main, because a website is part of the project and should be reviewed in
#  the same pull request as the claims it repeats.
#
#  `git subtree split` reconciles those: it rewrites the history of site/ as
#  though that directory had always been the repository root, and that is what
#  gh-pages becomes. The branch is therefore *generated*. Never edit it -- the
#  next run overwrites it, and an edit made there is an edit that disappears
#  without warning and takes the page with it.
#
#  The alternative -- checking out an orphan branch and copying files in by
#  hand -- leaves every file from main sitting untracked in the working tree,
#  which then blocks the checkout back. Ask how I know.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

BRANCH="${BRANCH:-gh-pages}"
REMOTE="${REMOTE:-origin}"
SRC="site"

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }

[ -d "$SRC" ] || fail "$SRC/ does not exist"
[ -f "$SRC/index.html" ] || fail "$SRC/index.html is missing -- nothing to serve"

# Pages ignores a directory whose CNAME disagrees with the configured domain,
# and the failure mode is a silent 404 on the custom domain while the
# github.io URL keeps working. Catch it here instead.
[ -f "$SRC/CNAME" ] || fail "$SRC/CNAME is missing -- the custom domain will not bind"
DOMAIN=$(tr -d '[:space:]' < "$SRC/CNAME")
ok "custom domain: $DOMAIN"

# Jekyll would try to render the page and drop any file beginning with an
# underscore. The site is hand-written HTML; it must be served verbatim.
[ -f "$SRC/.nojekyll" ] || fail "$SRC/.nojekyll is missing -- Pages would run Jekyll over the page"

if [ -n "$(git status --porcelain -- "$SRC")" ]; then
    fail "$SRC/ has uncommitted changes. subtree split reads committed history,
     so publishing now would put the *previous* version live and report success."
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD)

# The split branch is disposable: delete and re-derive, so a rerun is always
# idempotent rather than accumulating merge parents.
git branch -D "$BRANCH" >/dev/null 2>&1 || true
git subtree split --prefix "$SRC" -b "$BRANCH" >/dev/null
ok "split $SRC/ into $BRANCH at $(git rev-parse --short "$BRANCH")"

git push -f "$REMOTE" "$BRANCH":"$BRANCH"
ok "pushed to $REMOTE/$BRANCH"

# subtree split leaves HEAD alone, but be explicit -- this script is run
# rarely and by someone who will not remember what it touched.
[ "$(git rev-parse --abbrev-ref HEAD)" = "$CURRENT" ] || git checkout -q "$CURRENT"

echo
echo "  https://$DOMAIN  should update within a minute or two."
echo "  If it 404s, check Settings -> Pages: source must be branch '$BRANCH', folder '/ (root)'."
