#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard="$repo_dir/grafana/solana-community-validator-dashboard.json"
transform="$repo_dir/grafana/optimize-dashboard.jq"
enhancement="$repo_dir/grafana/enhance-dashboard.jq"
transformed="$(mktemp)"
enhanced="$(mktemp)"
unmigrated="$(mktemp)"
canonical_alpenglow_panels="$(mktemp)"
migration_dir="$(mktemp -d)"
trap 'rm -f "$transformed" "$enhanced" "$unmigrated" "$canonical_alpenglow_panels"; rm -rf "$migration_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

selector='{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}'
labels='cluster,genesis,consensus,pubkey,vote_account,schema'
included="increase(alpenglow_observed_included_total${selector}[10m])"
expected="increase(alpenglow_observed_expected_total${selector}[10m])"
missed="increase(alpenglow_observed_missed_total${selector}[10m])"
ready="alpenglow_observed_ready${selector}"
age="time() - timestamp(alpenglow_observed_observed_slot${selector})"
rate="(100 * $included / $expected) and on($labels) ($expected > 0)"
status="((0 * (($age) > 5)) + 4) or on($labels) ((0 * (($ready == 1) and on($labels) (($age) <= 5) and on($labels) ($expected == 0))) + 3) or on($labels) ((0 * (($ready == 1) and on($labels) (($age) <= 5) and on($labels) ($expected > 0))) + 2) or on($labels) (((0 * (($ready == 1) and on($labels) (($age) <= 5))) + 2) unless on($labels) $expected) or on($labels) ((0 * (($ready == 0) and on($labels) (($age) <= 5))) + 1)"
disclosure='RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry'
rate_description="$disclosure. Rolling included estimate divided by rolling expected estimate; zero-opportunity windows are shown as no value."
counts_description="$disclosure. Display-rounded rolling estimates account for increase() extrapolation at window boundaries."
status_description="$disclosure. Uses the latest ready value and actual sample timestamp; samples older than five seconds are stale."
history_description="$disclosure. Rolling ten-minute inclusion percentage; periods with zero estimated opportunities are omitted."

assert_status_semantics() {
  status_code() {
    local sample="$1" sample_age="$2" sample_ready="$3" expected_state="$4"
    if [[ "$sample" == absent ]]; then printf '%s' ''; return; fi
    if (( sample_age > 5 )); then printf '4'; return; fi
    if [[ "$sample_ready" == 1 && "$expected_state" == zero ]]; then printf '3'; return; fi
    if [[ "$sample_ready" == 1 ]]; then printf '2'; return; fi
    printf '1'
  }

  [[ "$(status_code present 2 1 absent)" == 2 ]] || fail 'fresh ready sample without computable increase must be current-attributed'
  [[ "$(status_code present 2 1 zero)" == 3 ]] || fail 'fresh ready zero-opportunity sample must keep zero-opportunity precedence'
  [[ "$(status_code present 2 1 positive)" == 2 ]] || fail 'fresh ready positive-expected sample must be current-attributed'
  [[ "$(status_code present 2 0 absent)" == 1 ]] || fail 'fresh unready sample must be unattributed'
  [[ "$(status_code present 6 1 absent)" == 4 ]] || fail 'stale sample must take precedence over readiness and increase availability'
  [[ -z "$(status_code absent 0 0 absent)" ]] || fail 'absent sample must remain no-sample'
}

assert_promql_semantics_if_available() {
  local promtool_bin="${PROMTOOL:-}"
  if [[ -z "$promtool_bin" ]]; then
    promtool_bin="$(command -v promtool || true)"
  fi
  [[ -n "$promtool_bin" && -x "$promtool_bin" ]] || return 0

  local concrete_status="$status"
  concrete_status="${concrete_status//cluster=~\"\$cluster\"/cluster=\"testnet\"}"
  concrete_status="${concrete_status//genesis=~\"\$genesis\"/genesis=\"genesis\"}"
  concrete_status="${concrete_status//pubkey=\"\$pubkey\"/pubkey=\"identity\"}"
  concrete_status="${concrete_status//vote_account=~\"\$vote_account\"/vote_account=\"vote\"}"

  local rules="$migration_dir/status-rules.yml"
  local tests="$migration_dir/status.test.yml"
  printf 'groups:\n- name: status\n  rules:\n  - record: alpenglow_status_test\n    expr: |\n      %s\n' "$concrete_status" >"$rules"
  printf '%s\n' \
    'rule_files:' \
    '- status-rules.yml' \
    'evaluation_interval: 1s' \
    'tests:' \
    '- interval: 1s' \
    '  input_series:' \
    '  - series: '\''alpenglow_observed_ready{cluster="testnet",genesis="genesis",consensus="alpenglow",pubkey="identity",vote_account="vote",schema="3"}'\''' \
    '    values: '\''1x10'\''' \
    '  - series: '\''alpenglow_observed_observed_slot{cluster="testnet",genesis="genesis",consensus="alpenglow",pubkey="identity",vote_account="vote",schema="3"}'\''' \
    '    values: '\''449000000x10'\''' \
    '  promql_expr_test:' \
    '  - expr: alpenglow_status_test' \
    '    eval_time: 10s' \
    '    exp_samples:' \
    '    - labels: '\''alpenglow_status_test{cluster="testnet",genesis="genesis",consensus="alpenglow",pubkey="identity",vote_account="vote",schema="3"}'\''' \
    '      value: 2' >"$tests"

  (cd "$migration_dir" && "$promtool_bin" test rules "$(basename "$tests")" >/dev/null) \
    || fail 'PromQL semantics do not map fresh ready with absent increase to current-attributed status 2'
}

assert_alpenglow_v3() {
  local file="$1"
  local label="${2:-$1}"
  jq -e \
    --arg included "$included" \
    --arg expected "$expected" \
    --arg missed "$missed" \
    --arg ready "$ready" \
    --arg age "$age" \
    --arg rate "$rate" \
    --arg status "$status" \
    --arg rate_description "$rate_description" \
    --arg counts_description "$counts_description" \
    --arg status_description "$status_description" \
    --arg history_description "$history_description" '
    def targets: [.targets[] | {datasource,editorMode,expr,hide,legendFormat,range,refId,instant}];
    ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171 or .id == 172)] | length == 4)
    and ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171) | .id] | sort == [168,169,170,171])
    and ([.panels[].id] | index(172) == null)
    and any(.panels[];
      .id == 168
      and .title == "Alpenglow vote inclusion rate — last 10 minutes"
      and .description == $rate_description
      and .type == "stat"
      and .gridPos == {"h":4,"w":6,"x":0,"y":55}
      and .fieldConfig.defaults.unit == "percent"
      and .fieldConfig.defaults.noValue == "No vote opportunities in the last 10 minutes"
      and .fieldConfig.defaults.mappings == []
      and (targets == [{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$rate,"hide":false,"legendFormat":"Alpenglow vote inclusion rate — last 10 minutes","range":false,"refId":"A","instant":true}])
    )
    and any(.panels[];
      .id == 169
      and .title == "Alpenglow vote counts — last 10 minutes"
      and .description == $counts_description
      and .type == "stat"
      and .gridPos == {"h":4,"w":12,"x":6,"y":55}
      and .fieldConfig.defaults.unit == "none"
      and .fieldConfig.defaults.noValue == "No recent samples"
      and .fieldConfig.defaults.mappings == []
      and (targets == [
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":("round(" + $included + ")"),"hide":false,"legendFormat":"Included","range":false,"refId":"A","instant":true},
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":("round(" + $expected + ")"),"hide":false,"legendFormat":"Estimated possible","range":false,"refId":"B","instant":true},
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":("round(" + $missed + ")"),"hide":false,"legendFormat":"Estimated missed","range":false,"refId":"C","instant":true}
      ])
    )
    and any(.panels[];
      .id == 170
      and .title == "Alpenglow collection status"
      and .description == $status_description
      and .type == "stat"
      and .gridPos == {"h":4,"w":6,"x":18,"y":55}
      and .interval == "2s"
      and .fieldConfig.defaults.unit == "none"
      and .fieldConfig.defaults.noValue == "No recent samples"
      and .fieldConfig.defaults.mappings == [{"options":{
        "1":{"color":"orange","index":0,"text":"Collecting / latest gap unattributed"},
        "2":{"color":"green","index":1,"text":"Current gap attributed"},
        "3":{"color":"blue","index":2,"text":"No vote opportunities in the last 10 minutes"},
        "4":{"color":"red","index":3,"text":"Stale — last sample older than 5 seconds"}
      },"type":"value"}]
      and (targets == [
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$ready,"hide":true,"legendFormat":"Ready","range":false,"refId":"A","instant":true},
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$age,"hide":true,"legendFormat":"Sample age","range":false,"refId":"B","instant":true},
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$expected,"hide":true,"legendFormat":"Estimated opportunities","range":false,"refId":"C","instant":true},
        {"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$status,"hide":false,"legendFormat":"Collection status","range":false,"refId":"D","instant":true}
      ])
    )
    and any(.panels[];
      .id == 171
      and .title == "Alpenglow inclusion rate history"
      and .description == $history_description
      and .type == "timeseries"
      and .gridPos == {"h":8,"w":24,"x":0,"y":59}
      and .fieldConfig.defaults.unit == "percent"
      and .fieldConfig.defaults.noValue == "No vote opportunities in the last 10 minutes"
      and .fieldConfig.defaults.custom.spanNulls == false
      and .fieldConfig.defaults.mappings == []
      and (targets == [{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"editorMode":"code","expr":$rate,"hide":false,"legendFormat":"Inclusion rate","range":true,"refId":"A","instant":false}])
    )
  ' "$file" >/dev/null || fail "$label does not contain the canonical schema-v3 Alpenglow panels"
  jq -e --slurpfile canonical "$canonical_alpenglow_panels" '
    ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171)] | sort_by(.id))
    == $canonical[0]
  ' "$file" >/dev/null || fail "$label contains schema-v3 Alpenglow panel-object drift"
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
  assert_alpenglow_v3 "$output" "$label migration"
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
jq -e '.refresh=="5s" and (.timepicker.refresh_intervals|index("5s")!=null)' "$dashboard" >/dev/null \
  || fail 'dashboard must actually refresh within the five-second freshness threshold'

jq '[.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171)] | sort_by(.id)' \
  "$dashboard" >"$canonical_alpenglow_panels"

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
  .refresh=="5s"
  and .timepicker.refresh_intervals==["5s","10s","30s","1m","2m","5m","15m","30m","1h"]
  and all(.annotations.list[]; .enable == false)
' "$dashboard" >/dev/null || fail 'dashboard refresh cadence or annotation policy is noncanonical'

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

assert_status_semantics
assert_promql_semantics_if_available
assert_alpenglow_v3 "$dashboard" 'canonical dashboard'

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

jq -e '
  ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedReady")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedIncluded")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedExpected")))
  and ([.[].description] | all(length > 0))
  and (map(.gridPos) == [{"h":4,"w":8,"x":0,"y":55},{"h":4,"w":16,"x":8,"y":55},{"h":8,"w":24,"x":0,"y":59}])
' "$repo_dir/tests/fixtures/dashboard-schema-v2-alpenglow-panels.json" >/dev/null \
  || fail 'schema-v2 fixture is not a genuine readiness-gated legacy panel set'

jq -e '
  ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedReady")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedUnattributed")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedReferences")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedSlot")))
  and ([.[].fieldConfig.defaults.mappings[]?.options | .. | strings] | any(. == "Comparable interval"))
  and ([.[].description] | all(length > 0))
  and (map(.gridPos.y) == [55,55,55,55,58])
' "$repo_dir/tests/fixtures/dashboard-legacy-alpenglow-panels.json" >/dev/null \
  || fail 'legacy fixture is not the genuine five-panel observed-metric layout'

jq -e '
  length == 3
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedReady")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedIncluded")))
  and ([.[].targets[].expr] | any(contains("nodemonitor_alpenglowObservedSlot")))
  and ([.[].description] | all(length > 0))
  and (map(.gridPos.y) == [55,55,58])
' "$repo_dir/tests/fixtures/dashboard-partial-alpenglow-panels.json" >/dev/null \
  || fail 'partial fixture is not a genuine incomplete legacy observed-metric layout'

jq --slurpfile old "$repo_dir/tests/fixtures/dashboard-schema-v2-alpenglow-panels.json" '
  .panels = ([.panels[] | select(.id as $id | ([168,169,170,171,172] | index($id)) == null)] + $old[0])
' "$dashboard" >"$migration_dir/schema-v2-three-panels-input.json"
migrate_and_assert "$migration_dir/schema-v2-three-panels-input.json" 'schema-v2-three-panels'

jq --slurpfile old "$repo_dir/tests/fixtures/dashboard-legacy-alpenglow-panels.json" '
  .panels = (
    [.panels[]
      | select(.id as $id | ([168,169,170,171,172] | index($id)) == null)
      | if .gridPos.y >= 67 then .gridPos.y -= 1 else . end
    ] + $old[0]
  )
' "$dashboard" >"$migration_dir/legacy-five-panels-input.json"
migrate_and_assert "$migration_dir/legacy-five-panels-input.json" 'legacy-five-panels'

jq --slurpfile old "$repo_dir/tests/fixtures/dashboard-partial-alpenglow-panels.json" '
  .panels = (
    [.panels[]
      | select(.id as $id | ([168,169,170,171,172] | index($id)) == null)
      | if .gridPos.y >= 67 then .gridPos.y -= 1 else . end
    ] + $old[0]
  )
' "$dashboard" >"$migration_dir/partial-panels-input.json"
migrate_and_assert "$migration_dir/partial-panels-input.json" 'partial-alpenglow-panels'

mutate_and_migrate() {
  local label="$1"
  local filter="$2"
  local input="$migration_dir/${label}-input.json"
  jq "$filter" "$dashboard" >"$input"
  migrate_and_assert "$input" "$label"
}

mutate_and_migrate 'noncanonical-title' '(.panels[] | select(.id == 168) | .title) = "Wrong title"'
mutate_and_migrate 'noncanonical-description' '(.panels[] | select(.id == 169) | .description) = "Wrong description"'
mutate_and_migrate 'noncanonical-geometry' '(.panels[] | select(.id == 170) | .gridPos.w) = 5'
mutate_and_migrate 'noncanonical-history-geometry' '(.panels[] | select(.id == 171) | .gridPos.y) = 60'
mutate_and_migrate 'noncanonical-no-value' '(.panels[] | select(.id == 171) | .fieldConfig.defaults.noValue) = "Wrong no-value"'
mutate_and_migrate 'noncanonical-mapping' '(.panels[] | select(.id == 170) | .fieldConfig.defaults.mappings[0].options["2"].text) = "Wrong mapping"'
mutate_and_migrate 'noncanonical-rate-expression' '(.panels[] | select(.id == 168) | .targets[0].expr) = "vector(99)"'
mutate_and_migrate 'noncanonical-count-expression' '(.panels[] | select(.id == 169) | .targets[1].expr) = "vector(99)"'
mutate_and_migrate 'noncanonical-status-expression' '(.panels[] | select(.id == 170) | .targets[] | select(.refId == "D") | .expr) = "(0 * alpenglow_observed_ready{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"alpenglow\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\",schema=\"3\"}) + 9"'
mutate_and_migrate 'noncanonical-history-expression' '(.panels[] | select(.id == 171) | .targets[0].expr) = "vector(99)"'
mutate_and_migrate 'noncanonical-rate-max' '(.panels[] | select(.id == 168) | .fieldConfig.defaults.max) = 99'
mutate_and_migrate 'noncanonical-count-thresholds' '(.panels[] | select(.id == 169) | .fieldConfig.defaults.thresholds.steps[0].color) = "red"'
mutate_and_migrate 'noncanonical-status-color-mode' '(.panels[] | select(.id == 170) | .options.colorMode) = "value"'
mutate_and_migrate 'noncanonical-status-text-mode' '(.panels[] | select(.id == 170) | .options.textMode) = "auto"'
mutate_and_migrate 'noncanonical-history-plugin-version' '(.panels[] | select(.id == 171) | .pluginVersion) = "0.0.0"'
mutate_and_migrate 'noncanonical-panel-datasource' '(.panels[] | select(.id == 168) | .datasource.uid) = "drifted-datasource"'
mutate_and_migrate 'noncanonical-dashboard-refresh' '.refresh = "1m"'
mutate_and_migrate 'noncanonical-refresh-intervals' '.timepicker.refresh_intervals = ["1m"]'
mutate_and_migrate 'partial-schema-v3' '.panels |= map(select(.id != 169))'

printf '%s\n' 'dashboard tests passed'
