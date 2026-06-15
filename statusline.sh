#!/bin/bash

# Claude Code statusLine: always return quickly and never surface errors.
set +e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REFRESH="$BASE_DIR/refresh.sh"
CODEX_CACHE="$BASE_DIR/codex-cache.json"
CLAUDE_CACHE="$BASE_DIR/claude-cache.json"
CLAUDE_SIG="$BASE_DIR/claude-input.sig"
CACHE_TTL=300
NOW="$(date +%s 2>/dev/null)"
INPUT="$(cat 2>/dev/null)"

[ -n "$NOW" ] || NOW=0

valid_percent() {
  case "$1" in
    ''|null|*[!0-9.]*|*.*.*) return 1 ;;
    *) return 0 ;;
  esac
}

percent_text() {
  value="$1"
  if ! valid_percent "$value"; then
    printf '%s' '--'
    return
  fi
  awk -v value="$value" 'BEGIN { printf "%.0f", value }' 2>/dev/null || printf '%s' '--'
}

color_usage() {
  raw="$1"
  text="$2"
  value="$(percent_text "$raw")"
  if [ "$value" = "--" ]; then
    printf '%s' "$text"
  elif [ "$value" -le 50 ] 2>/dev/null; then
    printf '\033[32m%s\033[0m' "$text"
  elif [ "$value" -le 80 ] 2>/dev/null; then
    printf '\033[33m%s\033[0m' "$text"
  else
    printf '\033[31m%s\033[0m' "$text"
  fi
}

usage_bar() {
  raw="$1"
  if ! valid_percent "$raw"; then
    bar='░░░░░░░░░░'
  else
    filled="$(awk -v value="$raw" 'BEGIN {
      cells = int((value + 5) / 10)
      if (cells < 0) cells = 0
      if (cells > 10) cells = 10
      print cells
    }' 2>/dev/null)"
    case "$filled" in ''|*[!0-9]*) filled=0 ;; esac
    bar=""
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
  fi
  printf '%s' "$bar"
}

iso_epoch() {
  iso="$1"
  [ -n "$iso" ] && [ "$iso" != "null" ] || return 1
  normalized="$(printf '%s' "$iso" |
    sed -E 's/\.[0-9]+([+-][0-9]{2}:[0-9]{2}|Z)$/\1/; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/' 2>/dev/null)"
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null
}

reset_text() {
  kind="$1"
  reset="$2"
  case "$kind" in
    iso) reset_epoch="$(iso_epoch "$reset")" ;;
    epoch)
      case "$reset" in ''|null|*[!0-9]*) return 0 ;; esac
      reset_epoch="$reset"
      ;;
    *) return 0 ;;
  esac
  case "$reset_epoch" in ''|*[!0-9]*) return 0 ;; esac
  remaining=$((reset_epoch - NOW))
  [ "$remaining" -gt 0 ] 2>/dev/null || return 0
  if [ "$remaining" -lt 3600 ]; then
    printf '↻%sm' "$((remaining / 60))"
  elif [ "$remaining" -lt 86400 ]; then
    printf '↻%sh%sm' "$((remaining / 3600))" "$(((remaining % 3600) / 60))"
  else
    printf '↻%sd' "$((remaining / 86400))"
  fi
}

five_hour_usage() {
  raw="$1"
  kind="$2"
  reset="$3"
  value="$(percent_text "$raw")"
  if [ "$value" = "--" ]; then
    percent='--'
  else
    percent="${value}%"
  fi
  usage="$(printf '▏%s %s' "$(usage_bar "$raw")" "$percent")"
  remaining="$(reset_text "$kind" "$reset")"
  printf '%s' "$(color_usage "$raw" "$usage")"
  [ -n "$remaining" ] && printf ' %s' "$remaining"
}

weekly_usage() {
  raw="$1"
  value="$(percent_text "$raw")"
  if [ "$value" = "--" ]; then
    percent='--'
  else
    percent="${value}%"
  fi
  color_usage "$raw" "$percent"
}

cache_age() {
  file="$1"
  fetched="$(jq -r '.fetched_at // 0' "$file" 2>/dev/null)"
  case "$fetched" in ''|*[!0-9]*) fetched=0 ;; esac
  printf '%s' "$((NOW - fetched))"
}

background_refresh() {
  mode="$1"
  [ -x "$REFRESH" ] || return 0
  nohup "$REFRESH" "$mode" >/dev/null 2>&1 </dev/null &
}

model="$(jq -r '.model.display_name // "Claude"' <<<"$INPUT" 2>/dev/null)"
[ -n "$model" ] && [ "$model" != "null" ] || model="Claude"

# Usage values Claude Code hands us on stdin; these are only refreshed by the
# harness after a prompt is sent, so they are the freshest source right then.
input_5h="$(jq -r '.rate_limits.five_hour.used_percentage // .rate_limits.five_hour.utilization // empty' <<<"$INPUT" 2>/dev/null)"
input_week="$(jq -r '.rate_limits.seven_day.used_percentage // .rate_limits.seven_day.utilization // empty' <<<"$INPUT" 2>/dev/null)"
input_5h_reset="$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$INPUT" 2>/dev/null)"

# A new prompt is the only thing that changes the stdin payload; detect that by
# comparing against the last signature so we can update immediately on a prompt.
input_fresh=0
if valid_percent "$input_5h" && valid_percent "$input_week"; then
  sig="${input_5h}|${input_week}|${input_5h_reset}"
  if [ "$sig" != "$(cat "$CLAUDE_SIG" 2>/dev/null)" ]; then
    input_fresh=1
    printf '%s' "$sig" >"$CLAUDE_SIG.tmp.$$" 2>/dev/null &&
      mv -f "$CLAUDE_SIG.tmp.$$" "$CLAUDE_SIG" 2>/dev/null
    background_refresh claude
  fi
fi

# Refresh the cache on a five-minute cadence so the value advances while idle,
# mirroring how the Codex side stays current without a prompt.
if [ ! -r "$CLAUDE_CACHE" ] || [ "$(cache_age "$CLAUDE_CACHE")" -gt "$CACHE_TTL" ] 2>/dev/null; then
  background_refresh claude
fi

if [ "$input_fresh" = 1 ]; then
  # Just sent a prompt: show the value Claude Code handed us right away.
  claude_5h="$input_5h"
  claude_week="$input_week"
  claude_5h_reset="$input_5h_reset"
  claude_5h_kind=epoch
else
  # Idle: read the background-refreshed cache so the percentage keeps updating.
  claude_5h="$(jq -r '.five_hour.utilization // empty' "$CLAUDE_CACHE" 2>/dev/null)"
  claude_week="$(jq -r '.seven_day.utilization // empty' "$CLAUDE_CACHE" 2>/dev/null)"
  claude_5h_reset="$(jq -r '.five_hour.resets_at // empty' "$CLAUDE_CACHE" 2>/dev/null)"
  claude_5h_kind=iso
  # Fall back to the stdin values until the cache is populated.
  if ! valid_percent "$claude_5h"; then
    claude_5h="$input_5h"
    claude_5h_reset="$input_5h_reset"
    claude_5h_kind=epoch
  fi
  valid_percent "$claude_week" || claude_week="$input_week"
fi

codex_5h=""
codex_week=""
codex_5h_reset=""
if [ -r "$CODEX_CACHE" ]; then
  codex_5h="$(jq -r '.rateLimits.primary.usedPercent // empty' "$CODEX_CACHE" 2>/dev/null)"
  codex_week="$(jq -r '.rateLimits.secondary.usedPercent // empty' "$CODEX_CACHE" 2>/dev/null)"
  codex_5h_reset="$(jq -r '.rateLimits.primary.resetsAt // empty' "$CODEX_CACHE" 2>/dev/null)"
  [ "$(cache_age "$CODEX_CACHE")" -le "$CACHE_TTL" ] 2>/dev/null || background_refresh codex
else
  background_refresh codex
fi

printf '🤖 %s │ ✳️ Claude %s (週 %s) │ ⬢ Codex %s (週 %s)' \
  "$model" \
  "$(five_hour_usage "$claude_5h" "$claude_5h_kind" "$claude_5h_reset")" \
  "$(weekly_usage "$claude_week")" \
  "$(five_hour_usage "$codex_5h" epoch "$codex_5h_reset")" \
  "$(weekly_usage "$codex_week")"

exit 0
