def epoch:
  if type == "number" then .
  elif type == "string" then
    try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null
  else null end;
def limit($id; $label; $remaining; $window; $reset):
  select(($remaining | type) == "number" and $remaining >= 0 and $remaining <= 100)
  | {id: $id, label: $label, remaining: $remaining, window: $window, reset: ($reset | epoch)};
if $provider == "codex" then
  [.rate_limit as $r | ["primary_window", "secondary_window"][] as $w
   | $r[$w] | select(. != null and (.used_percent | type) == "number")
   | .limit_window_seconds as $span
   | limit("codex_" + ($span | tostring); "ChatGPT " + (if $span == 18000 then "5h" elif $span == 604800 then "weekly" else ($span / 3600 | tostring) + "h" end);
           100 - .used_percent; $span; .reset_at)] as $limits
  | {limits: $limits, balances: []}
elif $provider == "claude-web" then
  .[0] as $payload | $payload.usage as $usage
  | (["primary", "secondary", "tertiary"] | map(. as $key | $usage[$key]
      | select(. != null and .isSyntheticPlaceholder != true)
      | ($payload.rateWindowLabels[$key] // "model") as $label
      | (if $key == "primary" then "five_hour"
         elif $key == "secondary" then "seven_day"
         else "seven_day_" + ($label | ascii_downcase | gsub("[^a-z0-9]+"; "_")) end) as $id
      | limit("claude_" + $id;
          (if $key == "primary" then "Claude 5h" elif $key == "secondary" then "Claude weekly" else "Claude weekly " + $label end);
          100 - .usedPercent; (.windowMinutes * 60); .resetsAt)))
    + [$usage.extraRateWindows[]? | select(.usageKnown != false and .window.isSyntheticPlaceholder != true)
       | . as $extra | .window
       | limit("claude_" + ($extra.id | ascii_downcase | gsub("[^a-z0-9]+"; "_")); "Claude " + $extra.title;
           100 - .usedPercent; (.windowMinutes * 60); .resetsAt)] as $limits
  | {limits:$limits, balances:[], observedAt:($usage.updatedAt | epoch), source:"web"}
elif $provider == "claude" then
  [to_entries[] | select(.key | test("^(five_hour|seven_day.*)$"))
   | select(.value != null and (.value.utilization | type) == "number")
   | limit("claude_" + .key; "Claude " + (.key | sub("five_hour"; "5h") | sub("seven_day"; "weekly") | gsub("_"; " "));
           100 - .value.utilization; (if .key == "five_hour" then 18000 else 604800 end); .value.resets_at)] as $limits
  | {limits: $limits, balances: []}
else
  . as $text
  | ((try capture("period (?<start>[0-9-]+) to (?<end>[0-9-]+)") catch {}) // {}) as $period
  | ((($period.end // "") + "T00:00:00Z") | epoch) as $end
  | ((($period.start // "") + "T00:00:00Z") | epoch) as $start
  | [($text | scan("(?<kind>agent|orb) usage [^\\n]*?remaining \\((?<pct>[0-9.]+)%\\)"))
      | limit("amp_" + .[0]; "Amp " + .[0] + " (monthly)"; (.[1] | tonumber); (($end - $start) // 2592000); $end)] as $limits
  | [($text | split("\n")[] | select(test("^\\*\\*(Individual credits|Workspace )"))
      | capture("^\\*\\*(?<label>[^*]+):\\*\\* \\$(?<amount>[0-9.]+) remaining")
      | {label, amount: (.amount | tonumber)})] as $balances
  | {limits: $limits, balances: $balances, renewal: $period.end}
end
| if (.limits | length) == 0 then error("No recognized limits") else . end
