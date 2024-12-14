# Update Created Timestamps syntax for OpenMetrics

* **Owners:**
    * Manik Rana [@Maniktherana](https://github.com/Maniktherana)
    * Arthur Silva Sens [@ArthurSens](https://github.com/ArthurSens)
    * Bartłomiej Płotka [@bwplotka](https://github.com/bwplotka)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
    * [github.com/prometheus/prometheus/issues/14217](https://github.com/prometheus/prometheus/issues/14217) 
    * [github.com/prometheus/prometheus/issues/14823](https://github.com/prometheus/prometheus/issues/14823) 

* **Other docs or links:**
    * [github.com/prometheus/proposals/blob/main/proposals/2023-06-13_created-timestamp.md](https://github.com/prometheus/proposals/blob/main/proposals/2023-06-13_created-timestamp.md) 

>  TL;DR: We propose an updated syntax for handling created timestamps in the OpenMetrics exposition format. This syntax allows for more efficient parsing of created lines and eliminates confusion on naming metrics that support `_created` lines by placing the created timestamp inline with the metric it is attached to.

## Why

Created Timestamps (CTs) were proposed in the summer of 2023 with support for the OpenMetrics (OM) exposition format following in summer of 2024. Once CT lines could be parsed by Prometheus in OM text it felt as though the syntax could be improved upon to optimize how the parser picks up these CTs. CT lines can be characterized as followed:

* They are represented as a standalone line in the OM text exposition format 
* It is denoted with a metric name and `_created`  suffix
* It can appear immediately after its associated metric line or between other metric lines and can be placed several lines apart while sharing labels where applicable.

These characterisitics, specifically the final one means that the parser must search or "peek" ahead to find the `_created` line for a given metric with the same label set and thus, requires additional CPU/memory resources when it can be saved.

This search operation can be specifically taxing when the CT line, if it exists, is the very last line in a large MetricFamily such as that of a histogram with many buckets.

### Pitfalls of the current solution

As stated above, `_created`  lines can appear anywhere after its associated metric line. This means parser is required to store the current position of the lexer before we start searching for the created timestamp. Currently, we cache the timestamp and minimize data stored in memory. Before, we used to make a deep copy of the parser at every line whenever the `CreatedTimestamp`  function was called which lead to [Prometheus consuming Gigabytes more memory](https://github.com/prometheus/prometheus/issues/14808) than needed.

## Goals

* Prometheus can efficiently parse Created Timestamps without peeking forward.
* OpenMetrics has an updated specification with a clear and precise syntax.

### Audience

* Developers maintaining the OpenMetrics text parser.
* Users that utilize the OpenMetrics Text format with Created Timestamps enabled.

## Non-Goals

* Require backwards compatibility. While this can be a step towards an OM 2.0 this proposal only deals with created timestamps which is small subset of the specification.
* Storing CTs in metadata storage or the WAL (we're only dealing with parsing here).
* Add CT support to additional metric types like guages.

## How

## Alternatives

## Action Plan


