#!/usr/bin/env bash
# feedback-map.sh — fetch + pre-digest every comment/review/review-comment on
# a GitHub PR. Emits a structured JSON map keyed by file/line, with each thread
# tagged by resolution status detected from the PR author's reply.
#
# Why pre-digest in the script: thread reconstruction, signal detection, and
# latest-review extraction are deterministic pattern work. Doing them once in
# bash/jq is cheaper and more reliable than asking the model to redo them every
# invocation.
#
# Usage:
#   feedback-map.sh                      # auto-detect PR from current branch
#   feedback-map.sh <owner> <repo> <N>   # explicit
#   feedback-map.sh <PR-url>             # parse a github.com/.../pull/N URL
#   feedback-map.sh --no-cache <...>     # bypass /tmp cache
#
# Output: JSON to stdout. Cache: /tmp/pr-feedback-<owner>-<repo>-<N>.json (5min TTL)
#
# Exit codes:
#   0  success
#   2  gh or jq not available
#   3  gh not authenticated
#   4  no PR resolvable (silent skip — review proceeds without a map)
#   5  api call failed

set -uo pipefail

CACHE_TTL_MINUTES=5
NO_CACHE=0
# Same dir the pr-post-gate.sh PreToolUse hook watches (override is for tests).
CACHE_DIR="${CLAUDE_PR_GATE_CACHE_DIR:-/tmp}"

err() { printf '%s\n' "$*" >&2; }

# Failure-skip marker for the posting gate: created ONLY when a fetch was
# genuinely attempted and failed (gh/jq missing, unauthenticated, API error) —
# never on "no PR" (exit 4). The gate honors it for 60 min so a broken gh
# cannot deadlock posting; the gate's deny message deliberately never mentions
# it, so the model can't learn to bypass preemptively.
touch_skip() {
    if [ -n "${1:-}" ]; then touch "$CACHE_DIR/pr-feedback-skip-$1" 2>/dev/null || true
    else touch "$CACHE_DIR/pr-feedback-skip" 2>/dev/null || true; fi
}

if [ "${1:-}" = "--no-cache" ]; then NO_CACHE=1; shift; fi

command -v gh >/dev/null 2>&1 || { err "gh CLI not installed"; touch_skip; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq not installed"; touch_skip; exit 2; }
gh auth status >/dev/null 2>&1 || { err "gh not authenticated"; touch_skip; exit 3; }

owner=""; repo=""; number=""

if [ "$#" -eq 0 ]; then
    pr_json=$(gh pr view --json number,url 2>/dev/null) || pr_json=""
    if [ -z "$pr_json" ]; then err "no PR for current branch"; exit 4; fi
    number=$(printf '%s' "$pr_json" | jq -r '.number')
    url=$(printf '%s' "$pr_json" | jq -r '.url')
    owner=$(printf '%s' "$url" | awk -F/ '{print $4}')
    repo=$(printf '%s' "$url" | awk -F/ '{print $5}')
elif [ "$#" -eq 1 ]; then
    url=$1
    owner=$(printf '%s' "$url" | awk -F/ '{print $4}')
    repo=$(printf '%s' "$url" | awk -F/ '{print $5}')
    number=$(printf '%s' "$url" | awk -F/ '{print $7}')
elif [ "$#" -eq 3 ]; then
    owner=$1; repo=$2; number=$3
else
    err "usage: $0 [--no-cache] [<owner> <repo> <N> | <pr-url>]"; exit 4
fi

[ -n "$owner" ] && [ -n "$repo" ] && [ -n "$number" ] || { err "could not resolve owner/repo/number"; exit 4; }

cache="$CACHE_DIR/pr-feedback-${owner}-${repo}-${number}.json"
if [ "$NO_CACHE" -eq 0 ] && [ -f "$cache" ] && [ "$(find "$cache" -mmin -${CACHE_TTL_MINUTES} 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    cat "$cache"; exit 0
fi

# Fetch the 4 endpoints in parallel — PR metadata (for author), line comments,
# issue comments, reviews. `wait` blocks until all four finish.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(gh api "repos/${owner}/${repo}/pulls/${number}"            > "$tmp/pr.json"  2>"$tmp/pr.err") &
(gh api "repos/${owner}/${repo}/pulls/${number}/comments"   --paginate > "$tmp/lc.json" 2>"$tmp/lc.err") &
(gh api "repos/${owner}/${repo}/issues/${number}/comments"  --paginate > "$tmp/ic.json" 2>"$tmp/ic.err") &
(gh api "repos/${owner}/${repo}/pulls/${number}/reviews"    --paginate > "$tmp/rv.json" 2>"$tmp/rv.err") &
wait

for f in pr lc ic rv; do
    if [ -s "$tmp/${f}.err" ] && ! grep -q '^$' "$tmp/${f}.err"; then
        err "api fetch failed ($f): $(cat "$tmp/${f}.err")"; touch_skip "$number"; exit 5
    fi
done

pr_author=$(jq -r '.user.login // ""' < "$tmp/pr.json")
[ -n "$pr_author" ] || { err "could not extract PR author"; touch_skip "$number"; exit 5; }

# Normalize --paginate output (concatenated arrays) into single arrays.
lc_norm=$(jq -cs 'flatten' < "$tmp/lc.json")
ic_norm=$(jq -cs 'flatten' < "$tmp/ic.json")
rv_norm=$(jq -cs 'flatten' < "$tmp/rv.json")

# Build the enriched map. jq does:
#   - group line_comments by thread (root id = in_reply_to_id // .id)
#   - extract the latest PR-author reply per thread, run signal detection
#   - same for issue_comments (each is its own "thread")
#   - find most-recent review by submitted_at
#   - assemble final structure
output=$(jq -n \
    --arg owner "$owner" --arg repo "$repo" --argjson number "$number" --arg pr_author "$pr_author" \
    --argjson lc "$lc_norm" --argjson ic "$ic_norm" --argjson rv "$rv_norm" \
'
# Signal detection: given a body string, return one of
# fixed | intentional | deferred | disputed | unclear | open  + confidence.
#
# Priority: explicit-action verbs > commit-hash reference > "intentional" >
# "deferred" > "disputed" > short-ambiguous > open.
#
# Commit hashes (7-40 lowercase hex chars) are a strong "fixed" signal even
# when the author verb is something not enumerated above (e.g. "Reverted in
# <sha>" or "Moved that to <sha>"). The author is pointing at a specific commit.
def detect_signal:
  . as $body |
  (ascii_downcase) as $b |
  if ($b | test("\\b(fixed|done|addressed|resolved|implemented|refactored|rewrote|rewritten|moved|renamed|removed|extracted|updated|reverted)\\b|✅|🆗")) then
    {status: "fixed", confidence: "high"}
  elif ($b | test("\\b[0-9a-f]{7,40}\\b")) then
    {status: "fixed", confidence: "high", note: "commit-hash reference"}
  elif ($b | test("\\b(intentional|by design|deliberate|as intended|expected behavior)\\b")) then
    {status: "intentional", confidence: "high"}
  elif ($b | test("\\btodo\\b|follow.?up|out.of.scope|won.?t.?fix|wontfix|will (do|address|fix) (later|in (a )?follow)")) then
    {status: "deferred", confidence: "high"}
  elif ($b | test("\\b(disagree|push back|i don.?t think)\\b") or (endswith("?"))) then
    {status: "disputed", confidence: "low"}
  elif (length < 25) then
    {status: "unclear", confidence: "low", note: "short ambiguous reply"}
  else
    {status: "open", confidence: "low", note: "no clear signal in author reply"}
  end;

# Given an array of messages (each {author, body, is_pr_author, created_at}),
# return the resolution status for the thread.
def thread_status:
  . as $msgs |
  ([.[] | select(.is_pr_author)] | sort_by(.created_at) | last) as $latest_author |
  if $latest_author == null then
    {status: "open", confidence: "n/a", note: "PR author has not replied"}
  else
    ($latest_author.body | detect_signal) + {by: $latest_author.author, at: $latest_author.created_at, excerpt: ($latest_author.body[0:120])}
  end;

# Build threads from line_comments. GitHub threading is flat: each reply has
# in_reply_to_id pointing at the ROOT comment (not the immediately prior reply).
($lc | map(. + {is_pr_author: (.user.login == $pr_author)})) as $lc_norm |
($lc_norm | map(select(.in_reply_to_id == null))) as $roots |

($roots | map(
  . as $root |
  ($lc_norm | map(select(.in_reply_to_id == $root.id))) as $replies |
  ([$root] + ($replies | sort_by(.created_at))) as $msgs |
  ($msgs | map({author: .user.login, body, is_pr_author, created_at})) as $msg_list |
  {
    file: $root.path,
    line: ($root.line // $root.original_line),
    root_id: $root.id,
    root_author: $root.user.login,
    topic_hint: ($root.body[0:160]),
    html_url: $root.html_url,
    created_at: $root.created_at,
    messages: $msg_list,
    pr_author_replied: ($msg_list | any(.is_pr_author and .author != $root.user.login)),
    resolution: ($msg_list | thread_status)
  }
)) as $threads |

# Group by file
($threads | group_by(.file) |
  map({key: .[0].file, value: (. | sort_by(.line))}) | from_entries) as $threads_by_file |

# Issue comments: treat each as its own thread (no native threading)
($ic | map(. + {is_pr_author: (.user.login == $pr_author)})) as $ic_norm |
($ic_norm | map({
  id, author: .user.login, body, created_at, html_url,
  is_pr_author,
  excerpt: (.body[0:160])
})) as $general_threads |

# Reviews: latest by submitted_at + aggregate counts
($rv | sort_by(.submitted_at) | last) as $latest_review |
($rv | group_by(.state) | map({key: .[0].state, value: length}) | from_entries) as $state_counts |

# Summary
($threads | map(.resolution.status) | group_by(.) |
  map({key: .[0], value: length}) | from_entries) as $line_status_counts |

{
  pr: {
    owner: $owner, repo: $repo, number: $number, author: $pr_author,
    url: "https://github.com/\($owner)/\($repo)/pull/\($number)"
  },

  threads_by_file: $threads_by_file,

  general_threads: $general_threads,

  reviews: {
    most_recent: (if $latest_review == null then null else {
      state: $latest_review.state,
      author: $latest_review.user.login,
      submitted_at: $latest_review.submitted_at,
      body: ($latest_review.body // ""),
      html_url: $latest_review.html_url
    } end),
    state_counts: $state_counts,
    total: ($rv | length)
  },

  summary: {
    total_line_threads: ($threads | length),
    total_general_comments: ($ic | length),
    total_reviews: ($rv | length),
    files_with_feedback: ($threads_by_file | keys),
    line_thread_status_counts: $line_status_counts
  }
}
')

# Write cache atomically (same-dir mktemp + mv — parallel review subagents past
# the TTL must never leave a torn JSON for another reader) and emit the same
# form to both, so cache-hit output matches fresh-run output.
cache_tmp=$(mktemp "${cache}.XXXXXX") || { err "cannot write cache"; printf '%s\n' "$output"; exit 0; }
printf '%s\n' "$output" > "$cache_tmp"
mv -f "$cache_tmp" "$cache"
cat "$cache"
