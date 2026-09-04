#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
configs=("$repo_dir/telegraf/solana-monitoring.conf.example")

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for config in "${configs[@]}"; do
  grep -q 'percpu = false' "$config" || fail "$config enables per-core CPU series"
  grep -q '"n_cpus"' "$config" || fail "$config omits CPU-count metrics used by normalized load"
  grep -q 'fieldpass = \["used_percent"\]' "$config" || fail "$config emits unused disk-capacity fields"
  grep -q '"tcp_listen"' "$config" || fail "$config omits TCP listen state"
  grep -q 'interface = \[' "$config" || fail "$config does not filter virtual interfaces"
  grep -q '/usr/bin/sudo -n -H -u VALIDATOR_USER' "$config" || fail "$config does not use the narrow non-interactive sudo path"
  grep -q 'urls = \["http://metrics.stakeconomy.com:8086"\]' "$config" || fail "$config does not publish to the community endpoint"
  grep -q 'fieldpass = \["total", "running", "blocked", "zombies"\]' "$config" \
    || fail "$config collects unused process states"

  if grep -q '^\[\[inputs\.diskio\]\]' "$config"; then
    fail "$config enables unused diskio collection"
  fi
  if grep -q 'data_type[[:space:]]*=' "$config"; then
    fail "$config forces a single field type for mixed Influx line protocol"
  fi
  if grep -Eq '^[[:space:]]*(username|password)[[:space:]]*=' "$config"; then
    fail "$config contains unnecessary credentials for the open community endpoint"
  fi
  if grep -Eq 'sudo su|runuser|n_physical_cpus' "$config"; then
    fail "$config contains a legacy privilege wrapper or unused CPU field"
  fi

  if command -v telegraf >/dev/null 2>&1; then
    telegraf --config "$config" --test --input-filter cpu --output-filter discard >/dev/null
  fi
done

printf '%s\n' 'telegraf configuration tests passed'
