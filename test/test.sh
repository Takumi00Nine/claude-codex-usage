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

assert_not_contains() {
  name="$1"
  haystack="$2"
  needle="$3"
  case "$haystack" in
    *"$needle"*) not_ok "$name: unexpected [$needle] in [$haystack]" ;;
    *) ok "$name" ;;
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

test_lock_cleanup_trap() {
  lock_cache="$tmp/lock-cleanup-cache"
  mkdir -p "$lock_cache"
  /bin/bash -c '
    export CLAUDE_CODEX_USAGE_TEST_LIB=1
    export XDG_CACHE_HOME="$1"
    . "$2/refresh.sh"
    trap '"'"'cleanup_locks; cleanup_codex_server; exit 143'"'"' TERM
    hold_and_signal() {
      kill -TERM $$
      sleep 5
    }
    nested_lock() {
      with_lock trap-test-inner hold_and_signal
    }
    with_lock trap-test nested_lock
  ' _ "$lock_cache" "$ROOT" >/dev/null 2>&1
  status=$?
  assert_eq "lock trap exits with TERM status" "143" "$status"
  if [ -d "$lock_cache/claude-codex-usage/locks/trap-test.lock.d" ]; then
    not_ok "lock trap cleanup removes held lock"
  else
    ok "lock trap cleanup removes held lock"
  fi
  if [ -d "$lock_cache/claude-codex-usage/locks/trap-test-inner.lock.d" ]; then
    not_ok "lock trap cleanup removes nested held lock"
  else
    ok "lock trap cleanup removes nested held lock"
  fi
}

test_invalid_numeric_config_fallback() {
  cfg_home="$tmp/numeric-config"
  cache_home="$tmp/numeric-cache"
  mkdir -p "$cfg_home/claude-codex-usage" "$cache_home"
  {
    printf '%s\n' 'REQUEST_TIMEOUT=abc'
    printf '%s\n' 'RETRY_COUNT=-1'
    printf '%s\n' 'WARN_THRESHOLD=101'
    printf '%s\n' 'HOOK_TIMEOUT=0'
  } >"$cfg_home/claude-codex-usage/config.sh"
  out="$(XDG_CONFIG_HOME="$cfg_home" XDG_CACHE_HOME="$cache_home" CLAUDE_CODEX_USAGE_TEST_LIB=1 /bin/bash -c '. "$1/refresh.sh"; printf "%s,%s,%s,%s\n" "$REQUEST_TIMEOUT" "$RETRY_COUNT" "$WARN_THRESHOLD" "$HOOK_TIMEOUT"' _ "$ROOT" 2>/dev/null | tail -n 1)"
  assert_eq "refresh invalid numeric config falls back" "15,2,80,60" "$out"

  cfg_home="$tmp/tmux-numeric-config"
  cache_home="$tmp/tmux-numeric-cache"
  mkdir -p "$cfg_home/claude-codex-usage" "$cache_home/claude-codex-usage"
  {
    printf '%s\n' 'CELLS=-4'
    printf '%s\n' 'STALE_MINUTES=nope'
    printf '%s\n' 'USAGE_NARROW_BELOW=wide'
  } >"$cfg_home/claude-codex-usage/config.sh"
  now="$(date '+%s')"
  jq -cn --argjson now "$now" '{schema_version:1,service:"claude",fetched_at:$now,updated_at:$now,five_hour:{used_percent:50,resets_at_epoch:null},seven_day:{used_percent:10,resets_at_epoch:null},last_error:null}' >"$cache_home/claude-codex-usage/claude-cache.json"
  out="$(XDG_CONFIG_HOME="$cfg_home" XDG_CACHE_HOME="$cache_home" "$ROOT/tmux-usage.sh" 120 2>/dev/null)"
  assert_contains "tmux invalid numeric config still renders" "$out" "50%"
}

test_uninstall_purge_cache_guard() {
  home_dir="$tmp/uninstall-home"
  cfg_home="$tmp/uninstall-config"
  cache_home="$tmp/uninstall-cache"
  mkdir -p "$home_dir/Library/LaunchAgents" "$cfg_home/claude-codex-usage" "$cache_home"
  dangerous="$home_dir/claude-codex-usage"
  mkdir -p "$dangerous"
  printf '%s\n' "CACHE_DIR=\"$dangerous\"" >"$cfg_home/claude-codex-usage/config.sh"
  out="$(HOME="$home_dir" XDG_CONFIG_HOME="$cfg_home" XDG_CACHE_HOME="$cache_home" "$ROOT/uninstall.sh" --purge-cache 2>&1)"
  status=$?
  assert_eq "purge-cache dangerous path rejected status" "2" "$status"
  assert_contains "purge-cache dangerous path rejected message" "$out" "refusing to purge"
  if [ -d "$dangerous" ]; then
    ok "purge-cache leaves dangerous path intact"
  else
    not_ok "purge-cache leaves dangerous path intact"
  fi
}

test_uninstall_purge_cache_canonical_guard() {
  home_dir="$tmp/uninstall-canonical-home"
  cfg_home="$tmp/uninstall-canonical-config"
  cache_home="$tmp/uninstall-canonical-cache"
  allowed="$cache_home/claude-codex-usage"
  outside="$tmp/uninstall-outside/claude-codex-usage"
  mkdir -p "$home_dir/Library/LaunchAgents" "$cfg_home/claude-codex-usage" "$allowed" "$outside"

  printf '%s\n' "CACHE_DIR=\"$cache_home/claude-codex-usage/../../uninstall-outside/claude-codex-usage\"" >"$cfg_home/claude-codex-usage/config.sh"
  out="$(HOME="$home_dir" XDG_CONFIG_HOME="$cfg_home" XDG_CACHE_HOME="$cache_home" "$ROOT/uninstall.sh" --purge-cache 2>&1)"
  status=$?
  assert_eq "purge-cache rejects dot-dot outside root status" "2" "$status"
  assert_contains "purge-cache rejects dot-dot outside root message" "$out" "outside allowed root"

  mkdir -p "$allowed"
  ln -s "$tmp/uninstall-outside" "$allowed/escape"
  printf '%s\n' "CACHE_DIR=\"$allowed/escape/claude-codex-usage\"" >"$cfg_home/claude-codex-usage/config.sh"
  out="$(HOME="$home_dir" XDG_CONFIG_HOME="$cfg_home" XDG_CACHE_HOME="$cache_home" "$ROOT/uninstall.sh" --purge-cache 2>&1)"
  status=$?
  assert_eq "purge-cache rejects symlink outside root status" "2" "$status"
  assert_contains "purge-cache rejects symlink outside root message" "$out" "outside allowed root"
}

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

test_usage_payload_validation() {
  out_file="$tmp/validated.out"
  err_file="$tmp/validated.err"
  valid='{"schema_version":1,"service":"claude","fetched_at":1,"updated_at":1,"five_hour":{"used_percent":42},"seven_day":{"used_percent":18},"last_error":null}'
  write_validated_usage_payload claude "$valid" "$out_file" "$err_file"
  assert_eq "validated payload writes output" "42" "$(jq -r '.five_hour.used_percent' "$out_file")"

  rm -f "$out_file" "$err_file"
  invalid_null='{"schema_version":1,"service":"claude","fetched_at":1,"updated_at":1,"five_hour":{"used_percent":null},"seven_day":{"used_percent":18},"last_error":null}'
  write_validated_usage_payload claude "$invalid_null" "$out_file" "$err_file"
  assert_eq "null percent rejected status" "11" "$?"
  assert_eq "null percent records parse token" "parse_error" "$(cat "$err_file")"
  if [ -f "$out_file" ]; then
    not_ok "null percent does not write output"
  else
    ok "null percent does not write output"
  fi

  rm -f "$out_file" "$err_file"
  invalid_range='{"schema_version":1,"service":"codex","fetched_at":1,"updated_at":1,"five_hour":{"used_percent":101},"seven_day":{"used_percent":18},"last_error":null}'
  write_validated_usage_payload codex "$invalid_range" "$out_file" "$err_file"
  assert_eq "range percent rejected status" "11" "$?"
}

test_parse_failure_cache() {
  export XDG_CACHE_HOME="$tmp/parse-cache"
  CACHE_DIR="$XDG_CACHE_HOME/claude-codex-usage"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
  mkdir -p "$CACHE_DIR" "$LOCK_DIR" "$TMP_DIR"
  RETRY_COUNT=0
  old='{"schema_version":1,"service":"codex","fetched_at":300,"updated_at":300,"five_hour":{"used_percent":60,"resets_at_epoch":null},"seven_day":{"used_percent":20,"resets_at_epoch":null},"last_error":null}'
  printf '%s\n' "$old" >"$CODEX_CACHE"

  fetch_codex_once() {
    out_file="$1"
    err_file="$2"
    printf '%s\n' 'parse_error' >"$err_file"
    : >"$out_file"
    return 11
  }

  refresh_service codex >/dev/null 2>&1
  assert_eq "parse writes error type" "parse" "$(jq -r '.last_error.type' "$CODEX_CACHE")"
  assert_eq "parse keeps previous usage" "60" "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")"
}

test_sanitized_fetch_logging() {
  RETRY_COUNT=0
  out_file="$tmp/logging.out"
  err_file="$tmp/logging.err"
  fetch_claude_once() {
    out_file="$1"
    err_file="$2"
    printf '%s\n' 'secret-token-value' >"$err_file"
    : >"$out_file"
    return 12
  }
  log_output="$(retry_fetch claude "$out_file" "$err_file" 2>&1)"
  assert_not_contains "fetch log omits raw stderr" "$log_output" "secret-token-value"
  assert_contains "fetch log keeps exit status" "$log_output" "status=12"

  fetch_claude_once() {
    out_file="$1"
    err_file="$2"
    printf '%s\n' 'http_status=401' >"$err_file"
    : >"$out_file"
    return 12
  }
  log_output="$(retry_fetch claude "$out_file" "$err_file" 2>&1)"
  assert_contains "fetch log includes safe token" "$log_output" "token=http_status=401"
}

test_fetch_claude_auth_uses_curl_config() {
  mock_bin="$tmp/mock-curl-bin"
  home_dir="$tmp/mock-claude-home"
  cache_dir="$tmp/mock-claude-cache"
  mkdir -p "$mock_bin" "$home_dir/.claude" "$cache_dir/tmp"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"dummy-oauth-token"}}' >"$home_dir/.claude/.credentials.json"
  cat >"$mock_bin/curl" <<'EOF'
#!/bin/bash
config=""
printf '%s\n' "$@" >"$MOCK_CURL_ARGS_FILE"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|-K)
      shift
      config="$1"
      ;;
  esac
  shift
done
printf '%s' "$config" >"$MOCK_CURL_CONFIG_PATH_FILE"
if [ -n "$config" ] && [ -f "$config" ]; then
  if grep 'Authorization: Bearer dummy-oauth-token' "$config" >/dev/null 2>&1; then
    printf '%s\n' yes >"$MOCK_CURL_CONFIG_HAS_TOKEN_FILE"
  else
    printf '%s\n' no >"$MOCK_CURL_CONFIG_HAS_TOKEN_FILE"
  fi
  perm="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config" 2>/dev/null)"
  printf '%s' "$perm" >"$MOCK_CURL_CONFIG_PERM_FILE"
else
  printf '%s\n' no >"$MOCK_CURL_CONFIG_HAS_TOKEN_FILE"
fi
printf '%s\n%s\n' '{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}' '200'
EOF
  chmod +x "$mock_bin/curl"

  old_path="$PATH"
  old_home="$HOME"
  old_tmp_dir="$TMP_DIR"
  old_request_timeout="$REQUEST_TIMEOUT"
  PATH="$mock_bin:$PATH"
  HOME="$home_dir"
  TMP_DIR="$cache_dir/tmp"
  REQUEST_TIMEOUT=15
  MOCK_CURL_ARGS_FILE="$tmp/mock-curl-args.txt"
  MOCK_CURL_CONFIG_PATH_FILE="$tmp/mock-curl-config-path.txt"
  MOCK_CURL_CONFIG_HAS_TOKEN_FILE="$tmp/mock-curl-config-token.txt"
  MOCK_CURL_CONFIG_PERM_FILE="$tmp/mock-curl-config-perm.txt"
  export MOCK_CURL_ARGS_FILE MOCK_CURL_CONFIG_PATH_FILE MOCK_CURL_CONFIG_HAS_TOKEN_FILE MOCK_CURL_CONFIG_PERM_FILE

  out_file="$tmp/mock-claude.out"
  err_file="$tmp/mock-claude.err"
  fetch_claude_once "$out_file" "$err_file"
  status=$?
  args="$(cat "$MOCK_CURL_ARGS_FILE")"
  config_path="$(cat "$MOCK_CURL_CONFIG_PATH_FILE")"
  assert_eq "claude fetch via mocked curl succeeds" "0" "$status"
  assert_contains "claude fetch passes curl config argv" "$args" "--config"
  assert_not_contains "claude token omitted from curl argv" "$args" "dummy-oauth-token"
  assert_eq "claude auth config contains token header" "yes" "$(cat "$MOCK_CURL_CONFIG_HAS_TOKEN_FILE")"
  assert_eq "claude auth config is 0600" "600" "$(cat "$MOCK_CURL_CONFIG_PERM_FILE")"
  if [ -e "$config_path" ]; then
    not_ok "claude auth config removed after curl"
  else
    ok "claude auth config removed after curl"
  fi

  PATH="$old_path"
  HOME="$old_home"
  TMP_DIR="$old_tmp_dir"
  REQUEST_TIMEOUT="$old_request_timeout"
  unset MOCK_CURL_ARGS_FILE MOCK_CURL_CONFIG_PATH_FILE MOCK_CURL_CONFIG_HAS_TOKEN_FILE MOCK_CURL_CONFIG_PERM_FILE
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
    printf '%s\n' 'http_status=401' >"$err_file"
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

test_install_config_order() {
  export XDG_CONFIG_HOME="$tmp/install-config"
  export XDG_CACHE_HOME="$tmp/install-cache"
  CONFIG_DIR="$XDG_CONFIG_HOME/claude-codex-usage"
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' 'REFRESH_INTERVAL="${REFRESH_INTERVAL:-120}"' >"$CONFIG_DIR/config.sh"
  printf '%s\n' 'REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-9}"' >>"$CONFIG_DIR/config.sh"
  unset REFRESH_INTERVAL REQUEST_TIMEOUT
  load_config
  assert_eq "install config default expression wins" "120" "$REFRESH_INTERVAL"
  assert_eq "install config timeout expression wins" "9" "$REQUEST_TIMEOUT"
  p120="$(generate_plist "/usr/bin:/bin")"
  c120="$(printf '%s\n' "$p120" | grep -c '<key>Minute</key>')"
  assert_eq "install plist uses configured interval" "30" "$c120"
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

test_lock_cleanup_trap
test_invalid_numeric_config_fallback
test_uninstall_purge_cache_guard
test_uninstall_purge_cache_canonical_guard
test_json_transform
test_usage_payload_validation
test_parse_failure_cache
test_fetch_claude_auth_uses_curl_config
test_sanitized_fetch_logging
test_failure_update
test_transient_refresh_failures
test_non_transient_refresh_failure
test_notifications
test_tmux_display
test_plist_generation
test_install_config_order
test_syntax

printf 'RESULT pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
