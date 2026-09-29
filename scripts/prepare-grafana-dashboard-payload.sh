#!/usr/bin/env bash
# Prepare a Grafana dashboard API payload from the portable JSON export.
#
# Grafana's HTTP API does not resolve __inputs such as ${DS_PROMETHEUS}.
# This helper binds those references to the UID from the live dashboard before
# the caller POSTs the result to /api/dashboards/db.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  prepare-grafana-dashboard-payload.sh \
    --source <portable-dashboard.json> \
    --live-dashboard <GET-/api/dashboards/uid response.json> \
    --datasource-uid <prometheus-uid> \
    --output <payload.json>
USAGE
}

source_dashboard=''
live_dashboard=''
datasource_uid=''
output=''

while (($#)); do
  case "$1" in
    --source) source_dashboard=${2:?missing value for --source}; shift 2 ;;
    --live-dashboard) live_dashboard=${2:?missing value for --live-dashboard}; shift 2 ;;
    --datasource-uid) datasource_uid=${2:?missing value for --datasource-uid}; shift 2 ;;
    --output) output=${2:?missing value for --output}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required in "$source_dashboard" "$live_dashboard" "$datasource_uid" "$output"; do
  [[ -n "$required" ]] || { usage >&2; exit 2; }
done

live_id=$(jq -er '.dashboard.id' "$live_dashboard")
live_uid=$(jq -er '.dashboard.uid' "$live_dashboard")
live_version=$(jq -er '.dashboard.version' "$live_dashboard")
live_title=$(jq -er '.dashboard.title' "$live_dashboard")
live_folder_id=$(jq -er '.dashboard.folderId // 0' "$live_dashboard")

prepared=$(mktemp)
trap 'rm -f "$prepared"' EXIT

jq \
  --argjson id "$live_id" \
  --arg uid "$live_uid" \
  --argjson version "$live_version" \
  --arg title "$live_title" \
  --arg datasource_uid "$datasource_uid" '
  def remap_prometheus_datasources:
    walk(
      if type == "object"
         and (.datasource? | type == "object")
         and .datasource.type == "prometheus"
      then .datasource.uid = $datasource_uid
      else .
      end
    );
  .id = $id
  | .uid = $uid
  | .version = $version
  | .title = $title
  | del(.__inputs)
  | remap_prometheus_datasources
' "$source_dashboard" > "$prepared"

jq -n \
  --slurpfile dashboard "$prepared" \
  --argjson folder_id "$live_folder_id" \
  '{dashboard: $dashboard[0], folderId: $folder_id, overwrite: true, message: "Health-first Alpenglow monitoring rollout"}' \
  > "$output"
