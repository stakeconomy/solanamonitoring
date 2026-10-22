# Changelog

## 0.15.0 - unreleased

### Collector

- Separates headline values from supporting breakdowns, fixes Stat typography and reduces display precision to avoid oversized, crowded overview panels.
- Integrates Alpenglow participation and income into the compact main dashboard overview, groups reward breakdowns and collapses diagnostics and removes the three obsolete Tower vote-credit graphs.
- Adds separate VX epoch earnings: base/priority fees, validator block-revenue share, estimated MEV share and estimated total validator income before costs, with explicit missing-rate handling and no double counting of the producer bonus.
- Adds optional VX certificate participation and gross epoch reward totals within the existing collector, with bounded requests, exact cluster routing, current-epoch selection and explicit data availability.
- Adds a four-card VX overview with consensus participation/rank, fast-vote inclusion over all finalization certificates, grouped epoch rewards and next-epoch admission, with source freshness/coverage and the unresolved VX/on-chain accounting difference below.

- Added schema-v2 `cluster`, `genesis`, `consensus`, `pubkey`, and `vote_account` tags, preventing shared-database mainnet/testnet collisions.
- Detects Tower versus Alpenglow with `getAgGenesisCert`; Tower credit-efficiency fields are deliberately omitted for Alpenglow.
- Emits `alpenglowRewardAccountingLamports` only for validated Alpenglow post-migration epoch-credit tuples; malformed or migration-marker tuples are omitted.
- Adds finalized-slot freshness plus collector and scheduled-slot-production provenance fields instead of fabricating zeroes after a failed supplemental RPC batch.

- Replaced repeated Solana CLI calls with batched JSON-RPC requests.
- Added explicit RPC, identity, vote-account, timeout, performance-RPC, and slot-duration options.
- Added local, configured-CLI, cluster, and slot-duration fallbacks for epoch ETA.
- Added genesis-hash validation before using a fallback performance RPC.
- Emits typed Influx line protocol and keeps diagnostics off standard output.
- Added deterministic fixtures and regression tests.

### Dashboard

- Requires cluster, genesis, identity, and vote-account selectors for all validator metrics.
- Renamed leader/skip cards to qualified scheduled-slot production terminology and labels Tower credit efficiency as Tower-only.

- Linked validator identity and system host through one selector so validator and OS metrics cannot be mixed accidentally.
- Added dynamic filesystem and interface selectors with virtual-resource filtering.
- Added aligned software-version and validator-health timelines.
- Added balance, delinquency, skip-gap, normalized-load, and host-health views.
- Mirrored receive traffic above zero and transmit traffic below zero.
- Converted current-value panels to instant queries and capped historical query resolution.
- Removed redundant range vectors and single-host median aggregations.
- Reduced low-value CPU, process, and TCP queries.

### Operations

- Added a community-dashboard migration guide with least-privilege Telegraf execution and rollback steps.
- Removed the obsolete private TIG-stack installation guide so the repository focuses on community-dashboard participation.
- Disabled unused per-core CPU and disk-I/O ingestion in the optimized profile.
