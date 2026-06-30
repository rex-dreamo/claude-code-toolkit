#!/usr/bin/env bash
#
# post-gate-test.sh — hermetic regression suite for hooks/pr-post-gate.sh
# (the PreToolUse posting gate) and the feedback-map.sh failure-skip markers.
#
# Hermetic: the cache dir is a sandbox under /tmp via CLAUDE_PR_GATE_CACHE_DIR.
# Crucially, the sandbox path handed to the gate is itself a SYMLINK to the
# real dir — every assertion therefore doubles as the regression net for the
# macOS bug where `find /tmp -maxdepth 1` silently returns nothing because
# /tmp -> private/tmp and BSD find doesn't follow command-line symlinks.
# (A gate that mishandles symlinked cache dirs fails this whole suite.)
#
# Drives the REAL gate script over stdin — no regex re-declaration here.
#
set -u
GATE="$HOME/.claude/hooks/pr-post-gate.sh"
FMAP="$HOME/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh"

SB=$(mktemp -d /tmp/post-gate-test.XXXXXX)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/cache-real"
ln -s "$SB/cache-real" "$SB/cache"
CACHE="$SB/cache"   # symlink — see header

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

gate_bash() { # $1 = bash command string; prints gate exit code
    jq -cn --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}' \
        | CLAUDE_PR_GATE_CACHE_DIR="$CACHE" bash "$GATE" >/dev/null 2>&1
    echo $?
}
gate_json() { # $1 = full input JSON; prints gate exit code
    printf '%s' "$1" | CLAUDE_PR_GATE_CACHE_DIR="$CACHE" bash "$GATE" >/dev/null 2>&1
    echo $?
}
expect_allow() { # $1 desc, $2 rc
    [ "$2" -eq 0 ] && ok "allow: $1" || bad "expected ALLOW (got $2): $1"
}
expect_deny() { # $1 desc, $2 rc
    [ "$2" -eq 2 ] && ok "deny:  $1" || bad "expected DENY (got $2): $1"
}
clean_cache() { rm -f "$SB/cache-real/"*; }
fresh_map()  { touch "$SB/cache-real/pr-feedback-acme-widgets-$1.json"; }
stale() { # $1 filename — push mtime 2h back
    touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$SB/cache-real/$1"
}

echo "TEST executable bits"
[ -x "$GATE" ] && ok "gate is executable" || bad "gate is NOT executable"
[ -x "$FMAP" ] && ok "feedback-map.sh is executable" || bad "feedback-map.sh NOT executable"

echo "TEST non-posting Bash commands pass (no map present)"
clean_cache
expect_allow "gh pr view 32"                       "$(gate_bash 'gh pr view 32')"
expect_allow "gh pr diff 32"                       "$(gate_bash 'gh pr diff 32')"
expect_allow "gh pr list"                          "$(gate_bash 'gh pr list')"
expect_allow "git commit -m fix-the-gate"          "$(gate_bash 'git commit -m "fix gh pr comment gate"')"
expect_allow "echo mentioning the path"            "$(gate_bash 'echo "the gh pr comment path"')"
expect_allow "quoted timeout+gh phrase"            "$(gate_bash 'echo "timeout 5 gh pr comment is gated"')"
expect_allow "bash -c quoted post (known limitation)" "$(gate_bash 'bash -c "gh pr comment 32 --body x"')"
expect_allow "gh api read of PR"                   "$(gate_bash 'gh api repos/acme/widgets/pulls/32')"
expect_allow "gh api GET read of comments"         "$(gate_bash 'gh api repos/acme/widgets/pulls/32/comments --paginate')"
expect_allow "gh api GET read of reviews"          "$(gate_bash 'gh api repos/acme/widgets/pulls/32/reviews')"
expect_allow "ls"                                  "$(gate_bash 'ls -la')"

echo "TEST posting blocked without a map"
clean_cache
expect_deny  "gh pr comment 32"                    "$(gate_bash 'gh pr comment 32 --body "looks wrong"')"
expect_deny  "gh pr review 32 --approve"           "$(gate_bash 'gh pr review 32 --approve')"
expect_deny  "gh pr comment via URL"               "$(gate_bash 'gh pr comment https://github.com/acme/widgets/pull/32 --body hi')"
expect_deny  "gh pr comment, branch-resolved"      "$(gate_bash 'gh pr comment --body "no number"')"
expect_deny  "gh api POST comments"                "$(gate_bash 'gh api repos/acme/widgets/pulls/32/comments -f body=dup')"
expect_deny  "gh api POST issue comments"          "$(gate_bash 'gh api repos/acme/widgets/issues/32/comments -f body=dup')"
expect_deny  "gh api --method POST reviews"        "$(gate_bash 'gh api --method POST repos/acme/widgets/pulls/32/reviews --input review.json')"
expect_deny  "gh api -X POST thread reply"         "$(gate_bash 'gh api -X POST repos/acme/widgets/pulls/comments/99/replies -f body=ok')"
expect_deny  "compound cd && post"                 "$(gate_bash 'cd repo && gh pr comment 32 --body hi')"
expect_deny  "piped body | post"                   "$(gate_bash 'cat body.md | gh pr comment 32 --body-file -')"
expect_deny  "timeout-wrapped post"                "$(gate_bash 'timeout 30 gh pr comment 32 --body x')"
expect_deny  "timeout 30s-wrapped post"            "$(gate_bash 'timeout 30s gh pr review 32 --approve')"
expect_deny  "env-wrapped post"                    "$(gate_bash 'env GH_PAGER=cat gh pr comment 32 --body x')"
expect_deny  "timeout-wrapped api POST"            "$(gate_bash 'timeout 30 gh api repos/acme/widgets/pulls/32/comments -f body=x')"
# Heredoc body with a line-start posting command is a KNOWN false positive
# (grep is line-oriented; data lines are indistinguishable from commands).
# Accepted: cost is one deny on a rare shape; use the Write tool for such files.
# This assertion documents the behavior so a refactor can't change it silently.
expect_deny  "heredoc data line (known FP, accepted)" "$(gate_bash $'cat > /tmp/s.sh <<EOF\ngh pr comment 32 --body x\nEOF')"

echo "TEST deny message instructs feedback-map, never mentions the skip marker"
clean_cache
errmsg=$(jq -cn '{tool_name:"Bash", tool_input:{command:"gh pr comment 32 --body x"}}' \
    | CLAUDE_PR_GATE_CACHE_DIR="$CACHE" bash "$GATE" 2>&1 >/dev/null)
printf '%s' "$errmsg" | grep -q 'feedback-map.sh' && ok "deny instructs feedback-map.sh" || bad "deny message lacks feedback-map.sh"
printf '%s' "$errmsg" | grep -qi 'skip' && bad "deny message leaks the skip marker" || ok "deny does not leak the bypass"

echo "TEST fresh map allows; per-PR precision"
clean_cache; fresh_map 32
expect_allow "posting to PR 32 with PR-32 map"     "$(gate_bash 'gh pr comment 32 --body verified')"
expect_allow "api POST to PR 32 with PR-32 map"    "$(gate_bash 'gh api repos/acme/widgets/pulls/32/comments -f body=ok')"
expect_deny  "posting to PR 51 with only PR-32 map" "$(gate_bash 'gh pr comment 51 --body other')"
expect_allow "unparseable N falls back to any-map" "$(gate_bash 'gh pr comment --body "branch-resolved"')"

echo "TEST stale map (>60 min) blocks again"
clean_cache; fresh_map 32; stale "pr-feedback-acme-widgets-32.json"
expect_deny  "stale PR-32 map"                     "$(gate_bash 'gh pr comment 32 --body late')"

echo "TEST skip markers (failure escape)"
clean_cache; touch "$SB/cache-real/pr-feedback-skip-32"
expect_allow "per-PR skip marker"                  "$(gate_bash 'gh pr comment 32 --body x')"
expect_deny  "per-PR skip does not cover PR 51"    "$(gate_bash 'gh pr comment 51 --body x')"
clean_cache; touch "$SB/cache-real/pr-feedback-skip"
expect_allow "global skip marker"                  "$(gate_bash 'gh pr comment 51 --body x')"
clean_cache; touch "$SB/cache-real/pr-feedback-skip"; stale "pr-feedback-skip"
expect_deny  "expired global skip marker"          "$(gate_bash 'gh pr comment 32 --body x')"

echo "TEST feedback-map.sh creates the marker on genuine fetch failure"
clean_cache
# exit 2 path: strip gh from PATH (jq must stay reachable for the gate; the
# map script checks gh first). /usr/bin:/bin has neither gh nor brew tools.
env PATH=/usr/bin:/bin CLAUDE_PR_GATE_CACHE_DIR="$CACHE" bash "$FMAP" acme widgets 32 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "feedback-map exits 2 without gh" || bad "feedback-map rc=$rc (expected 2)"
[ -e "$SB/cache-real/pr-feedback-skip" ] && ok "global skip marker created on failure" || bad "no skip marker after failure exit"
expect_allow "gate honors the failure marker"      "$(gate_bash 'gh pr comment 32 --body x')"

echo "TEST self-referential guard"
clean_cache
expect_allow "command mentioning pr-post-gate.sh"  "$(gate_bash 'printf x | bash ~/.claude/hooks/pr-post-gate.sh')"
expect_allow "command mentioning tests/hooks/"     "$(gate_bash 'bash ~/.claude/tests/hooks/run-all.sh')"

echo "TEST MCP github tools"
clean_cache
expect_deny  "pull_request_review_write, no map" \
    "$(gate_json '{"tool_name":"mcp__plugin_github_github__pull_request_review_write","tool_input":{"owner":"acme","repo":"widgets","pullNumber":32}}')"
fresh_map 32
expect_allow "pull_request_review_write, fresh map" \
    "$(gate_json '{"tool_name":"mcp__plugin_github_github__pull_request_review_write","tool_input":{"owner":"acme","repo":"widgets","pullNumber":32}}')"
clean_cache
expect_allow "add_issue_comment on a never-mapped issue (plain issue: zero friction)" \
    "$(gate_json '{"tool_name":"mcp__plugin_github_github__add_issue_comment","tool_input":{"owner":"acme","repo":"widgets","issue_number":7}}')"
fresh_map 32; stale "pr-feedback-acme-widgets-32.json"
expect_deny  "add_issue_comment on a mapped-but-stale PR" \
    "$(gate_json '{"tool_name":"mcp__plugin_github_github__add_issue_comment","tool_input":{"owner":"acme","repo":"widgets","issue_number":32}}')"
clean_cache; fresh_map 32
expect_allow "add_issue_comment on a freshly mapped PR" \
    "$(gate_json '{"tool_name":"mcp__plugin_github_github__add_issue_comment","tool_input":{"owner":"acme","repo":"widgets","issue_number":32}}')"

echo "TEST edge inputs"
expect_allow "malformed stdin"                     "$(printf 'not json' | CLAUDE_PR_GATE_CACHE_DIR="$CACHE" bash "$GATE" >/dev/null 2>&1; echo $?)"
expect_allow "unknown tool"                        "$(gate_json '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')"

echo ""
echo "post-gate-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
