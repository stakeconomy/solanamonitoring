# Alpenglow participation and rewards from VX

The existing `monitor.sh` collector makes one additional bounded HTTP request
per collection (one minute in the supplied Telegraf profile). No extra daemon,
gRPC connection, database or local state file is required.

VX is a public, external data source. For detected Alpenglow consensus, the
collector selects `https://api.vx.tools` for the exact mainnet genesis and
`https://api.testnet.vx.tools` for the exact testnet genesis. Tower, devnet and
custom clusters do not trigger a VX request. The request contains the public
vote account and `limit=1` and uses `/epochs/participation`.

Reference: https://api.vx.tools/llms.txt (checked 2026-10-21).

## Configuration

Enabled by default on supported Alpenglow clusters. Existing Telegraf commands
continue to work; keep their one-minute interval and timeout. VX aggregates are
updated approximately every 25 seconds, so polling faster is unnecessary for
this dashboard.

- `--no-vx` / `MONITOR_VX_ENABLED=0`: disable the lookup.
- `--vx-timeout 10` / `MONITOR_VX_TIMEOUT`: positive HTTP timeout in seconds.
- `--vx-max-slot-lag 600` / `MONITOR_VX_MAX_SLOT_LAG`: positive maximum difference
  between local RPC absolute slot and the last ingested VX reward slot. This is
  a slot-based tolerance, not a fixed wall-clock duration. A source ahead by more
  than this tolerance is also rejected (the local RPC may itself be behind).

These options require no additional sudo permissions. API failures do not change
local validator status or suppress the original monitoring fields.

## Epoch and availability

The current epoch comes from the local RPC, never from the last API array item.
VX can return an admission-only row for the *next* epoch, with null ingestion
progress and zero counts. That row is not current performance or income.

The original `nodemonitor` measurement and schema=2 tags are retained; all new
fields have the `vx` prefix. Missing, malformed and stale performance/reward
values are omitted, rather than converted to zero. Genuine zero amounts remain
zero. Each optional reward has its own availability flag. A total is available
only when its voting and producer components are present and sum correctly.

| Fields (Influx names) | Meaning |
| --- | --- |
| `vxEnabled`, `vxApiUp` | Lookup enabled for this cluster/consensus; a valid current-epoch response was obtained |
| `vxDataFresh` | Response progress is within the configured local slot tolerance |
| `vxEpoch`, `vxAdmitted`, `vxComplete` | Selected epoch, admission, and whether epoch ingestion is complete |
| `vxLastIngestedSlot`, `vxSlotLag` | Latest reward slot and nonnegative local-slot lag |
| `vxMissingFooters` | Source coverage gaps; these are not validator misses |
| `vxEligibleSlots` | Slots covered by the source's reward certificates |
| `vxNotarizedSlots`, `vxSkipVoteSlots`, `vxMissedSlots` | Notarize inclusion, skip inclusion, and absent participation |
| `vxParticipationPct` | 100 × (notarize + skip) / eligible; absent for zero eligible slots |
| `vxSkipOnBlockSlots` | Skip inclusions on slots where the cluster produced a block |
| `vxReward{Voting,Producer,Total,Missed,Unpayable,OnChain}Lamports` | Per-epoch gross reward accounting, described below |
| `vxReward{Voting,Producer,Total,Missed,Unpayable,OnChain}Available` | Whether each individual reward value is usable |

VX fields are integer gauges except the floating-point participation percentage.
Counts and reward totals reset at epoch boundaries; they are not lifetime
counters. Do not sum repeated polls or apply an unqualified `rate()` to them.

The dashboard hides performance/reward values unless they match the current
local epoch and a fresh source sample. It also checks that the metric and
freshness flag have the same sample timestamp, preventing an omitted field from
being resurrected by time-series lookback. Samples older than 150 seconds are
hidden. Source freshness and missing-footer coverage are separate indicators;
a fresh but incomplete dataset can still have coverage gaps.

## What participation means

A skip vote is successful participation and counts in the numerator. It is not
the old Tower meaning of a missed vote. A missing inclusion does not prove that
a validator was offline: its vote may have arrived late or been omitted by the
producer. The metric measures certificate inclusion, not all messages sent.

Slots that cannot pay anyone (for example a skipped block at reward slot + 8)
and missing source data must not become validator misses. The activation epoch
contains a Tower prefix; use VX's eligible count rather than the full epoch
length as the denominator. If `vxMissingFooters > 0`, the result is a sample with
incomplete coverage, not a complete epoch score.

## Rewards and reconciliation

All reward amounts are **cumulative within the selected epoch**, up to the last
ingested reward slot. Divide lamports by 1e9 to display SOL.

- Voting: VX-calculated gross rewards from notarize and skip inclusion.
- Producer: VX-calculated gross share for packing votes as a block producer.
- Total: voting + producer, checked by the collector.
- Missed: VX-calculated gross rewards missed through non-inclusion.
- Unpayable: VX-calculated rewards for slots that paid nobody; not validator fault.
- OnChain: VX-reported vote-account epoch reward accounting, used diagnostically.

These are before commission allocation between validator and stakers, exclude
transaction fees and Jito MEV, and are not net validator income or wallet
receipts. `OnChain` is also supplied by VX; it is not an independent local RPC
audit. No discrepancy is silently corrected or treated as confirmed lost income.

A mainnet epoch-1064 sample on 2026-10-21 reported total=4,935,698,781 lamports
versus onChain=79,056 lamports. That difference remains unexplained. The dashboard
therefore labels the rewards as VX calculations and displays total minus
on-chain accounting as a diagnostic. Epoch-boundary reconciliation must also
account for the eight-slot offset: certificate participation belongs to the
reward slot, while runtime accounting is credited in the carrying footer's epoch.

For short-window alerts, compare counter changes only within the same epoch,
with fresh samples and unchanged coverage; suppress calculations across source
outages, backfills or epoch rollover. No automated alert rules or hourly-income
estimates are installed by this integration.

## Validation and rollback

Run the repository's monitor, dashboard and Telegraf tests. Fixtures cover
supported cluster routing, next-epoch rows, missing/duplicate epochs, invalid
counts, source failures, stale and ahead-of-local samples, partial rewards,
genuine zero rewards, and contradictory totals.

Compare the current epoch's counts with the validator's VX consensus page.
Confirm the local `epoch`, `vxEpoch`, source progress and source-health cards.
Use `--no-vx` to disable the additional lookup while retaining local monitoring.
The existing installation guide's backups, least-privilege execution and full
rollback procedure still apply.
