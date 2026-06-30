# Claude Memory Sync (iCloud) — Manual

Claude's memory (`~/.claude/projects/<proj>/memory/`) is shared across your Macs
through **iCloud Drive** — **and it now pairs correctly even when the two Macs
have different macOS usernames** (e.g. `userb` vs `usera`). Write a memory on
either Mac, see it on both. This file is the runbook.

## How it works

Claude derives a project's memory dir by encoding its absolute path (every
non-alphanumeric char → `-`), so the home prefix `/Users/<user>` becomes
`-Users-<user>`. That embeds the **username** into the dir name, which used to
stop two differently-named Macs from ever lining up.

The linker removes the username from memory's identity by normalizing the home
prefix to a fixed token **`-HOME`** *in the iCloud store*. Each Mac's local
memory dir stays a symlink under its own `-Users-<user>-…` name, pointing at the
shared canonical dir:

```
Mac A (usera)      ~/.claude/projects/-Users-usera-…-proj/memory        ┐
                                                                       ├─▶ iCloud: projects/-HOME-…-proj/memory
Mac B (userb)      ~/.claude/projects/-Users-userb-…-proj/memory  ┘
```

The real files live in iCloud under the `-HOME-…` key; iCloud replicates them to
both Macs; each Mac's `-Users-<me>-…` symlink redirects transparently. Claude
reads/writes the normal local path and never sees the indirection. The symlinks
live *outside* iCloud, so only the real files sync.

### One memory per repo (clones converge)

Path-keying alone still fragments a repo across its clones: `example-app01-1`,
`example-app01-4`, and the other Mac's `example-app01-01` are different
paths → different buckets → split knowledge. The stable identity every clone
shares is its **git remote**. So **`~/.claude/build-repo-map.sh`** scans
`~/Development/GitHubProjects/`, and for each git repo writes
`<-HOME bucket>|-REPO-<remote-slug>` to two maps: a local `~/.claude/.memory-repo-map`
and a **shared `…/ClaudeMemory/repo-map.tsv`** in the store (each Mac upserts its
own lines, others preserved). `link-claude-memory.sh` then **canonicalizes any
mapped clone to its `-REPO-<slug>` key** and **folds every clone bucket of a repo
into that one `-REPO-` bucket**. Result: all clones — any folder name, any clone
suffix, any casing, either Mac — share one memory. https & ssh remotes normalize
to the same slug. The shared map lets one run fold even orphan buckets (a clone
that's gone/offline), so convergence is complete without waiting for both Macs.

The fold is **non-destructive**: union-only (identical skipped, missing copied,
genuine clashes kept *both* as `*.conflict-*`); source buckets are left in place,
tagged `.superseded-by-<slug>`, never deleted automatically. Reclaim them later
with `--prune-superseded` (the only destructive op; deletes a source bucket *only*
if every file is byte-identical in the `-REPO-` target).

**How same-named memory files merge.** Distinct files just coexist in the shared
bucket. Two clones with the *same filename but different content* are both kept
(the incoming one gets a `.conflict-*` suffix) — nothing is overwritten, but they
are **not** auto-merged into one file (merging prose needs judgement, not a script;
reconcile by hand when you next touch that project). The one exception is the index
**`MEMORY.md`**: a fold would otherwise leave it listing only one clone's memories,
so `--reconcile-index` (and the chatty no-arg run) **unions the index bullets** into
one complete `MEMORY.md` and drops the redundant copies. An index that mixes in
free-form prose is left + flagged instead of risk-merged.

**Distinct repos stay distinct.** Different remotes → different slugs, so
`…example-app02` and `…other-app` never cross-contaminate. **Non-repo dirs keep
their path key** (no remote → not mapped): `~/.claude`, the bare
`…GitHubProjects` root, and grandchild sub-paths like `management/gov-docs` stay
on their `-HOME-…` key. A clone you *want* kept separate (a divergent worktree)
goes in `~/.claude/.memory-repo-noshare` (one bucket or slug per line) — it then
keeps its path key.

**Why iCloud and not the `claude-config` git repo:** memory is auto-written,
high-churn, concurrently mutated on two Macs, and business-sensitive. Git would
conflict on generated prose and bake data into history. iCloud handles concurrent
edits non-destructively (`filename 2.md` conflict copies). `.gitignore` excludes
all of `projects/`.

The engine is **`~/.claude/link-claude-memory.sh`** (tracked in the repo, so both
Macs have it).

## Activate on a new / second Mac

Run once, in order:

```bash
# 1. Pull the config repo — gets the linker, the SessionStart hook, and .gitignore
cd ~/.claude && git pull

# 2. Let iCloud finish downloading the store before linking:
ls "$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory/projects"
#    If empty/incomplete, force-download and wait:
brctl download "$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory"

# 3. (optional, recommended once) back up the store outside iCloud first:
cp -R "$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory" \
      "$HOME/claude-memory-store-backup-$(date +%Y%m%d)"

# 4. Preview, then run. The first run CONSOLIDATES every legacy per-user dir
#    (-Users-<anyone>-…) into canonical -HOME-… keys (non-destructive union) and
#    repoints this Mac's local dirs at them. Whichever Mac runs it first
#    consolidates BOTH Macs' legacy data, because the store is shared.
bash ~/.claude/link-claude-memory.sh --dry-run | less   # preview every action
bash ~/.claude/link-claude-memory.sh                    # apply
```

After this, the SessionStart hook keeps everything linked automatically (below).

The consolidation is **non-destructive**: legacy `-Users-<user>-…` store dirs are
left in place (marked with a `.canon-migrated` file so they're processed only
once); their contents are *copied* into the `-HOME-…` bucket. If the same file
exists with different content in two legacy dirs, **both are kept** (the incoming
one gets a `.conflict-<user>-<timestamp>` suffix) — nothing is overwritten. Once
both Macs have run the new linker you may delete the legacy `-Users-*` store dirs
and the `*.conflict-*` / `memory.local-backup-*` artifacts after reviewing them.

## Daily operation (automatic)

A `SessionStart` hook runs `link-claude-memory.sh --auto` on every launch. `--auto`
is **silent unless something noteworthy happens**: it links new project memory dirs
to their canonical bucket and adopts canonical buckets this Mac doesn't have yet.
If it finds local data *and* canonical data both present for the same project, it
**unions the local files into the canonical bucket** (lossless: identical files are
skipped, missing ones copied, and genuinely-differing files are kept *both* as
`*.conflict-*` copies — local data is never demoted or lost), then links. New
projects self-heal on both Macs with no action from you.

`--auto` also **refreshes the repo map and folds repo clones** into their shared
`-REPO-` buckets (union-only; sources tagged superseded). Before the first fold it
snapshots the whole store once to `…/ClaudeMemory.backup-<ts>`, and appends every
fold/repoint to `…/ClaudeMemory/consolidation.log` — so the automatic path is
never silent. Folding is idempotent: once a clone is linked to its `-REPO-` bucket,
later runs are a no-op.

### Weekly rotating backup

The one-time `ClaudeMemory.backup-<ts>` snapshot only ever fires before the first
fold. For ongoing protection (a bad sync, a fat-finger, a future bug), `--auto` also
takes a **rotating weekly backup** of the store into a *sibling* iCloud dir
`…/CloudDocs/ClaudeMemory-backups/store-<ts>/`. It is marker-gated (`.last`, epoch)
so it runs at most once every 7 days regardless of how often sessions start, and it
keeps the **newest 6** snapshots (older ones are rotated out). Each snapshot holds
all `projects/*/memory/` buckets plus `repo-map.tsv` and `consolidation.log` (~1 MB).
The backup dir lives *outside* the store so backups never recursively re-enter the
sync set; because it's still in CloudDocs, the snapshots replicate to the other Mac
too (off-machine redundancy), and the shared `.last` marker means the two Macs take
turns rather than double-backing-up. Tunable via env: `CLAUDE_BACKUP_INTERVAL_DAYS`
(default 7), `CLAUDE_BACKUP_KEEP` (default 6). Restore is a plain `cp -R` from any
`store-<ts>/` back over `…/ClaudeMemory/projects/`.

> Earlier versions left a clash "untouched" in `--auto` and *adopted canonical /
> backed up local* in the manual run — which could drop a never-synced Mac's
> local-only memory out of the live set. As of 2026-06-06 both paths union
> losslessly, so no manual pre-merge is needed anymore.

## Commands

| Command | What it does |
|---|---|
| `bash ~/.claude/link-claude-memory.sh` | Consolidate legacy dirs into `-HOME` keys + link everything (chatty). Run manually. |
| `bash ~/.claude/link-claude-memory.sh --dry-run` | Print every action it *would* take; change nothing. |
| `bash ~/.claude/link-claude-memory.sh --auto` | Non-destructive; silent unless it consolidates, unions a clash, or keeps-both on a file conflict. (What the hook runs.) |
| `bash ~/.claude/link-claude-memory.sh --unlink` | Reverse: replace each symlink with a real copy from iCloud. Clean rollback; store left intact. |
| `bash ~/.claude/link-claude-memory.sh --prune-superseded` | The only destructive op (manual). Delete source buckets already folded into a `-REPO-` bucket, but only after re-verifying every file is byte-identical there. |
| `bash ~/.claude/link-claude-memory.sh --reconcile-index` | Merge a folded repo's `MEMORY.md.conflict-*` index copies into one complete `MEMORY.md` (union the bullet entries; longest description wins). Indexes that contain free-form prose are left and flagged for a human/LLM merge. The chatty no-arg run does this automatically; `--auto` only warns. |
| `bash ~/.claude/build-repo-map.sh [--dry-run]` | Rebuild the local repo map + publish to the shared store map. Run automatically by `--auto`; standalone is rarely needed. |

## Troubleshooting

- **A memory written on one Mac isn't on the other yet** → iCloud propagation lag. Confirm both
  Macs are on the same iCloud account with iCloud Drive on, then
  `brctl download "$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory"`.
- **`filename 2.md` appears** → iCloud conflict copy from a true simultaneous edit. Merge by hand;
  rare (you're seldom in the same project on both Macs at once).
- **A `memory/` dir is a real folder again, not a symlink** → re-run the full linker; it re-seeds
  or adopts as appropriate.
- **iCloud "Optimize Mac Storage" evicted files** → the linker/hook runs `brctl download` each time
  to keep the (tiny) files materialized; if you hit a read error, run that command manually.

## Caveats

- **Casing is NOT a problem on standard macOS.** `GitHubProjects` vs `Githubprojects` encode to
  different `-HOME-…` keys, but macOS volumes are **case-insensitive by default** (APFS/HFS+),
  so both keys resolve to the *same physical directory* in the store — they pair automatically.
  (Verified: the two casings share one inode.) The only way casing could fragment is a
  **case-sensitive** volume (rare; you'd have chosen it deliberately at format time). To check:
  `mkdir /tmp/Cc && [ -d /tmp/cc ] && echo insensitive; rmdir /tmp/Cc`.
- **Repo clones converge regardless of location/suffix/casing.** For any git repo under
  `~/Development/GitHubProjects/`, memory keys by the **git remote** (`-REPO-<slug>`), not the
  path — so `example-app01-1`, `-app01-4`, and the other Mac's `-app01-01` all share
  one bucket, and the folder name / clone suffix / casing no longer fragments them. Differing
  clone suffixes (`-1` vs `-01`) were the *real* fragmentation the repo map fixes.
- **Relative layout still matters only for non-repo dirs.** Path-keyed dirs (no git remote, or
  outside the scan root — `~/.claude`, the bare projects root, grandchild sub-paths) still pair by
  their path below `$HOME`, so those must live at the same relative path on both Macs. The repo
  standard `~/Development/GitHubProjects/` keeps everything aligned.
- **A shared-users location** (the macOS `Users/Shared` area, if you ever ran Claude
  there) would also normalize its `-Users-Shared` prefix to `-HOME`. Not a real
  concern for normal project work; noted for completeness.
