# Solana Validator Monitoring Tool

*This post is Part 1 of a 3-part series about setting up proper monitoring on your Solana Validator.*

* [Part 1.](https://github.com/stakeconomy/solanamonitoring/blob/main/README.md) Solana Validator Monitoring Tool
* [Part 2.](https://github.com/stakeconomy/solanamonitoring/blob/main/How%20to%20Install%20TIG%20Stack.md) How to Install Telegraf, InfluxDB, and Grafana
* [Part 3.](https://github.com/stakeconomy/solanamonitoring/blob/main/Guidelines%20interpreting%20metrics.md) Interpreting monitoring metrics

## Introduction

### Telegraf | A Metrics Collector For InfluxDB

Telegraf can collect metrics from a wide array of inputs and write them to a wide array of outputs. It is plugin-driven for both collection and output of data so it is easily extendable. It is written in Go, which means that it is compiled and standalone binary that can be executed on any system with no need for external dependencies, or package management tools required.

Telegraf is an open-source tool. It contains over 200 plugins for gathering and writing different types of data written by people who work with that data.

### Telegraf benefits
- Easy to setup
- Minimal memory footprint
- Over 200 plugins available
- Able to send metrics to central InfluxDB over http(s) without the need of client configuration

### Architecture

![Architecture](https://i.imgur.com/xmbND94.png)

### Solana Monitoring
The solution consist of a standard telegraf installation and one bash script "monitor.sh" that will get all server performance and validator performance metrics every 30 seconds and send all the metrics to a local or remote influx database server.

![Sample Dashboard](https://i.imgur.com/2CB2F1o.png)

# Features
* Simple setup with minimal performance impact to monitor validator node.
* Sample Dashboard to import into Grafana.
* Use of community dashboard on https://metrics.stakeconomy.com possible so you don't need to setup your own monitoring system.
* Customizable Parameters. You can use your own RPC node or Solana public RPC nodes (much slower).

TBD
------
* Optimize the way how we get skip-rate. 
* Rebuild solana monitoring script as telegraf input plugin written in Go.

# Installation & Setup

A fully functional Solana Validator is required to setup monitoring. In the example below we use Ubuntu 20.04.
To get all metrics from your local Validator RPC.

In the examples below we setup the validator with user "sol" with it's home in /home/sol. It is required that the script is installed and run under that same user.
You need to install the telegraf agent on your validator nodes. 

To have full statistics that include a whole epoch, make sure that your --limit-ledger-size configuration is big enough to store a whole epoch:

```       --limit-ledger-size <SHRED_COUNT>                       Keep this amount of shreds in root slots.```

You may use 250000000 for ~1 epoch or leavy it empty to use the default. 
Using less schred's to save diskspace still works, but it will mess up your leaderslots and skiprate stats.

```
# install telegraf
cat <<EOF | sudo tee /etc/apt/sources.list.d/influxdata.list
deb https://repos.influxdata.com/ubuntu bionic stable
EOF

sudo curl -sL https://repos.influxdata.com/influxdb.key | sudo apt-key add -

sudo apt-get update
sudo apt-get -y install telegraf jq bc

sudo systemctl enable --now telegraf
sudo systemctl is-enabled telegraf
systemctl status telegraf

# make the telegraf user sudo and adm to be able to execute scripts as sol user
sudo adduser telegraf sudo
sudo adduser telegraf adm
sudo -- bash -c 'echo "telegraf ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers'

sudo cp /etc/telegraf/telegraf.conf /etc/telegraf/telegraf.conf.orig
sudo rm -rf /etc/telegraf/telegraf.conf

# make sure you are the user you run solana with . eq. su - solana
git clone https://github.com/stakeconomy/solanamonitoring/
cd solanamonitoring


```
You might need to add your local RPC endpoint like "https://localhost:8899" and/or a timezone like "Europe / Amsterdam" to the monitor.sh script if you run into issues


# Example telegraf configuration
Add the configuration file /etc/telegraf/telegraf.conf based on the example below:

Change your hostname, mountpoints to monitor, location of the monitor script and the username

```
# Global Agent Configuration
[agent]
  hostname = "mynode-mainnet" # set this to a name you want to identify your node in the grafana dashboard
  flush_interval = "15s"
  interval = "15s"

# Input Plugins
[[inputs.cpu]]
    percpu = true
    totalcpu = true
    collect_cpu_time = false
    report_active = false
[[inputs.disk]]
    ignore_fs = ["devtmpfs", "devfs"]
[[inputs.diskio]]
[[inputs.mem]]
[[inputs.net]]
[[inputs.system]]
[[inputs.swap]]
[[inputs.netstat]]
[[inputs.processes]]
[[inputs.kernel]]
[[inputs.diskio]]

# Output Plugin InfluxDB
[[outputs.influxdb]]
  database = "metricsdb"
  urls = [ "http://metrics.stakeconomy.com:8086" ] # keep this to send all your metrics to the community dashboard otherwise use http://yourownmonitoringnode:8086
  username = "metrics" # keep both values if you use the community dashboard
  password = "password"

[[inputs.exec]]
  commands = ["sudo su -c /home/solana/solanamonitoring/monitor.sh -s /bin/bash solana"] # change home and username to the useraccount your validator runs at
  interval = "5m"
  timeout = "1m"
  data_format = "influx"
  data_type = "integer"
```


Please continue to [Part 2.](https://github.com/stakeconomy/solanamonitoring/blob/main/How%20to%20Install%20TIG%20Stack.md) that was written to help you setup your own TIG (Telegraf/InfluxDB/Grafana) stack.

Stake with Stakeconomy.com validator on Solflare.
Vote Account: [GNZ1PAAS33davY4Q1BMEpZEpVBtRtGvSpcTH5wYVkkVt](https://solanabeach.io/validator/GNZ1PAAS33davY4Q1BMEpZEpVBtRtGvSpcTH5wYVkkVt)
