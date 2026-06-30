# tests/githooks

Regression suite for `githooks/pre-commit` — the secret & org-context guard that
blocks credential-shaped content and git-ignored org literals from being committed.

```bash
bash tests/githooks/run-all.sh
```

## Suites

| Suite | Covers |
|---|---|
| `scan-test.sh` | `pre-commit` staged-diff guard: credential patterns BLOCK (AWS/GitHub/AI/Google/Slack keys, private-key headers, hardcoded secret assignments); placeholders & prose ALLOW (`${VAR}`, `YOUR_`, `<…>`, shell `$VAR`); `blocklist.local` org-literal matching; `tests/githooks/` path exclusion; `SKIP_SECRET_SCAN=1` bypass. |
| `scan-tree-test.sh` | `scan-tree.sh` whole-tree publish gate: clean tree passes; credentials & denylist literals/regexes block; `tests/githooks/` exempt; bad dir → exit 2. Uses fake literals only. |

## Hermeticity

Each suite builds a throwaway git repo under `mktemp -d`, copies the real
`githooks/pre-commit` into it, stages content, and asserts the hook's exit code.
The live `~/.claude` repo and your real `githooks/blocklist.local` are never read
or modified. Run this before committing changes to `githooks/pre-commit`.
