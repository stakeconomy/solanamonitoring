# Interpreting monitoring metrics

*This post is Part 3 of a 3-part series about setting up proper monitoring on your Solana Validator.*

* [Part 1.](https://github.com/stakeconomy/solanamonitoring/blob/main/README.md) Solana Validator Monitoring Tool
* [Part 2.](https://github.com/stakeconomy/solanamonitoring/blob/main/How%20to%20Install%20TIG%20Stack.md) How to Install Telegraf, InfluxDB, and Grafana
* [Part 3.](https://github.com/stakeconomy/solanamonitoring/blob/main/Guidelines%20interpreting%20metrics.md) Interpreting monitoring metrics

## Interpreting monitoring metrics

### Telegraf | A Metrics Collector For InfluxDB

Telegraf can collect metrics from a wide array of inputs and write them to a wide array of outputs. It is plugin-driven for both collection and output of data so it is easily extendable. It is written in Go, which means that it is compiled and standalone binary that can be executed on any system with no need for external dependencies, or package management tools required.

![Architecture](https://i.imgur.com/xmbND94.png)

### The Telegraf agent runs on the Validator node and sends metrics data to your InfluxDB database. 

#### Server performance metrics:
- Server uptime
- Server Load Average
- Server memory utilization - Used, cached, free
- CPU utilization
- Number of CPU cores and each cpu utilization
- Processes - stopped, sleeping, running e.t.c
- Disk Utilization - Free and used space for / and all othe system partitions
- Disk Inodes - / and all othe partitions in the system
- Open Files
- Swap - usage and IO
- Disk IO - requests, bytes and time per disk
- Disk Usage, ramdisk usage if used.

#### Solana Validator Application performance metrics:
- Validator Status. Is your validator health ok and validating
- Epoch progress
- Active Stake
- Leaderslots, missed slots and last voted slot
- Skiprate and Cluster skiprate measured from your local validator RPC.
- Solana version
- Validator fee
- Balance of your identity and vote accounts

### Metrics Explained

![Metrics-Explained](https://i.imgur.com/oTD0Uc4.png)


