#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_dir/grafana/solana-community-validator-dashboard.json"
transform="$repo_dir/grafana/optimize-dashboard.jq"
enhancement="$repo_dir/grafana/enhance-dashboard.jq"
transformed="$(mktemp)"
enhanced="$(mktemp)"
unmigrated="$(mktemp)"
migration_dir="$(mktemp -d)"
trap 'rm -f "$transformed" "$enhanced" "$unmigrated"; rm -rf "$migration_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

migrate_and_assert() {
  local input="$1"
  local label="$2"
  local output="$migration_dir/${label}.json"
  local second="$migration_dir/${label}-second.json"
  local tower_before="$migration_dir/${label}-tower-before.json"
  local tower_after="$migration_dir/${label}-tower-after.json"

  jq '[.panels[] | select(.id == 61 or .id == 121 or .id == 126)]' "$input" >"$tower_before"
  jq -f "$enhancement" "$input" >"$output"
  jq -e '
    [.panels[].id] as $ids
    | ($ids | length) == ($ids | unique | length)
    and ([.panels[] | select(.gridPos != null)] as $panels
      | [
          $panels[] as $a
          | $panels[] as $b
          | select($a.id < $b.id)
          | select(
              ($a.gridPos.x < ($b.gridPos.x + $b.gridPos.w)) and
              ($b.gridPos.x < ($a.gridPos.x + $a.gridPos.w)) and
              ($a.gridPos.y < ($b.gridPos.y + $b.gridPos.h)) and
              ($b.gridPos.y < ($a.gridPos.y + $a.gridPos.h))
            )
        ] | length == 0)
  ' "$output" >/dev/null || fail "$label migration creates duplicate IDs or panel overlap"
  jq '[.panels[] | select(.id == 61 or .id == 121 or .id == 126)]' "$output" >"$tower_after"
  cmp -s "$tower_before" "$tower_after" || fail "$label migration changes a Tower panel"
  jq -f "$enhancement" "$output" >"$second"
  cmp -s "$output" "$second" || fail "$label migration is not byte-idempotent"
}

[[ -L "$dashboard" ]] || fail 'canonical Grafana dashboard is not the root-dashboard symlink'
[[ "$(readlink "$dashboard")" == '../Solana Community Validator Dashboard-1623239777455.json' ]] \
  || fail 'canonical Grafana dashboard symlink targets the wrong root representation'

jq -e . "$dashboard" >/dev/null || fail 'dashboard is not valid JSON'

jq -e '.uid == "f2b2HcaGz25"' "$dashboard" >/dev/null \
  || fail 'dashboard UID does not target the canonical production dashboard'

jq -e '
  [.panels[].id] as $ids
  | ($ids | length) == ($ids | unique | length)
' "$dashboard" >/dev/null || fail 'dashboard contains duplicate panel IDs'

jq -e '
  [.panels[] | select(.gridPos != null)] as $panels
  | [
      $panels[] as $a
      | $panels[] as $b
      | select($a.id < $b.id)
      | select(
          ($a.gridPos.x < ($b.gridPos.x + $b.gridPos.w)) and
          ($b.gridPos.x < ($a.gridPos.x + $a.gridPos.w)) and
          ($a.gridPos.y < ($b.gridPos.y + $b.gridPos.h)) and
          ($b.gridPos.y < ($a.gridPos.y + $a.gridPos.h))
        )
    ]
  | length == 0
' "$dashboard" >/dev/null || fail 'dashboard panels overlap'

jq -e '
  [.templating.list[].name] as $variables
  | ($variables | index("cluster") != null)
    and ($variables | index("genesis") != null)
    and ($variables | index("pubkey") != null)
    and ($variables | index("vote_account") != null)
    and ($variables | index("server") != null)
    and ($variables | index("mountpoint") != null)
    and ($variables | index("interface") != null)
    and ($variables | index("inter") != null)
    and ($variables | index("netif") == null)
    and ($variables | index("version") == null)
' "$dashboard" >/dev/null || fail 'dashboard contains missing Alpenglow cluster-scoping variables'

jq -e '
  [.. | objects | .expr? // empty | select(contains("nodemonitor_"))]
  | all(.[]; test("nodemonitor_[A-Za-z0-9_]+\\{[^}]*cluster=~\\\"\\$cluster\\\"[^}]*genesis=~\\\"\\$genesis\\\""))
' "$dashboard" >/dev/null || fail 'nodemonitor PromQL queries are not scoped by cluster and genesis'

jq -e '
  any(.panels[]; .id == 126 and (.title | contains("Tower")))
  and any(.panels[]; .id == 99 and (.title | contains("Scheduled")))
  and any(.panels[]; .id == 100 and (.title | contains("Scheduled")))
' "$dashboard" >/dev/null || fail 'dashboard does not distinguish Tower credits from scheduled-slot production'

jq -e '
  .__inputs[]
  | select(.name == "DS_PROMETHEUS")
  | .pluginId == "prometheus"
' "$dashboard" >/dev/null || fail 'dashboard does not declare a portable datasource input'

jq -e '
  [.. | objects | .datasource? // empty | select(type == "object" and .type == "prometheus") | .uid]
  | all(.[]; . == "${DS_PROMETHEUS}")
' "$dashboard" >/dev/null || fail 'dashboard contains a hard-coded Prometheus datasource UID'

jq -e '
  (.templating.list[] | select(.name == "cluster")) as $cluster
  | (.templating.list[] | select(.name == "genesis")) as $genesis
  | (.templating.list[] | select(.name == "pubkey")) as $pubkey
  | (.templating.list[] | select(.name == "vote_account")) as $vote_account
  | (.templating.list[] | select(.name == "server")) as $server
  | ($cluster.includeAll | not)
    and ($cluster.query.query == "label_values(nodemonitor_collectorUp,cluster)")
    and ($genesis.includeAll | not)
    and ($genesis.query.query | contains("nodemonitor_collectorUp{cluster=~\"$cluster\"}"))
    and ($pubkey.hide == 0)
    and ($pubkey.label == "Validator / system")
    and ($pubkey.query.query | contains("label_join"))
    and ($pubkey.query.query | contains("nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\"}"))
    and ($pubkey.regex | contains("?<text>"))
    and ($pubkey.regex | contains("?<value>"))
    and ($vote_account.includeAll | not)
    and ($vote_account.query.query | contains("nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\"}"))
    and ($server.hide == 2)
    and ($server.skipUrlSync == true)
    and ($server.query.query | contains("nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"))
  and (.templating.list[] | select(.name == "mountpoint") | .multi and .includeAll)
  and (.templating.list[] | select(.name == "interface") | .multi and .includeAll)
' "$dashboard" >/dev/null || fail 'validator-host linking, mount-point or network-interface discovery is not configured correctly'

jq -e '
  .templating.list[]
  | select(.name == "inter")
  | .current.value == "1m"
' "$dashboard" >/dev/null || fail 'monitor graph interval is not aligned to the one-minute collector cadence'

jq -e '
  .panels[]
  | select(.title == "My Skiprate")
  | all(.targets[]; .legendFormat != "Solana Version")
    and all(.fieldConfig.overrides[]; .matcher.options != "Solana Version")
' "$dashboard" >/dev/null || fail 'skip-rate panel still contains the intrusive software-version line'

jq -e '
  any(.panels[];
    .id == 160
    and .type == "state-timeline"
    and .targets[0].expr == "nodemonitor_version{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and any(.panels[];
    .id == 161
    and .type == "state-timeline"
    and .targets[0].expr == "nodemonitor_status{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
' "$dashboard" >/dev/null || fail 'aligned software-version or validator-health timeline is missing'

jq -e '
  .panels[]
  | select(.id == 102)
  | .targets[0].expr as $expr
  | ($expr | contains("path=~\"$mountpoint\""))
    and ($expr | contains("var/lib"))
    and ($expr | contains("fstype!~"))
' "$dashboard" >/dev/null || fail 'filesystem panel does not support dynamic physical mount points'

jq -e '
  .templating.list[]
  | select(.name == "mountpoint")
  | (.query.query | contains("var/lib"))
    and (.query.query | contains("fstype!~"))
' "$dashboard" >/dev/null || fail 'mount-point selector does not exclude internal and virtual filesystems'

jq -e '
  .panels[]
  | select(.id == 111)
  | .fieldConfig.defaults.custom.axisCenteredZero == true
  and all(.fieldConfig.overrides[];
      all(.properties[]; .id != "custom.axisPlacement" or .value != "right")
    )
  and any(.fieldConfig.overrides[];
      .matcher.options == "/ transmit$/"
      and any(.properties[]; .id == "custom.transform" and .value == "negative-Y")
    )
  and all(.fieldConfig.overrides[];
      all(.properties[]; .id != "color")
    )
  and .fieldConfig.defaults.color.mode == "palette-classic"
  and .options.legend.placement == "right"
  and .options.legend.displayMode == "table"
  and all(.targets[]; .expr | contains("interface!~"))
' "$dashboard" >/dev/null || fail 'network traffic is not mirrored around zero'

jq -e '
  [.panels[] | select(.type == "stat" or .type == "gauge" or .type == "bargauge")]
  | all(.[ ];
      .maxDataPoints == 1
      and .fieldConfig.defaults.noValue == (
        if .id == 168 then "No vote opportunities in the last 10 minutes"
        elif .id == 169 or .id == 170 then "No recent samples"
        else "No recent data"
        end
      )
      and all(.targets[]; .instant == true and .range == false)
    )
' "$dashboard" >/dev/null || fail 'current-value panels still perform range queries'

jq -e '
  all(.panels[] | select(.type == "timeseries");
      .maxDataPoints <= 1200
      and all(.targets[]; .instant == false and .range == true)
    )
  and all(.panels[] | select(.type == "state-timeline");
      .maxDataPoints <= 1000 and .interval == "$inter"
    )
' "$dashboard" >/dev/null || fail 'history panels do not cap query resolution'

jq -e '
  (.panels[] | select(.id == 104) | (.targets | length) == 5)
  and (.panels[] | select(.id == 129) | (.targets | length) == 4)
  and (.panels[] | select(.id == 133) | (.targets | length) == 5)
' "$dashboard" >/dev/null || fail 'CPU, process or TCP query set is not optimized'

jq -e '
  (.panels[] | select(.id == 56) | all(.targets[]; (.expr | contains("[")) | not))
  and (.panels[] | select(.id == 75) | all(.targets[]; (.expr | contains("[")) | not))
  and (.panels[] | select(.id == 126) | all(.targets[]; (.expr | contains("[")) | not))
' "$dashboard" >/dev/null || fail 'raw validator gauges still use redundant range vectors'

jq -e '
  all(.timepicker.refresh_intervals[]; test("^[0-9]+s$") | not)
  and all(.annotations.list[]; .enable == false)
' "$dashboard" >/dev/null || fail 'dashboard permits sub-minute refreshes or unused annotations'

if jq -r '.. | objects | .expr? // empty' "$dashboard" | grep -q 'ideriv'; then
  fail 'counter panels still use reset-unsafe ideriv queries'
fi

if jq -r '.. | objects | .expr? // empty' "$dashboard" | grep -q 'median('; then
  fail 'single-host queries still contain redundant median aggregation'
fi

if jq -r '.. | objects | .expr? // empty' "$dashboard" | grep -Eq 'host[[:space:]]*=~[[:space:]]*"\^?\$server'; then
  fail 'single-value server variable still uses a regex matcher'
fi

jq -e '
  any(.panels[];
    .id == 166
    and .title == "Vote freshness"
    and .gridPos.y == 1
    and (.description | contains("Finalized slot minus last vote"))
    and .targets[0].expr == "nodemonitor_finalizedSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} - nodemonitor_lastVote{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and any(.panels[];
    .id == 167
    and .title == "Root freshness"
    and .gridPos.y == 1
    and (.description | contains("Finalized slot minus root slot"))
    and .targets[0].expr == "nodemonitor_finalizedSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} - nodemonitor_rootSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and all(.panels[] | select(.id == 54 or .id == 99 or .id == 100 or .id == 164 or .id == 43 or .id == 97); .gridPos.y == 1)
' "$dashboard" >/dev/null || fail 'dashboard upper area is not health-first'

jq -e '
  any(.panels[];
    .id == 165
    and .title == "Alpenglow reward accounting"
    and (.description | contains("reward accounting only, not performance"))
    and .fieldConfig.defaults.unit == "SOL"
    and .targets[0].expr == "nodemonitor_alpenglowRewardAccountingLamports{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"alpenglow\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} / 1e9"
  )
  and all(.panels[] | select(.id == 61 or .id == 121 or .id == 126);
    (.title | contains("Tower")) and (.targets[0].expr | contains("consensus=\"tower\""))
  )
  and ([.panels[] | select((.title // "") | test("Votor participation"; "i"))] | length == 0)
' "$dashboard" >/dev/null || fail 'dashboard does not isolate Tower credits or label Alpenglow reward accounting correctly'

selector='{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}'
included="increase(alpenglow_observed_included_total${selector}[10m])"
expected="increase(alpenglow_observed_expected_total${selector}[10m])"
missed="increase(alpenglow_observed_missed_total${selector}[10m])"
ready="alpenglow_observed_ready${selector}"
age="time() - timestamp(alpenglow_observed_observed_slot${selector})"
disclosure='RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry'

jq -e \
  --arg included "$included" \
  --arg expected "$expected" \
  --arg missed "$missed" \
  --arg ready "$ready" \
  --arg age "$age" \
  --arg disclosure "$disclosure" '
  any(.panels[];
    .id == 168
    and .title == "Alpenglow vote inclusion rate — last 10 minutes"
    and .type == "stat"
    and .gridPos == {"h": 4, "w": 6, "x": 0, "y": 55}
    and .fieldConfig.defaults.unit == "percent"
    and .fieldConfig.defaults.noValue == "No vote opportunities in the last 10 minutes"
    and (.description | contains($disclosure))
    and (.targets[0].expr == ("(100 * " + $included + " / " + $expected + ") and on(cluster,genesis,consensus,pubkey,vote_account,schema) (" + $expected + " > 0)"))
  )
  and any(.panels[];
    .id == 169
    and .title == "Alpenglow vote counts — last 10 minutes"
    and .type == "stat"
    and .gridPos == {"h": 4, "w": 12, "x": 6, "y": 55}
    and .fieldConfig.defaults.noValue == "No recent samples"
    and (.description | contains($disclosure))
    and ([.targets[].legendFormat] == ["Included", "Estimated possible", "Estimated missed"])
    and ([.targets[].expr] == ["round(" + $included + ")", "round(" + $expected + ")", "round(" + $missed + ")"])
  )
  and any(.panels[];
    .id == 170
    and .title == "Alpenglow collection status"
    and .type == "stat"
    and .gridPos == {"h": 4, "w": 6, "x": 18, "y": 55}
    and .fieldConfig.defaults.noValue == "No recent samples"
    and (.description | contains($disclosure))
    and ([.targets[].expr] | index($ready) != null)
    and ([.targets[].expr] | index($age) != null)
    and ([.targets[].expr] | index($expected) != null)
    and ([.targets[].expr] | join(" ") | contains("(" + $age + ") > 5"))
    and ([.targets[].expr] | join(" ") | contains("(" + $age + ") <= 5"))
    and (.targets[] | select(.refId == "D") | .expr | contains("+ 4"))
    and (.targets[] | select(.refId == "D") | .expr | contains("+ 3"))
    and (.targets[] | select(.refId == "D") | .expr | contains("+ 2"))
    and (.targets[] | select(.refId == "D") | .expr | contains("+ 1"))
    and ([.fieldConfig.defaults.mappings[]?.options | .. | strings] | any(. == "Current gap attributed"))
    and ([.fieldConfig.defaults.mappings[]?.options | .. | strings] | any(. == "Collecting / latest gap unattributed"))
    and ([.fieldConfig.defaults.mappings[]?.options | .. | strings] | any(. == "No vote opportunities in the last 10 minutes"))
    and ([.fieldConfig.defaults.mappings[]?.options | .. | strings] | any(. == "Stale — last sample older than 5 seconds"))
  )
  and any(.panels[];
    .id == 171
    and .title == "Alpenglow inclusion rate history"
    and .type == "timeseries"
    and .gridPos == {"h": 8, "w": 24, "x": 0, "y": 59}
    and .fieldConfig.defaults.unit == "percent"
    and .fieldConfig.defaults.custom.spanNulls == false
    and (.description | contains($disclosure))
    and (.targets[0].expr == ("(100 * " + $included + " / " + $expected + ") and on(cluster,genesis,consensus,pubkey,vote_account,schema) (" + $expected + " > 0)"))
  )
  and ([.panels[].id] | index(172) == null)
  and ([.panels[] | select((.title // "") | startswith("Alpenglow"))] | all(.description | contains($disclosure)))
  and ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171) | .targets[].expr] | all(.[];
    contains("cluster=~\"$cluster\"")
    and contains("genesis=~\"$genesis\"")
    and contains("consensus=\"alpenglow\"")
    and contains("pubkey=\"$pubkey\"")
    and contains("vote_account=~\"$vote_account\"")
    and contains("schema=\"3\"")
    and (contains("clamp_max") | not)
    and (contains("nodemonitor_alpenglowObserved") | not)
  ))
  and ([.panels[] | select(.id == 168 or .id == 169 or .id == 171) | .targets[].expr] | all(.[];
    contains("alpenglow_observed_ready") | not
  ))
' "$dashboard" >/dev/null || fail 'dashboard does not expose the schema-v3 Alpenglow operator view'

jq -f "$transform" "$dashboard" >"$transformed"
cmp -s "$dashboard" "$transformed" || fail 'dashboard optimization is not idempotent'

jq -f "$enhancement" "$dashboard" >"$enhanced"
cmp -s "$dashboard" "$enhanced" || fail 'dashboard enhancement is not idempotent'

jq '
  .panels |= map(
    select(.id as $id | ([168, 169, 170, 171, 172] | index($id)) == null)
    | if .gridPos.y >= 67 then .gridPos.y -= 12 else . end
  )
' "$dashboard" >"$unmigrated"
migrate_and_assert "$unmigrated" 'absent-alpenglow-panels'

jq '
  .panels |= map(
    select(.id != 170 and .id != 172)
    | if .id == 168 then .title = "Alpenglow vote inclusion rate"
      elif .id == 169 then .title = "Alpenglow vote counts"
      else .
      end
  )
' "$dashboard" >"$migration_dir/schema-v2-three-panels-input.json"
migrate_and_assert "$migration_dir/schema-v2-three-panels-input.json" 'schema-v2-three-panels'

jq '
  (.panels | map(select(.id == 168 or .id == 169 or .id == 170 or .id == 171))) as $alpenglow
  | .panels = (
      [.panels[]
        | select(.id as $id | ([168, 169, 170, 171, 172] | index($id)) == null)
        | if .gridPos.y >= 67 then .gridPos.y -= 1 else . end
      ]
      + [
          ($alpenglow[] | select(.id == 168) | .title = "Alpenglow observed inclusion readiness" | .gridPos = {"h":3,"w":6,"x":0,"y":55}),
          ($alpenglow[] | select(.id == 169) | .title = "Alpenglow unattributed accounts" | .gridPos = {"h":3,"w":6,"x":6,"y":55}),
          ($alpenglow[] | select(.id == 170) | .title = "Alpenglow reference accounts" | .gridPos = {"h":3,"w":6,"x":12,"y":55}),
          ($alpenglow[] | select(.id == 170) | .id = 172 | .title = "Alpenglow observed snapshot slot" | .gridPos = {"h":3,"w":6,"x":18,"y":55}),
          ($alpenglow[] | select(.id == 171) | .title = "Alpenglow observed inclusion — inferred interval counts" | .gridPos = {"h":8,"w":24,"x":0,"y":58})
        ]
    )
' "$dashboard" >"$migration_dir/legacy-five-panels-input.json"
migrate_and_assert "$migration_dir/legacy-five-panels-input.json" 'legacy-five-panels'

jq '.panels |= map(select(.id != 169))' "$dashboard" >"$migration_dir/partial-panels-input.json"
migrate_and_assert "$migration_dir/partial-panels-input.json" 'partial-alpenglow-panels'

printf '%s\n' 'dashboard tests passed'
