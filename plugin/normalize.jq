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
