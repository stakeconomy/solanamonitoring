# Installation & Setup

How to Install TIG Stack (Telegraf, InfluxDB, and Grafana) is described below
Setup a new Ubuntu 20.04 VM (2vCPU / 4GB vRAM) with a static ipv4 address.

```
go root
sudo su -


# install telegraf
# First, install the required dependencies using the following command:
apt-get install gnupg2 software-properties-common -y

# Next, import the GPG key with the following command:
wget -qO- https://repos.influxdata.com/influxdb.key | apt-key add -

#Next, add the InfluxData repository with the following command:
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

#start InfluxDB and enable at start
systemctl enable --now influxdb
systemctl start influxdb

#install Grafana
First, import the Grafana key with the following command:

wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -

add the Grafana repository with the following command:

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

create telegraf users


# reset admin password grafana
grafana-cli admin reset-admin-password password
```
