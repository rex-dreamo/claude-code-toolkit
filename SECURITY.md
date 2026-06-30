# Security model

This repo is **private** and contains operational context (an SSH host alias
target, GCP project IDs, service-account emails, internal project/container
names). It holds **no credentials** — those live only in `~/.secrets` (git-ignored)
and the macOS keychain. Before ever flipping this repo to public, read
**[Going public](#going-public)** below — it is not safe to publish as-is.

## Defense in depth

| Layer | Mechanism | Protects against |
|---|---|---|
| 1. Ignore | `.gitignore` excludes `*.pem`/`*.key`, `projects/` (memory + sessions), `*.jsonl`, `settings.local.json`, `plans/`, all caches/daemon state, and `githooks/blocklist.local`. | Accidentally tracking secrets, transcripts, or session data. |
| 2. Pre-commit guard | `githooks/pre-commit` scans **staged additions** and aborts the commit on credential-shaped content or any literal in `blocklist.local`. Installed repo-wide via `core.hooksPath=githooks` (done by `setup.sh`). | A key, token, private key, or known org literal being committed — now or in future. |
| 3. Runtime guards | `settings.json` `PreToolUse` hooks block Claude from reading `~/.secrets`, running `docker exec -it`, `pip install` on the NAS, or `docker run --privileged/-v`. | The agent itself leaking or misusing credentials/infra during a session. |
| 4. Secret storage | `~/.secrets` (chmod 600, git-ignored, sourced by `~/.zshrc`); MCP configs use literal `${ENV}` placeholders expanded at launch. | Secrets ever being written into tracked config. |

## The pre-commit guard

`githooks/pre-commit` runs on every `git commit` in this repo and inspects only the
lines a commit **adds** (via `git diff --cached -U0`), so it never re-flags
pre-existing lines.

**Always-on credential detection** — AWS access keys, GitHub tokens (classic +
fine-grained PAT), AI-provider keys (`sk-…`, `sk-ant-…`), Google API keys, Slack
tokens, private-key headers, and `password|secret|api_key|token = <value>`
assignments. Lines that are obvious placeholders (`${VAR}`, `$VAR`, `YOUR_…`,
`<…>`, `example`, `REDACT`) are excused.

**Org-literal blocklist** — `githooks/blocklist.local` (git-ignored; copy from
`blocklist.local.example`) holds your never-publish strings as `grep -E` regexes:
NAS host, project IDs, service-account emails, corporate email domain. The guard
knows these **without the repo storing them**. Matched unconditionally — the
placeholder allowlist cannot excuse a blocklisted literal.

```bash
# Verify the guard is installed in this clone:
git config --get core.hooksPath           # → githooks
# Test it:
bash tests/githooks/run-all.sh
# Bypass for a vetted false positive:
SKIP_SECRET_SCAN=1 git commit ...          # or: git commit --no-verify
```

The guard is **local** (a pre-commit hook can be bypassed and does not run on the
server). It is a strong speed bump, not a server-side control. For belt-and-braces,
enable GitHub **Secret Scanning + Push Protection** on the remote (Settings →
Code security) so the server rejects credential pushes even if the hook is skipped.

## Going public

A security audit (2026-06-29) found **no live credentials** but concluded the repo
is **not safe to publish as-is** — tracked files form a near-complete infra recon
map, including one internet-reachable SSH endpoint. To publish, either:

1. **Split (recommended) — automated via `publish.sh`.** This repo stays your
   live `~/.claude` (full org context); `publish.sh` derives a curated, org-free
   PUBLIC subset into `_public-export/` and refuses to ship unless
   `githooks/scan-tree.sh` finds zero secrets/org literals in the whole tree. The
   public allowlist (reusable engineering) is defined at the top of `publish.sh`;
   the org denylist lives in the git-ignored `githooks/publish-denylist.local`
   (seed from `*.example`). Run `bash publish.sh`, sanitise anything it flags,
   re-run until green, then create/push the public repo (the one manual,
   outward-facing step). An automated export stays clean forever; a one-time
   manual scrub rots.
2. **Scrub in place:** remove the NAS host/port/user, GCP project IDs, the 3
   service-account emails, container/repo names, the project-tier table, the
   company-identity block, the model App Store id, and the generated eval-output
   trees; replace your local home path (`/Users/<you>`) → `$HOME`; then enable the remaining
   `blocklist.local` entries to prevent reintroduction. Note: git **history** also
   needs rewriting (the corporate author email and every scrubbed literal
   persist in past commits).

Either way, turn on the commented-out `blocklist.local` entries afterward so the
guard prevents the literals from creeping back in.
