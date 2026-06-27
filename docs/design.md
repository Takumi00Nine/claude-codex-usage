# 詳細設計書 — claude-codex-usage リビルド

> 対象要件: `docs/requirements.md` Implemented 2026-06-28

## 1. 全体アーキテクチャ

`refresh.sh` が唯一のネットワーク利用・キャッシュ書き込みプロセスで、`tmux-usage.sh` はキャッシュを読むだけにする。これにより、tmux ステータスバーは毎秒呼ばれても外部 API・`codex app-server`・通知処理を起動しない。

```text
                         ~/.config/claude-codex-usage/config.sh
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ per-user LaunchAgent                                             │
│ com.claude-codex-usage.refresh                                   │
│ RunAtLoad + StartCalendarInterval                                │
└───────────────────────────────┬─────────────────────────────────┘
                                │ refresh.sh all
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ refresh.sh                                                       │
│ - 設定読込                                                       │
│ - mkdir ロック                                                   │
│ - Claude / Codex 取得                                            │
│ - retry / timeout                                                │
│ - notify-state 更新・通知                                        │
│ - atomic write                                                   │
└───────────────┬───────────────────────────────┬─────────────────┘
                │                               │
                ▼                               ▼
┌─────────────────────────────┐   ┌───────────────────────────────┐
│ Claude OAuth usage API       │   │ codex app-server              │
│ curl --max-time              │   │ JSON-RPC over stdin/stdout     │
└───────────────┬─────────────┘   └───────────────┬───────────────┘
                │                                 │
                ▼                                 ▼
┌─────────────────────────────┐   ┌───────────────────────────────┐
│ claude-cache.json            │   │ codex-cache.json               │
│ ~/.cache/claude-codex-usage/ │   │ ~/.cache/claude-codex-usage/   │
└───────────────┬─────────────┘   └───────────────┬───────────────┘
                │                                 │
                └───────────────┬─────────────────┘
                                ▼
                 ┌───────────────────────────────┐
                 │ notify-state.json              │
                 │ 通知済みフラグ・前回値         │
                 └───────────────────────────────┘

┌─────────────────────────────┐
│ tmux status-right            │
│ #(.../tmux-usage.sh #{client_width}) 
└───────────────┬─────────────┘
                │ cache read only
                ▼
┌─────────────────────────────┐
│ tmux-usage.sh                │
│ - jq でキャッシュ読込        │
│ - n/a / ERR / stale 表示     │
│ - 幅に応じた表示切替         │
└─────────────────────────────┘
```

## 2. ディレクトリとファイル

```text
リポジトリ:
  refresh.sh
  tmux-usage.sh
  install.sh
  uninstall.sh
  config.example.sh
  README.md
  docs/requirements.md
  docs/design.md
  test/test.sh

設定:
  ~/.config/claude-codex-usage/config.sh

キャッシュ:
  ~/.cache/claude-codex-usage/claude-cache.json
  ~/.cache/claude-codex-usage/codex-cache.json
  ~/.cache/claude-codex-usage/notify-state.json

ログ:
  ~/Library/Logs/claude-codex-usage/refresh.log

LaunchAgent（`install.sh` が生成）:
  ~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist
```

## 3. キャッシュ JSON スキーマ

### 3.1 共通方針

- JSON は `jq -c` で1行に正規化して保存する。
- 書き込みは同一ディレクトリ内の一時ファイルへ出力後、`mv -f` で atomic write する。
- 取得成功時は usage 値・時刻・API 生値由来フィールドを更新し、`last_error` は `null` にする。
- 取得失敗時は既存 usage 値を維持し、`last_error` と `updated_at` だけ更新する。
- 初回取得失敗でキャッシュが存在しない場合は usage 値なしのエラーキャッシュを作成してよい。
- Unix 時刻はすべて epoch seconds の整数とする。

### 3.2 `claude-cache.json`

保存先: `~/.cache/claude-codex-usage/claude-cache.json`

```json
{
  "schema_version": 1,
  "service": "claude",
  "fetched_at": 1782585600,
  "updated_at": 1782585600,
  "five_hour": {
    "used_percent": 42,
    "resets_at": "2026-06-28T12:34:56Z",
    "resets_at_epoch": 1782608096
  },
  "seven_day": {
    "used_percent": 37,
    "resets_at": "2026-07-01T00:00:00Z",
    "resets_at_epoch": 1782846000
  },
  "last_error": null
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---:|---:|---|
| `schema_version` | number | 必須 | キャッシュ形式のバージョン。初期値は `1` |
| `service` | string | 必須 | 固定値 `claude` |
| `fetched_at` | number | 条件付き | 最後に usage 取得へ成功した時刻。初回取得失敗のみ省略可 |
| `updated_at` | number | 必須 | キャッシュファイルを最後に更新した時刻。成功・失敗どちらでも更新 |
| `five_hour` | object | 条件付き | Claude 5時間枠。初回取得失敗のみ省略可 |
| `five_hour.used_percent` | number | 必須 | 5時間枠の使用率%。小数が返る場合は保持し、表示時に丸める |
| `five_hour.resets_at` | string/null | 任意 | API のリセット時刻文字列。ISO 8601 |
| `five_hour.resets_at_epoch` | number/null | 任意 | `resets_at` を epoch seconds に変換した値。変換不可なら `null` |
| `seven_day` | object | 条件付き | Claude 週枠。初回取得失敗のみ省略可 |
| `seven_day.used_percent` | number | 必須 | 週枠の使用率% |
| `seven_day.resets_at` | string/null | 任意 | API の週枠リセット時刻文字列。取得不可なら `null` |
| `seven_day.resets_at_epoch` | number/null | 任意 | 週枠リセット時刻の epoch seconds。変換不可なら `null` |
| `last_error` | object/null | 必須 | 直近取得エラー。成功時は `null` |

`last_error` のスキーマ:

| フィールド | 型 | 必須 | 説明 |
|---|---:|---:|---|
| `at` | number | 必須 | エラー発生時刻 |
| `type` | string | 必須 | `auth` / `http` / `timeout` / `parse` / `command` / `unknown` |
| `message` | string | 必須 | tmux 表示・ログ向けの短い説明。シークレットは含めない |
| `status` | number/null | 任意 | HTTP ステータス。該当なしは `null` |
| `attempts` | number | 必須 | 実行した試行回数 |

Claude API から取得する既存名が `five_hour.utilization` / `seven_day.utilization` の場合も、キャッシュ保存時は `used_percent` に正規化する。

### 3.3 `codex-cache.json`

保存先: `~/.cache/claude-codex-usage/codex-cache.json`

```json
{
  "schema_version": 1,
  "service": "codex",
  "fetched_at": 1782585600,
  "updated_at": 1782585600,
  "five_hour": {
    "used_percent": 12,
    "resets_at_epoch": 1782608096
  },
  "seven_day": {
    "used_percent": 44,
    "resets_at_epoch": 1782846000
  },
  "last_error": null
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---:|---:|---|
| `schema_version` | number | 必須 | キャッシュ形式のバージョン。初期値は `1` |
| `service` | string | 必須 | 固定値 `codex` |
| `fetched_at` | number | 条件付き | 最後に usage 取得へ成功した時刻。初回取得失敗のみ省略可 |
| `updated_at` | number | 必須 | キャッシュファイルを最後に更新した時刻 |
| `five_hour` | object | 条件付き | Codex 5時間枠。JSON-RPC の `primary` を正規化 |
| `five_hour.used_percent` | number | 必須 | 5時間枠の使用率%。`rateLimits.primary.usedPercent` 由来 |
| `five_hour.resets_at_epoch` | number/null | 任意 | 5時間枠のリセット時刻。`rateLimits.primary.resetsAt` 由来 |
| `seven_day` | object | 条件付き | Codex 週枠。JSON-RPC の `secondary` を正規化 |
| `seven_day.used_percent` | number | 必須 | 週枠の使用率%。`rateLimits.secondary.usedPercent` 由来 |
| `seven_day.resets_at_epoch` | number/null | 任意 | 週枠リセット時刻。取得不可なら `null` |
| `last_error` | object/null | 必須 | 直近取得エラー。成功時は `null` |

`last_error` は Claude と同一スキーマを使う。

### 3.4 `notify-state.json`

保存先: `~/.cache/claude-codex-usage/notify-state.json`

```json
{
  "schema_version": 1,
  "updated_at": 1782585600,
  "services": {
    "claude": {
      "five_hour": {
        "previous_used_percent": 42,
        "last_seen_used_percent": 4,
        "reset_notified": true,
        "reset_notified_at": 1782585600,
        "warn_notified": false,
        "warn_notified_at": null
      },
      "seven_day": {
        "previous_used_percent": 37,
        "last_seen_used_percent": 37,
        "reset_notified": false,
        "reset_notified_at": null,
        "warn_notified": false,
        "warn_notified_at": null
      }
    },
    "codex": {
      "five_hour": {
        "previous_used_percent": 12,
        "last_seen_used_percent": 12,
        "reset_notified": false,
        "reset_notified_at": null,
        "warn_notified": false,
        "warn_notified_at": null
      },
      "seven_day": {
        "previous_used_percent": 44,
        "last_seen_used_percent": 44,
        "reset_notified": false,
        "reset_notified_at": null,
        "warn_notified": false,
        "warn_notified_at": null
      }
    }
  }
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---:|---:|---|
| `schema_version` | number | 必須 | 通知状態スキーマのバージョン。初期値は `1` |
| `updated_at` | number | 必須 | 通知状態ファイルを最後に更新した時刻 |
| `services` | object | 必須 | サービス別状態 |
| `services.claude` | object | 必須 | Claude の通知状態 |
| `services.codex` | object | 必須 | Codex の通知状態 |
| `<service>.five_hour` | object | 必須 | 5時間枠の通知状態 |
| `<service>.seven_day` | object | 必須 | 週枠の通知状態 |
| `<window>.previous_used_percent` | number/null | 必須 | 判定直前に保持していた前回使用率。初回は `null` |
| `<window>.last_seen_used_percent` | number/null | 必須 | 今回処理後の最新使用率。初回は `null` |
| `<window>.reset_notified` | boolean | 必須 | 現在の低水準状態についてリセット通知済みなら `true` |
| `<window>.reset_notified_at` | number/null | 必須 | 最後にリセット通知した時刻 |
| `<window>.warn_notified` | boolean | 必須 | 現在の高使用率状態について警告通知済みなら `true` |
| `<window>.warn_notified_at` | number/null | 必須 | 最後に高使用率通知した時刻 |

## 4. スクリプト仕様

### 4.1 共通設定読込

各スクリプトは以下の順序で既定値を設定し、設定ファイルがあれば `.` で読み込む。

```bash
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
CONFIG_FILE="$CONFIG_DIR/config.sh"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
```

設定値はシェル変数として扱う。bash 3.2 互換のため、連想配列・`mapfile`・`readarray`・プロセス置換に依存しない。

### 4.2 `refresh.sh`

目的: Claude / Codex の usage を取得し、キャッシュと通知状態を更新する。

入力:

```text
refresh.sh claude
refresh.sh codex
refresh.sh all
```

引数なしは `all` として扱う。不明な引数は usage を標準エラーへ出して終了コード `2`。

出力:

- 標準出力: 原則なし。
- 標準エラー: 手動実行時の短いエラー説明。
- ログ: LaunchAgent 実行時は plist の `StandardOutPath` / `StandardErrorPath` により `~/Library/Logs/claude-codex-usage/refresh.log` へ集約。

環境変数:

| 変数 | 既定値 | 用途 |
|---|---:|---|
| `REFRESH_INTERVAL` | `60` | plist 生成時の起動間隔。`refresh.sh` 内では参考値 |
| `REQUEST_TIMEOUT` | `15` | 外部呼び出し1回あたりのタイムアウト秒 |
| `RETRY_COUNT` | `2` | 追加リトライ回数（初回含む合計 `RETRY_COUNT + 1` 回） |
| `WARN_THRESHOLD` | `80` | 高使用率通知しきい値 |
| `NOTIFY_THRESHOLD` | `20` | リセット通知対象となる前回使用率 |
| `NOTIFY_FLOOR` | `5` | リセット判定となる今回使用率 |
| `NOTIFY_SOUND` | `Ping` | `osascript` 通知サウンド |
| `RESET_HOOK` | 空 | リセット通知後に呼ぶ外部スクリプト |
| `HOOK_TIMEOUT` | `60` | `RESET_HOOK` 実行のタイムアウト秒 |
| `SLEEP_STALE_MINUTES` | `5` | スリープ復帰相当の stale 判定 |
| `XDG_CONFIG_HOME` | `$HOME/.config` | 設定ディレクトリ上書き |
| `XDG_CACHE_HOME` | `$HOME/.cache` | キャッシュディレクトリ上書き |

終了コード:

| コード | 意味 |
|---:|---|
| `0` | 指定対象すべての処理が完了。取得失敗があってもキャッシュへ `last_error` を記録できた場合は常駐運用を止めないため `0` |
| `1` | キャッシュディレクトリ作成不可、atomic write 不可などローカル永続化エラー |
| `2` | 引数不正 |
| `3` | 必須コマンド不足 |

ロック:

- `~/.cache/claude-codex-usage/locks/claude.lock.d`
- `~/.cache/claude-codex-usage/locks/codex.lock.d`
- `~/.cache/claude-codex-usage/locks/notify.lock.d`

ロックは `mkdir` 成功を獲得とみなす。中に `pid` と `created_at` を置き、`REQUEST_TIMEOUT * (RETRY_COUNT + 1) + HOOK_TIMEOUT + 30` 秒を超えたロックは stale とみなして削除する（`HOOK_TIMEOUT` の既定60秒を含めることで、hook 実行中の誤 stale 判定による二重通知を防ぐ）。

### 4.3 `tmux-usage.sh`

目的: キャッシュを読み、tmux status-right 用の1行文字列を出力する。

入力:

```text
tmux-usage.sh [client_width]
```

`client_width` は tmux 側から `#{client_width}` を渡す。未指定・数値でない場合は広幅として扱う。`tmux display-message` はフォールバックに留める。

出力:

- 標準出力: tmux 書式を含む1行。
- 標準エラー: 原則なし。

表示:

- キャッシュなし: `CL n/a` / `CX n/a`
- `last_error != null`: 対象サービスの末尾に `ERR` を表示
- `now - fetched_at > STALE_MINUTES * 60`: `(15分前)` のように経過分を表示
- 幅が `USAGE_NARROW_BELOW` 未満: ゲージを省略し、`↻NNm` 表示
- 幅が十分: ゲージ、`%`、`↻H:MM:SS`

環境変数:

| 変数 | 既定値 | 用途 |
|---|---:|---|
| `USAGE_NARROW_BELOW` | `100` | 狭幅表示へ切り替える列数 |
| `CELLS` | `8` | ゲージ幅 |
| `STALE_MINUTES` | `10` | stale 表示しきい値 |
| `XDG_CONFIG_HOME` | `$HOME/.config` | 設定ディレクトリ上書き |
| `XDG_CACHE_HOME` | `$HOME/.cache` | キャッシュディレクトリ上書き |

終了コード:

| コード | 意味 |
|---:|---|
| `0` | 表示生成完了。キャッシュなし・JSON parse 失敗でも `n/a` / `ERR` 表示で成功扱い |
| `1` | 設定ファイル読込時の致命的エラー |

性能方針:

- ネットワーク・`codex`・`osascript` は絶対に呼ばない。
- `jq` は最大3ファイルに限定する。
- ファイルが壊れている場合は `ERR` または `n/a` にフォールバックする。

### 4.4 `install.sh`

目的: 設定ファイル作成、LaunchAgent plist 生成、ロード、有効化、初回キックを行う。

入力:

```text
install.sh
```

出力:

- 標準出力: 実施した操作の短い要約。
- 標準エラー: 依存不足・設定不正・launchctl 失敗。

処理:

1. `jq` / `curl` / `codex` / `osascript` / `launchctl` の存在確認。
2. `REFRESH_INTERVAL` が60以上かつ60の倍数であることを確認。
3. `~/.config/claude-codex-usage/` を作成。
4. `config.sh` がなければ `config.example.sh` をコピー。
5. `~/.cache/claude-codex-usage/` と `~/Library/Logs/claude-codex-usage/` を作成。
6. `command -v jq curl codex` の親ディレクトリを集め、`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` と重複除去して plist の `PATH` を生成。
7. `~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist` を生成。
8. 既存ジョブがあれば `launchctl bootout gui/$(id -u)/com.claude-codex-usage.refresh` を試行。
9. `launchctl bootstrap`、`launchctl enable`、`launchctl kickstart -k` を実行。

終了コード:

| コード | 意味 |
|---:|---|
| `0` | インストール完了 |
| `1` | ファイル作成・plist 書き込み失敗 |
| `2` | 設定値不正 |
| `3` | 必須コマンド不足 |
| `4` | launchctl 操作失敗 |

### 4.5 `uninstall.sh`

目的: LaunchAgent を停止・登録解除し、plist を削除する。キャッシュと設定は既定では削除しない。

入力:

```text
uninstall.sh
uninstall.sh --purge-cache
```

出力:

- 標準出力: 実施した操作の短い要約。
- 標準エラー: launchctl 失敗や削除失敗。

処理:

1. `launchctl bootout gui/$(id -u)/com.claude-codex-usage.refresh` を試行。
2. `~/Library/LaunchAgents/com.claude-codex-usage.refresh.plist` を削除。
3. `--purge-cache` 指定時のみ `~/.cache/claude-codex-usage/` を削除。
4. `~/.config/claude-codex-usage/config.sh` は削除しない。

終了コード:

| コード | 意味 |
|---:|---|
| `0` | アンインストール完了。未ロードでも成功扱い |
| `1` | plist 削除失敗 |
| `2` | 引数不正 |
| `4` | launchctl 操作が致命的に失敗 |

## 5. LaunchAgent 設計

`StartCalendarInterval` は cron 風のカレンダー指定で起動する。1分ごとに起動するには `Minute` を `0` から `59` まで列挙する。`REFRESH_INTERVAL` は60の倍数に制約し、2分以上の場合は該当分だけ列挙する。

1分間隔の plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-codex-usage.refresh</string>

  <key>ProgramArguments</key>
  <array>
    <string>/path/to/claude-codex-usage/refresh.sh</string>
    <string>all</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Minute</key><integer>0</integer></dict>
    <dict><key>Minute</key><integer>1</integer></dict>
    <dict><key>Minute</key><integer>2</integer></dict>
    <!-- install.sh が 59 まで生成する -->
  </array>

  <key>StandardOutPath</key>
  <string>~/Library/Logs/claude-codex-usage/refresh.log</string>
  <key>StandardErrorPath</key>
  <string>~/Library/Logs/claude-codex-usage/refresh.log</string>
</dict>
</plist>
```

設計意図:

- `RunAtLoad` でロード直後に1回取得する。
- `StartCalendarInterval` でカレンダー時刻に起動する。
- macOS のスリープ中に逃したカレンダー実行は復帰後にまとめて扱われるため、復帰直後の `refresh.sh all` 起動を期待できる。
- 念のため `refresh.sh` は起動時に `fetched_at` を見て `SLEEP_STALE_MINUTES` 超なら通常取得を行う。通常の1分起動でも同じコードパスを使う。
- `StartInterval` は使わない。要件の coalesce 方針を優先する。

## 6. タイムアウト・リトライ実装方針

### 6.1 基本方針

- GNU `timeout` は使わない。
- HTTP は `curl --max-time "$REQUEST_TIMEOUT"` で制限する。
- `codex app-server`、`osascript`、`RESET_HOOK` はサブシェルと watchdog で制限する。
- リトライは初回 + `RETRY_COUNT` 回。`RETRY_COUNT=2` なら最大3回。
- 429 は指数バックオフ、その他は短い固定バックオフにする。

### 6.2 Claude トークン取得と API 呼び出し

トークンは macOS キーチェーンから取得する。キーチェーンのサービス名は `Claude Code-credentials` で、値は JSON 文字列。`claudeAiOauth.accessToken` フィールドを `jq` で抽出する。キーチェーンに見つからない場合は `~/.claude/.credentials.json` をフォールバックとして使う。

```bash
token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
  | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
if [ -z "$token" ]; then
  token="$(jq -r '.claudeAiOauth.accessToken // empty' \
    "$HOME/.claude/.credentials.json" 2>/dev/null)"
fi
```

取得できなければ `last_error.type="auth"` として終了する。

API 呼び出し:

```bash
curl -sS --max-time "$REQUEST_TIMEOUT" \
  -w '\n%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage"
```

HTTP body と status を分離して、2xx 以外は `last_error.type="http"` にする。429 の場合は `sleep 1, 2, 4...` の指数バックオフを行う。ただし各 sleep は最大30秒に丸める。

### 6.3 汎用コマンドタイムアウト

bash 3.2 互換で外部コマンドを制限する。

```bash
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
      : >"$flag"          # タイムアウトフラグを立ててから kill
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
```

タイムアウト時の終了コードは 124（GNU `timeout` と同じ値）。フラグファイルでタイムアウト判定するため、`child` がゼロ以外で終了した場合でも正確に区別できる。呼び出し側は `[ $? -eq 124 ]` で `last_error.type="timeout"` に分岐する。

子プロセスがさらに子を作る可能性がある `codex app-server` では、後述の接続管理で個別に `kill` と `wait` を行う。

### 6.4 リトライ疑似コード

```bash
attempt=0
max_attempts=$((RETRY_COUNT + 1))
while [ "$attempt" -lt "$max_attempts" ]; do
  attempt=$((attempt + 1))
  if fetch_once; then
    return 0
  fi

  [ "$attempt" -lt "$max_attempts" ] || break
  if [ "$last_status" = "429" ]; then
    sleep_seconds=$(( 1 << (attempt - 1) ))
    [ "$sleep_seconds" -gt 30 ] && sleep_seconds=30
  else
    sleep_seconds=1
  fi
  sleep "$sleep_seconds"
done
return 1
```

bash 3.2 互換のビットシフト `1 << n` で指数バックオフを実現する（`**` 演算子は bash 4.0 以降のため使用しない）。

## 7. 通知ステートマシン

通知判定は `refresh.sh` の取得成功後だけ行う。取得失敗時は前回値を変えず、通知もしない。

### 7.0 `notify-state.json` の初期化

`notify-state.json` が存在しない場合、または下記のいずれかに該当する場合は、全フィールドをゼロ埋め（`previous_used_percent=null`・`last_seen_used_percent=null`・`reset_notified=false`・`warn_notified=false`）で初期化してから処理を継続する。エラー終了しない。

- JSON として parse 不能（truncation・破損）
- `schema_version` が現行と一致しない
- `services.claude` または `services.codex` キーが欠落している
- 個別の `five_hour` / `seven_day` サブキーが欠落している（その枠のみ初期化）

`claude-cache.json` / `codex-cache.json` と `notify-state.json` は別々の atomic write のため、プロセス中断で不整合が生じる可能性がある。これは次回の `refresh.sh` 実行で自然に収束するため、追加のロックや整合性チェックは不要。

対象状態はサービスごと・枠ごとの4組:

- `claude.five_hour`
- `claude.seven_day`
- `codex.five_hour`
- `codex.seven_day`

### 7.1 リセット通知

状態:

```text
Armed       reset_notified=false, 前回値が NOTIFY_THRESHOLD 以上なら通知可能
Notified    reset_notified=true,  現在の低水準状態は通知済み
Rearmed     使用率が NOTIFY_THRESHOLD 以上に戻り reset_notified=false
```

遷移:

```text
初回
  previous_used_percent=null
  → last_seen_used_percent を保存して通知なし

Armed
  previous_used_percent >= NOTIFY_THRESHOLD
  かつ current_used_percent <= NOTIFY_FLOOR
  → リセット通知
  → reset_notified=true
  → reset_notified_at=now
  → RESET_HOOK が実行可能なら通知後に呼ぶ（5時間枠・週枠どちらも対象、FR-7-4）

Notified
  current_used_percent < NOTIFY_THRESHOLD
  → reset_notified=true のまま維持

Notified
  current_used_percent >= NOTIFY_THRESHOLD
  → reset_notified=false
  → reset_notified_at=null
  → 次回リセット通知可能
```

状態更新と通知判定の順序（実装者が `previous=current` にしてしまうミスを防ぐため明示）:

```text
1. current_used_percent を取得（キャッシュ読み込み済みの今回値）
2. previous_used_percent = state.previous_used_percent を読む（前回保存値）
3. 通知判定を行う（上記遷移に従い、previous と current を比較）
4. 通知・hook 実行（必要なら）
5. state.previous_used_percent = current_used_percent に更新して保存
```

つまり、current を previous に書き戻すのは通知判定の**後**。

通知文:

```text
Claude 5h リセット: 78% → 4%
Codex 7d リセット: 83% → 2%
```

### 7.2 高使用率通知

状態:

```text
Below       warn_notified=false, current < WARN_THRESHOLD
Warned      warn_notified=true,  current >= WARN_THRESHOLD を通知済み
```

遷移:

```text
Below
  current_used_percent >= WARN_THRESHOLD
  → 高使用率通知
  → warn_notified=true
  → warn_notified_at=now

Warned
  current_used_percent >= WARN_THRESHOLD
  → 通知なし

Warned
  current_used_percent < WARN_THRESHOLD
  → warn_notified=false
  → warn_notified_at=null
```

通知文:

```text
Claude 5h枠 警告: 82%
Codex 7d枠 警告: 91%
```

### 7.3 通知実行

`osascript` は `REQUEST_TIMEOUT` で制限する。`RESET_HOOK` は `HOOK_TIMEOUT`（既定: 60秒）で別途制限する。hook が重い処理（idle-agent 起動等）をする場合は `HOOK_TIMEOUT` を引き上げて対応する。通知・hook の失敗は usage キャッシュ更新の失敗にしないが、ログへ残す。

```bash
osascript -e 'display notification "Claude 5h枠 警告: 82%" with title "claude-codex-usage" sound name "Ping"'
```

`RESET_HOOK` は次の引数で呼ぶ。

```text
$RESET_HOOK <service> <window> <previous_percent> <current_percent>
```

例:

```text
/path/to/hook claude five_hour 78 4
```

hook が存在しない、または実行権限がない場合はスキップしてログに残す。

`osascript` 通知が失敗しても `RESET_HOOK` の呼び出しは行う（通知の成否と hook は独立。hook は副作用（idle-agent 起動等）が主目的のため、通知失敗で止めない）。

## 8. `codex app-server` 接続管理

`sleep 6` 固定待ちは廃止する。`codex app-server` を起動し、JSON-RPC の `account/rateLimits/read` 応答を readiness とみなす。

### 8.1 通信方針

`mkfifo` で stdin 用 FIFO を作り、stdout を一時ファイルへ流す。`server_pid`・`writer_pid`・`tmp_dir` はスクリプトグローバル変数（`_codex_server_pid` 等）に格納し、シグナル受信時の cleanup ハンドラから参照できるようにする。

```bash
# グローバル変数（fetch_codex_once の外で宣言）
_codex_server_pid=""
_codex_writer_pid=""
_codex_tmp_dir=""
```

```bash
_codex_tmp_dir="$CACHE_DIR/tmp/codex.$$.$RANDOM"
mkdir -p "$_codex_tmp_dir" || return 1
in_fifo="$_codex_tmp_dir/in"
server_out="$_codex_tmp_dir/out"
mkfifo "$in_fifo" || return 1
: >"$server_out"   # jq が空ファイルを読む前に必ず存在させる

codex app-server <"$in_fifo" >"$server_out" 2>"$_codex_tmp_dir/err" &
_codex_server_pid=$!

# codex app-server は initialize が完了してから account/* メソッドを処理する。
# 両リクエストを同時送信するとタイムアウトになるため、
# 3 秒の固定 sleep でシーケンシャルに送信する。
# ライターが終了しても FIFO がクローズされないよう、
# 最後に REQUEST_TIMEOUT 秒間 sleep して FIFO を開いたままにする。
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-codex-usage","version":"1.0"}}}'
  sleep 3
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
  sleep "$REQUEST_TIMEOUT"
} >"$in_fifo" &
_codex_writer_pid=$!
```

### 8.2 readiness 判定

`REQUEST_TIMEOUT + 5` 秒まで 0.1 秒刻みで `server_out` を確認する。+5 秒は initialize 送信から rateLimits 送信までの 3 秒固定 sleep のオーバーヘッドを吸収するバッファ。タイムアウト判定は `$SECONDS`（bash 組み込み変数・bash 3.2 対応）で行い、サブシェル生成を避ける。

```bash
codex_deadline=$(( REQUEST_TIMEOUT + 5 ))
start_seconds=$SECONDS
result=""
while [ $(( SECONDS - start_seconds )) -le "$codex_deadline" ]; do
  result="$(jq -c 'select(.id == 2) | .result.rateLimits // empty' "$server_out" 2>/dev/null | tail -n 1)"
  [ -n "$result" ] && break
  kill -0 "$_codex_server_pid" 2>/dev/null || break
  sleep 0.1
done
```

### 8.3 タイムアウト時の掃除

`cleanup_codex_server` 関数がグローバル変数を参照する。`trap` で `main` の先頭に登録し、シグナル受信時でもプロセスリークしない。

```bash
cleanup_codex_server() {
  [ -n "$_codex_writer_pid" ] && kill "$_codex_writer_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && kill "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && wait "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_tmp_dir" ]    && rm -rf "$_codex_tmp_dir" 2>/dev/null
}

# main() の先頭で登録する
trap 'cleanup_codex_server; exit 130' INT    # Ctrl+C (128+2)
trap 'cleanup_codex_server; exit 143' TERM   # kill (128+15)
trap 'cleanup_codex_server'           EXIT   # 通常終了・上記シグナル後の共通後処理
```

`codex app-server` が SIGTERM を無視した場合は `kill -9` にフォールバックする。

```bash
kill "$_codex_server_pid" 2>/dev/null
sleep 1
kill -0 "$_codex_server_pid" 2>/dev/null && kill -9 "$_codex_server_pid" 2>/dev/null
wait "$_codex_server_pid" 2>/dev/null
```

fetch 完了後（成功・失敗どちらも）はグローバル変数をクリアする。

```bash
_codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
```

## 9. エラー処理と stale 表示

取得失敗時:

1. 既存キャッシュを読む。
2. usage 関連フィールドは変更しない。
3. `updated_at=now` と `last_error={...}` を設定する。
4. `fetched_at` は最後の成功時刻のまま維持する。

tmux 表示:

- `last_error` がある場合は `ERR` を出す。
- stale 判定は `fetched_at` 基準で行う。失敗で `updated_at` が新しくなっても、古い usage 値であることを隠さない。

## 10. テスト方針

テストは `test/test.sh` に集約し、bash + jq のみで実行する。外部 API を叩くテストは既定では行わない。

対象:

- JSON 正規化: Claude / Codex のサンプルレスポンスからキャッシュスキーマへ変換できる。
- 失敗時更新: usage 値を維持し、`last_error` だけ更新する。
- 通知状態: リセット通知・高使用率通知・フラグ解除条件。
- tmux 表示: キャッシュなし、正常、ERR、stale、狭幅。
- plist 生成: `REFRESH_INTERVAL=60` / `120` で `StartCalendarInterval` が期待分を生成する。
- bash 構文: `/bin/bash -n refresh.sh tmux-usage.sh install.sh uninstall.sh test/test.sh`

手動確認:

- `install.sh` 実行後に `launchctl print gui/$(id -u)/com.claude-codex-usage.refresh` でロード確認。
- `launchctl kickstart -k gui/$(id -u)/com.claude-codex-usage.refresh` で初回取得。
- tmux で `status-right` 表示確認。
- macOS 通知権限とサウンド確認。

## 11. 未決事項への回答

| ID | 設計上の回答 |
|---|---|
| U1 | `sleep 6` は廃止する。`codex app-server` の stdout を監視し、JSON-RPC id=2 の `result.rateLimits` を受け取った時点で readiness 成功とする。`REQUEST_TIMEOUT` 超過時は writer/server 子プロセスを kill して掃除する |
| U3 | `install.sh` が PATH を自動検出する。`command -v jq curl codex` の親ディレクトリと macOS 標準 PATH を重複除去して plist に書く。ユーザー入力は不要 |
| U4 | unit 相当のシェルテストを作る。外部 API は mock JSON / 一時ディレクトリで検証し、LaunchAgent と通知だけ手動チェックを残す |
| U9 | `notify-state.json` は `services.<service>.<window>` 配下に `previous_used_percent`、`last_seen_used_percent`、`reset_notified`、`reset_notified_at`、`warn_notified`、`warn_notified_at` を持つスキーマで確定する |
| U10 | 設計全体で bash 3.2 互換を守る。連想配列、`mapfile`、GNU `timeout`、GNU `date`、GNU coreutils 拡張は使わない。構造化データは jq、リスト処理は改行区切り文字列と while/read で扱う |

## 12. 実装時の注意

- シークレット・トークンをログ、キャッシュ、通知、エラー文に出さない。
- `security find-generic-password` と `~/.claude/.credentials.json` の読込失敗は `auth` エラーに正規化する。
- `jq` の parse エラーは `parse` エラーに正規化する。
- `tmux-usage.sh` は `set -e` を使わず、壊れたキャッシュでも表示を返す。
- `refresh.sh` は `set -u` は使ってよいが、未設定環境変数はすべて `${VAR:-}` で扱う。
- `install.sh` は既存 `config.sh` を上書きしない。
- `.gitignore` に `*-cache.json` とローカルログを含める。ただし実際のキャッシュはリポジトリ外に置く。
