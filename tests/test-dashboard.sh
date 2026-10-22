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

jq -e '.uid == "f2b2HcaGz25"' "$dashboard" >/dev/null \
  || fail 'dashboard UID does not target the canonical production dashboard'

jq -e '
  [(.. | objects | select(has("gridPos") and has("id"))).id] as $ids
  | ($ids | length) == ($ids | unique | length)
' "$dashboard" >/dev/null || fail 'dashboard contains duplicate panel IDs'

jq -e '
  ([.] + [.. | objects | select(.type? == "row")])[] |
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
  all((.. | objects | select(has("gridPos") and has("id"))); .id != 61 and .id != 121 and .id != 126 and .id != 204)
  and any((.. | objects | select(has("gridPos") and has("id"))); .id == 99 and (.title | contains("Leader slots")))
  and any((.. | objects | select(has("gridPos") and has("id"))); .id == 100 and (.title | contains("Leader slots")))
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
  (.. | objects | select(has("gridPos") and has("id")))
  | select(.title == "My Skiprate")
  | all(.targets[]; .legendFormat != "Solana Version")
    and all(.fieldConfig.overrides[]; .matcher.options != "Solana Version")
' "$dashboard" >/dev/null || fail 'skip-rate panel still contains the intrusive software-version line'

jq -e '
  any((.. | objects | select(has("gridPos") and has("id")));
    .id == 160
    and .type == "state-timeline"
    and .targets[0].expr == "nodemonitor_version{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and any((.. | objects | select(has("gridPos") and has("id")));
    .id == 161
    and .type == "state-timeline"
    and .targets[0].expr == "nodemonitor_status{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
' "$dashboard" >/dev/null || fail 'aligned software-version or validator-health timeline is missing'

jq -e '
  (.. | objects | select(has("gridPos") and has("id")))
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
  (.. | objects | select(has("gridPos") and has("id")))
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
  [(.. | objects | select(has("gridPos") and has("id"))) | select(.type == "stat" or .type == "gauge" or .type == "bargauge")]
  | all(.[ ];
      .maxDataPoints == 1
      and .fieldConfig.defaults.noValue == "No recent data"
      and all(.targets[]; .instant == true and .range == false)
    )
' "$dashboard" >/dev/null || fail 'current-value panels still perform range queries'

jq -e '
  all((.. | objects | select(has("gridPos") and has("id"))) | select(.type == "timeseries");
      .maxDataPoints <= 1200
      and all(.targets[]; .instant == false and .range == true)
    )
  and all((.. | objects | select(has("gridPos") and has("id"))) | select(.type == "state-timeline");
      .maxDataPoints <= 1000 and .interval == "$inter"
    )
' "$dashboard" >/dev/null || fail 'history panels do not cap query resolution'

jq -e '
  ((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 104) | (.targets | length) == 5)
  and ((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 129) | (.targets | length) == 4)
  and ((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 133) | (.targets | length) == 5)
' "$dashboard" >/dev/null || fail 'CPU, process or TCP query set is not optimized'

jq -e '
  ((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 56) | all(.targets[]; (.expr | contains("[")) | not))
  and ((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 75) | all(.targets[]; (.expr | contains("[")) | not))
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
  any((.. | objects | select(has("gridPos") and has("id")));
    .id == 166
    and .title == "Vote freshness"
    and (.description | contains("Finalized slot minus last vote"))
    and .targets[0].expr == "nodemonitor_finalizedSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} - nodemonitor_lastVote{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and any((.. | objects | select(has("gridPos") and has("id")));
    .id == 167
    and .title == "Root freshness"
    and (.description | contains("Finalized slot minus root slot"))
    and .targets[0].expr == "nodemonitor_finalizedSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} - nodemonitor_rootSlot{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  and all((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 54 or .id == 98 or .id == 124 or .id == 97); .gridPos.y == 1)
' "$dashboard" >/dev/null || fail 'dashboard upper area is not health-first'

jq -e '
  any((.. | objects | select(has("gridPos") and has("id")));
    .id == 165
    and .title == "Alpenglow reward accounting"
    and (.description | contains("reward accounting only, not performance"))
    and .fieldConfig.defaults.unit == "SOL"
    and .targets[0].expr == "nodemonitor_alpenglowRewardAccountingLamports{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"alpenglow\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"} / 1e9"
  )
  and ([(.. | objects | select(has("gridPos") and has("id"))) | select((.title // "") | test("Votor participation"; "i"))] | length == 0)
' "$dashboard" >/dev/null || fail 'dashboard does not isolate Tower credits or label Alpenglow reward accounting correctly'

jq -f "$transform" "$dashboard" >"$transformed"
cmp -s "$dashboard" "$transformed" || fail 'dashboard optimization is not idempotent'

jq -f "$enhancement" "$dashboard" >"$enhanced"
cmp -s "$dashboard" "$enhanced" || fail 'dashboard enhancement is not idempotent'

printf '%s\n' 'dashboard tests passed'

jq -e '
  [(.. | objects | select(has("gridPos") and has("id"))) | select(.id >= 181 and .id <= 196 and .type == "stat")] as $vx |
  ($vx | length) == 12 and
  all($vx[]; all(.targets[]; .expr | contains("time() - 150"))) and
  all($vx[] | select(.id != 183 and .id != 189 and .id != 194);
    all(.targets[]; (.expr | contains("nodemonitor_vxDataFresh")) and
      (.expr | contains("nodemonitor_vxEpoch")) and
      (.expr | contains("timestamp(")))) and
  any($vx[]; .id == 188 and (.targets[0].expr | contains("vxRewardOnChainAvailable"))) and
  any($vx[]; .id == 187 and (.targets[0].expr | contains("vxRewardTotalAvailable")))
' "$dashboard" >/dev/null || fail 'VX panels lack current-epoch, availability or freshness guards'
printf '%s\n' 'VX dashboard tests passed'

jq -e '
  [(.. | objects | select(has("gridPos") and has("id"))) | select(.id == 181 or .id == 193 or .id == 187 or .id == 201)] as $overview |
  ($overview | length) == 4 and ([$overview[].gridPos.y] | unique) == [4] and all($overview[]; .gridPos.w == 6 and .gridPos.h == 4 and (.targets | length) == 1 and .options.text.valueSize == 36) and
  ([$overview[].title] | sort) == (["Consensus Participation", "Fast-Vote Inclusion", "Epoch rewards · gross", "Validator income · estimated"] | sort) and
  any($overview[]; .id == 187 and ([.targets[].legendFormat] == ["Gross rewards"]) and .fieldConfig.defaults.decimals == 4) and
  any($overview[]; .id == 193 and .fieldConfig.defaults.decimals == 3 and (.description | contains("not a direct latency"))) and
  any((.. | objects | select(has("gridPos") and has("id"))); .id == 194 and (.targets[0].expr | contains("vxNextEpochAvailable")) and (.targets[0].expr | contains(" + 1")) and ((.targets[0].expr | contains("vxDataFresh")) | not)) and
  all((.. | objects | select(has("gridPos") and has("id"))) | select(.id == 198 or .id == 199 or .id == 200); .fieldConfig.defaults.decimals == 9)
' "$dashboard" >/dev/null || fail 'VX overview grouping, precision or admission guards are incorrect'
printf '%s\n' 'VX overview tests passed'

jq -e '
  [(.. | objects | select(has("gridPos") and has("id"))) | select((.id >= 198 and .id <= 201) or .id == 213)] as $p |
  ($p | length) == 5 and
  all($p[];
    all(.targets[]; .instant == true and
      (.expr | contains("vxEarningsApiUp")) and
      (.expr | contains("vxEarningsEpoch")) and
      (.expr | contains("Available")) and
      (.expr | contains("timestamp(")) and
      (.expr | contains("time() - 150")) and
      (.expr | contains("cluster=~")) and
      (.expr | contains("genesis=~")) and
      (.expr | contains("vote_account=~"))))
' "$dashboard" >/dev/null || fail 'earnings panels must guard epoch, collection age, availability and identity'
printf 'VX earnings dashboard tests passed\n'

jq -e '
  all(.panels[]; .id != 180 and .id != 61 and .id != 126 and .id != 121) and
  any(.panels[]; .id == 195 and .collapsed == true and (.panels | length) == 14) and
  any(.panels[]; .id == 197 and .collapsed == true and ([.panels[].id] | sort) == [198,199,200]) and
  any(.panels[]; .id == 201 and ([.targets[].legendFormat] ==
    ["Before costs"])) and
  all(.panels[] | select(.id == 181 or .id == 193 or .id == 187 or .id == 201);
    .transparent == true and .gridPos.y < 15)
' "$dashboard" >/dev/null || fail 'integrated overview or collapsed historical rows are incorrect'

# An exported expanded row stores children at top level. Both forms must round-trip.
jq '.panels |= [.[] | if .type == "row" and .collapsed then
  (. + {collapsed:false,panels:[]}), .panels[] else . end]' "$dashboard" > "$transformed"
jq -f "$enhancement" "$transformed" > "$enhanced"
cmp -s "$dashboard" "$enhanced" || fail 'expanded row export does not rebuild deterministically'
printf 'integrated layout and collapsed/expanded round-trip tests passed\n'

jq -e '
  all(.panels[] | select(.id == 181 or .id == 193 or .id == 187 or .id == 201);
    (.targets | length) == 1 and .options.textMode == "value" and .options.text.valueSize == 36) and
  all(.panels[] | select(.id == 206 or .id == 194 or .id == 212 or .id == 213);
    .options.text.valueSize == 18 and .options.orientation == "horizontal" and .gridPos.y == 8) and
  all(.panels[] | select(.id == 206 or .id == 212); all(.targets[];
    (.expr | contains("vxDataFresh")) and (.expr | contains("timestamp(")) and (.expr | contains("time() - 150")))) and
  any(.panels[]; .id == 194 and (.targets | length) == 2) and
  any(.panels[]; .id == 212 and any(.fieldConfig.overrides[];
    .matcher.options == "Missed" and any(.properties[]; .id == "decimals" and .value == 6))) and
  all((.. | objects | select(.type? == "stat")); .options.text.valueSize <= 36)
' "$dashboard" >/dev/null || fail 'compact typography, supporting metrics or precision regressed'
printf 'compact overview typography tests passed\n'
