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
assert_contains "$output" "nodemonitor,pubkey=$identity "
assert_contains "$output" 'status=0i'
assert_contains "$output" 'rootSlot=437726128i'
assert_contains "$output" 'lastVote=437726159i'
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
assert_contains "$output" 'validatorCreditsCurrent=282326i'
assert_contains "$output" 'pctVote=1568.48'
assert_contains "$output" 'tps=698637083708i'

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
assert_contains "$batch_output" 'leaderSlots=0i'
assert_contains "$batch_output" 'nodes=0i'

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
