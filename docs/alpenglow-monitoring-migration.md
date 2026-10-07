# Alpenglow observed-inclusion schema-v3 migration

Use three rollback-safe phases. Schema-v3 state and counters are independent of the legacy schema-v2 collector and state.

## Phase 1 — install and shadow

1. Install `scripts/alpenglow-observed-vote-inclusion-v3.sh`, the exact-argument sudoers rule, and the separate two-second Telegraf input described in [installation.md](installation.md).
2. Keep the existing one-minute `monitor.sh` input, its sudo rule, schema-v2 state, and all schema-v2 dashboard queries unchanged.
3. Run the exact production v3 command once as the `telegraf` service user, then restart Telegraf.
4. Shadow for at least 24 hours before any dashboard cutover.

The shadow gate passes only when:

- collector runtime p99 remains below `1.5s` and Telegraf reports no timeout;
- no unexplained sample gap exceeds two collection intervals;
- state survives a service restart and remains valid JSON owned by the validator user;
- VictoriaMetrics receives repeated `schema="3"` cumulative samples, including unchanged totals;
- no v3 series appears for Mainnet, Tower Testnet, unknown consensus, a mismatched identity, or a mismatched vote account;
- no invariant violation or corrupt-state error occurs.

Rollback phase 1: disable only the v3 `inputs.exec` block, restart Telegraf, and leave the v3 state file in place for diagnosis. The legacy one-minute collection remains active throughout.

## Phase 2 — dashboard cutover

After the 24-hour shadow gate passes, switch only the Alpenglow observed-inclusion panels to bounded schema-v3 selectors and ten-minute `increase()` queries. Retain:

- the legacy one-minute `monitor.sh` invocation;
- the schema-v2 sudo rule;
- both v2 and v3 state files;
- old v2 series and all v3 cumulative series.

Verify the deployed Grafana UID and authenticated datasource by reading the imported dashboard and live query results back. Confirm that current, unattributed, zero-opportunity, and stale states are distinct.

Rollback phase 2: restore the previous dashboard JSON or panel queries. Do not stop either collector and do not alter either state file.

## Phase 3 — legacy retirement

Only after phase 2 is verified against the deployed Grafana UID and authenticated datasource may a later change remove the schema-v2 Alpenglow observed-inclusion call from `monitor.sh`. That retirement is not part of the shadow installation. Keep unrelated schema-v2 `nodemonitor` metrics, old historical series, and old state untouched unless a separately reviewed migration says otherwise.

Before applying the separately reviewed retirement commit, record the exact pre-retirement revision and preserve the executable. The one-minute Telegraf `monitor.sh` command normally remains configured because it still collects all non-retired schema-v2 validator metrics; phase three removes only the legacy Alpenglow sub-collection from that script.

```bash
REPOSITORY=/home/solana/solanamonitoring
ROLLBACK_DIR=/home/solana/.local/state/solanamonitoring
sudo -u solana install -d -m 0700 "$ROLLBACK_DIR"
PRE_RETIREMENT_REVISION="$(sudo -u solana git -C "$REPOSITORY" rev-parse HEAD)"
printf '%s\n' "$PRE_RETIREMENT_REVISION" | \
  sudo -u solana tee "$ROLLBACK_DIR/PRE_RETIREMENT_REVISION" >/dev/null
sudo -u solana cp --preserve=mode,timestamps \
  "$REPOSITORY/monitor.sh" \
  "$ROLLBACK_DIR/monitor.sh.pre-alpenglow-v3-retirement"
sudo -u solana test -x "$ROLLBACK_DIR/monitor.sh.pre-alpenglow-v3-retirement"
```

After deploying the retirement revision, restart Telegraf and read back a fresh normal schema-v2 sample from the unchanged one-minute command before considering phase three complete:

```bash
sudo systemctl restart telegraf
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3 | grep -m1 '^nodemonitor,.*schema=2 '
sudo journalctl -u telegraf --since '-2 minutes' --no-pager
```

Rollback phase 3 with the recorded executable, then restart and perform the same direct sample readback. Do not reset the repository or alter v3 state:

```bash
REPOSITORY=/home/solana/solanamonitoring
ROLLBACK_DIR=/home/solana/.local/state/solanamonitoring
PRE_RETIREMENT_REVISION="$(sudo -u solana sed -n '1p' "$ROLLBACK_DIR/PRE_RETIREMENT_REVISION")"
sudo -u solana git -C "$REPOSITORY" cat-file -e "$PRE_RETIREMENT_REVISION^{commit}"
sudo -u solana test -x "$ROLLBACK_DIR/monitor.sh.pre-alpenglow-v3-retirement"
sudo -u solana git -C "$REPOSITORY" show "$PRE_RETIREMENT_REVISION:monitor.sh" | \
  sudo -u solana cmp - "$ROLLBACK_DIR/monitor.sh.pre-alpenglow-v3-retirement"
sudo -u solana cp --preserve=mode,timestamps \
  "$ROLLBACK_DIR/monitor.sh.pre-alpenglow-v3-retirement" \
  "$REPOSITORY/monitor.sh"
sudo systemctl restart telegraf
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3 | grep -m1 '^nodemonitor,.*schema=2 '
sudo journalctl -u telegraf --since '-2 minutes' --no-pager
```

Keep the v3 collector and v3 state unchanged unless v3 itself is the fault. Restore a Telegraf configuration backup only if the separately reviewed retirement changed the normally retained one-minute command.

## State and rollback invariants

Do not copy v3 counters into v2 state. Do not copy v2 interval state into v3 cumulative totals. Rollback never deletes either state file or rewrites historical counters. Identity or vote-account rotation must be performed by changing the explicit production command only after the new identity-to-vote relationship can be proved by RPC; the v3 collector then creates a fresh zero-total state after validation.
