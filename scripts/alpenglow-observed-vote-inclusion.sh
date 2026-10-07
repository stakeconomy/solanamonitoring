#!/usr/bin/env bash
# Derives observed/inferred Alpenglow vote inclusion from finalized vote-account
# reward-accounting deltas. This is not certificate-direct Votor telemetry.

set -u
set -o pipefail
umask 077

rpc_url="$1"
state_file="$2"
genesis_hash="$3"
own_vote_account="$4"
own_node_pubkey="$5"
reference_accounts_json="$6"
curl_bin="$7"
rpc_timeout="$8"
epoch_start_slot="$9"
rate_samples="${10:-20}"

emit_unready() {
  local references="$1"
  printf 'alpenglowObservedReady=0i,alpenglowObservedUnattributed=1i,alpenglowObservedReferences=%si' "$references"
}

gcd() {
  local a="$1" b="$2" remainder
  while ((b != 0)); do
    remainder=$((a % b))
    a="$b"
    b="$remainder"
  done
  printf '%s' "$a"
}

rpc_call() {
  "$curl_bin" --silent --show-error --fail --max-time "$rpc_timeout" \
    --header 'Content-Type: application/json' --data "$1" "$rpc_url"
}

reference_count="$(jq -r 'length' <<<"$reference_accounts_json" 2>/dev/null || printf '0')"
if [[ ! "$reference_count" =~ ^[0-9]+$ ]]; then
  emit_unready 0
  exit 0
fi

accounts_json="$(jq -cn --arg own "$own_vote_account" --arg own_node "$own_node_pubkey" --argjson references "$reference_accounts_json" \
  '[{vote: $own, node: $own_node}] + $references' 2>/dev/null)" || {
  emit_unready "$reference_count"
  exit 0
}

account_pubkeys="$(jq -c '[.[].vote]' <<<"$accounts_json")"
snapshot_payload="$(jq -cn --argjson accounts "$account_pubkeys" '{jsonrpc:"2.0",id:"alpenglowObservedAccounts",method:"getMultipleAccounts",params:[$accounts,{encoding:"jsonParsed",commitment:"finalized"}]}' )"
if ! snapshot_response="$(rpc_call "$snapshot_payload" 2>/dev/null)"; then
  emit_unready "$reference_count"
  exit 0
fi

snapshot="$(jq -cer --argjson accounts "$accounts_json" '
  .result as $result |
  ($result.context.slot // null) as $slot |
  ($result.value // null) as $values |
  if (($slot | type) != "number") or ($slot < 0) or ($slot | floor != $slot) or
     (($values | type) != "array") or (($values | length) != ($accounts | length))
  then error("invalid finalized account snapshot")
  else {
    slot: $slot,
    accounts: [range(0; $accounts | length) as $i |
      $accounts[$i] + {
        total: (
          ($values[$i].data.parsed.info.epochCredits // []) as $history |
          ([
            $history[] |
            select(
              if type == "object" then .epoch != "18446744073709551615"
              elif type == "array" then .[0] != 18446744073709551615 and .[0] != "18446744073709551615"
              else true end
            )
          ] | last) as $credit |
          if ($credit | type) == "object" and
             ($credit.credits | type) == "string" and
             ($credit.credits | test("^(0|[1-9][0-9]*)$")) and
             (($credit.credits | length) < 19 or
              (($credit.credits | length) == 19 and $credit.credits <= "9223372036854775807"))
          then ($credit.credits | tonumber)
          elif ($credit | type) == "array" and ($credit | length) == 3 and
               ($credit[1] | type) == "number" and ($credit[1] >= 0) and ($credit[1] | floor == $credit[1])
          then $credit[1]
          else null end
        )
      }
    ]
  }
  end
' <<<"$snapshot_response" 2>/dev/null)" || {
  emit_unready "$reference_count"
  exit 0
}

observed_slot="$(jq -r '.slot' <<<"$snapshot")"
leader_payload="$(jq -cn --argjson start "$epoch_start_slot" '{jsonrpc:"2.0",id:"alpenglowObservedLeaders",method:"getLeaderSchedule",params:[$start,{commitment:"finalized"}]}' )"
leader_schedule='null'
if leader_response="$(rpc_call "$leader_payload" 2>/dev/null)"; then
  leader_schedule="$(jq -ce '.result // null | if type == "object" or . == null then . else error("invalid leader schedule") end' <<<"$leader_response" 2>/dev/null || printf 'null')"
fi

state='{}'
if [[ -f "$state_file" ]]; then
  state="$(jq -ce --arg genesis "$genesis_hash" --arg vote "$own_vote_account" '
    if .version == 1 and .genesis == $genesis and .vote_account == $vote and (.accounts | type) == "object"
    then . else {} end
  ' "$state_file" 2>/dev/null || printf '{}')"
fi

next_accounts='{}'
unknown=0
own_included=''
expected=''
ready=0

while IFS= read -r account_record; do
  vote="$(jq -r '.vote' <<<"$account_record")"
  node="$(jq -r '.node // ""' <<<"$account_record")"
  total="$(jq -r '.total // ""' <<<"$account_record")"
  previous="$(jq -c --arg vote "$vote" '.accounts[$vote] // null' <<<"$state")"
  previous_slot="$(jq -r '.slot // empty' <<<"$previous")"
  previous_total="$(jq -r '.total // empty' <<<"$previous")"
  previous_increment="$(jq -r '.increment // empty' <<<"$previous")"
  previous_gcd="$(jq -r '.gcd // empty' <<<"$previous")"
  previous_samples="$(jq -r '.samples // 0' <<<"$previous")"
  increment="$previous_increment"
  reward_gcd="$previous_gcd"
  sample_count="$previous_samples"
  count=''
  clean=0

  if [[ "$total" =~ ^[0-9]+$ && "$previous_slot" =~ ^[0-9]+$ && "$previous_total" =~ ^[0-9]+$ &&
        "$observed_slot" =~ ^[0-9]+$ ]] && ((observed_slot > previous_slot && total >= previous_total)); then
    # getLeaderSchedule returns slots relative to the epoch start.
    if [[ "$leader_schedule" != null ]] &&
       ! ((previous_slot < epoch_start_slot + 8 && observed_slot >= epoch_start_slot + 8)); then
      relative_before=$((previous_slot - epoch_start_slot))
      relative_after=$((observed_slot - epoch_start_slot))
      if ((relative_before < 0)); then relative_before=0; fi
      leader_in_gap="$(jq -r --arg node "$node" --argjson before "$relative_before" --argjson after "$relative_after" \
        '[$node as $n | .[$n][]? | select(. > $before and . <= $after)] | length' <<<"$leader_schedule" 2>/dev/null || printf '1')"
      if [[ "$leader_in_gap" == 0 ]]; then
        clean=1
      fi
    fi

    if ((clean)); then
      delta=$((total - previous_total))
      if ((delta > 0)); then
        if [[ "$reward_gcd" =~ ^[1-9][0-9]*$ ]]; then
          reward_gcd="$(gcd "$reward_gcd" "$delta")"
        else
          reward_gcd="$delta"
        fi
        sample_count=$((sample_count + 1))
        # A one-slot interval proves its positive delta is exactly one reward.
        # Longer intervals need a conservative GCD learning window; otherwise a
        # multi-inclusion delta can be mistaken for one inclusion.
        if ((observed_slot - previous_slot == 1 || sample_count >= rate_samples)); then
          increment="$reward_gcd"
        fi
      fi
      if ((delta == 0)); then
        count=0
      elif [[ "$increment" =~ ^[1-9][0-9]*$ && $((delta % increment)) -eq 0 ]]; then
        count=$((delta / increment))
      fi
    fi
  fi

  if [[ "$total" =~ ^[0-9]+$ ]]; then
    next_accounts="$(jq -c --arg vote "$vote" --argjson total "$total" --argjson slot "$observed_slot" --arg increment "$increment" --arg gcd "$reward_gcd" --argjson samples "$sample_count" \
      '. + {($vote): ({total: $total, slot: $slot, samples: $samples} +
        (if $gcd | test("^[1-9][0-9]*$") then {gcd: ($gcd | tonumber)} else {} end) +
        (if $increment | test("^[1-9][0-9]*$") then {increment: ($increment | tonumber)} else {} end))}' <<<"$next_accounts")"
  fi

  if [[ -z "$count" ]]; then
    unknown=$((unknown + 1))
  elif [[ "$vote" == "$own_vote_account" ]]; then
    own_included="$count"
  elif [[ -z "$expected" || "$count" -gt "$expected" ]]; then
    expected="$count"
  fi
done < <(jq -c '.accounts[]' <<<"$snapshot")

state_document="$(jq -cn --arg genesis "$genesis_hash" --arg vote "$own_vote_account" --argjson accounts "$next_accounts" \
  '{version: 1, genesis: $genesis, vote_account: $vote, accounts: $accounts}')"
state_dir="$(dirname "$state_file")"
if [[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null; then
  if temp_state="$(mktemp "${state_file}.tmp.XXXXXX" 2>/dev/null)"; then
    if printf '%s\n' "$state_document" >"$temp_state" && mv -f "$temp_state" "$state_file"; then
      :
    else
      rm -f "$temp_state"
      unknown=$((unknown + 1))
    fi
  else
    unknown=$((unknown + 1))
  fi
else
  unknown=$((unknown + 1))
fi

fields="alpenglowObservedReady=0i,alpenglowObservedUnattributed=${unknown}i,alpenglowObservedReferences=${reference_count}i,alpenglowObservedSlot=${observed_slot}i"
if [[ "$own_included" =~ ^[0-9]+$ && "$expected" =~ ^[0-9]+$ ]]; then
  missed=$((expected - own_included))
  if ((missed < 0)); then missed=0; fi
  fields="alpenglowObservedReady=1i,alpenglowObservedIncluded=${own_included}i,alpenglowObservedExpected=${expected}i,alpenglowObservedMissed=${missed}i,alpenglowObservedUnattributed=${unknown}i,alpenglowObservedReferences=${reference_count}i,alpenglowObservedSlot=${observed_slot}i"
fi
printf '%s' "$fields"
