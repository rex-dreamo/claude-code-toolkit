#!/usr/bin/env bash
#
# render-test.sh — hermetic golden-render suite for statusline-command.sh.
#
# Drives the REAL script over stdin with JSON payloads shaped exactly like the
# documented statusLine schema (code.claude.com/docs/en/statusline). Asserts on
# the ANSI-stripped output plus the raw colour codes. No part of the script is
# re-implemented here, so the script stays the single source of truth.
#
# Why this exists: the statusline went through several "looks the same" bugs
# whose root causes were invisible to eyeballing — a BSD `seq 1 0` that counts
# DOWNWARD (corrupting the bar at 0% and 100%) and a width blowout that
# truncated away the newest segments. Both are now pinned below.
#
set -u
SCRIPT="$HOME/.claude/statusline-command.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Render the script for a given JSON payload ($1). Raw output (ANSI intact).
render() { printf '%s' "$1" | bash "$SCRIPT"; }
# ANSI-stripped plain text.
plain()  { render "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
# Multibyte-correct counts (bash 3.2 can't length-count UTF-8 reliably).
bar_len()  { render "$1" | python3 -c 'import sys,re; s=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()); print(len(re.findall(r"[█░]",s)))'; }
vis_width(){ render "$1" | python3 -c 'import sys,re; s=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()).rstrip("\n"); print(len(s))'; }

# Shorthand payload builder: a model + a context dir, plus extra JSON merged in.
pay() { # $1 = current_dir, $2 = extra top-level JSON object members (may be empty)
  local extra="${2:-}"
  [ -n "$extra" ] && extra=",$extra"
  printf '{"model":{"display_name":"Fable 5"},"workspace":{"current_dir":"%s"}%s}' "$1" "$extra"
}
contains()    { plain "$1" | grep -qF "$2"; }
not_contains(){ ! plain "$1" | grep -qF "$2"; }
raw_has()     { render "$1" | grep -qF "$2"; }   # check raw ANSI codes

echo "TEST executable bit"
[ -x "$SCRIPT" ] && ok "script is executable" || bad "script is NOT executable"

echo "TEST context bar is always exactly 8 cells (the seq 1 0 regression)"
for pct in 0 1 10 49 50 63 79 80 84 89 90 96 100; do
  n=$(bar_len "$(pay /x "\"context_window\":{\"used_percentage\":$pct}")")
  [ "$n" -eq 8 ] && ok "bar=8 at ${pct}%" || bad "bar=$n at ${pct}% (expected 8)"
done
n=$(bar_len "$(pay /x)")   # no context_window at all → fresh-session anchor
[ "$n" -eq 8 ] && ok "bar=8 when used_percentage absent" || bad "bar=$n absent (expected 8)"

echo "TEST bar fill scales with percentage"
contains "$(pay /x '"context_window":{"used_percentage":0}')"   "░░░░░░░░ 0%"   && ok "0% all empty"  || bad "0% fill wrong"
contains "$(pay /x '"context_window":{"used_percentage":100}')" "████████ 100%" && ok "100% all full" || bad "100% fill wrong"

echo "TEST bar colour thresholds (green<50, yellow 50-79, orange 80-89, red 90+)"
raw_has "$(pay /x '"context_window":{"used_percentage":10}')" '38;5;114m' && ok "green at 10%"  || bad "green missing at 10%"
raw_has "$(pay /x '"context_window":{"used_percentage":63}')" '38;5;228m' && ok "yellow at 63%" || bad "yellow missing at 63%"
raw_has "$(pay /x '"context_window":{"used_percentage":84}')" '38;5;215m' && ok "orange at 84%" || bad "orange missing at 84%"
raw_has "$(pay /x '"context_window":{"used_percentage":96}')" '38;5;203m' && ok "red at 96%"    || bad "red missing at 96%"

echo "TEST no 'git:' prefix (old-style regression guard) + branch still shown"
realbranch=$(git -C "$HOME/.claude" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
out_real=$(pay "$HOME/.claude")
not_contains "$out_real" "git:" && ok "no git: prefix" || bad "git: prefix leaked back"
if [ -n "$realbranch" ]; then
  contains "$out_real" "$realbranch" && ok "branch '$realbranch' rendered" || bad "branch not rendered"
fi

echo "TEST model name compaction"
contains   "$(pay /x '"model":{"display_name":"Opus 4.8 (1M context)"}')" "Opus 4.8·1M" && ok "(1M context) → ·1M" || bad "model not compacted"
not_contains "$(pay /x '"model":{"display_name":"Opus 4.8 (1M context)"}')" "(1M context)" && ok "verbose suffix gone" || bad "verbose suffix remains"

echo "TEST long-path fish abbreviation"
contains "$(pay "$HOME/Development/GitHubProjects/example-service")" "~/D/G/example-service" && ok "fish-abbrev long path" || bad "long path not abbreviated"
contains "$(pay "$HOME/short")" "~/short" && ok "short path left intact" || bad "short path mangled"

echo "TEST worktree path compaction"
WT="$HOME/Development/GitHubProjects/example-ops/.claude/worktrees/sequential-brewing-manatee"
contains "$(pay "$WT/videogen")" "example-ops⎇videogen" && ok "worktree subdir → repo⎇tail" || bad "worktree subdir wrong"
contains "$(pay "$WT")" "example-ops⎇sequential-brewing-manatee" && ok "worktree root → repo⎇wt" || bad "worktree root wrong"
not_contains "$(pay "$WT/videogen")" "/./" && ok "no mangled /./ from .claude" || bad ".claude mangled to /./"

echo "TEST PR badge (real, documented field — fires only when pr present)"
contains "$(pay /x '"pr":{"number":42,"review_state":"changes_requested"}')" "PR#42 needs-changes" && ok "changes_requested → needs-changes" || bad "PR needs-changes wrong"
contains "$(pay /x '"pr":{"number":7,"review_state":"approved"}')" "PR#7 approved" && ok "approved badge" || bad "PR approved wrong"
contains "$(pay /x '"pr":{"number":9}')" "PR#9" && ok "bare PR number" || bad "bare PR wrong"
not_contains "$(pay /x)" "PR#" && ok "no PR badge when pr absent" || bad "PR badge leaked when absent"

echo "TEST vim mode (real, documented field)"
contains "$(pay /x '"vim":{"mode":"INSERT"}')" "INSERT" && ok "vim INSERT shown" || bad "vim INSERT missing"
not_contains "$(pay /x)" "INSERT" && ok "no vim segment when absent" || bad "vim leaked when absent"

echo "TEST 5h rate limit badge"
contains "$(pay /x '"rate_limits":{"five_hour":{"used_percentage":47}}')" "5h:47%" && ok "5h badge shown" || bad "5h badge missing"
not_contains "$(pay /x)" "5h:" && ok "no 5h badge when absent (usage-credit billing)" || bad "5h leaked when absent"

echo "TEST effort badge (only non-medium)"
contains   "$(pay /x '"effort":{"level":"high"}')" ":high" && ok "high → :high" || bad "high effort missing"
not_contains "$(pay /x '"effort":{"level":"medium"}')" ":medium" && ok "medium → no badge" || bad "medium effort shown"
not_contains "$(pay /x)" ":high" && ok "no effort badge when absent" || bad "effort leaked when absent"

echo "TEST session name capping (>16 chars)"
contains "$(pay /x '"session_name":"example-long-session-name"')" "example-long-se…" && ok "long name truncated +…" || bad "long name not capped"
contains "$(pay /x '"session_name":"short"')" "[short]" && ok "short name whole" || bad "short name altered"

echo "TEST output style (only non-default)"
contains   "$(pay /x '"output_style":{"name":"Explanatory"}')" "[Explanatory]" && ok "non-default style shown" || bad "style missing"
not_contains "$(pay /x '"output_style":{"name":"default"}')" "[default]" && ok "default style hidden" || bad "default style shown"

echo "TEST repo segment shown only when it adds info"
contains     "$(printf '{"model":{"display_name":"Fable 5"},"workspace":{"current_dir":"%s/x","repo":{"owner":"example-org","name":"widget"}}}' "$HOME")" "example-org/widget" && ok "repo shown when dir≠repo" || bad "repo missing"
not_contains "$(printf '{"model":{"display_name":"Fable 5"},"workspace":{"current_dir":"%s/widget","repo":{"owner":"example-org","name":"widget"}}}' "$HOME")" "example-org/widget" && ok "repo hidden when dir==repo" || bad "redundant repo shown"

echo "TEST path never blows up (the truncation regression that started all this)"
# The original bug: a long/worktree path rendered in full and pushed the
# right-zone segments (bar, 5h) off the edge. Guard the cause directly — the
# raw path strings must never survive into the output — rather than a brittle
# total-width number (a legitimate everything-on line is ~160 chars wide).
deeppay="$(printf '{"model":{"display_name":"Fable 5"},"workspace":{"current_dir":"%s/videogen","repo":{"owner":"example-org","name":"example-ops"}},"context_window":{"used_percentage":63},"rate_limits":{"five_hour":{"used_percentage":47}}}' "$WT")"
not_contains "$deeppay" ".claude/worktrees"        && ok "worktree path compacted away"   || bad "raw .claude/worktrees path leaked"
not_contains "$(pay "$HOME/Development/GitHubProjects/example-service")" "Development/GitHubProjects" && ok "long path fish-abbreviated away" || bad "raw long path leaked"
contains "$deeppay" "5h:47%"                        && ok "right-zone 5h badge survives"    || bad "5h badge truncated by path"

echo "TEST fail-open on malformed / empty stdin"
# stderr silenced: the script intentionally fail-opens, so its internal jq
# "parse error" chatter on garbage input is expected, not a test failure.
out=$(printf 'not json' | bash "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "malformed stdin exits 0" || bad "malformed stdin rc=$rc"
out=$(printf '' | bash "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "empty stdin exits 0" || bad "empty stdin rc=$rc"

echo "TEST documented full-payload fixture renders end-to-end"
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/full-payload.json"
if [ -f "$FIX" ]; then
  fout=$(bash "$SCRIPT" < "$FIX" | sed $'s/\033\\[[0-9;]*m//g')
  echo "$fout" | grep -qF "PR#42 needs-changes" \
    && echo "$fout" | grep -qF "5h:47%" \
    && echo "$fout" | grep -qF "Opus 4.8·1M:high" \
    && echo "$fout" | grep -qF "INSERT" \
    && ok "fixture exercises pr+5h+model+vim segments" || bad "fixture render missing a segment: $fout"
else
  bad "fixture file missing: $FIX"
fi

echo ""
echo "render-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
