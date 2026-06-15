# Claude and Codex Usage Statusline

**English** | [日本語](#日本語)

A lightweight Claude Code status line that shows Claude (Anthropic) and Codex (OpenAI/ChatGPT) plan usage.

```text
🤖 Opus │ ✳️ Claude ▏█████░░░░░ 51% ↻2h13m (週 6%) │ ⬢ Codex ▏█░░░░░░░░░ 6% ↻4h44m (週 14%)
```

The label `週` means "weekly": the bar and reset timer show the five-hour window, while the percentage in parentheses shows weekly usage.

## Features
- Shows each five-hour allowance as a bar, percentage, and time until reset
- Shows weekly usage as a compact percentage in parentheses
- Colors usage green through 50%, yellow through 80%, and red above 80%
- Displays both Claude and Codex plan usage in one status line
- Keeps rendering lightweight and non-blocking by refreshing slow data in the background

## Requirements
- macOS
- Bash
- [`jq`](https://jqlang.github.io/jq/)
- `curl`
- [Codex CLI](https://github.com/openai/codex), installed and signed in
- Claude Code, signed in to a Pro or Max plan

This tool currently requires macOS because it reads Claude credentials from Keychain and uses BSD `date -j`. Linux support requires adjustments to credential lookup and date parsing.

## Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/Takumi00Nine/usage-statusline.git
   cd usage-statusline
   ```
2. Make the scripts executable:
   ```bash
   chmod +x *.sh
   ```
3. Add a `statusLine` entry to `~/.claude/settings.json`. Set `command` to the absolute path where you cloned the repository:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/absolute/path/to/usage-statusline/statusline.sh",
       "padding": 0
     }
   }
   ```
Merge the `statusLine` key into your existing settings object if the file already contains other settings. The first render may show `--` until the background refresh finishes.

## How It Works
`statusline.sh` is called by Claude Code and always returns quickly. Both Claude and Codex usage are displayed from background-refreshed caches with a five-minute TTL, so the values keep advancing even while idle.

Claude Code only updates the usage data on statusline stdin when you submit a prompt, so it cannot drive a continuously updating display on its own. Instead, Claude usage refreshes through the unofficial Claude OAuth usage endpoint:
```text
https://api.anthropic.com/api/oauth/usage
```
The Claude OAuth token is read from macOS Keychain first, then from `~/.claude/.credentials.json`. The response is stored in `claude-cache.json`. The stdin fields are still used for instant updates the moment you submit a prompt:
- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at` as an epoch timestamp
- `rate_limits.seven_day.used_percentage`

A new prompt is detected by comparing the stdin values against the last signature saved in `claude-input.sig`. When it changes, the stdin value is shown immediately and a refresh is triggered; otherwise the display comes from `claude-cache.json`. The result is that Claude usage updates every five minutes while idle and instantly on each prompt.

For Codex, `refresh.sh` starts `codex app-server` in the background and sends the JSON-RPC method `account/rateLimits/read`. Its response is stored in `codex-cache.json`.

Caches have a five-minute TTL. Refreshes use `flock` when available and an atomic `mkdir` lock on standard macOS installations. Statusline rendering never waits for network or app-server refreshes.

## Caveats
- The Claude OAuth endpoint and Codex app-server JSON-RPC method are unofficial and undocumented. Updates to either CLI may break this tool without notice.
- Claude usage targets Pro/Max subscriptions. Codex usage targets the rate limits associated with a ChatGPT subscription.
- Cache files (`*-cache.json`) and `claude-input.sig` contain plan and usage data. They are excluded from Git by `.gitignore` and should not be committed.

## Troubleshooting
### Values stay at `--`
Confirm that Claude Code and Codex CLI are signed in. The relevant unofficial endpoint or JSON-RPC response may also have changed.
### Colors do not appear
Confirm that your terminal and Claude Code status line render ANSI color escape sequences. Also verify that the reported values are numeric percentages.
### Values are stale
Both caches refresh only after the status line runs and notices a missing or expired (older than five minutes) cache. Render the status line again, or refresh manually:
```bash
/absolute/path/to/usage-statusline/refresh.sh codex
/absolute/path/to/usage-statusline/refresh.sh claude
```

## License
MIT. See [LICENSE](LICENSE).

## 日本語

Claude（Anthropic）と Codex（OpenAI/ChatGPT）のプラン使用量を表示する、軽量な Claude Code ステータスラインです。

```text
🤖 Opus │ ✳️ Claude ▏█████░░░░░ 51% ↻2h13m (週 6%) │ ⬢ Codex ▏█░░░░░░░░░ 6% ↻4h44m (週 14%)
```

ラベル `週` は週次を意味します。バーとリセットタイマーは5時間枠を示し、括弧内のパーセンテージは週次使用量を示します。

## 機能
- 各5時間枠を、バー、パーセンテージ、リセットまでの時間で表示
- 週次使用量を括弧内にコンパクトなパーセンテージで表示
- 使用量が50%以下の場合は緑、80%以下の場合は黄、80%を超える場合は赤で表示
- Claude と Codex のプラン使用量を1つのステータスラインに表示
- 時間のかかるデータ更新をバックグラウンドで行い、軽量かつノンブロッキングな表示を維持

## 必要環境
- macOS
- Bash
- [`jq`](https://jqlang.github.io/jq/)
- `curl`
- [Codex CLI](https://github.com/openai/codex)（インストール済みかつサインイン済み）
- Claude Code（Pro または Max プランにサインイン済み）

このツールは Claude の認証情報を Keychain から読み取り、BSD `date -j` を使用するため、現在は macOS が必要です。Linux をサポートするには、認証情報の検索と日付解析を調整する必要があります。

## インストール
1. リポジトリをクローンします:
   ```bash
   git clone https://github.com/Takumi00Nine/usage-statusline.git
   cd usage-statusline
   ```
2. スクリプトを実行可能にします:
   ```bash
   chmod +x *.sh
   ```
3. `~/.claude/settings.json` に `statusLine` エントリを追加します。`command` には、リポジトリをクローンした場所の絶対パスを設定します:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/absolute/path/to/usage-statusline/statusline.sh",
       "padding": 0
     }
   }
   ```
ファイルに他の設定がすでに含まれている場合は、既存の設定オブジェクトに `statusLine` キーをマージしてください。バックグラウンド更新が完了するまで、初回表示では `--` と表示される場合があります。

## 仕組み
`statusline.sh` は Claude Code から呼び出され、常にすばやく応答します。Claude と Codex の使用量は、いずれも TTL 5分のバックグラウンド更新キャッシュから表示するため、アイドル中でも値が更新され続けます。

Claude Code がステータスラインの stdin に渡す使用量データは、プロンプトを送信したときにしか更新されません。そのため、それ単体では継続的に更新される表示を作れません。代わりに Claude の使用量は、非公式の Claude OAuth 使用量エンドポイント経由で更新します:
```text
https://api.anthropic.com/api/oauth/usage
```
Claude OAuth トークンは、最初に macOS Keychain、次に `~/.claude/.credentials.json` から読み取られます。レスポンスは `claude-cache.json` に保存されます。プロンプト送信直後の即時更新には、引き続き stdin の次のフィールドを使用します:
- `rate_limits.five_hour.used_percentage`
- エポックタイムスタンプとしての `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`

新しいプロンプトの検出は、stdin の値を `claude-input.sig` に保存した前回のシグネチャと比較して行います。変化していれば stdin の値を即座に表示し、更新もトリガーします。変化していなければ `claude-cache.json` から表示します。これにより Claude の使用量は、アイドル中は5分ごと、プロンプトごとには即座に更新されます。

Codex については、`refresh.sh` がバックグラウンドで `codex app-server` を起動し、JSON-RPC メソッド `account/rateLimits/read` を送信します。そのレスポンスは `codex-cache.json` に保存されます。

キャッシュの TTL は5分です。更新処理は、利用可能な場合は `flock` を使用し、標準的な macOS 環境ではアトミックな `mkdir` ロックを使用します。ステータスラインの表示がネットワークまたは app-server の更新を待つことはありません。

## 注意事項
- Claude OAuth エンドポイントと Codex app-server の JSON-RPC メソッドは非公式かつ文書化されていません。いずれかの CLI が更新されると、予告なくこのツールが動作しなくなる可能性があります。
- Claude の使用量は Pro/Max サブスクリプションを対象とします。Codex の使用量は ChatGPT サブスクリプションに関連付けられたレート制限を対象とします。
- キャッシュファイル（`*-cache.json`）と `claude-input.sig` にはプランと使用量のデータが含まれます。これらは `.gitignore` によって Git から除外されており、コミットしないでください。

## トラブルシューティング
### 値が `--` のまま変わらない
Claude Code と Codex CLI にサインインしていることを確認してください。関連する非公式エンドポイントまたは JSON-RPC レスポンスが変更されている可能性もあります。
### 色が表示されない
ターミナルと Claude Code のステータスラインが ANSI カラーエスケープシーケンスを表示できることを確認してください。また、報告された値が数値のパーセンテージであることも確認してください。
### 値が古い
どちらのキャッシュも、ステータスラインが実行され、キャッシュが存在しないか期限切れ（5分より古い）であることを検出した後にのみ更新されます。ステータスラインをもう一度表示するか、手動で更新してください:
```bash
/absolute/path/to/usage-statusline/refresh.sh codex
/absolute/path/to/usage-statusline/refresh.sh claude
```

## ライセンス
MIT。詳しくは [LICENSE](LICENSE) を参照してください。
