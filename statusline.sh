#!/bin/bash

# Claude Code statusLine: always return quickly and never surface errors.
set +e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REFRESH="$BASE_DIR/refresh.sh"
CODEX_CACHE="$BASE_DIR/codex-cache.json"
CLAUDE_CACHE="$BASE_DIR/claude-cache.json"
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

claude_5h="$(jq -r '.rate_limits.five_hour.used_percentage // .rate_limits.five_hour.utilization // empty' <<<"$INPUT" 2>/dev/null)"
claude_week="$(jq -r '.rate_limits.seven_day.used_percentage // .rate_limits.seven_day.utilization // empty' <<<"$INPUT" 2>/dev/null)"
claude_5h_reset="$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$INPUT" 2>/dev/null)"
claude_5h_kind=epoch

if ! valid_percent "$claude_5h" || ! valid_percent "$claude_week"; then
  if [ -r "$CLAUDE_CACHE" ] && [ "$(cache_age "$CLAUDE_CACHE")" -le "$CACHE_TTL" ] 2>/dev/null; then
    if ! valid_percent "$claude_5h"; then
      claude_5h="$(jq -r '.five_hour.utilization // empty' "$CLAUDE_CACHE" 2>/dev/null)"
      claude_5h_reset="$(jq -r '.five_hour.resets_at // empty' "$CLAUDE_CACHE" 2>/dev/null)"
      claude_5h_kind=iso
    fi
    if ! valid_percent "$claude_week"; then
      claude_week="$(jq -r '.seven_day.utilization // empty' "$CLAUDE_CACHE" 2>/dev/null)"
    fi
  else
    background_refresh claude
  fi
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
