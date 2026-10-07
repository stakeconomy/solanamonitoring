#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
configs=("$repo_dir/telegraf/solana-monitoring.conf.example")
installation="$repo_dir/docs/installation.md"
schema_v3="$repo_dir/docs/alpenglow-monitoring-schema-v3.md"
migration="$repo_dir/docs/alpenglow-monitoring-migration.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_literal() {
  local file="$1" expected="$2" message="$3"
  grep -Fq -- "$expected" "$file" || fail "$message"
}

for config in "${configs[@]}"; do
  grep -q 'percpu = false' "$config" || fail "$config enables per-core CPU series"
  grep -q '"n_cpus"' "$config" || fail "$config omits CPU-count metrics used by normalized load"
  grep -q 'fieldpass = \["used_percent"\]' "$config" || fail "$config emits unused disk-capacity fields"
  grep -q '"tcp_listen"' "$config" || fail "$config omits TCP listen state"
  grep -q 'interface = \[' "$config" || fail "$config does not filter virtual interfaces"
  grep -q '/usr/bin/sudo -n -H -u VALIDATOR_USER' "$config" || fail "$config does not use the narrow non-interactive sudo path"
  assert_literal "$config" '/home/VALIDATOR_USER/solanamonitoring/monitor.sh --rpc-url http://127.0.0.1:8899 --rpc-timeout 20 --price-timeout 3' \
    "$config does not preserve the exact legacy monitor command"
  assert_literal "$config" '/home/VALIDATOR_USER/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/VALIDATOR_USER/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20' \
    "$config omits the exact v3 shadow command"
  [[ "$(grep -c '^\[\[inputs\.exec\]\]' "$config")" -eq 2 ]] \
    || fail "$config must contain separate legacy and v3 exec inputs"
  [[ "$(grep -c 'interval = "2s"' "$config")" -eq 1 ]] \
    || fail "$config must schedule exactly one v3 input every two seconds"
  [[ "$(grep -c 'timeout = "3s"' "$config")" -eq 1 ]] \
    || fail "$config must give the v3 input a three-second timeout"
  awk '
    BEGIN { RS = "\\[\\[inputs\\.exec\\]\\]" }
    /alpenglow-observed-vote-inclusion-v3[.]sh/ && /interval = "2s"/ && /timeout = "3s"/ { found = 1 }
    END { exit !found }
  ' "$config" || fail "$config does not bind the two-second interval and three-second timeout to the v3 input"
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

for file in "$installation" "$schema_v3" "$migration"; do
  [[ -f "$file" ]] || fail "$file is missing"
done

legacy_sudo='telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh'
v3_sudo='telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http\://127.0.0.1\:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20'
assert_literal "$installation" "$legacy_sudo" 'installation docs must preserve the legacy monitor sudo rule'
assert_literal "$installation" "$v3_sudo" 'installation docs must bind every v3 production argument in sudoers'
assert_literal "$installation" 'sudo visudo -c' 'installation docs must validate the complete sudoers configuration'
assert_literal "$installation" 'sudo -ll -U telegraf' 'installation docs must inspect the effective telegraf sudo rules'
assert_literal "$installation" '--rpc-url http://127.0.0.1:8898' 'installation docs must probe rejection of an altered RPC URL'
assert_literal "$installation" '--identity ALTERED_IDENTITY' 'installation docs must probe rejection of an altered identity'
assert_literal "$installation" '--state /home/solana/.config/solana/altered-v3.json' 'installation docs must probe rejection of an altered state path'
assert_literal "$installation" '--reference-count 9' 'installation docs must probe rejection of altered parser arguments'
assert_literal "$installation" 'at least 24 hours' 'installation docs must require a 24-hour shadow gate'

assert_literal "$schema_v3" 'measurement:' 'schema-v3 docs must identify its measurement'
assert_literal "$schema_v3" 'alpenglow_observed' 'schema-v3 docs must name the v3 measurement'
assert_literal "$schema_v3" 'schema=3' 'schema-v3 docs must specify the schema tag'
assert_literal "$schema_v3" 'cumulative' 'schema-v3 docs must identify the counters as cumulative'
assert_literal "$schema_v3" 'not direct certificate telemetry' 'schema-v3 docs must disclose the estimator limitation'

assert_literal "$migration" 'Phase 1 — install and shadow' 'migration docs must define the shadow phase'
assert_literal "$migration" 'Phase 2 — dashboard cutover' 'migration docs must define dashboard cutover'
assert_literal "$migration" 'Phase 3 — legacy retirement' 'migration docs must define legacy retirement'
assert_literal "$migration" 'Rollback phase 2' 'migration docs must document phase-two rollback'
assert_literal "$migration" 'Rollback phase 3' 'migration docs must document phase-three rollback'
assert_literal "$migration" 'Do not copy v3 counters into v2 state' 'migration docs must prohibit state conversion during rollback'

printf '%s\n' 'telegraf configuration tests passed'
