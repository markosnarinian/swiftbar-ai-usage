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
# Full history includes observations older than both former display windows,
# but never extends beyond retention, even before collection prunes the DB.
sqlite3 "$CACHE/history.sqlite" "INSERT INTO samples VALUES($((NOW-864000)),'codex','codex_604800',64,1799990000); INSERT INTO samples VALUES($((NOW-21600)),'claude','claude_five_hour',37,1799990000); INSERT INTO samples VALUES($((NOW-7862400)),'codex','codex_604800',3,1799990000);"
sqlite3 "$CACHE/history.sqlite" "INSERT INTO samples VALUES($((NOW-863940)),'codex','codex_604800',67,1799990000); INSERT INTO samples VALUES($((NOW-863880)),'codex','codex_604800',62,1799990000); INSERT INTO samples VALUES($((NOW-863820)),'codex','codex_604800',65,1799990000);"
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
jq -e '.series[] | select(.id == "claude_five_hour") | [.points[].reset] | index(1799990000) != null and index(1800000000) != null' "$TEMP/chart.json" >/dev/null
jq -e '.series[] | select(.provider == "codex") | .label == "ChatGPT weekly"' "$TEMP/chart.json" >/dev/null
jq -e '[.series[] | select(.id == "claude_five_hour") | .points[].segment] | unique | length == 4' "$TEMP/chart.json" >/dev/null
jq -e --argjson earliest "$((NOW-864000))" '.now as $now | [.series[].span] | unique == [$now-$earliest]' "$TEMP/chart.json" >/dev/null
jq -e '[.series[] | select(.provider == "codex") | .points[].remaining] | index(64) != null and index(65) != null and index(67) != null and index(62) != null and index(3) == null' "$TEMP/chart.json" >/dev/null
jq -e '[.series[] | select(.id == "claude_five_hour") | .points[].remaining] | index(37) != null' "$TEMP/chart.json" >/dev/null
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
head -1 "$TEMP/rate-menu" | grep -q 'Claude stale 5h 0%'
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
# Opening bypasses the minute cache, but not provider cooldowns. Mock the
# refresh URL so no installed app is contacted by this offline test.
open() { printf '%s\n' "$*" >> "$HOME/refresh-calls"; }
export -f open
wait_for_refresh() {
  local attempt
  for attempt in {1..100}; do
    [[ ! -f $HOME/refresh-calls ]] || return 0
    sleep 0.05
  done
  echo 'FAIL: menu-open collector did not publish' >&2
  return 1
}
echo 0 > "$CACHE/claude.retry"
date +%s > "$CACHE/updated"
SWIFTBAR_PLUGIN_REFRESH_REASON=MenuOpen "$ROOT/usage.sh" > "$TEMP/open-menu"
wait_for_refresh
test "$(wc -l < "$HOME/curl-calls")" -eq "$((calls+1))"
grep -q 'swiftbar://refreshplugin?name=usage.1m.sh' "$HOME/refresh-calls"
rm "$HOME/refresh-calls"
SWIFTBAR_PLUGIN_REFRESH_REASON=MenuOpen "$ROOT/usage.sh" > /dev/null
wait_for_refresh
test "$(wc -l < "$HOME/curl-calls")" -eq "$((calls+1))"
# A concurrent open must leave the existing collector and its refresh alone.
rm "$HOME/refresh-calls"
mkdir "$CACHE/lock"; echo $$ > "$CACHE/lock/pid"
"$ROOT/usage.sh" collect
test ! -f "$HOME/refresh-calls"
test "$(wc -l < "$HOME/curl-calls")" -eq "$((calls+1))"
rm -rf "$CACHE/lock"
# Failed refreshes retain the last successful observation, labeled stale.
MOCK_HTTP_STATUS=429
echo 0 > "$CACHE/claude.retry"; echo 0 > "$CACHE/updated"
"$ROOT/usage.sh" > "$TEMP/stale-menu"
grep -q '^Stale reading · ' "$TEMP/stale-menu"
if grep -qi cached "$TEMP/stale-menu"; then exit 1; fi
# The opt-in website source stays live during an OAuth cooldown, verifies the
# account, and stores the website's observation time rather than inventing one.
printf 'SERVICES="claude"\nCLAUDE_SOURCE=web\n' > "$HOME/.config/swiftbar-usage/config"
printf '{"oauthAccount":{"emailAddress":"test@example.com","organizationName":"Personal"}}' > "$HOME/.claude.json"
jq -n --arg at "$(date -u -r "$((NOW-10))" '+%Y-%m-%dT%H:%M:%SZ')" '[{
  provider:"claude",source:"web",rateWindowLabels:{tertiary:"Sonnet"},usage:{
    accountEmail:"TEST@example.com",accountOrganization:"Personal",updatedAt:$at,
    primary:{usedPercent:7,windowMinutes:300,resetsAt:"2027-01-15T08:00:00Z"},
    secondary:{usedPercent:38,windowMinutes:10080,resetsAt:null},
    tertiary:{usedPercent:19,windowMinutes:10080,resetsAt:null},
    extraRateWindows:[{id:"weekly-opus",title:"Weekly Opus",window:{usedPercent:31,windowMinutes:10080,resetsAt:null}},
      {id:"unknown",title:"Unknown",usageKnown:false,window:{usedPercent:100,windowMinutes:10080}}]
  }}]' > "$HOME/web-good.json"
cp "$HOME/web-good.json" "$HOME/web-response.json"
codexbar() {
  [[ $* == 'usage --provider claude --source web --format json --no-credits --web-timeout 20' ]] || return 99
  echo called >> "$HOME/web-calls"
  cat "$HOME/web-response.json"
  return "${MOCK_WEB_EXIT:-0}"
}
export -f codexbar
calls=$(wc -l < "$HOME/curl-calls")
oauth_retry=$(cat "$CACHE/claude.retry")
"$ROOT/usage.sh" collect
jq -e --argjson at "$((NOW-10))" '.source == "web" and .observedAt == $at and .error == null and [.limits[].remaining] == [93,62,81,69]' "$CACHE/claude.json" >/dev/null
test "$(sqlite3 "$CACHE/history.sqlite" "SELECT remaining FROM samples WHERE provider='claude' AND id='claude_five_hour' AND at=$((NOW-10));")" = 93.0
"$ROOT/usage.sh" collect
test "$(wc -l < "$HOME/web-calls")" -eq 2
test "$(wc -l < "$HOME/curl-calls")" = "$calls"
test "$(cat "$CACHE/claude.retry")" = "$oauth_retry"
count=$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')
for mutation in '.[0].usage.accountEmail = "other@example.com"' '.[0].usage.accountOrganization = "Other"' '.[0].source = "codexbar-app"' '.[0].usage.updatedAt = "2020-01-01T00:00:00Z"' '.[0].usage.primary.usedPercent = "invalid"'; do
  jq "$mutation" "$HOME/web-good.json" > "$HOME/web-response.json"
  rm -f "$CACHE/claude-web.retry"
  "$ROOT/usage.sh" collect
  jq -e '.error != null and .limits[0].remaining == 93' "$CACHE/claude.json" >/dev/null
  test "$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')" = "$count"
done
cp "$HOME/web-good.json" "$HOME/web-response.json"
export MOCK_WEB_EXIT=1
rm -f "$CACHE/claude-web.retry"
"$ROOT/usage.sh" collect
jq -e '.error != null and .limits[0].remaining == 93' "$CACHE/claude.json" >/dev/null
test "$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')" = "$count"
calls=$(wc -l < "$HOME/web-calls")
"$ROOT/usage.sh" collect
test "$(wc -l < "$HOME/web-calls")" = "$calls"
test ! -e "$CACHE/claude-web.raw"
test ! -e "$CACHE/claude.json.tmp"
# Transient transport failures recover inside a refresh. Persistent failures,
# including a partial HTTP 200, must preserve stale data rather than enter history.
printf 'SERVICES="codex"\n' > "$HOME/.config/swiftbar-usage/config"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME"
printf '{"tokens":{"access_token":"test-only","account_id":"test-account"}}' > "$CODEX_HOME/auth.json"
export MOCK_CURL_EXIT=28 MOCK_RECOVER=1 MOCK_HTTP_STATUS=000
curl() {
  cat >/dev/null
  echo called >> "$HOME/transport-calls"
  local result=$MOCK_CURL_EXIT status=$MOCK_HTTP_STATUS
  if [[ $MOCK_RECOVER == 1 && $(wc -l < "$HOME/transport-calls") -gt 1 ]]; then result=0; status=200; fi
  while (( $# )); do
    case $1 in
      -D) printf 'HTTP/2 %s\r\n\r\n' "$status" > "$2"; shift;;
      -o) printf '{"rate_limit":{"primary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_at":1800000000}}}' > "$2"; shift;;
    esac
    shift
  done
  printf '%s' "$status"
  return "$result"
}
export -f curl
rm -f "$CACHE/codex.retry"
"$ROOT/usage.sh" collect
test "$(wc -l < "$HOME/transport-calls")" -eq 2
jq -e '.error == null and .limits[0].remaining == 71' "$CACHE/codex.json" >/dev/null
count=$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')
# Make a stale timestamp distinct from this refresh to detect accidental updates.
jq --argjson at "$((NOW-120))" '.observedAt = $at' "$CACHE/codex.json" > "$CACHE/codex.tmp"
mv "$CACHE/codex.tmp" "$CACHE/codex.json"
MOCK_RECOVER=0
for code in 6 28 18 60; do
  MOCK_CURL_EXIT=$code
  MOCK_HTTP_STATUS=000
  [[ $code != 18 ]] || MOCK_HTTP_STATUS=200
  : > "$HOME/transport-calls"
  "$ROOT/usage.sh" collect
  expected=2; [[ $code != 60 ]] || expected=1
  test "$(wc -l < "$HOME/transport-calls")" -eq "$expected"
  jq -e --argjson at "$((NOW-120))" '.error != null and (.error | contains("HTTP 000") | not) and .observedAt == $at and .limits[0].remaining == 71' "$CACHE/codex.json" >/dev/null
  test "$(sqlite3 "$CACHE/history.sqlite" 'SELECT count(*) FROM samples;')" = "$count"
  test ! -e "$CACHE/codex.raw"
  test ! -e "$CACHE/codex.headers"
done
# Authentication and rate-limit responses are not transport retries.
MOCK_CURL_EXIT=0
for status in 401 429; do
  MOCK_HTTP_STATUS=$status
  : > "$HOME/transport-calls"
  "$ROOT/usage.sh" collect
  test "$(wc -l < "$HOME/transport-calls")" -eq 1
  jq -e '.error != null and .limits[0].remaining == 71' "$CACHE/codex.json" >/dev/null
done
printf 'PASS: all limits/resets in combined title, full names, native chart data, reset/gap segments, readable rows, hidden controls, error state, retention and backoff\n'
