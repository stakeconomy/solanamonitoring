#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
collector="$repo_dir/scripts/alpenglow-observed-vote-inclusion-v3.sh"
mock_curl="$repo_dir/tests/fixtures/mock-alpenglow-v3-curl"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
identity = "Node111111111111111111111111111111111111111"
vote = "Vote111111111111111111111111111111111111111"
refs = [f"RefVote{c}" + "1" * (32 - len(f"RefVote{c}")) for c in "ABCDEFGH"]
nodes = [f"RefNode{c}" + "1" * (32 - len(f"RefNode{c}")) for c in "ABCDEFGH"]
accounts = {vote: {"node": identity, "total": "100", "slot": "449000000", "gcd": "2", "samples": 20, "increment": "2"}}
for index, (ref, node) in enumerate(zip(refs, nodes)):
    accounts[ref] = {"node": node, "total": str(200 + index), "slot": "449000000", "gcd": "2", "samples": 20, "increment": "2"}
tracked_nodes = [identity, *nodes]
epoch_first = 448940256
leader_slots = {node: [] for node in tracked_nodes}
# Roughly 382 KiB: nine selected validators with a deliberately skewed stake
# distribution, rather than pretending the selected cohort owns the whole epoch.
weights = [100, 55, 38, 29, 22, 17, 13, 10, 7]
weighted_nodes = [index for index, weight in enumerate(weights) for _ in range(weight)]
for selected in range(31750):
    offset = 100000 + selected * 10
    leader_slots[tracked_nodes[weighted_nodes[selected % len(weighted_nodes)]]].append(str(epoch_first + offset))
state = {
    "version": 3,
    "genesis": "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY",
    "consensus": "alpenglow",
    "pubkey": identity,
    "vote_account": vote,
    "config": {"reference_count": 8, "rate_samples": 20},
    "schedule": {"slots_per_epoch": 432000, "leader_schedule_slot_offset": 432000, "warmup": True, "first_normal_epoch": 14, "first_normal_slot": 524256},
    "epoch": "1052",
    "reference_votes": refs,
    "accounts": accounts,
    "leader_schedule_epoch": "1052",
    "leader_slots": leader_slots,
    "totals": {"included": "0", "expected": "0", "missed": "0", "unattributed_slots": "0"},
    "last_attributed_slot": "0",
}
fixture_accounts = {vote: {"node": identity, "history": [{"epoch": "1052", "credits": "100", "previousCredits": "0"}]}}
for index, (ref, node) in enumerate(zip(refs, nodes)):
    fixture_accounts[ref] = {"node": node, "history": [{"epoch": "1052", "credits": str(200 + index), "previousCredits": "0"}]}
(root / "state.json").write_text(json.dumps(state, separators=(",", ":")) + "\n")
(root / "fixture.json").write_text(json.dumps({"slot": 449000000, "accounts": fixture_accounts}, separators=(",", ":")) + "\n")
PY

python3 - "$collector" "$mock_curl" "$tmp/state.json" "$tmp/fixture.json" <<'PY'
import json
import os
import statistics
import subprocess
import sys
import time

collector, mock_curl, state, fixture = sys.argv[1:]
identity = "Node111111111111111111111111111111111111111"
vote = "Vote111111111111111111111111111111111111111"
command = [collector, "--rpc-url", "http://mock.invalid", "--identity", identity, "--vote-account", vote, "--state", state, "--reference-count", "8"]
env = os.environ.copy()
env.update({"CURL_BIN": mock_curl, "MOCK_ALPENGLOW_V3_IDENTITY": identity, "MOCK_ALPENGLOW_V3_VOTE": vote, "MOCK_ALPENGLOW_V3_FIXTURE": fixture})
samples = []
for index in range(100):
    slot = 449000001 + index
    fixture_data = json.load(open(fixture))
    fixture_data["slot"] = slot
    for account_index, account in enumerate(fixture_data["accounts"].values()):
        baseline = 100 if account_index == 0 else 199 + account_index
        account["history"][0]["credits"] = str(baseline + (index + 1) * 2)
    with open(fixture, "w") as handle:
        json.dump(fixture_data, handle, separators=(",", ":"))
        handle.write("\n")
    started = time.perf_counter()
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    samples.append(time.perf_counter() - started)
    if result.returncode != 0 or not result.stdout.startswith("alpenglow_observed,") or result.stderr:
        print(f"benchmark invocation {index + 1} failed: rc={result.returncode} stderr={result.stderr!r}", file=sys.stderr)
        raise SystemExit(1)
final_state = json.load(open(state))
if final_state["accounts"][vote]["slot"] != "449000100":
    raise SystemExit("advancing benchmark did not persist every finalized slot")
ordered = sorted(samples)
p99 = ordered[98]
median = statistics.median(samples)
maximum = max(samples)
print(f"production-shaped advancing timing: n=100 median={median:.3f}s p99={p99:.3f}s max={maximum:.3f}s state_bytes={os.path.getsize(state)}")
if p99 >= 1.5:
    raise SystemExit("production-shaped advancing p99 must remain below 1.5s")
PY
