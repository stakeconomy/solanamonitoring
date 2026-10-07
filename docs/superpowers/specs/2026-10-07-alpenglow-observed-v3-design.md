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

`monitor.sh` remains the one-minute general validator collector. It must stop invoking the legacy interval-based Alpenglow helper and must stop emitting `nodemonitor_alpenglowObserved*` fields.

The standalone collector runs independently so a leader slot contaminates only a short observation gap rather than a full one-minute monitor interval.

## Collector interface

The collector remains:

```text
scripts/alpenglow-observed-vote-inclusion.sh
```

It becomes a standalone CLI:

```bash
scripts/alpenglow-observed-vote-inclusion.sh \
  --rpc-url http://127.0.0.1:8899 \
  --identity <IDENTITY_PUBKEY> \
  --vote-account <VOTE_ACCOUNT_PUBKEY>
```

Optional arguments and environment variables:

- `--state PATH` / `MONITOR_ALPENGLOW_OBSERVED_STATE`
- `--rpc-timeout SECONDS` / `MONITOR_ALPENGLOW_RPC_TIMEOUT`, default `1`
- `--reference-count N` / `MONITOR_ALPENGLOW_REFERENCE_COUNT`, default `8`, maximum `32`
- `--rate-samples N` / `MONITOR_ALPENGLOW_RATE_SAMPLES`, default `20`, maximum `100`
- `CURL_BIN`, default `curl`

Identity, vote account, and RPC URL are required. The frequent collector does not run validator-process discovery or Solana CLI discovery.

## Exact network isolation

The collector emits a measurement only when every current observation proves:

```text
genesis == 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY
getAgGenesisCert succeeds with a non-null result
configured identity and vote account match persisted state
```

Mainnet, Tower Testnet, unknown consensus, malformed responses, and identity mismatch emit no `alpenglow_observed` line.

The normal RPC batch includes:

- `getGenesisHash`;
- `getAgGenesisCert`;
- `getEpochSchedule`;
- one finalized `getMultipleAccounts` request for the monitored vote account and persisted reference cohort.

`getVoteAccounts` runs only when creating or repairing the reference cohort. `getLeaderSchedule` runs only after an epoch change, a missing cache, or a tracked account node-identity change.

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

Write state with a same-directory temporary file, mode `0600`, followed by atomic rename.

Reset all state when any of these change:

- schema version;
- genesis;
- consensus;
- configured identity;
- configured vote account;
- immutable epoch-schedule fields.

On epoch change:

- preserve cumulative totals and cohort membership;
- discard the cross-epoch baseline;
- reset every account's rate learner;
- reset leader-schedule cache;
- establish a new same-epoch baseline.

State schema:

```json
{
  "version": 3,
  "genesis": "...",
  "consensus": "alpenglow",
  "pubkey": "...",
  "vote_account": "...",
  "schedule": {
    "slots_per_epoch": 432000,
    "first_normal_slot": 524256,
    "warmup": true
  },
  "epoch": 1053,
  "reference_votes": ["..."],
  "accounts": {
    "<vote-account>": {
      "node": "...",
      "total": "123456",
      "slot": 449000000,
      "rate_epoch": 1053,
      "gcd": "789",
      "samples": 20,
      "increment": "789"
    }
  },
  "leader_schedule_epoch": 1053,
  "leader_slots": {
    "<vote-account>": [449000100]
  },
  "totals": {
    "included": 1000,
    "expected": 1010,
    "missed": 10,
    "unattributed_slots": 400
  },
  "last_attributed_slot": 449000000
}
```

RPC credit totals and learned increments remain decimal strings in JSON. Reject values outside non-negative signed-64-bit range before Bash arithmetic.

## Gap safety

All account values must come from one finalized `getMultipleAccounts` context slot.

For account `a` and gap `(from,to]`:

```text
delta[a] = total[a,to] - total[a,from]
```

An account count is clean and known only when:

- `to > from`;
- totals are valid and non-decreasing;
- the gap remains in one epoch;
- the gap begins after `epoch_start + 8`;
- the account's node has a cached schedule for the epoch;
- the gap contains no leader slot for that account;
- and either `delta == 0` or an epoch-specific increment is known and divides `delta` exactly;
- inferred count does not exceed gap slot length.

A clean zero delta is a known count of zero even before increment learning.

## Epoch-specific increment learning

Each tracked account has one learner for the current epoch.

For every clean positive delta:

```text
gcd = gcd(previous_gcd, delta)
samples += 1
```

Promote `increment = gcd` when:

- the clean gap is exactly one slot; or
- the learner has at least the configured positive-sample count.

Never carry GCD, sample count, or increment across epochs.

If a later clean positive delta is not divisible by the stored increment, treat that account as unknown for the gap, update the candidate GCD for future observations, and do not rewrite historical totals.

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

Emit exactly one Influx line on every valid Testnet Alpenglow snapshot, including cold start and unchanged totals:

```text
alpenglow_observed,
  cluster=testnet,
  genesis=<exact-genesis>,
  consensus=alpenglow,
  pubkey=<identity>,
  vote_account=<vote-account>,
  schema=3
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

Add a second input:

```toml
[[inputs.exec]]
  commands = ["/usr/bin/sudo -n -H -u VALIDATOR_USER -- /home/VALIDATOR_USER/solanamonitoring/scripts/alpenglow-observed-vote-inclusion.sh --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --rpc-timeout 1"]
  interval = "2s"
  timeout = "1500ms"
  data_format = "influx"
```

The existing one-minute `monitor.sh` input stays unchanged except that it no longer calculates observed inclusion.

If real target hardware cannot complete comfortably within 1.5 seconds, do not silently increase overlap risk. Measure first; a persistent implementation is a later fallback, not part of schema v3.

## Grafana

Use a fixed ten-minute operator window.

Inclusion rate:

```promql
100 *
increase(alpenglow_observed_included_total{
  cluster=~"$cluster",
  genesis=~"$genesis",
  consensus="alpenglow",
  pubkey="$pubkey",
  vote_account=~"$vote_account"
}[10m])
/
increase(alpenglow_observed_expected_total{
  cluster=~"$cluster",
  genesis=~"$genesis",
  consensus="alpenglow",
  pubkey="$pubkey",
  vote_account=~"$vote_account"
}[10m])
```

Suppress the percentage only when the rolling expected increase is zero.

Counts:

```promql
increase(alpenglow_observed_included_total{...}[10m])
increase(alpenglow_observed_expected_total{...}[10m])
increase(alpenglow_observed_missed_total{...}[10m])
```

History uses the same rolling ten-minute rate. Remove:

- `clamp_max`;
- raw interval-gauge division;
- latest-sample readiness gating;
- legacy `nodemonitor_alpenglowObserved*` queries.

Primary titles remain:

- `Alpenglow vote inclusion rate`
- `Alpenglow vote counts`
- `Alpenglow inclusion rate history`

Descriptions say **RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry**.

## Migration

- Use a new v3 state filename; do not migrate v2 interval state into cumulative totals.
- Keep old v2 state untouched for rollback.
- Add the new collector and measurement first.
- Run schema v3 in shadow mode for 24 hours before considering the old interval contract removed operationally.
- Source code and dashboard may cut over together only after fixture and local runtime gates pass; production import still requires live readback.

## Required RED tests

1. Cold start emits all zero counters with `ready=0` and persists schema v3 state.
2. Mainnet, Tower Testnet, unknown consensus, and genesis mismatch emit no measurement and do not mutate state.
3. Own count larger than every reference produces `expected_gap == own_count` and no rate above 100%.
4. Clean all-zero gap is attributed with unchanged counters and `ready=1`.
5. Positive unknown-rate gap increases `unattributed_slots_total` and creates no pending queue.
6. Twenty clean positive samples establish an epoch-specific increment.
7. Epoch transition preserves cumulative totals but resets baseline, learners, and schedule cache.
8. Own leader contamination makes the gap unattributed; a contaminated reference is ignored while another clean reference can still define expected.
9. Restart preserves counters, cohort, baseline, and current-epoch learner.
10. Two concurrent invocations cannot both advance state.
11. Large candidate population still selects a bounded cohort with bounded parser subprocesses and snapshots at most monitored plus configured references.
12. Every successful snapshot emits all eight fields, even when totals do not change.
13. Dashboard uses ten-minute `increase()` queries, contains no clamp, and remains fully scoped by cluster, genesis, consensus, pubkey, and vote account.
14. Telegraf has a separate two-second input with timeout shorter than interval.
15. Existing Mainnet Tower queries and panels remain unchanged.

## Acceptance gates

Before push:

- syntax, monitor, collector, dashboard, and Telegraf suites pass;
- dashboard transformation is idempotent and has no overlapping panels;
- state writes are atomic and lock tests pass;
- execution against fixtures completes below two seconds;
- only intended files are committed.

Before production cutover:

- 24-hour shadow run on the target validator;
- no invariant violation;
- no schema-v3 Mainnet/Tower series;
- state survives restart;
- normal runtime remains below 1.5 seconds;
- VictoriaMetrics receives repeated cumulative samples, including unchanged totals;
- no unexplained dashboard gap longer than two collection intervals;
- live dashboard UID and datasource queries are read back after import.

## Residual limitation

The denominator remains an estimate. A bounded reference cohort can collectively miss an opportunity, so estimated misses may be undercounted. Portable RPC reward accounting cannot eliminate this limitation or identify which peer omitted a vote.
