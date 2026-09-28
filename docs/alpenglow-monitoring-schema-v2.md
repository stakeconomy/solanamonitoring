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
- `consensus`: `tower`, `alpenglow`, or `unknown`
- `pubkey`: validator identity
- `vote_account`: monitored vote account
- `schema`: `2`

The exact genesis hash is the collision-proof cluster identity. `cluster` is for people and Grafana selection; it is never inferred from a URL or a pubkey.

Known mapping:

- `5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp` → `mainnet-beta`, `tower`
- `4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY` → `testnet`, `alpenglow`
- `EtWTRABZaYq6iMfeYKouRu166VU2xqa1` → `devnet`, `unknown`

`SOLANA_EXPECTED_CLUSTER` and `SOLANA_EXPECTED_GENESIS` may pin a deployment. A mismatch emits a schema-v2 status-only record with `genesisMatch=0` and must not emit performance fields.

## Field rules

### Portable fields retained

`status`, `rootSlot`, `lastVote`, `activatedStake`, `commission`, balances, version, node count, epoch progress, epoch ETA, TPS, and scheduled-slot production remain collected from public RPC, but dashboards must label their source and scope honestly.

`leaderSlots`, `skippedSlots`, and skip percentages are observations from `getBlockProduction`/SlotHistory. They are not Votor participation, certificate-finality, or a universal Alpenglow-health score. The dashboard must call them scheduled-slot production / scheduled-slot absence.

### Tower-only credit fields

For `consensus=tower`, retain existing `credits`, `validatorCreditsCurrent`, and `pctVote` for compatibility and add explicit fields:

- `legacyVoteCreditsTotal`
- `legacyVoteCreditsEpoch`
- `legacyVoteCreditEfficiencyPct`

For `consensus=alpenglow` or `unknown`, omit all six credit/efficiency fields. Missing data is deliberate; it must never be emitted as zero or rendered as zero efficiency.

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
