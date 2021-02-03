# Monitoring Solana Validator | How to Install your own TIG Monitoring Stack 
(Telegraf, InfluxDB, and Grafana)

This post describes howto setup your own local monitoring setup

*This post is Part 2 of a 3-part series about setting up proper monitoring on your Solana Validator.*

* [Part 1.](https://github.com/stakeconomy/solanamonitoring/blob/main/README.md) Solana Validator Monitoring Tool
* [Part 2.](https://github.com/stakeconomy/solanamonitoring/blob/main/How%20to%20Install%20TIG%20Stack.md) How to Install Telegraf, InfluxDB, and Grafana
* [Part 3.](https://github.com/stakeconomy/solanamonitoring/blob/main/Guidelines%20interpreting%20metrics.md) Interpreting monitoring metrics

## Installation & Setup

We are going to setup a TIG monitoring stack for your solana infrastructure. So you can collects perofrmance metrics from your servers and applications running.

*Telegraf* - Data collector written in Go for collecting, processing, and aggregating and writting metrics. Its a plugin driven tool, we will use a few plugins while implementing our use case.
*InfluxDB* - Scalable time series database for metrics, events and real-time analytics.
*Grafana* - Data visualization and exploration tool. It lets you create graphs and dashboards based on data from various data sources (InfluxDB, Prometheus, etc.)


# Setup
Setup a new Ubuntu 20.04 VM (2vCPU / 4GB vRAM) with a static ipv4 address.


![TIG Stack](https://hackernoon.com/hn-images/0*Aw1A7GHp8-KMHpWY.)

```
# go root
sudo su -

# install telegraf
# First, install the required dependencies using the following command:
apt-get install gnupg2 software-properties-common -y

# Next, import the GPG key with the following command:
wget -qO- https://repos.influxdata.com/influxdb.key | apt-key add -

#N ext, add the InfluxData repository with the following command:
source /etc/lsb-release
echo "deb https://repos.influxdata.com/${DISTRIB_ID,,} ${DISTRIB_CODENAME} stable" | tee /etc/apt/sources.list.d/influxdata.list

# update respository and install telegraf
sudo apt-get update
sudo apt-get -y install telegraf

# enable and start telegraf
systemctl enable --now telegraf
systemctl start telegraf

# verify status
systemctl status telegraf

# now install InfluxDB
apt-get install influxdb -y

# start InfluxDB and enable at start
systemctl enable --now influxdb
systemctl start influxdb

# install Grafana

#First, import the Grafana key with the following command:
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -

# add the Grafana repository with the following command:
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"

# Update and install Grafana
apt-get update -y
apt-get install grafana -y

# reload the systemd daemon with the following command:
systemctl daemon-reload

# start grafana at boot time
systemctl enable --now grafana-server
systemctl start grafana-server

# verify the status of the Grafana service with the following command:
systemctl status grafana-server

# Configure InfluxDB
# you will need to configure the InfluxDB database to store the metrics collected by Telegraf agent. First, connect the InfluxDB with the following command:

influx
> create database telegraf
> use telegraf
> create user telegraf with password 'password'
> grant all on telegraf to telegraf

> create database metricsdb
> use metricsdb
> create user metrics with password 'password'
> grant WRITE on metricsdb to metrics
> grant all on metricsdb to telegraf

# reset admin password grafana
grafana-cli admin reset-admin-password password
```

Your newly installed TIG stack also has it's own telegraf agent that you need to configure to point to your local InfluxDB;
```
# Global Agent Configuration
[agent]
  hostname = "hostname" # set this to your hostname
  flush_interval = "15s"
  interval = "15s"

# Input Plugins
[[inputs.cpu]]
    percpu = true
    totalcpu = true
    collect_cpu_time = false
    report_active = false
[[inputs.disk]]
    ignore_fs = ["tmpfs", "devtmpfs", "devfs"]
[[inputs.io]]
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
  database = "telegraf"
  urls = [ "http://127.0.0.1:8086" ]
  username = "telegraf"
  password = "password"

```
Point your browser to http://server-ipdres:3000, you should see the newly installed Grafana Dashboard.

The default credential is admin with password admin. You might want to change this as soon as you can.


In [Part 3.](https://github.com/stakeconomy/solanamonitoring/blob/main/Guidelines%20interpreting%20metrics.md) you can read how to interpret all metrics
