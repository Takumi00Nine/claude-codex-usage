#!/bin/bash

# Render a tmux status segment from cache files only.

load_config() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
  CONFIG_FILE="$CONFIG_DIR/config.sh"
  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi
  USAGE_NARROW_BELOW="${USAGE_NARROW_BELOW:-100}"
  CELLS="${CELLS:-8}"
  STALE_MINUTES="${STALE_MINUTES:-10}"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

pcolor() {
  p="${1%.*}"
  is_number "$p" || { printf '%s' 'colour244'; return; }
  if [ "$p" -ge 80 ]; then
    printf '%s' 'colour197'
  elif [ "$p" -ge 50 ]; then
    printf '%s' 'colour214'
  else
    printf '%s' 'colour114'
  fi
}

meter() {
  label="$1"
  value="$2"
  p="${value%.*}"
  if ! is_number "$p"; then
    if [ "$SHOW_GAUGE" -eq 1 ]; then
      printf '#[fg=colour252]%s #[fg=colour238]' "$label"
      i=0
      while [ "$i" -lt "$CELLS" ]; do printf '░'; i=$(( i + 1 )); done
      printf ' #[fg=colour244]--'
    else
      printf '#[fg=colour252]%s #[fg=colour244]--' "$label"
    fi
    return
  fi
  [ "$p" -gt 100 ] && p=100
  [ "$p" -lt 0 ] && p=0
  color="$(pcolor "$p")"
  if [ "$SHOW_GAUGE" -eq 0 ]; then
    printf '#[fg=colour252]%s #[fg=%s]%s%%' "$label" "$color" "$p"
    return
  fi
  filled=$(( (p * CELLS + 50) / 100 ))
  [ "$filled" -gt "$CELLS" ] && filled="$CELLS"
  empty=$(( CELLS - filled ))
  printf '#[fg=colour252]%s #[fg=%s]' "$label" "$color"
  i=0
  while [ "$i" -lt "$filled" ]; do printf '█'; i=$(( i + 1 )); done
  printf '#[fg=colour238]'
  i=0
  while [ "$i" -lt "$empty" ]; do printf '░'; i=$(( i + 1 )); done
  printf ' #[fg=%s]%s%%' "$color" "$p"
}

reset_remaining() {
  epoch="$1"
  is_number "$epoch" || return 0
  rem=$(( epoch - NOW ))
  [ "$rem" -gt 0 ] || return 0
  if [ "$SHOW_GAUGE" -eq 0 ]; then
    printf '#[fg=colour244] ↻%dm' $(( rem / 60 ))
  else
    printf '#[fg=colour244] ↻%d:%02d:%02d' $(( rem / 3600 )) $(( (rem % 3600) / 60 )) $(( rem % 60 ))
  fi
}

age_suffix() {
  fetched="$1"
  is_number "$fetched" || return 0
  age=$(( NOW - fetched ))
  limit=$(( STALE_MINUTES * 60 ))
  if [ "$age" -gt "$limit" ]; then
    printf ' #[fg=colour244](%d分前)' $(( age / 60 ))
  fi
}

read_field() {
  file="$1"
  expr="$2"
  jq -r "$expr // empty" "$file" 2>/dev/null
}

service_segment() {
  service="$1"
  file="$2"
  label="$3"
  color="$4"
  if [ ! -f "$file" ]; then
    printf '#[fg=colour244]%s n/a' "$label"
    return
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf '#[fg=%s,bold]%s#[nobold] #[fg=colour197]ERR' "$color" "$label"
    return
  fi
  h="$(read_field "$file" '.five_hour.used_percent')"
  d="$(read_field "$file" '.seven_day.used_percent')"
  r="$(read_field "$file" '.five_hour.resets_at_epoch')"
  rd="$(read_field "$file" '.seven_day.resets_at_epoch')"
  fetched="$(read_field "$file" '.fetched_at')"
  err="$(read_field "$file" '.last_error.type')"
  printf '#[fg=%s,bold]%s#[nobold] ' "$color" "$label"
  meter "5h" "$h"
  reset_remaining "$r"
  printf '  '
  meter "7d" "$d"
  reset_remaining "$rd"
  [ -n "$err" ] && printf ' #[fg=colour197]ERR'
  age_suffix "$fetched"
}

main() {
  load_config
  NOW="$(date '+%s')"
  width="${1:-999}"
  is_number "$width" || width=999
  SHOW_GAUGE=1
  if [ "$width" -lt "$USAGE_NARROW_BELOW" ]; then
    SHOW_GAUGE=0
  fi
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' '#[fg=colour197]usage ERR'
    return 0
  }
  service_segment claude "$CLAUDE_CACHE" CL colour39
  printf ' #[fg=colour240]| #[default]'
  service_segment codex "$CODEX_CACHE" CX colour213
  printf '\n'
  return 0
}

main "$@"
