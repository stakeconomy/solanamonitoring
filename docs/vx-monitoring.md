# Alpenglow participation and rewards from VX

The existing `monitor.sh` collector makes two additional bounded HTTP requests
per collection (one minute in the supplied Telegraf profile). No extra daemon,
gRPC connection, database or local state file is required.

VX is a public, external data source. For detected Alpenglow consensus, the
collector selects `https://api.vx.tools` for the exact mainnet genesis and
`https://api.testnet.vx.tools` for the exact testnet genesis. Tower, devnet and
custom clusters do not trigger a VX request. Both requests contain the public
vote account and `limit=1`: `/epochs/participation` and `/epochs/earnings`.
Each has its own timeout (default 10 seconds, at most 20 seconds combined).
Either endpoint can fail independently without suppressing local monitoring.

Reference: https://api.vx.tools/llms.txt (checked 2026-10-21).

## Configuration

Enabled by default on supported Alpenglow clusters. Existing Telegraf commands
continue to work; keep their one-minute interval and timeout. VX aggregates are
updated approximately every 25 seconds, so polling faster is unnecessary for
this dashboard.

- `--no-vx` / `MONITOR_VX_ENABLED=0`: disable both lookups.
- `--vx-timeout 10` / `MONITOR_VX_TIMEOUT`: positive HTTP timeout in seconds per request.
- `--vx-max-slot-lag 600` / `MONITOR_VX_MAX_SLOT_LAG`: positive maximum difference
  between local RPC absolute slot and the last ingested VX reward slot. This is
  a slot-based tolerance, not a fixed wall-clock duration. A source ahead by more
  than this tolerance is also rejected (the local RPC may itself be behind).

These options require no additional sudo permissions. API failures do not change
local validator status or suppress the original monitoring fields.

## Epoch and availability

The current epoch comes from the local RPC, never from the last API array item.
VX can return an admission-only row for the *next* epoch, with null ingestion
progress and zero counts. That row is not current performance or income. It is exposed separately for the
Next-Epoch Admission card. Missing, duplicate or non-boolean admission records
remain unknown; explicit false produces a red "Not admitted" warning.

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
| `vxParticipationRank` | One-based VX competition rank (API rank + 1); ties shared, no inferred percentile |
| `vxFinalizedCerts`, `vxFinalizedSlots`, `vxFastFinalizedSlots` | Decoded finalization certificates, validator inclusions, and fast-path inclusions |
| `vxFastVoteInclusionPct` | 100 × fastFinalizedSlots / finalizedCerts; absent for zero/invalid/missing denominators |
| `vxNextEpochAvailable`, `vxNextEpoch`, `vxNextEpochAdmitted` | Availability and admission for local RPC epoch + 1, separate from current performance |
| `vxSkipOnBlockSlots` | Skip inclusions on slots where the cluster produced a block |
| `vxReward{Voting,Producer,Total,Missed,Unpayable,OnChain}Lamports` | Per-epoch gross reward accounting, described below |
| `vxReward{Voting,Producer,Total,Missed,Unpayable,OnChain}Available` | Whether each individual reward value is usable |

VX fields are integer gauges except the floating-point participation percentage.
The rank is a gauge with shared ties; it may refresh less frequently than counts.
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

## Four-card overview

The overview groups Consensus Participation (with rank), Fast-Vote Inclusion,
Epoch Rewards (Total, Voting, Producer bonus) and Next-Epoch Admission. Source
health, coverage, missed rewards and the accounting difference remain in the
diagnostic section underneath. Performance percentages use four decimal places;
SOL rewards use nine so a one-lamport loss is not formatted as zero.

Fast-Vote Inclusion is **100 × fastFinalizedSlots / finalizedCerts**. The denominator
is all decoded finalization certificates, not only fast certificates. VX samples
certificates carried by leaders; this is an inclusion measure, not validator
latency, a count of all votes sent, or a claim to reproduce Solcircle's formula.
The optional counts must satisfy fast <= included <= certificates. Invalid or
missing counts suppress this metric without losing participation or rewards.

Next-Epoch Admission does not depend on current-epoch admission or current vote
progress: an ineligible validator can be admitted next epoch. It requires a valid
API response, an explicit unique next-epoch record, a matching local epoch + 1,
and a recent matching collection timestamp. API failure and rollover cannot
reuse an old admission value. Its status is VX-reported, not an independent audit.

A red "Not admitted" status is an operational warning to investigate funding,
BLS registration and other eligibility conditions. It does not identify VAT as
the cause. The same card displays the existing local RPC vote-account balance;
this includes rent reserves and is not a spendable VAT balance. No fixed VAT fee
or funding threshold is invented, and no automated notification is installed.

The supplied Solcircle tooltips clarify that FAST divides by **fast certificates
only**. VX documents `finalizedCerts` as all decoded certificates and does not
expose a fast-only certificate denominator in `/epochs/participation`. Our field
is therefore named `vxFastVoteInclusionPct`, and its card Fast-Vote Inclusion;
it must not be compared directly with Solcircle FAST. Never substitute the
validator-specific `fastFinalizedSlots` as the cluster denominator.

Solcircle defines Vote Accuracy as votes matching final slot outcomes / votes
cast. VX provides included-vote counts and `skippedNotarizedSlots` (skip votes on
slots with blocks), not a separately documented complete vote/outcome accuracy
measure. The raw skip-on-produced-block count remains available; no claim of
an exact Solcircle accuracy reproduction is made.

VX separately documents producer `effectiveInclusion` via `/epochs/production`:
the average included stake share over payable leader slots, with the producer's
skipped slots counting zero and warehouse gaps excluded. This concerns collecting
other validators' votes as leader, unlike our own vote participation. It is not
implemented here because it requires another endpoint. The supplied screenshots
do not include Solcircle's Effective Inclusion tooltip.

Cluster medians/percentiles are not inferred from per-validator data; the rank
comes from the same existing API response, without another request.

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
genuine zero rewards, contradictory totals, finalization denominators, shared
rank handling and next-epoch admission/unknown/rollover cases.

Compare the current epoch's counts with the validator's VX consensus page.
Confirm the local `epoch`, `vxEpoch`, source progress and source-health cards.
Use `--no-vx` to disable the additional lookup while retaining local monitoring.
The existing installation guide's backups, least-privilege execution and full
rollback procedure still apply.


## Block revenue and estimated validator income

`/epochs/earnings` is a separate current-epoch snapshot. Select exactly one row
matching the local RPC epoch and Alpenglow consensus; never use the last row
blindly. Mainnet and testnet use their respective VX domains. The response has
no ingestion-slot watermark, so `vxEarningsApiUp=1` means a valid response was
retrieved, not that the source is independently verified as up to date.
Dashboard queries require recent collection, matching epoch, availability and
matching timestamps to prevent old omitted values reappearing via lookback.

All amounts below are cumulative integer lamports (gauge values resetting each
epoch). Prefix `vxEarnings`, suffix `Lamports`, with a companion `Available`
flag for each amount:

| Kind | Meaning |
| --- | --- |
| `BaseFees` | VX gross base fees |
| `PriorityFees` | VX gross priority fees |
| `MevTips` | Gross Jito tips before downstream deductions |
| `BlockRevenue` | VX validator share of base + priority fees at the separate block-revenue commission |
| `MevShare` | Estimated validator MEV share at the separate MEV commission |
| `EstimatedAlpenglow` | Floor of (earnings votingReward + producerBonus) × inflation commission bps / 10000 |
| `EstimatedTotal` | EstimatedAlpenglow + BlockRevenue + MevShare; unknown unless all three are available |

`vxEarningsEpoch` identifies the row. `vxEarningsInflationCommissionBps`,
`vxEarningsBlockCommissionBps` and `vxEarningsMevCommissionBps` expose valid
rates (0..10000). `vxEarningsMevRatePreviousEpoch=1` marks VX using the previous
epoch MEV rate pending the current one. Missing rates are not assumed to be
100%; zero tips with a zero share remain a genuine zero even without a rate.
Missing/invalid components remain unavailable and never produce a partial total.

The estimated total uses one earnings response for all components. It does not
add the participation endpoint rewards or `voteAccountReward` again. Alpenglow
producer bonus is subject to inflation commission; ordinary block fees use their
own commission. Values are provisional: payout rounding, effective rates, lag
and corrections can change them. MEV share is before block-builder and tip-router
fees and can overstate final proceeds. VAT, vote fees and server costs are not
subtracted: this is estimated income before costs, not net profit.

Live checks on 2026-10-22 confirmed mainnet and testnet response schemas. The
sample mainnet response had all three rates; the testnet response had null rates,
so its estimated total correctly stays unavailable. A mainnet snapshot with only
its epoch normalized supplies the earnings test fixture. Endpoint errors,
missing/duplicate/wrong-epoch rows, malformed optional amounts, missing/out-of-range
rates, previous-epoch MEV rates, true zeros and independent endpoint failures are
tested alongside dashboard query guards and transform idempotence.


## Integrated dashboard layout

The main overview follows a SolCircle-inspired two-column hierarchy using native
Grafana panels, without additional plugins. Epoch health is followed by
participation and fast-vote inclusion, then gross epoch rewards and estimated
validator income. Gross rewards show total, voting, producer bonus and missed
rewards together. Estimated income shows total and the Alpenglow, block-fee and
MEV shares, keeping gross rewards separate from validator income before costs.
Admission, leader production and balances follow directly underneath.

Income breakdown and Consensus diagnostics are collapsed by default. Expand
those rows to inspect the gross fee/MEV breakdown, source coverage and accounting
discrepancy. Tower history retains the three legacy vote-credit graphs in a
collapsed row; it is manually expandable for historical Tower periods, not
conditional auto-hiding based on the selected cluster. Under Alpenglow those
three graphs intentionally have no data. Host snapshots and historical charts
remain below the validator overview.

This adopts the app screenshot hierarchy, not unsupported SolCircle calculations:
Fast-Vote Inclusion still uses all decoded certificates, with no invented FAST,
Vote Accuracy, cluster medians or percentile comparisons. All existing identity,
epoch, freshness and availability guards are retained. Import the new dashboard
JSON to apply this presentation-only change; no collector update is needed.
Export the existing dashboard first to preserve any local customizations and
allow restoring its layout. The enhancement transform handles collapsed and
expanded exports without losing child panels or duplicating them.
