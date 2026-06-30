#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LABEL="com.claude-codex-usage.refresh"

load_config() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
  LOG_DIR="$HOME/Library/Logs/claude-codex-usage"
  LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
  PLIST_PATH="$LAUNCHAGENT_DIR/$LABEL.plist"
  CONFIG_FILE="$CONFIG_DIR/config.sh"
  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi
  REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-15}"
  RETRY_COUNT="${RETRY_COUNT:-2}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-80}"
  NOTIFY_THRESHOLD="${NOTIFY_THRESHOLD:-20}"
  NOTIFY_FLOOR="${NOTIFY_FLOOR:-5}"
  NOTIFY_SOUND="${NOTIFY_SOUND:-Ping}"
  RESET_HOOK="${RESET_HOOK:-}"
  HOOK_TIMEOUT="${HOOK_TIMEOUT:-60}"
  USAGE_NARROW_BELOW="${USAGE_NARROW_BELOW:-100}"
  CELLS="${CELLS:-8}"
  STALE_MINUTES="${STALE_MINUTES:-10}"
  validate_config_numbers
}

xml_escape() {
  local value
  value="$1"
  printf '%s' "$value" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

config_log() {
  printf '%s\n' "$*" >&2
}

is_unsigned_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

config_fallback() {
  local name default reason
  name="$1"
  default="$2"
  reason="$3"
  config_log "config: $name invalid ($reason); using default $default"
  eval "$name=\$default"
}

normalize_int_config() {
  local name default min max value
  name="$1"
  default="$2"
  min="$3"
  max="$4"
  eval "value=\"\${$name}\""
  is_unsigned_int "$value" || { config_fallback "$name" "$default" "not an integer"; return; }
  [ "$value" -ge "$min" ] || { config_fallback "$name" "$default" "below $min"; return; }
  if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
    config_fallback "$name" "$default" "above $max"
  fi
}

validate_config_numbers() {
  normalize_int_config REFRESH_INTERVAL 60 1 ""
  normalize_int_config REQUEST_TIMEOUT 15 1 ""
  normalize_int_config RETRY_COUNT 2 0 ""
  normalize_int_config WARN_THRESHOLD 80 0 100
  normalize_int_config NOTIFY_THRESHOLD 20 0 100
  normalize_int_config NOTIFY_FLOOR 5 0 100
  normalize_int_config HOOK_TIMEOUT 60 1 ""
  normalize_int_config USAGE_NARROW_BELOW 100 1 ""
  normalize_int_config CELLS 8 1 ""
  normalize_int_config STALE_MINUTES 10 1 ""
}

path_dir() {
  local command_path
  command_path="$1"
  dirname "$command_path"
}

append_unique_path() {
  local item current
  item="$1"
  current="$2"
  case ":$current:" in
    *":$item:"*) printf '%s' "$current" ;;
    *) if [ -n "$current" ]; then printf '%s:%s' "$current" "$item"; else printf '%s' "$item"; fi ;;
  esac
}

build_path() {
  local result cmd found dir
  result=""
  for cmd in jq curl codex osascript launchctl; do
    found="$(command -v "$cmd" 2>/dev/null)"
    [ -n "$found" ] && result="$(append_unique_path "$(path_dir "$found")" "$result")"
  done
  for dir in /usr/bin /bin /usr/sbin /sbin /opt/homebrew/bin /usr/local/bin; do
    result="$(append_unique_path "$dir" "$result")"
  done
  printf '%s' "$result"
}

validate_interval() {
  case "$REFRESH_INTERVAL" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$REFRESH_INTERVAL" -ge 60 ] || return 1
  [ $(( REFRESH_INTERVAL % 60 )) -eq 0 ] || return 1
  [ "$REFRESH_INTERVAL" -le 3600 ] || return 1
  return 0
}

calendar_entries() {
  local interval step minute
  interval="$1"
  step=$(( interval / 60 ))
  minute=0
  while [ "$minute" -lt 60 ]; do
    printf '    <dict><key>Minute</key><integer>%s</integer></dict>\n' "$minute"
    minute=$(( minute + step ))
  done
}

generate_plist() {
  local refresh_path env_path log_path
  refresh_path="$(xml_escape "$SCRIPT_DIR/refresh.sh")"
  env_path="$(xml_escape "$1")"
  log_path="$(xml_escape "$LOG_DIR/refresh.log")"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>Label</key>'
    printf '  <string>%s</string>\n' "$LABEL"
    printf '%s\n' '  <key>ProgramArguments</key>'
    printf '%s\n' '  <array>'
    printf '    <string>%s</string>\n' "$refresh_path"
    printf '%s\n' '    <string>all</string>'
    printf '%s\n' '  </array>'
    printf '%s\n' '  <key>EnvironmentVariables</key>'
    printf '%s\n' '  <dict>'
    printf '%s\n' '    <key>PATH</key>'
    printf '    <string>%s</string>\n' "$env_path"
    printf '%s\n' '  </dict>'
    printf '%s\n' '  <key>RunAtLoad</key>'
    printf '%s\n' '  <true/>'
    printf '%s\n' '  <key>StartCalendarInterval</key>'
    printf '%s\n' '  <array>'
    calendar_entries "$REFRESH_INTERVAL"
    printf '%s\n' '  </array>'
    printf '%s\n' '  <key>StandardOutPath</key>'
    printf '  <string>%s</string>\n' "$log_path"
    printf '%s\n' '  <key>StandardErrorPath</key>'
    printf '  <string>%s</string>\n' "$log_path"
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  }
}

write_plist() {
  local env_path tmp
  env_path="$1"
  tmp="$PLIST_PATH.tmp.$$"
  generate_plist "$env_path" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$PLIST_PATH" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

check_required() {
  local missing cmd
  missing=""
  for cmd in jq curl codex osascript; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ "${CLAUDE_CODEX_USAGE_SKIP_LAUNCHCTL:-}" != "1" ]; then
    command -v launchctl >/dev/null 2>&1 || missing="$missing launchctl"
  fi
  if [ -n "$missing" ]; then
    printf 'missing required command(s):%s\n' "$missing" >&2
    return 1
  fi
  return 0
}

main() {
  local env_path uid
  load_config
  check_required || return 3
  validate_interval || {
    printf '%s\n' 'REFRESH_INTERVAL must be 60 or a multiple of 60 seconds' >&2
    return 2
  }
  mkdir -p "$CONFIG_DIR" "$CACHE_DIR" "$CACHE_DIR/locks" "$CACHE_DIR/tmp" "$LOG_DIR" "$LAUNCHAGENT_DIR" 2>/dev/null || return 1
  if [ ! -f "$CONFIG_FILE" ]; then
    cp "$SCRIPT_DIR/config.example.sh" "$CONFIG_FILE" 2>/dev/null || return 1
    printf 'created %s\n' "$CONFIG_FILE"
  fi
  env_path="$(build_path)"
  write_plist "$env_path" || return 1
  chmod +x "$SCRIPT_DIR/refresh.sh" "$SCRIPT_DIR/tmux-usage.sh" 2>/dev/null
  uid="$(id -u)"
  if [ "${CLAUDE_CODEX_USAGE_SKIP_LAUNCHCTL:-}" != "1" ]; then
    launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$uid" "$PLIST_PATH" >/dev/null 2>&1 || return 4
    launchctl enable "gui/$uid/$LABEL" >/dev/null 2>&1 || return 4
    launchctl kickstart -k "gui/$uid/$LABEL" >/dev/null 2>&1 || return 4
  fi
  printf 'installed %s\n' "$PLIST_PATH"
  return 0
}

if [ "${CLAUDE_CODEX_USAGE_TEST_LIB:-}" = "1" ]; then
  load_config
else
  main "$@"
  exit $?
fi
