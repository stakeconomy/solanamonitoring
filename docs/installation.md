# Migrate to the Stakeconomy community monitor

This guide upgrades an existing validator to `monitor.sh` v0.15 and the optimized Telegraf profile used by the public [Stakeconomy dashboard](https://metrics.stakeconomy.com/). It does not install a private monitoring stack.

The examples assume:

- validator user: `solana`;
- repository: `/home/solana/solanamonitoring`;
- local RPC: `http://127.0.0.1:8899`;
- Telegraf service user: `telegraf`.

Adjust these values to match the validator.

## 1. Record and back up the current setup

```bash
systemctl show telegraf --property=User --property=Group
sudo systemctl cat telegraf
sudo -ll -U telegraf

sudo cp /etc/telegraf/telegraf.conf \
  /etc/telegraf/telegraf.conf.pre-v015

cp /home/solana/solanamonitoring/monitor.sh \
  /home/solana/solanamonitoring/monitor.sh.pre-v015
```

Do not remove the backups until the new collector has run successfully for at least one epoch.

## 2. Update and test `monitor.sh`

Fetch the release as the account that owns the repository:

```bash
sudo -u solana git -C /home/solana/solanamonitoring fetch --tags origin
sudo -u solana git -C /home/solana/solanamonitoring status --short
sudo -u solana git -C /home/solana/solanamonitoring checkout v0.15.0
```

Stop if `status --short` reports local changes. Preserve or move those changes before checking out the release; do not force-reset a validator checkout.

Run the regression test and then a real collection:

```bash
sudo -u solana /home/solana/solanamonitoring/tests/test-monitor.sh

sudo -u solana /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3
```

The real collection must emit exactly one `nodemonitor,...` line. A successful line normally contains `status=0i`, a non-zero `epochEnds`, and current validator values. `solanaPrice=0` is allowed when the external price request times out.

## 3. Restrict Telegraf's sudo access

Telegraf does not need root access. Create the narrow rule with:

```bash
sudo visudo -f /etc/sudoers.d/telegraf-solana-monitor
```

Add:

```sudoers
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh
```

Remove every unrestricted legacy entry, especially:

```sudoers
telegraf ALL=(ALL) NOPASSWD:ALL
```

Validate the complete sudo configuration:

```bash
sudo chmod 0440 /etc/sudoers.d/telegraf-solana-monitor
sudo chown root:root /etc/sudoers.d/telegraf-solana-monitor
sudo visudo -c
sudo -ll -U telegraf
```

The effective output should list only `monitor.sh` running as `solana`. Test the same command Telegraf will execute:

```bash
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3
```

## 4. Migrate Telegraf

Start from `telegraf/solana-monitoring.conf.example` and change:

- `agent.hostname` to a unique, stable community-dashboard name;
- `VALIDATOR_USER` and every home-directory path;
- the actual validator mount points;
- the RPC port if it is not `8899`.

Keep these optimized defaults:

| Setting | Value | Reason |
| --- | --- | --- |
| Host collection | `15s` | Useful host resolution without excessive ingestion |
| Collector interval | `1m` | Solana metrics do not need 15-second RPC polling |
| Collector timeout | `1m` | Prevents overlapping executions |
| `percpu` | `false` | Dashboard uses `cpu-total`; avoids per-core cardinality |
| Disk collection | `1m` | Capacity changes slowly |
| Swap/process/nstat | `30s` | Sufficient for operational trends |
| `inputs.diskio` | disabled | Not used by the community dashboard |
| Jitter | enabled | Spreads writes from community validators |
| Output timeout | `5s` | Prevents a slow endpoint from blocking collection |

Install the reviewed configuration:

```bash
sudo cp /home/solana/solanamonitoring/telegraf/solana-monitoring.conf.example \
  /etc/telegraf/telegraf.conf.v015

sudoedit /etc/telegraf/telegraf.conf.v015

sudo -u telegraf telegraf \
  --config /etc/telegraf/telegraf.conf.v015 \
  --test
```

When the test succeeds, activate it:

```bash
sudo cp /etc/telegraf/telegraf.conf.v015 \
  /etc/telegraf/telegraf.conf

sudo systemctl restart telegraf
sudo journalctl -u telegraf -n 100 --no-pager
```

Do not add `data_type = "integer"`; the collector intentionally emits both integer and floating-point fields.

## 5. Verify the community dashboard

Check the journal after at least one collector interval:

```bash
sudo journalctl -u telegraf --since '-5 minutes' --no-pager
```

There should be no `inputs.exec` parsing, timeout, sudo, or output errors. Open <https://metrics.stakeconomy.com/>, select the validator identity and system hostname, and confirm fresh status, epoch, skip-rate, CPU, memory, filesystem, and network values.

Because validator identities and system hosts are independent selectors, select both explicitly after migration.

## Epoch ETA when local samples are unavailable

Validators with transaction history disabled may return an empty result for `getRecentPerformanceSamples`. The collector then checks the RPC configured for the Solana CLI user and verifies that its genesis hash matches the local validator before using its samples. Testnet finally falls back to a 200 ms target slot duration.

Use `--performance-rpc-url` to choose the fallback explicitly or `--slot-ms` to override only the final duration fallback.

## Rollback

```bash
cp /home/solana/solanamonitoring/monitor.sh.pre-v015 \
  /home/solana/solanamonitoring/monitor.sh

sudo cp /etc/telegraf/telegraf.conf.pre-v015 \
  /etc/telegraf/telegraf.conf

sudo systemctl restart telegraf
```

The v0.15 collector retains the existing `nodemonitor` measurement and field names, so rollout and rollback do not require a database migration.
