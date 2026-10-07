# Alpenglow Observed Metrics Schema v3 Design

**Date:** October 7, 2026

## Goal

Provide continuous, understandable, RPC-only estimated Alpenglow vote-inclusion metrics for Stakeconomy SolanaMonitoring without adding a daemon or pretending reward-accounting inference is direct certificate evidence.

The operator view must answer:

- What percentage of estimated opportunities included my vote?
- How many were included?
- How many were estimated missed?
- Is collection current?

## KISS decision

Use one standalone Bash collector scheduled by a separate Telegraf `inputs.exec` entry every two seconds.

The design has:

- one script;
- one JSON state file;
- one non-blocking lock file;
- one `alpenglow_observed` measurement;
- eight fixed fields;
- one stable randomized cohort of eight references;
- one ten-minute dashboard window.

It deliberately has no daemon, pending-gap queue, replay engine, reference quorum, reason-label family, or peer attribution.

## Separation from the general monitor

`monitor.sh` remains the one-minute general validator collector. During phase-one shadow rollout it keeps invoking the legacy interval helper and keeps emitting `nodemonitor_alpenglowObserved*`. Only phase three removes that invocation and those fields.

The standalone collector runs independently so a leader slot contaminates only a short observation gap rather than a full one-minute monitor interval.

## Collector interface

The collector remains:

```text
scripts/alpenglow-observed-vote-inclusion-v3.sh
```

The new v3 collector is a standalone CLI; the existing non-v3 helper and positional ABI remain untouched during shadow:

```bash
scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 \
  --identity <IDENTITY_PUBKEY> \
  --vote-account <VOTE_ACCOUNT_PUBKEY>
```

Optional arguments and environment variables:

- `--state PATH` / `MONITOR_ALPENGLOW_OBSERVED_STATE`
- `--rpc-timeout SECONDS` / `MONITOR_ALPENGLOW_RPC_TIMEOUT`, default `0.7` per call
- `--reference-count N` / `MONITOR_ALPENGLOW_REFERENCE_COUNT`, default `8`, maximum `32`
- `--rate-samples N` / `MONITOR_ALPENGLOW_RATE_SAMPLES`, default `20`, maximum `100`
- `CURL_BIN`, default `curl`

`SOLANA_CONFIG_DIR` defaults to `$HOME/.config/solana`. The state parent directory must already exist or be creatable and writable by the validator user.

Required runtime commands are `bash`, `curl`, `jq`, `flock`, `mktemp`, `mv`, `chmod`, `date`, `sed`, `mkdir`, and `rm`. Missing dependencies or invalid arguments exit `64` or `69`, write a concise error to stderr, emit nothing, and do not mutate state.

Identity, vote account, and RPC URL are required. The frequent collector does not run validator-process discovery or Solana CLI discovery.

## Exact network and identity isolation

A valid current observation must prove all of these before any existing state is replaced or advanced:

```text
genesis == 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY
getAgGenesisCert succeeds with a non-null result
monitored account owner == Vote111111111111111111111111111111111111111
monitored account is parsed type "vote"
monitored account nodePubkey == --identity
```

Mainnet, Tower Testnet, unknown consensus, malformed responses, wrong genesis, and monitored-node mismatch emit no line, return non-zero for RPC/data failure, and leave existing state byte-for-byte unchanged.

Transition ordering:

| Condition | Output | State action |
|---|---|---|
| No state file and valid Testnet Alpenglow observation | cold `ready=0` record | create v3 state |
| Valid observation and state identity matches | normal record | advance state |
| Valid observation but persisted pubkey or vote account differs | cold `ready=0` record | atomically replace with fresh totals for the explicitly configured validator |
| Persisted version, genesis, consensus, or immutable schedule fingerprint differs | no output, exit non-zero | no mutation; operator intervention required |
| Wrong network, Tower, unknown consensus, RPC error, malformed account, or monitored `nodePubkey != --identity` | no output | no mutation |
| Existing core state (excluding the separately recoverable leader-cache subsection) is unreadable, truncated, structurally invalid, or violates cumulative invariants | no output, exit non-zero | no mutation; operator must move the bad file aside explicitly |

An intentional identity or vote-account rotation is initialized by running the collector with new explicit arguments against a valid Testnet Alpenglow snapshot. When either configured identity or configured vote account differs from persisted state, the mandatory batch includes only the newly configured monitored vote account—never persisted references. After ownership proof, replacement state starts with zero cumulative totals, an empty cohort, only the monitored baseline, null schedule cache, and reset learners; the optional call may then discover a fresh cohort. No old cohort, account, learner, or schedule record is retained.

`reference_count` and `rate_samples` are persisted under `config`. Transition precedence is: validate state and mandatory observation; handle identity/vote replacement; apply configuration changes; handle epoch change; then classify stale, repeated, or advancing slots.

A changed `reference_count` preserves totals, learners, baselines, and initialized retained members; it trims deterministically by persisted order when lowered and adds null-baseline members through the optional repair call when raised. Existing clean accounts may still classify the current gap.

A changed `rate_samples` preserves totals but invalidates learner semantics. Clear every learner before using the current snapshot. If `to > from`, force that whole span to unattributed exactly once, advance every valid baseline, keep `last_attributed_slot` unchanged, store the new threshold, and emit `ready=0`. If `to == from`, store the new threshold and cleared learners with no slot or counter change and emit `ready=0`. Thus configuration mutation is allowed on a repeated snapshot and takes precedence over the normal repeated-slot no-mutation rule.

The mandatory RPC batch includes exact unique IDs for:

- `getGenesisHash`;
- `getAgGenesisCert`;
- `getEpochSchedule`;
- finalized `getMultipleAccounts` with `encoding:"jsonParsed"` for the monitored vote account and persisted reference cohort.

Reject missing or duplicate batch IDs, JSON-RPC errors, null monitored account, wrong owner, non-vote parsed type, malformed epoch-credit history, and invalid context slot. Parse `epochCredits` in array order. Within each generation, non-marker epochs must be strictly increasing and unique. The exact generation-boundary marker has epoch token `18446744073709551615` and both credit strings equal to that same value; it resets ordering and discards the preceding generation for latest-value selection. No other unsafe numeric epoch is a marker, even with marker-like credits. Marker-only history fails closed. Canonical object entries otherwise require `credits` and `previousCredits` as decimal strings and accept `epoch` as either a decimal string or an exact non-negative JSON integer no greater than `9007199254740991`. Legacy array entries `[epoch,credits,previousCredits]` are accepted only when all three are exact non-negative JSON integers no greater than `9007199254740991`. The latest post-boundary non-marker epoch must not exceed the slot-derived current epoch. The cumulative source total is its `credits`; `previousCredits` is validated but not subtracted.

`getVoteAccounts` uses `commitment:"finalized"` only when creating or repairing the cohort. `getLeaderSchedule` uses `commitment:"confirmed"`, receives the current epoch's first absolute slot, rejects a null or non-object result, and runs only after an epoch change, a missing cache, or a tracked account node-identity change. Its returned values are epoch-relative slot offsets; validate `0 <= offset < slots_per_epoch` and persist absolute slots as `epoch_first_slot + offset`. `leaderScheduleSlotOffset` is persisted as part of the immutable schedule fingerprint but is not used in epoch arithmetic or as the `getLeaderSchedule` argument.

## Reference cohort

Choose up to the configured limit from active current vote accounts, excluding the monitored account.

- Selection is randomized only when initializing or replacing missing members.
- Persist vote-account membership.
- Keep valid members across polls and epochs.
- Refresh current node identities from vote-account snapshots.
- Do not use activated-stake rank as a correctness rule.
- Use all clean known references in the denominator maximum.
- Require at least one clean known reference to attribute a gap.

No reference pubkey or node identity becomes a metric tag.

## State and locking

Default state:

```text
$SOLANA_CONFIG_DIR/alpenglow-observed-vote-inclusion-v3.json
```

Acquire an exclusive non-blocking `flock` on `<state>.lock` before reading state or calling RPC. If the lock is held, exit successfully without output.

Write state with a same-directory temporary file, mode `0600`, followed by atomic rename. A failed write emits no line, exits non-zero, and leaves the previous state intact.

Core state validation occurs before RPC interpretation. Require the exact top-level/account schema, unique reference votes, configured account-key equality, valid nullable learner forms, signed-64-safe decimal strings, non-negative totals, and:

```text
expected == included + missed
included <= expected
```

Invalid core state is never overwritten automatically. The leader-cache subsection is the sole recoverable exception: its invalidity cannot alter counters or baselines and is normalized exactly as defined below.

On a valid identity transition described above, replace state only after network and monitored-account ownership have been proven. On epoch change:

- preserve cumulative totals and valid cohort membership;
- account the cross-epoch slot span as unattributed once;
- replace every account baseline with the current snapshot;
- reset every account's GCD, samples, and increment;
- reset and refetch leader schedules;
- emit `ready=0` for that invocation.

State schema:

```json
{
  "version": 3,
  "genesis": "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY",
  "consensus": "alpenglow",
  "pubkey": "...",
  "vote_account": "...",
  "config": {
    "reference_count": 8,
    "rate_samples": 20
  },
  "schedule": {
    "slots_per_epoch": 432000,
    "leader_schedule_slot_offset": 432000,
    "warmup": true,
    "first_normal_epoch": 14,
    "first_normal_slot": 524256
  },
  "epoch": "1053",
  "reference_votes": ["..."],
  "accounts": {
    "<vote-account>": {
      "node": "...",
      "total": "123456",
      "slot": "449000000",
      "gcd": "789",
      "samples": 20,
      "increment": "789"
    },
    "<new-reference-without-baseline>": {
      "node": null,
      "total": null,
      "slot": null,
      "gcd": null,
      "samples": 0,
      "increment": null
    }
  },
  "leader_schedule_epoch": "1053",
  "leader_slots": {
    "<node-identity>": ["449000100"]
  },
  "totals": {
    "included": "1000",
    "expected": "1010",
    "missed": "10",
    "unattributed_slots": "400"
  },
  "last_attributed_slot": "449000000"
}
```

`accounts` keys must equal exactly the monitored vote account plus `reference_votes`. A newly selected reference uses the explicit all-null baseline form shown above. For an initialized account, `node`, `total`, and `slot` are non-null; every initialized account `slot` must equal the monitored account's baseline slot, so every compared delta covers the same `(from,to]` span. A partial baseline (some but not all of node/total/slot non-null) is invalid. `gcd` and `increment` are either canonical positive decimal strings or null; `samples` is an exact JSON integer in `0..rate_samples`; `increment != null` requires `gcd != null` and `samples >= 1`. Learner reset sets `gcd=null`, `samples=0`, and `increment=null`.

Leader-cache state is valid only in one of two exact forms:

- absent cache: `leader_schedule_epoch=null` and `leader_slots={}`;
- current cache: `leader_schedule_epoch == epoch`, every key is a unique non-null `node` used by an initialized tracked account, and each value is a strictly increasing unique array of canonical decimal-string absolute slots within `[epoch_first_slot, epoch_first_slot + slots_per_epoch)`.

Extra node keys, missing required node keys, unsafe slots, out-of-epoch slots, duplicates, unsorted arrays, or a cache epoch different from state epoch invalidate the cache portion. They do not invalidate counters or baselines: normalize to the absent-cache form before classifying the current gap, fetch once if the optional-call slot is available, and treat only accounts still lacking a valid schedule as unknown.

All potentially large state integers—epoch, slots, credit totals, GCD values, increments, and cumulative totals—are canonical decimal strings. Only bounded schema/config/sample values remain JSON numbers. Validate every string before Bash arithmetic: decimal syntax only, range `0..9223372036854775807`, checked addition/subtraction, and fail closed on overflow. jq must never convert these strings with `tonumber`. Influx integer fields are emitted directly from validated decimal strings with the `i` suffix.

For this exact Testnet genesis, require the immutable schedule tuple to equal exactly:

```text
slotsPerEpoch=432000
leaderScheduleSlotOffset=432000
warmup=true
firstNormalEpoch=14
firstNormalSlot=524256
```

Any different tuple is an isolation failure and cannot replace or advance state. Epoch arithmetic uses `MINIMUM_SLOTS_PER_EPOCH = 32`. For slot `s`:

```text
if warmup && s < first_normal_slot:
  epoch = greatest e where ((2^e - 1) * 32) <= s
else:
  epoch = first_normal_epoch + floor((s - first_normal_slot) / slots_per_epoch)
```

The first slot of epoch `e` is:

```text
if warmup && e <= first_normal_epoch:
  first_slot = (2^e - 1) * 32
else:
  first_slot = (e - first_normal_epoch) * slots_per_epoch + first_normal_slot
```

Reject impossible schedules, negative terms, shifts outside safe bounds, or any result outside signed-64 range.

## Gap safety

All account values come from one finalized `getMultipleAccounts` context slot `to`. Each parsed vote account supplies `nodePubkey` and the current epoch-credit total from the explicitly named tuple fields.

For account `a` and gap `(from,to]`:

```text
delta[a] = total[a,to] - total[a,from]
first included slot = from + 1
```

A gap is epoch-safe only when both endpoints derive to the same epoch and:

```text
from + 1 >= epoch_first_slot + 8
```

Thus the first accepted included slot is exactly `epoch_first_slot + 8`; boundary tests cover `+7`, `+8`, and `+9`.

An account count is clean and known only when:

- `to > from`;
- totals are valid and non-decreasing;
- the gap is epoch-safe by the exact predicate above;
- the account's current node has a non-null cached schedule for that epoch;
- the gap contains no leader slot for that node;
- and either `delta == 0` or a current-epoch increment is known and divides `delta` exactly;
- inferred count does not exceed `to - from`.

A clean zero delta is a known count of zero even before increment learning.

Deterministic snapshot transitions:

| Condition | Measurement | Baseline/state transition |
|---|---|---|
| `to <` the monitored baseline slot | no output, non-zero exit | no mutation |
| `to ==` the monitored baseline slot | emit unchanged totals with `ready=0`, `usable_references=0` | preserve baseline slot/total and counters; refresh changed valid tracked nodes, clear their learners, and persist an exact current-node schedule cache |
| monitored account null, malformed, wrong owner/type, wrong node, or decreasing total | no output, non-zero exit | no mutation |
| reference null or malformed | exclude it for this gap | remove that reference/account record; if the optional-call slot is available, repair in the same invocation with null-baseline members, otherwise repair later |
| reference total decreases | reference unknown for this gap | advance its baseline to the lower current total, clear its learner, keep membership |
| tracked account node changes | account unknown for this gap | advance baseline, clear learner, invalidate that account's cached schedule |
| leader schedule missing/null | affected account unknown | advance its valid baseline; retry schedule next invocation |
| any otherwise valid but unattributed gap | emit `ready=0` | count the monitored slot span once, then advance every valid current account baseline |
| attributed gap | emit `ready=1` | update counters, then advance every valid current account baseline |

One bad reference never invalidates a valid monitored snapshot or another clean reference. Because v3 has no replay queue, every valid current account baseline advances after the current monitored span is classified; this prevents double counting and prevents a later interval from spanning an earlier contaminated gap.

## Epoch-specific increment learning

Each tracked account has one learner for the current epoch.

For a leader-clean, epoch-safe positive delta with no stored increment:

```text
gcd = gcd(previous_gcd, delta)  # delta when no previous candidate exists
samples += 1
```

Promote `increment = gcd` when the gap length is exactly one slot, or when `samples >= --rate-samples`. If promotion occurs on the current gap, that gap may be counted immediately only when the promoted increment divides its delta and the inferred count fits the gap.

For a leader-clean positive delta with a stored increment:

- if divisible, keep the increment, fold the delta into the candidate GCD, and increment samples;
- if not divisible and the gap is exactly one slot, replace `gcd`, `samples`, and `increment` with `delta`, `1`, and `delta`;
- if not divisible and the gap spans multiple slots, mark the account unknown, clear `increment`, and restart recovery with `gcd=delta` and `samples=1`.

Never carry GCD, sample count, or increment across epochs. A restart during recovery preserves the current epoch's candidate GCD and sample count. Historical totals are never rewritten after a contradiction.

## Per-gap totals

An attributed gap requires:

- a known monitored count;
- at least one clean known reference count.

Formula:

```text
included_gap = monitored_count
expected_gap = max(included_gap, every clean known reference_count)
missed_gap   = expected_gap - included_gap
```

`expected_gap == 0` is valid and attributed. It changes no cumulative count but keeps collection truthful and current.

For an attributed gap:

```text
included_total += included_gap
expected_total += expected_gap
missed_total   += missed_gap
last_attributed_slot = to
ready = 1
```

Otherwise:

```text
unattributed_slots_total += to - from
ready = 0
```

The collector does not persist or replay pending gaps. Warm-up loss is explicit in `unattributed_slots_total`.

Required invariants:

```text
expected_total == included_total + missed_total
included_total <= expected_total
```

## Measurement contract

Emit exactly one Influx line on every valid Testnet Alpenglow snapshot, including cold start and unchanged totals. Use standard Influx escaping for backslash, comma, equals, and space in tag values. Exact shape:

```text
alpenglow_observed,cluster=testnet,genesis=<escaped-genesis>,consensus=alpenglow,pubkey=<escaped-identity>,vote_account=<escaped-vote-account>,schema=3 included_total=0i,expected_total=0i,missed_total=0i,unattributed_slots_total=0i,ready=0i,observed_slot=449000000i,last_attributed_slot=0i,usable_references=0i
```

Integer fields:

```text
included_total
expected_total
missed_total
unattributed_slots_total
ready
observed_slot
last_attributed_slot
usable_references
```

Field meanings:

- `ready`: whether the latest gap was attributed; cold baseline is `0`.
- `usable_references`: clean references with known counts in the latest gap.
- `observed_slot`: latest finalized snapshot slot.
- `last_attributed_slot`: zero until the first attributed gap.

No reference identities, reason strings, epoch, or implementation internals become tags.

## Telegraf

Each invocation performs one mandatory normal batch and at most one optional RPC call, each capped by `--rpc-timeout` (default `0.7s`):

1. mandatory batch: network markers, exact epoch schedule, and finalized account snapshot;
2. optional call chosen after parsing the mandatory batch: if the cohort is empty, `getVoteAccounts`; otherwise if a schedule needed by a tracked account is missing, `getLeaderSchedule`; otherwise if the cohort is below target, `getVoteAccounts`; otherwise none.

Cold start snapshots only the monitored account, proves ownership, and may select cohort membership. Reference baselines are null until a later normal batch. A failed optional call invalidates only accounts that require its missing data: an existing clean monitored account plus at least one existing clean reference may still attribute the gap. If attribution remains possible, emit `ready=1`; otherwise emit `ready=0` and count the span once as unattributed. A same-invocation cohort repair adds new members in the explicit null-baseline form; they become usable only on a later snapshot. No path makes a third RPC call.

The script writes stdout only after its atomic state rename succeeds. Telegraf uses a measured bounded `10s` fail-safe timeout so a valid full-epoch schedule refresh is not killed; the interval remains `2s`, and the non-blocking state lock makes overlapping scheduler launches exit quietly instead of running concurrently. This fail-safe does not relax shadow acceptance: production-shaped repeated timing still requires p99 runtime below `1.5s`.

Install the standalone collector sudo rule before enabling its input. The v3 rule must include the exact production arguments, including the fixed state path, so Telegraf cannot choose another RPC destination, identity, vote account, state file, or parser setting:

```sudoers
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http\://127.0.0.1\:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20
```

Install as root-owned mode `0440`, run `visudo -c`, and inspect `sudo -ll -U telegraf` for the exact argument-bound command. Then execute that exact production command once in shadow mode and verify its output/state; `--help` is a normal unprivileged script check and is not authorized through sudo.

Add the second input only after that validation:

```toml
[[inputs.exec]]
  commands = ["/usr/bin/sudo -n -H -u VALIDATOR_USER -- /home/VALIDATOR_USER/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/VALIDATOR_USER/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20"]
  interval = "2s"
  timeout = "10s"
  data_format = "influx"
```

The existing one-minute `monitor.sh` input and sudo rule stay unchanged throughout shadow rollout.

Exit contract:

| Class | stdout | stderr | exit | state |
|---|---|---|---:|---|
| `--help` | usage text | empty | 0 | no lock/RPC/state access |
| valid snapshot | one complete Influx line | optional bounded warning | 0 | atomic successor |
| lock held | empty | empty | 0 | unchanged |
| invalid arguments | empty | concise error | 64 | unchanged |
| dependency unavailable | empty | concise error | 69 | unchanged |
| mandatory RPC/JSON/isolation/state-validation failure | empty | concise error | 1 | unchanged |
| optional call fails after a valid mandatory snapshot | one complete line reflecting actual per-account usability | concise warning | 0 | valid baselines advance; failed cache remains missing |
| atomic write fails | empty | concise error | 1 | previous state retained |

If target hardware cannot remain below 1.5 seconds at p99 during shadow operation, v3 does not cut over. A persistent implementation is a later fallback, not part of this KISS design.

## Grafana

Use a fixed ten-minute operator window and this exact bounded selector in every target:

```promql
{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}
```

Inclusion rate:

```promql
(
  100 *
  increase(alpenglow_observed_included_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m])
  /
  increase(alpenglow_observed_expected_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m])
)
and on(cluster,genesis,consensus,pubkey,vote_account,schema)
(
  increase(alpenglow_observed_expected_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m]) > 0
)
```

This suppresses only the percentage when the rolling expected increase is zero.

Count cards use display-rounded rolling estimates because PromQL `increase()` extrapolation may be fractional at window boundaries:

```promql
round(increase(alpenglow_observed_included_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m]))
round(increase(alpenglow_observed_expected_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m]))
round(increase(alpenglow_observed_missed_total{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}[10m]))
```

History uses the same rolling ten-minute rate.

Collection status is independent of historical counts. A compact status panel queries the latest instant-vector sample:

```promql
alpenglow_observed_ready{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"}
```

and its actual scrape age:

```promql
time() - timestamp(alpenglow_observed_observed_slot{cluster=~"$cluster",genesis=~"$genesis",consensus="alpenglow",pubkey="$pubkey",vote_account=~"$vote_account",schema="3"})
```

The age result uses the original instant sample timestamp, not a range-function result. Map age `<=5s` as current and `>5s` as stale; no sample is `No recent samples`. Within a current sample, map `ready=1` to `Current gap attributed` and `ready=0` to `Collecting / latest gap unattributed`. A separate zero-opportunity condition uses the ten-minute expected increase: latest `ready=1`, current age, and expected increase `0` displays `No vote opportunities in the last 10 minutes`. Historical rate/count queries are never gated by latest readiness.

The canonical dashboard refresh is `5s`, and the refresh interval list includes `5s`. This intentionally increases query load so the five-second freshness contract is actually observable; panel resolution and selectors remain bounded.

Remove:

- `clamp_max`;
- raw interval-gauge division;
- readiness gating on historical values;
- legacy `nodemonitor_alpenglowObserved*` queries after shadow cutover.

Primary titles are:

- `Alpenglow vote inclusion rate — last 10 minutes`
- `Alpenglow vote counts — last 10 minutes`
- `Alpenglow inclusion rate history`
- `Alpenglow collection status`

Every Alpenglow panel description says **RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry**.

## Migration

Use three explicit rollback-safe phases:

1. **Install/shadow:** add the script, v3 state path, sudoers rule, and two-second Telegraf input. Keep the legacy one-minute `monitor.sh` invocation and schema-v2 dashboard queries unchanged. Shadow for at least 24 hours.
2. **Dashboard cutover:** after shadow gates pass, switch panels to schema-v3 queries while retaining legacy collection, old state, and old series. Rollback is dashboard-only.
3. **Legacy retirement:** only after the cutover is verified through the deployed Grafana UID and authenticated datasource, remove the schema-v2 collector call from `monitor.sh`. Keep old v2 state and historical series untouched.

Do not migrate v2 interval state into v3 cumulative totals. Rollback never copies v3 counters into v2 and never deletes either state file.

## Required RED tests

1. Cold start proves monitored `nodePubkey`, emits all zero counters with `ready=0`, and persists schema v3 state.
2. Mainnet, Tower Testnet, unknown consensus, genesis mismatch, and monitored-node mismatch emit nothing and leave state byte-identical.
3. Valid configured identity/vote rotation replaces mismatched state only after network and ownership proof; corrupt existing state is never overwritten.
4. Own count larger than every reference produces `expected_gap == own_count` and no rate above 100%.
5. Clean all-zero gap is attributed with unchanged counters and `ready=1`.
6. Positive unknown-rate gap increases `unattributed_slots_total` and creates no pending queue.
7. Twenty clean positive samples establish an epoch-specific increment; a one-slot sample establishes it immediately.
8. A multi-slot increment contradiction clears and restarts the learner; a one-slot contradiction replaces it; restart preserves recovery state.
9. Epoch transition preserves cumulative totals, counts the cross-epoch span once as unattributed, and resets baselines, learners, and schedule cache.
10. Reward-delay boundaries reject first included slot `epoch_start+7` and accept exact `epoch_start+8` and later.
11. Own leader contamination makes the gap unattributed; a contaminated reference is ignored while another clean reference can define expected.
12. Repeated slot with unchanged config emits `ready=0` without mutation; regressing slot, mismatched initialized baseline slots, malformed monitored account, decreasing monitored total, and invalid core state fail without mutation.
13. Null/malformed reference is removed without poisoning clean peers; decreasing reference total, node rotation, and missing schedule advance that valid baseline conservatively and make only that account unknown.
14. Two concurrent invocations cannot both advance state; forced termination during a write leaves the previous JSON valid.
15. Large candidate population selects default eight, configurable up to 32, with bounded parser subprocesses and snapshots at most monitored plus configured references.
16. Every successful snapshot emits all eight fields and escaped bounded tags, even when totals do not change.
17. Decimal-string state preserves values above jq's exact-number range; overflow, wrong fixed schedule tuple, malformed/unsorted epoch history, duplicate/missing batch IDs, JSON-RPC errors, wrong owner/type, and unsafe marker forms fail closed. Stale, extra-key, missing-key, duplicate, unsorted, unsafe, or out-of-epoch leader caches normalize to absent and never suppress contamination checks.
18. Mandatory batch plus at most one optional call never makes a third RPC call; every fixture path remains below the `1.5s` p99 target in repeated local timing runs.
19. Optional-call failure invalidates only dependent accounts and still attributes when an existing clean monitored account and reference remain.
20. Exit codes/stdout/stderr match the exit contract, including `--help`, quiet lock contention, and optional-call warning behavior.
21. Telegraf has a separate two-second input with a measured bounded `10s` fail-safe timeout, exact fixed arguments, and `0.7`-second RPC timeout; sudoers tests reject altered state, RPC URL, identity, or parser arguments while preserving the old monitor rule.
22. The legacy helper path and thirteen-positional-argument ABI remain unchanged during shadow; v3 uses the separate `-v3.sh` path.
23. Changed identity or vote account discards old cohort/cache/learners; changed reference count adjusts membership deterministically even on a repeated slot; changed rate-sample threshold resets learners, forces an advancing span wholly unattributed, and on a repeated slot changes only config/learners without resetting totals.
24. Dashboard uses exact schema-v3 ten-minute `increase()` queries, no clamp, bounded selectors, count rounding, instant-sample timestamp age, and a five-second stale threshold; zero-opportunity differs from stale collection.
25. Dashboard transformation remains byte-idempotent with no duplicate IDs or overlap, and existing Mainnet Tower panels remain unchanged.
26. Shadow configuration retains legacy collection; a separate cutover fixture removes legacy invocation only in phase three.

## Acceptance gates

Before push:

- shell syntax, monitor, collector, dashboard, Telegraf, installation, and migration suites pass;
- every new behavior has a recorded RED failure before implementation;
- dashboard transformation is byte-idempotent and has no overlapping panels;
- state writes are atomic and lock/termination tests pass;
- repeated fixture timing demonstrates p99 below 1.5 seconds and no path performs more than two RPC calls;
- `git diff --check` passes and only intended files are committed.

Before production cutover:

- sudoers file validates with `visudo -c`, `sudo -ll -U telegraf`, rejection probes for altered arguments, and one exact production-command shadow invocation;
- 24-hour shadow run on the target validator;
- p99 collector runtime below 1.5 seconds and no Telegraf timeout;
- no invariant violation, corrupt state, or schema-v3 Mainnet/Tower series;
- state survives restart and learner recovery survives restart;
- VictoriaMetrics receives repeated cumulative samples, including unchanged totals;
- no unexplained sample gap longer than two collection intervals;
- collection-status panel distinguishes current, unattributed, zero-opportunity, and stale states;
- live dashboard UID and authenticated datasource queries are read back after import;
- legacy retirement occurs only after those readbacks pass.

## Residual limitation

The denominator and learned per-inclusion increment remain estimates. A bounded reference cohort can collectively miss an opportunity, so estimated misses may be undercounted. Multi-gap GCD promotion can retain a common multiplier and therefore undercount both included and expected events; the twenty-sample threshold reduces but cannot prove away that risk. A one-slot positive gap is the only direct atomic-increment observation in this RPC model. Every panel therefore labels the values RPC-derived estimates, and historical counters are never rewritten when later evidence changes a learner. Portable RPC reward accounting cannot eliminate these limitations or identify which peer omitted a vote.
