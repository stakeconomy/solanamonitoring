# Alpenglow Monitoring Schema v2

## Problem

The shared `metricsdb` receives `nodemonitor` records from both mainnet-beta (Tower consensus) and testnet (Alpenglow). The current collector tags records only with `pubkey`, while the Grafana dashboard queries only by `pubkey`. An identity can therefore collide across clusters and pollute a single dashboard view.

The collector also treats vote-account `epochCredits` as Tower credits and emits `pctVote`; the Grafana dashboard divides it by 16 and calls it vote-credit efficiency. Alpenglow epoch-credit accounting uses lamport rewards instead of the Tower credit model, so this is false on Alpenglow clusters. Agave explicitly distinguishes Tower and Alpenglow vote/epoch-credit history. See upstream PR #12872.

## Scope

Schema v2 prevents cross-cluster mixing and removes false Tower credit claims on Alpenglow. It remains portable: it uses public JSON-RPC calls available to community validators. Sentinel-local Votor Prometheus gauges are explicitly out of scope for the community collector.

## Record identity

Every successful `nodemonitor` record must have these tags:

- `cluster`: canonical name derived from genesis (`mainnet-beta`, `testnet`, `devnet`, or `custom`)
- `genesis`: exact `getGenesisHash` result
- `consensus`: `tower`, `alpenglow`, or `unknown`, determined from `getAgGenesisCert`
- `pubkey`: validator identity
- `vote_account`: monitored vote account
- `schema`: `2`

The exact genesis hash is the collision-proof cluster identity. `cluster` is for people and Grafana selection; it is never inferred from a URL or a pubkey.

Known genesis-to-cluster mapping:

- `5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp` → `mainnet-beta`
- `4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY` → `testnet`
- `EtWTRABZaYq6iMfeYKouRu166VU2xqa1` → `devnet`

`getAgGenesisCert` is the consensus detector: a non-null certificate means `alpenglow`; a null result means `tower`; an RPC error is `unknown`. The detector is not inferred from cluster name or validator version.

## Field rules

### Portable fields retained

`status`, `rootSlot`, `lastVote`, `activatedStake`, `commission`, balances, version, node count, epoch progress, epoch ETA, TPS, and scheduled-slot production remain collected from public RPC, but dashboards must label their source and scope honestly.

`leaderSlots`, `skippedSlots`, and skip percentages are observations from `getBlockProduction`/SlotHistory. They are not Votor participation, certificate-finality, or a universal Alpenglow-health score. The dashboard must call them scheduled-slot production / scheduled-slot absence.

### Tower-only credit fields

For `consensus=tower`, retain existing `credits`, `validatorCreditsCurrent`, and `pctVote` for compatibility and add explicit fields:

- `legacyVoteCreditsTotal`
- `legacyVoteCreditsEpoch`
- `legacyVoteCreditEfficiencyPct`

For `consensus=alpenglow` or `unknown`, omit all six Tower credit/efficiency fields. Missing Tower data is deliberate; it must never be emitted as zero or rendered as zero efficiency.

For `consensus=alpenglow` only, emit `alpenglowRewardAccountingLamports` when the latest `epochCredits` tuple is a valid non-negative integer tuple `[epoch, total, previous]` with `total >= previous`. Its value is `total - previous` in lamports. Reject migration markers and malformed tuples rather than fabricating zeroes. Grafana may divide by `1e9` to display SOL, and must label it reward accounting rather than performance.

### Alpenglow observed/inferred vote inclusion

For `consensus=alpenglow`, the collector may emit these integer fields without adding tags or labels:

- `alpenglowObservedReady`
- `alpenglowObservedIncluded`
- `alpenglowObservedExpected`
- `alpenglowObservedMissed`
- `alpenglowObservedUnattributed`
- `alpenglowObservedReferences`
- `alpenglowObservedSlot`

The collector obtains immutable `getEpochSchedule` parameters and derives the epoch boundary from the exact finalized `getMultipleAccounts` snapshot slot. It considers all eligible active **current** same-cluster vote accounts from `getVoteAccounts` except the selected vote account. On a new or reset state it randomly chooses a bounded cohort, persists only its vote accounts, and reuses it on later runs; only cohort members no longer eligible are replaced. The finalized account snapshot contains the selected vote account and that cohort, while each member's current `getVoteAccounts` node identity is used for leader-gap attribution. It learns each account's reward increment per inclusion with the GCD of positive clean reward deltas. A one-slot clean delta proves the increment immediately; otherwise the collector requires `MONITOR_ALPENGLOW_RATE_SAMPLES` clean positive deltas (default `20`) before using the GCD. This prevents one multi-inclusion interval from being falsely treated as one inclusion. A gap is not clean if it crosses `epoch_start + 8`, if the account is scheduled as leader during the gap according to finalized `getLeaderSchedule`, if account data is invalid, or if schedule data is unavailable. `Expected` is the maximum inferred inclusion count among clean, known references. `Missed` is emitted only if the selected account's inferred inclusion count and `Expected` are both known.

`Unattributed` counts accounts whose current interval cannot be attributed under those rules. Unknown is omitted from `Included`, `Expected`, and `Missed`; it is never rewritten as zero. `Ready=1` only when the selected account and at least one reference have comparable inferred counts. `References` is bounded by `MONITOR_ALPENGLOW_REFERENCE_COUNT` (default `8`, maximum `32`), while `Slot` is the finalized account-snapshot context slot.

This is an **observed/inferred reward-accounting signal**, not certificate-direct inclusion and not direct Votor telemetry. Portable RPC-only direct Votor collection is explicitly out of scope. The implementation persists a validator-user-writable state file, atomically replacing it with a same-directory temporary-file rename. It resets the cohort and baseline when the recorded genesis hash or vote account differs from the active record.

### Collector health

Add:

- `collectorUp=1`
- `genesisMatch=1`
- `productionDataOk=1` only when `getBlockProduction` succeeded

A supplemental RPC failure must not fabricate zero production fields; omit that family and emit `productionDataOk=0`.

## Grafana contract

The dashboard must select data in this order:

1. `$cluster`
2. `$genesis`
3. `$pubkey`
4. `$vote_account`

Every `nodemonitor_*` PromQL selector, including variable discovery and the validator-to-host link, must constrain `cluster`, `genesis`, `pubkey`, and where applicable `vote_account`.

The default dashboard exposes only schema-v2 tagged records. Untagged historical records are not backfilled or silently assigned to a cluster; they remain excluded because their provenance cannot be proven.

The legacy credit row is visible only for `consensus=tower`. For Alpenglow it displays an explanatory text panel rather than a made-up efficiency value.

## Non-goals

- No synthetic `sentinel_alpenglow_*` data in `monitor.sh`.
- No claim of sub-second certificate finality from a one-minute collector.
- No historical tag rewrite based only on pubkey.
