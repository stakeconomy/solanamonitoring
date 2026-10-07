#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
configs=("$repo_dir/telegraf/solana-monitoring.conf.example")
readme="$repo_dir/README.md"
installation="$repo_dir/docs/installation.md"
schema_v3="$repo_dir/docs/alpenglow-monitoring-schema-v3.md"
migration="$repo_dir/docs/alpenglow-monitoring-migration.md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_literal() {
  local file="$1" expected="$2" message="$3"
  grep -Fq -- "$expected" "$file" || fail "$message"
}

legacy_command='/usr/bin/sudo -n -H -u VALIDATOR_USER -- /home/VALIDATOR_USER/solanamonitoring/monitor.sh --rpc-url http://127.0.0.1:8899 --rpc-timeout 20 --price-timeout 3'
v3_command='/usr/bin/sudo -n -H -u VALIDATOR_USER -- /home/VALIDATOR_USER/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/VALIDATOR_USER/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20'

for config in "${configs[@]}"; do
  python3 - "$config" "$legacy_command" "$v3_command" <<'PY' || fail "$config exec inputs do not match the exact production contract"
import sys
import tomllib

config_path, legacy_command, v3_command = sys.argv[1:]
with open(config_path, "rb") as handle:
    config = tomllib.load(handle)

actual = [
    {
        "commands": entry.get("commands"),
        "interval": entry.get("interval"),
        "collection_jitter": entry.get("collection_jitter"),
        "timeout": entry.get("timeout"),
        "data_format": entry.get("data_format"),
    }
    for entry in config.get("inputs", {}).get("exec", [])
]
expected = [
    {
        "commands": [legacy_command],
        "interval": "1m",
        "collection_jitter": None,
        "timeout": "1m",
        "data_format": "influx",
    },
    {
        "commands": [v3_command],
        "interval": "2s",
        "collection_jitter": "0s",
        "timeout": "10s",
        "data_format": "influx",
    },
]
if actual != expected:
    print(f"expected exact exec inputs: {expected!r}", file=sys.stderr)
    print(f"actual exec inputs: {actual!r}", file=sys.stderr)
    raise SystemExit(1)

outputs = config.get("outputs", {}).get("influxdb", [])
if len(outputs) != 1:
    print(f"expected exactly one InfluxDB output, got: {outputs!r}", file=sys.stderr)
    raise SystemExit(1)
output = outputs[0]
if output.get("flush_interval") != "2s" or output.get("flush_jitter") != "0s":
    print(
        "schema-v3 freshness requires output flush_interval='2s' and flush_jitter='0s'",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

  grep -q 'percpu = false' "$config" || fail "$config enables per-core CPU series"
  grep -q '"n_cpus"' "$config" || fail "$config omits CPU-count metrics used by normalized load"
  grep -q 'fieldpass = \["used_percent"\]' "$config" || fail "$config emits unused disk-capacity fields"
  grep -q '"tcp_listen"' "$config" || fail "$config omits TCP listen state"
  grep -q 'interface = \[' "$config" || fail "$config does not filter virtual interfaces"
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

for file in "$readme" "$installation" "$schema_v3" "$migration"; do
  [[ -f "$file" ]] || fail "$file is missing"
done

legacy_sudo='telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh'
v3_sudo='telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http\://127.0.0.1\:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20'

for doc in "$readme" "$installation"; do
  fixture="$tmp/$(basename "$doc").sudoers"
  python3 - "$doc" "$fixture" "$legacy_sudo" "$v3_sudo" <<'PY' || fail "$doc sudoers example is not exactly least privilege"
import re
import sys
from pathlib import Path

path, fixture_path, legacy, v3 = sys.argv[1:]
text = Path(path).read_text()
blocks = re.findall(r"```sudoers\n(.*?)```", text, flags=re.DOTALL)
lines = [line.strip() for block in blocks for line in block.splitlines() if line.strip() and not line.lstrip().startswith("#")]
expected = [legacy, v3]

def exact_policy(candidate):
    return candidate == expected

if not exact_policy(lines):
    print(f"expected exactly two sudo rules in order: {expected!r}", file=sys.stderr)
    print(f"actual sudo rules: {lines!r}", file=sys.stderr)
    raise SystemExit(1)

mutations = {
    "changed": [legacy, v3.replace("127.0.0.1\\:8899", "127.0.0.1\\:8898")],
    "omitted": [legacy, v3.replace(" --rate-samples 20", "")],
    "appended": [legacy, v3 + " --help"],
    "reordered": [legacy, v3.replace(" --reference-count 8 --rate-samples 20", " --rate-samples 20 --reference-count 8")],
    "duplicate": [legacy, v3, v3],
    "broader": ["telegraf ALL=(ALL) NOPASSWD: ALL", v3],
    "wildcard": [legacy, v3 + " *"],
}
for name, mutation in mutations.items():
    if exact_policy(mutation):
        print(f"negative sudoers mutation was accepted: {name}", file=sys.stderr)
        raise SystemExit(1)

Path(fixture_path).write_text("\n".join(lines) + "\n")
PY
  command -v visudo >/dev/null 2>&1 || fail 'visudo is required to validate the extracted sudoers fixture'
  visudo -cf "$fixture" >/dev/null || fail "$doc extracted sudoers fixture must parse with visudo"
done

assert_literal "$installation" 'sudo visudo -c' 'installation docs must validate the complete sudoers configuration'
assert_literal "$installation" 'sudo -ll -U telegraf' 'installation docs must inspect the effective telegraf sudo rules'
assert_literal "$installation" 'REVIEWED_REVISION=' 'installation docs must pin an immutable reviewed revision'
assert_literal "$installation" "git -C \"\$REPOSITORY\" status --porcelain" 'installation docs must require a clean repository'
assert_literal "$installation" "git -C \"\$REPOSITORY\" cat-file -e \"\$REVIEWED_REVISION^{commit}\"" 'installation docs must verify the reviewed commit exists'
assert_literal "$installation" "git -C \"\$REPOSITORY\" merge-base --is-ancestor HEAD \"\$REVIEWED_REVISION\"" 'installation docs must require a fast-forward deployment path'
assert_literal "$installation" "git -C \"\$REPOSITORY\" checkout --detach \"\$REVIEWED_REVISION\"" 'installation docs must check out the immutable reviewed revision without a force reset'
assert_literal "$installation" "test -x \"\$REPOSITORY/scripts/alpenglow-observed-vote-inclusion-v3.sh\"" 'installation docs must verify the v3 collector is executable'
assert_literal "$installation" '--rpc-url http://127.0.0.1:8898' 'installation docs must probe rejection of an altered RPC URL'
assert_literal "$installation" '--identity ALTERED_IDENTITY' 'installation docs must probe rejection of an altered identity'
assert_literal "$installation" '--state /home/solana/.config/solana/altered-v3.json' 'installation docs must probe rejection of an altered state path'
assert_literal "$installation" '--reference-count 9' 'installation docs must probe rejection of altered parser arguments'
assert_literal "$installation" 'Omitted argument' 'installation docs must include an omitted-argument rejection command'
assert_literal "$installation" 'Appended argument' 'installation docs must include an appended-argument rejection command'
assert_literal "$installation" 'Reordered arguments' 'installation docs must include a reordered-argument rejection command'
assert_literal "$installation" 'at least 24 hours' 'installation docs must require a 24-hour shadow gate'
# shellcheck disable=SC2016 # Markdown backticks are intentional literals.
expected_timeout_row='| standalone v3 collector | `2s` | `10s` |'
assert_literal "$installation" "$expected_timeout_row" 'installation docs must retain the ten-second v3 fail-safe timeout'
assert_literal "$installation" 'exact Testnet genesis' 'installation docs must require the exact-genesis gate'
assert_literal "$installation" 'Mainnet and Tower' 'installation docs must retain legacy-only collection outside Testnet Alpenglow'

assert_literal "$schema_v3" 'measurement:' 'schema-v3 docs must identify its measurement'
assert_literal "$schema_v3" 'alpenglow_observed' 'schema-v3 docs must name the v3 measurement'
assert_literal "$schema_v3" 'schema=3' 'schema-v3 docs must specify the schema tag'
assert_literal "$schema_v3" 'cumulative' 'schema-v3 docs must identify the counters as cumulative'
assert_literal "$schema_v3" 'not direct certificate telemetry' 'schema-v3 docs must disclose the estimator limitation'

assert_literal "$migration" 'Phase 1 — install and shadow' 'migration docs must define the shadow phase'
assert_literal "$migration" 'Phase 2 — dashboard cutover' 'migration docs must define dashboard cutover'
assert_literal "$migration" 'Phase 3 — legacy retirement' 'migration docs must define legacy retirement'
assert_literal "$migration" 'PRE_RETIREMENT_REVISION' 'migration docs must record the pre-retirement revision'
assert_literal "$migration" 'monitor.sh.pre-alpenglow-v3-retirement' 'migration docs must preserve monitor.sh before phase three'
assert_literal "$migration" 'sudo systemctl restart telegraf' 'migration docs must include an exact Telegraf restart command'
assert_literal "$migration" 'grep -m1' 'migration docs must include a schema-v2 sample readback command'
assert_literal "$migration" 'normally remains configured' 'migration docs must clarify that the one-minute Telegraf command normally remains'
assert_literal "$migration" 'Rollback phase 2' 'migration docs must document phase-two rollback'
assert_literal "$migration" 'Rollback phase 3' 'migration docs must document phase-three rollback'
assert_literal "$migration" 'Do not copy v3 counters into v2 state' 'migration docs must prohibit state conversion during rollback'

printf '%s\n' 'telegraf configuration tests passed'
