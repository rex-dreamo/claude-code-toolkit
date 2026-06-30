#!/usr/bin/env bash
#
# build-repo-map.sh — derive memory's repo-identity map from git remotes.
#
# Claude keys memory by the project's encoded filesystem PATH, so every clone of
# one repo (myproject-1, myproject-2, myproject-01, …) gets a SEPARATE memory bucket and the
# knowledge fragments. The stable identity that all clones share is their git
# remote (`origin`). This script walks the project root(s), and for each git repo
# folder records:  <home-normalized encoded bucket name>  ->  -REPO-<remote-slug>
#
# link-claude-memory.sh reads this map: any bucket listed here is canonicalized to
# its shared -REPO- key instead of its per-clone path key, so all clones (on any
# Mac, under any folder name) link to ONE bucket. https and ssh remotes normalize
# to the same slug, so the same repo always yields the same key.
#
# The local map is per-Mac (folder layout differs), git-ignored, and cheap to
# rebuild. Scope is deliberately just ~/Development/GitHubProjects (the documented
# standard); ~/.claude and other dirs are intentionally NOT scanned and keep their
# path key.
#
# In addition to the local map, this Mac's lines are UPSERTED into a SHARED map in
# the iCloud store (STORE/repo-map.tsv): this Mac's bucket lines replace any prior
# lines for the same buckets, while every OTHER Mac's lines are preserved. The
# shared map lets link-claude-memory.sh fold buckets whose owning clone is offline
# or gone (orphans) — so one consolidation run on either Mac is complete, without
# waiting for both Macs to run. It only ever writes small text map files; it never
# touches memory content.
#
# Usage:
#   build-repo-map.sh            Rebuild local map + publish to shared store map
#   build-repo-map.sh --dry-run  Print what it would write; change nothing
#
set -uo pipefail

ROOTS="${CLAUDE_SCAN_ROOTS_OVERRIDE:-$HOME/Development/GitHubProjects}"
MAP="${CLAUDE_REPO_MAP_OVERRIDE:-$HOME/.claude/.memory-repo-map}"
STORE="${CLAUDE_STORE_OVERRIDE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory}"
SHARED_MAP="${CLAUDE_SHARED_MAP_OVERRIDE:-$STORE/repo-map.tsv}"
ENCODED_HOME="${CLAUDE_ENCODED_HOME_OVERRIDE:-$(printf '%s' "$HOME" | sed 's/[^[:alnum:]]/-/g')}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

encode()    { printf '%s' "$1" | sed 's/[^[:alnum:]]/-/g'; }
home_norm() { case "$1" in
                "$ENCODED_HOME")   echo "-HOME" ;;
                "$ENCODED_HOME"-*) echo "-HOME${1#"$ENCODED_HOME"}" ;;
                *)                 echo "$1" ;;
              esac; }
# repo_slug <dir> -> "-REPO-<slug>" from origin remote, or non-zero if no remote.
# Strips scheme (https://), user@ (git@), and a trailing .git so https and ssh
# forms of the same repo collapse to one slug; then non-alnum -> '-'.
repo_slug() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  url="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/@]+@##; s#\.git/?$##')"
  printf -- '-REPO-%s' "$(printf '%s' "$url" | sed 's/[^[:alnum:]]/-/g')"
}

# upsert_shared <new-lines-file> <shared-map> — merge this Mac's lines into the
# shared map: keep every line whose bucket (field 1) we are NOT republishing, then
# add ours. awk's own arrays are used (not bash), so this is bash-3.2 safe. The
# result is sorted+deduped, so a line identical across Macs collapses to one.
upsert_shared() {
  local new="$1" shared="$2"
  mkdir -p "$(dirname "$shared")"
  if [ -f "$shared" ]; then
    awk -F'|' 'NR==FNR { mine[$1]=1; next } !($1 in mine)' "$new" "$shared" > "$shared.tmp"
    cat "$new" >> "$shared.tmp"
    LC_ALL=C sort -u "$shared.tmp" -o "$shared.tmp"
    mv "$shared.tmp" "$shared"
  else
    LC_ALL=C sort -u "$new" -o "$shared"
  fi
}

tmp="$(mktemp)"
for root in $ROOTS; do
  [ -d "$root" ] || continue
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    slug="$(repo_slug "$d")" || continue
    [ -n "$slug" ] || continue
    printf '%s|%s\n' "$(home_norm "$(encode "$d")")" "$slug" >> "$tmp"
  done
done
LC_ALL=C sort -u "$tmp" -o "$tmp"

n_buckets="$(grep -c . "$tmp" 2>/dev/null || echo 0)"
n_repos="$(cut -d'|' -f2 "$tmp" 2>/dev/null | LC_ALL=C sort -u | grep -c . 2>/dev/null || echo 0)"

if [ "$DRY" = 1 ]; then
  echo "# DRY-RUN: would write $n_buckets clone bucket(s) across $n_repos repo(s) -> $MAP"
  echo "# DRY-RUN: would upsert the same lines into shared map -> $SHARED_MAP"
  cat "$tmp"; rm -f "$tmp"; exit 0
fi

cp "$tmp" "$MAP"
echo "memory-repo-map: $n_buckets clone bucket(s) across $n_repos repo(s) -> $MAP"

# Publish into the shared store map (only when the store is reachable).
if [ -d "$STORE" ] || [ -n "${CLAUDE_SHARED_MAP_OVERRIDE:-}" ]; then
  upsert_shared "$tmp" "$SHARED_MAP"
  echo "memory-repo-map: published $n_buckets bucket line(s) -> $SHARED_MAP"
else
  echo "memory-repo-map: store not present — shared map skipped." >&2
fi
rm -f "$tmp"
