# Interpreting monitoring metrics

*This post is Part 3 of a 3-part series about setting up proper monitoring on your Solana Validator.*

* [Part 1.](https://github.com/stakeconomy/solanamonitoring/blob/main/README.md) Solana Validator Monitoring Tool
* [Part 2.](https://github.com/stakeconomy/solanamonitoring/blob/main/How%20to%20Install%20TIG%20Stack.md) How to Install Telegraf, InfluxDB, and Grafana
* [Part 3.](https://github.com/stakeconomy/solanamonitoring/blob/main/Guidelines%20interpreting%20metrics.md) Interpreting monitoring metrics

## Interpreting monitoring metrics

### Telegraf | A Metrics Collector For InfluxDB

Telegraf can collect metrics from a wide array of inputs and write them to a wide array of outputs. It is plugin-driven for both collection and output of data so it is easily extendable. It is written in Go, which means that it is compiled and standalone binary that can be executed on any system with no need for external dependencies, or package management tools required.

### Telegraf agent sends metrics data to InfluxDB

- Server uptime
- Server memory utilization - Used, cached, free
- CPU utilization - Load average and usage
- Number of CPU cores and each cpu utilization
- Processes - stopped, sleeping, running e.t.c
- Disk Utilization - Free and used space for / and all othe system partitions
- Disk Inodes - / and all othe partitions in the system
- Swap - usage and IO
- Disk IO - requests, bytes and time

### Metrics Explained

![Architecture](https://i.imgur.com/xmbND94.png)


