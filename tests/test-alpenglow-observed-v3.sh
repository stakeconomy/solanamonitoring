#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
collector="$repo_dir/scripts/alpenglow-observed-vote-inclusion-v3.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
help_out="$($collector --help 2>"$tmp/help.err")" || fail '--help must exit zero'
[[ -s "$tmp/help.err" ]] && fail '--help must not write stderr'
[[ "$help_out" == *'Usage:'* ]] || fail '--help must print usage'
[[ "$help_out" == *'--rpc-url URL'* ]] || fail 'usage must document --rpc-url'
[[ "$help_out" == *'--identity PUBKEY'* ]] || fail 'usage must document --identity'
[[ "$help_out" == *'--vote-account PUBKEY'* ]] || fail 'usage must document --vote-account'

run_capture() {
  local out_file="$1" err_file="$2"
  shift 2
  set +e
  "$collector" "$@" >"$out_file" 2>"$err_file"
  CAPTURE_STATUS=$?
  set -e
}

identity='Node111111111111111111111111111111111111111'
vote='Vote111111111111111111111111111111111111111'

run_capture "$tmp/invalid.out" "$tmp/invalid.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --reference-count 33
[[ "$CAPTURE_STATUS" -eq 64 ]] || fail 'invalid arguments must exit 64'
[[ ! -s "$tmp/invalid.out" ]] || fail 'invalid arguments must emit no stdout'
[[ -s "$tmp/invalid.err" ]] || fail 'invalid arguments must emit a concise error'
grep -q -- '--reference-count' "$tmp/invalid.err" || fail 'invalid reference count error must name the flag'

state="$tmp/cold.json"
call_log="$tmp/calls.jsonl"
export CURL_BIN="$repo_dir/tests/fixtures/mock-alpenglow-v3-curl"
export MOCK_ALPENGLOW_V3_IDENTITY="$identity"
export MOCK_ALPENGLOW_V3_VOTE="$vote"
export MOCK_ALPENGLOW_V3_CALL_LOG="$call_log"

expect_usage() {
  local name="$1" expected="$2"
  shift 2
  run_capture "$tmp/usage-$name.out" "$tmp/usage-$name.err" "$@"
  [[ "$CAPTURE_STATUS" -eq 64 ]] || fail "$name must exit 64"
  [[ ! -s "$tmp/usage-$name.out" ]] || fail "$name must emit no stdout"
  grep -q -- "$expected" "$tmp/usage-$name.err" || fail "$name error must name $expected"
}

expect_usage bad-url '--rpc-url' --rpc-url file:///tmp/rpc --identity "$identity" --vote-account "$vote" --state "$tmp/bad-url.json"
expect_usage relative-state '--state' --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state relative.json
expect_usage parent-state '--state' --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$tmp/dir/../state.json"
expect_usage short-identity '--identity' --rpc-url http://mock.invalid --identity Node111 --vote-account "$vote" --state "$tmp/short.json"
expect_usage control-identity '--identity' --rpc-url http://mock.invalid --identity $'Node1111111111111111111111111111111111111\nX' --vote-account "$vote" --state "$tmp/control.json"
expect_usage invalid-vote '--vote-account' --rpc-url http://mock.invalid --identity "$identity" --vote-account 'Vote01111111111111111111111111111111111111' --state "$tmp/invalid-vote.json"
expect_usage oversized-vote '--vote-account' --rpc-url http://mock.invalid --identity "$identity" --vote-account 'Vote11111111111111111111111111111111111111111' --state "$tmp/oversized-vote.json"
expect_usage timeout-format '--rpc-timeout' --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --rpc-timeout 1e3 --state "$tmp/timeout.json"
expect_usage reference-zero '--reference-count' --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --reference-count 0 --state "$tmp/ref-zero.json"
expect_usage samples-high '--rate-samples' --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --rate-samples 101 --state "$tmp/samples-high.json"
expect_usage mixed-help '--help' --help --rpc-url http://mock.invalid
expect_usage duplicate-rpc '--rpc-url' --rpc-url http://mock.invalid --rpc-url https://mock.invalid --identity "$identity" --vote-account "$vote" --state "$tmp/duplicate.json"

run_capture "$tmp/cold.out" "$tmp/cold.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'valid cold start must exit zero'
[[ ! -s "$tmp/cold.err" ]] || fail 'valid cold start must not warn'
expected_line="alpenglow_observed,cluster=testnet,genesis=4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY,consensus=alpenglow,pubkey=$identity,vote_account=$vote,schema=3 included_total=0i,expected_total=0i,missed_total=0i,unattributed_slots_total=0i,ready=0i,observed_slot=449000000i,last_attributed_slot=0i,usable_references=0i"
[[ "$(<"$tmp/cold.out")" == "$expected_line" ]] || fail 'cold start must emit the exact measurement contract'
[[ -f "$state" ]] || fail 'cold start must create state'
[[ "$(stat -c '%a' "$state")" == 600 ]] || fail 'state mode must be 0600'
jq -e --arg identity "$identity" --arg vote "$vote" '
  .version == 3 and
  .genesis == "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY" and
  .consensus == "alpenglow" and .pubkey == $identity and .vote_account == $vote and
  .config == {reference_count:8,rate_samples:20} and
  .schedule == {slots_per_epoch:432000,leader_schedule_slot_offset:432000,warmup:true,first_normal_epoch:14,first_normal_slot:524256} and
  .epoch == "1052" and
  .reference_votes == ["ReferenceVote1111111111111111111111111111111"] and
  (.accounts | keys | sort) == ([ $vote, "ReferenceVote1111111111111111111111111111111" ] | sort) and
  .accounts[$vote] == {node:$identity,total:"123456",slot:"449000000",gcd:null,samples:0,increment:null} and
  .accounts["ReferenceVote1111111111111111111111111111111"] == {node:null,total:null,slot:null,gcd:null,samples:0,increment:null} and
  .leader_schedule_epoch == null and .leader_slots == {} and
  .totals == {included:"0",expected:"0",missed:"0",unattributed_slots:"0"} and
  .last_attributed_slot == "0" and
  (has("pending") | not) and (has("included_total") | not)
' "$state" >/dev/null || fail 'cold state must match the exact v3 schema'

for scenario in mainnet tower wrong-node wrong-owner wrong-program wrong-type fixed-schedule malformed-batch-ids wrong-batch-id bad-jsonrpc malformed-genesis-result malformed-cert zero-cert-slot malformed-schedule-result malformed-accounts-result; do
  export MOCK_ALPENGLOW_V3_SCENARIO="$scenario"
  isolated_state="$tmp/isolation-$scenario.json"
  run_capture "$tmp/isolation-$scenario.out" "$tmp/isolation-$scenario.err" \
    --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
    --state "$isolated_state"
  [[ "$CAPTURE_STATUS" -eq 1 ]] || fail "$scenario isolation failure must exit 1"
  [[ ! -s "$tmp/isolation-$scenario.out" ]] || fail "$scenario isolation failure must emit no stdout"
  [[ ! -e "$isolated_state" ]] || fail "$scenario isolation failure must not create state"
done
unset MOCK_ALPENGLOW_V3_SCENARIO

for scenario in optional-bad-jsonrpc optional-wrong-id optional-malformed-result optional-invalid-reference; do
  export MOCK_ALPENGLOW_V3_SCENARIO="$scenario"
  optional_state="$tmp/$scenario.json"
  run_capture "$tmp/$scenario.out" "$tmp/$scenario.err" \
    --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
    --state "$optional_state"
  [[ "$CAPTURE_STATUS" -eq 0 ]] || fail "$scenario must degrade to an empty reference cohort"
  [[ ! -s "$tmp/$scenario.err" ]] || fail "$scenario must not warn"
  jq -e --arg vote "$vote" '.reference_votes == [] and (.accounts | keys) == [$vote]' "$optional_state" >/dev/null ||
    fail "$scenario must not accept a malformed optional envelope or reference"
done
unset MOCK_ALPENGLOW_V3_SCENARIO

export MOCK_ALPENGLOW_V3_SCENARIO=previous-max
max_state="$tmp/previous-max.json"
run_capture "$tmp/previous-max.out" "$tmp/previous-max.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$max_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'u63 max previousCredits must be accepted'
jq -e --arg vote "$vote" '.accounts[$vote].total == "9223372036854775807"' "$max_state" >/dev/null ||
  fail 'u63 max credits must remain an exact decimal string'

for scenario in previous-overflow previous-greater; do
  export MOCK_ALPENGLOW_V3_SCENARIO="$scenario"
  credit_state="$tmp/$scenario.json"
  run_capture "$tmp/$scenario.out" "$tmp/$scenario.err" \
    --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$credit_state"
  [[ "$CAPTURE_STATUS" -eq 1 ]] || fail "$scenario must fail closed"
  [[ ! -s "$tmp/$scenario.out" && ! -e "$credit_state" ]] || fail "$scenario must emit no output or state"
done
unset MOCK_ALPENGLOW_V3_SCENARIO

corrupt_state="$tmp/corrupt.json"
jq '.totals = {included:"1",expected:"2",missed:"0",unattributed_slots:"0"}' "$state" >"$corrupt_state"
corrupt_before="$(sha256sum "$corrupt_state")"
corrupt_calls_before="$(wc -l <"$call_log")"
run_capture "$tmp/corrupt.out" "$tmp/corrupt.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$corrupt_state"
[[ "$CAPTURE_STATUS" -eq 1 ]] || fail 'corrupt state must exit 1'
[[ ! -s "$tmp/corrupt.out" ]] || fail 'corrupt state must emit no stdout'
grep -q 'invalid existing v3 state' "$tmp/corrupt.err" || fail 'corrupt state must be identified before RPC'
[[ "$(sha256sum "$corrupt_state")" == "$corrupt_before" ]] || fail 'corrupt state must remain byte-identical'
[[ "$(wc -l <"$call_log")" == "$corrupt_calls_before" ]] || fail 'corrupt state must make zero new RPC calls'

other_identity='OtherNode11111111111111111111111111111111111'
other_vote='OtherVote11111111111111111111111111111111111'
for mutation in pubkey vote_account reference_count rate_samples monitored_node reference_pubkey; do
  bound_state="$tmp/bound-$mutation.json"
  case "$mutation" in
    pubkey) jq --arg value "$other_identity" '.pubkey = $value' "$state" >"$bound_state" ;;
    vote_account) jq --arg value "$other_vote" '.vote_account = $value' "$state" >"$bound_state" ;;
    reference_count) jq '.config.reference_count = 7' "$state" >"$bound_state" ;;
    rate_samples) jq '.config.rate_samples = 19' "$state" >"$bound_state" ;;
    monitored_node) jq --arg vote "$vote" --arg value "$other_identity" '.accounts[$vote].node = $value' "$state" >"$bound_state" ;;
    reference_pubkey) jq --arg bad $'Reference\nVote111111111111111111111111111111' '
      .reference_votes[0] as $old |
      .reference_votes[0] = $bad |
      .accounts[$bad] = .accounts[$old] |
      del(.accounts[$old])
    ' "$state" >"$bound_state" ;;
  esac
  bound_calls_before="$(wc -l <"$call_log")"
  run_capture "$tmp/bound-$mutation.out" "$tmp/bound-$mutation.err" \
    --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
    --state "$bound_state"
  [[ "$CAPTURE_STATUS" -eq 1 ]] || fail "$mutation state mismatch must exit 1"
  grep -q 'invalid existing v3 state' "$tmp/bound-$mutation.err" || fail "$mutation mismatch must fail state validation"
  [[ "$(wc -l <"$call_log")" == "$bound_calls_before" ]] || fail "$mutation mismatch must make zero RPC calls"
done

first_payload="$(sed -n '1p' "$call_log")"
jq -e --arg vote "$vote" '
  type == "array" and length == 4 and
  ([.[].id] | unique | length) == 4 and
  ([.[].id] | sort) == (["v3-genesis","v3-ag-genesis-cert","v3-epoch-schedule","v3-accounts"] | sort) and
  ([.[].method] | sort) == (["getGenesisHash","getAgGenesisCert","getEpochSchedule","getMultipleAccounts"] | sort) and
  (map(select(.id == "v3-accounts"))[0].params == [[$vote],{encoding:"jsonParsed",commitment:"finalized"}])
' <<<"$first_payload" >/dev/null || fail 'mandatory batch must use exact unique IDs and finalized monitored snapshot'

lock_victim="$tmp/lock-victim"
printf 'do-not-truncate\n' >"$lock_victim"
symlink_state="$tmp/symlink-lock.json"
ln -s "$lock_victim" "$symlink_state.lock"
symlink_calls_before="$(wc -l <"$call_log")"
run_capture "$tmp/symlink-lock.out" "$tmp/symlink-lock.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$symlink_state"
[[ "$CAPTURE_STATUS" -eq 1 ]] || fail 'symlink lock must be rejected'
[[ "$(<"$lock_victim")" == 'do-not-truncate' ]] || fail 'symlink lock target must not be truncated'
[[ ! -e "$symlink_state" ]] || fail 'symlink lock rejection must not create state'
[[ "$(wc -l <"$call_log")" == "$symlink_calls_before" ]] || fail 'symlink lock rejection must occur before RPC'

preserved_lock_state="$tmp/preserved-lock.json"
printf 'persistent-lock-marker\n' >"$preserved_lock_state.lock"
run_capture "$tmp/preserved-lock.out" "$tmp/preserved-lock.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$preserved_lock_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'owned regular lock must remain usable'
[[ "$(<"$preserved_lock_state.lock")" == 'persistent-lock-marker' ]] || fail 'lock open must not truncate an existing regular lock'

lock_state="$tmp/locked.json"
exec 9>"$lock_state.lock"
flock -n 9 || fail 'test setup could not acquire state lock'
call_count_before="$(wc -l <"$call_log")"
run_capture "$tmp/lock.out" "$tmp/lock.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$lock_state"
flock -u 9
exec 9>&-
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'lock contention must exit zero'
[[ ! -s "$tmp/lock.out" && ! -s "$tmp/lock.err" ]] || fail 'lock contention must be quiet'
[[ ! -e "$lock_state" ]] || fail 'lock contention must not create state'
[[ "$(wc -l <"$call_log")" == "$call_count_before" ]] || fail 'lock contention must occur before RPC'

fail_bin="$tmp/fail-bin"
mkdir "$fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fail_bin/mv"
chmod +x "$fail_bin/mv"
old_path="$PATH"
export PATH="$fail_bin:$PATH"
atomic_state="$tmp/atomic-failure.json"
run_capture "$tmp/atomic.out" "$tmp/atomic.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
  --state "$atomic_state"
export PATH="$old_path"
[[ "$CAPTURE_STATUS" -eq 1 ]] || fail 'atomic rename failure must exit 1'
[[ ! -s "$tmp/atomic.out" ]] || fail 'atomic rename failure must emit no stdout'
[[ ! -e "$atomic_state" ]] || fail 'atomic rename failure must not expose partial state'
if compgen -G "$tmp/.alpenglow-observed-v3.*" >/dev/null; then
  fail 'atomic rename failure must clean its temporary state file'
fi

printf 'PASS: alpenglow observed v3 focused tests\n'
