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

# Every VX value must belong to this collection and the RPC current epoch.
# This also prevents Prometheus lookback from resurrecting omitted values.
def vx_metric($field): "nodemonitor_" + $field + "{consensus=\"alpenglow\",pubkey=\"$pubkey\"}";
def vx_recent($field):
  vx_metric($field) + " and (timestamp(" + vx_metric($field) + ") > time() - 150)";
def vx_value($field):
  vx_recent($field) + " and (" + vx_metric("vxDataFresh") + " == 1)" +
  " and (" + vx_metric("vxAdmitted") + " == 1)" +
  " and (" + vx_metric("vxEpoch") + " == " + vx_metric("epoch") + ")" +
  " and (timestamp(" + vx_metric($field) + ") == timestamp(" + vx_metric("vxDataFresh") + "))";
def vx_reward($kind):
  "(" + vx_value("vxReward" + $kind + "Lamports") +
  " and (" + vx_metric("vxReward" + $kind + "Available") + " == 1)) / 1e9";
def vx_next($field):
  vx_recent($field) + " and (" + vx_metric("vxApiUp") + " == 1)" +
  " and (" + vx_metric("vxNextEpochAvailable") + " == 1)" +
  " and (" + vx_metric("vxNextEpoch") + " == (" + vx_metric("epoch") + " + 1))" +
  " and (timestamp(" + vx_metric($field) + ") == timestamp(" + vx_metric("vxApiUp") + "))";
# Earnings has no source-slot watermark: recent successful collection is not proof of source freshness.
def vx_earnings($kind):
  ("vxEarnings" + $kind + "Lamports") as $field |
  "(" + vx_recent($field) + " and (" + vx_metric("vxEarningsApiUp") + " == 1)" +
  " and (" + vx_metric("vxEarningsEpoch") + " == " + vx_metric("epoch") + ")" +
  " and (" + vx_metric("vxEarnings" + $kind + "Available") + " == 1)" +
  " and (timestamp(" + vx_metric($field) + ") == timestamp(" + vx_metric("vxEarningsApiUp") + "))) / 1e9";
def named_target($id; $expr; $label): target($id; $expr; $label);

def vx_stat($id; $title; $desc; $expr; $unit; $x; $y):
  stat_panel($id; $title; $desc; $expr; $unit; $x;
    [{"color": "blue", "value": null}]) |
  .gridPos = {h: 4, w: 6, x: $x, y: $y} |
  .fieldConfig.defaults.decimals = (if $unit == "percent" then 4 elif $unit == "SOL" then 9 else 0 end);

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

def mount_filter:
  "^/((boot|dev|proc|run|snap|sys|tmp|var/lib|var/snap|var/tmp)(/.*)?|(home/[^/]+|mnt)/[.].*)$";

def fstype_filter:
  "^(autofs|binfmt_misc|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|efivarfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|securityfs|squashfs|sysfs|tmpfs|tracefs)$";

def interface_filter:
  "^(lo|docker.*|veth.*|br-.*|virbr.*|tailscale.*|wg.*|tun.*|tap.*|cni.*|flannel.*|cali.*|kube.*|nodelocal.*|nodellocal.*)$";

# Unpack our collapsed rows before rebuilding them (also handles exported expanded rows).
.panels |= [ .[] | if .id == 195 or .id == 197 or .id == 204 then .panels[]? else . end ]
| .panels |= map(select(.id != 205 and .id != 61 and .id != 121 and .id != 126))
| (.templating.list[] | select(.name == "pubkey")) as $pubkey_var
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
      | .description = "Post-migration epochCredits tuple delta shown in SOL; reward accounting only, not performance."
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
# Rebuild our owned VX panels so upgrades and reruns produce the same layout.
| .panels |= map(select(.id < 180 or .id > 201))
| ([.panels[].gridPos | .y + .h] | max) as $bottom
| ($bottom + 1) as $y
| .panels += [
    {id: 180, type: "row", title: "Alpenglow overview — VX",
     collapsed: false, panels: [], gridPos: {h: 1, w: 24, x: 0, y: $bottom}},
    (vx_stat(181; "Consensus Participation";
      "Current epoch: 100 × (notarizedSlots + skippedSlots) / eligibleSlots. Skip votes count as participation. Measures certificate inclusion, not all messages sent. Rank is VX competition rank + 1; ties are shared and rank may update less frequently than counts. Missing footers reduce coverage.";
      vx_value("vxParticipationPct"); "percent"; 0; $y) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_value("vxParticipationPct"); "Participation"),
                  named_target("B"; vx_value("vxParticipationRank"); "Rank (ties shared)")] |
      .fieldConfig.overrides = [{matcher: {id: "byName", options: "Rank (ties shared)"},
        properties: [{id: "unit", value: "none"}, {id: "decimals", value: 0}]}]),
    (vx_stat(193; "Fast-Vote Inclusion";
      "Current epoch: 100 × fastFinalizedSlots / finalizedCerts from VX. Denominator includes all decoded finalization certificates, not just fast certificates. Leader-sampled certificate inclusion, not a direct latency measurement. Solcircle FAST divides by fast certificates only; this metric divides by all decoded certificates and is not comparable to FAST. Missing, invalid or zero-denominator data is unknown.";
      vx_value("vxFastVoteInclusionPct"); "percent"; 6; $y) | .gridPos.h = 6),
    (vx_stat(187; "Epoch Rewards";
      "VX-calculated gross cumulative SOL this epoch. Total = Voting + Producer bonus, checked for consistency. Before commission allocation to validator/stakers, excluding transaction fees and MEV. Not confirmed net income. Missing components remain unknown; the accounting comparison is below.";
      vx_reward("Total"); "SOL"; 12; $y) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_reward("Total"); "Total"),
                  named_target("B"; vx_reward("Voting"); "Voting"),
                  named_target("C"; vx_reward("Producer"); "Producer bonus")]),
    (vx_stat(194; "Next-Epoch Admission";
      "VX admission record for local RPC epoch + 1. Not admitted is an operational warning: investigate VAT funding, BLS registration and other eligibility conditions; the response does not identify the cause. Missing or duplicate next-epoch records are unknown. Vote-account balance is the local RPC balance including rent reserve, not spendable VAT funds or proof of admission. No fixed fee threshold is assumed.";
      vx_next("vxNextEpochAdmitted"); "none"; 18; $y) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_next("vxNextEpochAdmitted"); "Admission"),
                  named_target("B"; vx_next("vxNextEpoch"); "Next epoch"),
                  named_target("C"; vx_recent("validatorVoteBalance"); "Vote-account balance")] |
      .fieldConfig.overrides = [
        {matcher: {id: "byName", options: "Admission"}, properties: [{id: "mappings", value: [
          {type: "value", options: {"0": {text: "Not admitted", color: "red"}, "1": {text: "Admitted", color: "green"}}}]}]},
        {matcher: {id: "byName", options: "Vote-account balance"},
         properties: [{id: "unit", value: "SOL"}, {id: "decimals", value: 9}]}]),
    {id: 197, type: "row", title: "Block revenue and estimated validator income — VX",
     collapsed: false, panels: [], gridPos: {h: 1, w: 24, x: 0, y: ($y + 6)}},
    (vx_stat(198; "Block Fees — Gross";
      "Cumulative current-epoch base fees and priority fees reported by VX earnings. Separate from the Alpenglow producer bonus. Excludes MEV. Earnings has no ingestion-slot watermark: a successful fetch does not prove source freshness.";
      vx_earnings("BaseFees"); "SOL"; 0; ($y + 7)) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_earnings("BaseFees"); "Base fees"),
                  named_target("B"; vx_earnings("PriorityFees"); "Priority fees")]),
    (vx_stat(199; "Validator Block Revenue";
      "VX-reported validator share of base plus priority fees, using the epoch block-revenue commission. Not the inflation commission. Excludes Alpenglow producer bonus and MEV. Missing rates remain unknown.";
      vx_earnings("BlockRevenue"); "SOL"; 6; ($y + 7)) | .gridPos.h = 6),
    (vx_stat(200; "MEV Tips and Estimated Share";
      "Gross Jito tips and estimated validator share at the separate MEV commission. VX may use the previous epoch rate until the current rate is available. Before block-builder and tip-router deductions; may overstate final proceeds. Unknown rates stay unknown; genuine zero tips remain zero.";
      vx_earnings("MevShare"); "SOL"; 12; ($y + 7)) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_earnings("MevTips"); "Gross tips"),
                  named_target("B"; vx_earnings("MevShare"); "Estimated validator share")]),
    (vx_stat(201; "Estimated Validator Income";
      "Current epoch before VAT and operating costs. Alpenglow estimate = (votingReward + producerBonus) × inflation commission. Total adds validator block-fee share and estimated MEV share from the same earnings response, never the gross producer bonus or voteAccountReward again. All three components must be available. Provisional rates, source lag, payout rounding and MEV deductions can change the result. Not net profit or confirmed payout.";
      vx_earnings("EstimatedTotal"); "SOL"; 18; ($y + 7)) |
      .gridPos.h = 6 | .options.orientation = "vertical" | .options.textMode = "value_and_name" |
      .targets = [named_target("A"; vx_earnings("EstimatedTotal"); "Estimated income before costs"),
                  named_target("B"; vx_earnings("EstimatedAlpenglow"); "Estimated Alpenglow commission")]),
    {id: 195, type: "row", title: "Alpenglow diagnostics — VX",
     collapsed: false, panels: [], gridPos: {h: 1, w: 24, x: 0, y: ($y + 13)}},
    vx_stat(182; "Missed Participations";
      "Current epoch eligible slots absent from both reward bitmaps. Does not prove the validator was offline; the producer may have omitted its vote. Unpayable slots and missing source data are excluded.";
      vx_value("vxMissedSlots"); "short"; 0; ($y + 14)),
    (vx_stat(183; "VX Data Fresh";
      "1: valid current-epoch source progress within the configured slot tolerance. 0: failed, missing, stale or disabled. Collector samples older than 150 seconds are hidden. Coverage is separate.";
      vx_recent("vxDataFresh"); "none"; 6; ($y + 14)) |
      .fieldConfig.defaults.mappings = [{type: "value", options: {"0": {text: "Unavailable / stale", color: "red"}, "1": {text: "Fresh", color: "green"}}}]),
    vx_stat(184; "VX Missing Footers";
      "Current epoch source gaps. Nonzero means participation is measured on incomplete coverage; it must not be treated as a complete epoch score.";
      vx_value("vxMissingFooters"); "short"; 12; ($y + 14)),
    vx_stat(189; "VX Source Lag";
      "Local RPC absolute slot minus VX last ingested reward slot, floored at zero. Aggregates update roughly every 25 seconds; collection is once per minute. Source progress too far ahead is also rejected.";
      vx_recent("vxSlotLag"); "short"; 18; ($y + 14)),
    vx_stat(190; "Missed Rewards — Epoch";
      "VX estimate of gross rewards missed through non-inclusion, in SOL this epoch. Cause is not inferred. Nine decimal places preserve small losses down to one lamport.";
      vx_reward("Missed"); "SOL"; 0; ($y + 18)),
    vx_stat(191; "Unpayable Rewards — Epoch";
      "VX estimate for slots that paid nobody, for example a skipped payer block. Not counted as validator misses. Cumulative gross SOL this epoch.";
      vx_reward("Unpayable"); "SOL"; 6; ($y + 18)),
    vx_stat(188; "VX Minus On-Chain Accounting";
      "Diagnostic SOL difference: VX total minus VX-reported onChainLamports. A mismatch is not automatically a loss or fault. Activation and the eight-slot reward/footer epoch boundary require reconciliation; equality is not independent verification.";
      "(" + vx_reward("Total") + ") - (" + vx_reward("OnChain") + ")";
      "SOL"; 12; ($y + 18)),
    vx_stat(196; "Skip Votes on Produced Blocks";
      "VX skippedNotarizedSlots: skip inclusions on slots where the cluster produced a block. Raw diagnostic count, not an unverified Vote Accuracy percentage.";
      vx_value("vxSkipOnBlockSlots"); "short"; 18; ($y + 18))
  ]
| .panels |= map(
    if (.type == "stat" or .type == "gauge" or .type == "bargauge") then
      .maxDataPoints = 1
      | .targets |= map(.instant = true | .range = false)
      | .fieldConfig.defaults.noValue = "No recent data"
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
# SolCircle-inspired hierarchy: epoch health, two-column performance/rewards,
# leader/admission, expandable details, then host health and history.
| .panels |= map(
    .id as $id |
    if $id == 180 then empty
    elif $id == 181 then .gridPos = {x:0,y:3,w:12,h:6}
    elif $id == 193 then .gridPos = {x:12,y:3,w:12,h:6}
    elif $id == 187 then .gridPos = {x:0,y:9,w:12,h:6}
    elif $id == 201 then .gridPos = {x:12,y:9,w:12,h:6}
    elif $id == 194 then .gridPos = {x:0,y:15,w:8,h:6}
    elif $id == 99 then .gridPos = {x:8,y:15,w:4,h:3} | .title = "Leader Slots Produced"
    elif $id == 100 then .gridPos = {x:12,y:15,w:4,h:3} | .title = "Leader Slots Skipped"
    elif $id == 62 then .gridPos = {x:16,y:15,w:8,h:3}
    elif $id == 162 then .gridPos = {x:8,y:18,w:8,h:3}
    elif $id == 163 then .gridPos = {x:16,y:18,w:8,h:3}
    elif $id == 97 then .gridPos = {x:6,y:1,w:4,h:2} | .title = "Epoch Progress"
    elif $id == 124 then .gridPos = {x:10,y:1,w:4,h:2}
    elif $id == 54 then .gridPos = {x:14,y:1,w:2,h:2}
    elif $id == 197 then .gridPos = {x:0,y:21,w:24,h:1} | .title = "Income breakdown — fees and MEV"
    elif $id == 198 then .gridPos = {x:0,y:22,w:8,h:6}
    elif $id == 199 then .gridPos = {x:8,y:22,w:8,h:6}
    elif $id == 200 then .gridPos = {x:16,y:22,w:8,h:6}
    elif $id == 195 then .gridPos = {x:0,y:22,w:24,h:1} | .title = "Consensus diagnostics and data coverage"
    elif $id == 165 then .gridPos = {x:0,y:31,w:6,h:4}
    elif ([182,183,184,189,190,191,188,196] | index($id)) != null then
      ([182,183,184,189,190,191,188,196] | index($id)) as $n |
      .gridPos = {x:(($n % 4)*6),y:(23+(($n/4|floor)*4)),w:6,h:4}
    elif ([120,73,52,71,89,90,80,67,69,142,92,44,98,29] | index($id)) != null then
      .gridPos.y = (if ([92,44,98,29] | index($id)) != null then 27 else 25 end)
    elif $id == 117 then .gridPos = {x:0,y:30,w:24,h:1}
    elif $id == 56 then .gridPos = {x:0,y:31,w:12,h:8}
    elif $id == 144 then .gridPos = {x:12,y:31,w:12,h:8}
    elif $id == 160 then .gridPos = {x:0,y:39,w:12,h:3}
    elif $id == 161 then .gridPos = {x:12,y:39,w:12,h:3}
    elif $id == 75 then .gridPos = {x:0,y:42,w:24,h:8}
    elif $id == 76 then .gridPos = {x:0,y:50,w:12,h:8}
    elif $id == 4 then .gridPos = {x:12,y:50,w:12,h:8}
    elif $id == 122 then .gridPos = {x:0,y:58,w:12,h:8}
    elif $id == 57 then .gridPos = {x:12,y:58,w:12,h:8}
    elif $id == 113 then .gridPos = {x:0,y:66,w:24,h:1}
    elif ([104,102,85,139,108,111,118,135,129,133,127,137,131] | index($id)) != null then
      ({"104":67,"102":67,"85":77,"139":77,"108":87,"111":87,
        "118":97,"135":97,"129":106,"133":106,"127":115,"137":115,"131":124}[($id|tostring)]) as $host_y |
      .gridPos.y = $host_y
    else . end |
    if ([181,193,187,201] | index($id)) != null then
      .transparent = false | .options.textMode = "value_and_name" |
      .fieldConfig.defaults.color = {mode:"fixed",fixedColor:(if $id == 187 then "purple" else "green" end)}
    else . end |
    if $id == 187 then
      .title = "Epoch Rewards — Gross" |
      .targets += [named_target("D"; vx_reward("Missed"); "Missed rewards")] |
      .fieldConfig.overrides += [{matcher:{id:"byName",options:"Missed rewards"},
        properties:[{id:"color",value:{mode:"fixed",fixedColor:"orange"}}]}]
    elif $id == 201 then
      .title = "Validator Income — Estimated" |
      .targets += [named_target("C"; vx_earnings("BlockRevenue"); "Block fees — validator share"),
                  named_target("D"; vx_earnings("MevShare"); "MEV — estimated share")]
    elif $id == 120 then
      .options.content = "### Validator and host health\nCurrent-epoch participation, rewards and admission are shown above. Income is estimated before costs; expand the breakdown or diagnostics for details.\n\n[Stakeconomy](https://stakeconomy.com) · [Monitoring repository](https://github.com/stakeconomy/solanamonitoring)"
    else . end
  )
| .panels += [
    {id:205,type:"row",title:"Host snapshot — $server",collapsed:false,
     panels:[],gridPos:{x:0,y:24,w:24,h:1}}
  ]
| .panels as $all
| .panels |= map(
    .id as $id |
    if ([198,199,200,182,183,184,189,190,191,188,196,165] | index($id)) != null then empty
    elif $id == 197 then .collapsed = true | .panels = [$all[] | select(.id == 198 or .id == 199 or .id == 200)]
    elif $id == 195 then .collapsed = true | .panels = [$all[] | .id as $child | select(([182,183,184,189,190,191,188,196,165] | index($child)) != null)]
    else . end
  )
# Close the space left by removing the legacy Tower history row.
| .panels |= map(if .gridPos.y >= 24 then .gridPos.y -= 1 else . end)
# New targets added to the cards must remain instant queries too.
| walk(if type == "object" and .type? == "stat" then
    .targets |= map(.instant = true | .range = false) else . end)
| walk(if type == "object" and .type? == "row" then .panels |= sort_by(.gridPos.y, .gridPos.x, .id) else . end)
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
