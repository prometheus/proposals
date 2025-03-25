
## Your Proposal Title

* **Owners:**
  * @fionaliao
TODO: add others from delta wg

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * `<GH Issues/PRs>`

* **Other docs or links:**
  * `<Links…>`

 This design doc proposes adding native delta support to Prometheus. This means storing delta metrics without transforming to cumulative, and having functions that behave appropriately for delta metrics.

## Why

Prometheus supports the ingestion of OTEL metrics via its OTLP endpoint. Counter-like OTEL metrics (e.g. histograms, sum) can have either [cumulative or delta temporality](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality). 

However, Prometheus only supports cumulative metrics, due to its pull-based approach to collecting metrics.

Therefore, delta metrics need to be converted to cumulative ones during ingestion. The OTLP endpoint in Prometheus has an [experimental feature to convert delta to cumulative](https://github.com/prometheus/prometheus/blob/9b4c8f6be28823c604aab50febcd32013aa4212c/docs/feature_flags.md?plain=1#L167[). Alternatively, users can run the [deltatocumulative processor](https://github.com/sh0rez/opentelemetry-collector-contrib/tree/main/processor/deltatocumulativeprocessor) in their OTEL pipeline before writing the metrics to Prometheus.

Example conversion:
```
T0: 0 -> T0: 0
T1: 1 -> T1: 1
T2: 1 -> T2: 2
T3: 5 -> T3: 7
```

The benefit of the current solution is that it is simple - the cumulative code for storage and querying can be reused, and when querying, users don’t need to think about the temporality of the metrics - everything just works. However, there are downsides elaborated in the Pitfalls section below.

Prometheus' goal of becoming the best OTEL metrics backend means we should make sure to support delta metrics properly. We propose to add native support for OTEL delta metrics (i.e. metrics ingested via the OTLP endpoint). Native support means storing delta metrics without transforming to cumulative, and having functions that behave appropriately for delta metrics.

### Delta datapoints

In the [OTEL spec](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality), like cumulative metrics, a datapoint for a delta metric has a `(start,end]` time window. However, the time windows of the previous datapoint and the current datapoints do not overlap.
The `end` timestamp is referred to as `TimeUnixNano` and is mandatory. The `start` timestamp is referred to as `StartTimeUnixNano`. This second timestamp is optional, but recommended for better rate calculations and to detect gaps and overlaps in a stream. Examples where `StartTimeUnixNano` is not added include the countconnector

### Characteristics of delta metrics

Sparse metrics are more common for delta than cumulative metrics. While delta datapoints can be emitted at a regular interval, in some cases (like the OTEL SDKs), datapoints are only emitted when there is a change (e.g. if tracking request count, only send a datapoint if the number of requests in the ingestion interval > 0). This can be beneficial for the metrics producer, reducing memory usage and network bandwidth. 

Further insights and discussions on delta metrics can be found in [Chronosphere Delta Experience Report](https://docs.google.com/document/d/1L8jY5dK8-X3iEoljz2E2FZ9kV2AbCa77un3oHhariBc/edit?tab=t.0#heading=h.3gflt74cpc0y), which describes Chronosphere's experience of adding functionality to ingest OTEL delta metrics and query them back with PromQL, and also [Musings on delta temporality in Prometheus](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q).

### Pitfalls of the current solution

#### Lack of out of order support

Delta to cumulative conversion requires adding up older delta samples values with the current delta value to get the current cumulative value, so deltas that arrive out of order cannot be added without rewriting newer samples that were already ingested.

As suggested in an [earlier delta doc](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q), a delay could be added to collect all the deltas within a certain time period before converting them to cumulative. This means a longer delay before metrics are queryable, so would not be suitable for long out of order time windows.

#### No added value to conversion

The benefit of cumulative metrics is that they’re resilient to data loss - if a sample is dropped, the next sample will still include the count from the previous sample. With delta metrics, if a sample is dropped, its data is just lost. Converting from delta to cumulative doesn’t improve resiliency as the data is already lost before it becomes a cumulative metric. 

Cumulative metrics are usually converted into deltas during querying (this is part of what rate() and increase() do), so converting deltas to cumulative is wasteful if they’re going to be converted back into deltas on read.

#### Conversion is stateful

Converting from delta to cumulative requires knowing previous values of the same series, so it’s stateful. Users may be unwilling to run stateful processes on the client-side (like the deltatocumulative processor). This is improved with doing the delta to cumulative conversion within the Prometheus OTLP endpoint, as that means there’s only one application that needs to maintain state (Prometheus is stateful anyway).

State becomes more complex in distributed cases - if there are multiple OTEL collectors running, or data being replicated to multiple Prometheus instances.

#### Values written aren’t the same as the values read
Cumulative metrics usually need to be wrapped in a `rate()` or `increase()` etc. call to get a useful result. However, it could be confusing, especially to newcomers to Prometheus, that when querying just the metric without any functions, the returned value is not the same as the ingested value.

#### Does not handle sparse metrics well
As mentioned in Background, sparse metrics are more common with delta. This can interact awkwardly with `rate()` - the `rate()` function in Prometheus does not work with only a single datapoint in the range, and assumes even spacing between samples. There is more discussion on this in the Querying deltas section.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

• Allow OTEL delta metrics to be ingested via the OTLP endpoint and stored as-is
• Support for all OTEL metric types that can have delta temporality (sums, histograms, exponential histograms)
• Queries behave appropriately for delta metrics

### Audience

This document is for Prometheus server maintainers, PromQL maintainers, and Prometheus users interested in delta ingestion.

## Non-Goals

* Support for ingesting delta metrics via other means (e.g. remote-write)
* Support for non-monotonic sums

These may come in later iterations of delta support, however.

## How

### Ingesting deltas

#### Storing samples
When an OTLP sample has its aggregation temporality set to delta, write its value at `TimeUnixNano`. 

TODO: start time nano injection

For the initial implementation, reuse existing chunk encodings. 

Currently the counter reset behaviour for cumulative native histograms is to cut a new chunk if a counter reset is detected. If a value in a bucket drops, that counts as a counter reset. As delta samples don’t build on top of each other, there could be many false counter resets detected and cause unnecessary chunks to be cut. Therefore a new counter reset hint/header is required, to indicate the cumulative counter reset behaviour for chunk cutting should not apply.

##### Alternatives

###### CreatedTimestamp per sample
If `StartTimeUnixNano` is set for a delta counter, it should be stored in the CreatedTimestamp field of the sample. The CreatedTimestamp field does not exist yet, but there is currently an effort towards adding it for cumulative counters ([PR](https://github.com/prometheus/prometheus/pull/16046/files)), and can be reused for deltas. Having the timestamp and the start timestamp stored in a sample means that there is the potential to detect overlaps between delta samples (indicative of multiple producers sending samples for the same series), and help with more accurate rate calculations.

###### Treat as gauge
To avoid introducing a new type, deltas could be represented as gauges instead and the start time ignored.

This could be confusing as gauges are usually used for sampled data (for example, in OTEL: "Gauges do not provide an aggregation semantic, instead “last sample value” is used when performing operations like temporal alignment or adjusting resolution.”) rather than data that should be summed/rated over time. 

###### Treat as “mini-cumulative”
Deltas can be thought of as cumulative counters that reset after every sample. So it is technically possible to ingest as cumulative and on querying just use the cumulative functions. 

This requires CT-per-sample to be implemented. Just zero-injection of StartTimeUnixNano would not work all the time. If there are samples at consecutive intervals, the StartTimeUnixNano for a sample would be the same as the TimeUnixNano for the preceding sample and cannot be injected.

Functions will not take into account delta-specific characteristics. The OTEL SDKs only emit datapoints when there is a change in the interval. rate() assumes samples in a range are equally spaced to figure out how much to extrapolate, which is less likely to be true for delta samples.

This also does not work for samples missing StartTimeUnixNano.

###### Convert to rate on ingest
Convert delta metrics to per-second rate by dividing the sample value with (`TimeUnixName` - `StartTimeUnixNano`) on ingest, and also append `:rate` to the end of the metric name (e.g. `http_server_request_duration_seconds` -> `http_server_request_duration_seconds:rate`). So the metric ends up looking like a normal Prometheus counter that was rated with a recording rule.

The difference is that there is no interval information in the metric name (like :rate1m) as there is no guarantee that the interval from sample to sample stays constant.

To averages rates over more than the original collection interval, a new time-weighted average function is required to accommdate cases like the collection interval changing and having a query range which isn't a multiple of the interval.

This would also require zero timestamp injection or CT-per-sample for better rate calculations.

Users might want to convert back to original values (e.g. to sum the original values over time). It can be difficult to reconstruct the original value if the start timestamp is far away (as there are probably limits to how far we could look back). Having CT-per-sample would help in this case, as both the StartTimeUnixNano and the TimeUnixNano would be within the sample. However, in this case it is trivial to convert between the rated and unrated count, so there is no additional benefit of storing as the calculated rate. In that case, we should prefer to store the original value as that would cause less confusion to users who look at the stored values.

This also does not work for samples missing StartTimeUnixNano.

#### Distinguishing between delta and cumulative metrics

There should be a way to distinguish between delta and cumulative metrics. This would allow the query engine to apply different behaviour depending on the metric type. Users should also be able to see the temporality of a metric, which is useful for understanding the metric and for debugging.

Our suggestion is to build on top of the [proposal to add type and unit metadata labels to metrics](https://github.com/prometheus/proposals/pull/39/files). The `__type__` label will be extended with additional delta types for any counter-like types (e.g. `delta_counter`, `delta_histogram`). The original types (e.g. `counter`) will indicate cumulative temporality.

When ingesting a delta metric via the OTLP endpoint, the type will be added as a label.

A con of this approach is that querying for all counter types or all delta series is less efficient - regex matchers like `__type__=~”(delta_counter|counter)” or `__type__=~”delta_.*”` would have to be used. However, this does not seem like a particularly necessary use case to optimise for.

##### Alternatives
###### New `__temporality__` label

A new `__temporality__` label could be added instead.

However, not all metric types should have a temporality (e.g. gauge). Having `delta_` as part of the type label enforces that only specific metric types can have temporality. Otherwise, additional label error checking would need to be done to make sure `__temporality__` is only added to specific types.

###### Metric naming convention

Have a convention for naming metrics e.g. appending `_delta_counter` to a metric name. This could make the temporality more obvious at query time. However, assuming the type and unit metadata proposal is implemented, having the temporality as part of a metadata label would be more consistent than having it in the metric name.

#### Remote write
Remote write support is a non-goal for the initial implementation to reduce its scope. However, the current design ends up partially supporting ingesting delta metrics via remote write. This is because a label will be added to indicate the temporality of the metric and used during querying, and therefore can be added by remote write. However, there is currently no equivalent to StartTimeUnixNano per sample in remote write.

For the initial implementation, there should be a documented warning that deltas are not _properly_ supported with remote write yet.

#### Scraping

No scraped metrics should have delta temporality as there is no additional benefit over cumulative in this case. To produce delta samples from scrapes, the application being scraped has to keep track of when a scrape is done and resetting the counter. If the scraped value fails to be written to storage, the application will not know about it and therefore cannot correctly calculate the delta for the next scrape.

Federation allows a Prometheus server to scrape selected time series from another Prometheus server. There are problems with exposing a delta metric when federating. If the current value of the delta series is exposed directly, data can be incorrectly collected if the ingestion interval is not the same as the scrape interval for the federate endpoint. The alternative is to convert the delta metric to a cumulative one, which has issues detailed above. Therefore, delta metrics will be filtered out from metrics being federated.




Explain the full overview of the proposed solution. Some guidelines:

* Make it concise and **simple**; put diagrams; be concrete, avoid using “really”, “amazing” and “great” (:
* How you will test and verify?
* How you will migrate users, without downtime. How we solve incompatibilities?
* What open questions are left? (“Known unknowns”)

## Alternatives

The section stating potential alternatives. Highlight the objections reader should have towards your proposal as they read it. Tell them why you still think you should take this path [[ref](https://twitter.com/whereistanya/status/1353853753439490049)]

1. This is why not solution Z...

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
