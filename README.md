# Solana Validator Monitoring Tool

Complete Solana Validator Monitoring solution to be used with Telegraf / Grafana / InfluxDB. 

The solution consist of a standard telegraf installation and one bash script "monitor.sh" that will get all server performance and validator performance metrics every 60 seconds and send all the metrics to a local or remote influx database server.

![Sample Dashboard](https://i.imgur.com/2CB2F1o.png)

# Features

* Simple setup with minimal performance impact to monitor validator node.
* Sample Dashboard to import into Grafana.
* Use of community dashboard on https://metrics.stakeconomy.com possible so you don't need to setup your own monitoring system.
* Customizable Parameters. You can use your own RPC node or Solana public RPC nodes (much slower).

TBD
------
* Optimize the way how we get skip-rate

# Installation & Setup

A fully functional Solana Validator is required to setup monitoring. In the example below we use Ubuntu 20.04.
To get all metrics from your local Validator RPC you need to add --enable-rpc-transaction-history in your validator startup script.
In the examples below we setup the validator with user "sol" with it's home in /home/sol. It is required that the script is installed and run under that same user.
You need to install the telegraf agent on your validator nodes. 

```
# install telegraf
cat <<EOF | sudo tee /etc/apt/sources.list.d/influxdata.list
deb https://repos.influxdata.com/ubuntu bionic stable
EOF

sudo curl -sL https://repos.influxdata.com/influxdb.key | sudo apt-key add -

sudo apt-get update
sudo apt-get -y install telegraf

sudo systemctl enable --now telegraf
sudo systemctl is-enabled telegraf
systemctl status telegraf

# make the telegraf user sudo and adm to be able to execute scripts as sol user
sudo adduser telegraf sudo
sudo adduser telegraf adm
sudo -- bash -c 'echo "telegraf ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers'

sudo cp /etc/telegraf/telegraf.conf /etc/telegraf/telegraf.conf.orig
sudo rm -rf /etc/telegraf/telegraf.conf

git clone https://github.com/mbroeken/solanamonitoring/
cd solanamonitoring
chmod +x monitor.sh

sudo apt install jq bc
```

# Example telegraf configuration
Add the configuration file /etc/telegraf/telegraf.conf based on the example below:

Change your hostname, mountpoints to monitor, location of the monitor script and the username

```
# Global Agent Configuration
[agent]
  hostname = "hostname" #set this to your hostname or your solana pubkey
  flush_interval = "15s"
  interval = "15s"

# Input Plugins
[[inputs.cpu]]
    percpu = true
    totalcpu = true
    collect_cpu_time = false
    report_active = false
[[inputs.disk]]
    mount_points = ["/", "/data", "/mnt/ramdisk"] #change this to your local server mountpoints
    ignore_fs = ["devtmpfs", "devfs"]
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
  database = "metricsdb"
  urls = [ "http://metrics.stakeconomy.com:8086" ] #keep this to send all your metrics to the community dashboard
  username = "metrics"
  password = "password"

[[inputs.exec]]
  commands = ["sudo su -c /home/sol/monitor.sh -s /bin/sh sol"] #change home and username to the account your validator runs
  interval = "60s"
  timeout = "30s"
  data_format = "influx"
  data_type = "integer"
```



