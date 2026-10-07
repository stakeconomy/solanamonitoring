#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: alpenglow-observed-vote-inclusion-v3.sh --rpc-url URL --identity PUBKEY --vote-account PUBKEY [OPTIONS]

Required:
  --rpc-url URL
  --identity PUBKEY
  --vote-account PUBKEY

Options:
  --state PATH
  --rpc-timeout SECONDS
  --reference-count N
  --rate-samples N
  --help
EOF
}

fail_usage() {
  printf 'error: %s\n' "$1" >&2
  exit 64
}

require_commands() {
  local command_name
  for command_name in bash "$curl_bin" jq flock mktemp mv chmod date sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'error: required command unavailable: %s\n' "$command_name" >&2
      exit 69
    }
  done
}

if [[ "${1:-}" == "--help" && $# -eq 1 ]]; then
  usage
  exit 0
fi

rpc_url=''
identity=''
vote_account=''
state_file="${MONITOR_ALPENGLOW_OBSERVED_STATE:-${SOLANA_CONFIG_DIR:-$HOME/.config/solana}/alpenglow-observed-vote-inclusion-v3.json}"
rpc_timeout="${MONITOR_ALPENGLOW_RPC_TIMEOUT:-0.7}"
reference_count="${MONITOR_ALPENGLOW_REFERENCE_COUNT:-8}"
rate_samples="${MONITOR_ALPENGLOW_RATE_SAMPLES:-20}"
curl_bin="${CURL_BIN:-curl}"

while (($#)); do
  case "$1" in
    --rpc-url|--identity|--vote-account|--state|--rpc-timeout|--reference-count|--rate-samples)
      (($# >= 2)) || fail_usage "$1 requires a value"
      case "$1" in
        --rpc-url) rpc_url="$2" ;;
        --identity) identity="$2" ;;
        --vote-account) vote_account="$2" ;;
        --state) state_file="$2" ;;
        --rpc-timeout) rpc_timeout="$2" ;;
        --reference-count) reference_count="$2" ;;
        --rate-samples) rate_samples="$2" ;;
      esac
      shift 2
      ;;
    --help) fail_usage '--help must be used alone' ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$rpc_url" ]] || fail_usage '--rpc-url is required'
[[ -n "$identity" ]] || fail_usage '--identity is required'
[[ -n "$vote_account" ]] || fail_usage '--vote-account is required'
[[ -n "$state_file" ]] || fail_usage '--state must not be empty'
[[ "$rpc_timeout" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || fail_usage '--rpc-timeout must be a positive number'
[[ ! "$rpc_timeout" =~ ^0*([.]0*)?$ ]] || fail_usage '--rpc-timeout must be positive'
if [[ ! "$reference_count" =~ ^[1-9][0-9]*$ ]] || ((reference_count > 32)); then
  fail_usage '--reference-count must be between 1 and 32'
fi
if [[ ! "$rate_samples" =~ ^[1-9][0-9]*$ ]] || ((rate_samples > 100)); then
  fail_usage '--rate-samples must be between 1 and 100'
fi

require_commands

genesis_expected='4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY'
vote_program='Vote111111111111111111111111111111111111111'

is_u63_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  ((${#1} < 19)) && return 0
  ((${#1} == 19)) || return 1
  # Decimal-string ordering is intentional; arithmetic would overflow at max+1.
  # shellcheck disable=SC2071
  [[ ! "$1" > 9223372036854775807 ]]
}

checked_add() {
  is_u63_decimal "$1" && is_u63_decimal "$2" || return 1
  local left=$((10#$1)) right=$((10#$2))
  ((left <= 9223372036854775807 - right)) || return 1
  printf '%s' "$((left + right))"
}

checked_sub() {
  is_u63_decimal "$1" && is_u63_decimal "$2" || return 1
  local left=$((10#$1)) right=$((10#$2))
  ((left >= right)) || return 1
  printf '%s' "$((left - right))"
}

rpc_call() {
  "$curl_bin" --silent --show-error --fail --max-time "$rpc_timeout" \
    --header 'Content-Type: application/json' --data "$1" "$rpc_url"
}

influx_tag() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/=/\\=/g' -e 's/ /\\ /g'
}

validate_core_state() {
  local path="$1" totals expected_sum included expected missed unattributed last
  jq -e --arg genesis "$genesis_expected" '
    def exact_keys($keys): (keys | sort) == ($keys | sort);
    def dec:
      type == "string" and test("^(0|[1-9][0-9]*)$") and
      ((length < 19) or (length == 19 and . <= "9223372036854775807"));
    def pos: dec and . != "0";
    . as $root |
    exact_keys(["version","genesis","consensus","pubkey","vote_account","config","schedule","epoch","reference_votes","accounts","leader_schedule_epoch","leader_slots","totals","last_attributed_slot"]) and
    .version == 3 and .genesis == $genesis and .consensus == "alpenglow" and
    (.pubkey|type) == "string" and (.pubkey|length) > 0 and
    (.vote_account|type) == "string" and (.vote_account|length) > 0 and
    (.config | exact_keys(["reference_count","rate_samples"])) and
    (.config.reference_count|type) == "number" and (.config.reference_count|floor) == .config.reference_count and
    .config.reference_count >= 1 and .config.reference_count <= 32 and
    (.config.rate_samples|type) == "number" and (.config.rate_samples|floor) == .config.rate_samples and
    .config.rate_samples >= 1 and .config.rate_samples <= 100 and
    .schedule == {slots_per_epoch:432000,leader_schedule_slot_offset:432000,warmup:true,first_normal_epoch:14,first_normal_slot:524256} and
    (.epoch|dec) and
    (.reference_votes|type) == "array" and all(.reference_votes[]; type == "string" and length > 0) and
    (.reference_votes|unique|length) == (.reference_votes|length) and
    (.reference_votes|index($root.vote_account)|not) and
    (.accounts|type) == "object" and
    ((.accounts|keys|sort) == ([.vote_account] + .reference_votes | sort)) and
    (.accounts[.vote_account].node|type) == "string" and
    (.accounts[.vote_account].total|dec) and (.accounts[.vote_account].slot|dec) and
    (.accounts[.vote_account] | exact_keys(["node","total","slot","gcd","samples","increment"])) and
    (all(.accounts[];
      exact_keys(["node","total","slot","gcd","samples","increment"]) and
      (((.node == null) and (.total == null) and (.slot == null)) or
       ((.node|type) == "string" and (.node|length) > 0 and (.total|dec) and (.slot|dec) and .slot == $root.accounts[$root.vote_account].slot)) and
      ((.gcd == null) or (.gcd|pos)) and
      ((.increment == null) or (.increment|pos)) and
      (.samples|type) == "number" and (.samples|floor) == .samples and
      .samples >= 0 and .samples <= $root.config.rate_samples and
      (if .increment != null then .gcd != null and .samples >= 1 else true end) and
      (if .node == null then .gcd == null and .samples == 0 and .increment == null else true end)
    )) and
    ((.leader_schedule_epoch == null and .leader_slots == {}) or
     ((.leader_schedule_epoch|dec) and (.leader_slots|type) == "object")) and
    (.totals | exact_keys(["included","expected","missed","unattributed_slots"])) and
    (.totals.included|dec) and (.totals.expected|dec) and (.totals.missed|dec) and (.totals.unattributed_slots|dec) and
    (.last_attributed_slot|dec)
  ' "$path" >/dev/null 2>&1 || return 1
  totals="$(jq -r '[.totals.included,.totals.expected,.totals.missed,.totals.unattributed_slots,.last_attributed_slot]|@tsv' "$path")" || return 1
  IFS=$'\t' read -r included expected missed unattributed last <<<"$totals"
  is_u63_decimal "$unattributed" && is_u63_decimal "$last" || return 1
  expected_sum="$(checked_add "$included" "$missed")" || return 1
  [[ "$expected_sum" == "$expected" ]]
}

write_state_atomic() {
  local document="$1" state_dir temp_state
  state_dir="${state_file%/*}"
  [[ "$state_dir" != "$state_file" ]] || state_dir='.'
  [[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || return 1
  temp_state="$(mktemp "$state_dir/.alpenglow-observed-v3.XXXXXX")" || return 1
  if ! printf '%s\n' "$document" >"$temp_state" ||
     ! chmod 0600 "$temp_state" ||
     ! mv -f "$temp_state" "$state_file"; then
    rm -f "$temp_state"
    return 1
  fi
}

emit_measurement() {
  local observed_slot="$1" ready="$2" usable="$3"
  printf 'alpenglow_observed,cluster=testnet,genesis=%s,consensus=alpenglow,pubkey=%s,vote_account=%s,schema=3 included_total=%si,expected_total=%si,missed_total=%si,unattributed_slots_total=%si,ready=%si,observed_slot=%si,last_attributed_slot=%si,usable_references=%si\n' \
    "$(influx_tag "$genesis_expected")" "$(influx_tag "$identity")" "$(influx_tag "$vote_account")" \
    "$total_included" "$total_expected" "$total_missed" "$total_unattributed" \
    "$ready" "$observed_slot" "$last_attributed_slot" "$usable"
}

state_dir="${state_file%/*}"
[[ "$state_dir" != "$state_file" ]] || state_dir='.'
[[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || {
  printf 'error: cannot create state directory\n' >&2
  exit 1
}
exec {lock_fd}>"${state_file}.lock" || { printf 'error: cannot open state lock\n' >&2; exit 1; }
flock -n "$lock_fd" || exit 0

if [[ -e "$state_file" ]]; then
  validate_core_state "$state_file" || { printf 'error: invalid existing v3 state\n' >&2; exit 1; }
  printf 'error: advancing existing state is not implemented\n' >&2
  exit 1
fi

batch_payload="$(jq -cn --arg vote "$vote_account" '[
  {jsonrpc:"2.0",id:"v3-genesis",method:"getGenesisHash"},
  {jsonrpc:"2.0",id:"v3-ag-genesis-cert",method:"getAgGenesisCert"},
  {jsonrpc:"2.0",id:"v3-epoch-schedule",method:"getEpochSchedule"},
  {jsonrpc:"2.0",id:"v3-accounts",method:"getMultipleAccounts",params:[[$vote],{encoding:"jsonParsed",commitment:"finalized"}]}
]')" || { printf 'error: cannot build mandatory RPC batch\n' >&2; exit 1; }
batch_response="$(rpc_call "$batch_payload" 2>/dev/null)" || { printf 'error: mandatory RPC batch failed\n' >&2; exit 1; }

cold_snapshot="$(jq -cer --arg genesis "$genesis_expected" --arg owner "$vote_program" --arg identity "$identity" '
  if type != "array" or length != 4 or ([.[].id] | unique | length) != 4 then error("invalid batch ids") else . end |
  (map(select(.id == "v3-genesis")) | if length == 1 then .[0] else error("genesis id") end) as $g |
  (map(select(.id == "v3-ag-genesis-cert")) | if length == 1 then .[0] else error("cert id") end) as $c |
  (map(select(.id == "v3-epoch-schedule")) | if length == 1 then .[0] else error("schedule id") end) as $s |
  (map(select(.id == "v3-accounts")) | if length == 1 then .[0] else error("accounts id") end) as $a |
  if any(.[]; has("error")) or $g.result != $genesis or $c.result == null or
     $s.result != {slotsPerEpoch:432000,leaderScheduleSlotOffset:432000,warmup:true,firstNormalEpoch:14,firstNormalSlot:524256}
  then error("network isolation failed") else . end |
  ($a.result.context.slot) as $slot | ($a.result.value) as $values |
  if ($slot|type) != "number" or $slot < 0 or $slot > 9007199254740991 or ($slot|floor) != $slot or
     ($values|type) != "array" or ($values|length) != 1 or $values[0] == null or
     $values[0].owner != $owner or $values[0].data.parsed.type != "vote" or
     $values[0].data.parsed.info.nodePubkey != $identity
  then error("invalid monitored account") else . end |
  ($values[0].data.parsed.info.epochCredits) as $history |
  if ($history|type) != "array" or ($history|length) == 0 then error("invalid epoch credits") else . end |
  ($history[-1]) as $credit |
  if ($credit|type) != "object" or ($credit.epoch|type) != "string" or
     ($credit.epoch|test("^(0|[1-9][0-9]*)$")|not) or
     ($credit.credits|type) != "string" or ($credit.credits|test("^(0|[1-9][0-9]*)$")|not) or
     ($credit.previousCredits|type) != "string" or ($credit.previousCredits|test("^(0|[1-9][0-9]*)$")|not)
  then error("invalid epoch credit entry") else . end |
  {slot:($slot|tostring),epoch:$credit.epoch,total:$credit.credits,node:$identity}
' <<<"$batch_response" 2>/dev/null)" || { printf 'error: mandatory RPC data or isolation failure\n' >&2; exit 1; }

observed_slot="$(jq -r '.slot' <<<"$cold_snapshot")"
credit_epoch="$(jq -r '.epoch' <<<"$cold_snapshot")"
monitored_total="$(jq -r '.total' <<<"$cold_snapshot")"
if ! is_u63_decimal "$observed_slot" || ! is_u63_decimal "$credit_epoch" || ! is_u63_decimal "$monitored_total"; then
  printf 'error: mandatory RPC integer out of range\n' >&2
  exit 1
fi
if ((10#$observed_slot >= 524256)); then
  derived_epoch=$((14 + (10#$observed_slot - 524256) / 432000))
else
  derived_epoch=0
  for ((candidate_epoch = 1; candidate_epoch <= 14; candidate_epoch++)); do
    candidate_first_slot=$((((1 << candidate_epoch) - 1) * 32))
    ((candidate_first_slot <= 10#$observed_slot)) || break
    derived_epoch=$candidate_epoch
  done
fi
((10#$credit_epoch <= derived_epoch)) || { printf 'error: epoch credits exceed current epoch\n' >&2; exit 1; }
epoch="$derived_epoch"

reference_votes='[]'
accounts="$(jq -cn --arg vote "$vote_account" --arg identity "$identity" --arg total "$monitored_total" --arg slot "$observed_slot" \
  '{($vote):{node:$identity,total:$total,slot:$slot,gcd:null,samples:0,increment:null}}')"
optional_payload="$(jq -cn '{jsonrpc:"2.0",id:"v3-vote-accounts",method:"getVoteAccounts",params:[{commitment:"finalized"}]}')"
if optional_response="$(rpc_call "$optional_payload" 2>/dev/null)"; then
  reference_votes="$(jq -ce --arg own "$vote_account" --argjson limit "$reference_count" '
    if has("error") or (.result.current|type) != "array" or (.result.delinquent|type) != "array" then error("invalid") else
      [(.result.current + .result.delinquent)[] | .votePubkey | select(type == "string" and . != $own)] | unique | .[:$limit]
    end
  ' <<<"$optional_response" 2>/dev/null)" || reference_votes='[]'
fi
while IFS= read -r reference_vote; do
  accounts="$(jq -c --arg vote "$reference_vote" '. + {($vote):{node:null,total:null,slot:null,gcd:null,samples:0,increment:null}}' <<<"$accounts")"
done < <(jq -r '.[]' <<<"$reference_votes")

state_document="$(jq -cn \
  --arg genesis "$genesis_expected" --arg identity "$identity" --arg vote "$vote_account" \
  --arg epoch "$epoch" --argjson reference_count "$reference_count" --argjson rate_samples "$rate_samples" \
  --argjson references "$reference_votes" --argjson accounts "$accounts" '
  {
    version:3,genesis:$genesis,consensus:"alpenglow",pubkey:$identity,vote_account:$vote,
    config:{reference_count:$reference_count,rate_samples:$rate_samples},
    schedule:{slots_per_epoch:432000,leader_schedule_slot_offset:432000,warmup:true,first_normal_epoch:14,first_normal_slot:524256},
    epoch:$epoch,reference_votes:$references,accounts:$accounts,
    leader_schedule_epoch:null,leader_slots:{},
    totals:{included:"0",expected:"0",missed:"0",unattributed_slots:"0"},
    last_attributed_slot:"0"
  }')" || { printf 'error: cannot construct state\n' >&2; exit 1; }

total_included=0
total_expected=0
total_missed=0
total_unattributed=0
last_attributed_slot=0
write_state_atomic "$state_document" || { printf 'error: atomic state write failed\n' >&2; exit 1; }
emit_measurement "$observed_slot" 0 0
