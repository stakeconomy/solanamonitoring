#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_dir/grafana/solana-community-validator-dashboard.json"
transform="$repo_dir/grafana/optimize-dashboard.jq"
enhancement="$repo_dir/grafana/enhance-dashboard.jq"
transformed="$(mktemp)"
enhanced="$(mktemp)"
trap 'rm -f "$transformed" "$enhanced"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

jq -e . "$dashboard" >/dev/null || fail 'dashboard is not valid JSON'

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
      and .fieldConfig.defaults.noValue == "No recent data"
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

jq -f "$transform" "$dashboard" >"$transformed"
cmp -s "$dashboard" "$transformed" || fail 'dashboard optimization is not idempotent'

jq -f "$enhancement" "$dashboard" >"$enhanced"
cmp -s "$dashboard" "$enhanced" || fail 'dashboard enhancement is not idempotent'

printf '%s\n' 'dashboard tests passed'
