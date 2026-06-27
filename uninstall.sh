#!/bin/bash

LABEL="com.claude-codex-usage.refresh"

load_config() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
  LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
  PLIST_PATH="$LAUNCHAGENT_DIR/$LABEL.plist"
  CONFIG_FILE="$CONFIG_DIR/config.sh"
  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi
}

main() {
  purge=0
  case "${1:-}" in
    "") ;;
    --purge-cache) purge=1 ;;
    *) printf '%s\n' 'usage: uninstall.sh [--purge-cache]' >&2; return 2 ;;
  esac
  load_config
  uid="$(id -u)"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1
  fi
  if [ -e "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH" 2>/dev/null || return 1
    printf 'removed %s\n' "$PLIST_PATH"
  else
    printf 'plist not found: %s\n' "$PLIST_PATH"
  fi
  if [ "$purge" -eq 1 ]; then
    rm -rf "$CACHE_DIR" 2>/dev/null || return 1
    printf 'removed %s\n' "$CACHE_DIR"
  fi
  return 0
}

main "$@"
