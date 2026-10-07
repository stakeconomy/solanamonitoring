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

for scenario in context-api-version context-api-version-null; do
  export MOCK_ALPENGLOW_V3_SCENARIO="$scenario"
  context_state="$tmp/$scenario.json"
  run_capture "$tmp/$scenario.out" "$tmp/$scenario.err" \
    --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" \
    --state "$context_state"
  [[ "$CAPTURE_STATUS" -eq 0 ]] || fail "$scenario must accept standards-compliant context.apiVersion"
  [[ ! -s "$tmp/$scenario.err" ]] || fail "$scenario must not warn"
  [[ "$(<"$tmp/$scenario.out")" == "$expected_line" ]] || fail "$scenario must emit the exact cold measurement"
  jq -e --arg vote "$vote" '.accounts[$vote].slot == "449000000" and .totals == {included:"0",expected:"0",missed:"0",unattributed_slots:"0"}' "$context_state" >/dev/null ||
    fail "$scenario must create valid cold state"
done
unset MOCK_ALPENGLOW_V3_SCENARIO

for scenario in mainnet tower wrong-node wrong-owner wrong-program wrong-type fixed-schedule malformed-batch-ids wrong-batch-id bad-jsonrpc malformed-genesis-result malformed-cert zero-cert-slot malformed-schedule-result unknown-context-key malformed-api-version oversized-api-version; do
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
  grep -q 'warning: optional cohort response invalid' "$tmp/$scenario.err" || fail "$scenario must warn about malformed optional data"
  [[ "$(wc -l <"$tmp/$scenario.err")" -eq 1 ]] || fail "$scenario warning must be bounded to one line"
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

other_identity='NewNode111111111111111111111111111111111111'
other_vote='NewVote111111111111111111111111111111111111'
for mutation in monitored_node reference_pubkey; do
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

# Task 2 vertical slice: an existing cold state must retain its cohort and initialize
# the null reference baseline from the next mandatory snapshot without a third RPC.
unset MOCK_ALPENGLOW_V3_SCENARIO
cohort_state="$tmp/cohort-advance.json"
cohort_log="$tmp/cohort-advance-calls.jsonl"
export MOCK_ALPENGLOW_V3_CALL_LOG="$cohort_log"
run_capture "$tmp/cohort-cold.out" "$tmp/cohort-cold.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$cohort_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'cohort cold start must succeed'
: >"$cohort_log"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/cohort-next-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000001,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"123456","previousCredits":"123000"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"123456","previousCredits":"123000"}]}},"leader_schedule":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]}}
JSON
run_capture "$tmp/cohort-next.out" "$tmp/cohort-next.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$cohort_state"
unset MOCK_ALPENGLOW_V3_FIXTURE
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'existing cohort snapshot must advance'
[[ "$(wc -l <"$cohort_log")" -le 2 ]] || fail 'existing cohort snapshot must make at most two RPC calls'
jq -e '
  .reference_votes == ["ReferenceVote1111111111111111111111111111111"] and
  .accounts["ReferenceVote1111111111111111111111111111111"].total == "123456" and
  .accounts["ReferenceVote1111111111111111111111111111111"].slot == "449000001"
' "$cohort_state" >/dev/null || fail 'existing cohort must remain stable and initialize its null baseline'

# Exact object parsing keeps numeric epochs and decimal-string credits above jq's exact range.
export MOCK_ALPENGLOW_V3_SCENARIO=numeric-epoch-large-credit
large_state="$tmp/numeric-epoch-large-credit.json"
run_capture "$tmp/numeric-epoch-large-credit.out" "$tmp/numeric-epoch-large-credit.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$large_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'numeric object epoch and large string credits must be accepted exactly'
jq -e --arg vote "$vote" '.epoch == "1052" and .accounts[$vote].total == "9007199254740993"' "$large_state" >/dev/null ||
  fail 'large string credits must survive without jq numeric conversion'
unset MOCK_ALPENGLOW_V3_SCENARIO

# Deterministic attributed transition: own count is included, the clean reference
# maximum defines expected, and cumulative totals advance exactly once.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/accounting-fixture.json"
accounting_state="$tmp/accounting-state.json"
cat >"$accounting_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":1,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["ReferenceVote1111111111111111111111111111111"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449000000","gcd":"2","samples":1,"increment":"2"},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","total":"200","slot":"449000000","gcd":"2","samples":1,"increment":"2"}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000002,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}},"leader_schedule":{}}
JSON
run_capture "$tmp/accounting.out" "$tmp/accounting.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$accounting_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'clean known gap must succeed'
grep -q 'included_total=1i,expected_total=2i,missed_total=1i.*ready=1i.*usable_references=1i' "$tmp/accounting.out" ||
  fail 'clean known gap must emit cumulative included/expected/missed totals'
jq -e '.totals == {included:"1",expected:"2",missed:"1",unattributed_slots:"0"} and .last_attributed_slot == "449000002" and all(.accounts[]; .slot == "449000002")' "$accounting_state" >/dev/null ||
  fail 'attributed transition must persist exact totals and aligned baselines'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Initialized baselines must cover the same interval. A mismatched reference slot
# is invalid core state and must be rejected before any RPC.
baseline_mismatch_state="$tmp/baseline-mismatch-state.json"
jq '.accounts["ReferenceVote1111111111111111111111111111111"].slot="449000001"' "$accounting_state" >"$baseline_mismatch_state"
baseline_mismatch_log="$tmp/baseline-mismatch-calls.jsonl"; : >"$baseline_mismatch_log"; export MOCK_ALPENGLOW_V3_CALL_LOG="$baseline_mismatch_log"
run_capture "$tmp/baseline-mismatch.out" "$tmp/baseline-mismatch.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$baseline_mismatch_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 1 && ! -s "$tmp/baseline-mismatch.out" ]] || fail 'initialized baseline-slot mismatch must fail closed'
[[ ! -s "$baseline_mismatch_log" ]] || fail 'baseline-slot mismatch must fail before RPC'

# Epoch rollover accounts the cross-epoch span once, resets learners/baselines,
# and retains the freshly fetched current-epoch leader cache.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/epoch-fixture.json"
epoch_state="$tmp/epoch-state.json"
cat >"$epoch_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":1,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["ReferenceVote1111111111111111111111111111111"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449372255","gcd":"2","samples":20,"increment":"2"},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","total":"200","slot":"449372255","gcd":"2","samples":20,"increment":"2"}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]},"totals":{"included":"7","expected":"9","missed":"2","unattributed_slots":"3"},"last_attributed_slot":"449372250"}
JSON
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449372256,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1053","credits":"101","previousCredits":"100"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1053","credits":"201","previousCredits":"200"}]}},"leader_schedule":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]}}
JSON
run_capture "$tmp/epoch.out" "$tmp/epoch.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$epoch_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'epoch rollover must succeed'
jq -e --arg identity "$identity" '
  .epoch == "1053" and .totals == {included:"7",expected:"9",missed:"2",unattributed_slots:"4"} and
  .leader_schedule_epoch == "1053" and (.leader_slots|has($identity)) and
  all(.accounts[]; .slot == "449372256" and .gcd == null and .samples == 0 and .increment == null)
' "$epoch_state" >/dev/null || fail 'epoch rollover must reset learners and keep the current cache'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Bounded discovery scans 600 active candidates in one optional response, excludes
# the monitored vote, and still snapshots only the monitored account on cold start.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/bounded-fixture.json"
bounded_state="$tmp/bounded-state.json"
bounded_log="$tmp/bounded-calls.jsonl"
export MOCK_ALPENGLOW_V3_CALL_LOG="$bounded_log"
jq -cn --arg vote "$vote" --arg identity "$identity" '
  def ch($n): "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"[$n:$n+1];
  {slot:449000000,accounts:{($vote):{node:$identity,history:[{epoch:"1052",credits:"10",previousCredits:"0"}]}},
   vote_accounts:([range(0;600) as $i|{votePubkey:("CandidateVote111111111111111111111"+ch(($i/58|floor))+ch($i%58)),nodePubkey:("CandidateNode111111111111111111111"+ch(($i/58|floor))+ch($i%58))}]+[{votePubkey:$vote,nodePubkey:$identity}])}
' >"$MOCK_ALPENGLOW_V3_FIXTURE"
run_capture "$tmp/bounded.out" "$tmp/bounded.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$bounded_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail '600-account bounded discovery must succeed'
[[ "$(wc -l <"$bounded_log")" -eq 2 ]] || fail 'bounded discovery must use exactly mandatory plus one optional RPC call'
jq -e --arg vote "$vote" '.reference_votes|length==8 and index($vote)==null' "$bounded_state" >/dev/null ||
  fail 'bounded discovery must select eight active non-own references'
first_bounded_payload="$(sed -n '1p' "$bounded_log")"
jq -e 'map(select(.id=="v3-accounts"))[0].params[0]|length==1' <<<"$first_bounded_payload" >/dev/null ||
  fail 'cold bounded discovery must snapshot only the monitored account'

# Vacancy selection is seed-controlled and randomized only for new members. Two
# seeds choose different cohorts, while the configured maximum still admits 32.
export MONITOR_ALPENGLOW_COHORT_SEED=alpha
seed_alpha_state="$tmp/seed-alpha-state.json"
run_capture "$tmp/seed-alpha.out" "$tmp/seed-alpha.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$seed_alpha_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'seeded alpha cohort discovery must succeed'
seed_alpha_refs="$(jq -c '.reference_votes' "$seed_alpha_state")"
export MONITOR_ALPENGLOW_COHORT_SEED=beta
seed_beta_state="$tmp/seed-beta-state.json"
run_capture "$tmp/seed-beta.out" "$tmp/seed-beta.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$seed_beta_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'seeded beta cohort discovery must succeed'
seed_beta_refs="$(jq -c '.reference_votes' "$seed_beta_state")"
[[ "$seed_alpha_refs" != "$seed_beta_refs" ]] || fail 'different controlled seeds must randomize vacancy selection'
unset MONITOR_ALPENGLOW_COHORT_SEED

max_cohort_state="$tmp/max-cohort-state.json"
run_capture "$tmp/max-cohort.out" "$tmp/max-cohort.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$max_cohort_state" --reference-count 32
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'configured 32-member cohort discovery must succeed'
jq -e '.config.reference_count==32 and (.reference_votes|length)==32 and (.accounts|keys|length)==33' "$max_cohort_state" >/dev/null ||
  fail 'configured maximum must persist exactly 32 references'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Persisted membership may never exceed its persisted configured bound; reject
# this core-state violation before issuing even the mandatory RPC batch.
overbound_state="$tmp/overbound-state.json"
overbound_ref='BoundExtraVote111111111111111111111111111111'
jq --arg ref "$overbound_ref" '
  .reference_votes += [$ref] |
  .accounts[$ref]={node:null,total:null,slot:null,gcd:null,samples:0,increment:null}
' "$accounting_state" >"$overbound_state"
overbound_log="$tmp/overbound-calls.jsonl"; : >"$overbound_log"; export MOCK_ALPENGLOW_V3_CALL_LOG="$overbound_log"
run_capture "$tmp/overbound.out" "$tmp/overbound.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$overbound_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 1 && ! -s "$tmp/overbound.out" ]] || fail 'over-configured persisted cohort must fail closed'
[[ ! -s "$overbound_log" ]] || fail 'over-configured persisted cohort must fail before RPC'

# Exact history parsing accepts a migration marker followed by ordered object data
# and accepts legacy safe integer tuples without converting decimal-string credits.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/history-fixture.json"
history_state="$tmp/history-state.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000000,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"18446744073709551615","credits":"18446744073709551615","previousCredits":"18446744073709551615"},[1051,7,5],{"epoch":1052,"credits":"9007199254740993","previousCredits":"7"}]}}}
JSON
run_capture "$tmp/history.out" "$tmp/history.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$history_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'marker and legacy/object mixed history must parse'
jq -e --arg vote "$vote" '.accounts[$vote].total=="9007199254740993" and .epoch=="1052"' "$history_state" >/dev/null ||
  fail 'exact history parsing must retain the latest large decimal string'

# Unsorted/duplicate epochs fail closed and cannot create state.
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000000,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"10","previousCredits":"0"},{"epoch":"1052","credits":"11","previousCredits":"10"}]}}}
JSON
bad_history_state="$tmp/bad-history-state.json"
run_capture "$tmp/bad-history.out" "$tmp/bad-history.err" \
  --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$bad_history_state"
[[ "$CAPTURE_STATUS" -eq 1 && ! -s "$tmp/bad-history.out" && ! -e "$bad_history_state" ]] ||
  fail 'duplicate epoch history must fail closed without state'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Reward-delay boundary: first included slot epoch+7 is unattributed; epoch+8 is clean.
boundary_state="$tmp/boundary-state.json"
cat >"$boundary_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":1,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["ReferenceVote1111111111111111111111111111111"],"accounts":{"$vote":{"node":"$identity","total":"10","slot":"448940262","gcd":"1","samples":1,"increment":"1"},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","total":"20","slot":"448940262","gcd":"1","samples":1,"increment":"1"}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/boundary-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":448940263,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"11","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"21","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/boundary7.out" "$tmp/boundary7.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$boundary_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'epoch+7 boundary snapshot must succeed conservatively'
jq -e '.totals.unattributed_slots=="1" and .last_attributed_slot=="0"' "$boundary_state" >/dev/null || fail 'epoch+7 must be unattributed'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":448940264,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"12","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"22","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/boundary8.out" "$tmp/boundary8.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$boundary_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'epoch+8 boundary snapshot must succeed'
grep -q 'included_total=1i,expected_total=1i,missed_total=0i.*ready=1i' "$tmp/boundary8.out" || fail 'epoch+8 must be attributed'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":448940265,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"13","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"23","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/boundary9.out" "$tmp/boundary9.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$boundary_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'epoch+9 boundary snapshot must succeed'
grep -q 'included_total=2i,expected_total=2i,missed_total=0i.*ready=1i' "$tmp/boundary9.out" || fail 'epoch+9 must remain attributed'
unset MOCK_ALPENGLOW_V3_FIXTURE

# A monitored cumulative decrease is fatal even when a rate-sample configuration
# change would otherwise force a conservative reset.
decrease_state="$tmp/decrease-state.json"
cp "$accounting_state" "$decrease_state"
decrease_before="$(sha256sum "$decrease_state")"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/decrease-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000003,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"1","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"205","previousCredits":"0"}]}},"leader_schedule":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]}}
JSON
run_capture "$tmp/decrease.out" "$tmp/decrease.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$decrease_state" --reference-count 1 --rate-samples 19
[[ "$CAPTURE_STATUS" -eq 1 && ! -s "$tmp/decrease.out" ]] || fail 'monitored decrease with config change must fail closed'
[[ "$(sha256sum "$decrease_state")" == "$decrease_before" ]] || fail 'monitored decrease must leave state byte-identical'
unset MOCK_ALPENGLOW_V3_FIXTURE

# One-slot learner promotion survives restart; a later multi-slot contradiction
# becomes unattributed and restarts recovery without rewriting historical totals.
learner_state="$tmp/learner-state.json"
cat >"$learner_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":1,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["ReferenceVote1111111111111111111111111111111"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449000010","gcd":null,"samples":0,"increment":null},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","total":"200","slot":"449000010","gcd":null,"samples":0,"increment":null}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/learner-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000011,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/learner-promote.out" "$tmp/learner-promote.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$learner_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'one-slot learner promotion must succeed'
jq -e --arg vote "$vote" '.accounts[$vote].increment=="2" and .accounts[$vote].samples==1 and .totals.included=="1"' "$learner_state" >/dev/null || fail 'one-slot learner must promote and count immediately'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000013,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"105","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"212","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/learner-contradict.out" "$tmp/learner-contradict.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$learner_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'multi-slot contradiction recovery must succeed'
jq -e --arg vote "$vote" '.accounts[$vote].gcd=="3" and .accounts[$vote].samples==1 and .accounts[$vote].increment==null and .totals.included=="1" and .totals.unattributed_slots=="2"' "$learner_state" >/dev/null || fail 'contradiction must restart learner and preserve history'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Invalid leader-cache keys normalize only that subsection; fetched own leadership
# contaminates the gap while preserving counters and advancing aligned baselines.
leader_state="$tmp/leader-state.json"
cp "$accounting_state" "$leader_state"
jq '.leader_slots.ExtraNode111111111111111111111111111111111=[]' "$leader_state" >"$tmp/leader-state-new.json" && mv "$tmp/leader-state-new.json" "$leader_state"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/leader-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}},"leader_schedule":{"$identity":[59747],"ReferenceNode1111111111111111111111111111111":[]}}
JSON
run_capture "$tmp/leader.out" "$tmp/leader.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$leader_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'invalid cache normalization and refetch must succeed'
jq -e --arg identity "$identity" '.leader_schedule_epoch=="1052" and (.leader_slots|keys|length)==2 and (.leader_slots[$identity]|length)==1 and .totals.unattributed_slots=="2" and all(.accounts[];.slot=="449000004")' "$leader_state" >/dev/null || fail 'own leader contamination must be unattributed with repaired cache'
unset MOCK_ALPENGLOW_V3_FIXTURE

# A malformed reference is removed and repaired in the same invocation with an
# explicit null baseline; no third RPC is allowed.
repair_state="$tmp/repair-state.json"
cp "$accounting_state" "$repair_state"
repair_log="$tmp/repair-calls.jsonl"; : >"$repair_log"; export MOCK_ALPENGLOW_V3_CALL_LOG="$repair_log"
new_ref='RepairVote111111111111111111111111111111111'
new_node='RepairNode111111111111111111111111111111111'
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/repair-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"104","previousCredits":"0"}]}},"vote_accounts":[{"votePubkey":"$new_ref","nodePubkey":"$new_node"}]}
JSON
run_capture "$tmp/repair.out" "$tmp/repair.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$repair_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'malformed reference repair must succeed'
[[ "$(wc -l <"$repair_log")" -eq 2 ]] || fail 'same-invocation repair must use at most two calls'
jq -e --arg ref "$new_ref" '.reference_votes==[$ref] and .accounts[$ref]=={node:null,total:null,slot:null,gcd:null,samples:0,increment:null}' "$repair_state" >/dev/null || fail 'repair must install a null-baseline member'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Identity/vote rotation snapshots only the new monitored account and resets every
# old cohort/cache/learner/cumulative field after ownership proof.
rotation_state="$tmp/rotation-state.json"
cp "$accounting_state" "$rotation_state"
rotation_log="$tmp/rotation-calls.jsonl"; : >"$rotation_log"; export MOCK_ALPENGLOW_V3_CALL_LOG="$rotation_log"
export MOCK_ALPENGLOW_V3_IDENTITY="$other_identity" MOCK_ALPENGLOW_V3_VOTE="$other_vote" MOCK_ALPENGLOW_V3_FIXTURE="$tmp/rotation-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000010,"accounts":{"$other_vote":{"node":"$other_identity","history":[{"epoch":"1052","credits":"50","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/rotation.out" "$tmp/rotation.err" --rpc-url http://mock.invalid --identity "$other_identity" --vote-account "$other_vote" --state "$rotation_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'valid identity/vote rotation must cold replace state'
jq -e --arg identity "$other_identity" --arg vote "$other_vote" '.pubkey==$identity and .vote_account==$vote and .reference_votes==[] and (.accounts|keys)==[$vote] and .totals=={included:"0",expected:"0",missed:"0",unattributed_slots:"0"} and .leader_schedule_epoch==null' "$rotation_state" >/dev/null || fail 'rotation must discard old cohort/cache/learners/totals'
rotation_payload="$(sed -n '1p' "$rotation_log")"
jq -e --arg vote "$other_vote" 'map(select(.id=="v3-accounts"))[0].params[0]==[$vote]' <<<"$rotation_payload" >/dev/null || fail 'rotation mandatory snapshot must contain only the new vote account'
export MOCK_ALPENGLOW_V3_IDENTITY="$identity" MOCK_ALPENGLOW_V3_VOTE="$vote"
unset MOCK_ALPENGLOW_V3_FIXTURE

# A failed optional cohort-repair call warns but does not poison an otherwise
# attributable gap using the existing clean monitored/reference pair.
optional_state="$tmp/optional-isolation-state.json"
cp "$accounting_state" "$optional_state"
jq '.config.reference_count=2' "$optional_state" >"$tmp/optional-isolation-new.json" && mv "$tmp/optional-isolation-new.json" "$optional_state"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/optional-isolation-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"optional_fail":"getVoteAccounts","accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/optional-isolation.out" "$tmp/optional-isolation.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$optional_state" --reference-count 2
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'optional repair failure must not fail a valid mandatory snapshot'
grep -q 'warning: optional cohort RPC failed' "$tmp/optional-isolation.err" || fail 'optional repair failure must emit a bounded warning'
grep -q 'ready=1i.*usable_references=1i' "$tmp/optional-isolation.out" || fail 'optional repair failure must preserve existing attribution'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Twenty-sample promotion, clean zero/zero attribution, own-inclusive denominator,
# and deterministic rate-sample resets all preserve cumulative invariants.
sample_state="$tmp/sample-state.json"
cat >"$sample_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":1,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["ReferenceVote1111111111111111111111111111111"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449000020","gcd":"2","samples":19,"increment":null},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","total":"200","slot":"449000020","gcd":"2","samples":19,"increment":null}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"ReferenceNode1111111111111111111111111111111":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/sample-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000022,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/sample20.out" "$tmp/sample20.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$sample_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'twentieth learner sample must succeed'
jq -e --arg vote "$vote" '.accounts[$vote].samples==20 and .accounts[$vote].increment=="2" and .totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"0"}' "$sample_state" >/dev/null || fail 'twentieth sample must promote and count immediately'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000023,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/zero-gap.out" "$tmp/zero-gap.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$sample_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'clean zero-count gap must succeed'
grep -q 'ready=1i.*last_attributed_slot=449000023i' "$tmp/zero-gap.out" || fail 'clean zero/zero gap must be attributed'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000025,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"206","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/own-denominator.out" "$tmp/own-denominator.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$sample_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'own-inclusive denominator gap must succeed'
jq -e '.totals=={included:"3",expected:"4",missed:"1",unattributed_slots:"0"}' "$sample_state" >/dev/null || fail 'own count must bound expected and prevent rates above 100 percent'
run_capture "$tmp/rate-repeat.out" "$tmp/rate-repeat.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$sample_state" --reference-count 1 --rate-samples 10
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'repeated-slot rate-samples change must succeed'
jq -e '.config.rate_samples==10 and all(.accounts[];.gcd==null and .samples==0 and .increment==null) and .totals=={included:"3",expected:"4",missed:"1",unattributed_slots:"0"}' "$sample_state" >/dev/null || fail 'repeated config change must reset only learner semantics'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000026,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"107","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"207","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/rate-advance.out" "$tmp/rate-advance.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$sample_state" --reference-count 1 --rate-samples 11
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'advancing rate-samples change must succeed conservatively'
jq -e '.config.rate_samples==11 and .totals.unattributed_slots=="1" and all(.accounts[];.slot=="449000026" and .gcd==null and .samples==0 and .increment==null)' "$sample_state" >/dev/null || fail 'advancing config change must count the whole span unattributed once'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Reference-count increases add null members on a repeated snapshot and decreases
# trim deterministically without resetting counters or retained baselines.
refconfig_state="$tmp/refconfig-state.json"
cp "$accounting_state" "$refconfig_state"
extra_ref='ExtraVote1111111111111111111111111111111111'
extra_node='ExtraNode1111111111111111111111111111111111'
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/refconfig-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000002,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}},"vote_accounts":[{"votePubkey":"$extra_ref","nodePubkey":"$extra_node"}]}
JSON
run_capture "$tmp/ref-raise.out" "$tmp/ref-raise.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$refconfig_state" --reference-count 2
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'reference-count raise on repeated slot must succeed'
jq -e --arg extra "$extra_ref" '.config.reference_count==2 and .reference_votes[1]==$extra and .accounts[$extra].total==null and .totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"0"}' "$refconfig_state" >/dev/null || fail 'reference-count raise must preserve state and append a null member'
run_capture "$tmp/ref-lower.out" "$tmp/ref-lower.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$refconfig_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'reference-count lower on repeated slot must succeed'
jq -e '.config.reference_count==1 and (.reference_votes|length)==1 and (.accounts|keys|length)==2 and .totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"0"}' "$refconfig_state" >/dev/null || fail 'reference-count lower must deterministically trim only excess members'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Repeated snapshots are byte-stable; regressing slots fail before any optional RPC;
# reference node rotation advances only that baseline and resets its learner.
repeat_state="$tmp/repeat-state.json"
cp "$accounting_state" "$repeat_state"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/repeat-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000002,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}}}
JSON
repeat_before="$(sha256sum "$repeat_state")"
run_capture "$tmp/repeat.out" "$tmp/repeat.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$repeat_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'repeated snapshot must succeed'
[[ "$(sha256sum "$repeat_state")" == "$repeat_before" ]] || fail 'repeated unchanged snapshot must not mutate state bytes'
grep -q 'ready=0i.*usable_references=0i' "$tmp/repeat.out" || fail 'repeated snapshot must emit not-ready unchanged totals'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000001,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"204","previousCredits":"0"}]}}}
JSON
regress_before="$(sha256sum "$repeat_state")"
run_capture "$tmp/regress.out" "$tmp/regress.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$repeat_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 1 && ! -s "$tmp/regress.out" ]] || fail 'regressing finalized slot must fail closed'
[[ "$(sha256sum "$repeat_state")" == "$regress_before" ]] || fail 'regressing slot must leave state byte-identical'
rotated_node='RotatedNode11111111111111111111111111111111'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"$rotated_node","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}},"leader_schedule":{"$identity":[],"$rotated_node":[]}}
JSON
run_capture "$tmp/node-rotate.out" "$tmp/node-rotate.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$repeat_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'reference node rotation must advance conservatively'
jq -e --arg node "$rotated_node" '.accounts["ReferenceVote1111111111111111111111111111111"]=={node:$node,total:"208",slot:"449000004",gcd:null,samples:0,increment:null} and .totals.unattributed_slots=="2" and (.leader_slots|has($node))' "$repeat_state" >/dev/null || fail 'node rotation must reset only the rotated learner and install its schedule'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Every cached schedule value must be an array. Object/scalar/null values cannot
# masquerade as empty schedules: normalize the whole cache, refetch, and apply
# contamination from the repaired schedule before attribution.
for cache_kind in object scalar null duplicate descending unsafe before-epoch at-epoch-end noncanonical; do
  malformed_cache_state="$tmp/cache-type-$cache_kind-state.json"
  cp "$accounting_state" "$malformed_cache_state"
  case "$cache_kind" in
    object) cache_value='{}' ;;
    scalar) cache_value='7' ;;
    null) cache_value='null' ;;
    duplicate) cache_value='["449000001","449000001"]' ;;
    descending) cache_value='["449000002","449000001"]' ;;
    unsafe) cache_value='["9223372036854775808"]' ;;
    before-epoch) cache_value='["448940255"]' ;;
    at-epoch-end) cache_value='["449372256"]' ;;
    noncanonical) cache_value='["0449000001"]' ;;
  esac
  jq --arg identity "$identity" --argjson value "$cache_value" '.leader_slots[$identity]=$value' "$malformed_cache_state" >"$tmp/cache-type-new.json" && mv "$tmp/cache-type-new.json" "$malformed_cache_state"
  export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/cache-type-$cache_kind-fixture.json"
  cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}},"leader_schedule":{"$identity":[59747],"ReferenceNode1111111111111111111111111111111":[]}}
JSON
  run_capture "$tmp/cache-type-$cache_kind.out" "$tmp/cache-type-$cache_kind.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$malformed_cache_state" --reference-count 1
  [[ "$CAPTURE_STATUS" -eq 0 ]] || fail "$cache_kind cache value must normalize and refetch"
  jq -e --arg identity "$identity" '.leader_slots[$identity]==["449000003"] and .totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"2"}' "$malformed_cache_state" >/dev/null ||
    fail "$cache_kind cache value must not bypass repaired leader contamination"
done
unset MOCK_ALPENGLOW_V3_FIXTURE

# If cache normalization succeeds but the sole repair RPC fails, no account may
# be attributed from the discarded cache.
repair_fail_state="$tmp/cache-repair-fail-state.json"
cp "$accounting_state" "$repair_fail_state"
jq --arg identity "$identity" '.leader_slots[$identity]={}' "$repair_fail_state" >"$tmp/cache-repair-fail-new.json" && mv "$tmp/cache-repair-fail-new.json" "$repair_fail_state"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/cache-repair-fail-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"optional_fail":"getLeaderSchedule","accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/cache-repair-fail.out" "$tmp/cache-repair-fail.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$repair_fail_state" --reference-count 1
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'failed leader-cache repair must degrade conservatively'
grep -q 'warning: optional leader schedule RPC failed' "$tmp/cache-repair-fail.err" || fail 'failed leader-cache repair must warn'
grep -q 'ready=0i.*usable_references=0i' "$tmp/cache-repair-fail.out" || fail 'failed leader-cache repair must prohibit attribution'
jq -e '.leader_schedule_epoch==null and .leader_slots=={} and .totals.unattributed_slots=="2"' "$repair_fail_state" >/dev/null || fail 'failed leader-cache repair must persist absent cache and count the span once'
unset MOCK_ALPENGLOW_V3_FIXTURE

# A contaminated reference is excluded while a clean peer still defines expected;
# a later decreasing reference is isolated/reset without poisoning that clean peer.
dirty_ref='DirtyVote1111111111111111111111111111111111'
dirty_node='DirtyNode1111111111111111111111111111111111'
good_ref='GoodVote11111111111111111111111111111111111'
good_node='GoodNode11111111111111111111111111111111111'
peer_state="$tmp/peer-isolation-state.json"
cat >"$peer_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":2,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["$dirty_ref","$good_ref"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449000000","gcd":"2","samples":1,"increment":"2"},"$dirty_ref":{"node":"$dirty_node","total":"200","slot":"449000000","gcd":"2","samples":1,"increment":"2"},"$good_ref":{"node":"$good_node","total":"300","slot":"449000000","gcd":"2","samples":1,"increment":"2"}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"$dirty_node":["449000001"],"$good_node":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/peer-isolation-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000002,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"$dirty_ref":{"node":"$dirty_node","history":[{"epoch":"1052","credits":"206","previousCredits":"0"}]},"$good_ref":{"node":"$good_node","history":[{"epoch":"1052","credits":"304","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/peer-contaminated.out" "$tmp/peer-contaminated.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$peer_state" --reference-count 2
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'contaminated plus clean reference gap must succeed'
grep -q 'ready=1i.*usable_references=1i' "$tmp/peer-contaminated.out" || fail 'only the clean reference must remain usable'
jq -e '.totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"0"}' "$peer_state" >/dev/null || fail 'clean peer must define expected beside contamination'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"104","previousCredits":"0"}]},"$dirty_ref":{"node":"$dirty_node","history":[{"epoch":"1052","credits":"100","previousCredits":"0"}]},"$good_ref":{"node":"$good_node","history":[{"epoch":"1052","credits":"306","previousCredits":"0"}]}}}
JSON
run_capture "$tmp/peer-decrease.out" "$tmp/peer-decrease.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$peer_state" --reference-count 2
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'decreasing reference beside clean peer must succeed'
grep -q 'ready=1i.*usable_references=1i' "$tmp/peer-decrease.out" || fail 'decreasing reference must not poison clean peer'
jq -e --arg dirty "$dirty_ref" '.totals=={included:"2",expected:"3",missed:"1",unattributed_slots:"0"} and .accounts[$dirty]=={node:.accounts[$dirty].node,total:"100",slot:"449000004",gcd:null,samples:0,increment:null}' "$peer_state" >/dev/null || fail 'decreasing reference must reset only its own baseline and learner'

# Filling a vacancy must preserve persisted members and order; only the missing
# suffix is selected by the seeded randomized pass.
retain_state="$tmp/retain-vacancy-state.json"
cp "$peer_state" "$retain_state"
jq '.config.reference_count=3' "$retain_state" >"$tmp/retain-vacancy-new.json" && mv "$tmp/retain-vacancy-new.json" "$retain_state"
retain_new='RetainNewVote111111111111111111111111111111'
retain_other='RetainBetaVote11111111111111111111111111111'
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"104","previousCredits":"0"}]},"$dirty_ref":{"node":"$dirty_node","history":[{"epoch":"1052","credits":"100","previousCredits":"0"}]},"$good_ref":{"node":"$good_node","history":[{"epoch":"1052","credits":"306","previousCredits":"0"}]}},"vote_accounts":[{"votePubkey":"$retain_new","nodePubkey":"RetainNewNode111111111111111111111111111111"},{"votePubkey":"$retain_other","nodePubkey":"RetainBetaNode11111111111111111111111111111"}]}
JSON
export MONITOR_ALPENGLOW_COHORT_SEED=retain-seed
run_capture "$tmp/retain-vacancy.out" "$tmp/retain-vacancy.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$retain_state" --reference-count 3
unset MONITOR_ALPENGLOW_COHORT_SEED
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'seeded vacancy fill must succeed'
jq -e --arg first "$dirty_ref" --arg second "$good_ref" '.reference_votes|length==3 and .[0]==$first and .[1]==$second' "$retain_state" >/dev/null || fail 'vacancy fill must retain persisted members in order'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Unsafe numeric epochs are accepted only as migration markers when both credit
# strings are exact u64-max markers. The marker is skipped before the valid entry.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/unsafe-marker-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000000,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":9007199254740992,"credits":"18446744073709551615","previousCredits":"18446744073709551615"},{"epoch":"1052","credits":"10","previousCredits":"0"}]}}}
JSON
unsafe_marker_state="$tmp/unsafe-marker-state.json"
run_capture "$tmp/unsafe-marker.out" "$tmp/unsafe-marker.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$unsafe_marker_state"
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'unsafe numeric epoch with exact marker credits must be skipped'
jq -e --arg vote "$vote" '.accounts[$vote].total=="10"' "$unsafe_marker_state" >/dev/null || fail 'unsafe numeric marker must preserve the following exact entry'

# An unsafe numeric epoch in one reference is isolated to that account. It is
# removed while another clean reference still attributes the gap.
bad_epoch_ref='BadEpochVote11111111111111111111111111111111'
good_epoch_ref='GoodEpochVote1111111111111111111111111111111'
good_epoch_node='GoodEpochNode1111111111111111111111111111111'
unsafe_ref_state="$tmp/unsafe-reference-state.json"
cat >"$unsafe_ref_state" <<JSON
{"version":3,"genesis":"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY","consensus":"alpenglow","pubkey":"$identity","vote_account":"$vote","config":{"reference_count":2,"rate_samples":20},"schedule":{"slots_per_epoch":432000,"leader_schedule_slot_offset":432000,"warmup":true,"first_normal_epoch":14,"first_normal_slot":524256},"epoch":"1052","reference_votes":["$bad_epoch_ref","$good_epoch_ref"],"accounts":{"$vote":{"node":"$identity","total":"100","slot":"449000000","gcd":"2","samples":1,"increment":"2"},"$bad_epoch_ref":{"node":"BadEpochNode11111111111111111111111111111111","total":"200","slot":"449000000","gcd":"2","samples":1,"increment":"2"},"$good_epoch_ref":{"node":"$good_epoch_node","total":"300","slot":"449000000","gcd":"2","samples":1,"increment":"2"}},"leader_schedule_epoch":"1052","leader_slots":{"$identity":[],"BadEpochNode11111111111111111111111111111111":[],"$good_epoch_node":[]},"totals":{"included":"0","expected":"0","missed":"0","unattributed_slots":"0"},"last_attributed_slot":"0"}
JSON
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000002,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"102","previousCredits":"0"}]},"$bad_epoch_ref":{"node":"BadEpochNode11111111111111111111111111111111","history":[{"epoch":9007199254740992,"credits":"202","previousCredits":"0"}]},"$good_epoch_ref":{"node":"$good_epoch_node","history":[{"epoch":"1052","credits":"304","previousCredits":"0"}]}},"vote_accounts":[]}
JSON
run_capture "$tmp/unsafe-reference.out" "$tmp/unsafe-reference.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$unsafe_ref_state" --reference-count 2
[[ "$CAPTURE_STATUS" -eq 0 ]] || fail 'unsafe numeric epoch in a reference must not abort the monitored snapshot'
grep -q 'ready=1i.*usable_references=1i' "$tmp/unsafe-reference.out" || fail 'clean reference must still attribute beside malformed reference'
jq -e --arg bad "$bad_epoch_ref" --arg good "$good_epoch_ref" '.reference_votes==[$good] and (.accounts|has($bad)|not) and .totals=={included:"1",expected:"2",missed:"1",unattributed_slots:"0"}' "$unsafe_ref_state" >/dev/null || fail 'malformed reference must be removed without poisoning clean peers'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Unsafe numeric object epochs and signed-64 overflow fail before state creation.
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/unsafe-epoch-fixture.json"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"slot":449000000,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":9007199254740992,"credits":"10","previousCredits":"0"}]}}}
JSON
unsafe_epoch_state="$tmp/unsafe-epoch-state.json"
run_capture "$tmp/unsafe-epoch.out" "$tmp/unsafe-epoch.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$unsafe_epoch_state"
[[ "$CAPTURE_STATUS" -eq 1 && ! -e "$unsafe_epoch_state" && ! -s "$tmp/unsafe-epoch.out" ]] || fail 'unsafe numeric object epoch must fail closed'
unset MOCK_ALPENGLOW_V3_FIXTURE

# Forced termination after the temporary state is complete but before rename must
# leave the previous state byte-valid and unchanged.
forced_state="$tmp/forced-write-state.json"
cp "$accounting_state" "$forced_state"
forced_before="$(sha256sum "$forced_state")"
forced_fixture="$tmp/forced-write-fixture.json"
cat >"$forced_fixture" <<JSON
{"slot":449000004,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"106","previousCredits":"0"}]},"ReferenceVote1111111111111111111111111111111":{"node":"ReferenceNode1111111111111111111111111111111","history":[{"epoch":"1052","credits":"208","previousCredits":"0"}]}}}
JSON
forced_bin="$tmp/forced-bin"; mkdir "$forced_bin"
forced_ready="$tmp/forced-write.ready"
real_mv="$(command -v mv)"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n: >"$FORCED_WRITE_READY"\nsleep 30\nexec "$REAL_MV" "$@"\n' >"$forced_bin/mv"
chmod +x "$forced_bin/mv"
setsid env PATH="$forced_bin:$PATH" REAL_MV="$real_mv" FORCED_WRITE_READY="$forced_ready" CURL_BIN="$CURL_BIN" MOCK_ALPENGLOW_V3_IDENTITY="$identity" MOCK_ALPENGLOW_V3_VOTE="$vote" MOCK_ALPENGLOW_V3_FIXTURE="$forced_fixture" \
  "$collector" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$forced_state" --reference-count 1 >"$tmp/forced-write.out" 2>"$tmp/forced-write.err" &
forced_pid=$!
forced_wait=0
while [[ ! -e "$forced_ready" ]] && ((forced_wait < 500)); do sleep 0.01; ((forced_wait += 1)); done
[[ -e "$forced_ready" ]] || fail 'forced-write collector must reach pre-rename boundary'
kill -TERM -- "-$forced_pid"
set +e
wait "$forced_pid"
forced_status=$?
set -e
[[ "$forced_status" -ne 0 && ! -s "$tmp/forced-write.out" ]] || fail 'forced termination during write must not emit success'
[[ "$(sha256sum "$forced_state")" == "$forced_before" ]] || fail 'forced termination during write must preserve previous state bytes'
jq -e '.version==3 and .totals.expected=="2"' "$forced_state" >/dev/null || fail 'forced termination must leave previous JSON valid'

# Two actual overlapping collector processes cannot both enter RPC/state advancement.
concurrent_state="$tmp/concurrent-state.json"
concurrent_log="$tmp/concurrent-calls.jsonl"; : >"$concurrent_log"; export MOCK_ALPENGLOW_V3_CALL_LOG="$concurrent_log"
export MOCK_ALPENGLOW_V3_FIXTURE="$tmp/concurrent-fixture.json"
concurrent_ready="$tmp/concurrent.ready"
concurrent_release="$tmp/concurrent.release"
cat >"$MOCK_ALPENGLOW_V3_FIXTURE" <<JSON
{"sync_ready_file":"$concurrent_ready","sync_release_file":"$concurrent_release","slot":449000000,"accounts":{"$vote":{"node":"$identity","history":[{"epoch":"1052","credits":"10","previousCredits":"0"}]}},"vote_accounts":[]}
JSON
"$collector" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$concurrent_state" >"$tmp/concurrent-first.out" 2>"$tmp/concurrent-first.err" &
first_pid=$!
wait_ready=0
while [[ ! -e "$concurrent_ready" ]] && ((wait_ready < 500)); do
  sleep 0.01
  ((wait_ready += 1))
done
[[ -e "$concurrent_ready" ]] || fail 'first concurrent collector must reach the synchronized RPC boundary'
run_capture "$tmp/concurrent-second.out" "$tmp/concurrent-second.err" --rpc-url http://mock.invalid --identity "$identity" --vote-account "$vote" --state "$concurrent_state"
second_status=$CAPTURE_STATUS
: >"$concurrent_release"
wait "$first_pid" || fail 'first concurrent collector must complete'
[[ "$second_status" -eq 0 && ! -s "$tmp/concurrent-second.out" && ! -s "$tmp/concurrent-second.err" ]] || fail 'overlapping collector must exit quietly under lock contention'
[[ "$(wc -l <"$concurrent_log")" -eq 2 ]] || fail 'overlapping collector must make zero additional RPC calls'
jq -e '.version==3 and .totals.expected=="0"' "$concurrent_state" >/dev/null || fail 'concurrent completion must leave one valid successor state'
unset MOCK_ALPENGLOW_V3_FIXTURE

printf 'PASS: alpenglow observed v3 focused tests\n'
