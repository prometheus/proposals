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
* Developers maintaining client libraries.
* Users that utilize the OpenMetrics Text format with Created Timestamps enabled.

## Non-Goals

* Require backwards compatibility. While this can be a step towards an OM 2.0 this proposal only deals with created timestamps which is small subset of the specification.
* Storing CTs in metadata storage or the WAL (we're only dealing with parsing here).
* Add CT support to additional metric types like guages.

## How

We store the Created Timestamp inline with the metric it is attached to and we remove `_created` lines. This will allow the parser to immediately associate the CT with the metric without having to search for it. For counters its straightforward as we can just add the timestamp after the metric value like an exemplar. To separate it from a traditional timstamp we can prefix the created timestamp with something like `ct@`, although this portion of the syntax is not final and can be changed. Furthermore, we can order the created timestamp such that it is after the metric value + timestamp and before an exemplar.

Lets look at some examples to illustrate the difference.

### Counters

```
# HELP foo Counter with and without labels to certify CT is parsed for both cases
# TYPE foo counter
foo_total 17.0 1520879607.789 ct@1520872607.123 # {id="counter-test"} 5
foo_total{a="b"} 17.0 1520879607.789 ct@1520872607.123 # {id="counter-test"} 5
foo_total{le="c"} 21.0 ct1520872621.123
foo_total{le="1"} 10.0
```

vs the current syntax:

```
# HELP foo Counter with and without labels to certify CT is parsed for both cases
# TYPE foo counter
foo_total 17.0 1520879607.789 # {id="counter-test"} 5
foo_created 1520872607.123
foo_total{a="b"} 17.0 1520879607.789 # {id="counter-test"} 5
foo_created{a="b"} 1520872607.123
foo_total{le="c"} 21.0
foo_created{le="c"} 1520872621.123
foo_total{le="1"} 10.0
```

### Summaries and Histograms

Summaries and histograms are a bit more complex as they have quantiles and buckets respectively. Moreoever, there is no defacto line like in a counter where we can place the CT. Thus, we can opt to place the CT on the first line of the metric with the same label set. We can then cache this timestamp with a hash of the label set and use it for all subsequent lines with the same label set. This is something we somewhat do already with the current syntax.

A diff example (for brevity) of a summary metric with current vs proposed syntax:

```diff
# HELP rpc_durations_seconds RPC latency distributions.
# TYPE rpc_durations_seconds summary
+rpc_durations_seconds{service="exponential",quantile="0.5"} 7.689368882420941e-07 ct@1.7268398130168908e+09
-rpc_durations_seconds{service="exponential",quantile="0.5"} 7.689368882420941e-07
rpc_durations_seconds{service="exponential",quantile="0.9"} 1.6537614174305048e-06
rpc_durations_seconds{service="exponential",quantile="0.99"} 2.0965499063061924e-06
rpc_durations_seconds_sum{service="exponential"} 2.0318666372575776e-05
rpc_durations_seconds_count{service="exponential"} 22
-rpc_durations_seconds_created{service="exponential"} 1.7268398130168908e+09
```

With the current syntax `_created` line can be anywhere after the `quantile` lines. A histogram would look similar to the summary but with `le` labels instead of `quantile` labels.

Another option is to simply place the CT on every line of a summary or histogram metric. This would be more verbose but would be more explicit and easier to parse and avoids storing the CT completely:

```
# HELP rpc_durations_seconds RPC latency distributions.
# TYPE rpc_durations_seconds summary
+rpc_durations_seconds{service="exponential",quantile="0.5"} 7.689368882420941e-07 ct@1.7268398130168908e+09
rpc_durations_seconds{service="exponential",quantile="0.9"} 1.6537614174305048e-06 ct@1.7268398130168908e+09
rpc_durations_seconds{service="exponential",quantile="0.99"} 2.0965499063061924e-06 ct@1.7268398130168908e+09
rpc_durations_seconds_sum{service="exponential"} 2.0318666372575776e-05 ct@1.7268398130168908e+09
rpc_durations_seconds_count{service="exponential"} 22 ct@1.7268398130168908e+09
```

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
# CREATED 1520872607.123; {a="b"} 1520872607.123; {le="c"} 1520872621.123
foo_total 17.0 1520879607.789 # {id="counter-test"} 5
foo_total{a="b"} 17.0 1520879607.789 # {id="counter-test"} 5
foo_total{le="c"} 21.0
foo_total{le="1"} 10.0
```

When the same MetricFamily has multiple label sets with their own CTs we'd have to cram all the timestamps with the additional labels with a delimiter in between.

## Action Plan

In no particular order:

* [ ] Update the OpenMetrics specification to include the new syntax for Created Timestamps.
* [ ] Update Prometheus's OpenMetrics text parser to support the new syntax.
* [ ] Update tooling and libraries that expose OpenMetrics text. 
