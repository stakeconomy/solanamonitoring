def optimize_query:
  gsub("host =~ \"\\^\\$server\\$\""; "host=\"$server\"")
  | gsub("host =~ \"\\$server\\$\""; "host=\"$server\"")
  | gsub("host =~ \"\\$server\""; "host=\"$server\"")
  | gsub("host=~\"\\$server\""; "host=\"$server\"")
  | gsub("pubkey=~\"\\$pubkey\""; "pubkey=\"$pubkey\"")
  | gsub("cpu = \"cpu-total\""; "cpu=\"cpu-total\"")
  | gsub("cpu = 'cpu-total'"; "cpu=\"cpu-total\"");

walk(
  if type == "object" and has("expr") and (.expr | type) == "string" then
    .expr |= optimize_query
  elif type == "object" and has("query") and (.query | type) == "string" then
    .query |= optimize_query
  else
    .
  end
)
| .templating.list |= map(select(.name != "netif" and .name != "version"))
| .templating.list |= map(
    if .name == "inter" then
      .current = {selected: false, text: "1m", value: "1m"}
      | .options |= map(.selected = (.value == "1m"))
    else
      .
    end
  )
