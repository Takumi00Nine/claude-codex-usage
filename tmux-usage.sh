#!/usr/bin/env bash
# tmux status segment: Claude + Codex plan usage, read from the local caches
# written by refresh.sh (kept fresh by the launchd agent). Pure read — never
# hits the network, so it is cheap to call every few seconds from tmux.
#
# Renders a colored gauge per metric:
#   CL 5h ███░░░░░ 19%  7d ███░░░░░ 37% │ CX 5h ░░░░░░░░ 1%  7d ░░░░░░░░ 4%
#
# Usage in ~/.tmux.conf:
#   set -g status-right "#(/path/to/usage-statusline/tmux-usage.sh) ..."
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
now="$(date +%s)"
CELLS=8   # gauge width in characters

# Color by utilization: <50 green, 50-80 orange, >=80 red.
pcolor() {
  local p="${1%.*}"
  [[ -z "$p" ]] && { printf 'colour244'; return; }
  if   (( p >= 80 )); then printf 'colour197'
  elif (( p >= 50 )); then printf 'colour214'
  else                     printf 'colour114'
  fi
}

# meter LABEL PERCENT  ->  "LABEL ████░░░░ NN%" (filled colored by level, empty dim)
meter() {
  local label="$1" p="${2%.*}"
  if [[ -z "$p" ]]; then
    printf '#[fg=colour252]%s #[fg=colour238]░░░░░░░░ #[fg=colour244]--' "$label"
    return
  fi
  local filled=$(( (p * CELLS + 50) / 100 )) empty i f="" e=""
  (( filled > CELLS )) && filled=$CELLS
  (( filled < 0 ))     && filled=0
  empty=$(( CELLS - filled ))
  for (( i = 0; i < filled; i++ )); do f+="█"; done
  for (( i = 0; i < empty;  i++ )); do e+="░"; done
  printf '#[fg=colour252]%s #[fg=%s]%s#[fg=colour238]%s #[fg=%s]%s%%' \
    "$label" "$(pcolor "$p")" "$f" "$e" "$(pcolor "$p")" "$p"
}

# reset_remaining KIND VALUE  ->  "↻3h37m" (time until the 5h window resets, with minutes).
# KIND is "iso" (Claude, e.g. 2026-06-17T16:09:59+00:00) or "epoch" (Codex, unix seconds).
reset_remaining() {
  local kind="$1" val="$2" re=""
  case "$kind" in
    iso)
      [[ -n "$val" && "$val" != "null" ]] || return
      local norm
      norm="$(printf '%s' "$val" | sed -E 's/\.[0-9]+([+-][0-9]{2}:[0-9]{2}|Z)$/\1/; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/' 2>/dev/null)"
      re="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" '+%s' 2>/dev/null)"
      ;;
    epoch)
      [[ "$val" =~ ^[0-9]+$ ]] && re="$val"
      ;;
  esac
  [[ "$re" =~ ^[0-9]+$ ]] || return
  local rem=$(( re - now ))
  (( rem <= 0 )) && return
  if (( rem < 86400 )); then
    printf '#[fg=colour244] ↻%d:%02d:%02d' $(( rem / 3600 )) $(( (rem % 3600) / 60 )) $(( rem % 60 ))
  else
    printf '#[fg=colour244] ↻%dd %d:%02d:%02d' $(( rem / 86400 )) $(( (rem % 86400) / 3600 )) $(( (rem % 3600) / 60 )) $(( rem % 60 ))
  fi
}

# If the cache is older than 10 min, show its age so a frozen/stale value is obvious.
age_suffix() {
  local fa="${1:-0}"
  [[ "$fa" =~ ^[0-9]+$ ]] || return
  (( fa == 0 )) && return
  local age=$(( now - fa ))
  (( age > 600 )) && printf ' #[fg=colour244](%dm前)' $(( age / 60 ))
}

claude_seg() {
  local f="$DIR/claude-cache.json" h d fa rst
  [[ -f "$f" ]] || { printf '#[fg=colour244]CL n/a'; return; }
  h="$(jq -r '.five_hour.utilization  // empty' "$f" 2>/dev/null)"
  d="$(jq -r '.seven_day.utilization  // empty' "$f" 2>/dev/null)"
  rst="$(jq -r '.five_hour.resets_at  // empty' "$f" 2>/dev/null)"
  fa="$(jq -r '.fetched_at // 0'                "$f" 2>/dev/null)"
  printf '#[fg=colour39,bold]CL#[nobold] '
  meter "5h" "$h"; reset_remaining iso "$rst"; printf '  '; meter "7d" "$d"
  age_suffix "$fa"
}

codex_seg() {
  local f="$DIR/codex-cache.json" p s fa rst
  [[ -f "$f" ]] || { printf '#[fg=colour244]CX n/a'; return; }
  p="$(jq -r '.rateLimits.primary.usedPercent   // empty' "$f" 2>/dev/null)"
  s="$(jq -r '.rateLimits.secondary.usedPercent // empty' "$f" 2>/dev/null)"
  rst="$(jq -r '.rateLimits.primary.resetsAt    // empty' "$f" 2>/dev/null)"
  fa="$(jq -r '.fetched_at // 0'                       "$f" 2>/dev/null)"
  printf '#[fg=colour213,bold]CX#[nobold] '
  meter "5h" "$p"; reset_remaining epoch "$rst"; printf '  '; meter "7d" "$s"
  age_suffix "$fa"
}

claude_seg
printf ' #[fg=colour240]│ #[default]'
codex_seg
