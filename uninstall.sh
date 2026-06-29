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

normalize_path_no_trailing_slash() {
  local path
  path="$1"
  while [ "$path" != "/" ]; do
    case "$path" in
      */) path="${path%/}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$path"
}

validate_purge_cache_dir() {
  local target home rest
  target="$(normalize_path_no_trailing_slash "$CACHE_DIR")"
  home="$(normalize_path_no_trailing_slash "$HOME")"
  case "$target" in
    ""|"/")
      printf 'refusing to purge unsafe cache dir: %s\n' "${target:-<empty>}" >&2
      return 1
      ;;
  esac
  if [ "$target" = "$home" ]; then
    printf 'refusing to purge unsafe cache dir: %s\n' "$target" >&2
    return 1
  fi
  case "$target" in
    "$home"/*)
      rest="${target#$home/}"
      case "$rest" in
        */*) ;;
        *)
          printf 'refusing to purge shallow HOME path: %s\n' "$target" >&2
          return 1
          ;;
      esac
      ;;
  esac
  case "$target" in
    */claude-codex-usage) ;;
    *)
      printf 'refusing to purge unexpected cache dir: %s\n' "$target" >&2
      return 1
      ;;
  esac
  CACHE_DIR="$target"
  return 0
}

main() {
  local purge uid
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
    validate_purge_cache_dir || return 2
    printf 'purging cache dir: %s\n' "$CACHE_DIR"
    rm -rf "$CACHE_DIR" 2>/dev/null || return 1
    printf 'removed %s\n' "$CACHE_DIR"
  fi
  return 0
}

if [ "${CLAUDE_CODEX_USAGE_TEST_LIB:-}" = "1" ]; then
  load_config
else
  main "$@"
  exit $?
fi
