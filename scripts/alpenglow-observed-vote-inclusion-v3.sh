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

fail_usage() { printf 'error: %s\n' "$1" >&2; exit 64; }
is_solana_pubkey() { [[ ${#1} -ge 32 && ${#1} -le 44 && "$1" =~ ^[1-9A-HJ-NP-Za-km-z]+$ ]]; }
has_control() { local LC_ALL=C; [[ "$1" =~ [[:cntrl:]] ]]; }

if [[ "${1:-}" == "--help" && $# -eq 1 ]]; then usage; exit 0; fi

rpc_url=''
identity=''
vote_account=''
state_file="${MONITOR_ALPENGLOW_OBSERVED_STATE:-${SOLANA_CONFIG_DIR:-$HOME/.config/solana}/alpenglow-observed-vote-inclusion-v3.json}"
rpc_timeout="${MONITOR_ALPENGLOW_RPC_TIMEOUT:-0.7}"
reference_count="${MONITOR_ALPENGLOW_REFERENCE_COUNT:-8}"
rate_samples="${MONITOR_ALPENGLOW_RATE_SAMPLES:-20}"
cohort_seed="${MONITOR_ALPENGLOW_COHORT_SEED:-$RANDOM-$RANDOM-$RANDOM}"
curl_bin="${CURL_BIN:-curl}"
declare -A seen_args=()
while (($#)); do
  case "$1" in
    --rpc-url|--identity|--vote-account|--state|--rpc-timeout|--reference-count|--rate-samples)
      [[ -z "${seen_args[$1]:-}" ]] || fail_usage "duplicate argument: $1"
      seen_args[$1]=1
      (($# >= 2)) || fail_usage "$1 requires a value"
      [[ "$2" != --* ]] || fail_usage "$1 requires a value"
      case "$1" in
        --rpc-url) rpc_url="$2" ;;
        --identity) identity="$2" ;;
        --vote-account) vote_account="$2" ;;
        --state) state_file="$2" ;;
        --rpc-timeout) rpc_timeout="$2" ;;
        --reference-count) reference_count="$2" ;;
        --rate-samples) rate_samples="$2" ;;
      esac
      shift 2 ;;
    --help) fail_usage '--help must be used alone' ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$rpc_url" ]] || fail_usage '--rpc-url is required'
[[ -n "$identity" ]] || fail_usage '--identity is required'
[[ -n "$vote_account" ]] || fail_usage '--vote-account is required'
[[ -n "$state_file" ]] || fail_usage '--state must not be empty'
[[ ${#rpc_url} -le 2048 && "$rpc_url" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] || fail_usage '--rpc-url must be an http or https URL'
is_solana_pubkey "$identity" || fail_usage '--identity must be a 32..44 character Solana Base58 public key'
is_solana_pubkey "$vote_account" || fail_usage '--vote-account must be a 32..44 character Solana Base58 public key'
[[ ${#state_file} -le 4096 && "$state_file" == /* ]] || fail_usage '--state must be an absolute path'
has_control "$state_file" && fail_usage '--state must not contain control characters'
[[ ! "$state_file" =~ (^|/)\.\.?(/|$) ]] || fail_usage '--state must not contain dot path components'
[[ ${#rpc_timeout} -le 16 && "$rpc_timeout" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || fail_usage '--rpc-timeout must be a positive number'
[[ ! "$rpc_timeout" =~ ^0*([.]0*)?$ ]] || fail_usage '--rpc-timeout must be positive'
if [[ ! "$reference_count" =~ ^[1-9][0-9]*$ ]] || ((${#reference_count} > 2)) || ((reference_count > 32)); then fail_usage '--reference-count must be between 1 and 32'; fi
if [[ ! "$rate_samples" =~ ^[1-9][0-9]*$ ]] || ((${#rate_samples} > 3)) || ((rate_samples > 100)); then fail_usage '--rate-samples must be between 1 and 100'; fi
[[ -n "$cohort_seed" && ${#cohort_seed} -le 128 ]] || fail_usage 'MONITOR_ALPENGLOW_COHORT_SEED must be 1..128 characters'
has_control "$cohort_seed" && fail_usage 'MONITOR_ALPENGLOW_COHORT_SEED must not contain control characters'
for command_name in bash "$curl_bin" jq flock mktemp mv chmod date sed; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'error: required command unavailable: %s\n' "$command_name" >&2; exit 69; }
done

genesis_expected='4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY'
vote_program='Vote111111111111111111111111111111111111111'
max_u63='9223372036854775807'
max_safe_json='9007199254740991'

is_u63_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  ((${#1} < 19)) && return 0
  ((${#1} == 19)) || return 1
  # Decimal lexical ordering is intentional at the signed-64 boundary.
  # shellcheck disable=SC2071
  [[ "$1" < "$max_u63" || "$1" == "$max_u63" ]]
}

dec_le() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ && "$2" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  ((${#1} < ${#2})) && return 0
  ((${#1} > ${#2})) && return 1
  [[ "$1" < "$2" || "$1" == "$2" ]]
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

gcd_decimal() {
  local a=$((10#$1)) b=$((10#$2)) t
  while ((b != 0)); do t=$((a % b)); a=$b; b=$t; done
  printf '%s' "$a"
}

rpc_call() {
  "$curl_bin" --silent --show-error --fail --max-time "$rpc_timeout" --header 'Content-Type: application/json' --data "$1" --url "$rpc_url" --
}

influx_tag() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/=/\\=/g' -e 's/ /\\ /g'; }

write_state_atomic() {
  local document="$1" state_dir temp_state
  state_dir="${state_file%/*}"; [[ "$state_dir" != "$state_file" ]] || state_dir='.'
  [[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || return 1
  temp_state="$(mktemp "$state_dir/.alpenglow-observed-v3.XXXXXX")" || return 1
  if ! printf '%s\n' "$document" >"$temp_state" || ! chmod 0600 "$temp_state" || ! mv -f -- "$temp_state" "$state_file"; then rm -f -- "$temp_state"; return 1; fi
}

emit_measurement() {
  local observed_slot="$1" ready="$2" usable="$3"
  printf 'alpenglow_observed,cluster=testnet,genesis=%s,consensus=alpenglow,pubkey=%s,vote_account=%s,schema=3 included_total=%si,expected_total=%si,missed_total=%si,unattributed_slots_total=%si,ready=%si,observed_slot=%si,last_attributed_slot=%si,usable_references=%si\n' \
    "$(influx_tag "$genesis_expected")" "$(influx_tag "$identity")" "$(influx_tag "$vote_account")" \
    "$total_included" "$total_expected" "$total_missed" "$total_unattributed" "$ready" "$observed_slot" "$last_attributed_slot" "$usable"
}

validate_core_state() {
  local path="$1" row included expected missed sum
  jq -e --arg genesis "$genesis_expected" '
    def exact_keys($expected): (keys|sort)==($expected|sort);
    def dec: type=="string" and test("^(0|[1-9][0-9]*)$") and ((length<19) or (length==19 and .<="9223372036854775807"));
    def pos: dec and .!="0";
    def pubkey: type=="string" and length>=32 and length<=44 and test("^[1-9A-HJ-NP-Za-km-z]+$");
    . as $root |
    exact_keys(["version","genesis","consensus","pubkey","vote_account","config","schedule","epoch","reference_votes","accounts","leader_schedule_epoch","leader_slots","totals","last_attributed_slot"]) and
    .version==3 and .genesis==$genesis and .consensus=="alpenglow" and (.pubkey|pubkey) and (.vote_account|pubkey) and
    (.config|exact_keys(["reference_count","rate_samples"])) and
    (.config.reference_count|type)=="number" and (.config.reference_count|floor)==.config.reference_count and .config.reference_count>=1 and .config.reference_count<=32 and
    (.config.rate_samples|type)=="number" and (.config.rate_samples|floor)==.config.rate_samples and .config.rate_samples>=1 and .config.rate_samples<=100 and
    .schedule=={slots_per_epoch:432000,leader_schedule_slot_offset:432000,warmup:true,first_normal_epoch:14,first_normal_slot:524256} and (.epoch|dec) and
    (.reference_votes|type)=="array" and (.reference_votes|length)<=$root.config.reference_count and all(.reference_votes[];pubkey) and (.reference_votes|unique|length)==(.reference_votes|length) and (.reference_votes|index($root.vote_account)|not) and
    (.accounts|type)=="object" and ((.accounts|keys|sort)==([.vote_account]+.reference_votes|sort)) and .accounts[.vote_account].node==.pubkey and
    all(.accounts[];
      exact_keys(["node","total","slot","gcd","samples","increment"]) and
      (((.node==null) and (.total==null) and (.slot==null)) or ((.node|pubkey) and (.total|dec) and (.slot|dec) and .slot==$root.accounts[$root.vote_account].slot)) and
      ((.gcd==null) or (.gcd|pos)) and ((.increment==null) or (.increment|pos)) and
      (.samples|type)=="number" and (.samples|floor)==.samples and .samples>=0 and .samples<=$root.config.rate_samples and
      (if .increment!=null then .gcd!=null and .samples>=1 else true end) and
      (if .node==null then .gcd==null and .samples==0 and .increment==null else true end)
    ) and
    ((.leader_schedule_epoch==null) or (.leader_schedule_epoch|dec)) and (.leader_slots|type)=="object" and
    (.totals|exact_keys(["included","expected","missed","unattributed_slots"])) and (.totals.included|dec) and (.totals.expected|dec) and (.totals.missed|dec) and (.totals.unattributed_slots|dec) and (.last_attributed_slot|dec)
  ' "$path" >/dev/null 2>&1 || return 1
  row="$(jq -r '[.totals.included,.totals.expected,.totals.missed]|@tsv' "$path")" || return 1
  IFS=$'\t' read -r included expected missed <<<"$row"
  sum="$(checked_add "$included" "$missed")" || return 1
  [[ "$sum" == "$expected" ]]
}

derive_epoch() {
  local slot="$1" e first
  if ((10#$slot >= 524256)); then printf '%s' "$((14+(10#$slot-524256)/432000))"; return; fi
  for ((e=1;e<=14;e++)); do first=$((((1<<e)-1)*32)); ((first<=10#$slot)) || { printf '%s' "$((e-1))"; return; }; done
  printf '14'
}

first_slot_of_epoch() {
  local e=$((10#$1))
  if ((e<=14)); then printf '%s' "$((((1<<e)-1)*32))"; else printf '%s' "$(((e-14)*432000+524256))"; fi
}

normalize_raw_numeric_epochs() {
  local rest="$1" output='' token match prefix match_prefix
  while [[ "$rest" =~ \"epoch\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; do
    token="${BASH_REMATCH[1]}"; match="${BASH_REMATCH[0]}"
    prefix="${rest%%"$match"*}"
    match_prefix="${match%"$token"}"
    output+="$prefix$match_prefix"
    if dec_le "$token" "$max_safe_json"; then
      output+="\"$token\""
    else
      output+="\"__unsafe_numeric__:$token\""
    fi
    rest="${rest#*"$match"}"
  done
  printf '%s%s' "$output" "$rest"
}

parse_batch() {
  local raw="$1" votes="$2" normalized
  normalized="$(normalize_raw_numeric_epochs "$raw")" || return 1
  jq -cer --arg genesis "$genesis_expected" --arg owner "$vote_program" --arg identity "$identity" --argjson votes "$votes" '
    def exact_keys($expected):(keys|sort)==($expected|sort);
    def byte:type=="number" and floor==. and .>=0 and .<=255;
    def safe_integer:type=="number" and floor==. and .>=0 and .<=9007199254740991;
    def dec:type=="string" and test("^(0|[1-9][0-9]*)$");
    def dec_lt($a;$b):(($a|length)<($b|length)) or ((($a|length)==($b|length)) and $a<$b);
    def dec_le($a;$b):$a==$b or dec_lt($a;$b);
    def valid_context:type=="object" and has("slot") and ((keys-["apiVersion","slot"])|length)==0 and ((has("apiVersion")|not) or .apiVersion==null or ((.apiVersion|type)=="string" and (.apiVersion|length)>=1 and (.apiVersion|length)<=64));
    def response($id):map(select(.id==$id))|if length==1 and .[0].jsonrpc=="2.0" and (.[0]|exact_keys(["jsonrpc","id","result"])) then .[0] else error("envelope") end;
    def history_entry:
      if type=="object" and exact_keys(["epoch","credits","previousCredits"]) and (.credits|dec) and (.previousCredits|dec) then
        if ((.epoch|type)=="string" and (.epoch|test("^__unsafe_numeric__:[0-9]+$"))) then
          if .credits=="18446744073709551615" and .previousCredits=="18446744073709551615" then {marker:true} else error("unsafe numeric epoch") end
        elif (.epoch|dec) then
          if .epoch=="18446744073709551615" and .credits=="18446744073709551615" and .previousCredits=="18446744073709551615" then {marker:true}
          elif .credits=="18446744073709551615" or .previousCredits=="18446744073709551615" then error("marker")
          elif dec_le(.previousCredits;.credits) then {marker:false,epoch:.epoch,credits:.credits,previous:.previousCredits} else error("credits") end
        else error("epoch") end
      elif type=="array" and length==3 and all(.[];safe_integer) then {marker:false,epoch:(.[0]|tostring),credits:(.[1]|tostring),previous:(.[2]|tostring)}
      else error("history entry") end;
    def parsed_history:
      if type!="array" or length==0 then error("history") else
        reduce .[] as $raw ({last:null,seen:false}; ($raw|history_entry) as $e |
          if $e.marker then {last:null,seen:false} elif .last!=null and (dec_lt(.last.epoch;$e.epoch)|not) then error("history order") else {last:$e,seen:true} end
        ) | if .seen then .last else error("marker only") end
      end;
    def parsed_account($account;$vote):
      if $account==null or $account.owner!=$owner or $account.data.program!="vote" or $account.data.parsed.type!="vote" or (($account.data.parsed.info.nodePubkey|type)!="string") then error("account")
      else ($account.data.parsed.info.epochCredits|parsed_history) as $h | {vote:$vote,valid:true,node:$account.data.parsed.info.nodePubkey,epoch:$h.epoch,total:$h.credits,previous:$h.previous} end;
    if type!="array" or length!=4 or ([.[].id]|unique|length)!=4 then error("ids") else . end |
    response("v3-genesis") as $g | response("v3-ag-genesis-cert") as $c | response("v3-epoch-schedule") as $s | response("v3-accounts") as $a |
    if ($g.result|type)!="string" or $g.result!=$genesis or ($c.result|type)!="object" or ($c.result|exact_keys(["block","signature"])|not) or
       ($c.result.block|type)!="object" or ($c.result.block|exact_keys(["slot","blockId"])|not) or ($c.result.block.slot|safe_integer|not) or $c.result.block.slot==0 or
       ($c.result.block.blockId|type)!="array" or ($c.result.block.blockId|length)!=32 or (all($c.result.block.blockId[];byte)|not) or
       ($c.result.signature|type)!="object" or ($c.result.signature|exact_keys(["bitmap","signature"])|not) or ($c.result.signature.bitmap|type)!="array" or ($c.result.signature.bitmap|length)==0 or (all($c.result.signature.bitmap[];byte)|not) or
       ($c.result.signature.signature|type)!="array" or ($c.result.signature.signature|length)!=192 or (all($c.result.signature.signature[];byte)|not) or
       $s.result!={slotsPerEpoch:432000,leaderScheduleSlotOffset:432000,warmup:true,firstNormalEpoch:14,firstNormalSlot:524256} or
       ($a.result|type)!="object" or ($a.result|exact_keys(["context","value"])|not) or ($a.result.context|valid_context|not) or ($a.result.context.slot|safe_integer|not) or ($a.result.value|type)!="array" or ($a.result.value|length)!=($votes|length)
    then error("isolation") else . end |
    [$a.result.value as $all | range(0;$votes|length) as $i | (try parsed_account($all[$i];$votes[$i]) catch {vote:$votes[$i],valid:false})] as $accounts |
    if ($accounts[0].valid|not) or $accounts[0].node!=$identity then error("monitored") else . end |
    {slot:($a.result.context.slot|tostring),accounts:$accounts}
  ' <<<"$normalized" 2>/dev/null
}

select_cohort() {
  local response="$1" retained="$2"
  jq -ce --arg own "$vote_account" --arg seed "$cohort_seed" --argjson limit "$reference_count" --argjson retained "$retained" '
    def exact_keys($expected):(keys|sort)==($expected|sort);
    def pubkey:type=="string" and length>=32 and length<=44 and test("^[1-9A-HJ-NP-Za-km-z]+$");
    def score($value): reduce ($value|explode[]) as $c (0; ((. * 131 + $c) % 2147483647));
    if type!="object" or .jsonrpc!="2.0" or .id!="v3-vote-accounts" or (exact_keys(["jsonrpc","id","result"])|not) or (.result|type)!="object" or (.result|exact_keys(["current","delinquent"])|not) or
       (.result.current|type)!="array" or (.result.delinquent|type)!="array" or (all(.result.current[];(.votePubkey|pubkey) and (.nodePubkey|pubkey))|not) or (all(.result.delinquent[];(.votePubkey|pubkey) and (.nodePubkey|pubkey))|not)
    then error("invalid") else
      ($retained | map(select(.!=$own)))[:$limit] as $keep |
      (reduce .result.current[].votePubkey as $vote ([];
        if $vote==$own or ($keep|index($vote)) or index($vote) then . else .+[$vote] end
      ) | map({vote:.,score:score(.+":"+$seed)}) | sort_by(.score,.vote) | map(.vote)) as $vacancies |
      $keep + $vacancies[:($limit-($keep|length))]
    end
  ' <<<"$response" 2>/dev/null
}

fetch_leader_schedule() {
  local epoch_first="$1" nodes="$2" payload response
  payload="$(jq -cn --argjson first "$epoch_first" '{jsonrpc:"2.0",id:"v3-leader-schedule",method:"getLeaderSchedule",params:[$first,{commitment:"confirmed"}]}')" || return 1
  response="$(rpc_call "$payload" 2>/dev/null)" || return 1
  jq -ce --argjson first "$epoch_first" --argjson span 432000 --argjson nodes "$nodes" '
    def exact_keys($expected):(keys|sort)==($expected|sort);
    if type!="object" or .jsonrpc!="2.0" or .id!="v3-leader-schedule" or (exact_keys(["jsonrpc","id","result"])|not) or (.result|type)!="object" then error("invalid") else . end |
    .result as $r | reduce $nodes[] as $node ({}; ($r[$node]//[]) as $offsets |
      if ($offsets|type)!="array" or (all($offsets[];type=="number" and floor==. and .>=0 and .<$span)|not) or (($offsets|unique|length)!=($offsets|length)) or (($offsets|sort)!=$offsets)
      then error("offsets") else .+{($node):[$offsets[]|(($first+.)|tostring)]} end)
  ' <<<"$response" 2>/dev/null
}

cache_is_valid() {
  local document="$1" epoch="$2" first="$3" end="$4" nodes="$5"
  jq -e --arg epoch "$epoch" --arg first "$first" --arg end "$end" --argjson nodes "$nodes" '
    def dec: type=="string" and test("^(0|[1-9][0-9]*)$") and ((length<19) or (length==19 and .<="9223372036854775807"));
    def dec_lt($a;$b): (($a|length)<($b|length)) or ((($a|length)==($b|length)) and $a<$b);
    def valid_slots($first;$limit):
      . as $slots |
      type=="array" and
      all($slots[]; dec and (dec_lt(.;$first)|not) and dec_lt(.;$limit)) and
      all(range(1;($slots|length)); . as $i | dec_lt($slots[$i-1];$slots[$i]));
    .leader_schedule_epoch==$epoch and
    (.leader_slots|type)=="object" and
    ((.leader_slots|keys|sort)==($nodes|sort)) and
    (.leader_slots as $slots | all($nodes[]; $slots[.]|valid_slots($first;$end)))
  ' <<<"$document" >/dev/null 2>&1
}

leader_contaminated() {
  local document="$1" node="$2" from="$3" to="$4" slot
  while IFS= read -r slot; do ((10#$slot>10#$from && 10#$slot<=10#$to)) && return 0; done < <(jq -r --arg node "$node" '.leader_slots[$node][]?' <<<"$document")
  return 1
}

state_dir="${state_file%/*}"; [[ "$state_dir" != "$state_file" ]] || state_dir='.'
[[ -d "$state_dir" ]] || mkdir -p -- "$state_dir" 2>/dev/null || { printf 'error: cannot create state directory\n' >&2; exit 1; }
[[ ! -L "$state_dir" && -O "$state_dir" ]] || { printf 'error: state directory must be validator-owned and not a symlink\n' >&2; exit 1; }
lock_file="${state_file}.lock"
if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then (set -o noclobber; : >"$lock_file") 2>/dev/null || true; fi
[[ -f "$lock_file" && ! -L "$lock_file" && -O "$lock_file" ]] || { printf 'error: unsafe state lock\n' >&2; exit 1; }
exec {lock_fd}<>"$lock_file" || { printf 'error: cannot open state lock\n' >&2; exit 1; }
flock -n "$lock_fd" || exit 0

state_exists=0
rotation=0
state_json=''
persisted_references='[]'
if [[ -e "$state_file" ]]; then
  validate_core_state "$state_file" || { printf 'error: invalid existing v3 state\n' >&2; exit 1; }
  state_exists=1
  state_json="$(jq -c . "$state_file")" || exit 1
  persisted_identity="$(jq -r '.pubkey' <<<"$state_json")"
  persisted_vote="$(jq -r '.vote_account' <<<"$state_json")"
  if [[ "$persisted_identity" != "$identity" || "$persisted_vote" != "$vote_account" ]]; then rotation=1; else persisted_references="$(jq -c '.reference_votes' <<<"$state_json")"; fi
fi
requested_votes="$(jq -cn --arg vote "$vote_account" --argjson refs "$persisted_references" '[$vote]+$refs')" || exit 1
batch_payload="$(jq -cn --argjson votes "$requested_votes" '[
 {jsonrpc:"2.0",id:"v3-genesis",method:"getGenesisHash"},
 {jsonrpc:"2.0",id:"v3-ag-genesis-cert",method:"getAgGenesisCert"},
 {jsonrpc:"2.0",id:"v3-epoch-schedule",method:"getEpochSchedule"},
 {jsonrpc:"2.0",id:"v3-accounts",method:"getMultipleAccounts",params:[$votes,{encoding:"jsonParsed",commitment:"finalized"}]}
]')" || { printf 'error: cannot build mandatory RPC batch\n' >&2; exit 1; }
batch_response="$(rpc_call "$batch_payload" 2>/dev/null)" || { printf 'error: mandatory RPC batch failed\n' >&2; exit 1; }
snapshot="$(parse_batch "$batch_response" "$requested_votes")" || { printf 'error: mandatory RPC data or isolation failure\n' >&2; exit 1; }
observed_slot="$(jq -r '.slot' <<<"$snapshot")"
is_u63_decimal "$observed_slot" || { printf 'error: mandatory RPC integer out of range\n' >&2; exit 1; }
epoch="$(derive_epoch "$observed_slot")"
epoch_first="$(first_slot_of_epoch "$epoch")"
epoch_end="$(checked_add "$epoch_first" 432000)" || { printf 'error: epoch arithmetic overflow\n' >&2; exit 1; }

declare -A snap_valid=() snap_node=() snap_total=()
while IFS=$'\t' read -r svote valid node sepoch total previous; do
  snap_valid["$svote"]="$valid"
  if [[ "$valid" == true ]]; then
    if ! is_solana_pubkey "$node" || ! is_u63_decimal "$sepoch" || ! is_u63_decimal "$total" || ! is_u63_decimal "$previous" || ! dec_le "$previous" "$total" || ! dec_le "$sepoch" "$epoch"; then
      [[ "$svote" == "$vote_account" ]] && { printf 'error: mandatory RPC integer out of range or inconsistent\n' >&2; exit 1; }
      snap_valid["$svote"]=false; continue
    fi
    snap_node["$svote"]="$node"; snap_total["$svote"]="$total"
  fi
done < <(jq -r '.accounts[]|[.vote,(.valid|tostring),(.node//""),(.epoch//""),(.total//""),(.previous//"")]|@tsv' <<<"$snapshot")
[[ "${snap_valid[$vote_account]:-false}" == true && "${snap_node[$vote_account]}" == "$identity" ]] || { printf 'error: invalid monitored account\n' >&2; exit 1; }

cold=0
if ((state_exists==0 || rotation==1)); then
  cold=1
  state_json="$(jq -cn --arg genesis "$genesis_expected" --arg identity "$identity" --arg vote "$vote_account" --arg epoch "$epoch" --arg total "${snap_total[$vote_account]}" --arg slot "$observed_slot" --argjson rc "$reference_count" --argjson rs "$rate_samples" '
    {version:3,genesis:$genesis,consensus:"alpenglow",pubkey:$identity,vote_account:$vote,config:{reference_count:$rc,rate_samples:$rs},
     schedule:{slots_per_epoch:432000,leader_schedule_slot_offset:432000,warmup:true,first_normal_epoch:14,first_normal_slot:524256},epoch:$epoch,reference_votes:[],
     accounts:{($vote):{node:$identity,total:$total,slot:$slot,gcd:null,samples:0,increment:null}},leader_schedule_epoch:null,leader_slots:{},
     totals:{included:"0",expected:"0",missed:"0",unattributed_slots:"0"},last_attributed_slot:"0"}')" || exit 1
fi

if ((cold==0)); then
  persisted_monitored_total="$(jq -r --arg vote "$vote_account" '.accounts[$vote].total' <<<"$state_json")"
  persisted_monitored_slot="$(jq -r --arg vote "$vote_account" '.accounts[$vote].slot' <<<"$state_json")"
  dec_le "$persisted_monitored_total" "${snap_total[$vote_account]}" || { printf 'error: monitored total decreased\n' >&2; exit 1; }
  ((10#$observed_slot >= 10#$persisted_monitored_slot)) || { printf 'error: finalized slot regressed\n' >&2; exit 1; }
fi

old_rate="$(jq -r '.config.rate_samples' <<<"$state_json")"
rate_changed=0; [[ "$old_rate" != "$rate_samples" ]] && rate_changed=1
state_json="$(jq -c --argjson rc "$reference_count" --argjson rs "$rate_samples" '.config.reference_count=$rc|.config.rate_samples=$rs' <<<"$state_json")" || exit 1
if ((rate_changed)); then state_json="$(jq -c '.accounts|=with_entries(.value.gcd=null|.value.samples=0|.value.increment=null)' <<<"$state_json")" || exit 1; fi
state_json="$(jq -c --arg vote "$vote_account" --argjson limit "$reference_count" '.reference_votes=.reference_votes[:$limit]|([$vote]+.reference_votes) as $keep|.accounts|=with_entries(select(.key as $k|$keep|index($k)))' <<<"$state_json")" || exit 1

while IFS= read -r ref; do
  if [[ "${snap_valid[$ref]:-false}" != true ]]; then state_json="$(jq -c --arg ref "$ref" '.reference_votes|=map(select(.!=$ref))|del(.accounts[$ref])' <<<"$state_json")" || exit 1; fi
done < <(jq -r '.reference_votes[]' <<<"$state_json")

current_refs="$(jq -c '.reference_votes' <<<"$state_json")"
schedule_nodes="$(jq -cn --arg vote "$vote_account" --argjson refs "$current_refs" --argjson snapshots "$(jq -c '.accounts' <<<"$snapshot")" '
  ([$vote]+$refs) as $votes|reduce $votes[] as $v ([];([$snapshots[]|select(.vote==$v and .valid)|.node][0]) as $n|if $n==null or index($n) then . else .+[$n] end)
')" || exit 1
if ! cache_is_valid "$state_json" "$epoch" "$epoch_first" "$epoch_end" "$schedule_nodes"; then state_json="$(jq -c '.leader_schedule_epoch=null|.leader_slots={}' <<<"$state_json")" || exit 1; fi

optional_kind='none'
if [[ "$(jq -r '.reference_votes|length' <<<"$state_json")" -eq 0 ]]; then optional_kind='cohort'
elif [[ "$(jq -r '.leader_schedule_epoch==null' <<<"$state_json")" == true ]]; then optional_kind='schedule'
elif [[ "$(jq -r '.reference_votes|length' <<<"$state_json")" -lt "$reference_count" ]]; then optional_kind='cohort'; fi
cohort_result=''
if [[ "$optional_kind" == cohort ]]; then
  optional_payload="$(jq -cn '{jsonrpc:"2.0",id:"v3-vote-accounts",method:"getVoteAccounts",params:[{commitment:"finalized"}]}')"
  if optional_response="$(rpc_call "$optional_payload" 2>/dev/null)"; then
    if ! cohort_result="$(select_cohort "$optional_response" "$(jq -c '.reference_votes' <<<"$state_json")")"; then
      cohort_result=''
      printf 'warning: optional cohort response invalid\n' >&2
    fi
  else
    printf 'warning: optional cohort RPC failed\n' >&2
  fi
elif [[ "$optional_kind" == schedule ]]; then
  if leader_slots="$(fetch_leader_schedule "$epoch_first" "$schedule_nodes")"; then
    state_json="$(printf '%s\n%s\n' "$state_json" "$leader_slots" | jq -sc --arg epoch "$epoch" '.[0] as $state | .[1] as $slots | $state | .leader_schedule_epoch=$epoch | .leader_slots=$slots')" || exit 1
  else printf 'warning: optional leader schedule RPC failed\n' >&2; fi
fi

persisted_epoch="$(jq -r '.epoch' <<<"$state_json")"
from_slot="$(jq -r --arg vote "$vote_account" '.accounts[$vote].slot' <<<"$state_json")"
if ((cold)); then
  ready=0; usable=0
elif ((10#$observed_slot<10#$from_slot)); then
  printf 'error: finalized slot regressed\n' >&2; exit 1
elif [[ "$observed_slot" == "$from_slot" ]]; then
  ready=0; usable=0
else
  gap="$(checked_sub "$observed_slot" "$from_slot")" || exit 1
  if [[ "$persisted_epoch" != "$epoch" ]]; then
    new_unattributed="$(checked_add "$(jq -r '.totals.unattributed_slots' <<<"$state_json")" "$gap")" || { printf 'error: cumulative overflow\n' >&2; exit 1; }
    state_json="$(jq -c --arg epoch "$epoch" --arg slot "$observed_slot" --arg unattributed "$new_unattributed" --argjson snapshots "$(jq -c '.accounts' <<<"$snapshot")" '
      .epoch=$epoch|.totals.unattributed_slots=$unattributed|
      reduce $snapshots[] as $s (.;if $s.valid and .accounts[$s.vote]!=null then .accounts[$s.vote]={node:$s.node,total:$s.total,slot:$slot,gcd:null,samples:0,increment:null} else . end)
    ' <<<"$state_json")" || exit 1
    ready=0; usable=0
  elif ((rate_changed)); then
    new_unattributed="$(checked_add "$(jq -r '.totals.unattributed_slots' <<<"$state_json")" "$gap")" || { printf 'error: cumulative overflow\n' >&2; exit 1; }
    state_json="$(jq -c --arg slot "$observed_slot" --arg unattributed "$new_unattributed" --argjson snapshots "$(jq -c '.accounts' <<<"$snapshot")" '
      .totals.unattributed_slots=$unattributed|reduce $snapshots[] as $s (.;if $s.valid and .accounts[$s.vote]!=null then .accounts[$s.vote]={node:$s.node,total:$s.total,slot:$slot,gcd:null,samples:0,increment:null} else . end)
    ' <<<"$state_json")" || exit 1
    ready=0; usable=0
  else
    first_included="$(checked_add "$from_slot" 1)" || exit 1
    safe_start="$(checked_add "$epoch_first" 8)" || exit 1
    epoch_safe=1; ((10#$first_included>=10#$safe_start)) || epoch_safe=0
    declare -A known_count=()
    monitored_known=0; usable=0
    tracked_votes="$(jq -c --arg vote "$vote_account" '[$vote]+.reference_votes' <<<"$state_json")"
    while IFS= read -r tracked; do
      [[ "${snap_valid[$tracked]:-false}" == true ]] || continue
      row="$(jq -r --arg vote "$tracked" '.accounts[$vote]|[.node//"",.total//"",.gcd//"",(.samples|tostring),.increment//""]|join("|")' <<<"$state_json")"
      IFS='|' read -r old_node old_total old_gcd old_samples old_increment <<<"$row"
      current_node="${snap_node[$tracked]}"; current_total="${snap_total[$tracked]}"
      if [[ -z "$old_total" ]]; then
        state_json="$(jq -c --arg vote "$tracked" --arg node "$current_node" --arg total "$current_total" --arg slot "$observed_slot" '.accounts[$vote]={node:$node,total:$total,slot:$slot,gcd:null,samples:0,increment:null}' <<<"$state_json")" || exit 1
        continue
      fi
      if [[ "$tracked" == "$vote_account" ]] && ! dec_le "$old_total" "$current_total"; then printf 'error: monitored total decreased\n' >&2; exit 1; fi
      if ! dec_le "$old_total" "$current_total" || [[ "$old_node" != "$current_node" ]]; then
        state_json="$(jq -c --arg vote "$tracked" --arg node "$current_node" --arg total "$current_total" --arg slot "$observed_slot" '.accounts[$vote]={node:$node,total:$total,slot:$slot,gcd:null,samples:0,increment:null}' <<<"$state_json")" || exit 1
        continue
      fi
      delta="$(checked_sub "$current_total" "$old_total")" || exit 1
      new_gcd="$old_gcd"; new_samples="$old_samples"; new_increment="$old_increment"; count=''; clean=1
      ((epoch_safe)) || clean=0
      [[ "$(jq -r --arg node "$current_node" '.leader_slots|has($node)' <<<"$state_json")" == true ]] || clean=0
      leader_contaminated "$state_json" "$current_node" "$from_slot" "$observed_slot" && clean=0
      if ((clean)); then
        if [[ "$delta" == 0 ]]; then count=0
        elif [[ -z "$old_increment" ]]; then
          if [[ -z "$old_gcd" ]]; then new_gcd="$delta"; else new_gcd="$(gcd_decimal "$old_gcd" "$delta")"; fi
          new_samples=$((old_samples+1)); ((new_samples>rate_samples)) && new_samples=$rate_samples
          if [[ "$gap" == 1 || "$new_samples" -ge "$rate_samples" ]]; then new_increment="$new_gcd"; fi
          if [[ -n "$new_increment" && $((10#$delta%10#$new_increment)) -eq 0 ]]; then count=$((10#$delta/10#$new_increment)); ((count<=10#$gap)) || count=''; fi
        elif ((10#$delta%10#$old_increment==0)); then
          count=$((10#$delta/10#$old_increment)); ((count<=10#$gap)) || count=''
          new_gcd="$(gcd_decimal "$old_gcd" "$delta")"; new_samples=$((old_samples+1)); ((new_samples>rate_samples)) && new_samples=$rate_samples
        elif [[ "$gap" == 1 ]]; then new_gcd="$delta"; new_samples=1; new_increment="$delta"; count=1
        else new_gcd="$delta"; new_samples=1; new_increment=''; count=''; fi
      fi
      state_json="$(jq -c --arg vote "$tracked" --arg node "$current_node" --arg total "$current_total" --arg slot "$observed_slot" --arg gcd "$new_gcd" --argjson samples "$new_samples" --arg increment "$new_increment" '
        .accounts[$vote]={node:$node,total:$total,slot:$slot,gcd:(if $gcd=="" then null else $gcd end),samples:$samples,increment:(if $increment=="" then null else $increment end)}
      ' <<<"$state_json")" || exit 1
      if [[ -n "$count" ]]; then known_count["$tracked"]="$count"; if [[ "$tracked" == "$vote_account" ]]; then monitored_known=1; else usable=$((usable+1)); fi; fi
    done < <(jq -r '.[]' <<<"$tracked_votes")
    if ((monitored_known && usable>0)); then
      included_gap="${known_count[$vote_account]}"; expected_gap="$included_gap"
      while IFS= read -r ref; do [[ -n "${known_count[$ref]:-}" && ${known_count[$ref]} -gt $expected_gap ]] && expected_gap="${known_count[$ref]}"; done < <(jq -r '.reference_votes[]' <<<"$state_json")
      missed_gap=$((expected_gap-included_gap))
      total_included="$(checked_add "$(jq -r '.totals.included' <<<"$state_json")" "$included_gap")" || exit 1
      total_expected="$(checked_add "$(jq -r '.totals.expected' <<<"$state_json")" "$expected_gap")" || exit 1
      total_missed="$(checked_add "$(jq -r '.totals.missed' <<<"$state_json")" "$missed_gap")" || exit 1
      state_json="$(jq -c --arg i "$total_included" --arg e "$total_expected" --arg m "$total_missed" --arg last "$observed_slot" '.totals.included=$i|.totals.expected=$e|.totals.missed=$m|.last_attributed_slot=$last' <<<"$state_json")" || exit 1
      ready=1
    else
      new_unattributed="$(checked_add "$(jq -r '.totals.unattributed_slots' <<<"$state_json")" "$gap")" || exit 1
      state_json="$(jq -c --arg u "$new_unattributed" '.totals.unattributed_slots=$u' <<<"$state_json")" || exit 1
      ready=0
    fi
  fi
fi

if [[ -n "$cohort_result" ]]; then
  state_json="$(jq -c --arg vote "$vote_account" --argjson refs "$cohort_result" '
    .reference_votes=$refs|reduce $refs[] as $r (.;if .accounts[$r]==null then .accounts[$r]={node:null,total:null,slot:null,gcd:null,samples:0,increment:null} else . end)|
    ([$vote]+$refs) as $keep|.accounts|=with_entries(select(.key as $k|$keep|index($k)))
  ' <<<"$state_json")" || exit 1
fi

total_included="$(jq -r '.totals.included' <<<"$state_json")"
total_expected="$(jq -r '.totals.expected' <<<"$state_json")"
total_missed="$(jq -r '.totals.missed' <<<"$state_json")"
total_unattributed="$(jq -r '.totals.unattributed_slots' <<<"$state_json")"
last_attributed_slot="$(jq -r '.last_attributed_slot' <<<"$state_json")"
write_state_atomic "$state_json" || { printf 'error: atomic state write failed\n' >&2; exit 1; }
emit_measurement "$observed_slot" "$ready" "$usable"
