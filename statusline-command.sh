#!/usr/bin/env bash
# Claude Code statusLine command — enhanced visibility
#
# Color palette (matches Powerlevel10k Pure / Ghostty):
#   grey=242    blue=81     magenta=213   yellow=228
#   cyan=123    green=114   red=203       orange=215
#   dim=238     white=255
#
# Layout (left segments conditional; the context bar is always shown as a
# constant visual anchor):
#   user@host  ~/dir  owner/repo  branch  [PR#]  [name]
#   model[:effort]  [bar] XX%  [5h:XX%]  [style]  [vim]
#
# All JSON paths below are from the documented statusLine schema
# (code.claude.com/docs/en/statusline → Available data). pr.*, vim.*, and
# rate_limits.* are genuinely present but conditional — absent on sessions
# with no open PR / vim off / usage-credit billing, which is why a quick
# glance at one session may not show them.

input=$(cat)

# ── Extract all fields up front ────────────────────────────────────────────
cwd=$(echo "$input"         | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input"       | jq -r '.model.display_name // empty')
model_id=$(echo "$input"    | jq -r '.model.id // empty')
used_pct=$(echo "$input"    | jq -r '.context_window.used_percentage // empty')
session_name=$(echo "$input"  | jq -r '.session_name // empty')
repo_owner=$(echo "$input"  | jq -r '.workspace.repo.owner // empty')
repo_name=$(echo "$input"   | jq -r '.workspace.repo.name // empty')
pr_num=$(echo "$input"      | jq -r '.pr.number // empty')
pr_state=$(echo "$input"    | jq -r '.pr.review_state // empty')
effort=$(echo "$input"      | jq -r '.effort.level // empty')
vim_mode=$(echo "$input"    | jq -r '.vim.mode // empty')
style=$(echo "$input"       | jq -r '.output_style.name // empty')
rate_5h=$(echo "$input"     | jq -r '.rate_limits.five_hour.used_percentage // empty')

# ── Path display: ~ for home; compact worktree + long-path forms ───────────
# Width on the left zone is precious — the right zone (context bar, 5h badge)
# gets truncated away first. Two compactions keep it short:
#   • Claude worktree  ~/…/marketing/.claude/worktrees/<wt>/videogen
#       → marketing⎇videogen   (plain fish-abbrev gives the unreadable ~/D/G/m/./w/s/…)
#   • any long path    ~/Development/GitHubProjects/foo → ~/D/G/foo
short_cwd="${cwd/#$HOME/~}"
if [[ "$short_cwd" == */.claude/worktrees/* ]]; then
  wt_repo=$(basename "${short_cwd%%/.claude/worktrees/*}")
  wt_rest="${short_cwd#*/.claude/worktrees/}"        # <wt>[/<tail>]
  if [ "$wt_rest" = "${wt_rest%/*}" ]; then
    short_cwd="${wt_repo}⎇${wt_rest}"                # at worktree root → show wt name
  else
    short_cwd="${wt_repo}⎇${wt_rest#*/}"             # in a subdir → show the tail
  fi
elif [ "${#short_cwd}" -gt 32 ]; then
  cwd_base=$(basename "$short_cwd")
  cwd_dirs=$(dirname "$short_cwd")
  short_cwd="$(echo "$cwd_dirs" | awk -F/ '{for(i=1;i<=NF;i++) printf "%s/", substr($i,1,1)}')${cwd_base}"
fi

# ── Git branch (--no-optional-locks avoids stale-lock false positives) ─────
git_branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# ── Context fill-bar (8 chars, Unicode block elements) ─────────────────────
# Always rendered (0% when the field is absent, e.g. fresh session) so the
# bar serves as a constant visual anchor — its absence reads as "old style".
[ -z "$used_pct" ] && used_pct=0
ctx_bar=""
if [ -n "$used_pct" ]; then
  filled=$(printf '%.0f' "$(echo "$used_pct * 8 / 100" | bc -l 2>/dev/null || echo 0)")
  [ "$filled" -gt 8 ] 2>/dev/null && filled=8
  [ "$filled" -lt 0 ] 2>/dev/null && filled=0
  # counting loops, not seq: BSD `seq 1 0` counts DOWN (two iterations), which
  # corrupted the bar at 0% and 100%
  bar=""
  i=0
  while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i+1)); done
  while [ "$i" -lt 8 ];         do bar="${bar}░"; i=$((i+1)); done
  ctx_bar="$bar"
fi

# ── Model label: prefer display_name, fall back to the raw id ───────────────
model_short="$model"
if [ -z "$model_short" ] && [ -n "$model_id" ]; then
  model_short="$model_id"
fi
# compact the verbose 1M-context suffix: "Opus 4.8 (1M context)" → "Opus 4.8·1M"
model_short="${model_short/ (1M context)/·1M}"

# ── Effort badge ───────────────────────────────────────────────────────────
effort_badge=""
if [ -n "$effort" ] && [ "$effort" != "medium" ]; then
  case "$effort" in
    low)    effort_badge=":low" ;;
    high)   effort_badge=":high" ;;
    xhigh)  effort_badge=":xhigh" ;;
    max)    effort_badge=":max" ;;
  esac
fi

# ── PR review state badge ──────────────────────────────────────────────────
pr_badge=""
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)           pr_badge="PR#${pr_num} approved" ;;
    changes_requested)  pr_badge="PR#${pr_num} needs-changes" ;;
    draft)              pr_badge="PR#${pr_num} draft" ;;
    *)                  pr_badge="PR#${pr_num}" ;;
  esac
fi

# ── Context color: green <50, yellow 50-79, orange 80-89, red 90+ ──────────
ctx_color=114  # green
if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  if   [ "$pct_int" -ge 90 ]; then ctx_color=203  # red
  elif [ "$pct_int" -ge 80 ]; then ctx_color=215  # orange
  elif [ "$pct_int" -ge 50 ]; then ctx_color=228  # yellow
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# OUTPUT — two logical zones separated by double-space
# ═══════════════════════════════════════════════════════════════════════════

# Zone 1: Location ──────────────────────────────────────────────────────────

# user@host — dim grey
printf "\033[38;5;242m%s@%s\033[0m" "$(whoami)" "$(hostname -s)"

# cwd — blue
printf "  \033[38;5;81m%s\033[0m" "$short_cwd"

# repo owner/name — dim grey; skipped when the dir name already says it
# (basename == repo name makes the segment pure noise — width is precious)
if [ -n "$repo_owner" ] && [ -n "$repo_name" ] && [ "$repo_name" != "$(basename "$cwd")" ]; then
  printf "  \033[38;5;238m%s/%s\033[0m" "$repo_owner" "$repo_name"
fi

# git branch — magenta. (No worktree suffix: the path segment already carries
# worktree context, and the branch name itself usually contains the wt name.)
if [ -n "$git_branch" ]; then
  printf "  \033[38;5;213m%s\033[0m" "$git_branch"
fi

# PR badge — yellow (approved=green, needs-changes=red)
if [ -n "$pr_badge" ]; then
  pr_color=228
  [ "$pr_state" = "approved" ]           && pr_color=114
  [ "$pr_state" = "changes_requested" ]  && pr_color=203
  printf "  \033[38;5;%dm%s\033[0m" "$pr_color" "$pr_badge"
fi

# session name (only when renamed) — dim, capped so it can't eat the line
if [ -n "$session_name" ]; then
  [ "${#session_name}" -gt 16 ] && session_name="${session_name:0:15}…"
  printf "  \033[38;5;238m[%s]\033[0m" "$session_name"
fi

# Zone 2: Model / Context ───────────────────────────────────────────────────

# model + effort — cyan
if [ -n "$model_short" ]; then
  printf "  \033[38;5;123m%s%s\033[0m" "$model_short" "$effort_badge"
fi

# context bar + percentage — color-coded
if [ -n "$ctx_bar" ] && [ -n "$used_pct" ]; then
  printf "  \033[38;5;%dm%s %s%%\033[0m" \
    "$ctx_color" "$ctx_bar" "$(printf '%.0f' "$used_pct")"
fi

# 5-hour rate limit (only when used) — orange when present
if [ -n "$rate_5h" ]; then
  rate_int=$(printf '%.0f' "$rate_5h")
  rate_color=215
  [ "$rate_int" -ge 80 ] && rate_color=203
  printf "  \033[38;5;%dm5h:%d%%\033[0m" "$rate_color" "$rate_int"
fi

# output style (only when non-default) — dim
if [ -n "$style" ] && [ "$style" != "default" ]; then
  printf "  \033[38;5;238m[%s]\033[0m" "$style"
fi

# vim mode — bright when active
if [ -n "$vim_mode" ]; then
  vim_color=228
  [ "$vim_mode" = "NORMAL" ]      && vim_color=114
  [ "$vim_mode" = "VISUAL" ]      && vim_color=215
  [ "$vim_mode" = "VISUAL LINE" ] && vim_color=215
  printf "  \033[38;5;%dm%s\033[0m" "$vim_color" "$vim_mode"
fi

printf "\n"
