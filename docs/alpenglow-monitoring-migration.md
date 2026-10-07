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

Rollback phase 3: restore the previous `monitor.sh` and its one-minute Telegraf command, restart Telegraf, and verify fresh schema-v2 samples. Keep the v3 collector and v3 state unchanged unless v3 itself is the fault.

## State and rollback invariants

Do not copy v3 counters into v2 state. Do not copy v2 interval state into v3 cumulative totals. Rollback never deletes either state file or rewrites historical counters. Identity or vote-account rotation must be performed by changing the explicit production command only after the new identity-to-vote relationship can be proved by RPC; the v3 collector then creates a fresh zero-total state after validation.
