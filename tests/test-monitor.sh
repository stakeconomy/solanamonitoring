#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mock_curl="$repo_dir/tests/fixtures/mock-monitor-curl"
identity="8SQEcP4FaYQySktNQeyxF3w8pvArx3oMEh7fPrzkN9pu"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

output="$(
  CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"

[[ "$(wc -l <<<"$output")" -eq 1 ]] || fail 'collector must emit exactly one stdout line'
assert_contains "$output" "nodemonitor,cluster=testnet,genesis=4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY,consensus=alpenglow,pubkey=$identity,vote_account=2HUKQz7W2nXZSwrdX5RkfS2rLU4j1QZLjdGCHcoUKFh3,schema=2 "
assert_contains "$output" 'collectorUp=1i'
assert_contains "$output" 'genesisMatch=1i'
assert_contains "$output" 'status=0i'
assert_contains "$output" 'rootSlot=437726128i'
assert_contains "$output" 'lastVote=437726159i'
assert_contains "$output" 'finalizedSlot=437726180i'
assert_contains "$output" 'activatedStake=1756474.290046330'
assert_contains "$output" 'version=430i'
assert_contains "$output" 'leaderSlots=84i'
assert_contains "$output" 'skippedSlots=8i'
assert_contains "$output" 'pctSkipped=9.52'
assert_contains "$output" 'pctTotSkipped=1.10'
assert_contains "$output" 'pctTotDelinquent=0.59'
assert_contains "$output" 'validatorBalance=3424.665720544'
assert_contains "$output" 'validatorVoteBalance=38708.561305920'
assert_contains "$output" 'nodes=2i'
assert_contains "$output" 'epoch=1026i'
assert_contains "$output" 'pctEpochElapsed=4.17'
assert_contains "$output" 'alpenglowRewardAccountingLamports=282326i'
[[ "$output" != *'credits='* ]] || fail 'Alpenglow must not emit Tower credits'
[[ "$output" != *'validatorCreditsCurrent='* ]] || fail 'Alpenglow must not emit Tower epoch credits'
[[ "$output" != *'pctVote='* ]] || fail 'Alpenglow must not emit Tower vote-credit efficiency'
[[ "$output" != *'pctNewerVersions='* ]] || fail 'collector must not emit a hard-coded newer-version percentage'
assert_contains "$output" 'tps=698637083708i'

migration_marker_output="$(
  MOCK_ALPENGLOW_EPOCH_CREDIT_MARKER=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
[[ "$migration_marker_output" != *'alpenglowRewardAccountingLamports='* ]] || \
  fail 'Alpenglow migration-marker epochCredits must not emit reward accounting'

invalid_tuple_output="$(
  MOCK_INVALID_ALPENGLOW_EPOCH_CREDIT=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
[[ "$invalid_tuple_output" != *'alpenglowRewardAccountingLamports='* ]] || \
  fail 'invalid Alpenglow epochCredits must not emit reward accounting'

mainnet_output="$(
  MOCK_MAINNET=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
assert_contains "$mainnet_output" 'cluster=mainnet-beta'
assert_contains "$mainnet_output" 'consensus=tower'
assert_contains "$mainnet_output" 'legacyVoteCreditsTotal=2336223624i'
assert_contains "$mainnet_output" 'legacyVoteCreditsEpoch=282326i'
assert_contains "$mainnet_output" 'legacyVoteCreditEfficiencyPct=1568.48'

tower_testnet_output="$(
  MOCK_AG_CERT_NULL=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
assert_contains "$tower_testnet_output" 'cluster=testnet'
assert_contains "$tower_testnet_output" 'consensus=tower'
assert_contains "$tower_testnet_output" 'legacyVoteCreditEfficiencyPct=1568.48'

set +e
failure_output="$(
  MOCK_RPC_FAIL=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid 2>/dev/null
)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail 'RPC failure must return a non-zero exit status'
[[ "$failure_output" == "nodemonitor,pubkey=$identity status=2i "* ]] || fail 'RPC failure must emit only status=2'
[[ "$(wc -l <<<"$failure_output")" -eq 1 ]] || fail 'RPC failure must emit exactly one stdout line'

set +e
multiple_output="$(
  MOCK_MULTIPLE_VOTES=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid 2>/dev/null
)"
multiple_status=$?
set -e
[[ "$multiple_status" -ne 0 ]] || fail 'ambiguous vote discovery must return non-zero'
[[ "$multiple_output" == "nodemonitor,pubkey=$identity status=2i "* ]] || fail 'ambiguous vote discovery must emit status=2'

batch_output="$(
  MOCK_BATCH_FAIL=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid 2>/dev/null
)"
assert_contains "$batch_output" 'status=0i'
assert_contains "$batch_output" 'productionDataOk=0i'
[[ "$batch_output" != *'leaderSlots='* ]] || fail 'failed production RPC must not emit zero scheduled-slot production'
[[ "$batch_output" != *'skippedSlots='* ]] || fail 'failed production RPC must not emit zero scheduled-slot absence'

fallback_output="$(
  MOCK_EMPTY_PERFORMANCE=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
[[ "$fallback_output" != *'epochEnds=0i'* ]] || fail 'empty performance samples must use the epoch-end fallback'
fallback_epoch_ends="$(sed -nE 's/.*epochEnds=([0-9]+)i.*/\1/p' <<<"$fallback_output")"
fallback_timestamp_ns="${fallback_output##* }"
fallback_delta_ms=$((fallback_epoch_ends - fallback_timestamp_ns / 1000000))
[[ "$fallback_delta_ms" -ge 82799000 && "$fallback_delta_ms" -le 82801000 ]] || \
  fail 'testnet genesis hash must select the 200 ms slot fallback'

public_fallback_output="$(
  MOCK_EMPTY_PERFORMANCE=1 MOCK_PUBLIC_PERFORMANCE_SUCCESS=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
public_epoch_ends="$(sed -nE 's/.*epochEnds=([0-9]+)i.*/\1/p' <<<"$public_fallback_output")"
public_timestamp_ns="${public_fallback_output##* }"
public_delta_ms=$((public_epoch_ends - public_timestamp_ns / 1000000))
[[ "$public_delta_ms" -ge 74519000 && "$public_delta_ms" -le 74521000 ]] || \
  fail 'empty local performance samples must use the matching public cluster RPC'

configured_fallback_output="$(
  MOCK_EMPTY_PERFORMANCE=1 MOCK_PUBLIC_PERFORMANCE_SUCCESS=1 \
  MOCK_REQUIRE_PERFORMANCE_ENDPOINT=https://configured-rpc.invalid \
  CURL_BIN="$mock_curl" SOLANA_CLI="$repo_dir/tests/fixtures/mock-solana" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
configured_epoch_ends="$(sed -nE 's/.*epochEnds=([0-9]+)i.*/\1/p' <<<"$configured_fallback_output")"
configured_timestamp_ns="${configured_fallback_output##* }"
configured_delta_ms=$((configured_epoch_ends - configured_timestamp_ns / 1000000))
[[ "$configured_delta_ms" -ge 74519000 && "$configured_delta_ms" -le 74521000 ]] || \
  fail 'the configured Solana CLI RPC must be preferred for performance samples'

cli_fallback_output="$(
  MOCK_EMPTY_PERFORMANCE=1 MOCK_UNKNOWN_GENESIS=1 CURL_BIN="$mock_curl" \
  SOLANA_CLI="$repo_dir/tests/fixtures/mock-solana" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
cli_epoch_ends="$(sed -nE 's/.*epochEnds=([0-9]+)i.*/\1/p' <<<"$cli_fallback_output")"
cli_timestamp_ns="${cli_fallback_output##* }"
cli_delta_ms=$((cli_epoch_ends - cli_timestamp_ns / 1000000))
[[ "$cli_delta_ms" -ge 93783000 && "$cli_delta_ms" -le 93785000 ]] || \
  fail 'an unknown cluster without performance samples must use the CLI epoch ETA'

testnet_cli_output="$(
  MOCK_EMPTY_PERFORMANCE=1 CURL_BIN="$mock_curl" SOLANA_CLI="$repo_dir/tests/fixtures/mock-solana" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
testnet_cli_epoch_ends="$(sed -nE 's/.*epochEnds=([0-9]+)i.*/\1/p' <<<"$testnet_cli_output")"
testnet_cli_timestamp_ns="${testnet_cli_output##* }"
testnet_cli_delta_ms=$((testnet_cli_epoch_ends - testnet_cli_timestamp_ns / 1000000))
[[ "$testnet_cli_delta_ms" -ge 82799000 && "$testnet_cli_delta_ms" -le 82801000 ]] || \
  fail 'testnet must not use the CLI 400 ms fallback when performance samples are empty'

price_failure_output="$(
  MOCK_PRICE_FAIL=1 CURL_BIN="$mock_curl" \
  "$repo_dir/monitor.sh" --identity "$identity" --rpc-url http://mock-rpc.invalid
)"
[[ "$price_failure_output" != *'solanaPrice='* ]] || fail 'failed price lookups must not emit a false zero price'

set +e
"$repo_dir/monitor.sh" --identity >/dev/null 2>&1
argument_status=$?
set -e
[[ "$argument_status" -eq 64 ]] || fail 'missing option values must return usage status 64'

printf 'monitor tests passed\n'

# VX responses are optional: failures must preserve local validator monitoring.
run_vx() {
  env CURL_BIN="$mock_curl" "$@" "$repo_dir/monitor.sh" \
    --identity "$identity" --rpc-url http://mock-rpc.invalid
}
assert_absent() {
  [[ "$1" != *"$2"* ]] || fail "unexpected field: $2"
}
vx_output="$(run_vx MOCK_VX_EXPECT_ENDPOINT=https://api.testnet.vx.tools/epochs/participation)"
assert_contains "$vx_output" 'vxApiUp=1i,vxDataFresh=1i'
assert_contains "$vx_output" 'vxEpoch=1026i'
assert_contains "$vx_output" 'vxParticipationPct=99.9676'
assert_contains "$vx_output" 'vxMissedSlots=25i'
assert_contains "$vx_output" 'vxSkipVoteSlots=504i'
assert_contains "$vx_output" 'vxRewardVotingLamports=2353670667i'
assert_contains "$vx_output" 'vxRewardProducerLamports=2582028114i'
assert_contains "$vx_output" 'vxRewardTotalLamports=4935698781i'
assert_contains "$vx_output" 'vxRewardOnChainLamports=79056i'
assert_contains "$vx_output" 'vxSlotLag=100i'
[[ "$(wc -l <<<"$vx_output")" -eq 1 ]] || fail 'VX must remain one Influx record'

vx_mainnet="$(run_vx MOCK_MAINNET_ALPENGLOW=1 MOCK_VX_EXPECT_ENDPOINT=https://api.vx.tools/epochs/participation)"
assert_contains "$vx_mainnet" 'cluster=mainnet-beta'
assert_contains "$vx_mainnet" 'vxApiUp=1i'
assert_contains "$vx_mainnet" 'genesis=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d'
assert_contains "$vx_mainnet" 'vxEnabled=1i'
# A truncated chain identifier is not a valid mainnet genesis hash.
vx_truncated="$(run_vx 'MOCK_BATCH_FILTER=map(if .id == "genesisHash" then .result = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp" else . end)')"
assert_contains "$vx_truncated" 'cluster=custom'
assert_contains "$vx_truncated" 'vxEnabled=0i'

for mode in 'MONITOR_VX_ENABLED=0' 'MOCK_MAINNET=1' 'MOCK_UNKNOWN_GENESIS=1'; do
  disabled="$(run_vx "$mode")"
  assert_contains "$disabled" 'vxEnabled=0i'
  assert_absent "$disabled" 'vxParticipationPct='
done
for filter in 'null' '[.[1]]' '. + [.[0]]' '.[0].missedSlots = -1' \
    '.[0].eligibleSlots = 1' '.[0].notarizedSlots = "76663"' \
    '.[0].missedSlots = 25.5'; do
  invalid="$(run_vx "MOCK_VX_FILTER=$filter" 2>/dev/null)"
  assert_contains "$invalid" 'vxApiUp=0i,vxDataFresh=0i'
  assert_contains "$invalid" 'collectorUp=1i'
  assert_absent "$invalid" 'vxParticipationPct='
  assert_absent "$invalid" 'vxRewardVotingLamports='
done
failed="$(run_vx MOCK_VX_FAIL=1 2>/dev/null)"
assert_contains "$failed" 'vxApiUp=0i,vxDataFresh=0i'
assert_contains "$failed" 'status=0i'
for slot in 437725000 437728000 null; do
  stale="$(run_vx "MOCK_VX_FILTER=.[0].lastIngestedSlot = $slot")"
  assert_contains "$stale" 'vxApiUp=1i,vxDataFresh=0i'
  assert_absent "$stale" 'vxParticipationPct='
  assert_absent "$stale" 'vxRewardVotingLamports='
done
partial="$(run_vx 'MOCK_VX_FILTER=.[0].rewards.producerBonusLamports = null')"
assert_contains "$partial" 'vxRewardVotingLamports=2353670667i'
assert_contains "$partial" 'vxRewardProducerAvailable=0i'
assert_contains "$partial" 'vxRewardTotalAvailable=0i'
assert_absent "$partial" 'vxRewardProducerLamports='
assert_absent "$partial" 'vxRewardTotalLamports='
zero="$(run_vx 'MOCK_VX_FILTER=.[0].rewards.votingLamports = 0 | .[0].rewards.totalLamports = .[0].rewards.producerBonusLamports')"
assert_contains "$zero" 'vxRewardVotingAvailable=1i,vxRewardVotingLamports=0i'
wrong_total="$(run_vx 'MOCK_VX_FILTER=.[0].rewards.totalLamports = 1')"
assert_contains "$wrong_total" 'vxRewardTotalAvailable=0i'
assert_absent "$wrong_total" 'vxRewardTotalLamports='
coverage="$(run_vx 'MOCK_VX_FILTER=.[0].missingFooters = 12')"
assert_contains "$coverage" 'vxMissingFooters=12i'
assert_contains "$coverage" 'vxParticipationPct='
not_admitted="$(run_vx 'MOCK_VX_FILTER=.[0].admitted = false')"
assert_contains "$not_admitted" 'vxAdmitted=0i'
assert_absent "$not_admitted" 'vxParticipationPct='
assert_absent "$not_admitted" 'vxRewardVotingLamports='
next_epoch="$(run_vx 'MOCK_BATCH_FILTER=map(if .id == "epochInfo" then .result.epoch = 1027 else . end)')"
assert_contains "$next_epoch" 'vxEpoch=1027i'
assert_contains "$next_epoch" 'vxDataFresh=0i'
assert_absent "$next_epoch" 'vxParticipationPct='
assert_absent "$next_epoch" 'vxRewardVotingLamports='
no_epoch="$(run_vx 'MOCK_BATCH_FILTER=map(select(.id != "epochInfo"))')"
assert_contains "$no_epoch" 'vxApiUp=0i,vxDataFresh=0i'
assert_absent "$no_epoch" 'vxEpoch='
for args in '--vx-timeout 0' '--vx-timeout invalid' '--vx-max-slot-lag -1'; do
  read -ra options <<<"$args"
  if CURL_BIN="$mock_curl" "$repo_dir/monitor.sh" "${options[@]}" >/dev/null 2>&1; then
    fail "invalid VX options accepted: $args"
  fi
done
printf '%s\n' 'VX monitor tests passed'

assert_contains "$vx_output" 'vxFastVoteInclusionPct=99.7'
assert_contains "$vx_output" 'vxParticipationRank=43i'
assert_contains "$vx_output" 'vxNextEpochAvailable=1i,vxNextEpoch=1027i,vxNextEpochAdmitted=1i'
for filter in 'del(.[0].fastFinalizedSlots)' '.[0].fastFinalizedSlots = 1001' \
    '.[0].finalizedSlots = 1001' '.[0].finalizedCerts = -1' \
    '.[0].finalizedCerts = 0 | .[0].finalizedSlots = 0 | .[0].fastFinalizedSlots = 0'; do
  optional="$(run_vx "MOCK_VX_FILTER=$filter")"
  assert_contains "$optional" 'vxParticipationPct='
  assert_absent "$optional" 'vxFastVoteInclusionPct='
done
fast_zero="$(run_vx 'MOCK_VX_FILTER=.[0].fastFinalizedSlots = 0')"
assert_contains "$fast_zero" 'vxFastVoteInclusionPct=0'
for filter in '[.[0]]' '. + [.[1]]' '.[1].admitted = null' '.[1].epoch = 1028'; do
  unknown="$(run_vx "MOCK_VX_FILTER=$filter")"
  assert_contains "$unknown" 'vxNextEpochAvailable=0i'
  assert_absent "$unknown" 'vxNextEpochAdmitted='
  assert_contains "$unknown" 'vxParticipationPct='
done
not_next="$(run_vx 'MOCK_VX_FILTER=.[1].admitted = false')"
assert_contains "$not_next" 'vxNextEpochAvailable=1i,vxNextEpoch=1027i,vxNextEpochAdmitted=0i'
current_ineligible="$(run_vx 'MOCK_VX_FILTER=.[0].admitted = false')"
assert_contains "$current_ineligible" 'vxNextEpochAdmitted=1i'
assert_absent "$current_ineligible" 'vxFastVoteInclusionPct='
assert_absent "$failed" 'vxNextEpochAdmitted='
assert_contains "$failed" 'vxNextEpochAvailable=0i'
rollover="$(run_vx 'MOCK_BATCH_FILTER=map(if .id == "epochInfo" then .result.epoch = 1027 else . end)' 'MOCK_VX_FILTER=. + [(.[1] | .epoch = 1028 | .admitted = false)]')"
assert_contains "$rollover" 'vxEpoch=1027i'
assert_contains "$rollover" 'vxNextEpoch=1028i,vxNextEpochAdmitted=0i'
assert_absent "$rollover" 'vxFastVoteInclusionPct='
assert_absent "$rollover" 'vxParticipationPct='
rank_missing="$(run_vx 'MOCK_VX_FILTER=.[0].rank = null')"
assert_absent "$rank_missing" 'vxParticipationRank='
assert_contains "$rank_missing" 'vxParticipationPct='
printf '%s\n' 'VX finalization and admission tests passed'

# Earnings from a live mainnet response, with epoch normalized to the RPC fixture.
earnings="$(run_vx MOCK_EARNINGS_EXPECT_ENDPOINT=https://api.testnet.vx.tools/epochs/earnings)"
assert_contains "$earnings" 'vxEarningsApiUp=1i,vxEarningsEpoch=1026i'
assert_contains "$earnings" 'vxEarningsBaseFeesLamports=186985000i'
assert_contains "$earnings" 'vxEarningsPriorityFeesLamports=2387302869i'
assert_contains "$earnings" 'vxEarningsBlockRevenueLamports=2574287869i'
assert_contains "$earnings" 'vxEarningsMevShareLamports=86507349i'
assert_contains "$earnings" 'vxEarningsEstimatedAlpenglowLamports=417911026i'
assert_contains "$earnings" 'vxEarningsEstimatedTotalLamports=3078706244i'
mainnet_earnings="$(run_vx MOCK_MAINNET_ALPENGLOW=1 MOCK_EARNINGS_EXPECT_ENDPOINT=https://api.vx.tools/epochs/earnings)"
assert_contains "$mainnet_earnings" 'vxEarningsApiUp=1i'
for filter in 'null' '[]' '. + .' '.[0].epoch += 1' '.[0].consensus = "tower"'; do
  invalid="$(run_vx "MOCK_EARNINGS_FILTER=$filter" 2>/dev/null)"
  assert_contains "$invalid" 'vxEarningsApiUp=0i'
  assert_contains "$invalid" 'vxApiUp=1i'
  assert_absent "$invalid" 'vxEarningsEstimatedTotalLamports='
done
failed="$(run_vx MOCK_EARNINGS_FAIL=1 2>/dev/null)"
assert_contains "$failed" 'vxEarningsApiUp=0i'
assert_contains "$failed" 'vxParticipationPct='
failed="$(run_vx MOCK_VX_FAIL=1 2>/dev/null)"
assert_contains "$failed" 'vxApiUp=0i'
assert_contains "$failed" 'vxEarningsEstimatedTotalLamports='
for filter in '.[0].rates.mevCommissionBps = null' '.[0].income.mevCommission = null' \
  '.[0].rates.blockRevenueCommissionBps = null' '.[0].rates.inflationRewardsCommissionBps = 10001' \
  '.[0].income.producerBonus = -1' '.[0].income.blockRevenueCommission = 9007199254740992' \
  '.[0].income.mevCommission = 1.5'; do
  partial="$(run_vx "MOCK_EARNINGS_FILTER=$filter")"
  assert_contains "$partial" 'vxEarningsApiUp=1i'
  assert_contains "$partial" 'vxEarningsEstimatedTotalAvailable=0i'
  assert_absent "$partial" 'vxEarningsEstimatedTotalLamports='
done
zero="$(run_vx 'MOCK_EARNINGS_FILTER=.[0].blockRevenue.mevTips = 0 | .[0].income.mevCommission = 0 | .[0].rates.mevCommissionBps = null')"
assert_contains "$zero" 'vxEarningsMevShareAvailable=1i,vxEarningsMevShareLamports=0i'
previous="$(run_vx 'MOCK_EARNINGS_FILTER=.[0].rates.mevCommissionBpsSource = "previousEpoch"')"
assert_contains "$previous" 'vxEarningsMevRatePreviousEpoch=1i'
for mode in 'MONITOR_VX_ENABLED=0' 'MOCK_MAINNET=1' 'MOCK_UNKNOWN_GENESIS=1'; do
  disabled="$(run_vx "$mode")"
  assert_contains "$disabled" 'vxEarningsApiUp=0i'
  assert_absent "$disabled" 'vxEarningsEstimatedTotalLamports='
done
printf 'VX earnings tests passed\n'

stake="$(run_vx MOCK_STAKE_EXPECT_ENDPOINT=https://api.testnet.vx.tools/validators/stake)"
assert_contains "$stake" 'vxStakeApiUp=1i,vxStakeEpoch=1026i,vxStakeDataFresh=1i'
assert_contains "$stake" 'vxStakeActivatingLamports=0i'
assert_contains "$stake" 'vxStakeDeactivatingLamports=4073023979018i'
assert_contains "$stake" 'vxStakeNetPendingLamports=-4073023979018i'
mainnet_stake="$(run_vx MOCK_MAINNET_ALPENGLOW=1 MOCK_STAKE_EXPECT_ENDPOINT=https://api.vx.tools/validators/stake)"
assert_contains "$mainnet_stake" 'vxStakeApiUp=1i'
positive="$(run_vx 'MOCK_STAKE_FILTER=.activatingStake = 5000000000000 | .moving.activating = .activatingStake')"
assert_contains "$positive" 'vxStakeNetPendingLamports=926976020982i'
for filter in 'null' '.epoch += 1' '.identity = "wrong"' '.voteKey = "wrong"' \
  '.activatingStake = -1' '.deactivatingStake = null' '.activeStake = 9007199254740992' \
  '.activatingStake = 1.5'; do
  invalid="$(run_vx "MOCK_STAKE_FILTER=$filter" 2>/dev/null)"
  assert_contains "$invalid" 'vxStakeApiUp=0i,vxStakeDataFresh=0i'
  assert_absent "$invalid" 'vxStakeNetPendingLamports='
  assert_contains "$invalid" 'vxEarningsApiUp=1i'
done
for filter in '.moving.updatedAt -= 301' '.moving.updatedAt += 120' \
  'del(.moving.updatedAt)' '.moving.activating = 123'; do
  stale="$(run_vx "MOCK_STAKE_FILTER=$filter")"
  assert_contains "$stale" 'vxStakeApiUp=1i,vxStakeEpoch=1026i,vxStakeDataFresh=0i'
  assert_absent "$stale" 'vxStakeActivatingLamports='
done
failed="$(run_vx MOCK_STAKE_FAIL=1 2>/dev/null)"
assert_contains "$failed" 'vxStakeApiUp=0i'
assert_contains "$failed" 'vxParticipationPct='
assert_contains "$failed" 'vxEarningsApiUp=1i'
for mode in 'MONITOR_VX_ENABLED=0' 'MOCK_MAINNET=1' 'MOCK_UNKNOWN_GENESIS=1' 'MOCK_BATCH_FAIL=1'; do
  disabled="$(run_vx "$mode" 2>/dev/null)"
  assert_contains "$disabled" 'vxStakeApiUp=0i'
  assert_absent "$disabled" 'vxStakeNetPendingLamports='
done
printf 'VX pending stake tests passed\n'
