#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PASS=0
FAIL=0

say() {
  printf '%s\n' "$1"
}

ok() {
  PASS=$(( PASS + 1 ))
  printf 'PASS %s\n' "$1"
}

not_ok() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL %s\n' "$1"
}

assert_eq() {
  name="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name"
  else
    not_ok "$name: expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  name="$1"
  haystack="$2"
  needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) not_ok "$name: missing [$needle] in [$haystack]" ;;
  esac
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ccu-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

export XDG_CONFIG_HOME="$tmp/config"
export XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
export CLAUDE_CODEX_USAGE_TEST_LIB=1
. "$ROOT/refresh.sh"
. "$ROOT/install.sh"
unset CLAUDE_CODEX_USAGE_TEST_LIB

test_json_transform() {
  now=1782585600
  claude_raw='{"five_hour":{"utilization":42,"resets_at":"2026-06-28T12:34:56Z"},"seven_day":{"utilization":18,"resets_at":"2026-07-01T00:00:00Z"}}'
  out="$(transform_claude_usage "$claude_raw" "$now")"
  assert_eq "claude transform service" "claude" "$(printf '%s' "$out" | jq -r '.service')"
  assert_eq "claude transform five_hour" "42" "$(printf '%s' "$out" | jq -r '.five_hour.used_percent')"
  assert_eq "claude transform clears error" "null" "$(printf '%s' "$out" | jq -r '.last_error')"
  codex_raw='{"primary":{"usedPercent":12,"resetsAt":1782608096},"secondary":{"usedPercent":44,"resetsAt":1782846000}}'
  out="$(transform_codex_usage "$codex_raw" "$now")"
  assert_eq "codex transform service" "codex" "$(printf '%s' "$out" | jq -r '.service')"
  assert_eq "codex transform weekly" "44" "$(printf '%s' "$out" | jq -r '.seven_day.used_percent')"
}

test_failure_update() {
  CACHE_DIR="$tmp/cache/claude-codex-usage"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  mkdir -p "$CACHE_DIR"
  old='{"schema_version":1,"service":"claude","fetched_at":100,"updated_at":100,"five_hour":{"used_percent":55,"resets_at":null,"resets_at_epoch":null},"seven_day":{"used_percent":10,"resets_at":null,"resets_at_epoch":null},"last_error":null}'
  printf '%s\n' "$old" >"$CLAUDE_CACHE"
  write_failure_cache claude "$CLAUDE_CACHE" timeout "request timed out" null 3
  assert_eq "failure keeps usage" "55" "$(jq -r '.five_hour.used_percent' "$CLAUDE_CACHE")"
  assert_eq "failure writes error" "timeout" "$(jq -r '.last_error.type' "$CLAUDE_CACHE")"
  assert_eq "failure keeps fetched_at" "100" "$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
}

test_transient_refresh_failures() {
  export XDG_CACHE_HOME="$tmp/transient-cache"
  CACHE_DIR="$XDG_CACHE_HOME/claude-codex-usage"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
  mkdir -p "$CACHE_DIR" "$LOCK_DIR" "$TMP_DIR"
  RETRY_COUNT=2
  old='{"schema_version":1,"service":"claude","fetched_at":100,"updated_at":100,"five_hour":{"used_percent":55,"resets_at":null,"resets_at_epoch":null},"seven_day":{"used_percent":10,"resets_at":null,"resets_at_epoch":null},"last_error":null}'
  printf '%s\n' "$old" >"$CLAUDE_CACHE"

  MOCK_ATTEMPTS_FILE="$tmp/mock-attempts.log"
  MOCK_STATUS=42
  MOCK_DETAIL=429
  fetch_claude_once() {
    out_file="$1"
    err_file="$2"
    printf '%s\n' attempt >>"$MOCK_ATTEMPTS_FILE"
    printf '%s\n' "$MOCK_DETAIL" >"$err_file"
    : >"$out_file"
    return "$MOCK_STATUS"
  }

  : >"$MOCK_ATTEMPTS_FILE"
  refresh_service claude >/dev/null 2>&1
  assert_eq "429 keeps last_error null" "null" "$(jq -r '.last_error' "$CLAUDE_CACHE")"
  assert_eq "429 keeps fetched_at" "100" "$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  assert_eq "429 suppresses retry" "1" "$(wc -l <"$MOCK_ATTEMPTS_FILE" | tr -d ' ')"
  out="$("$ROOT/tmux-usage.sh" 120)"
  case "$out" in
    *ERR*) not_ok "429 tmux omits ERR" ;;
    *) ok "429 tmux omits ERR" ;;
  esac

  MOCK_STATUS=28
  MOCK_DETAIL="operation timed out"
  : >"$MOCK_ATTEMPTS_FILE"
  refresh_service claude >/dev/null 2>&1
  assert_eq "timeout keeps last_error null" "null" "$(jq -r '.last_error' "$CLAUDE_CACHE")"
  assert_eq "timeout keeps usage" "55" "$(jq -r '.five_hour.used_percent' "$CLAUDE_CACHE")"
}

test_non_transient_refresh_failure() {
  export XDG_CACHE_HOME="$tmp/non-transient-cache"
  CACHE_DIR="$XDG_CACHE_HOME/claude-codex-usage"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
  mkdir -p "$CACHE_DIR" "$LOCK_DIR" "$TMP_DIR"
  RETRY_COUNT=2
  old='{"schema_version":1,"service":"claude","fetched_at":200,"updated_at":200,"five_hour":{"used_percent":60,"resets_at":null,"resets_at_epoch":null},"seven_day":{"used_percent":20,"resets_at":null,"resets_at_epoch":null},"last_error":null}'
  printf '%s\n' "$old" >"$CLAUDE_CACHE"

  fetch_claude_once() {
    out_file="$1"
    err_file="$2"
    printf '%s\n' 401 >"$err_file"
    : >"$out_file"
    return 12
  }

  refresh_service claude >/dev/null 2>&1
  assert_eq "401 writes error type" "http" "$(jq -r '.last_error.type' "$CLAUDE_CACHE")"
  assert_eq "401 writes status" "401" "$(jq -r '.last_error.status' "$CLAUDE_CACHE")"
  out="$("$ROOT/tmux-usage.sh" 120)"
  assert_contains "401 tmux shows ERR" "$out" "ERR"
}

test_notifications() {
  CACHE_DIR="$tmp/cache/claude-codex-usage"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
  mkdir -p "$CACHE_DIR"
  export CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG="$tmp/notify.log"
  : >"$CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG"
  WARN_THRESHOLD=80
  NOTIFY_THRESHOLD=20
  NOTIFY_FLOOR=5
  now=1782585600
  cache="$CACHE_DIR/claude-cache.json"
  transform_claude_usage '{"five_hour":{"utilization":50},"seven_day":{"utilization":10}}' "$now" >"$cache"
  process_notifications claude "$cache"
  assert_eq "notification initial quiet" "0" "$(wc -l <"$tmp/notify.log" 2>/dev/null | tr -d ' ')"
  transform_claude_usage '{"five_hour":{"utilization":4},"seven_day":{"utilization":85}}' "$now" >"$cache"
  process_notifications claude "$cache"
  log="$(cat "$tmp/notify.log")"
  assert_contains "reset notification" "$log" "Claude 5h リセット: 50% -> 4%"
  assert_contains "warn notification" "$log" "Claude 7d枠 警告: 85%"
  assert_eq "reset flag set" "true" "$(jq -r '.services.claude.five_hour.reset_notified' "$NOTIFY_STATE")"
  transform_claude_usage '{"five_hour":{"utilization":30},"seven_day":{"utilization":70}}' "$now" >"$cache"
  process_notifications claude "$cache"
  assert_eq "reset flag cleared" "false" "$(jq -r '.services.claude.five_hour.reset_notified' "$NOTIFY_STATE")"
  assert_eq "warn flag cleared" "false" "$(jq -r '.services.claude.seven_day.warn_notified' "$NOTIFY_STATE")"
  unset CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG
}

test_tmux_display() {
  export XDG_CACHE_HOME="$tmp/tmux-cache-empty"
  out="$("$ROOT/tmux-usage.sh" 120)"
  assert_contains "tmux no cache claude" "$out" "CL n/a"
  assert_contains "tmux no cache codex" "$out" "CX n/a"

  export XDG_CACHE_HOME="$tmp/tmux-cache"
  cache_dir="$XDG_CACHE_HOME/claude-codex-usage"
  mkdir -p "$cache_dir"
  now="$(date '+%s')"
  reset=$(( now + 3600 ))
  jq -cn --argjson now "$now" --argjson reset "$reset" '{schema_version:1,service:"claude",fetched_at:$now,updated_at:$now,five_hour:{used_percent:42,resets_at:null,resets_at_epoch:$reset},seven_day:{used_percent:18,resets_at:null,resets_at_epoch:null},last_error:null}' >"$cache_dir/claude-cache.json"
  jq -cn --argjson now "$now" --argjson reset "$reset" '{schema_version:1,service:"codex",fetched_at:$now,updated_at:$now,five_hour:{used_percent:12,resets_at_epoch:$reset},seven_day:{used_percent:44,resets_at_epoch:null},last_error:null}' >"$cache_dir/codex-cache.json"
  out="$("$ROOT/tmux-usage.sh" 120)"
  assert_contains "tmux normal claude percent" "$out" "42%"
  assert_contains "tmux normal codex percent" "$out" "44%"
  jq '.last_error={at:1,type:"timeout",message:"x",status:null,attempts:1}' "$cache_dir/claude-cache.json" >"$cache_dir/t" && mv "$cache_dir/t" "$cache_dir/claude-cache.json"
  out="$("$ROOT/tmux-usage.sh" 120)"
  assert_contains "tmux err" "$out" "ERR"
  old=$(( now - 1200 ))
  jq --argjson old "$old" '.fetched_at=$old' "$cache_dir/claude-cache.json" >"$cache_dir/t" && mv "$cache_dir/t" "$cache_dir/claude-cache.json"
  out="$("$ROOT/tmux-usage.sh" 120)"
  assert_contains "tmux stale" "$out" "分前"
  out="$("$ROOT/tmux-usage.sh" 80)"
  case "$out" in
    *"█"*) not_ok "tmux narrow omits gauge" ;;
    *) ok "tmux narrow omits gauge" ;;
  esac
}

test_plist_generation() {
  REFRESH_INTERVAL=60
  p60="$(generate_plist "/usr/bin:/bin")"
  c60="$(printf '%s\n' "$p60" | grep -c '<key>Minute</key>')"
  assert_eq "plist 60 has 60 entries" "60" "$c60"
  REFRESH_INTERVAL=120
  p120="$(generate_plist "/usr/bin:/bin")"
  c120="$(printf '%s\n' "$p120" | grep -c '<key>Minute</key>')"
  assert_eq "plist 120 has 30 entries" "30" "$c120"
  assert_contains "plist includes minute 58" "$p120" "<integer>58</integer>"
}

test_syntax() {
  for f in refresh.sh tmux-usage.sh install.sh uninstall.sh test/test.sh; do
    if /bin/bash -n "$ROOT/$f"; then
      ok "syntax $f"
    else
      not_ok "syntax $f"
    fi
  done
}

test_json_transform
test_failure_update
test_transient_refresh_failures
test_non_transient_refresh_failure
test_notifications
test_tmux_display
test_plist_generation
test_syntax

printf 'RESULT pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
