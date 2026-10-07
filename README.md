# Stakeconomy Solana Community Monitoring

Lightweight monitoring for Solana validators that publish host and validator metrics to the public [Stakeconomy community dashboard](https://metrics.stakeconomy.com/).

This repository intentionally focuses on three things:

- `monitor.sh`: one-minute Solana validator metrics in Influx line protocol;
- `telegraf/solana-monitoring.conf.example`: a low-cardinality, least-privilege Telegraf configuration;
- `grafana/solana-community-validator-dashboard.json`: the dashboard source used by the community service.

It is not a guide for installing a private Telegraf, time-series database, and Grafana stack.

## What is monitored

Validator metrics are scoped by exact genesis, canonical cluster, identity, vote account, and detected consensus. They include finalized-slot vote/root freshness, status, active stake, scheduled-slot production, commission, software version, epoch progress and ETA, cluster TPS, SOL price, identity/vote balances, cluster size, and delinquent stake. Tower vote-credit fields are emitted only when `getAgGenesisCert` reports Tower consensus. Alpenglow emits a validated post-migration `epochCredits` tuple delta as `alpenglowRewardAccountingLamports`; the dashboard presents it as SOL reward accounting, never as performance.

On Alpenglow, the collector also emits a bounded **observed/inferred** vote-inclusion signal from finalized `getMultipleAccounts` reward-accounting snapshots: `alpenglowObservedIncluded`, `alpenglowObservedExpected`, `alpenglowObservedMissed`, `alpenglowObservedUnattributed`, `alpenglowObservedReady`, `alpenglowObservedReferences`, and `alpenglowObservedSlot`. It learns per-account increments from clean reward deltas and compares the validator with bounded top-stake reference vote accounts. This is not certificate-direct inclusion or direct Votor telemetry; portable RPC-only direct Votor collection remains out of scope.

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

Telegraf should remain an unprivileged service. Allow it to run only this collector as the validator user.

Create `/etc/sudoers.d/telegraf-solana-monitor` with `visudo`:

```sudoers
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh
```

Validate the rule:

```bash
sudo chmod 0440 /etc/sudoers.d/telegraf-solana-monitor
sudo chown root:root /etc/sudoers.d/telegraf-solana-monitor
sudo visudo -c
sudo -ll -U telegraf
```

The effective rules must not contain `telegraf ALL=(ALL) NOPASSWD:ALL`.

The Telegraf command is:

```bash
/usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3
```

Start from [`telegraf/solana-monitoring.conf.example`](telegraf/solana-monitoring.conf.example). Change the hostname, validator username, repository path, RPC URL, and real validator mount points. Keep the Stakeconomy output settings when using the community dashboard.

Do not configure `data_type = "integer"`; the emitted line contains both integer and floating-point fields.

## Migrating an existing validator

Follow the [community-dashboard migration guide](docs/installation.md). It covers backups, a side-by-side test, removal of unrestricted sudo, Telegraf validation, rollout checks, and rollback.

The collector retains the `nodemonitor` measurement but writes schema-v2 tagged series. Untagged historical data is legacy-unclassified and is intentionally excluded from normal cluster-scoped dashboard views; do not assign it retrospectively from a pubkey.

## RPC and epoch ETA behavior

The collector prefers the local validator RPC. It batches compatible JSON-RPC calls to reduce subprocess and RPC overhead.

`epochEnds` normally uses recent performance samples. If the local validator has transaction history disabled and returns no samples, the collector checks the RPC configured for the Solana CLI user and verifies its genesis hash before using it. An explicit `--performance-rpc-url` can override that source. Testnet can finally fall back to its 200 ms target slot duration; `--slot-ms` overrides the duration fallback.

## Observed Alpenglow vote inclusion

`monitor.sh` uses only Bash, `curl`, `jq`, and JSON-RPC. For `consensus=alpenglow`, it takes one finalized `getMultipleAccounts` snapshot of the selected vote account plus up to `MONITOR_ALPENGLOW_REFERENCE_COUNT` (default `8`, maximum `32`) highest-stake other vote accounts. It obtains their node identities from `getVoteAccounts` and excludes a reward-delta gap for any account that crosses `epoch_start + 8` or contains that account's leader slot from `getLeaderSchedule`.

For clean gaps, it learns each account's per-inclusion reward increment as the GCD of positive reward-accounting deltas. A one-slot clean delta proves the increment immediately; longer intervals require `MONITOR_ALPENGLOW_RATE_SAMPLES` clean positive samples (default `20`, maximum `100`) before the GCD is used. That deliberately delays initial data rather than mistaking a multi-inclusion delta for one inclusion. `alpenglowObservedExpected` is the maximum inferred inclusion count among clean, known reference gaps; `alpenglowObservedIncluded` is the selected account's inferred count; `alpenglowObservedMissed` is emitted only when both values are known. A missing baseline, invalid account encoding, leader-slot gap, epoch-delay gap, failed schedule request, or non-divisible delta is counted as `alpenglowObservedUnattributed`; it is never fabricated as zero inclusion.

The state file defaults to `$SOLANA_CONFIG_DIR/alpenglow-observed-vote-inclusion.json` and can be overridden with `MONITOR_ALPENGLOW_OBSERVED_STATE`. It must be writable by the validator user. State is written to a same-directory temporary file and renamed atomically; a stored genesis hash or vote account mismatch resets the learned baseline, so data is never compared across cluster or vote-account changes. This signal is observed/inferred reward accounting only, not certificate-direct inclusion and not direct Votor telemetry. Portable RPC-only direct Votor collection remains out of scope.

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
