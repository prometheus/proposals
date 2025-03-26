
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

Prometheus supports the ingestion of OTEL metrics via its OTLP endpoint. Counter-like OTEL metrics (e.g. histograms, sum) can have either [cumulative or delta temporality](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality). However, Prometheus only supports cumulative metrics, due to its pull-based approach to collecting metrics.

Therefore, delta metrics need to be converted to cumulative ones during ingestion. The OTLP endpoint in Prometheus has an [experimental feature to convert delta to cumulative](https://github.com/prometheus/prometheus/blob/9b4c8f6be28823c604aab50febcd32013aa4212c/docs/feature_flags.md?plain=1#L167[). Alternatively, users can run the [deltatocumulative processor](https://github.com/sh0rez/opentelemetry-collector-contrib/tree/main/processor/deltatocumulativeprocessor) in their OTEL pipeline before writing the metrics to Prometheus. 

Tthe cumulative code for storage and querying can be reused, and when querying, users don’t need to think about the temporality of the metrics - everything just works. However, there are downsides elaborated in the Pitfalls section below. 

Prometheus' goal of becoming the best OTEL metrics backend means we should support delta metrics properly. 

We propose to add native support for OTEL delta metrics (i.e. metrics ingested via the OTLP endpoint). Native support means storing delta metrics without transforming to cumulative, and having functions that behave appropriately for delta metrics.

### Delta datapoints

In the [OTEL spec](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality), like cumulative metrics, a datapoint for a delta metric has a `(start,end]` time window. However, the time windows of delta datapoints do not overlap.

The `end` timestamp is called  `TimeUnixNano` and is mandatory. The `start` timestamp is called `StartTimeUnixNano`. `StartTimeUnixNano` timestamp is optional, but recommended for better rate calculations and to detect gaps and overlaps in a stream.

### Characteristics of delta metrics

Sparse metrics are more common for delta than cumulative metrics. While delta datapoints can be emitted at a regular interval, in some cases (like the OTEL SDKs), datapoints are only emitted when there is a change (e.g. if tracking request count, only send a datapoint if the number of requests in the ingestion interval > 0). This can be beneficial for the metrics producer, reducing memory usage and network bandwidth. 

Further insights and discussions on delta metrics can be found in [Chronosphere Delta Experience Report](https://docs.google.com/document/d/1L8jY5dK8-X3iEoljz2E2FZ9kV2AbCa77un3oHhariBc/edit?tab=t.0#heading=h.3gflt74cpc0y), which describes Chronosphere's experience of adding functionality to ingest OTEL delta metrics and query them back with PromQL, and also [Musings on delta temporality in Prometheus](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q).

### Pitfalls of the current solution

#### Lack of out of order support

Delta to cumulative conversion requires adding up older delta samples values with the current delta value to get the current cumulative value, so deltas that arrive out of order cannot be added without rewriting newer samples that were already ingested.

As suggested in an [earlier delta doc](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q), a delay could be added to collect all the deltas within a certain time period before converting them to cumulative. This means a longer delay before metrics are queryable.

#### No added value to conversion

Cumulative metrics are resilient to data loss - if a sample is dropped, the next sample will still include the count from the previous sample. With delta metrics, if a sample is dropped, its data is just lost. Converting from delta to cumulative doesn’t improve resiliency as the data is already lost before it becomes a cumulative metric. 

Cumulative metrics are usually converted into deltas during querying (this is part of what `rate()` and `increase()` do), so converting deltas to cumulative is wasteful if they’re going to be converted back into deltas on read.

#### Conversion is stateful

Converting from delta to cumulative requires knowing previous values of the same series, so it’s stateful. Users may be unwilling to run stateful processes on the client-side (like the deltatocumulative processor). This is improved with doing the delta to cumulative conversion within the Prometheus OTLP endpoint, as that means there’s only one application that needs to maintain state (Prometheus is stateful anyway).

State becomes more complex in distributed cases - if there are multiple OTEL collectors running, or data being replicated to multiple Prometheus instances.

#### Values written aren’t the same as the values read

Cumulative metrics usually need to be wrapped in a `rate()` or `increase()` etc. call to get a useful result. However, it could be confusing when querying just the metric without any functions, the returned value is not the same as the ingested value.

#### Does not handle sparse metrics well
As mentioned in Background, sparse metrics are more common with delta. This can interact awkwardly with `rate()` - the `rate()` function in Prometheus does not work with only a single datapoint in the range, and assumes even spacing between samples.

TODO: would intermittent be a better word to describe this behaviour?

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow OTEL delta metrics to be ingested via the OTLP endpoint and stored as-is
* Support for all OTEL metric types that can have delta temporality (sums, histograms, exponential histograms)
* Queries behave appropriately for delta metrics

### Audience

This document is for Prometheus server maintainers, PromQL maintainers, and Prometheus users interested in delta ingestion.

## Non-Goals

* Support for ingesting delta metrics via other means (e.g. remote-write)
* Support for non-monotonic sums

These may come in later iterations of delta support, however.

## How

### Ingesting deltas
When an OTLP sample has its aggregation temporality set to delta, write its value at `TimeUnixNano`. 

TODO: start time nano injection
TODO: move the CT-per-sample here as the eventual goal

If `StartTimeUnixNano` is set for a delta counter, it should be stored in the CreatedTimestamp field of the sample. The CreatedTimestamp field does not exist yet, but there is currently an effort towards adding it for cumulative counters ([PR](https://github.com/prometheus/prometheus/pull/16046/files)), and can be reused for deltas. Having the timestamp and the start timestamp stored in a sample means that there is the potential to detect overlaps between delta samples (indicative of multiple producers sending samples for the same series), and help with more accurate rate calculations.

### Chunks
For the initial implementation, reuse existing chunk encodings. 

Currently the counter reset behaviour for cumulative native histograms is to cut a new chunk if a counter reset is detected. If a value in a bucket drops, that counts as a counter reset. As delta samples don’t build on top of each other, there could be many false counter resets detected and cause unnecessary chunks to be cut. Therefore a new counter reset hint/header is required, to indicate the cumulative counter reset behaviour for chunk cutting should not apply.

### Distinguishing between delta and cumulative metrics

We need to be able to distinguish between delta and cumulative metrics. This would allow the query engine to apply different behaviour depending on the metric type. Users should also be able to see the temporality of a metric, which is useful for understanding the metric and for debugging.

Our suggestion is to build on top of the [proposal to add type and unit metadata labels to metrics](https://github.com/prometheus/proposals/pull/39/files). The `__type__` label will be extended with additional delta types for any counter-like types (e.g. `delta_counter`, `delta_histogram`). The original types (e.g. `counter`) will indicate cumulative temporality. (Note: type metadata might become native series information rather than labels; if that happens, we'd use that for indicating the delta types instead of labels.)

When ingesting a delta metric via the OTLP endpoint, the type will be added as a label.

A downside is that querying for all counter types or all delta series is less efficient - regex matchers like `__type__=~”(delta_counter|counter)”` or `__type__=~”delta_.*”` would have to be used. However, this does not seem like a particularly necessary use case to optimise for.

### Remote write

Remote write support is a non-goal for the initial implementation to reduce its scope. However, the current design ends up partially supporting ingesting delta metrics via remote write. This is because a label will be added to indicate the temporality of the metric and used during querying, and therefore can be added by remote write. However, there is currently no equivalent to StartTimeUnixNano per sample in remote write.

For the initial implementation, there should be a documented warning that deltas are not _properly_ supported with remote write yet.

### Scraping

No scraped metrics should have delta temporality as there is no additional benefit over cumulative in this case. To produce delta samples from scrapes, the application being scraped has to keep track of when a scrape is done and resetting the counter. If the scraped value fails to be written to storage, the application will not know about it and therefore cannot correctly calculate the delta for the next scrape.

Delta metrics will be filtered out from metrics being federated. If the current value of the delta series is exposed directly, data can be incorrectly collected if the ingestion interval is not the same as the scrape interval for the federate endpoint. The alternative is to convert the delta metric to a cumulative one, which has issues detailed above. 
### Querying deltas

`rate()` and `increase()` will be extended to support delta metrics too. If the `__type__` starts with `delta_`, execute delta-specific logic instead of the current cumulative logic. The delta-specific logic will keep the intention of the rate/increase functions - that is, estimate the rate/increase over the selected range given the samples in the range, extrapolating if the samples do not align with the start and end of the range.

`irate()` will also be extended to support delta metrics.

Having functions transparently handle the temporality simplifies the user experience - users do not need to know the temporality of a series for querying, and means queries don't need to be rewriten wehn migrating between cumulative and delta metrics.

`resets()` does not apply to delta metrics, however, so will return no results plus a warning in this case.

While the intention is to eventually use `rate()`/`increase()` etc. for both delta and cumulative metrics, initially experimental functions prefixed with `delta_` will be introduced behind a delta-support feature flag. This is to make it clear that these are experimental and the logic could change as we start seeing how they work in real-world scenarios. In the long run, we’d move the logic into `rate()`.

#### Guessing start and end of series

The current `rate()`/`increase()` implementations guess if the series starts or ends within the range, and if so, reduces the interval it extrapolates to. The guess is based on the gaps between gaps and the boundaries on the range.

With sparse delta series, a long gap to a boundary is not very meaningful. The series could be ongoing but if there are no new increments to the metric then there could be a long gap between ingested samples. Therefore the delta implementation of `rate()`/`increase()` will not try and guess when a series starts and ends. Instead, it will always assume the series is ongoing for the whole range and always extrapolate to the whole range.

This could inflate the value of the series, which can be especially problematic during rollouts when old series are replaced by new ones.

As part of the implementation, experiment with heuristics to try and improve this (e.g. if intervals between samples are regular and there are than X samples, assume the samples are continuously ingested and therefore a gap would mean the series ended). This would make the calculation more complex, however.

#### `rate()`/`increase()` calculation

When CT-per-sample is introduced, there will be more information that could be used to more accurately calculate the rate (specifically, the first sample can be taken into account). Therefore the calculation differs depending on whether there is a CT within the sample.

TODO: write code for these implementations to make it clearer

*Without CT-per-sample rate()/increase()*

`(sum of second to last samples / (last sample ts - first sample ts))` (multiply by range if `increase()`)

We ignore the value of the first sample as we do not know when it started.

*With CT-per-sample rate()/increase()*

In this case, we don’t need to guess where the series started. As we have CT-per-sample, if a sample is before the range start, it can't be within in the range at all. We still cannot tell if there is a sample that overlaps with the end range, however.

1. If the start time of the first sample is outside the range, truncate the sample so we only take into account of the value within the range: 
    * `first sample value = first sample value * (first sample interval - (range start ts - first sample start ts))`
    * `first sample value ts = range start ts` 
2. Calculate rate: `(sum of all samples / (last sample ts - range start ts))` 
    * Multiply by `range end ts - max(range start ts, first sample start ts)` for `increase()`.

#### Non-extrapolation

There may be cases where extrapolating to get the rate/increase over the selected range is unwanted for delta metrics. Extrapolation may work worse for deltas since we do not try and guess when series start and end.

Users may prefer "non-extrapolation" behaviour that just gives them the sum of the sample values within the range. This can be accomplished with `sum_over_time()`. Note that this does not accurately give them the increase within the range.

As an example:

* S1: StartTimeUnixNano: T0, TimeUnixNano: T2, Value: 5
* S2: StartTimeUnixNano: T2, TimeUnixNano: T4, Value: 1
* S3: StartTimeUnixNano: T4, TimeUnixNano: T6, Value: 9 

And  `sum_over_time() was executed between T1 and T5.

As the samples are written at TimeUnixNano, only S1 and S2 are inside the query range. The total (aka “increase”)  of S1 and S2 would be 5 + 1 = 6. This is actually the increase between T0 (StartTimeUnixNano of S1) and T4 (TimeUnixNano of S2) rather than the increase between T1 and T5. In this case, the size of the requested range is the same as the actual range, but if the query was done between T1 and T4, the request and actual ranges would not match.

`sum_over_time()` does not work for cumulative metrics, so a warning should be returned in this case. One downside is that this could make migrating from delta to cumulative metrics harder, since `sum_over_time()` queries would need to be rewritten, and users wanting to use `sum_over_time()` will need to know the temporality of their metrics.

One possible solution would to have a function that does `sum_over_time()` for deltas and the cumulative equivalent too (this requires subtracting the latest sample before the start of the range with the last sample in the range). This is outside the scope of this design, however.

### Handling missing StartTimeUnixNano

StartTimeUnixNano is optional in the OTEL spec ...
Keep it for OTEL compatibility
use spacing between intervals when possible
non-extrapolation

## Alternatives

### Ingesting deltas alternatives

#### CreatedTimestamp per sample

If `StartTimeUnixNano` is set for a delta counter, it should be stored in the CreatedTimestamp field of the sample. The CreatedTimestamp field does not exist yet, but there is currently an effort towards adding it for cumulative counters ([PR](https://github.com/prometheus/prometheus/pull/16046/files)), and can be reused for deltas. Having the timestamp and the start timestamp stored in a sample means that there is the potential to detect overlaps between delta samples (indicative of multiple producers sending samples for the same series), and help with more accurate rate calculations.

#### Treat as gauge
To avoid introducing a new type, deltas could be represented as gauges instead and the start time ignored.

This could be confusing as gauges are usually used for sampled data (for example, in OTEL: "Gauges do not provide an aggregation semantic, instead “last sample value” is used when performing operations like temporal alignment or adjusting resolution.”) rather than data that should be summed/rated over time. 

#### Treat as “mini-cumulative”
Deltas can be thought of as cumulative counters that reset after every sample. So it is technically possible to ingest as cumulative and on querying just use the cumulative functions. 

This requires CT-per-sample to be implemented. Just zero-injection of StartTimeUnixNano would not work all the time. If there are samples at consecutive intervals, the StartTimeUnixNano for a sample would be the same as the TimeUnixNano for the preceding sample and cannot be injected.

Functions will not take into account delta-specific characteristics. The OTEL SDKs only emit datapoints when there is a change in the interval. rate() assumes samples in a range are equally spaced to figure out how much to extrapolate, which is less likely to be true for delta samples.

This also does not work for samples missing StartTimeUnixNano.

#### Convert to rate on ingest
Convert delta metrics to per-second rate by dividing the sample value with (`TimeUnixName` - `StartTimeUnixNano`) on ingest, and also append `:rate` to the end of the metric name (e.g. `http_server_request_duration_seconds` -> `http_server_request_duration_seconds:rate`). So the metric ends up looking like a normal Prometheus counter that was rated with a recording rule.

The difference is that there is no interval information in the metric name (like :rate1m) as there is no guarantee that the interval from sample to sample stays constant.

To averages rates over more than the original collection interval, a new time-weighted average function is required to accommdate cases like the collection interval changing and having a query range which isn't a multiple of the interval.

This would also require zero timestamp injection or CT-per-sample for better rate calculations.

Users might want to convert back to original values (e.g. to sum the original values over time). It can be difficult to reconstruct the original value if the start timestamp is far away (as there are probably limits to how far we could look back). Having CT-per-sample would help in this case, as both the StartTimeUnixNano and the TimeUnixNano would be within the sample. However, in this case it is trivial to convert between the rated and unrated count, so there is no additional benefit of storing as the calculated rate. In that case, we should prefer to store the original value as that would cause less confusion to users who look at the stored values.

This also does not work for samples missing StartTimeUnixNano.

### Distinguishing between delta and cumulative metrics alternatives

#### New `__temporality__` label

A new `__temporality__` label could be added instead.

However, not all metric types should have a temporality (e.g. gauge). Having `delta_` as part of the type label enforces that only specific metric types can have temporality. Otherwise, additional label error checking would need to be done to make sure `__temporality__` is only added to specific types.

#### Metric naming convention

Have a convention for naming metrics e.g. appending `_delta_counter` to a metric name. This could make the temporality more obvious at query time. However, assuming the type and unit metadata proposal is implemented, having the temporality as part of a metadata label would be more consistent than having it in the metric name.

### Querying deltas alternatives

TODO: these are the top ones, for more see ...

rate() to do sum_over_time()
convert to cumulative on read

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
