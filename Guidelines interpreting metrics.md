# Monitoring Solana validator performance metrics
*This post is Part 2 of a 3-part series about monitoring your Solana Validator. [Part 1.] was written  to help you setup monitoring on your node.

## Where metrics come from

### Telegraf | A Metrics Collector For InfluxDB

Telegraf can collect metrics from a wide array of inputs and write them to a wide array of outputs. It is plugin-driven for both collection and output of data so it is easily extendable. It is written in Go, which means that it is compiled and standalone binary that can be executed on any system with no need for external dependencies, or package management tools required.

Telegraf is an open-source tool. It contains over 200 plugins for gathering and writing different types of data written by people who work with that data.

#### Telegraf benefits
- easy to setup
- Minimal memory footprint
- Over 200 plugins available
- Able to send metrics to central InfluxDB without the need of client configuration

#### Architecture

[![CPU per host](https://dev.stakeconomy.com/wp-content/uploads/2021/01/telegraf-influxdb.png)](https://stakeconomy.com/wp-content/uploads/2021/01/telegraf-influxdb.png)

