# Changelog

## 0.15.0 - unreleased

### Collector

- Replaced repeated Solana CLI calls with batched JSON-RPC requests.
- Added explicit RPC, identity, vote-account, timeout, performance-RPC, and slot-duration options.
- Added local, configured-CLI, cluster, and slot-duration fallbacks for epoch ETA.
- Added genesis-hash validation before using a fallback performance RPC.
- Emits typed Influx line protocol and keeps diagnostics off standard output.
- Added deterministic fixtures and regression tests.

### Dashboard

- Separated validator identity and system-host selectors.
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
