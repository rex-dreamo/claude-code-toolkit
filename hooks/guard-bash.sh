#!/usr/bin/env bash
#
# guard-bash.sh — PreToolUse guard for Bash commands.
#
# Consolidates the rules formerly inline in settings.json (docker exec -it, NAS
# pip install, docker run host-mounts, ~/.secrets access) into one testable
# script, and generalizes the secret-access block to every credential store in
# hooks/secret-paths.txt. Bash reads bypass tool-level deny rules
# (strings/source/cat/base64/curl/scp), so a command that READS or TRANSMITS a
# secret path is refused here — but a bare mention (echo, a comment, a git commit
# message describing the path) is not a read and is allowed, to avoid false
# positives. NOTE: command-string matching is a speed-bump, not a hard boundary
# (indirection via a script file or var-assembly can evade it); the real boundary
# is the permission-layer deny + the pre-commit exit-scan.
#
# Reads the tool call as JSON on stdin; exit 2 (with a stderr reason) blocks it.
# Deliberately bash-3.2 safe: no arrays, no `local var=$(...)`.
#
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS="$DIR/secret-paths.txt"

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || exit 0

# 1) docker exec -it — hangs forever without a TTY (CLAUDE.md §4).
if printf '%s' "$CMD" | grep -qE 'docker[[:space:]]+exec[[:space:]]+-[^ ]*[it]'; then
  echo 'Blocked: never use docker exec -it — it hangs forever without a TTY. Use docker exec without -it.' >&2
  exit 2
fi

# 2) pip install on the NAS native Python 3.8 — risks Synology DSM tools (CLAUDE.md §6).
if printf '%s' "$CMD" | grep -qE 'ssh[[:space:]]+nas.*pip3?[[:space:]]+install'; then
  echo 'Blocked: never pip install on the NAS native Python 3.8.' >&2
  exit 2
fi

# 3) docker run with host mounts / privileged — can expose host root.
if printf '%s' "$CMD" | grep -qE 'docker[[:space:]]+run' \
   && printf '%s' "$CMD" | grep -qE -- '--privileged|--volume|--mount|[[:space:]]-v[[:space:]]'; then
  echo 'Blocked: docker run with --privileged/-v/--volume/--mount can expose host root — narrow it or run it manually.' >&2
  exit 2
fi

# 4) A pure-secret store (hooks/secret-paths.txt) that is READ or TRANSMITTED —
#    a read/exfil verb, a command substitution `$(`/backtick, or a pipe. A bare
#    mention (echo, comment, commit message) is not a read, so it is allowed.
if [ -f "$PATTERNS" ] \
   && printf '%s' "$CMD" | grep -qiE -f <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PATTERNS"); then
  READCTX='(^|[[:space:];&|(])(cat|less|more|head|tail|strings|source|base64|xxd|od|hexdump|cp|mv|scp|rsync|curl|wget|nc|ncat|socat|tar|zip|dd|openssl|gpg|pbcopy|grep|egrep|fgrep|awk|sed|python3?|ruby|perl|node)([[:space:]]|$)'
  if printf '%s' "$CMD" | grep -qE "$READCTX" \
     || printf '%s' "$CMD" | grep -qE '\$\(|`|\|'; then
    echo 'Blocked: this command reads/transmits a protected credential store (hooks/secret-paths.txt).' >&2
    echo 'Secret stores are off-limits to Bash (reads bypass tool-level deny). Access them in your own terminal.' >&2
    exit 2
  fi
fi

exit 0
