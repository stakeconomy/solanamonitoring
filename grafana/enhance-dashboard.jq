def datasource:
  {"type": "prometheus", "uid": "${DS_PROMETHEUS}"};

def scope_nodemonitor:
  gsub(
    "\\{consensus=\\\"tower\\\",pubkey=\\\"\\$pubkey\\\"\\}";
    "{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"tower\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  | gsub(
    "\\{consensus=\\\"alpenglow\\\",pubkey=\\\"\\$pubkey\\\"\\}";
    "{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"alpenglow\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  )
  | gsub(
    "\\{pubkey=\\\"\\$pubkey\\\"\\}";
    "{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}"
  );

def target($ref; $expr; $legend):
  {
    "datasource": datasource,
    "editorMode": "code",
    "expr": $expr,
    "hide": false,
    "legendFormat": $legend,
    "range": true,
    "refId": $ref
  };

def alpenglow_selector:
  "{cluster=~\"$cluster\",genesis=~\"$genesis\",consensus=\"alpenglow\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\",schema=\"3\"}";

def alpenglow_included_increase:
  "increase(alpenglow_observed_included_total" + alpenglow_selector + "[10m])";

def alpenglow_expected_increase:
  "increase(alpenglow_observed_expected_total" + alpenglow_selector + "[10m])";

def alpenglow_missed_increase:
  "increase(alpenglow_observed_missed_total" + alpenglow_selector + "[10m])";

def alpenglow_rate:
  "(100 * " + alpenglow_included_increase + " / " + alpenglow_expected_increase + ") and on(cluster,genesis,consensus,pubkey,vote_account,schema) (" + alpenglow_expected_increase + " > 0)";

def alpenglow_disclosure:
  "RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry";

def stat_panel($id; $title; $description; $expr; $unit; $x; $thresholds):
  {
    "datasource": datasource,
    "description": $description,
    "fieldConfig": {
      "defaults": {
        "color": {"mode": "thresholds"},
        "decimals": 2,
        "mappings": [],
        "noValue": "N/A",
        "thresholds": {"mode": "absolute", "steps": $thresholds},
        "unit": $unit
      },
      "overrides": []
    },
    "gridPos": {"h": 3, "w": 6, "x": $x, "y": 8},
    "id": $id,
    "interval": "1m",
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "horizontal",
      "reduceOptions": {
        "calcs": ["lastNotNull"],
        "fields": "",
        "values": false
      },
      "textMode": "auto"
    },
    "pluginVersion": "9.2.3",
    "targets": [target("A"; $expr; $title)],
    "title": $title,
    "transparent": true,
    "type": "stat"
  };

def timeline_panel($id; $title; $description; $expr; $x; $mappings):
  {
    "datasource": datasource,
    "description": $description,
    "fieldConfig": {
      "defaults": {
        "color": {"mode": "palette-classic"},
        "custom": {
          "fillOpacity": 80,
          "lineWidth": 0,
          "spanNulls": true
        },
        "mappings": [{"options": $mappings, "type": "value"}],
        "noValue": "No data"
      },
      "overrides": []
    },
    "gridPos": {"h": 3, "w": 12, "x": $x, "y": 20},
    "id": $id,
    "interval": "1m",
    "options": {
      "alignValue": "center",
      "legend": {
        "displayMode": "hidden",
        "placement": "bottom",
        "showLegend": false
      },
      "mergeValues": true,
      "rowHeight": 0.8,
      "showValue": "always",
      "tooltip": {"mode": "single", "sort": "none"}
    },
    "pluginVersion": "9.2.3",
    "targets": [target("A"; $expr; $title)],
    "title": $title,
    "transparent": true,
    "type": "state-timeline"
  };

def observed_inclusion_panel:
  {
    "datasource": datasource,
    "description": (alpenglow_disclosure + ". Rolling ten-minute inclusion percentage; periods with zero estimated opportunities are omitted."),
    "fieldConfig": {
      "defaults": {
        "color": {"mode": "palette-classic"},
        "custom": {"drawStyle": "line", "fillOpacity": 15, "lineWidth": 1, "spanNulls": false},
        "decimals": 2,
        "mappings": [],
        "min": 0,
        "max": 100,
        "noValue": "No vote opportunities in the last 10 minutes",
        "unit": "percent"
      },
      "overrides": []
    },
    "gridPos": {"h": 8, "w": 24, "x": 0, "y": 59},
    "id": 171,
    "interval": "$inter",
    "maxDataPoints": 1200,
    "options": {
      "legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "right", "showLegend": true},
      "tooltip": {"mode": "multi", "sort": "desc"}
    },
    "targets": [target("A"; alpenglow_rate; "Inclusion rate")],
    "title": "Alpenglow inclusion rate history",
    "transparent": true,
    "type": "timeseries"
  };

def alpenglow_status_expression:
  ("alpenglow_observed_ready" + alpenglow_selector) as $ready
  | ("time() - timestamp(alpenglow_observed_observed_slot" + alpenglow_selector + ")") as $age
  | alpenglow_expected_increase as $expected
  | (
      "((0 * ((" + $age + ") > 5)) + 4)"
      + " or on(cluster,genesis,consensus,pubkey,vote_account,schema) ((0 * ((" + $ready + " == 1) and on(cluster,genesis,consensus,pubkey,vote_account,schema) ((" + $age + ") <= 5) and on(cluster,genesis,consensus,pubkey,vote_account,schema) (" + $expected + " == 0))) + 3)"
      + " or on(cluster,genesis,consensus,pubkey,vote_account,schema) ((0 * ((" + $ready + " == 1) and on(cluster,genesis,consensus,pubkey,vote_account,schema) ((" + $age + ") <= 5) and on(cluster,genesis,consensus,pubkey,vote_account,schema) (" + $expected + " > 0))) + 2)"
      + " or on(cluster,genesis,consensus,pubkey,vote_account,schema) (((0 * ((" + $ready + " == 1) and on(cluster,genesis,consensus,pubkey,vote_account,schema) ((" + $age + ") <= 5))) + 2) unless on(cluster,genesis,consensus,pubkey,vote_account,schema) " + $expected + ")"
      + " or on(cluster,genesis,consensus,pubkey,vote_account,schema) ((0 * ((" + $ready + " == 0) and on(cluster,genesis,consensus,pubkey,vote_account,schema) ((" + $age + ") <= 5))) + 1)"
    );

def observed_status_panel:
  ("alpenglow_observed_ready" + alpenglow_selector) as $ready
  | ("time() - timestamp(alpenglow_observed_observed_slot" + alpenglow_selector + ")") as $age
  | alpenglow_expected_increase as $expected
  | alpenglow_status_expression as $status
  | {
    "datasource": datasource,
    "description": (alpenglow_disclosure + ". Uses the latest ready value and actual sample timestamp; samples older than five seconds are stale."),
    "fieldConfig": {
      "defaults": {
        "color": {"mode": "thresholds"},
        "decimals": 0,
        "mappings": [{
          "options": {
            "1": {"color": "orange", "index": 0, "text": "Collecting / latest gap unattributed"},
            "2": {"color": "green", "index": 1, "text": "Current gap attributed"},
            "3": {"color": "blue", "index": 2, "text": "No vote opportunities in the last 10 minutes"},
            "4": {"color": "red", "index": 3, "text": "Stale — last sample older than 5 seconds"}
          },
          "type": "value"
        }],
        "noValue": "No recent samples",
        "thresholds": {"mode": "absolute", "steps": [{"color": "orange", "value": null}]},
        "unit": "none"
      },
      "overrides": []
    },
    "gridPos": {"h": 4, "w": 6, "x": 18, "y": 55},
    "id": 170,
    "interval": "2s",
    "maxDataPoints": 1,
    "options": {
      "colorMode": "background",
      "graphMode": "none",
      "justifyMode": "auto",
      "orientation": "horizontal",
      "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
      "textMode": "value_and_name"
    },
    "pluginVersion": "9.2.3",
    "targets": [
      (target("A"; $ready; "Ready") | .hide = true),
      (target("B"; $age; "Sample age") | .hide = true),
      (target("C"; $expected; "Estimated opportunities") | .hide = true),
      target("D"; $status; "Collection status")
    ],
    "title": "Alpenglow collection status",
    "transparent": true,
    "type": "stat"
  };

def target_signature:
  [.targets[] | {datasource,editorMode,expr,hide,legendFormat,range,refId,instant}];

def alpenglow_v3_canonical:
  ("alpenglow_observed_ready" + alpenglow_selector) as $ready
  | ("time() - timestamp(alpenglow_observed_observed_slot" + alpenglow_selector + ")") as $age
  | alpenglow_status_expression as $status
  | ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171 or .id == 172)] | length == 4)
  and ([.panels[] | select(.id == 168 or .id == 169 or .id == 170 or .id == 171) | .id] | sort == [168,169,170,171])
  and ([.panels[].id] | index(172) == null)
  and any(.panels[];
    .id == 168
    and .title == "Alpenglow vote inclusion rate — last 10 minutes"
    and .description == (alpenglow_disclosure + ". Rolling included estimate divided by rolling expected estimate; zero-opportunity windows are shown as no value.")
    and .type == "stat"
    and .gridPos == {"h":4,"w":6,"x":0,"y":55}
    and .fieldConfig.defaults.unit == "percent"
    and .fieldConfig.defaults.noValue == "No vote opportunities in the last 10 minutes"
    and .fieldConfig.defaults.mappings == []
    and (target_signature == [{"datasource":datasource,"editorMode":"code","expr":alpenglow_rate,"hide":false,"legendFormat":"Alpenglow vote inclusion rate — last 10 minutes","range":false,"refId":"A","instant":true}])
  )
  and any(.panels[];
    .id == 169
    and .title == "Alpenglow vote counts — last 10 minutes"
    and .description == (alpenglow_disclosure + ". Display-rounded rolling estimates account for increase() extrapolation at window boundaries.")
    and .type == "stat"
    and .gridPos == {"h":4,"w":12,"x":6,"y":55}
    and .fieldConfig.defaults.unit == "none"
    and .fieldConfig.defaults.noValue == "No recent samples"
    and .fieldConfig.defaults.mappings == []
    and (target_signature == [
      {"datasource":datasource,"editorMode":"code","expr":("round(" + alpenglow_included_increase + ")"),"hide":false,"legendFormat":"Included","range":false,"refId":"A","instant":true},
      {"datasource":datasource,"editorMode":"code","expr":("round(" + alpenglow_expected_increase + ")"),"hide":false,"legendFormat":"Estimated possible","range":false,"refId":"B","instant":true},
      {"datasource":datasource,"editorMode":"code","expr":("round(" + alpenglow_missed_increase + ")"),"hide":false,"legendFormat":"Estimated missed","range":false,"refId":"C","instant":true}
    ])
  )
  and any(.panels[];
    .id == 170
    and .title == "Alpenglow collection status"
    and .description == (alpenglow_disclosure + ". Uses the latest ready value and actual sample timestamp; samples older than five seconds are stale.")
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
    and (target_signature == [
      {"datasource":datasource,"editorMode":"code","expr":$ready,"hide":true,"legendFormat":"Ready","range":false,"refId":"A","instant":true},
      {"datasource":datasource,"editorMode":"code","expr":$age,"hide":true,"legendFormat":"Sample age","range":false,"refId":"B","instant":true},
      {"datasource":datasource,"editorMode":"code","expr":alpenglow_expected_increase,"hide":true,"legendFormat":"Estimated opportunities","range":false,"refId":"C","instant":true},
      {"datasource":datasource,"editorMode":"code","expr":$status,"hide":false,"legendFormat":"Collection status","range":false,"refId":"D","instant":true}
    ])
  )
  and any(.panels[];
    .id == 171
    and .title == "Alpenglow inclusion rate history"
    and .description == (alpenglow_disclosure + ". Rolling ten-minute inclusion percentage; periods with zero estimated opportunities are omitted.")
    and .type == "timeseries"
    and .gridPos == {"h":8,"w":24,"x":0,"y":59}
    and .fieldConfig.defaults.unit == "percent"
    and .fieldConfig.defaults.noValue == "No vote opportunities in the last 10 minutes"
    and .fieldConfig.defaults.custom.spanNulls == false
    and .fieldConfig.defaults.mappings == []
    and (target_signature == [{"datasource":datasource,"editorMode":"code","expr":alpenglow_rate,"hide":false,"legendFormat":"Inclusion rate","range":true,"refId":"A","instant":false}])
  );

def mount_filter:
  "^/((boot|dev|proc|run|snap|sys|tmp|var/lib|var/snap|var/tmp)(/.*)?|(home/[^/]+|mnt)/[.].*)$";

def fstype_filter:
  "^(autofs|binfmt_misc|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|efivarfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|securityfs|squashfs|sysfs|tmpfs|tracefs)$";

def interface_filter:
  "^(lo|docker.*|veth.*|br-.*|virbr.*|tailscale.*|wg.*|tun.*|tap.*|cni.*|flannel.*|cali.*|kube.*|nodelocal.*|nodellocal.*)$";

(.templating.list[] | select(.name == "pubkey")) as $pubkey_var
| (.templating.list[] | select(.name == "server")) as $server_var
| (.templating.list[] | select(.name == "inter")) as $interval_var
| ((.panels[] | select(.id == 29) | .fieldConfig.defaults.mappings[0].options) // {}) as $old_version_mappings
| ($old_version_mappings + {
    "0": {"color": "gray", "text": "Unknown"},
    "420": {"color": "blue", "text": "4.2.0"},
    "421": {"color": "green", "text": "4.2.1"},
    "422": {"color": "yellow", "text": "4.2.2"},
    "430": {"color": "orange", "text": "4.3.0"},
    "4303": {"color": "orange", "text": "4.3.0 beta 3"},
    "4305": {"color": "semi-dark-orange", "text": "4.3.0 beta 5"}
  }) as $version_mappings
| {
    "current": (
      if $pubkey_var.current.value == "4QNekaDqrLmUENqkVhGCJrgHziPxkX9kridbKwunx9su"
      then {
        "selected": false,
        "text": "mainnet-stakeconomy — 4QNekaDqrLmUENqkVhGCJrgHziPxkX9kridbKwunx9su",
        "value": "4QNekaDqrLmUENqkVhGCJrgHziPxkX9kridbKwunx9su"
      }
      else $pubkey_var.current
      end
    ),
    "datasource": datasource,
    "definition": "query_result(label_join(topk(1, tlast_over_time(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\"}[24h])) by (pubkey), \"a_display\", \" — \", \"host\", \"pubkey\"))",
    "description": "Select a validator identity after selecting a cluster and genesis. The system host is derived from its newest schema-v2 monitor sample.",
    "hide": 0,
    "includeAll": false,
    "label": "Validator / system",
    "multi": false,
    "name": "pubkey",
    "options": [],
    "query": {
      "query": "query_result(label_join(topk(1, tlast_over_time(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\"}[24h])) by (pubkey), \"a_display\", \" — \", \"host\", \"pubkey\"))",
      "refId": "StandardVariableQuery"
    },
    "refresh": 1,
    "regex": "/a_display=\"(?<text>[^\"]+)\".*pubkey=\"(?<value>[^\"]+)\"/",
    "skipUrlSync": false,
    "sort": 1,
    "type": "query"
  } as $new_pubkey_var
| {
    "current": {"selected": false, "text": "", "value": ""},
    "datasource": datasource,
    "definition": "label_values(nodemonitor_collectorUp,cluster)",
    "description": "Required cluster scope. Untagged legacy data is intentionally excluded.",
    "hide": 0, "includeAll": false, "label": "Cluster", "multi": false,
    "name": "cluster", "options": [],
    "query": {"query": "label_values(nodemonitor_collectorUp,cluster)", "refId": "StandardVariableQuery"},
    "refresh": 1, "regex": "", "skipUrlSync": false, "sort": 1, "type": "query"
  } as $new_cluster_var
| {
    "current": {"selected": false, "text": "", "value": ""},
    "datasource": datasource,
    "definition": "label_values(nodemonitor_collectorUp{cluster=~\"$cluster\"},genesis)",
    "description": "Required exact genesis scope for the selected cluster.",
    "hide": 0, "includeAll": false, "label": "Genesis", "multi": false,
    "name": "genesis", "options": [],
    "query": {"query": "label_values(nodemonitor_collectorUp{cluster=~\"$cluster\"},genesis)", "refId": "StandardVariableQuery"},
    "refresh": 1, "regex": "", "skipUrlSync": false, "sort": 1, "type": "query"
  } as $new_genesis_var
| {
    "current": {"selected": false, "text": "", "value": ""},
    "datasource": datasource,
    "definition": "label_values(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\"},vote_account)",
    "description": "Required monitored vote account scope for the selected identity.",
    "hide": 0, "includeAll": false, "label": "Vote account", "multi": false,
    "name": "vote_account", "options": [],
    "query": {"query": "label_values(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\"},vote_account)", "refId": "StandardVariableQuery"},
    "refresh": 1, "regex": "", "skipUrlSync": false, "sort": 1, "type": "query"
  } as $new_vote_account_var
| {
    "current": $server_var.current,
    "datasource": datasource,
    "definition": "query_result(topk(1, tlast_over_time(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}[24h])))",
    "description": "Automatically derived from the selected validator identity.",
    "hide": 2,
    "includeAll": false,
    "label": "System host",
    "multi": false,
    "name": "server",
    "options": [],
    "query": {
      "query": "query_result(topk(1, tlast_over_time(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\"}[24h])))",
      "refId": "StandardVariableQuery"
    },
    "refresh": 1,
    "regex": "/host=\"([^\"]+)\"/",
    "skipUrlSync": true,
    "sort": 1,
    "type": "query"
  } as $new_server_var
| {
    "allValue": ".*",
    "current": {"selected": true, "text": "All", "value": "$__all"},
    "datasource": datasource,
    "definition": "label_values(disk_used_percent{host=\"$server\",path!~\"^/((boot|dev|proc|run|snap|sys|tmp|var/lib|var/snap|var/tmp)(/.*)?|(home/[^/]+|mnt)/[.].*)$\",fstype!~\"^(autofs|binfmt_misc|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|efivarfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|securityfs|squashfs|sysfs|tmpfs|tracefs)$\"},path)",
    "hide": 0,
    "includeAll": true,
    "label": "Mount point",
    "multi": true,
    "name": "mountpoint",
    "options": [],
    "query": {
      "query": "label_values(disk_used_percent{host=\"$server\",path!~\"^/((boot|dev|proc|run|snap|sys|tmp|var/lib|var/snap|var/tmp)(/.*)?|(home/[^/]+|mnt)/[.].*)$\",fstype!~\"^(autofs|binfmt_misc|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|efivarfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|securityfs|squashfs|sysfs|tmpfs|tracefs)$\"},path)",
      "refId": "StandardVariableQuery"
    },
    "refresh": 1,
    "regex": "",
    "skipUrlSync": false,
    "sort": 1,
    "type": "query"
  } as $mountpoint_var
| {
    "allValue": ".*",
    "current": {"selected": true, "text": "All", "value": "$__all"},
    "datasource": datasource,
    "definition": ("label_values(net_bytes_recv{host=\"$server\",interface!~\"" + interface_filter + "\"},interface)"),
    "hide": 0,
    "includeAll": true,
    "label": "Network interface",
    "multi": true,
    "name": "interface",
    "options": [],
    "query": {
      "query": ("label_values(net_bytes_recv{host=\"$server\",interface!~\"" + interface_filter + "\"},interface)"),
      "refId": "StandardVariableQuery"
    },
    "refresh": 1,
    "regex": "",
    "skipUrlSync": false,
    "sort": 1,
    "type": "query"
  } as $interface_var
| ($interval_var
    | .auto_min = "1m"
    | .current = {"selected": false, "text": "1m", "value": "1m"}
    | .query = "1m,2m,5m,10m,30m,1h"
    | .options |= map(select(.value != "10s" and .value != "30s"))
    | .options |= map(.selected = (.value == "1m"))
  ) as $new_interval_var
| .templating.list = [$new_cluster_var, $new_genesis_var, $new_pubkey_var, $new_vote_account_var, $new_server_var, $mountpoint_var, $interface_var, $new_interval_var]
| (any(.panels[]; .id == 160)) as $layout_done
| (any(.panels[]; .id == 166)) as $health_first_done
| (any(.panels[]; .id as $id | ([168, 169, 170, 171, 172] | index($id)) != null)) as $observed_inclusion_present
| (any(.panels[]; .id == 171 and .gridPos == {"h":8,"w":24,"x":0,"y":58})) as $observed_inclusion_legacy_height
| alpenglow_v3_canonical as $observed_inclusion_done
| (any(.panels[]; .id == 54 and .targets[0].instant == true and .targets[0].range == false)) as $query_optimization_done
| (($pubkey_var.label == "Validator / system") and ($server_var.hide == 2)) as $selector_linked
| .panels |= map(
    if ($layout_done | not) and .gridPos.y >= 17 then
      .gridPos.y += 6
    elif ($layout_done | not) and .gridPos.y >= 8 then
      .gridPos.y += 3
    else
      .
    end
  )
| .panels |= map(
    if .id == 115 then
      .title = "Overview — validator $pubkey / host $server"
    elif .id == 120 then
      .gridPos = {"h": 2, "w": 6, "x": 0, "y": 3}
      | .options.content = "# Stakeconomy Community Monitoring Dashboard\nThe upper cards are validator health first: freshness uses the finalized slot; scheduled-slot production comes from `getBlockProduction`. Epoch and account cards are secondary.\n\n*Provided by [Stakeconomy.com](https://stakeeconomy.com) · [Monitoring repository](https://github.com/stakeeconomy/solanamonitoring)*"
    elif .id == 97 then
      .targets[0].expr = "nodemonitor_pctEpochElapsed{pubkey=\"$pubkey\"}"
    elif .id == 124 then
      .targets[0].expr = "nodemonitor_epochEnds{pubkey=\"$pubkey\"}"
    elif .id == 54 then
      .fieldConfig.defaults.mappings[0].options += {
        "4": {"color": "dark-red", "text": "Configuration/RPC unavailable"}
      }
      | .fieldConfig.defaults.thresholds.steps = (
          (.fieldConfig.defaults.thresholds.steps | map(select(.value != 4)))
          + [{"color": "dark-red", "value": 4}]
        )
    elif .id == 99 then
      .title = "Scheduled slots with a block present"
      | .description = "getBlockProduction scheduled slots with a block present; this is not an Alpenglow Votor or certificate-finality metric."
      | .fieldConfig.defaults.displayName = "Scheduled slots present"
      | .targets[0].expr = "nodemonitor_leaderSlots{pubkey=\"$pubkey\"}"
    elif .id == 100 then
      .title = "Scheduled-slot absence"
      | .description = "getBlockProduction scheduled slots without a block present; this is not an Alpenglow Votor or certificate-finality metric."
      | .fieldConfig.defaults.displayName = "Scheduled slots absent"
      | .targets[0].expr = "nodemonitor_skippedSlots{pubkey=\"$pubkey\"}"
    elif .id == 62 then
      .gridPos = {"h": 3, "w": 6, "x": 12, "y": 8}
      | .fieldConfig.defaults.displayName = "Skip rate"
      | .targets[0].expr = "nodemonitor_pctSkipped{pubkey=\"$pubkey\"}"
    elif .id == 43 then
      .targets[0].expr = "nodemonitor_activatedStake{pubkey=\"$pubkey\"}"
    elif .id == 145 then
      .title = "Cluster nodes"
      | .targets[0].expr = "nodemonitor_nodes{pubkey=\"$pubkey\"}"
    elif .id == 147 then
      .title = "Community validators online"
      | .description = "Validators that sent a status sample during the last 10 minutes."
      | .targets[0].expr = "count(count(last_over_time(nodemonitor_collectorUp{cluster=~\"$cluster\",genesis=~\"$genesis\"}[10m])) by (pubkey))"
      | .targets[0].legendFormat = "Online reporters"
    elif .id == 71 then
      .title = "Root filesystem"
      | .targets[0].expr = "disk_used_percent{host=\"$server\",path=\"/\"}"
      | .targets[0].legendFormat = "/"
    elif .id == 89 then
      .title = "Selected disk max"
      | .description = "Highest utilization among the selected data mount points. Runtime, package, container, hidden and virtual filesystems are excluded."
      | .targets[0].expr = ("max(disk_used_percent{host=\"$server\",path=~\"$mountpoint\",path!~\"" + mount_filter + "\",fstype!~\"" + fstype_filter + "\"})")
      | .targets[0].legendFormat = "Selected max"
    elif .id == 90 then
      .title = "Host disk max"
      | .description = "Highest utilization across relevant data filesystems. /var/lib, boot, runtime, package, container, hidden and virtual mounts are excluded."
      | .targets[0].expr = ("max(disk_used_percent{host=\"$server\",path!~\"" + mount_filter + "\",fstype!~\"" + fstype_filter + "\"})")
      | .targets[0].legendFormat = "Host max"
    elif .id == 69 then
      .title = "5m load / CPU"
      | .description = "Five-minute load average normalized by logical CPU count, so differently sized hosts are comparable."
      | .targets[0].expr = "100 * system_load5{host=\"$server\"} / system_n_cpus{host=\"$server\"}"
      | .targets[0].legendFormat = "Load / CPU"
      | .fieldConfig.defaults.unit = "percent"
      | .fieldConfig.defaults.min = 0
      | .fieldConfig.defaults.thresholds.steps = [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 70},
          {"color": "red", "value": 100}
        ]
    elif .id == 142 then
      .title = "SOL/USD"
      | .targets[0].expr = "nodemonitor_solanaPrice{pubkey=\"$pubkey\"}"
    elif .id == 92 then
      .title = "System uptime"
      | .targets[0].expr = "system_uptime{host=\"$server\"}"
    elif .id == 44 then
      .targets[0].expr = "nodemonitor_commission{pubkey=\"$pubkey\"}"
    elif .id == 98 then
      .targets[0].expr = "nodemonitor_epoch{pubkey=\"$pubkey\"}"
    elif .id == 29 then
      .title = "Software version"
      | .description = "Numeric version code reported by the monitor. The timeline below makes upgrades visible against performance."
      | .fieldConfig.defaults.mappings[0].options = $version_mappings
    elif .id == 117 then
      .title = "Validator performance — $pubkey"
    elif .id == 56 then
      .targets |= map(select(.refId != "C" and .legendFormat != "Solana Version"))
      | .fieldConfig.overrides |= map(select(.matcher.options != "Solana Version"))
      | .description = "Validator and cluster skip rates. Software changes are shown separately in the aligned timeline below."
      | .targets[0].expr = "nodemonitor_pctSkipped{pubkey=\"$pubkey\"}"
      | .targets[1].expr = "nodemonitor_pctTotSkipped{pubkey=\"$pubkey\"}"
    elif .id == 144 then
      .targets[0].expr = "rate(nodemonitor_tps{pubkey=\"$pubkey\"}[5m])"
      | .description = "Five-minute rate of the cluster transaction counter."
    elif .id == 75 then
      .title = "Leader slots and skips"
      | .targets[0].expr = "nodemonitor_leaderSlots{pubkey=\"$pubkey\"}"
      | .targets[1].expr = "nodemonitor_skippedSlots{pubkey=\"$pubkey\"}"
    elif .id == 61 then
      .title = "Tower vote-credit rate"
      | .targets[0].expr = "rate(nodemonitor_credits{consensus=\"tower\",pubkey=\"$pubkey\"}[5m])"
      | .targets[0].legendFormat = "Tower vote-credit rate"
      | .description = "Five-minute rate of Tower vote credits; it is intentionally unavailable on Alpenglow clusters."
    elif .id == 126 then
      .title = "Tower vote-credit efficiency"
      | .description = "Tower-only credit-efficiency estimate. It is intentionally unavailable on Alpenglow clusters."
      | .targets[0].legendFormat = "Tower vote-credit efficiency"
      | .fieldConfig.defaults.unit = "percent"
      | .fieldConfig.defaults.min = 0
      | .fieldConfig.defaults.max = 100
      | .targets[0].expr = "nodemonitor_pctVote{consensus=\"tower\",pubkey=\"$pubkey\"}/16"
    elif .id == 121 then
      .title = "Tower epoch vote credits"
      | .description = "Tower-only epoch vote-credit accounting. It is intentionally unavailable on Alpenglow clusters."
      | .targets[0].legendFormat = "Tower epoch vote credits"
      | .targets[0].expr = "nodemonitor_validatorCreditsCurrent{consensus=\"tower\",pubkey=\"$pubkey\"}"
    elif .id == 164 then
      .gridPos = {"h": 2, "w": 2, "x": 16, "y": 1}
      | .title = "Cluster delinquent stake"
      | .description = "Current percentage of activated cluster stake on delinquent vote accounts."
      | .targets[0].legendFormat = "Delinquent stake"
      | .targets[0].expr = "nodemonitor_pctTotDelinquent{pubkey=\"$pubkey\"}"
      | .fieldConfig.defaults.min = 0
      | .fieldConfig.defaults.max = 100
      | .fieldConfig.defaults.thresholds.steps = [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 5},
          {"color": "red", "value": 15}
        ]
    elif .id == 165 then
      .gridPos = {"h": 3, "w": 6, "x": 18, "y": 8}
      | .title = "Alpenglow reward accounting"
      | .description = (alpenglow_disclosure + ". Post-migration epochCredits tuple delta shown in SOL; reward accounting only, not performance.")
      | .targets[0].legendFormat = "Alpenglow reward accounting"
      | .targets[0].expr = "nodemonitor_alpenglowRewardAccountingLamports{consensus=\"alpenglow\",pubkey=\"$pubkey\"} / 1e9"
      | .fieldConfig.defaults.unit = "SOL"
      | .fieldConfig.defaults.min = 0
      | .fieldConfig.defaults.max = null
      | .fieldConfig.defaults.thresholds.steps = [{"color": "green", "value": null}]
    elif .id == 4 then
      .title = "Identity-account balance"
      | .description = "SOL held by the selected validator identity account."
      | .targets[0].legendFormat = "Identity balance"
      | .targets[0].expr = "nodemonitor_validatorBalance{pubkey=\"$pubkey\"}"
      | .fieldConfig.defaults.thresholds.steps = [{"color": "green", "value": null}]
    elif .id == 122 then
      .targets[0].legendFormat = "Active stake"
      | .targets[0].expr = "nodemonitor_activatedStake{pubkey=\"$pubkey\"}"
      | .options.legend.calcs = ["lastNotNull", "min", "max"]
    elif .id == 57 then
      .title = "Vote-account balance"
      | .description = "SOL held by the selected validator vote account."
      | .targets[0].legendFormat = "Vote-account balance"
      | .targets[0].expr = "nodemonitor_validatorVoteBalance{pubkey=\"$pubkey\"}"
      | .fieldConfig.defaults.thresholds.steps = [{"color": "green", "value": null}]
    elif .id == 113 then
      .title = "System metrics — $server"
    elif .id == 104 then
      .description = "CPU time by the five categories that matter operationally. Per-core collection is intentionally disabled in the optimized Telegraf profile."
      | .targets = [
          target("A"; "cpu_usage_user{host=\"$server\",cpu=\"cpu-total\"}"; "User"),
          target("B"; "cpu_usage_system{host=\"$server\",cpu=\"cpu-total\"}"; "System"),
          target("C"; "cpu_usage_softirq{host=\"$server\",cpu=\"cpu-total\"}"; "Soft IRQ"),
          target("D"; "cpu_usage_iowait{host=\"$server\",cpu=\"cpu-total\"}"; "I/O wait"),
          target("E"; "cpu_usage_steal{host=\"$server\",cpu=\"cpu-total\"}"; "Steal")
        ]
    elif .id == 102 then
      .title = "Filesystem utilization — $mountpoint"
      | .description = "Utilization for selected data mount points. /var/lib, boot, runtime, package, container, hidden and virtual filesystems are excluded."
      | .targets = [target(
          "A";
          ("max(disk_used_percent{host=\"$server\",path=~\"$mountpoint\",path!~\"" + mount_filter + "\",fstype!~\"" + fstype_filter + "\"}) by (path)");
          "{{path}}"
        )]
      | .fieldConfig.defaults.unit = "percent"
      | .fieldConfig.defaults.min = 0
      | .fieldConfig.defaults.max = 100
      | .fieldConfig.defaults.decimals = 1
      | .fieldConfig.defaults.thresholds = {
          "mode": "absolute",
          "steps": [
            {"color": "green", "value": null},
            {"color": "yellow", "value": 70},
            {"color": "red", "value": 85}
          ]
        }
      | .fieldConfig.overrides = []
    elif .id == 85 then
      .title = "Load per CPU capacity"
      | .description = "Load averages normalized by logical CPU count; 100% means one runnable task per logical CPU."
      | .targets[0].expr = "100 * system_load1{host=\"$server\"} / system_n_cpus{host=\"$server\"}"
      | .targets[0].legendFormat = "1 minute"
      | .targets[1].expr = "100 * system_load5{host=\"$server\"} / system_n_cpus{host=\"$server\"}"
      | .targets[1].legendFormat = "5 minutes"
      | .targets[2].expr = "100 * system_load15{host=\"$server\"} / system_n_cpus{host=\"$server\"}"
      | .targets[2].legendFormat = "15 minutes"
      | .fieldConfig.defaults.unit = "percent"
      | .fieldConfig.defaults.max = 150
    elif .id == 139 then
      .targets = [
          target("A"; "swap_used{host=\"$server\"}"; "Used"),
          target("B"; "swap_total{host=\"$server\"}"; "Total")
        ]
    elif .id == 108 then
      .description = "Host memory totals without redundant aggregation over a single selected host."
      | .targets = [
          target("A"; "mem_used{host=\"$server\"}"; "Used"),
          target("B"; "mem_cached{host=\"$server\"}"; "Cached"),
          target("C"; "mem_free{host=\"$server\"}"; "Free"),
          target("D"; "mem_total{host=\"$server\"}"; "Total")
        ]
    elif .id == 111 then
      .title = "Network traffic — receive ↑ / transmit ↓ — $interface"
      | .description = "Mirrored traffic view: receive is shown above zero and transmit below zero. The negative transmit direction is a display transform only; stored values, legend statistics and tooltips remain positive."
      | .targets[0].expr = ("rate(net_bytes_recv{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])*8")
      | .targets[0].legendFormat = "{{interface}} receive"
      | .targets[1].expr = ("rate(net_bytes_sent{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])*8")
      | .targets[1].legendFormat = "{{interface}} transmit"
      | .fieldConfig.defaults.custom.axisCenteredZero = true
      | .fieldConfig.defaults.custom.axisPlacement = "left"
      | .fieldConfig.defaults.custom.axisLabel = "Receive (+) / Transmit (-)"
      | .options.legend = {
          "calcs": ["lastNotNull", "max"],
          "displayMode": "table",
          "placement": "right",
          "showLegend": true,
          "sortBy": "Last *",
          "sortDesc": true,
          "width": 300
        }
      | .options.tooltip = {"mode": "multi", "sort": "desc"}
      | .fieldConfig.overrides = [
          {
            "matcher": {"id": "byRegexp", "options": "/ transmit$/"},
            "properties": [
              {"id": "custom.transform", "value": "negative-Y"}
            ]
          }
        ]
    elif .id == 118 then
      .title = "System allocated file handles"
      | .description = "System-wide allocated file handles reported by the validator monitor; unavailable on system-only Telegraf hosts."
      | .targets[0].expr = "nodemonitor_openFiles{cluster=~\"$cluster\",genesis=~\"$genesis\",pubkey=\"$pubkey\",vote_account=~\"$vote_account\",host=\"$server\"}"
    elif .id == 135 then
      .targets[0].expr = "rate(net_udp_indatagrams{host=\"$server\"}[$__rate_interval])"
      | .targets[1].expr = "rate(net_udp_outdatagrams{host=\"$server\"}[$__rate_interval])"
    elif .id == 129 then
      .description = "The four process states most useful for validator troubleshooting."
      | .targets = [
          target("A"; "processes_total{host=\"$server\"}"; "Total"),
          target("B"; "processes_running{host=\"$server\"}"; "Running"),
          target("C"; "processes_blocked{host=\"$server\"}"; "Blocked"),
          target("D"; "processes_zombies{host=\"$server\"}"; "Zombies")
        ]
    elif .id == 133 then
      .description = "Useful TCP socket states; transitional noise is omitted."
      | .targets = [
          target("A"; "netstat_tcp_established{host=\"$server\"}"; "Established"),
          target("B"; "netstat_tcp_listen{host=\"$server\"}"; "Listen"),
          target("C"; "netstat_tcp_time_wait{host=\"$server\"}"; "Time wait"),
          target("D"; "netstat_tcp_close_wait{host=\"$server\"}"; "Close wait"),
          target("E"; "netstat_tcp_syn_recv{host=\"$server\"}"; "SYN received")
        ]
    elif .id == 127 then
      .targets[0].expr = "avg_over_time(cpu_usage_iowait{host=\"$server\",cpu=\"cpu-total\"}[10m])"
      | .description = "Ten-minute mean CPU time spent waiting for I/O."
    elif .id == 137 then
      .title = "Network errors and drops"
      | .description = "Per-second interface errors/drops plus UDP checksum, socket-buffer and no-listener errors."
      | .targets = [
          target("A"; ("rate(net_err_in{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])"); "{{interface}} receive errors"),
          target("B"; ("rate(net_err_out{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])"); "{{interface}} transmit errors"),
          target("C"; ("rate(net_drop_in{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])"); "{{interface}} receive drops"),
          target("D"; ("rate(net_drop_out{host=\"$server\",interface=~\"$interface\",interface!~\"" + interface_filter + "\"}[$__rate_interval])"); "{{interface}} transmit drops"),
          target("E"; "rate(nstat_UdpInCsumErrors{host=\"$server\"}[$__rate_interval])"; "UDP checksum errors"),
          target("F"; "rate(nstat_UdpInErrors{host=\"$server\"}[$__rate_interval])"; "UDP input errors"),
          target("G"; "rate(nstat_UdpNoPorts{host=\"$server\"}[$__rate_interval])"; "UDP no listener"),
          target("H"; "rate(nstat_UdpRcvbufErrors{host=\"$server\"}[$__rate_interval])"; "UDP receive-buffer errors"),
          target("I"; "rate(nstat_UdpSndbufErrors{host=\"$server\"}[$__rate_interval])"; "UDP send-buffer errors")
        ]
      | .fieldConfig.defaults.unit = "ops"
      | .fieldConfig.overrides = []
    elif .id == 131 then
      .targets[0].expr = "rate(kernel_context_switches{host=\"$server\"}[$__rate_interval])"
      | .targets[0].legendFormat = "Context switches"
    else
      .
    end
  )
| if $layout_done then
    .
  else
    .panels += [
      stat_panel(
        162; "Identity balance";
        "Current identity-account balance. Red below 1 SOL, yellow below 5 SOL.";
        "nodemonitor_validatorBalance{pubkey=\"$pubkey\"}";
        "SOL"; 0;
        [{"color": "red", "value": null}, {"color": "yellow", "value": 1}, {"color": "green", "value": 5}]
      ),
      stat_panel(
        163; "Vote-account balance";
        "Current vote-account balance.";
        "nodemonitor_validatorVoteBalance{pubkey=\"$pubkey\"}";
        "SOL"; 6;
        [{"color": "red", "value": null}, {"color": "green", "value": 1}]
      ),
      stat_panel(
        164; "Cluster delinquent stake";
        "Current percentage of activated cluster stake on delinquent vote accounts.";
        "nodemonitor_pctTotDelinquent{pubkey=\"$pubkey\"}";
        "percent"; 12;
        [{"color": "green", "value": null}, {"color": "yellow", "value": 5}, {"color": "red", "value": 15}]
      ),
      stat_panel(
        165; "Skip-rate gap";
        "Validator skip rate minus cluster skip rate, in percentage points.";
        "nodemonitor_pctSkipped{pubkey=\"$pubkey\"} - nodemonitor_pctTotSkipped{pubkey=\"$pubkey\"}";
        "percent"; 18;
        [{"color": "green", "value": null}, {"color": "yellow", "value": 1}, {"color": "red", "value": 3}]
      ),
      timeline_panel(
        160; "Validator software version";
        "Software version state aligned with the skip-rate chart above. A color boundary marks an upgrade without overlaying another line on performance data.";
        "nodemonitor_version{pubkey=\"$pubkey\"}";
        0; $version_mappings
      ),
      timeline_panel(
        161; "Validator health state";
        "Validating, delinquent and monitor-error periods aligned with cluster TPS above.";
        "nodemonitor_status{pubkey=\"$pubkey\"}";
        12; {
          "0": {"color": "green", "text": "Validating"},
          "1": {"color": "blue", "text": "Up"},
          "2": {"color": "orange", "text": "Monitor/RPC error"},
          "3": {"color": "dark-red", "text": "Delinquent"},
          "4": {"color": "red", "text": "Configuration/RPC unavailable"}
        }
      )
    ]
  end
| if $health_first_done then
    .
  else
    .panels += [
      (
        stat_panel(
          166; "Vote freshness";
          "Finalized slot minus last vote. Lower is fresher; this is a one-minute collector health signal, not certificate finality.";
          "nodemonitor_finalizedSlot{pubkey=\"$pubkey\"} - nodemonitor_lastVote{pubkey=\"$pubkey\"}";
          "none"; 0;
          [{"color": "green", "value": null}, {"color": "yellow", "value": 8}, {"color": "red", "value": 32}]
        ) | .gridPos = {"h": 2, "w": 3, "x": 0, "y": 1}
      ),
      (
        stat_panel(
          167; "Root freshness";
          "Finalized slot minus root slot. Lower is fresher; this is a one-minute collector health signal, not certificate finality.";
          "nodemonitor_finalizedSlot{pubkey=\"$pubkey\"} - nodemonitor_rootSlot{pubkey=\"$pubkey\"}";
          "none"; 3;
          [{"color": "green", "value": null}, {"color": "yellow", "value": 8}, {"color": "red", "value": 32}]
        ) | .gridPos = {"h": 2, "w": 3, "x": 3, "y": 1}
      )
    ]
  end
| if $observed_inclusion_done then
    .
  else
    (if $observed_inclusion_present then
      .panels |= map(
        select(.id as $id | ([168, 169, 170, 171, 172] | index($id)) == null)
        | if $observed_inclusion_legacy_height and .gridPos.y >= 66 then .gridPos.y += 1 else . end
      )
    else
      .panels |= map(if .gridPos.y >= 55 then .gridPos.y += 12 else . end)
    end)
    | .panels += [
      (
        stat_panel(
          168; "Alpenglow vote inclusion rate — last 10 minutes";
          (alpenglow_disclosure + ". Rolling included estimate divided by rolling expected estimate; zero-opportunity windows are shown as no value.");
          alpenglow_rate;
          "percent"; 0;
          [{"color": "red", "value": null}, {"color": "yellow", "value": 80}, {"color": "green", "value": 95}]
        ) | .gridPos = {"h": 4, "w": 6, "x": 0, "y": 55}
        | .fieldConfig.defaults.max = 100
      ),
      (
        stat_panel(
          169; "Alpenglow vote counts — last 10 minutes";
          (alpenglow_disclosure + ". Display-rounded rolling estimates account for increase() extrapolation at window boundaries.");
          ("round(" + alpenglow_included_increase + ")");
          "none"; 8;
          [{"color": "green", "value": null}]
        ) | .gridPos = {"h": 4, "w": 12, "x": 6, "y": 55}
        | .targets = [
            target("A"; ("round(" + alpenglow_included_increase + ")"); "Included"),
            target("B"; ("round(" + alpenglow_expected_increase + ")"); "Estimated possible"),
            target("C"; ("round(" + alpenglow_missed_increase + ")"); "Estimated missed")
          ]
      ),
      observed_status_panel,
      observed_inclusion_panel
    ]
  end
| .panels |= map(
    if (.type == "stat" or .type == "gauge" or .type == "bargauge") then
      .maxDataPoints = 1
      | .targets |= map(.instant = true | .range = false)
      | .fieldConfig.defaults.noValue = (
          if .id == 168 then "No vote opportunities in the last 10 minutes"
          elif .id == 169 or .id == 170 then "No recent samples"
          else "No recent data"
          end
        )
      | if .type == "stat" then .options.graphMode = "none" else . end
    elif .type == "state-timeline" then
      .interval = "$inter"
      | .maxDataPoints = 1000
      | .targets |= map(.instant = false | .range = true)
    elif .type == "timeseries" then
      .id as $panel_id
      | .interval = (if ([56, 144, 75, 61, 126, 121, 76, 4, 122, 57] | index($panel_id)) != null then "$inter" else "30s" end)
      | .maxDataPoints = 1200
      | .targets |= map(.instant = false | .range = true)
    else
      .
    end
  )
| .panels |= sort_by(.gridPos.y, .gridPos.x, .id)
| walk(
    if type == "object" then
      (if has("expr") then
        (.expr |= scope_nodemonitor)
        | del(.alias, .dsType, .groupBy, .measurement, .orderByTime, .policy, .resultFormat, .select, .tags)
      else . end)
      | (if has("query") and (.query | type) == "string" then .query |= scope_nodemonitor else . end)
      | (if (.datasource? | type) == "object" and .datasource.type == "prometheus" then
          .datasource.uid = "${DS_PROMETHEUS}"
        else . end)
    else
      .
    end
  )
| .__inputs = [
    {
      "name": "DS_PROMETHEUS",
      "label": "VictoriaMetrics / Prometheus",
      "description": "Prometheus-compatible datasource backed by VictoriaMetrics or Prometheus",
      "type": "datasource",
      "pluginId": "prometheus",
      "pluginName": "Prometheus"
    }
  ]
| .__requires = [
    {"type": "grafana", "id": "grafana", "name": "Grafana", "version": "9.2.3"},
    {"type": "datasource", "id": "prometheus", "name": "Prometheus", "version": "1.0.0"}
  ]
| .description = "Solana validator and host health dashboard maintained by Stakeconomy.com. Links each validator identity to its reporting system host and supports dynamic mounts, interfaces, and aligned software/status timelines."
| .refresh = "1m"
| .timepicker.refresh_intervals = ["1m", "2m", "5m", "15m", "30m", "1h"]
| .annotations.list |= map(.enable = false)
| .version = ((.version // 0) + (if ($layout_done and $query_optimization_done and $selector_linked) then 0 else 1 end))
