# Stakeconomy Solana Community Monitoring

Lightweight monitoring for Solana validators that publish host and validator metrics to the public [Stakeconomy community dashboard](https://metrics.stakeconomy.com/).

This repository intentionally focuses on three things:

- `monitor.sh`: one-minute Solana validator metrics in Influx line protocol;
- `telegraf/solana-monitoring.conf.example`: a low-cardinality, least-privilege Telegraf configuration;
- `grafana/solana-community-validator-dashboard.json`: the dashboard source used by the community service.

It is not a guide for installing a private Telegraf, time-series database, and Grafana stack.

## What is monitored

Validator metrics are scoped by exact genesis, canonical cluster, identity, vote account, and detected consensus. They include finalized-slot vote/root freshness, status, active stake, scheduled-slot production, commission, software version, epoch progress and ETA, cluster TPS, SOL price, identity/vote balances, cluster size, and delinquent stake. Tower vote-credit fields are emitted only when `getAgGenesisCert` reports Tower consensus. Alpenglow emits a validated post-migration `epochCredits` tuple delta as `alpenglowRewardAccountingLamports`; the dashboard presents it as SOL reward accounting, never as performance.

On Alpenglow, the collector also emits a bounded **observed/inferred** vote-inclusion signal from finalized `getMultipleAccounts` reward-accounting snapshots: `alpenglowObservedIncluded`, `alpenglowObservedExpected`, `alpenglowObservedMissed`, `alpenglowObservedUnattributed`, `alpenglowObservedReady`, `alpenglowObservedReferences`, and `alpenglowObservedSlot`. It learns per-account increments from clean reward deltas and compares the validator with a bounded stable randomized reference cohort. This is not certificate-direct inclusion or direct Votor telemetry; portable RPC-only direct Votor collection remains out of scope.

Host metrics include total CPU, IOWait, normalized load, memory, swap, relevant filesystem utilization, network traffic/errors, UDP errors, process states, TCP states, allocated file handles, and context switches.

The dashboard requires cluster, exact genesis, validator identity, and vote-account selection before mapping the selected validator to its reporting host. That prevents a mainnet and testnet identity from sharing a dashboard series. It supports dynamic mount/interface selectors, software-version and health timelines, mirrored receive/transmit traffic, and filters for virtual resources.

## Requirements

- a running Solana or Agave validator with a local RPC endpoint;
- Telegraf;
- Bash, `curl`, `jq`, `awk`, `sed`, `pgrep`, and `date`;
- the Solana CLI when identity discovery or the epoch-ETA fallback is needed.

`bc` is no longer required.

## Quick test

Run the collector as the validator user before configuring Telegraf:

```bash
cd /home/solana/solanamonitoring

./monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3
```

It must emit exactly one line beginning with `nodemonitor,cluster=` on standard output. The record includes `cluster`, `genesis`, `consensus`, `pubkey`, `vote_account`, and `schema=2` tags. Integer fields have the required Influx `i` suffix; balances and percentages remain floating point. Diagnostics are written to standard error.

If one identity has multiple vote accounts, add:

```bash
--vote-account VOTE_ACCOUNT_PUBKEY
```

Run `./monitor.sh --help` for all command-line and environment-variable options.

## Safe Telegraf execution

Telegraf should remain an unprivileged service. During schema-v3 shadow, preserve the legacy one-minute rule and add a second rule that binds every v3 production argument:

```sudoers
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http\://127.0.0.1\:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20
```

Replace the identity and vote-account placeholders in both sudoers and Telegraf with fixed real public keys. Do not add wildcards or authorize an alternate RPC URL, state path, identity, vote account, reference count, or rate-sample threshold.

Enable the v3 rule and two-second input only when the local RPC proves the exact Testnet genesis `4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY` and reports Alpenglow. Mainnet and Tower validators retain only the legacy `monitor.sh` rule and one-minute input.

Validate and inspect the effective policy:

```bash
sudo chmod 0440 /etc/sudoers.d/telegraf-solana-monitor
sudo chown root:root /etc/sudoers.d/telegraf-solana-monitor
sudo visudo -c
sudo -ll -U telegraf
```

The effective rules must not contain `telegraf ALL=(ALL) NOPASSWD:ALL`. Follow the [installation guide](docs/installation.md) to prove altered arguments are rejected and to execute the exact production command once before enabling its input.

The example configuration keeps two independent inputs:

- legacy `monitor.sh`: `interval = "1m"`, `timeout = "1m"`, schema v2;
- standalone v3 collector: `interval = "2s"`, `collection_jitter = "0s"`, `timeout = "10s"`, fixed `--rpc-timeout 0.7 --reference-count 8 --rate-samples 20` and validator-home v3 state. The community output flushes every `2s` without jitter so the dashboard's five-second freshness state reflects collector health rather than Telegraf buffering. The longer process timeout is only a bounded fail-safe for a full-epoch schedule refresh; `flock -n` prevents overlap and shadow acceptance still requires p99 below 1.5 seconds.

Start from [`telegraf/solana-monitoring.conf.example`](telegraf/solana-monitoring.conf.example). Replace the Testnet-neutral `validator-community-host` example with a unique stable hostname, then change the validator username, repository path, RPC URL, fixed identity/vote account, and real validator mount points. Keep the Stakeconomy output settings when using the community dashboard. Do not configure `data_type = "integer"`; the emitted lines contain both integer and floating-point fields.

## Migrating an existing validator

Follow the [installation guide](docs/installation.md) and the [schema-v3 migration guide](docs/alpenglow-monitoring-migration.md). Keep legacy collection and dashboard queries unchanged for at least a 24-hour shadow, cut the dashboard over in phase two, and retire legacy Alpenglow collection only in phase three. Phase-two rollback is dashboard-only; phase-three rollback restores the previous `monitor.sh`. Never copy state or counters between schemas.

The collector retains the `nodemonitor` measurement but writes schema-v2 tagged series. The standalone `alpenglow_observed` measurement uses `schema=3` cumulative counters documented in the [schema-v3 contract](docs/alpenglow-monitoring-schema-v3.md). Untagged historical data is legacy-unclassified and is intentionally excluded from normal cluster-scoped dashboard views; do not assign it retrospectively from a pubkey.

## RPC and epoch ETA behavior

The collector prefers the local validator RPC. It batches compatible JSON-RPC calls to reduce subprocess and RPC overhead.

`epochEnds` normally uses recent performance samples. If the local validator has transaction history disabled and returns no samples, the collector checks the RPC configured for the Solana CLI user and verifies its genesis hash before using it. An explicit `--performance-rpc-url` can override that source. Testnet can finally fall back to its 200 ms target slot duration; `--slot-ms` overrides the duration fallback.

## Observed Alpenglow vote inclusion

`monitor.sh` uses only Bash, `curl`, `jq`, and JSON-RPC. For `consensus=alpenglow`, it considers all active same-cluster `getVoteAccounts` entries except the selected vote account, then chooses up to `MONITOR_ALPENGLOW_REFERENCE_COUNT` (default `8`, maximum `32`) at random for a stable persisted reference cohort. Later runs reuse that cohort and refresh only vote accounts that are no longer eligible; current `getVoteAccounts` node identities are used for leader-gap attribution. It takes one finalized `getMultipleAccounts` snapshot of the selected vote account plus that cohort, and excludes a reward-delta gap for any account that crosses `epoch_start + 8` or contains that account's leader slot from `getLeaderSchedule`.

For clean gaps, it learns each account's per-inclusion reward increment as the GCD of positive reward-accounting deltas. A one-slot clean delta proves the increment immediately; longer intervals require `MONITOR_ALPENGLOW_RATE_SAMPLES` clean positive samples (default `20`, maximum `100`) before the GCD is used. That deliberately delays initial data rather than mistaking a multi-inclusion delta for one inclusion. `alpenglowObservedExpected` is the maximum inferred inclusion count among clean, known reference gaps; `alpenglowObservedIncluded` is the selected account's inferred count; `alpenglowObservedMissed` is emitted only when both values are known. A missing baseline, invalid account encoding, leader-slot gap, epoch-delay gap, failed schedule request, or non-divisible delta is counted as `alpenglowObservedUnattributed`; it is never fabricated as zero inclusion.

The state file defaults to `$SOLANA_CONFIG_DIR/alpenglow-observed-vote-inclusion.json` and can be overridden with `MONITOR_ALPENGLOW_OBSERVED_STATE`. It must be writable by the validator user. State is written to a same-directory temporary file and renamed atomically; it includes the bounded reference vote-account cohort. A stored genesis hash or vote account mismatch resets the cohort and learned baseline, so data is never compared across cluster or vote-account changes. This signal is observed/inferred reward accounting only, not certificate-direct inclusion and not direct Votor telemetry. Portable RPC-only direct Votor collection remains out of scope.

Whole-epoch block-production statistics require enough retained ledger data for the current epoch. Aggressive `--limit-ledger-size` pruning can make leader-slot and skip-rate history incomplete.

## Dashboard maintenance

The canonical dashboard is [`grafana/solana-community-validator-dashboard.json`](grafana/solana-community-validator-dashboard.json). Current-value cards use instant queries and historical panels cap their resolution to protect the shared query endpoint.

Dashboard transformation files are retained so changes remain repeatable and regression-testable:

- `grafana/optimize-dashboard.jq`
- `grafana/enhance-dashboard.jq`

## Tests

Run before every pull request:

```bash
bash -n monitor.sh tests/test-*.sh
./tests/test-monitor.sh
./tests/test-dashboard.sh
./tests/test-telegraf.sh
```

See [Interpreting monitoring metrics](Guidelines%20interpreting%20metrics.md) for operational guidance.

Stake with the Stakeconomy validator on Solflare. Vote account: [`GNZ1PAAS33davY4Q1BMEpZEpVBtRtGvSpcTH5wYVkkVt`](https://solanabeach.io/validator/GNZ1PAAS33davY4Q1BMEpZEpVBtRtGvSpcTH5wYVkkVt).
