#!/bin/bash

# Refresh slow or rate-limited usage APIs and replace caches atomically.
set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CODEX_CACHE="$BASE_DIR/codex-cache.json"
CLAUDE_CACHE="$BASE_DIR/claude-cache.json"
MODE="${1:-all}"

mkdir -p "$BASE_DIR" 2>/dev/null || exit 0

run_locked() {
  name="$1"
  shift

  if command -v flock >/dev/null 2>&1; then
    (
      flock -n 9 || exit 0
      "$@"
    ) 9>"/tmp/${name}-usage.lock"
    return
  fi

  # macOS does not ship flock; mkdir is an atomic, dependency-free fallback.
  lock_dir="/tmp/${name}-usage.lock.d"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null)"
    case "$lock_pid" in
      ''|*[!0-9]*)
        rm -rf "$lock_dir" 2>/dev/null
        ;;
      *)
        kill -0 "$lock_pid" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null
        ;;
    esac
    mkdir "$lock_dir" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" >"$lock_dir/pid" 2>/dev/null || true
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM
  "$@"
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
  trap - EXIT HUP INT TERM
}

write_cache() {
  cache_path="$1"
  payload="$2"
  tmp="${cache_path}.tmp.$$"

  printf '%s\n' "$payload" >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$cache_path" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
}

refresh_codex() {
  raw="$(
    {
      printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"sl","version":"1.0"}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
      sleep 6
    } | codex app-server 2>/dev/null | jq -c 'select(.id==2).result.rateLimits' 2>/dev/null | tail -n 1
  )"

  [ -n "$raw" ] || return 1
  jq -e 'type == "object" and (.primary.usedPercent? != null or .secondary.usedPercent? != null)' \
    >/dev/null 2>&1 <<<"$raw" || return 1

  payload="$(jq -c --argjson fetched_at "$(date +%s)" \
    '{fetched_at: $fetched_at, rateLimits: .}' <<<"$raw" 2>/dev/null)" || return 1
  write_cache "$CODEX_CACHE" "$payload"
}

refresh_claude() {
  tok="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
    jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$tok" ]; then
    tok="$(jq -r '.claudeAiOauth.accessToken // empty' \
      "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  [ -n "$tok" ] || return 1

  raw="$(curl -s --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)"

  [ -n "$raw" ] || return 1
  jq -e 'type == "object" and (.five_hour.utilization? != null or .seven_day.utilization? != null)' \
    >/dev/null 2>&1 <<<"$raw" || return 1

  payload="$(jq -c --argjson fetched_at "$(date +%s)" \
    '{fetched_at: $fetched_at, five_hour: .five_hour, seven_day: .seven_day}' \
    <<<"$raw" 2>/dev/null)" || return 1
  write_cache "$CLAUDE_CACHE" "$payload"
}

case "$MODE" in
  codex)
    run_locked codex refresh_codex
    ;;
  claude)
    run_locked claude refresh_claude
    ;;
  all)
    run_locked codex refresh_codex
    run_locked claude refresh_claude
    ;;
esac

exit 0
