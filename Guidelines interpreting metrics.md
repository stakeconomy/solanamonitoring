# Interpreting community-dashboard metrics

This guide explains the validator and host metrics shown on the public [Stakeconomy community dashboard](https://metrics.stakeconomy.com/). See the [project README](README.md) to join the dashboard or migrate an existing validator.

## Interpreting monitoring metrics

### Telegraf | A Metrics Collector For InfluxDB

Telegraf can collect metrics from a wide array of inputs and write them to a wide array of outputs. It is plugin-driven for both collection and output of data so it is easily extendable. It is written in Go, which means that it is compiled and standalone binary that can be executed on any system with no need for external dependencies, or package management tools required.

![Architecture](https://i.imgur.com/xmbND94.png)

### The Telegraf agent runs on the Validator node and sends metrics data to your InfluxDB database. 

### Metrics Explained

#### Server performance metrics:
- Server uptime
- Server Load Average
- Server memory utilization - Used, cached, free
- CPU utilization
- Normalized load and total CPU utilization
- Total, running, blocked, and zombie processes
- Disk utilization for relevant validator mount points
- Open Files
- Swap usage
- Receive/transmit traffic, packet errors, drops, and UDP errors

#### Solana Validator Application performance metrics:
- Validator Status. Is your validator health ok and validating
- Epoch progress
- Active Stake
- Leaderslots, missed slots and last voted slot
- Skiprate and Cluster skiprate measured from your local validator RPC.
- Solana version and version-change timeline
- Validator fee
- Balance of your identity and vote accounts
- Vote-credit efficiency and cluster delinquent stake

### Things you should be looking for in your grafana dashboard:
To have a good performing server and validator, all the different metrics in the dashboard should be in it's best state. When one of the components in the table below if in a red state. the rest of the server would suffer from it and will probably result in high skiprate or a very short NVMe disk life. depending on what's going on.

I have put most metrics in a detailed table, the normal and alarm table states what normal and alarm values are + some details on what to do when numbers look bad.


| metric  | normal | alarm | details|
|---------|--------|-------|--------|
|Load / CPU| <70% | sustained >100% | The dashboard normalizes five-minute load by logical CPU count. Above 100% means more runnable or uninterruptible tasks than logical CPUs. Correlate it with CPU, IOWait, and blocked processes.|
|Memory usage| stable with headroom | sustained pressure plus swap growth | Linux intentionally uses free RAM as page cache. Judge memory together with swap and application behavior instead of treating cache as wasted memory.|
|IOWait | host baseline, usually low | sustained increase from baseline | IOWait means CPUs were idle while at least one I/O operation was outstanding; it is not disk utilization. Correlate it with skip-rate changes, blocked processes, and storage telemetry.|
|Disk usage| <70% | >85% | Keep capacity for ledger growth, snapshots, and database compaction. The dashboard excludes package, runtime, container, and `/var/lib` mounts from validator capacity panels.|
|Swap usage| zero or stable | growing during validator load | Non-zero allocated swap is less important than active swap pressure. Sustained growth with latency or skips indicates memory pressure.|
|Status| Validating | Delinquent or monitor/RPC error | The health timeline distinguishes validator delinquency from collector or RPC failures.|
|Active Stake| your stake | 0 | This metric should show your active stake.|
|Last slot voted| | | Metric should show the last slot your validator has voted on. This value should progress every 15-30 seconds.|
|Skip-rate gap| close to 0 percentage points | persistently above the cluster | Compare validator skip rate with the cluster rate. A relative regression is more actionable than one universal absolute threshold because network conditions and epoch stage vary. Correlate changes with the version timeline, IOWait, load, and traffic.|
|Vote-credit efficiency| close to 100% | sustained decline | Shows earned timely vote credits relative to the theoretical maximum. Confirm a decline against validator status and network errors.|


![Metrics-Explained](https://i.imgur.com/oTD0Uc4.png)
