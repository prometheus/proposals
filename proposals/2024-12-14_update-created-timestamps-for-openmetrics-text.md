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

### Do nothing

Continue using the OM text format in its current state and further optimize CPU usage through PRs that build on [﻿github.com/prometheus/prometheus/issues/14823](https://github.com/prometheus/prometheus/issues/14823) . This is desirable if we wish to keep backwards compatibility but we would have to live with an inefficient solution.

### Storing CTs Using a `# HELP`-Like Syntax

In addition to the `TYPE`, `UNIT`, and `HELP` fields, we can introduce a `# CREATED` line for metrics that have an associated creation timestamp (CT). This approach allows us to quickly determine whether a CT exists for a given metric, eliminating the need for a more time-consuming search process. By parsing the `# CREATED` line, we can associate it with a specific hash corresponding to the metric's label set, thereby mapping each CT to the correct metric.

However, this method still involves the overhead of storing the CT until we encounter the relevant metric line. A more efficient solution would be to place the CT inline with the metric itself, streamlining the process and reducing the need for intermediate storage.

Furthermore the `CREATED`  line itself might look somewhat convoluted compared to `TYPE` , `UNIT` , and `HELP`  which are very human readable. This new `CREATED`  line can end up looking something like this:

```
# HELP foo Counter with and without labels to certify CT is parsed for both cases
# TYPE foo counter
# CREATED 1520872607.123; {a="b"} 1520872607.123
foo_total 17.0 1520879607.789 # {id="counter-test"} 5
foo_total{a="b"} 17.0 1520879607.789 # {id="counter-test"} 5
foo_total{le="c"} 21.0
foo_created{le="c"} 1520872621.123
foo_total{le="1"} 10.0
```

When the same MetricFamily has multiple label sets with their own CTs we'd have to cram all the timestamps with the additional labels with a delimiter in between.

## Action Plan


