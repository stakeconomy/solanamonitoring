#!/usr/bin/env bash
# Solana Validator Monitoring Script v0.15
# Emits one Influx line-protocol record for Telegraf.

set -u
set -o pipefail

config_dir="${SOLANA_CONFIG_DIR:-$HOME/.config/solana}"
solana_cli="${SOLANA_CLI:-}"
curl_bin="${CURL_BIN:-curl}"
identity_pubkey="${SOLANA_IDENTITY_PUBKEY:-}"
vote_account="${SOLANA_VOTE_ACCOUNT:-}"
rpc_url="${SOLANA_RPC_URL:-}"
rpc_timeout="${MONITOR_RPC_TIMEOUT:-20}"
price_timeout="${MONITOR_PRICE_TIMEOUT:-3}"
slot_milliseconds="${MONITOR_SLOT_MILLISECONDS:-}"
performance_rpc_url="${SOLANA_PERFORMANCE_RPC_URL:-}"
price_url="${SOLANA_PRICE_URL:-https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd}"
now="$(date +%s%N)"

usage() {
  cat <<'EOF'
Usage: monitor.sh [options]

Options:
  --identity PUBKEY       Validator identity (otherwise discovered with solana address)
  --vote-account PUBKEY   Vote account (otherwise discovered from getVoteAccounts)
  --rpc-url URL           Validator RPC URL (otherwise discovered from the validator process)
  --solana-cli PATH       Path to the solana CLI (identity and epoch-ETA fallback)
  --rpc-timeout SECONDS   RPC request timeout (default: 20)
  --price-timeout SECONDS Price request timeout (default: 3)
  --performance-rpc-url URL
                          RPC used when local performance samples are empty
  --slot-ms MILLISECONDS  Fallback slot duration when RPC samples are unavailable
  -h, --help              Show this help

The same values can be provided with SOLANA_IDENTITY_PUBKEY,
SOLANA_VOTE_ACCOUNT, SOLANA_RPC_URL, SOLANA_CLI, MONITOR_RPC_TIMEOUT,
MONITOR_PRICE_TIMEOUT, SOLANA_PERFORMANCE_RPC_URL, and
MONITOR_SLOT_MILLISECONDS.
EOF
}

require_option_value() {
  if (($# < 2)) || [[ -z "${2:-}" ]]; then
    printf 'monitor: %s requires a value\n' "$1" >&2
    exit 64
  fi
}

while (($#)); do
  case "$1" in
    --identity)
      require_option_value "$@"
      identity_pubkey="${2:-}"
      shift 2
      ;;
    --vote-account)
      require_option_value "$@"
      vote_account="${2:-}"
      shift 2
      ;;
    --rpc-url)
      require_option_value "$@"
      rpc_url="${2:-}"
      shift 2
      ;;
    --solana-cli)
      require_option_value "$@"
      solana_cli="${2:-}"
      shift 2
      ;;
    --rpc-timeout)
      require_option_value "$@"
      rpc_timeout="${2:-}"
      shift 2
      ;;
    --price-timeout)
      require_option_value "$@"
      price_timeout="${2:-}"
      shift 2
      ;;
    --performance-rpc-url)
      require_option_value "$@"
      performance_rpc_url="${2:-}"
      shift 2
      ;;
    --slot-ms)
      require_option_value "$@"
      slot_milliseconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'monitor: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "$rpc_timeout" =~ ^[0-9]+([.][0-9]+)?$ || ! "$price_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'monitor: timeout values must be non-negative numbers\n' >&2
  exit 64
fi
if [[ -n "$slot_milliseconds" && ! "$slot_milliseconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'monitor: slot duration must be a positive integer in milliseconds\n' >&2
  exit 64
fi

for command_name in "$curl_bin" jq awk sed pgrep date; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'monitor: required command not found: %s\n' "$command_name" >&2
    exit 69
  fi
done

emit_status() {
  local status="$1"
  printf 'nodemonitor,pubkey=%s status=%si %s\n' "${identity_pubkey:-unknown}" "$status" "$now"
}

discover_rpc_url() {
  local process_line rpc_port
  process_line="$(pgrep -a -f '(agave-validator|solana-validator|fdctl)' 2>/dev/null | sed -n '1p')"
  rpc_port="$(sed -nE 's/.*--rpc-port(=|[[:space:]]+)([0-9]+).*/\2/p' <<<"$process_line")"
  if [[ -n "$rpc_port" ]]; then
    printf 'http://127.0.0.1:%s' "$rpc_port"
  fi
}

discover_solana_cli() {
  local install_config active_release
  if [[ -n "$solana_cli" ]]; then
    return
  fi
  if command -v solana >/dev/null 2>&1; then
    solana_cli="$(command -v solana)"
    return
  fi
  install_config="$config_dir/install/config.yml"
  if [[ -r "$install_config" ]]; then
    active_release="$(awk '$1 == "active_release_dir:" {print $2; exit}' "$install_config")"
    if [[ -x "$active_release/bin/solana" ]]; then
      solana_cli="$active_release/bin/solana"
    fi
  fi
}

configured_cli_rpc_url() {
  local config_output configured_url

  discover_solana_cli
  if [[ -z "$solana_cli" || ! -x "$solana_cli" ]]; then
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    config_output="$(timeout "$rpc_timeout" "$solana_cli" config get 2>/dev/null)" || return 1
  else
    config_output="$("$solana_cli" config get 2>/dev/null)" || return 1
  fi
  configured_url="$(awk -F': ' '/^RPC URL:/ {print substr($0, index($0, $2)); exit}' <<<"$config_output")"
  if [[ ! "$configured_url" =~ ^https?:// ]]; then
    return 1
  fi
  printf '%s' "$configured_url"
}

rpc_call() {
  local payload="$1" endpoint="${2:-$rpc_url}"
  "$curl_bin" --silent --show-error --fail \
    --max-time "$rpc_timeout" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$endpoint"
}

pct() {
  awk -v numerator="$1" -v denominator="$2" \
    'BEGIN { if (denominator == 0) print "0.00"; else printf "%.2f", 100 * numerator / denominator }'
}

sol_amount() {
  awk -v lamports="$1" 'BEGIN { printf "%.9f", lamports / 1000000000 }'
}

load_performance_samples() {
  local endpoint="$1" response summary remote_genesis fallback_slots fallback_seconds
  local payload

  payload='[
    {"jsonrpc":"2.0","id":"performanceGenesis","method":"getGenesisHash"},
    {"jsonrpc":"2.0","id":"performanceFallback","method":"getRecentPerformanceSamples","params":[5]}
  ]'
  response="$(rpc_call "$payload" "$endpoint" 2>/dev/null)" || return 1
  summary="$(jq -er '
    if type != "array" then error("invalid batch response") else
      ([.[] | select(.id == "performanceGenesis")][0].result // "") as $genesis |
      ([.[] | select(.id == "performanceFallback")][0].result // null) as $samples |
      if ($samples | type) != "array" then error("invalid performance result") else
        {
          genesis: $genesis,
          slots: ([$samples[].numSlots] | add // 0),
          seconds: ([$samples[].samplePeriodSecs] | add // 0)
        }
      end
    end
  ' <<<"$response" 2>/dev/null)" || return 1

  remote_genesis="$(jq -r '.genesis' <<<"$summary")"
  fallback_slots="$(jq -r '.slots' <<<"$summary")"
  fallback_seconds="$(jq -r '.seconds' <<<"$summary")"
  if [[ -z "$genesis_hash" || "$remote_genesis" != "$genesis_hash" ]] || \
     ((fallback_slots <= 0 || fallback_seconds <= 0)); then
    return 1
  fi

  sample_slots="$fallback_slots"
  sample_seconds="$fallback_seconds"
}

epoch_end_from_cli() {
  local epoch_info remaining total_seconds current_seconds

  discover_solana_cli
  if [[ -z "$solana_cli" || ! -x "$solana_cli" ]]; then
    return 1
  fi

  # The CLI derives an estimated duration from cluster progress and prints it
  # in parentheses, for example: "(19h 27m 3s remaining)". This is more
  # representative than a nominal slot duration when the RPC node exposes no
  # recent performance samples.
  if command -v timeout >/dev/null 2>&1; then
    epoch_info="$(timeout "$rpc_timeout" "$solana_cli" epoch-info --url "$rpc_url" 2>/dev/null)" || return 1
  else
    epoch_info="$("$solana_cli" epoch-info --url "$rpc_url" 2>/dev/null)" || return 1
  fi

  remaining="$(awk -F'[()]' '/Epoch Completed Time:/ {print $2; exit}' <<<"$epoch_info")"
  total_seconds="$(awk '
    {
      total = 0
      found = 0
      for (i = 1; i <= NF; i++) {
        value = $i
        if (value ~ /^[0-9]+days?$/) {
          sub(/days?$/, "", value); total += value * 86400; found = 1
        } else if (value ~ /^[0-9]+h$/) {
          sub(/h$/, "", value); total += value * 3600; found = 1
        } else if (value ~ /^[0-9]+m$/) {
          sub(/m$/, "", value); total += value * 60; found = 1
        } else if (value ~ /^[0-9]+s$/) {
          sub(/s$/, "", value); total += value; found = 1
        }
      }
      if (found) print total
    }
  ' <<<"$remaining")"
  if [[ ! "$total_seconds" =~ ^[0-9]+$ || "$total_seconds" -le 0 ]]; then
    return 1
  fi

  current_seconds="$(date +%s)"
  printf '%s' "$(( (current_seconds + total_seconds) * 1000 ))"
}

if [[ -z "$rpc_url" ]]; then
  rpc_url="$(discover_rpc_url)"
fi
if [[ -z "$rpc_url" ]]; then
  printf 'monitor: unable to discover validator RPC URL; set SOLANA_RPC_URL or --rpc-url\n' >&2
  emit_status 4
  exit 1
fi

if [[ -z "$identity_pubkey" ]]; then
  discover_solana_cli
  if [[ -z "$solana_cli" || ! -x "$solana_cli" ]]; then
    printf 'monitor: identity is unset and the solana CLI could not be found\n' >&2
    emit_status 4
    exit 1
  fi
  identity_pubkey="$($solana_cli address --url "$rpc_url" 2>/dev/null || true)"
fi
if [[ -z "$identity_pubkey" ]]; then
  printf 'monitor: unable to discover validator identity\n' >&2
  emit_status 4
  exit 1
fi

# Do not request unstaked delinquent vote accounts here. They add no stake to
# cluster delinquency calculations and can expand this response by megabytes.
vote_payload='{"jsonrpc":"2.0","id":"voteAccounts","method":"getVoteAccounts","params":[{"commitment":"confirmed"}]}'
if ! vote_response="$(rpc_call "$vote_payload" 2>/dev/null)" || ! jq -e '.result.current and .result.delinquent' >/dev/null 2>&1 <<<"$vote_response"; then
  printf 'monitor: getVoteAccounts RPC request failed\n' >&2
  emit_status 2
  exit 1
fi

if [[ -z "$vote_account" ]]; then
  mapfile -t matching_vote_accounts < <(
    jq -r --arg identity "$identity_pubkey" \
      '[.result.current[], .result.delinquent[]] | .[] | select(.nodePubkey == $identity) | .votePubkey' \
      <<<"$vote_response"
  )
  if ((${#matching_vote_accounts[@]} != 1)); then
    printf 'monitor: found %s vote accounts for identity %s; set SOLANA_VOTE_ACCOUNT or --vote-account\n' \
      "${#matching_vote_accounts[@]}" "$identity_pubkey" >&2
    emit_status 2
    exit 1
  fi
  vote_account="${matching_vote_accounts[0]}"
fi

if ! vote_summary="$(jq -er --arg vote "$vote_account" '
  ([.result.current[] | select(.votePubkey == $vote) | . + {monitorStatus: 0}] +
   [.result.delinquent[] | select(.votePubkey == $vote) | . + {monitorStatus: 3}]) as $selected |
  if ($selected | length) != 1 then error("vote account not found or ambiguous") else
    $selected[0] as $v |
    {
      status: $v.monitorStatus,
      rootSlot: ($v.rootSlot // 0),
      lastVote: ($v.lastVote // 0),
      credits: ($v.epochCredits[-1][1] // 0),
      previousCredits: ($v.epochCredits[-1][2] // 0),
      activatedStake: ($v.activatedStake // 0),
      commission: ($v.commission // 0),
      totalStake: (([.result.current[].activatedStake, .result.delinquent[].activatedStake] | add) // 0),
      delinquentStake: (([.result.delinquent[].activatedStake] | add) // 0)
    }
  end
' <<<"$vote_response" 2>/dev/null)"; then
  printf 'monitor: vote account %s was not found uniquely in getVoteAccounts\n' "$vote_account" >&2
  emit_status 2
  exit 1
fi

batch_payload="$(jq -cn --arg identity "$identity_pubkey" --arg vote "$vote_account" '[
  {jsonrpc:"2.0",id:"blockProduction",method:"getBlockProduction",params:[{commitment:"confirmed"}]},
  {jsonrpc:"2.0",id:"clusterNodes",method:"getClusterNodes"},
  {jsonrpc:"2.0",id:"epochInfo",method:"getEpochInfo",params:[{commitment:"confirmed"}]},
  {jsonrpc:"2.0",id:"performance",method:"getRecentPerformanceSamples",params:[5]},
  {jsonrpc:"2.0",id:"identityBalance",method:"getBalance",params:[$identity,{commitment:"confirmed"}]},
  {jsonrpc:"2.0",id:"voteBalance",method:"getBalance",params:[$vote,{commitment:"confirmed"}]},
  {jsonrpc:"2.0",id:"genesisHash",method:"getGenesisHash"}
]')"

batch_response='[]'
if ! batch_candidate="$(rpc_call "$batch_payload" 2>/dev/null)" || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$batch_candidate"; then
  printf 'monitor: supplemental JSON-RPC batch failed; emitting validator status with zeroed supplemental fields\n' >&2
else
  batch_response="$batch_candidate"
fi

batch_summary="$(jq -c --arg identity "$identity_pubkey" '
  def response($id): ([.[] | select(.id == $id)][0] // {});
  (response("blockProduction").result.value // {}) as $bp |
  (response("clusterNodes").result // []) as $nodes |
  (response("epochInfo").result // {}) as $epoch |
  (response("performance").result // []) as $performance |
  ($bp.byIdentity[$identity] // [0, 0]) as $validatorProduction |
  ([($bp.byIdentity // {})[] | .[0]] | add // 0) as $clusterLeaderSlots |
  ([($bp.byIdentity // {})[] | .[1]] | add // 0) as $clusterProducedBlocks |
  {
    leaderSlots: ($validatorProduction[0] // 0),
    producedBlocks: ($validatorProduction[1] // 0),
    clusterLeaderSlots: $clusterLeaderSlots,
    clusterProducedBlocks: $clusterProducedBlocks,
    nodes: ($nodes | length),
    version: (($nodes[] | select(.pubkey == $identity) | .version) // ""),
    epoch: ($epoch.epoch // 0),
    slotIndex: ($epoch.slotIndex // 0),
    slotsInEpoch: ($epoch.slotsInEpoch // 0),
    transactionCount: ($epoch.transactionCount // 0),
    sampleSlots: ([$performance[].numSlots] | add // 0),
    sampleSeconds: ([$performance[].samplePeriodSecs] | add // 0),
    identityBalance: (response("identityBalance").result.value // 0),
    voteBalance: (response("voteBalance").result.value // 0),
    genesisHash: (response("genesisHash").result // "")
  }
' <<<"$batch_response")"

status="$(jq -r '.status' <<<"$vote_summary")"
root_slot="$(jq -r '.rootSlot' <<<"$vote_summary")"
last_vote="$(jq -r '.lastVote' <<<"$vote_summary")"
credits="$(jq -r '.credits' <<<"$vote_summary")"
previous_credits="$(jq -r '.previousCredits' <<<"$vote_summary")"
activated_stake_lamports="$(jq -r '.activatedStake' <<<"$vote_summary")"
commission="$(jq -r '.commission' <<<"$vote_summary")"
total_stake="$(jq -r '.totalStake' <<<"$vote_summary")"
delinquent_stake="$(jq -r '.delinquentStake' <<<"$vote_summary")"

leader_slots="$(jq -r '.leaderSlots' <<<"$batch_summary")"
produced_blocks="$(jq -r '.producedBlocks' <<<"$batch_summary")"
skipped_slots=$((leader_slots - produced_blocks))
if ((skipped_slots < 0)); then skipped_slots=0; fi
cluster_leader_slots="$(jq -r '.clusterLeaderSlots' <<<"$batch_summary")"
cluster_produced_blocks="$(jq -r '.clusterProducedBlocks' <<<"$batch_summary")"
cluster_skipped_slots=$((cluster_leader_slots - cluster_produced_blocks))
if ((cluster_skipped_slots < 0)); then cluster_skipped_slots=0; fi

pct_skipped="$(pct "$skipped_slots" "$leader_slots")"
pct_total_skipped="$(pct "$cluster_skipped_slots" "$cluster_leader_slots")"
pct_skipped_delta="$(awk -v own="$pct_skipped" -v cluster="$pct_total_skipped" \
  'BEGIN { if (cluster == 0) print "0.00"; else printf "%.2f", 100 * (own - cluster) / cluster }')"
pct_total_delinquent="$(pct "$delinquent_stake" "$total_stake")"

version="$(jq -r '.version' <<<"$batch_summary")"
version_number="$(awk -F. '/^[0-9]+\.[0-9]+\.[0-9]+/ {printf "%d%d%d", $1, $2, $3}' <<<"$version")"
version_number="${version_number:-0}"
nodes="$(jq -r '.nodes' <<<"$batch_summary")"
epoch="$(jq -r '.epoch' <<<"$batch_summary")"
slot_index="$(jq -r '.slotIndex' <<<"$batch_summary")"
slots_in_epoch="$(jq -r '.slotsInEpoch' <<<"$batch_summary")"
transaction_count="$(jq -r '.transactionCount' <<<"$batch_summary")"
sample_slots="$(jq -r '.sampleSlots' <<<"$batch_summary")"
sample_seconds="$(jq -r '.sampleSeconds' <<<"$batch_summary")"
identity_balance_lamports="$(jq -r '.identityBalance' <<<"$batch_summary")"
vote_balance_lamports="$(jq -r '.voteBalance' <<<"$batch_summary")"
genesis_hash="$(jq -r '.genesisHash' <<<"$batch_summary")"

# Some validator builds expose getRecentPerformanceSamples but don't populate
# their local PerfSamples column. Prefer the Solana user's configured CLI RPC
# for this small request, and verify it belongs to the same cluster. An
# explicit URL takes precedence; the official cluster RPC is the last network
# fallback when no explicit URL is supplied.
if ((sample_slots <= 0 || sample_seconds <= 0)); then
  if [[ -n "$performance_rpc_url" ]]; then
    load_performance_samples "$performance_rpc_url" || true
  else
    configured_performance_rpc="$(configured_cli_rpc_url || true)"
    if [[ -n "$configured_performance_rpc" ]]; then
      load_performance_samples "$configured_performance_rpc" || true
    fi

    official_performance_rpc=""
    case "$genesis_hash" in
      5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp)
        official_performance_rpc='https://api.mainnet-beta.solana.com'
        ;;
      4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY)
        official_performance_rpc='https://api.testnet.solana.com'
        ;;
      EtWTRABZaYq6iMfeYKouRu166VU2xqa1)
        official_performance_rpc='https://api.devnet.solana.com'
        ;;
    esac
    if ((sample_slots <= 0 || sample_seconds <= 0)) && \
       [[ -n "$official_performance_rpc" && \
          "${official_performance_rpc%/}" != "${configured_performance_rpc%/}" ]]; then
      load_performance_samples "$official_performance_rpc" || true
    fi
  fi
fi

current_credits=$((credits - previous_credits))
if ((current_credits < 0)); then current_credits=0; fi
pct_epoch_elapsed="$(pct "$slot_index" "$slots_in_epoch")"
# Kept compatible with the current dashboard, which divides pctVote by 16.
pct_vote="$(pct "$current_credits" "$slot_index")"

epoch_ends=0
if ((slots_in_epoch > slot_index)); then
  remaining_slots=$((slots_in_epoch - slot_index))
  if ((sample_slots > 0 && sample_seconds > 0)); then
    epoch_ends="$(awk -v now_seconds="$(date +%s)" -v remaining="$remaining_slots" \
      -v seconds="$sample_seconds" -v slots="$sample_slots" \
      'BEGIN { printf "%.0f", 1000 * (now_seconds + remaining * seconds / slots) }')"
  else
    if [[ -z "$slot_milliseconds" ]]; then
      case "$genesis_hash" in
        4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY)
          # The 4.3 testnet currently targets 200 ms, while `solana
          # epoch-info` falls back to 400 ms when PerfSamples is empty.
          slot_milliseconds=200
          ;;
        *)
          if epoch_ends="$(epoch_end_from_cli)"; then
            slot_milliseconds=""
          else
            slot_milliseconds=400
          fi
          ;;
      esac
    fi
    if [[ -n "$slot_milliseconds" ]]; then
      # Final fallback for installations without usable samples or a CLI.
      epoch_ends="$(awk -v now_seconds="$(date +%s)" -v remaining="$remaining_slots" \
        -v slot_ms="$slot_milliseconds" \
        'BEGIN { printf "%.0f", 1000 * now_seconds + remaining * slot_ms }')"
    fi
  fi
fi

solana_price=""
for _price_attempt in 1 2; do
  price_candidate="$($curl_bin --silent --show-error --fail --max-time "$price_timeout" \
    --header 'accept: application/json' "$price_url" 2>/dev/null | jq -r '.solana.usd // empty' 2>/dev/null || true)"
  if [[ "$price_candidate" =~ ^[0-9]+([.][0-9]+)?$ ]] && \
     awk -v price="$price_candidate" 'BEGIN { exit !(price > 0) }'; then
    solana_price="$price_candidate"
    break
  fi
done
price_field=""
if [[ -n "$solana_price" ]]; then
  price_field=",solanaPrice=$solana_price"
fi
open_files="$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || printf '0')"
open_files="${open_files:-0}"

activated_stake="$(sol_amount "$activated_stake_lamports")"
identity_balance="$(sol_amount "$identity_balance_lamports")"
vote_balance="$(sol_amount "$vote_balance_lamports")"

printf 'nodemonitor,pubkey=%s status=%si,rootSlot=%si,lastVote=%si,credits=%si,activatedStake=%s,version=%si,commission=%si,leaderSlots=%si,skippedSlots=%si,pctSkipped=%s,pctTotSkipped=%s,pctSkippedDelta=%s,pctTotDelinquent=%s,pctNewerVersions=0%s,openFiles=%si,validatorBalance=%s,validatorVoteBalance=%s,nodes=%si,epoch=%si,pctEpochElapsed=%s,validatorCreditsCurrent=%si,epochEnds=%si,pctVote=%s,tps=%si %s\n' \
  "$identity_pubkey" "$status" "$root_slot" "$last_vote" "$credits" "$activated_stake" "$version_number" "$commission" \
  "$leader_slots" "$skipped_slots" "$pct_skipped" "$pct_total_skipped" "$pct_skipped_delta" "$pct_total_delinquent" \
  "$price_field" "$open_files" "$identity_balance" "$vote_balance" "$nodes" "$epoch" "$pct_epoch_elapsed" \
  "$current_credits" "$epoch_ends" "$pct_vote" "$transaction_count" "$now"
