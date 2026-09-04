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
  | ($variables | index("pubkey") != null)
    and ($variables | index("server") != null)
    and ($variables | index("mountpoint") != null)
    and ($variables | index("interface") != null)
    and ($variables | index("inter") != null)
    and ($variables | index("netif") == null)
    and ($variables | index("version") == null)
' "$dashboard" >/dev/null || fail 'dashboard contains missing or obsolete variables'

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
  (.templating.list[] | select(.name == "server")) as $server
  | ($server.hide == 0)
    and ($server.query.query == "label_values(mem_used_percent,host)")
  and (.templating.list[] | select(.name == "mountpoint") | .multi and .includeAll)
  and (.templating.list[] | select(.name == "interface") | .multi and .includeAll)
' "$dashboard" >/dev/null || fail 'host, mount-point or network-interface discovery is not configured correctly'

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
    and .targets[0].expr == "nodemonitor_version{pubkey=\"$pubkey\"}"
  )
  and any(.panels[];
    .id == 161
    and .type == "state-timeline"
    and .targets[0].expr == "nodemonitor_status{pubkey=\"$pubkey\"}"
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
