# Stakeconomy Solana Community Monitoring

Lightweight monitoring for Solana validators that publish host and validator metrics to the public [Stakeconomy community dashboard](https://metrics.stakeconomy.com/).

This repository intentionally focuses on three things:

- `monitor.sh`: one-minute Solana validator metrics in Influx line protocol;
- `telegraf/solana-monitoring.conf.example`: a low-cardinality, least-privilege Telegraf configuration;
- `grafana/solana-community-validator-dashboard.json`: the dashboard source used by the community service.

It is not a guide for installing a private Telegraf, time-series database, and Grafana stack.

## What is monitored

Validator metrics include status, root and vote slots, vote credits, active stake, leader slots, skipped slots, validator and cluster skip rates, commission, software version, epoch progress and ETA, cluster TPS, SOL price, identity/vote balances, cluster size, and delinquent stake.

Host metrics include total CPU, IOWait, normalized load, memory, swap, relevant filesystem utilization, network traffic/errors, UDP errors, process states, TCP states, allocated file handles, and context switches.

The dashboard uses one linked validator/system selector, automatically maps the selected validator identity to its reporting host, and supports dynamic mount/interface selectors, software-version and health timelines, mirrored receive/transmit traffic, and filters for virtual resources.

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

It must emit exactly one line beginning with `nodemonitor,pubkey=` on standard output. Integer fields have the required Influx `i` suffix; balances and percentages remain floating point. Diagnostics are written to standard error.

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

The new collector retains the existing `nodemonitor` measurement and field names, so no database migration is required.

## RPC and epoch ETA behavior

The collector prefers the local validator RPC. It batches compatible JSON-RPC calls to reduce subprocess and RPC overhead.

`epochEnds` normally uses recent performance samples. If the local validator has transaction history disabled and returns no samples, the collector checks the RPC configured for the Solana CLI user and verifies its genesis hash before using it. An explicit `--performance-rpc-url` can override that source. Testnet can finally fall back to its 200 ms target slot duration; `--slot-ms` overrides the duration fallback.

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
