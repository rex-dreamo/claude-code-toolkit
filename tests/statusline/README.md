# Statusline regression tests

Regression net for [`statusline-command.sh`](../../statusline-command.sh) — the
`statusLine` command Claude Code runs to draw the bottom bar.

## Run

```bash
bash ~/.claude/tests/statusline/run-all.sh     # non-zero exit if any fail
```

## Why this exists

The status line shipped, then went through several "it looks the same / it
doesn't update" rounds whose real causes were invisible to eyeballing:

- **`seq 1 0` counts downward on BSD** — the fill-bar loop produced 10 cells
  instead of 8 at exactly 0% and 100%. Pinned: the bar is asserted to be
  exactly 8 cells across the full 0–100 range.
- **Path blowup → right-zone truncation** — a long or worktree path rendered in
  full and pushed the context bar and `5h:` badge off the terminal edge, so the
  "new" segments were simply never visible. Pinned: raw `.claude/worktrees` and
  `Development/GitHubProjects` strings must never survive into the output.
- **"Invented fields" scare** — `pr.*`, `vim.*`, `workspace.git_worktree` were
  briefly suspected of being made up because they were absent from one captured
  payload. They are all in the [documented schema](https://code.claude.com/docs/en/statusline);
  they are just conditional. `fixtures/full-payload.json` mirrors that schema so
  the field set has a committed source of truth.

## Hermetic by construction

Suites drive the real script purely over stdin with JSON payloads shaped like
the documented schema. The one real-world touch is `git -C ~/.claude` (to prove
a branch renders *without* the old `git:` prefix); it reads nothing and is
guarded for the no-branch case. Multibyte-sensitive assertions (bar length,
visible width) use `python3` because bash 3.2 can't length-count UTF-8.

## Fixture

`fixtures/full-payload.json` is the documented statusLine JSON with realistic
values. It is both an end-to-end render case and the reference for which fields
exist — edit it (not guesswork) when the schema changes.
