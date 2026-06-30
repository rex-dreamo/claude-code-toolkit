# Memory-sharing regression tests

Regression net for the iCloud memory-sharing system —
[`link-claude-memory.sh`](../../link-claude-memory.sh) and
[`build-repo-map.sh`](../../build-repo-map.sh). See
[`MEMORY-SYNC.md`](../../MEMORY-SYNC.md) for the design.

## Run

```bash
bash ~/.claude/tests/memory-sync/run-all.sh     # all suites; non-zero exit if any fail
bash ~/.claude/tests/memory-sync/multimac-test.sh   # a single suite
```

## Hermetic by construction

Every suite drives the scripts entirely through `CLAUDE_*_OVERRIDE` sandboxes under
`/tmp` and **never** reads or writes the real `~/.claude/.memory-repo-map`, the real
iCloud store, or the real backups. `run-all.sh` also fingerprints the real maps
before/after and fails if anything changed.

Relevant overrides: `CLAUDE_PROJECTS_OVERRIDE`, `CLAUDE_STORE_OVERRIDE`,
`CLAUDE_ENCODED_HOME_OVERRIDE`, `CLAUDE_REPO_MAP_OVERRIDE` (local map; also disables
the linker's auto build-repo-map), `CLAUDE_SHARED_MAP_OVERRIDE`,
`CLAUDE_SCAN_ROOTS_OVERRIDE`, `CLAUDE_NOSHARE_OVERRIDE`, `CLAUDE_BACKUP_DIR_OVERRIDE`,
`CLAUDE_BACKUP_INTERVAL_DAYS`, `CLAUDE_BACKUP_KEEP`.

## Suites

| File | Covers |
|---|---|
| `lcm-test.sh` | Union-on-conflict (local memory never demoted); pre-merge backup. |
| `lcm-test2.sh` | `--auto` self-heals a clash losslessly; idempotency. |
| `repokey-test.sh` | `build-repo-map` derives shared keys from git remotes (https/ssh collapse); linker collapses clones to one `-REPO-` bucket. |
| `repokey-test2.sh` | Shared-map upsert (other Macs' lines preserved); non-destructive fold; tag superseded; `--prune-superseded` deletes only verified subsets; escape hatch. |
| `multimac-test.sh` | Two Macs, different usernames + **different folder names** for one repo → converge; distinct repos stay separate; cross-Mac repoint idempotency; index reconciliation (pure merged, prose flagged). |
| `onboard-test.sh` | Brand-new Mac (local **real** dirs) folds into existing `-REPO-`; NOSHARE-by-bucket; `--dry-run` changes nothing; missing/empty maps; mapped bucket with no memory dir. |
| `samepath-test.sh` | Pathological same-relative-path-different-repo across two Macs: folds once (no flip-flop), no data loss, each Mac routes its own clone to its own repo. |
| `backup-test.sh` | Weekly rotating store backup: takes a backup when due (contents + maps), marker gates re-runs, stale marker re-triggers, rotation keeps newest `BACKUP_KEEP`, rotation is **name-based not mtime-based** (iCloud-mtime-churn safe), `--dry-run` skips, backups land outside the store, rotation is correct + `rm`-bounded under a **spaced path** (`Mobile Documents`), and a bad numeric env (non-numeric/negative/zero `BACKUP_KEEP`/`INTERVAL`) is **sanitized, not fed raw into `$(( ))`** where `set -u` would abort the run. |

Total: ~103 assertions.
