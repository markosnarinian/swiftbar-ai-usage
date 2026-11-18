#!/bin/bash
# Shared implementation; credentials are read only and never saved in the cache.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 077
ROOT="$HOME/.local/share/swiftbar-usage"
CACHE="$HOME/.cache/swiftbar-usage"
CONFIG="$HOME/.config/swiftbar-usage/config"
mkdir -p "$CACHE"
SERVICES="codex claude amp"
# shellcheck source=/dev/null
source "$CONFIG"
SELF="$ROOT/usage.sh"
DB="$CACHE/history.sqlite"
NOW=$(date +%s)

MODE=${1:-menu}
for dep in jq curl sqlite3; do
  command -v "$dep" >/dev/null || { printf 'Usage unavailable\n---\nMissing dependency: %s\n' "$dep"; exit; }
done

error() {
  local previous='{"limits":[],"balances":[]}'
  [[ ! -f $CACHE/$1.json ]] || previous=$(cat "$CACHE/$1.json")
  jq --arg error "$2" --argjson at "$NOW" '. + {error:$error, errorAt:$at}' <<< "$previous" > "$CACHE/$1.json.tmp"
  mv "$CACHE/$1.json.tmp" "$CACHE/$1.json"
}

fetch_http() {
  local provider=$1 token account status url delay retry_after retry_at
  if [[ $provider == codex ]]; then
    token=$(jq -er '.tokens.access_token // empty' "${CODEX_HOME:-$HOME/.codex}/auth.json" 2>/dev/null) || { error codex 'Login unavailable — run codex login'; return; }
    account=$(jq -r '.tokens.account_id // empty' "${CODEX_HOME:-$HOME/.codex}/auth.json")
    url=https://chatgpt.com/backend-api/wham/usage
  else
    token=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null | jq -er '.claudeAiOauth.accessToken // empty' 2>/dev/null) || { error claude 'Login unavailable — open Claude Code and sign in; allow Keychain access'; return; }
    account=''
    url=https://api.anthropic.com/api/oauth/usage
  fi
  # Headers go through stdin, not process arguments or temporary files.
  status=$({
    printf '%s' "$token" | jq -Rs '"header = " + (("Authorization: Bearer " + .) | @json)' -r
    if [[ -n $account ]]; then printf '%s' "$account" | jq -Rs '"header = " + (("ChatGPT-Account-Id: " + .) | @json)' -r; fi
    printf 'header = "anthropic-beta: oauth-2025-04-20"\n'
  } | curl --config - --silent --show-error --connect-timeout 5 --max-time 20 \
        -H 'Accept: application/json' -A 'SwiftBar-Usage' -D "$CACHE/$provider.headers" -o "$CACHE/$provider.raw" -w '%{http_code}' "$url" 2>/dev/null)
  retry_after=$(awk 'tolower($1)=="retry-after:" {$1=""; sub(/^ /, ""); sub(/\r$/, ""); print}' "$CACHE/$provider.headers" 2>/dev/null | tail -1)
  rm -f "$CACHE/$provider.headers"
  case $status in
    200) ;;
    401|403) error "$provider" "HTTP $status — sign in again with $provider; plugin never refreshes credentials"; return ;;
    429)
      delay=$(cat "$CACHE/$provider.backoff" 2>/dev/null || echo 150)
      delay=$((delay * 2)); (( delay <= 3600 )) || delay=3600
      echo "$delay" > "$CACHE/$provider.backoff"
      retry_at=0
      if [[ $retry_after =~ ^[0-9]+$ ]]; then retry_at=$((NOW + retry_after))
      elif [[ -n $retry_after ]]; then retry_at=$(LC_ALL=C date -j -f '%a, %d %b %Y %H:%M:%S %Z' "$retry_after" +%s 2>/dev/null || echo 0); fi
      (( retry_at >= NOW + delay )) || retry_at=$((NOW + delay))
      echo "$retry_at" > "$CACHE/$provider.retry"
      error "$provider" 'Usage check paused (rate limited)'; return ;;
    *) error "$provider" "Request failed (HTTP ${status:-000}) — check connection; automatic retry"; return ;;
  esac
  if jq -e --arg provider "$provider" -f "$ROOT/normalize.jq" "$CACHE/$provider.raw" | jq --argjson at "$NOW" '. + {observedAt:$at}' > "$CACHE/$provider.json.tmp"; then
    mv "$CACHE/$provider.json.tmp" "$CACHE/$provider.json"
    rm -f "$CACHE/$provider.backoff" "$CACHE/$provider.retry"
    # Countdown rendering stays on the minute timer; Claude requests do not.
    [[ $provider != claude ]] || echo $((NOW + 300)) > "$CACHE/$provider.retry"
  else error "$provider" 'Usage response changed — parser needs updating'; fi
  rm -f "$CACHE/$provider.raw" "$CACHE/$provider.json.tmp"
}

collect() {
  sqlite3 "$DB" 'PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS samples (at INTEGER, provider TEXT, id TEXT, remaining REAL, reset INTEGER, PRIMARY KEY(at,provider,id));' >/dev/null
  local p retry pid
  for p in $SERVICES; do
    case $p in codex|claude|amp) ;; *) continue ;; esac
    retry=$(cat "$CACHE/$p.retry" 2>/dev/null || echo 0)
    if (( NOW < retry )); then continue; fi
    if [[ $p != amp ]]; then fetch_http "$p"
    else
      # Bound the CLI call, including a hung network request.
      amp usage > "$CACHE/amp.raw" 2>/dev/null & pid=$!
      (sleep 25; kill "$pid" 2>/dev/null) </dev/null >/dev/null 2>&1 & local watchdog=$!
      if wait "$pid" && jq -eRs --arg provider amp -f "$ROOT/normalize.jq" "$CACHE/amp.raw" > "$CACHE/amp.json.tmp" 2>/dev/null; then
        mv "$CACHE/amp.json.tmp" "$CACHE/amp.json"
      else error amp 'Usage unavailable — run amp usage or amp login'; fi
      kill "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true
      rm -f "$CACHE/amp.raw" "$CACHE/amp.json.tmp"
    fi
    # IDs are constrained locally; SQL never receives labels or remote text.
    jq -r --arg p "$p" --argjson at "$NOW" 'select(.error == null) | .limits[] | select(.id | test("^[a-z0-9_]+$")) | "INSERT OR REPLACE INTO samples VALUES(\($at),\u0027\($p)\u0027,\u0027\(.id)\u0027,\(.remaining),\(.reset // "NULL"));"' "$CACHE/$p.json" | sqlite3 "$DB"
  done
  sqlite3 "$DB" "DELETE FROM samples WHERE at < $((NOW - 7776000)); PRAGMA incremental_vacuum;" >/dev/null
  echo "$NOW" > "$CACHE/updated"
}

# Opening the menu must never wait for a network request on AppKit's main thread.
if [[ ${SWIFTBAR_PLUGIN_REFRESH_REASON:-} == MenuOpen && $MODE == menu ]]; then
  "$SELF" collect </dev/null >/dev/null 2>&1 &
  MODE=preview
fi

if [[ $MODE != preview ]]; then
  last=$(cat "$CACHE/updated" 2>/dev/null || echo 0)
  if (( NOW - last >= 55 )) && mkdir "$CACHE/lock" 2>/dev/null; then
    trap 'rm -rf "$CACHE/lock"; rm -f "$CACHE/"*.raw' EXIT
    echo $$ > "$CACHE/lock/pid"
    collect
    rm -f "$CACHE/"*.raw
    rm -rf "$CACHE/lock"
    trap - EXIT
  elif [[ -f $CACHE/lock/pid ]] && ! kill -0 "$(cat "$CACHE/lock/pid")" 2>/dev/null; then
    rm -rf "$CACHE/lock"
  fi
fi
if [[ $MODE == collect ]]; then
  open -g 'swiftbar://refreshplugin?name=usage.1m.sh'
  exit
fi

SELECTED=$SERVICES
files=()
for p in $SELECTED; do
  # A different entrypoint may still be collecting the first sample.
  [[ -f $CACHE/$p.json ]] || { printf 'Usage …\n---\nCollecting first readings — refresh shortly\n'; exit; }
  files+=("$CACHE/$p.json")
done
[[ ${#files[@]} -gt 0 ]] || { printf 'Usage\n---\nNo services enabled\n'; exit; }

chart() {
  local p id label span points
  local series='[]'
  for p in $SELECTED; do
    while IFS=$'\t' read -r id label span; do
      [[ $id =~ ^[a-z0-9_]+$ ]] || continue
      local range=604800 gap=180
      [[ $p != claude ]] || gap=420
      (( span > 18000 )) || range=18000
      # Preserve outages, resets, and extrema while bounding points per time bucket.
      points=$(sqlite3 -json "$DB" "WITH previous AS (
        SELECT at, remaining, reset, lag(at) OVER (ORDER BY at) AS prev_at,
          lag(reset) OVER (ORDER BY at) AS prev_reset
        FROM samples WHERE provider='$p' AND id='$id' AND at BETWEEN $((NOW-range)) AND $NOW
      ), segments AS (
        SELECT *, sum(CASE WHEN at-prev_at>$gap OR reset IS NOT prev_reset THEN 1 ELSE 0 END)
          OVER (ORDER BY at) AS segment FROM previous
      ), ranked AS (
        SELECT *, row_number() OVER (PARTITION BY segment, (at-$NOW+$range)*200/$range ORDER BY remaining,at) AS low,
          row_number() OVER (PARTITION BY segment, (at-$NOW+$range)*200/$range ORDER BY remaining DESC,at DESC) AS high
        FROM segments
      ) SELECT at,remaining,segment FROM ranked WHERE low=1 OR high=1 ORDER BY at;")
      series=$(jq -c --arg id "$id" --arg label "$label" --arg provider "$p" --argjson span "$range" --argjson points "${points:-[]}" \
        '. + [{id:$id,label:$label,provider:$provider,span:$span,points:$points}]' <<< "$series")
    done < <(jq -r '.limits[] | [.id,(.label | sub("^Codex "; "ChatGPT ")),.window] | @tsv' "$CACHE/$p.json")
  done
  local payload
  payload=$(jq -cn --argjson now "$NOW" --argjson series "$series" '{now:$now,series:$series}')
  printf 'Remaining over time | nativechart=%s\n' "$(printf '%s' "$payload" | base64 | tr -d '\n')"
}

countdown() {
  local reset=$1 provider=$2 seconds
  [[ $reset =~ ^[0-9]+$ ]] || { printf '—'; return; }
  seconds=$((reset-NOW))
  if (( seconds <= 0 )); then printf 'due'; return; fi
  if [[ $provider == amp ]]; then printf '~%sd' "$(((seconds+86399)/86400))"
  elif (( seconds >= 86400 )); then printf '%sd%sh' "$((seconds/86400))" "$((seconds/3600%24))"
  else printf '%sh%sm' "$((seconds/3600))" "$((seconds/60%60))"; fi
}

title=''
last=$(cat "$CACHE/updated" 2>/dev/null || echo 0)
for p in $SELECTED; do
  case $p in codex) name=ChatGPT;; claude) name=Claude;; amp) name=Amp;; esac
  values=''
  while IFS=$'\t' read -r label remaining reset; do
    label=${label#"$name "}; label=${label/ (monthly)/}; label=${label/weekly/wk}
    values+="${values:+ / }$label $remaining% ($(countdown "$reset" "$p"))"
  done < <(jq -r '.limits[] | [(.label | sub("^Codex "; "ChatGPT ")),(.remaining|round),(.reset // "unknown")] | @tsv' "$CACHE/$p.json")
  if [[ -n $values ]] && jq -e '.error != null' "$CACHE/$p.json" >/dev/null; then values="cached $values"; fi
  if [[ -z $values ]] || (( NOW-last>180 )); then values='unavailable'; fi
  title+="${title:+  ·  }$name $values"
done
printf '%s | size=11\n---\n' "$title"
for p in $SELECTED; do
  case $p in codex) name=ChatGPT; url=https://chatgpt.com/codex/settings/usage;; claude) name=Claude; url=https://claude.ai/settings/usage;; amp) name=Amp; url=https://ampcode.com/settings;; esac
  printf '%s | href=%s size=13\n' "$name" "$url"
  if (( NOW - last > 180 )); then printf 'Waiting for updated readings | textonly=true\n'; fi
  jq -r 'select(.error) | .error + " | textonly=true size=11"' "$CACHE/$p.json"
  if jq -e '.error != null and .observedAt != null' "$CACHE/$p.json" >/dev/null; then
    printf 'Cached reading · %s | textonly=true size=11\n' "$(date -r "$(jq -r '.observedAt' "$CACHE/$p.json")" '+%d %b %H:%M')"
  fi
  while IFS=$'\t' read -r label remaining reset span; do
    label=${label#"$name "}
    reset_text='Reset unavailable'
    if [[ $reset =~ ^[0-9]+$ ]]; then
      if [[ $p == amp ]]; then
        reset_text="Resets in $(countdown "$reset" "$p") · $(jq -r '.renewal' "$CACHE/$p.json")"
      else
        reset_text="Resets in $(countdown "$reset" "$p") · $(date -r "$reset" '+%a %d %b %H:%M')"
      fi
    fi
    printf '%s: %s%% remaining | textonly=true\n' "$label" "$remaining"
    printf '%s | textonly=true size=11\n' "$reset_text"
  done < <(jq -r '.limits[] | [(.label | sub("^Codex "; "ChatGPT ")),(.remaining|round),(.reset // "unknown"),.window] | @tsv' "$CACHE/$p.json")
  jq -r '.balances[] | "\(.label): $\(.amount) | textonly=true"' "$CACHE/$p.json"
  printf '%s\n' '---'
done
chart
