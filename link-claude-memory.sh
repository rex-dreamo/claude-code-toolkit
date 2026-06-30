#!/usr/bin/env bash
#
# link-claude-memory.sh — share Claude memory across Macs via iCloud Drive,
#                         independent of each Mac's macOS username.
#
# Claude stores memory at ~/.claude/projects/<encoded-path>/memory, where
# <encoded-path> is the project's absolute path with every non-alphanumeric
# character turned into "-". The home prefix /Users/<user> therefore encodes to
# -Users-<user>, so the SAME project gets DIFFERENT dir names on two Macs with
# different usernames (-Users-usera-... vs -Users-userb-...) and their memory
# never lines up.
#
# This script removes the username from memory's identity. In the iCloud store
# the home prefix is normalized to a fixed token "-HOME", so every Mac maps a
# given project to ONE canonical store dir. Each Mac's local memory dir stays a
# symlink under its own -Users-<user>-... name, pointing at that shared canonical
# dir. Result: write a memory on either Mac, see it on both.
#
#   local (Mac A)  ~/.claude/projects/-Users-usera-...-proj/memory       ┐
#                                                                       ├─► iCloud store: projects/-HOME-...-proj/memory
#   local (Mac B)  ~/.claude/projects/-Users-userb-...-proj/memory ┘
#
# Why iCloud and not the claude-config git repo: memory is machine-authored,
# high-churn, concurrently mutated on two Macs, and business-sensitive. Git
# would produce merge conflicts on auto-generated prose and bake customer data
# into history forever. iCloud handles concurrent edits non-destructively
# (conflict copies). See the project_claude_config_repo memory note for the full rationale.
#
# Everything here is NON-DESTRUCTIVE: legacy per-user store dirs are consolidated
# by UNION (never delete; filename clashes keep both), guarded by a marker so it
# runs once, and the whole store is small enough to back up trivially first.
#
# Usage:
#   link-claude-memory.sh            Consolidate + link everything (chatty). On a
#                                    local/canonical clash it UNIONs local into the
#                                    canonical store (lossless; differing files kept
#                                    both) before linking — never demotes local data.
#   link-claude-memory.sh --auto     Hook mode: silent unless noteworthy. Also unions
#                                    losslessly on a clash (self-heals; was previously
#                                    a manual step).
#   link-claude-memory.sh --dry-run  Print every action it WOULD take; change nothing.
#   link-claude-memory.sh --unlink   Reverse: replace each symlink with a real copy
#                                    from the iCloud store (clean rollback).
#   link-claude-memory.sh --prune-superseded
#                                    The ONLY destructive op, and manual-only: delete
#                                    a store bucket already tagged .superseded-by-<slug>
#                                    iff every one of its files is byte-identical in the
#                                    -REPO-<slug> target (re-verified with cmp).
#   link-claude-memory.sh --reconcile-index
#                                    Merge a folded repo's MEMORY.md.conflict-* index
#                                    copies into one complete MEMORY.md (union bullets;
#                                    prose-bearing indexes are left + flagged for a human).
#                                    The chatty no-arg run does this too; --auto only warns.
#
# Repo-identity consolidation (auto/manual): all clones of one git repo collapse to
# one -REPO-<slug> bucket. It is NON-DESTRUCTIVE by construction — it only unions
# (copy-missing / skip-identical / keep-both-on-clash) and repoints symlinks, snapshots
# the store once before the first merge, and appends every action to consolidation.log.
# Source buckets are tagged superseded, never deleted on the auto path.
#
set -uo pipefail

PROJECTS="${CLAUDE_PROJECTS_OVERRIDE:-$HOME/.claude/projects}"
STORE="${CLAUDE_STORE_OVERRIDE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory}"
STORE_PROJECTS="$STORE/projects"

# Repo-identity map (built by build-repo-map.sh): lines "<home-normalized bucket>|-REPO-<slug>".
# When a bucket is listed here, canonicalize() returns its shared -REPO- key so every
# clone of one git repo links to ONE bucket. Absent map = pure path-keying (old behavior).
REPO_MAP="${CLAUDE_REPO_MAP_OVERRIDE:-$HOME/.claude/.memory-repo-map}"

# Shared repo map in the store (published by every Mac). Used by the consolidation
# pass to fold ALL clone buckets of a repo — including orphans whose local clone is
# gone — into one -REPO- bucket. NOSHARE lists buckets/slugs to keep path-keyed
# (escape hatch for a deliberately divergent worktree). Both optional.
SHARED_MAP="${CLAUDE_SHARED_MAP_OVERRIDE:-$STORE/repo-map.tsv}"
NOSHARE="${CLAUDE_NOSHARE_OVERRIDE:-$HOME/.claude/.memory-repo-noshare}"

# build-repo-map.sh lives beside this script; --auto/manual refresh+publish the map
# before consolidating (skipped under a test REPO_MAP override, where the map is fixed).
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BUILD_MAP="$SCRIPT_DIR/build-repo-map.sh"

# Weekly rotating backup of the store, into a SIBLING dir in iCloud (NOT inside the
# store — keeping it inside would recursively bloat the sync). Gated to once per
# interval by a marker; keeps the newest N. All three overridable (tests + tuning).
WEEKLY_BACKUP_DIR="${CLAUDE_BACKUP_DIR_OVERRIDE:-$(dirname "$STORE")/ClaudeMemory-backups}"
BACKUP_INTERVAL_DAYS="${CLAUDE_BACKUP_INTERVAL_DAYS:-7}"
BACKUP_KEEP="${CLAUDE_BACKUP_KEEP:-6}"
# Sanitize: a non-numeric/empty/negative override would otherwise blow up `$(( ))`
# under `set -u` (bash treats a non-numeric token as a var name -> "unbound variable"
# -> exit 127 -> the whole SessionStart --auto run aborts). The `*[!0-9]*` glob also
# catches a leading '-'. INTERVAL=0 is allowed (means "back up every run").
case "$BACKUP_INTERVAL_DAYS" in ''|*[!0-9]*) BACKUP_INTERVAL_DAYS=7 ;; esac
case "$BACKUP_KEEP"          in ''|*[!0-9]*) BACKUP_KEEP=6 ;; esac
[ "$BACKUP_KEEP" -lt 1 ] && BACKUP_KEEP=1   # always retain at least one snapshot

# Encoded form of THIS Mac's home dir, e.g. /Users/<user> -> -Users-<user>.
# (Override is for the test harness only.)
ENCODED_HOME="${CLAUDE_ENCODED_HOME_OVERRIDE:-$(printf '%s' "$HOME" | sed 's/[^[:alnum:]]/-/g')}"

MODE="manual"; DRY=0
for arg in "$@"; do
  case "$arg" in
    --auto)             MODE="auto" ;;
    --unlink)           MODE="unlink" ;;
    --prune-superseded) MODE="prune" ;;
    --reconcile-index)  MODE="reconcile" ;;
    --dry-run)          DRY=1 ;;
    "")                 : ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { if [ "$MODE" != "auto" ]; then echo "$@"; fi; }
warn() { echo "$@" >&2; }
ts()   { date +%Y%m%d-%H%M%S; }

# ---- dry-run-aware mutation primitives ---------------------------------------
_mkdirp() { if [ "$DRY" = 1 ]; then say "DRY mkdir -p $1"; else mkdir -p "$1"; fi; }
_mv()     { if [ "$DRY" = 1 ]; then say "DRY mv $1 -> $2"; else mv "$1" "$2"; fi; }
_ln()     { if [ "$DRY" = 1 ]; then say "DRY ln -s $1 <- $2"; else ln -s "$1" "$2"; fi; }
_rm()     { if [ "$DRY" = 1 ]; then say "DRY rm $1"; else rm "$1"; fi; }
_cp()     { if [ "$DRY" = 1 ]; then say "DRY cp $1 -> $2"; else cp -p "$1" "$2"; fi; }
_touch()  { if [ "$DRY" = 1 ]; then say "DRY touch $1"; else : > "$1"; fi; }
# _rm_rf — recursive delete, guarded to paths strictly under the store (the only
# place this script ever deletes), and only from --prune-superseded.
_rm_rf()  {
  case "$1" in
    "$STORE_PROJECTS"/*) : ;;
    *) warn "refusing to rm outside store: $1"; return 1 ;;
  esac
  if [ "$DRY" = 1 ]; then say "DRY rm -rf $1"; else rm -rf "$1"; fi
}

link_target() { readlink "$1" 2>/dev/null; }

# ---- iCloud reachability check ------------------------------------------------
ICLOUD_ROOT="${CLAUDE_STORE_OVERRIDE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs}"
if [ ! -d "$(dirname "$STORE")" ] && [ -z "${CLAUDE_STORE_OVERRIDE:-}" ]; then
  warn "link-claude-memory: iCloud Drive not found — skipping."
  exit 0   # never fail a session-start hook over this
fi

linked=0 seeded=0 adopted=0 conflicts=0 already=0 migrated=0 cleaned=0 merged=0 repo_folded=0 pruned=0 reconciled=0

# audit <msg> — append a timestamped line to the store's consolidation log so the
# automatic, unattended path is observable after the fact (never silent).
audit() {
  if [ "$DRY" = 1 ]; then say "DRY audit: $*"; return; fi
  echo "$(ts) $*" >> "$STORE/consolidation.log" 2>/dev/null || true
}

# is_superseded <store-bucket-dir> — true if it carries a .superseded-by-* marker.
is_superseded() {
  local m
  for m in "$1"/.superseded-by-*; do [ -e "$m" ] && return 0; done
  return 1
}

# canonicalize <local-basename> -> shared store key.
# Step 1: normalize this Mac's home prefix (-Users-<me> -> -HOME) so usernames pair.
# Step 2: if the home-normalized bucket is a known git clone (in REPO_MAP), return its
#         shared -REPO-<slug> key so ALL clones of that repo collapse to one bucket.
canonicalize() {
  local hk repo
  case "$1" in
    "$ENCODED_HOME")    hk="-HOME" ;;
    "$ENCODED_HOME"-*)  hk="-HOME${1#"$ENCODED_HOME"}" ;;
    *)                  hk="$1" ;;            # not under this home: shared verbatim
  esac
  # Escape hatch: a bucket listed in NOSHARE keeps its path key (divergent worktree).
  # (-e: keys start with "-", which grep would otherwise read as options.)
  if [ -f "$NOSHARE" ] && grep -qxF -e "$hk" "$NOSHARE"; then echo "$hk"; return; fi
  if [ -f "$REPO_MAP" ]; then
    # exact field match (awk), so e.g. "...project01-1" never matches "...project01-10".
    repo="$(awk -F'|' -v b="$hk" '$1==b {print $2; exit}' "$REPO_MAP")"
    if [ -n "$repo" ]; then
      # also honor an escape hatch listed by slug
      if [ -f "$NOSHARE" ] && grep -qxF -e "$repo" "$NOSHARE"; then echo "$hk"; return; fi
      echo "$repo"; return
    fi
  fi
  echo "$hk"
}

# decanonicalize <store key> -> THIS Mac's local basename (-HOME -> -Users-<me>)
decanonicalize() {
  case "$1" in
    "-HOME")    echo "$ENCODED_HOME" ;;
    "-HOME"-*)  echo "$ENCODED_HOME${1#-HOME}" ;;
    *)          echo "$1" ;;
  esac
}

# legacy_canon <store basename> -> canonical key if it's a legacy per-user dir
# (-Users-<anyuser>[-...]), else empty. Generic across usernames.
legacy_canon() {
  case "$1" in
    -HOME|-HOME-*) echo ""; return ;;          # already canonical
    -Users-*)      : ;;
    *)             echo ""; return ;;          # not under any /Users home
  esac
  local rest user tail
  rest="${1#-Users-}"; user="${rest%%-*}"
  [ -n "$user" ] || { echo ""; return; }
  tail="${rest#"$user"}"
  echo "-HOME$tail"
}

# union_dir <src> <dst> <tag> — copy src into dst non-destructively (recursive).
# Missing -> copy. Identical -> skip. Differing file -> keep both (suffix tag+ts).
union_dir() {
  local src="$1" dst="$2" tag="$3" f bn
  [ -d "$src" ] || return 0
  _mkdirp "$dst"
  for f in "$src"/* "$src"/.[!.]*; do
    [ -e "$f" ] || continue
    bn="$(basename "$f")"
    case "$bn" in .canon-migrated) continue ;; esac
    if [ -d "$f" ]; then
      union_dir "$f" "$dst/$bn" "$tag"
    elif [ ! -e "$dst/$bn" ]; then
      _cp "$f" "$dst/$bn"
    elif cmp -s "$f" "$dst/$bn" 2>/dev/null; then
      :
    else
      _cp "$f" "$dst/$bn.conflict-$tag-$(ts)"
      conflicts=$((conflicts+1))
      say "    conflict: $bn differs — kept both ($bn.conflict-$tag-...)"
    fi
  done
}

# snapshot_once — copy the whole store to a sibling backup, exactly once ever
# (marker-guarded). Cheap (the store is tiny) and belt-and-suspenders for the first
# big fold; the real safety is that consolidation is union-only.
snapshot_once() {
  [ -n "${CLAUDE_STORE_OVERRIDE:-}" ] && return 0   # tests: skip snapshotting
  local marker="$STORE/.consolidate-snapshot-done"
  [ -e "$marker" ] && return 0
  local bk; bk="$(dirname "$STORE")/ClaudeMemory.backup-$(ts)"
  if [ "$DRY" = 1 ]; then say "DRY snapshot $STORE -> $bk"; return 0; fi
  if cp -R "$STORE" "$bk" 2>/dev/null; then
    : > "$marker"; audit "snapshot: $STORE -> $bk"
    say "  snapshot:  store backed up -> $(basename "$bk")"
  else
    warn "link-claude-memory: store snapshot failed — consolidation skipped this run."
    return 1
  fi
}

# weekly_backup — rotating snapshot of the store into a SIBLING iCloud dir, at most
# once per BACKUP_INTERVAL_DAYS (marker-gated), keeping the newest BACKUP_KEEP.
# snapshot_once only ever fires before the first big fold; this is the ONGOING net,
# so an accidental store corruption (bad fold, iCloud sync glitch, fat-finger) is
# recoverable to within a week. Runs on every --auto launch, but the marker makes
# all but ~one launch a week a cheap no-op. Backups live OUTSIDE the store so they
# never recursively re-enter the sync set.
weekly_backup() {
  [ "$DRY" = 1 ] && return 0
  # In tests the store is overridden; only run when the backup dir is ALSO overridden
  # so a dedicated backup test can exercise this without ever touching real iCloud.
  [ -n "${CLAUDE_STORE_OVERRIDE:-}" ] && [ -z "${CLAUDE_BACKUP_DIR_OVERRIDE:-}" ] && return 0
  [ -d "$STORE_PROJECTS" ] || return 0
  local now interval marker last dest
  now="$(date +%s 2>/dev/null)" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  interval=$(( BACKUP_INTERVAL_DAYS * 86400 ))
  mkdir -p "$WEEKLY_BACKUP_DIR" 2>/dev/null || { warn "link-claude-memory: cannot create backup dir."; return 0; }
  marker="$WEEKLY_BACKUP_DIR/.last"
  last=0; [ -f "$marker" ] && last="$(cat "$marker" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt "$interval" ] && return 0   # backed up recently — no-op
  dest="$WEEKLY_BACKUP_DIR/store-$(ts)"
  # Avoid a same-second name collision (concurrent run, or two Macs within the iCloud
  # marker-propagation window) — cp -R into an existing dir would nest as store-<ts>/projects.
  [ -e "$dest" ] && dest="$dest-$$"
  if cp -R "$STORE_PROJECTS" "$dest" 2>/dev/null; then
    [ -f "$STORE/repo-map.tsv" ]      && cp -p "$STORE/repo-map.tsv" "$dest/" 2>/dev/null
    [ -f "$STORE/consolidation.log" ] && cp -p "$STORE/consolidation.log" "$dest/" 2>/dev/null
    printf '%s\n' "$now" > "$marker"
    audit "weekly-backup: $STORE_PROJECTS -> $dest"
    say "  backup:    weekly snapshot -> $(basename "$dest")"
    [ "$MODE" = "auto" ] && echo "link-claude-memory: weekly memory backup -> $(basename "$dest")"
    # Rotation: keep the newest BACKUP_KEEP, delete the rest. Sort by the timestamped
    # NAME (sort -r => newest first), NOT mtime — iCloud eviction/re-download can
    # rewrite mtimes, so `ls -dt` could drop a newer backup; the name is authoritative.
    # tail -n +N drops the kept prefix. while-read (not a for-loop) because the iCloud
    # path contains a space ("Mobile Documents") and would word-split unquoted.
    ls -d "$WEEKLY_BACKUP_DIR"/store-* 2>/dev/null | sort -r | tail -n +"$(( BACKUP_KEEP + 1 ))" | while IFS= read -r old; do
      case "$old" in
        "$WEEKLY_BACKUP_DIR"/store-*) rm -rf "$old" && audit "weekly-backup: rotated out $(basename "$old")" ;;
      esac
    done
  else
    warn "link-claude-memory: weekly backup failed (store copy)."
  fi
}

# consolidate_repos — fold every clone bucket of a repo into its shared -REPO- dir,
# driven by the shared map. Non-destructive: union_dir only; sources are tagged
# .superseded-by-<slug>, never deleted here. Idempotent (identical files skipped).
consolidate_repos() {
  [ -f "$SHARED_MAP" ] || return 0
  local slug bucket src dst snapped=0
  for slug in $(awk -F'|' '{print $2}' "$SHARED_MAP" | LC_ALL=C sort -u); do
    case "$slug" in -REPO-*) : ;; *) continue ;; esac
    if [ -f "$NOSHARE" ] && grep -qxF -e "$slug" "$NOSHARE"; then continue; fi
    dst="$STORE_PROJECTS/$slug/memory"
    for bucket in $(awk -F'|' -v s="$slug" '$2==s {print $1}' "$SHARED_MAP"); do
      [ "$bucket" = "$slug" ] && continue
      if [ -f "$NOSHARE" ] && grep -qxF -e "$bucket" "$NOSHARE"; then continue; fi
      src="$STORE_PROJECTS/$bucket/memory"
      [ -d "$src" ] || continue                         # orphan line: nothing to fold
      is_superseded "$STORE_PROJECTS/$bucket" && continue
      if [ "$snapped" = 0 ]; then snapshot_once || return 0; snapped=1; fi
      local before=$conflicts
      union_dir "$src" "$dst" "fold-$bucket"
      _touch "$STORE_PROJECTS/$bucket/.superseded-by-$slug"
      repo_folded=$((repo_folded+1))
      audit "fold: $bucket/memory -> $slug/memory ($((conflicts-before)) clash(es) kept-both)"
      say "  folded:    $bucket/memory -> $slug/memory"
    done
  done
}

# subset_ok <src> <dst> — true iff every regular file under src exists byte-identical
# under dst (markers ignored). Used by --prune-superseded before any delete.
subset_ok() {
  local src="$1" dst="$2" f bn
  for f in "$src"/* "$src"/.[!.]*; do
    [ -e "$f" ] || continue
    bn="$(basename "$f")"
    case "$bn" in .superseded-by-*|.canon-migrated) continue ;; esac
    if [ -d "$f" ]; then
      subset_ok "$f" "$dst/$bn" || return 1
    else
      cmp -s "$f" "$dst/$bn" 2>/dev/null || return 1
    fi
  done
  return 0
}

# has_prose <file> — true if it has any line that is NOT blank, a header (#…), or
# an index bullet (- [..](..)). Such content (e.g. a "## Lessons" section) can't be
# safely auto-merged, so its presence makes us defer that index to a human.
has_prose() {
  awk '
    /^[[:space:]]*$/ { next }
    /^#/             { next }
    /^- \[/          { next }
    { found=1 }
    END { exit(found?0:1) }
  ' "$1"
}

# reconcile_index <repo-memory-dir> — make the folded bucket's MEMORY.md complete.
# A fold keeps each clone's own index as MEMORY.md.conflict-*, so the primary index
# can be missing entries. This unions the index BULLETS (by link target, longest
# line wins) into MEMORY.md and removes the now-redundant conflict copies — but ONLY
# when every variant is a pure bullet list. If any variant carries prose, it is left
# untouched and flagged, because merging prose needs human/LLM judgement, not awk.
# Manual-only (it both rewrites the index and deletes files); --auto only warns.
reconcile_index() {
  local d="$1"
  local base="$d/MEMORY.md"
  local bkt; bkt="$(basename "$(dirname "$d")")"   # the -REPO-… bucket, not "memory"
  local v list
  list=$(ls "$d"/MEMORY.md.conflict-* 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  local prose=0
  [ -f "$base" ] && has_prose "$base" && prose=1
  for v in $list; do has_prose "$v" && prose=1; done
  if [ "$prose" = 1 ]; then
    warn "link-claude-memory: index for $bkt contains prose — needs manual merge (kept *.conflict-*)."
    return 0
  fi
  if [ "$DRY" = 1 ]; then say "DRY reconcile-index $bkt ($(printf '%s\n' $list | wc -l | tr -d ' ') copy/ies)"; return 0; fi
  local merged hdr
  merged="$(mktemp)"
  hdr="$( { [ -f "$base" ] && grep -m1 '^#' "$base"; } 2>/dev/null )"; [ -n "$hdr" ] || hdr="# Memory Index"
  awk '
    function target(line,   a){ if (match(line, /\]\([^)]*\)/)) return substr(line,RSTART+2,RLENGTH-3); return line }
    /^- \[/ {
      t=target($0)
      if (!(t in seen)) { order[++n]=t; best[t]=$0; seen[t]=1 }
      else if (length($0) > length(best[t])) { best[t]=$0 }
    }
    END { for (i=1;i<=n;i++) print best[order[i]] }
  ' "$base" $list > "$merged"
  { echo "$hdr"; echo ""; cat "$merged"; } > "$base"
  rm -f "$merged"
  for v in $list; do _rm "$v"; done
  reconciled=$((reconciled+1))
  say "  reconciled: $bkt index — $(grep -c '^- \[' "$base") entries, removed $(printf '%s\n' $list | wc -l | tr -d ' ') copy/ies"
  audit "reconcile-index: $bkt -> $(grep -c '^- \[' "$base") entries"
}

# reconcile every -REPO- bucket's index (used by manual run and --reconcile-index).
reconcile_all() {
  local s
  for s in "$STORE_PROJECTS"/-REPO-*/; do
    [ -d "${s}memory" ] || continue
    reconcile_index "${s}memory"
  done
}

# ---- --unlink: reverse everything --------------------------------------------
if [ "$MODE" = "unlink" ]; then
  say "Unlinking: replacing symlinks with real copies from iCloud..."
  for dir in "$PROJECTS"/*/memory; do
    [ -L "$dir" ] || continue
    tgt="$(link_target "$dir")"
    _rm "$dir"
    if [ -d "$tgt" ]; then
      if [ "$DRY" = 1 ]; then say "DRY cp -R $tgt -> $dir"; else cp -R "$tgt" "$dir"; fi
      say "  restored:  $(basename "$(dirname "$dir")")/memory (real copy)"
    else
      _mkdirp "$dir"
      say "  recreated empty: $(basename "$(dirname "$dir")")/memory"
    fi
  done
  say "Done. iCloud store left intact at: $STORE"
  exit 0
fi

_mkdirp "$STORE_PROJECTS"

# Rotating weekly backup runs FIRST in every store-touching mode — so even a manual
# --prune-superseded (the one destructive op) is preceded by a fresh-enough snapshot.
weekly_backup

# ---- --prune-superseded: the ONLY destructive mode, manual-only --------------
# Delete a store bucket tagged .superseded-by-<slug> iff every file in it is
# byte-identical under the -REPO-<slug> target (re-verified now with cmp).
if [ "$MODE" = "prune" ]; then
  for s in "$STORE_PROJECTS"/*/; do
    [ -d "$s" ] || continue
    sdir="${s%/}"; sbn="$(basename "$sdir")"
    m="$(ls "$sdir"/.superseded-by-* 2>/dev/null | head -1)" || true
    [ -n "$m" ] || continue
    slug="${m##*/.superseded-by-}"
    dst="$STORE_PROJECTS/$slug/memory"
    if [ -d "$sdir/memory" ] && [ -d "$dst" ] && subset_ok "$sdir/memory" "$dst"; then
      if _rm_rf "$sdir"; then
        pruned=$((pruned+1)); audit "prune: removed $sbn (verified subset of $slug)"
        say "  pruned:    $sbn (verified subset of $slug)"
      fi
    else
      warn "prune: SKIP $sbn — not a verified byte-identical subset of $slug (kept)."
    fi
  done
  echo "link-claude-memory: pruned $pruned superseded bucket(s). Store: $STORE"
  exit 0
fi

# ---- --reconcile-index: merge folded clones' index copies into one MEMORY.md --
if [ "$MODE" = "reconcile" ]; then
  reconcile_all
  echo "link-claude-memory: reconciled $reconciled index(es). Store: $STORE"
  exit 0
fi

# ---- PASS 0: consolidate legacy per-user store dirs into canonical keys -------
# Runs once per legacy dir (a .canon-migrated marker makes it idempotent/cheap).
# Store-global: whichever Mac runs this consolidates BOTH Macs' legacy data,
# because the iCloud store is shared.
if [ -d "$STORE_PROJECTS" ]; then
  for s in "$STORE_PROJECTS"/*/; do
    [ -d "$s" ] || continue
    sbn="$(basename "$s")"
    [ -e "$s/.canon-migrated" ] && continue
    canon="$(legacy_canon "$sbn")"
    [ -n "$canon" ] || continue
    [ "$canon" = "$sbn" ] && continue
    [ -d "$s/memory" ] || { _touch "$s/.canon-migrated"; continue; }
    tag="${sbn#-Users-}"; tag="${tag%%-*}"
    say "  consolidate: $sbn/memory -> $canon/memory (union, keeping legacy)"
    union_dir "$s/memory" "$STORE_PROJECTS/$canon/memory" "$tag"
    _touch "$s/.canon-migrated"
    migrated=$((migrated+1))
  done
fi

# ---- Refresh+publish the repo map, then fold clones into shared -REPO- buckets
# Skipped under a test REPO_MAP override (fixed map) and on --dry-run (no writes).
if [ "$DRY" != 1 ] && [ -z "${CLAUDE_REPO_MAP_OVERRIDE:-}" ] && [ -f "$BUILD_MAP" ]; then
  bash "$BUILD_MAP" >/dev/null 2>&1 || warn "link-claude-memory: build-repo-map failed; using existing map."
fi
consolidate_repos

# ---- PASS 1: link each LOCAL project dir to its canonical store target --------
link_local() {
  local bn="$1"
  local D="$PROJECTS/$bn/memory"
  local canon; canon="$(canonicalize "$bn")"
  local T="$STORE_PROJECTS/$canon/memory"

  # Already correctly linked?
  if [ -L "$D" ] && [ "$(link_target "$D")" = "$T" ]; then
    already=$((already+1)); return
  fi

  # Stray symlink (e.g. old per-user target): ensure canonical target has the
  # data, then repoint. The data move is covered by PASS 0 for store dirs, but
  # also pull this Mac's own legacy target in case PASS 0 didn't see it.
  if [ -L "$D" ]; then
    local old; old="$(link_target "$D")"
    # Pull data forward only if it isn't already consolidated: PASS 0 marks legacy
    # dirs (.canon-migrated) and consolidate_repos marks folded clones
    # (.superseded-by-*). Skipping a folded source avoids re-introducing stale
    # *.conflict-* index copies every time the 2nd Mac repoints to the -REPO- bucket.
    if [ -d "$old" ] && [ "$old" != "$T" ] \
       && [ ! -e "$(dirname "$old")/.canon-migrated" ] \
       && ! is_superseded "$(dirname "$old")"; then
      union_dir "$old" "$T" "$ENCODED_HOME"
    fi
    _rm "$D"; _mkdirp "$(dirname "$T")"; [ -d "$T" ] || _mkdirp "$T"; _ln "$T" "$D"
    say "  repointed: $bn/memory -> $canon/memory"
    linked=$((linked+1)); return
  fi

  local d_real="false"; [ -d "$D" ] && d_real="true"
  local t_exists="false"; [ -d "$T" ] && t_exists="true"

  if [ "$d_real" = "true" ] && [ "$t_exists" = "false" ]; then
    _mkdirp "$(dirname "$T")"; _mv "$D" "$T"; _ln "$T" "$D"
    say "  seeded:    $bn/memory -> $canon (iCloud)"
    seeded=$((seeded+1))
  elif [ "$d_real" = "true" ] && [ "$t_exists" = "true" ]; then
    # Both local (a real dir) and canonical exist — the dangerous case. We must
    # NOT just adopt canonical: this Mac's local-only memories (never yet synced)
    # would silently drop out of the live set. Instead UNION local into canonical
    # (identical files skipped, missing copied, genuine clashes kept as .conflict
    # copies — never overwritten), THEN replace local with a symlink. After the
    # union canonical is a superset of local, so linking loses nothing. The
    # pre-merge local dir is parked as a backup purely to guard against a copy
    # that failed mid-union; it is redundant once verified and safe to delete.
    local before=$conflicts
    union_dir "$D" "$T" "local-$ENCODED_HOME"
    local backup; backup="$D.premerge-backup-$(ts)"
    _mv "$D" "$backup"; _ln "$T" "$D"
    merged=$((merged+1))
    if [ "$conflicts" -gt "$before" ]; then
      warn "link-claude-memory: $bn/memory — merged local into canonical; $((conflicts-before)) file(s) differed and were kept BOTH (review *.conflict-* in the store)."
    else
      say "  merged:    $bn/memory — local unioned into canonical, linked (backup: $(basename "$backup"))"
      [ "$MODE" = "auto" ] && warn "link-claude-memory: $bn/memory — merged local memory into canonical (iCloud), linked."
    fi
  elif [ "$d_real" = "false" ] && [ "$t_exists" = "true" ]; then
    _mkdirp "$(dirname "$D")"; _ln "$T" "$D"
    say "  adopted:   $bn/memory <- $canon (iCloud)"
    adopted=$((adopted+1))
  fi
}

if [ -d "$PROJECTS" ]; then
  for d in "$PROJECTS"/*/; do
    [ -d "$d" ] || [ -L "${d%/}" ] || continue
    link_local "$(basename "$d")"
  done
fi

# ---- PASS 2: adopt canonical store dirs this Mac doesn't have locally ---------
# Only canonical (-HOME-*) and genuinely-shared non-/Users dirs; never legacy
# per-user dirs (those are superseded by PASS 0).
if [ -d "$STORE_PROJECTS" ]; then
  for s in "$STORE_PROJECTS"/*/; do
    [ -d "$s" ] || continue
    sbn="$(basename "$s")"
    case "$sbn" in
      -Users-*) continue ;;     # legacy per-user: superseded by PASS 0
      -REPO-*)  continue ;;     # repo-keyed: reached only via PASS 1 when a clone exists
                                #             locally — can't map a -REPO key to one path.
    esac
    is_superseded "${s%/}" && continue   # folded into a -REPO- bucket — don't re-adopt
    [ -d "$s/memory" ] || continue
    localbn="$(decanonicalize "$sbn")"
    D="$PROJECTS/$localbn/memory"
    [ -e "$D" ] || [ -L "$D" ] && continue
    _mkdirp "$(dirname "$D")"; _ln "$s/memory" "$D"
    say "  adopted:   $localbn/memory <- $sbn (iCloud)"
    adopted=$((adopted+1))
  done
fi

# ---- Index reconciliation (after all folds/links, so one run catches them all)-
# Manual runs MERGE folded index copies (rewrites MEMORY.md + deletes the redundant
# copies — kept out of --auto so the unattended path never deletes content).
# --auto instead WARNS, so an incomplete index is never silent.
if [ "$MODE" = "auto" ]; then
  pend=0
  for s in "$STORE_PROJECTS"/-REPO-*/; do
    [ -d "${s}memory" ] || continue
    ls "${s}memory"/MEMORY.md.conflict-* >/dev/null 2>&1 && pend=$((pend+1))
  done
  [ "$pend" -gt 0 ] && warn "link-claude-memory: $pend repo index(es) need reconciliation — run: link-claude-memory.sh --reconcile-index"
else
  reconcile_all
fi

# ---- PASS 3: remove vestigial cross-user local symlinks -----------------------
# On this Mac, -Users-<otheruser>-* local dirs can only be old adoptions from the
# pre-canonical scheme (Claude never has a cwd under another user's home here).
# They are pure symlinks (no data), now superseded by canonical adoption.
if [ -d "$PROJECTS" ]; then
  for d in "$PROJECTS"/*/; do
    bn="$(basename "$d")"
    case "$bn" in
      "$ENCODED_HOME"|"$ENCODED_HOME"-*) continue ;;   # mine
      -Users-*) : ;;                                    # another user's
      *) continue ;;
    esac
    M="$PROJECTS/$bn/memory"
    if [ -L "$M" ]; then
      _rm "$M"
      [ "$DRY" = 1 ] || rmdir "$PROJECTS/$bn" 2>/dev/null || true
      say "  cleaned:   vestigial $bn/memory (cross-user symlink)"
      cleaned=$((cleaned+1))
    fi
  done
fi

# ---- Keep iCloud copies materialized (avoid eviction to dataless placeholders)
if [ "$DRY" != 1 ] && [ -z "${CLAUDE_STORE_OVERRIDE:-}" ] && command -v brctl >/dev/null 2>&1; then
  brctl download "$STORE" >/dev/null 2>&1 || true
fi

# ---- Summary -----------------------------------------------------------------
if [ "$MODE" = "auto" ]; then
  [ "$repo_folded" -gt 0 ] && echo "link-claude-memory: folded $repo_folded clone bucket(s) into -REPO- bucket(s) — union-only, sources tagged superseded (reclaim with --prune-superseded)."
  [ "$merged" -gt 0 ] && echo "link-claude-memory: merged $merged local dir(s) into canonical (iCloud) — lossless union."
  [ "$reconciled" -gt 0 ] && echo "link-claude-memory: reconciled $reconciled repo index(es)."
  [ "$conflicts" -gt 0 ] && warn "link-claude-memory: $conflicts file-level clash(es) kept both — review *.conflict-* copies in the store."
  [ "$migrated" -gt 0 ] && echo "link-claude-memory: consolidated $migrated legacy dir(s) into canonical -HOME keys."
else
  echo "link-claude-memory: $already linked, $seeded seeded, $adopted adopted, $merged merged, $repo_folded folded, $reconciled index-reconciled, $linked repointed, $migrated consolidated, $cleaned vestigial cleaned, $conflicts conflicts."
  echo "Store: $STORE"
fi
exit 0
