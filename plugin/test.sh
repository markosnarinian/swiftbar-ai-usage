#!/bin/bash
# Offline contract checks. Never reads real credentials or changes live history.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
SOURCE=$(cd "$(dirname "$0")" && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
export HOME="$TEMP"
ROOT="$HOME/.local/share/swiftbar-usage"
CACHE="$HOME/.cache/swiftbar-usage"
mkdir -p "$ROOT" "$CACHE" "$HOME/.config/swiftbar-usage"
cp "$SOURCE/usage.sh" "$SOURCE/normalize.jq" "$ROOT/"
printf 'SERVICES="codex claude amp"\n' > "$HOME/.config/swiftbar-usage/config"
cat <<'JSON' | jq --arg provider codex -f "$ROOT/normalize.jq" > "$CACHE/codex.json"
{"rate_limit":{"primary_window":{"used_percent":17,"limit_window_seconds":604800,"reset_at":1800000000},"secondary_window":null}}
JSON
jq -e '.limits | length == 1 and .[0].remaining == 83 and .[0].window == 604800 and .[0].label == "ChatGPT weekly"' "$CACHE/codex.json" >/dev/null
# Existing caches retain their old labels until the next successful request.
jq '.limits[0].label = "Codex weekly"' "$CACHE/codex.json" > "$CACHE/codex.tmp"
mv "$CACHE/codex.tmp" "$CACHE/codex.json"
cat <<'JSON' | jq --arg provider claude -f "$ROOT/normalize.jq" > "$CACHE/claude.json"
{"five_hour":{"utilization":100,"resets_at":"2027-01-15T08:00:00.123456+00:00"},"seven_day":{"utilization":0,"resets_at":null},"seven_day_opus":{"utilization":31,"resets_at":null},"seven_day_sonnet":null}
JSON
jq -e '.limits | length == 3 and .[0].remaining == 0 and .[0].reset == 1800000000 and .[1].remaining == 100 and .[2].remaining == 69' "$CACHE/claude.json" >/dev/null
cat <<'TEXT' | jq -Rs --arg provider amp -f "$ROOT/normalize.jq" > "$CACHE/amp.json"
**Amp Megawatt Tier:** agent usage $2.30 of $10.00 remaining (23%), orb usage 74h of 750h a1.small orb hours remaining (10%) - period 2026-10-27 to 2026-11-27
**Individual credits:** $2.94 remaining - https://ampcode.com/settings
**Workspace example:** $7.18 remaining - https://ampcode.com/workspaces/example
TEXT
jq -e '.limits[0].remaining == 23 and .limits[1].remaining == 10 and .balances[0].amount == 2.94 and .balances[1].amount == 7.18' "$CACHE/amp.json" >/dev/null
if printf '{}' | jq --arg provider codex -f "$ROOT/normalize.jq" >/dev/null 2>&1; then echo 'FAIL: empty response accepted'; exit 1; fi

NOW=$(date +%s)
echo "$NOW" > "$CACHE/updated"
sqlite3 "$CACHE/history.sqlite" 'CREATE TABLE samples (at INTEGER, provider TEXT, id TEXT, remaining REAL, reset INTEGER, PRIMARY KEY(at,provider,id));'
for p in codex claude amp; do
  jq -r --arg p "$p" --argjson at "$NOW" '.limits[] | "INSERT INTO samples VALUES(\($at),\u0027\($p)\u0027,\u0027\(.id)\u0027,\(.remaining),\(.reset // "NULL"));"' "$CACHE/$p.json" | sqlite3 "$CACHE/history.sqlite"
done
# A reset, a normal interval, and a missing-data gap must not become a diagonal across time.
sqlite3 "$CACHE/history.sqlite" "INSERT INTO samples VALUES($((NOW-600)),'claude','claude_five_hour',12,1799990000); INSERT INTO samples VALUES($((NOW-540)),'claude','claude_five_hour',96,1800000000); INSERT INTO samples VALUES($((NOW-480)),'claude','claude_five_hour',92,1800000000);"
"$ROOT/usage.sh" > "$TEMP/menu"
head -1 "$TEMP/menu" | grep -q 'ChatGPT wk 83% (.*Claude 5h 0% (.* / wk 100% (.* / wk opus 69% (.*Amp agent 23% (~.* / orb 10% (~'
grep -q '^ChatGPT | href=' "$TEMP/menu"
if grep -q 'Codex' "$TEMP/menu"; then exit 1; fi
if head -1 "$TEMP/menu" | grep -Fq '\n'; then echo 'FAIL: multiline menu bar'; exit 1; fi
test "$(grep -Ec '^Reset(s in| unavailable).*textonly=true' "$TEMP/menu")" = 6
test "$(grep -c ' | href=' "$TEMP/menu")" = 3
if grep -Eq 'image=|Refresh now|Last collection|History starts|90-day retention|Separate layout|time not supplied|↻|✕|color=black,white' "$TEMP/menu"; then exit 1; fi
sed -n 's/.*nativechart=//p' "$TEMP/menu" | base64 -D > "$TEMP/chart.json"
jq -e '.series | length == 6' "$TEMP/chart.json" >/dev/null
jq -e '.series[] | select(.provider == "codex") | .label == "ChatGPT weekly"' "$TEMP/chart.json" >/dev/null
jq -e '[.series[] | select(.id == "claude_five_hour") | .points[].segment] | unique | length == 3' "$TEMP/chart.json" >/dev/null
jq -e '[.series[].span] | unique == [18000,604800]' "$TEMP/chart.json" >/dev/null
# A first-run failure has no readings to show.
cp "$CACHE/claude.json" "$TEMP/claude-good.json"
printf '{"error":"HTTP 401 — sign in again", "limits":[],"balances":[]}' > "$CACHE/claude.json"
"$ROOT/usage.sh" > "$TEMP/error-menu"
head -1 "$TEMP/error-menu" | grep -q 'Claude unavailable'
grep -q 'HTTP 401' "$TEMP/error-menu"
# Exercise pruning through the normal entrypoint, with every provider backed off
# so this remains offline. Both sides of the 90-day boundary matter.
sqlite3 "$CACHE/history.sqlite" "INSERT INTO samples VALUES($((NOW-7776001)),'codex','old',11,0); INSERT INTO samples VALUES($((NOW-7775940)),'codex','keep',22,0);"
for p in codex claude amp; do echo $((NOW+300)) > "$CACHE/$p.retry"; done
echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > "$TEMP/backoff-menu"
test "$(sqlite3 "$CACHE/history.sqlite" "SELECT count(*) FROM samples WHERE id='old';")" = 0
test "$(sqlite3 "$CACHE/history.sqlite" "SELECT count(*) FROM samples WHERE id='keep';")" = 1

# Exercise HTTP failures through the public entrypoint, without real credentials
# or network calls. Previously observed values must not become new samples.
cp "$TEMP/claude-good.json" "$CACHE/claude.json"
sqlite3 "$CACHE/history.sqlite" "UPDATE samples SET at=at-60 WHERE provider='claude';"
export MOCK_HTTP_STATUS=429 MOCK_RETRY_AFTER=900
security() { printf '{"claudeAiOauth":{"accessToken":"test-only"}}'; }
curl() {
  cat >/dev/null
  echo called >> "$HOME/curl-calls"
  while (( $# )); do
    case $1 in
      -D) printf 'HTTP/2 %s\r\nRetry-After: %s\r\n\r\n' "$MOCK_HTTP_STATUS" "$MOCK_RETRY_AFTER" > "$2"; shift;;
      -o) printf '{"five_hour":{"utilization":43,"resets_at":null}}' > "$2"; shift;;
    esac
    shift
  done
  printf '%s' "$MOCK_HTTP_STATUS"
}
export -f security curl
count=$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')
echo 0 > "$CACHE/claude.retry"; echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > "$TEMP/rate-menu"
head -1 "$TEMP/rate-menu" | grep -q 'Claude cached 5h 0%'
jq -e '.error != null and (.limits | length == 3)' "$CACHE/claude.json" >/dev/null
test "$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')" = "$count"
test "$(cat "$CACHE/claude.retry")" -ge "$((NOW+900))"
sed -n 's/.*nativechart=//p' "$TEMP/rate-menu" | base64 -D | jq -e '[.series[] | select(.provider == "claude")] | length == 3' >/dev/null
echo 0 > "$CACHE/claude.retry"; echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > /dev/null
test "$(cat "$CACHE/claude.backoff")" = 600
MOCK_RETRY_AFTER=$(LC_ALL=C date -u -r "$((NOW+7200))" '+%a, %d %b %Y %H:%M:%S GMT')
echo 0 > "$CACHE/claude.retry"; echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > /dev/null
test "$(cat "$CACHE/claude.retry")" = "$((NOW+7200))"
MOCK_HTTP_STATUS=200
echo 0 > "$CACHE/claude.retry"; echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > "$TEMP/recovered-menu"
jq -e '.error == null and .limits[0].remaining == 57 and .observedAt != null' "$CACHE/claude.json" >/dev/null
test ! -e "$CACHE/claude.backoff"
test "$(cat "$CACHE/claude.retry")" -ge "$((NOW+300))"
calls=$(wc -l < "$HOME/curl-calls")
echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > /dev/null
test "$(wc -l < "$HOME/curl-calls")" = "$calls"
printf 'PASS: all limits/resets in combined title, full names, native chart data, reset/gap segments, readable rows, hidden controls, error state, retention and backoff\n'
