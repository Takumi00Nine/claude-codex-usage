#!/bin/bash

# Fetch Claude/Codex usage, update cache files atomically, and send notifications.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

load_config() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
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
  SLEEP_STALE_MINUTES="${SLEEP_STALE_MINUTES:-5}"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
}

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$$" "$*"
}

# Global state for codex server cleanup (set by fetch_codex_once, read by trap handler)
_codex_server_pid=""
_codex_writer_pid=""
_codex_tmp_dir=""

cleanup_codex_server() {
  [ -n "$_codex_writer_pid" ] && kill "$_codex_writer_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && kill "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && wait "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_tmp_dir" ]    && rm -rf "$_codex_tmp_dir" 2>/dev/null
}

now_epoch() {
  date -u '+%s'
}

iso_to_epoch() {
  value="$1"
  [ -n "$value" ] && [ "$value" != "null" ] || return 1
  normalized="$(printf '%s' "$value" | sed -E 's/\.[0-9]+([+-][0-9]{2}:[0-9]{2}|Z)$/\1/; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/' 2>/dev/null)"
  date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null
}

json_string() {
  printf '%s' "$1" | jq -Rs .
}

atomic_write() {
  local path content dir tmp
  path="$1"
  content="$2"
  dir="$(dirname "$path")"
  tmp="$dir/.tmp.$(basename "$path").$$"
  printf '%s\n' "$content" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$path" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

run_with_timeout() {
  local seconds flag child watcher status
  seconds="$1"
  shift
  flag="${TMPDIR:-/tmp}/claude-codex-timeout.$$.$RANDOM"
  "$@" &
  child=$!
  (
    sleep "$seconds"
    if kill -0 "$child" 2>/dev/null; then
      : >"$flag"
      kill "$child" 2>/dev/null
      sleep 1
      kill -0 "$child" 2>/dev/null && kill -9 "$child" 2>/dev/null
    fi
  ) &
  watcher=$!
  wait "$child"
  status=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then
    rm -f "$flag" 2>/dev/null
    return 124
  fi
  rm -f "$flag" 2>/dev/null
  return "$status"
}

is_transient_fetch_status() {
  case "$1" in
    42|124|5|6|7|28|52|55|56) return 0 ;;
    *) return 1 ;;
  esac
}

lock_max_age() {
  printf '%s\n' $(( REQUEST_TIMEOUT * (RETRY_COUNT + 1) + HOOK_TIMEOUT + 30 ))
}

with_lock() {
  name="$1"
  shift
  mkdir -p "$LOCK_DIR" "$TMP_DIR" 2>/dev/null || return 1
  lock="$LOCK_DIR/$name.lock.d"
  if ! mkdir "$lock" 2>/dev/null; then
    created="$(cat "$lock/created_at" 2>/dev/null)"
    now="$(now_epoch)"
    max_age="$(lock_max_age)"
    case "$created" in
      ''|*[!0-9]*) rm -rf "$lock" 2>/dev/null ;;
      *) [ $(( now - created )) -gt "$max_age" ] && rm -rf "$lock" 2>/dev/null ;;
    esac
    mkdir "$lock" 2>/dev/null || { log "$name: lock held, skipping"; return 0; }
  fi
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null
  now_epoch >"$lock/created_at" 2>/dev/null
  "$@"
  status=$?
  rm -rf "$lock" 2>/dev/null
  return "$status"
}

empty_error_cache() {
  service="$1"
  now="$2"
  type="$3"
  message="$4"
  status="${5:-null}"
  attempts="$6"
  jq -cn \
    --arg service "$service" \
    --arg type "$type" \
    --arg message "$message" \
    --argjson now "$now" \
    --argjson status "$status" \
    --argjson attempts "$attempts" \
    '{schema_version:1, service:$service, updated_at:$now, last_error:{at:$now,type:$type,message:$message,status:$status,attempts:$attempts}}'
}

write_failure_cache() {
  local service cache type message status attempts now msg_json out
  service="$1"
  cache="$2"
  type="$3"
  message="$4"
  status="${5:-null}"
  attempts="$6"
  now="$(now_epoch)"
  msg_json="$(json_string "$message")"
  if [ -f "$cache" ] && jq -e . "$cache" >/dev/null 2>&1; then
    out="$(jq -c \
      --arg service "$service" \
      --arg type "$type" \
      --argjson message "$msg_json" \
      --argjson now "$now" \
      --argjson status "$status" \
      --argjson attempts "$attempts" \
      '.schema_version=1
       | .service=$service
       | .updated_at=$now
       | .last_error={at:$now,type:$type,message:$message,status:$status,attempts:$attempts}' \
      "$cache" 2>/dev/null)" || return 1
  else
    out="$(empty_error_cache "$service" "$now" "$type" "$message" "$status" "$attempts")" || return 1
  fi
  atomic_write "$cache" "$out"
}

transform_claude_usage() {
  raw="$1"
  now="$2"
  fh_reset="$(printf '%s' "$raw" | jq -r '.five_hour.resets_at // .five_hour.resetsAt // empty' 2>/dev/null)"
  sd_reset="$(printf '%s' "$raw" | jq -r '.seven_day.resets_at // .seven_day.resetsAt // empty' 2>/dev/null)"
  fh_epoch="null"
  sd_epoch="null"
  if [ -n "$fh_reset" ]; then
    value="$(iso_to_epoch "$fh_reset")" && fh_epoch="$value"
  fi
  if [ -n "$sd_reset" ]; then
    value="$(iso_to_epoch "$sd_reset")" && sd_epoch="$value"
  fi
  printf '%s' "$raw" | jq -c \
    --argjson now "$now" \
    --argjson fh_epoch "$fh_epoch" \
    --argjson sd_epoch "$sd_epoch" \
    '{
      schema_version: 1,
      service: "claude",
      fetched_at: $now,
      updated_at: $now,
      five_hour: {
        used_percent: (.five_hour.used_percent // .five_hour.utilization),
        resets_at: (.five_hour.resets_at // .five_hour.resetsAt // null),
        resets_at_epoch: $fh_epoch
      },
      seven_day: {
        used_percent: (.seven_day.used_percent // .seven_day.utilization),
        resets_at: (.seven_day.resets_at // .seven_day.resetsAt // null),
        resets_at_epoch: $sd_epoch
      },
      last_error: null
    }' 2>/dev/null
}

transform_codex_usage() {
  raw="$1"
  now="$2"
  printf '%s' "$raw" | jq -c --argjson now "$now" '
    .rateLimits? // . as $r
    | {
      schema_version: 1,
      service: "codex",
      fetched_at: $now,
      updated_at: $now,
      five_hour: {
        used_percent: ($r.primary.usedPercent // $r.primary.used_percent),
        resets_at_epoch: ($r.primary.resetsAt // $r.primary.resets_at_epoch // null)
      },
      seven_day: {
        used_percent: ($r.secondary.usedPercent // $r.secondary.used_percent),
        resets_at_epoch: ($r.secondary.resetsAt // $r.secondary.resets_at_epoch // null)
      },
      last_error: null
    }' 2>/dev/null
}

fetch_claude_once() {
  out_file="$1"
  err_file="$2"
  token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$token" ]; then
    token="$(jq -r '.claudeAiOauth.accessToken // empty' \
      "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  if [ -z "$token" ]; then
    printf '%s\n' 'missing Claude token in keychain or credentials file' >"$err_file"
    return 10
  fi
  response="$(curl -sS --max-time "$REQUEST_TIMEOUT" \
    -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>"$err_file")"
  curl_status=$?
  [ "$curl_status" -eq 0 ] || return "$curl_status"
  status="$(printf '%s\n' "$response" | tail -n 1)"
  body="$(printf '%s\n' "$response" | sed '$d')"
  case "$status" in
    2??)
      now="$(now_epoch)"
      transformed="$(transform_claude_usage "$body" "$now")" || return 11
      printf '%s\n' "$transformed" >"$out_file"
      return 0
      ;;
    429) printf '%s\n' "$status" >"$err_file"; return 42 ;;
    *) printf '%s\n' "$status" >"$err_file"; return 12 ;;
  esac
}

fetch_codex_once() {
  out_file="$1"
  err_file="$2"
  _codex_tmp_dir="$TMP_DIR/codex.$$.$RANDOM"
  mkdir -p "$_codex_tmp_dir" 2>/dev/null || return 1
  in_fifo="$_codex_tmp_dir/in"
  server_out="$_codex_tmp_dir/out"
  server_err="$_codex_tmp_dir/err"
  mkfifo "$in_fifo" 2>/dev/null || {
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir=""
    return 1
  }
  : >"$server_out"
  codex app-server <"$in_fifo" >"$server_out" 2>"$server_err" &
  _codex_server_pid=$!

  # codex app-server requires initialize to complete before serving account/* methods.
  # We keep the FIFO open for the full duration by holding it open in the writer subshell.
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-codex-usage","version":"1.0"}}}'
    sleep 3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
    sleep "$REQUEST_TIMEOUT"
  } >"$in_fifo" &
  _codex_writer_pid=$!

  # Codex timeout = REQUEST_TIMEOUT (for the rateLimits call) + 5s (initialize overhead)
  codex_deadline=$(( REQUEST_TIMEOUT + 5 ))
  start_seconds=$SECONDS
  result=""
  while [ $(( SECONDS - start_seconds )) -le "$codex_deadline" ]; do
    result="$(jq -c 'select(.id == 2) | .result.rateLimits // empty' "$server_out" 2>/dev/null | tail -n 1)"
    [ -n "$result" ] && break
    kill -0 "$_codex_server_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$_codex_writer_pid" 2>/dev/null
  kill "$_codex_server_pid" 2>/dev/null
  sleep 1
  kill -0 "$_codex_server_pid" 2>/dev/null && kill -9 "$_codex_server_pid" 2>/dev/null
  wait "$_codex_writer_pid" 2>/dev/null
  wait "$_codex_server_pid" 2>/dev/null
  if [ -z "$result" ]; then
    cat "$server_err" >"$err_file" 2>/dev/null
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
    return 124
  fi
  now="$(now_epoch)"
  transformed="$(transform_codex_usage "$result" "$now")" || {
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
    return 11
  }
  printf '%s\n' "$transformed" >"$out_file"
  rm -rf "$_codex_tmp_dir" 2>/dev/null
  _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
  return 0
}

retry_fetch() {
  service="$1"
  out_file="$2"
  err_file="$3"
  attempt=0
  max_attempts=$(( RETRY_COUNT + 1 ))
  last_status=1
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$(( attempt + 1 ))
    if [ "$service" = "claude" ]; then
      fetch_claude_once "$out_file" "$err_file"
    else
      fetch_codex_once "$out_file" "$err_file"
    fi
    last_status=$?
    if [ "$last_status" -eq 0 ]; then
      log "$service: fetch OK (attempt $attempt/$max_attempts)"
      return 0
    fi
    err_detail="$(cat "$err_file" 2>/dev/null | head -1)"
    log "$service: fetch FAILED status=$last_status attempt=$attempt/$max_attempts${err_detail:+ ($err_detail)}"
    if [ "$last_status" -eq 42 ]; then
      log "$service: rate limited; retry suppressed until next refresh cycle"
      break
    fi
    [ "$attempt" -lt "$max_attempts" ] || break
    sleep_seconds=1
    log "$service: retry in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  done
  return "$last_status"
}

ensure_notify_state_json() {
  jq -cn '{
    schema_version:1,
    updated_at:0,
    services:{
      claude:{
        five_hour:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        seven_day:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null}
      },
      codex:{
        five_hour:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        seven_day:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null}
      }
    }
  }'
}

read_notify_state() {
  if [ -f "$NOTIFY_STATE" ] && jq -e '.schema_version == 1 and .services.claude and .services.codex' "$NOTIFY_STATE" >/dev/null 2>&1; then
    jq -c . "$NOTIFY_STATE"
  else
    ensure_notify_state_json
  fi
}

send_notification() {
  message="$1"
  if [ -n "${CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG:-}" ]; then
    printf '%s\n' "$message" >>"$CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG"
    return 0
  fi
  run_with_timeout "$REQUEST_TIMEOUT" osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "claude-codex-usage" sound name (item 2 of argv)' \
    -e 'end run' \
    "$message" "$NOTIFY_SOUND"
  return 0
}

run_reset_hook() {
  service="$1"
  window="$2"
  prev="$3"
  current="$4"
  [ -n "$RESET_HOOK" ] || return 0
  [ -x "$RESET_HOOK" ] || return 0
  run_with_timeout "$HOOK_TIMEOUT" "$RESET_HOOK" "$service" "$window" "$prev" "$current"
  return 0
}

process_notifications() {
  service="$1"
  cache="$2"
  [ -f "$cache" ] || return 0
  jq -e '.last_error == null and .five_hour.used_percent != null and .seven_day.used_percent != null' "$cache" >/dev/null 2>&1 || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  state="$(read_notify_state)" || return 1
  now="$(now_epoch)"
  cache_json="$(jq -c . "$cache" 2>/dev/null)" || return 0
  events="$(jq -rn \
    --argjson state "$state" \
    --argjson cache "$cache_json" \
    --arg service "$service" \
    --argjson warn "$WARN_THRESHOLD" \
    --argjson threshold "$NOTIFY_THRESHOLD" \
    --argjson floor "$NOTIFY_FLOOR" '
      ["five_hour","seven_day"][] as $w
      | ($cache[$w].used_percent) as $current
      | ($state.services[$service][$w].previous_used_percent) as $prev
      | ($state.services[$service][$w].reset_notified // false) as $rn
      | ($state.services[$service][$w].warn_notified // false) as $wn
      | if ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then
          "reset|\($w)|\($prev)|\($current)"
        else empty end,
        if (($wn|not) and $current >= $warn) then
          "warn|\($w)|\($current)"
        else empty end
    ' 2>/dev/null)"
  printf '%s\n' "$events" | while IFS='|' read kind window a b; do
    [ -n "$kind" ] || continue
    display_service="$(printf '%s' "$service" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    display_window="$window"
    [ "$window" = "five_hour" ] && display_window="5h"
    [ "$window" = "seven_day" ] && display_window="7d"
    if [ "$kind" = "reset" ]; then
      send_notification "$display_service $display_window リセット: ${a}% -> ${b}%"
      run_reset_hook "$service" "$window" "$a" "$b"
    elif [ "$kind" = "warn" ]; then
      send_notification "$display_service ${display_window}枠 警告: ${a}%"
    fi
  done
  updated="$(jq -cn \
    --argjson state "$state" \
    --argjson cache "$cache_json" \
    --arg service "$service" \
    --argjson now "$now" \
    --argjson warn "$WARN_THRESHOLD" \
    --argjson threshold "$NOTIFY_THRESHOLD" \
    --argjson floor "$NOTIFY_FLOOR" '
      def empty_window: {previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null};
      reduce ["five_hour","seven_day"][] as $w ($state;
        .schema_version=1
        | .updated_at=$now
        | .services.claude.five_hour=(.services.claude.five_hour // empty_window)
        | .services.claude.seven_day=(.services.claude.seven_day // empty_window)
        | .services.codex.five_hour=(.services.codex.five_hour // empty_window)
        | .services.codex.seven_day=(.services.codex.seven_day // empty_window)
        | ($cache[$w].used_percent) as $current
        | (.services[$service][$w].previous_used_percent) as $prev
        | (.services[$service][$w].reset_notified // false) as $rn
        | (.services[$service][$w].warn_notified // false) as $wn
        | (.services[$service][$w].reset_notified) =
            (if ($rn and $current >= $threshold) then false
             elif ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then true
             else $rn end)
        | (.services[$service][$w].reset_notified_at) =
            (if ($rn and $current >= $threshold) then null
             elif ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then $now
             else .services[$service][$w].reset_notified_at end)
        | (.services[$service][$w].warn_notified) =
            (if $current >= $warn then true else false end)
        | (.services[$service][$w].warn_notified_at) =
            (if (($wn|not) and $current >= $warn) then $now
             elif $current < $warn then null
             else .services[$service][$w].warn_notified_at end)
        | (.services[$service][$w].previous_used_percent) = $current
        | (.services[$service][$w].last_seen_used_percent) = $current
      )' 2>/dev/null)" || return 1
  atomic_write "$NOTIFY_STATE" "$updated"
}

refresh_service() {
  service="$1"
  if [ "$service" = "claude" ]; then
    cache="$CLAUDE_CACHE"
  else
    cache="$CODEX_CACHE"
  fi
  out="$TMP_DIR/$service.out.$$"
  err="$TMP_DIR/$service.err.$$"
  mkdir -p "$CACHE_DIR" "$TMP_DIR" 2>/dev/null || return 1
  retry_fetch "$service" "$out" "$err"
  fetch_status=$?
  attempts=$(( RETRY_COUNT + 1 ))
  if [ "$fetch_status" -eq 0 ]; then
    payload="$(cat "$out" 2>/dev/null)"
    atomic_write "$cache" "$payload" || {
      rm -f "$out" "$err" 2>/dev/null
      return 1
    }
    rm -f "$out" "$err" 2>/dev/null
    with_lock notify process_notifications "$service" "$cache"
    return 0
  fi
  if is_transient_fetch_status "$fetch_status"; then
    log "$service: transient fetch failure; keeping existing cache"
    rm -f "$out" "$err" 2>/dev/null
    return 0
  fi
  case "$fetch_status" in
    10) error_type="auth"; message="authentication failed"; status_json="null" ;;
    11) error_type="parse"; message="failed to parse usage response"; status_json="null" ;;
    12) error_type="http"; message="HTTP request failed"; status_json="$(cat "$err" 2>/dev/null | tail -n 1)";;
    42) error_type="http"; message="rate limited"; status_json="429" ;;
    124) error_type="timeout"; message="request timed out"; status_json="null" ;;
    *) error_type="command"; message="usage command failed"; status_json="null" ;;
  esac
  case "$status_json" in ''|*[!0-9]*) status_json="null" ;; esac
  write_failure_cache "$service" "$cache" "$error_type" "$message" "$status_json" "$attempts"
  rm -f "$out" "$err" 2>/dev/null
  return 0
}

main() {
  load_config
  trap 'cleanup_codex_server; exit 130' INT
  trap 'cleanup_codex_server; exit 143' TERM
  trap 'cleanup_codex_server'           EXIT
  mode="${1:-all}"
  case "$mode" in
    claude|codex|all) ;;
    *) printf '%s\n' "usage: $0 [claude|codex|all]" >&2; return 2 ;;
  esac
  log "refresh.sh $mode: started"
  command -v jq >/dev/null 2>&1 || { printf '%s\n' 'missing required command: jq' >&2; return 3; }
  command -v curl >/dev/null 2>&1 || { printf '%s\n' 'missing required command: curl' >&2; return 3; }
  if [ "$mode" = "codex" ] || [ "$mode" = "all" ]; then
    command -v codex >/dev/null 2>&1 || { printf '%s\n' 'missing required command: codex' >&2; return 3; }
  fi
  mkdir -p "$CACHE_DIR" "$LOCK_DIR" "$TMP_DIR" 2>/dev/null || return 1
  if [ "$mode" = "claude" ] || [ "$mode" = "all" ]; then
    with_lock claude refresh_service claude || return 1
  fi
  if [ "$mode" = "codex" ] || [ "$mode" = "all" ]; then
    with_lock codex refresh_service codex || return 1
  fi
  return 0
}

if [ "${CLAUDE_CODEX_USAGE_TEST_LIB:-}" = "1" ]; then
  load_config
else
  main "$@"
  exit $?
fi
