# OTEL delta temporality support

* **Owners:**
  * @fionaliao

* **Contributors:**
  * Initial design started by @ArthurSens and @sh0rez
  * Delta WG: @ArthurSens, @enisoc and @subvocal, among others

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/12763

* **Other docs or links:**
  * [Original design doc](https://docs.google.com/document/d/15ujTAWK11xXP3D-EuqEWTsxWiAlbBQ5NSMloFyF93Ug/edit?tab=t.0)
  * [#prometheus-delta-dev](https://cloud-native.slack.com/archives/C08C6CMEUF6) - Slack channel for project
  * [OpenTelemetry metrics: A guide to Delta vs. Cumulative temporality trade-offs](https://docs.google.com/document/d/1wpsix2VqEIZlgYDM3FJbfhkyFpMq1jNFrJgXgnoBWsU/edit?tab=t.0#heading=h.wwiu0da6ws68)
  * [Musings on delta temporality in Prometheus](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q)
  * [Chronosphere Delta Experience Report](https://docs.google.com/document/d/1L8jY5dK8-X3iEoljz2E2FZ9kV2AbCa77un3oHhariBc/edit?tab=t.0#heading=h.3gflt74cpc0y)

A proposal for adding experimental support for OTEL delta temporality metrics in Prometheus, allowing them to be ingested, stored and queried directly.

## Why

Prometheus supports the ingestion of OTEL metrics via its OTLP endpoint. Counter-like OTEL metrics (e.g. histograms, sum) can have either [cumulative or delta temporality](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality). However, Prometheus only supports cumulative metrics, due to its pull-based approach to collecting metrics.

Therefore, delta metrics need to be converted to cumulative ones during ingestion. The OTLP endpoint in Prometheus has an [experimental feature to convert delta to cumulative](https://github.com/prometheus/prometheus/blob/9b4c8f6be28823c604aab50febcd32013aa4212c/docs/feature_flags.md?plain=1#L167). Alternatively, users can run the [deltatocumulative processor](https://github.com/sh0rez/opentelemetry-collector-contrib/tree/main/processor/deltatocumulativeprocessor) in their OTEL pipeline before writing the metrics to Prometheus.

The cumulative code for storage and querying can be reused, and when querying, users don’t need to think about the temporality of the metrics - everything just works. However, there are downsides elaborated in the [Pitfalls section](#pitfalls-of-the-current-solution) below.

Prometheus' goal of becoming the best OTEL metrics backend means it should improve its support for delta metrics, allowing them to be ingested and stored without being transformed into cumulative.

We propose some initial steps for delta support in this document. These delta features will be experimental and opt-in, allowing us to gather feedback and gain practical experience with deltas before deciding on future steps.

### OTEL delta datapoints

In the [OTEL spec](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality), like cumulative metrics, a datapoint for a delta metric has a `(start,end]` time window. However, the time windows of delta datapoints do not overlap.

The `end` timestamp is called `TimeUnixNano` and is mandatory. The `start` timestamp is called `StartTimeUnixNano`. `StartTimeUnixNano` timestamp is optional, but recommended for better rate calculations and to detect gaps and overlaps in a stream.

### Characteristics of delta metrics

#### Sparseness

Sparse metrics are more common for delta than cumulative metrics. While delta datapoints can be emitted at a regular interval, in some cases (like the OTEL SDKs), datapoints are only emitted when there is a change (e.g. if tracking request count, only send a datapoint if the number of requests in the collection interval > 0). This can be beneficial for the metrics producer, reducing memory usage and network bandwidth.

#### Alignment

Usually, delta metrics are reported at timestamps aligned to the collection interval - that is, values are collected over a defined window (for example, one minute) and the final aggregated value is emitted exactly at the interval boundary (such as at each full minute).

This isn't true in all cases though, for example, the StatsD client libraries emits a delta every time an event happens rather than aggregating, producing unaligned samples (though if the StatsD daemon is used, that then aggregates the input values and aligns the data to the interval).

#### Further reading

[Chronosphere Delta Experience Report](https://docs.google.com/document/d/1L8jY5dK8-X3iEoljz2E2FZ9kV2AbCa77un3oHhariBc/edit?tab=t.0#heading=h.3gflt74cpc0y) describes Chronosphere's experience of adding functionality to ingest OTEL delta metrics and query them back with PromQL, and there is additionally [Musings on delta temporality in Prometheus](https://docs.google.com/document/d/1vMtFKEnkxRiwkr0JvVOrUrNTogVvHlcEWaWgZIqsY7Q/edit?tab=t.0#heading=h.5sybau7waq2q).

### Monotonicity

OTEL sums have a [monotonicity property](https://opentelemetry.io/docs/specs/otel/metrics/supplementary-guidelines/#monotonicity-property), which indicates if the sum can only increase (monotonic) or if it can increase and decrease (non-monotonic). Monotonic cumulative sums are mapped to Prometheus counters. Non-monotonic cumulative sums are mapped to Prometheus gauges, since Prometheus does not support counters that can decrease. This is because any drop in a Prometheus counter is assumed to be a counter reset.

[StatsD counters are non-monotonic by definition](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/1789), and [the StatsD receiver sets counters as non-monotonic by default](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/statsdreceiver/README.md). Since StatsD is so widely used, when considering delta support, it's important to make sure non-monotonic counters will work properly in Prometheus.

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

Cumulative metrics usually need to be wrapped in a `rate()` or `increase()` etc. call to get a useful result. However, it could be confusing that when querying just the metric without any functions, the returned value is not the same as the ingested value.

#### Poor sparse metrics handling

Sparse metrics are more common with deltas. This can interact awkwardly with `rate()` - the `rate()` function in Prometheus does not work with only a single datapoint in the range, and assumes even spacing between samples.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow OTEL delta metrics to be ingested via the OTLP endpoint and stored directly.
* Support for all OTEL metric types that can have delta temporality (sums, histograms, exponential histograms).
* Allow delta metrics to be distinguished from cumulative metrics.
* Allow the query engine to flag warnings when a cumulative function is used on deltas.

### Audience

This document is for Prometheus server maintainers, PromQL maintainers, and Prometheus users interested in delta ingestion.

## Non-Goals

* Support for ingesting delta metrics via other, non-OTLP means (e.g. replacing push gateway).
* Advanced querying support for deltas (e.g. function overloading for `rate()`). Given that delta support is new and advanced querying also depends on other experimental features, the best approach - or whether we should even extend querying - is currently uncertain. However, this document does explore some possible options.

These may come in later iterations of delta support.

## How

This section outlines the proposed approach for delta temporality support. Additional approaches and extensions can be found in [Potential future extensions](#potential-future-extensions) and [Discarded alternatives](#discarded-alternatives).

### Ingesting deltas

Add a feature flag for ingesting deltas: `--enable-feature=otlp-native-delta-ingestion`.

When an OTLP sample has its aggregation temporality set to delta, write its value at `TimeUnixNano`.

For the initial implementation, ignore `StartTimeUnixNano`. To ensure compatibility with the OTEL spec, this case should ideally be supported. A way to preserve `StartTimeUnixNano` is described in the potential future extension, [CT-per-sample](#ct-per-sample).

#### Set metric type as gauge

For this initial proposal, OTEL deltas will be treated as a special case of Prometheus gauges. When ingesting, the metric metadata type will be set to `gauge` / `gaugehistogram`.

A gauge is a metric that can ["arbitrarily go up and down"](https://prometheus.io/docs/concepts/metric_types/#gauge), meaning it's compatible with delta data. In general, delta data is aggregated over time by adding up all the values in the range. There are no restrictions on how a gauge should be aggregated over time.

Prometheus already uses gauges to represent deltas. While gauges ingested into Prometheus via scraping represent sampled values rather than a count within a interval, there are other sources that can ingest "delta" gauges. For example, `increase()` outputs the delta count of a series over a specified interval. While the output type is not explicitly defined, it's considered a gauge. A common optimisation is to use recording rules with `increase()` to generate “delta” samples at regular intervals. When calculating the increase over a longer period of time, instead of loading large volumes of raw cumulative counter data, the stored deltas can be summed over time. Non-monotonic cumulative sums in OTEL are already ingested as Prometheus gauges, meaning there is precedent for counter-like OTEL metrics being converted to Prometheus gauge types. Another way of putting it is that deltas are already a subset of the Prometheus gauge type.

This approach leverages an existing Prometheus metric type, avoiding the changes to the core Prometheus data model.

As per [Prometheus documentation](https://prometheus.io/docs/concepts/metric_types/), "The Prometheus server does not yet make use of the type information and flattens all data into untyped time series". Recently however, there has been [an accepted Prometheus proposal (PROM-39)](https://github.com/prometheus/proposals/pull/39) to add experimental support type and unit metadata as labels to series, allowing more persistent and structured storage of metadata than was previously available. This means there is potential to build features on top of the typing in the future. If type and unit metadata labels is enabled, `__type__="gauge"` / `__type__="gaugehistogram"` will be added as a label. If the `--enable-feature=type-and-unit-labels` (from PROM-39) is set, a `__type__="gauge"` will be added as a label.

An alternative/potential future extension is to [ingest as Prometheus counters instead](#ingest-as-counter). That option is a bigger change since it alters the Prometheus model rather than reusing a pre-existing type. However, could be less confusing as it aligns the Prometheus data model more closely to the OTEL one.

#### Add otel metric properties as informational labels

The key problem of ingesting OTEL deltas as Prometheus gauges is the lack of distinction between OTEL gauges and OTEL deltas, even though their semantics differ. There are issues like:

* Gauge has different meanings in Prometheus and OTEL. In Prometheus, it's just a value that can go up and down, while in OTEL it's the "last-sampled event for a given time window". While it technically makes sense to represent an OTEL delta counter as a Prometheus gauge, this could be a point of confusion for OTEL users who see their counter being mapped to a Prometheus gauge rather than a Prometheus counter. There could also be uncertainty for the user on whether the metric was accidentally instrumented as a gauge or whether it was converted from a delta counter to a gauge.
* Prometheus gauges are usually aggregated in time by averaging or taking the last value, while OTEL deltas are usually summed. Treating both as a single type would mean there wouldn't be an appropriate default aggregation for gauges. Having a predictable aggregation by type is useful for downsampling, or applications that try to automatically display meaningful graphs for metrics.
* The original delta information is lost upon conversion. If the resulting Prometheus gauge metric is converted back into an OTEL metric, it would be converted into a gauge rather than a delta metric. While there's no proven need for roundtrippable deltas, maintaining OTEL interoperability helps Prometheus be a good citizen in the OpenTelemetry ecosystem.

It is useful to be able to identify delta metrics and distinguish them from cumulative metrics and gauges. This would allow users to understand what the raw data represents and what functions are appropriate to use. Additionally, this could allow the query engine or UIs displaying Prometheus data apply different behaviour depending on the metric type to provide meaningful output.

Therefore it is important to maintain information about the OTEL metric properties. Alongside setting the type to `gauge` / `gaugehistogram`, the original OTEL metric properties will also be added as labels:

* `__otel_type__="sum"` - this will allow the metric to be converted back to an OTEL sum (with delta temporality) rather than a gauge if the metrics as exported back to OTEL.
* `__temporality__="delta"`
* `__monotonicity__="true"/"false"` - as mentioned in [Monotonicity](#monotonicity), it is important to be able to ingest non-monotonic counters. Therefore this label is added to be able to distinguish between monotonic and non-monotonic cases.

This is similar to the approach taken for type and unit labels in PROM-39. However, since these are new labels being added, there is not a strong dependency so does not require `--enable-feature=type-and-unit-labels` to be enabled. At query time, these should be dropped in the same way as the other metadata labels (as per PROM-39: "When a query drops the metric name in an effect of an operation or function, `__type__` and `__unit__` will also be dropped"), as these labels do provide type information about the metric and that changes when certain operations/functions are applied.

The temporality and monotonicity labels do not have the `otel_` prefix, since they don't clash with any reserved labels in Prometheus. This means that metrics ingested via other sources (e.g. remote write) could add `__temporality__="delta"` and `__monotonicity__="true"/"false"` labels too as a way of ingesting delta metrics.

There is a risk that tooling and workflows could rely too much on the OTEL-added labels rather than Prometheus native types where possible, leading to inconsistent user experience depending on whether OTEL or Prometheus is used for ingestion. This can also be confusing, as OTEL users would need to understand there are two different types - the OTEL types and the Prometheus types. For example, knowing that an OTEL gauge is not the same as a Prometheus gauge and there's also additional labels to consider.

#### Metric names

OTEL metric names are normalised when translated to Prometheus by default ([code](https://github.com/prometheus/otlptranslator/blob/94f535e0c5880f8902ab8c7f13e572cfdcf2f18e/metric_namer.go#L157)). This includes adding suffixes in some cases. For example, OTEL metrics converted into Prometheus counters (i.e. monotonic cumulative sums in OTEL) have the `__total` suffix added to the metric name, while gauges do not.

The `_total` suffix will not be added to OTEL deltas. The `_total` suffix is used to help users figure out whether a metric is a counter. The `__otel_type__` and `__temporality__` labels will be able to provide the distinction and the suffix is unnecessary.

This means switching between cumulative and delta temporality can result in metric names changing, affecting dashboards and alerts. However, the current proposal requires different functions for querying delta and cumulative counters anyway.

#### Chunks

For the initial implementation, reuse existing chunk encodings.

Delta counters will use the standard XOR chunks for float samples.

Delta histograms will use native histogram chunks with the `GaugeType` counter reset hint/header. The counter reset behaviour for cumulative native histograms is to cut a new chunk if a counter reset is detected. A (bucket or total) count drop is detected as a counter reset. As delta samples don’t build on top of each other, there could be many false counter resets detected and cause unnecessary chunks to be cut. Additionally, counter histogram chunks have the invariant that no count ever goes down baked into their implementation. `GaugeType` allows counts to go up and down, and does not cut new chunks on counter resets.

### Scraping

No scraped metrics should have delta temporality as there is no additional benefit over cumulative in this case. To produce delta samples from scrapes, the application being scraped has to keep track of when a scrape is done and resetting the counter. If the scraped value fails to be written to storage, the application will not know about it and therefore cannot correctly calculate the delta for the next scrape.

### Federation

Federating delta series directly could be usable if there is a constant and known collection interval for the delta series, and the metrics are scraped at least as often as the collection interval. However, this is not the case for all deltas and the scrape interval cannot be enforced.

Therefore we will add a warning to the delta documentation explaining the issue with federating delta metrics, and provide a scrape config for ignoring deltas if the delta labels are set.

### Remote write ingestion

Remote write support is a non-goal for this initial delta proposal to reduce its scope. However, the current design ends up supporting ingesting delta metrics via remote write. This is because OTEL labels are added to indicate the type and temporality of the metric, and therefore can be added manually added to metrics before being sent by remote write.

### Prometheus metric metadata

Prometheus has metric metadata as part of its metric model, which include the type of a metric. This will not be modified for the initial proposal, since the OTEL type/temporality are just added as labels rather than extending the Prometheus metric model.

### Prometheus OTEL receivers

Once deltas are ingested into Prometheus, they can be converted back into OTEL metrics by the [prometheusreceiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/prometheusreceiver) (scrape) and [prometheusremotewritereceiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/prometheusremotewritereceiver) (push).

The prometheusreceiver has the same issue described in [Scraping](#scraping) regarding possibly misaligned scrape vs delta collection intervals.

If we do not modify prometheusremotewritereceiver, then as the metric metadata type is set to gauge, the receiver will currently assume it's a OTEL gauge rather than an OTEL sum. If we gain more confidence that the OTEL labels is the correct approach, the receiver should be updated to translate Prometheus metrics based on the `__otel_...` labels. For now, we will recommend that delta metrics should be dropped before reaching the receiver, and provide a remote write relabel config for doing so.

### Querying deltas

For this initial proposal, existing functions will be used for querying deltas.

`rate()` and `increase()` will not work, since they assume cumulative metrics. Instead, the `sum_over_time()` function can be used to get the increase in the range, and `sum_over_time(metric[<range>]) / <range>` can be used for the rate. A single delta sample can also be meaningful without aggregating over time as unlike cumulative metrics, each delta sample is independent. `metric / interval` can also be used to calculate a rate if the collection interval is known.

Having different functions for delta and cumulative counters mean that if the temporality of a metric changes, queries will have to be updated.

Possible improvements to rate/increase calculations and user experience can be found in [Rate calculation extensions](#rate-calculation-extensions-without-ct-per-sample) and [Function overloading](#function-overloading).

Note: With [left-open range selectors](https://prometheus.io/docs/prometheus/3.5/migration/#range-selectors-and-lookback-exclude-samples-coinciding-with-the-left-boundary) introduced in Prometheus 3.0, queries such as `sum_over_time(metric[<interval>])` will exclude the sample at the left boundary. This is a fortunate usability improvement for querying deltas - with Prometheus 2, a `1m` interval actually covered `1m1s`, which could lead to double counting samples in consecutive steps and inflated sums; to get the actual value within `1m`, the awkward `59s999ms` had to be used instead.

#### Querying range misalignment

With `sum_over_time()`, the actual range covered by the sum could be different from the query range. For the ranges to match, the query range needs to be a multiple of the collection interval, which Prometheus does not enforce. Additionally, this finds the rate between the start time of the first sample and the end time of the last sample, which won't always match the start and end times of the query. This differs for `rate()` and `increase()` for cumulative metrics, which calculates the rate/increase specifically for the selected range.

**Example 1**

* S1: StartTimeUnixNano: T0, TimeUnixNano: T2, Value: 5
* S2: StartTimeUnixNano: T2, TimeUnixNano: T4, Value: 1
* S3: StartTimeUnixNano: T4, TimeUnixNano: T6, Value: 9

And `sum_over_time()` was executed between T1 and T5.

As the samples are written at TimeUnixNano, only S1 and S2 are inside the query range. The total (aka “increase”) of S1 and S2 would be 5 + 1 = 6. This is actually the increase between T0 (StartTimeUnixNano of S1) and T4 (TimeUnixNano of S2) rather than the increase between T1 and T5. In this case, the size of the requested range is the same as the actual range, but if the query was done between T1 and T4, the request and actual ranges would not match.

**Example 2**

* S1: StartTimeUnixNano: T0, TimeUnixNano: T5, Value: 10

`sum_over_time()` between T0 and T5 will get 10. Divided by 5 for the rate results in 2.

However, if you only query between T4 and T5, the rate would be 10/1 = 1 , and queries between earlier times (T0-T1, T1-T2 etc.) will have a rate of zero.

Whether this is a problem or not is subjective. Users may prefer this behaviour, as unlike the cumulative `rate()`/`increase()`, it does not attempt to extrapolate. This makes the results easier to reason about and directly reflects the ingested data. The [Chronosphere user experience report](https://docs.google.com/document/d/1L8jY5dK8-X3iEoljz2E2FZ9kV2AbCa77un3oHhariBc/edit?tab=t.0) supports this: "user feedback indicated [`sum_over_time()`] felt much more natural and trustworthy when working with deltas" compared to converting deltas to cumulative and having `rate()`/`increase()` apply its usual extrapolation.

For some delta systems like StatsD, each sample represents an value that occurs at a specific moment in time, rather than being aggregated over a window. Each delta sample can be viewed as representing an infinitesimally small interval around its timestamp. This means taking into account of all the samples in the range, without extrapolation or interpolation, is a good representation of increase in the range - there are no samples in the range that only partially contribute to the range, and there are no samples out of the range which contribute to the increase in the range at all. For our initial implementation, the collection interval is ignored (i.e. `StartTimeUnixNano` is dropped), so all deltas could be viewed in this way.

Additionally, as mentioned before, it is common for deltas to have samples emitted at fixed time boundaries (i.e. are aligned). This means if the collection interval is known, and query ranges match the time boundaries, accurate results can be produced with `sum_over_time()`.

#### Function warnings

To help users use the correct functions, warnings will be added if the metric type/temporality does not match the types that should be used with the function. The warnings will be based on the `__type__` label, so will only work if `--enable-feature=type-and-unit-labels` is enabled. Because of this, while not necessary, it will be recommended to enabled the type and unit labels feature alongside the delta support feature.

* Cumulative counter-specific functions (`rate()`, `increase()`, `irate()` and `resets()`) will warn if `__type__="gauge"`.
* `sum_over_time()` will warn if `type="counter"`.

### Summary

This initial approach enables Prometheus to support OTEL delta metrics in a careful manner by relying on existing concepts like labels and reusing existing functions with minimal changes, and also provides a foundation for potentially building more advanced delta features in the future.

## Known unknowns

### Native histograms performance

To work out the delta for all the cumulative native histograms in an range, the first sample is subtracted from the last and then adjusted for counter resets within all the samples. Counter resets are detected at ingestion time when possible. This means the query engine does not have to read all buckets from all samples to calculate the result. The same is not true for delta metrics - as each sample is independent, to get the delta between the start and end of the range, all of the buckets in all of the samples need to be summed, which is less efficient at query time.

## Implementation Plan

### 1. Experimental feature flag for OTLP delta ingestion

A `--enable-feature=otlp-native-delta-ingestion` was already introduced in https://github.com/prometheus/prometheus/pull/16360, but that doesn't add any type metadata to the ingested series. Update the feature to set the type to gauge and add the `__otel_...` labels.

### 2. Function warnings

Add function warnings when a function is used with series of wrong type or temporality as described in [Function warnings](#function-warnings).

There are already warnings if `rate()`/`increase()` are used without the `__type__="counter"` label: https://github.com/prometheus/prometheus/pull/16632.

### 3. Update documentation

Update documentation explaining new experimental delta functionality, including recommended configs for filtering out delta metrics from scraping and remote write.

### 4. Review deltas in practice and experiment with possible future extensions

Review how deltas work in practice using the current approach, and use experience and feedback to decide whether any of the potential extensions are necessary.

## Potential future extensions

Potential extensions, some may require dedicated proposals.

### Ingest as counter

Instead of ingesting as a Prometheus gauge, ingest as a Prometheus counter. When ingesting a delta metric via the OTLP endpoint, the metric type is set to `counter` / `histogram` (and with PROM-39, the `__type__` label will be `counter` / `histogram`).

This will change the Prometheus definition of a counter (currently: "A counter is a cumulative metric that represents a single monotonically increasing counter whose value can only increase or be reset to zero on restart").

As mentioned in the [Chunks](#chunks) section, `GaugeType` should still be the counter reset hint/header.

Cumulative counter-like metrics ingested via the OTLP endpoint will also have a `__temporality__="cumulative"` label added.

**Pros**
* Clear distinction between OTEL delta metrics and OTEL gauge metrics when ingested into Prometheus, meaning users know the appropriate functions to use for each type (e.g. `sum_over_time()` is unlikely to be useful for OTEL gauge metrics).
* Closer match with the OTEL model - in OTEL, counter-like types sum over events over time, with temporality being an property of the type. This is mirrored by having `__type__="counter"` and `__temporality__="delta"/"cumulative"` labels in Prometheus.

**Cons**
* Introduces additional complexity to the Prometheus data model.
* Confusing overlap between gauge and delta counters. Essentially deltas already exist in Prometheus as gauges, and deltas can be viewed as a subset of gauges under the Prometheus definition. The same `sum_over_time()` would be used for aggregating these pre-existing deltas-as-gauges and delta counters, creating confusion on why there are two different "types".
  * Pre-existing deltas-as-gauges could be converted to counters with `__temporality__="delta"`, to have one consistent "type" which should be summed over time.
* Systems or scripts that handle Prometheus metrics may be unaware of the new `__temporality__` label and could incorrectly treat all counter-like metrics as cumulative, resulting in hard-to-notice calculation errors.

We decided not to go for this approach for the initial version as it is more invasive to the Prometheus model - it changes the definition of a Prometheus counter, especially if we allow non-monotonic deltas to be ingested as counters. This would mean we won't always be able convert Prometheus delta counters to Prometheus cumulative counters, as Prometheus cumulative counters have to monotonic (as drops are detected as resets). There's no actual use case yet for being able to convert delta counters to cumulative ones but it makes the Prometheus data model more complex (counters sometimes need to be monotonic, but not always). An alternative is allow cumulative counters to be non-monotonic (by setting a `__monontonicity__="false"` label) and adding warnings if a non-monotonic cumulative counter is used with `rate()`, but that makes `rate()` usages more confusing.

We may switch to this option if marking as the type as gauge appears too confusing to users.

### CT-per-sample

[CreatedTimestamp (PROM-29)](https://github.com/prometheus/proposals/blob/main/proposals/0029-created-timestamp.md) records when a series was created or last reset, therefore allowing more accurate rate or increase calculations. This is similar to the `StartTimeUnixNano` field in OTEL metrics.

There is an effort towards adding CreatedTimestamp as a field for each sample ([PR](https://github.com/prometheus/prometheus/pull/16046/files)). This is for cumulative counters, but can be reused for deltas too. When this is completed, if `StartTimeUnixNano` is set for a delta counter, it should be stored in the CreatedTimestamp field of the sample.

CT-per-sample is not a blocker for deltas - before this is ready, `StartTimeUnixNano` will just be ignored.

Having CT-per-sample can improve the `rate()` calculation - the collection interval for each sample will be directly available, rather than having to guess the interval based on gaps. It also means a single sample in the range can result in a result from `rate()` as the range will effectively have an additional point at `StartTimeUnixNano`.

There are unknowns over the performance and storage with this approach.

### OTEL metric properties on all metrics

For this initial proposal, the OTEL metric properties will only be added to delta metrics. If this works out, we should consider adding the properties to all metrics ingested via OTEL. This can be useful in other cases too, for example, distinguishing OTEL non-monotonic cumulative sums from OTEL gauges (which are currently both mapped to Prometheus gauges with no distinguishing labels).

### Inject zeroes for StartTimeUnixNano

[CreatedAt timestamps can be injected as 0-valued samples](https://prometheus.io/docs/prometheus/latest/feature_flags/#created-timestamps-zero-injection). Similar could be done for StartTimeUnixNano.

CT-per-sample is a better solution overall as it links the start timestamp with the sample. It makes it easier to detect overlaps between delta samples (indicative of multiple producers sending samples for the same series), and help with more accurate rate calculations.

If CT-per-sample takes too long, this could be a temporary solution.

It's possible for the StartTimeUnixNano of a sample to be the same as the TimeUnixNano of the preceding sample; care would need to be taken to not overwrite the non-zero sample value.

### Rate calculation extensions (without CT-per-sample)

[Querying deltas](#querying-deltas) outlined the caveats of using `sum_over_time(...[<interval>]) / <interval>` to calculate the increase for delta metrics. In this section, we explore possible alternative implementations for delta metrics.

This section assumes knowledge of [Extended range selectors semantics proposal](https://github.com/prometheus/proposals/blob/main/proposals/2025-04-04_extended-range-selectors-semantics.md) which introduces the `smoothed` and `anchored` modifers to range selectors, in particular for `rate()` and `increase()` for cumulative counters.

This also assumes CT-per-sample is not available. A possibly simpler solution if CT-per-sample is available is discussed in [Treat as mini-cumulative](#treat-as-mini-cumulative).

##### Lookahead and lookbehind of range

The reason why `increase()`/`rate()` need extrapolation for cumulative counters is to cover the entire range is that they’re constrained to only look at the samples within the range. This is a problem for both cumulative and delta metrics.

To work out the increase more accurately, the functions would also have to look at the sample before and the sample after the range to see if there are samples that partially overlap with the range - in that case the partial overlaps should be added to the increase.

The `smoothed` modifer in the extended range selectors proposal does this for cumulative counters - looking at the points before and after the range to more accurately calculate the rate/increase. We could implement something similar with deltas, though we cannot naively use the propossed smoothed behaviour for deltas.

The `smoothed` proposal works by injecting points at the edges of the range. For the start boundary, the injected point will have its value worked out by linearly interpolating between the closest point before the range start and the first point inside the range.

![cumulative smoothed example](../assets/0048-otel_delta_temporality_support/cumulative-smoothed.png)

That value would be nonesensical for deltas, as the values for delta samples are independent. Additionally, for deltas, to work out the increase, we add all the values up in the range (with some adjustments) vs in the cumulative case where you subtract the first point in the range from the last point. So it makes sense the smoothing behaviour would be different.

In the delta case, the adjustment to samples in the range used for the rate calculation would be to work out the proportion of the first sample within the range and update its value. We would use the assumption that the start timestamp for the first sample is equal the the timestamp of the previous sample, and then use the formula `inside value * (inside ts - range start ts) / (inside ts - outside ts)` to adjust the first sample (aka the `inside value`).

Support for retaining `StartTimeUnixNano` would improve the calculation, as we would then know the real interval for the first sample, rather than assuming its interval extends back until the previous sample. For sparse cases, this assumption could be wrong.

#### Similar logic to cumulative case

For cumulative counters, `increase()` works by subtracting the first sample from the last sample in the range, adjusting for counter resets, and then extrapolating to estimate the increase for the entire range. The extrapolation is required as the first and last samples are unlikely to perfectly align with the start and end of the range, and therefore just taking the difference between the two is likely to be an underestimation of the increase for the range. `rate()` divides the result of `increase()` by the range. This gives an estimate of the increase or rate of the selected range.

For consistency, we could emulate that for deltas.

First sum all sample values in the range, with the first sample’s value only partially included if it's not completely within the query range. To estimate the proportion of the first sample within the range, assume its interval is the average interval betweens all samples within the range. If the last sample does not align with the end of the time range, the sum should be extrapolated to cover the range until the end boundary.

The cumulative `rate()`/`increase()` implementations guess if the series starts or ends within the range, and if so, reduces the interval it extrapolates to. The guess is based on the gaps between gaps and the boundaries on the range. With sparse delta series, a long gap to a boundary is not very meaningful. The series could be ongoing but if there are no new increments to the metric then there could be a long gap between ingested samples.

For the delta end boundary extrapolation, we could just not try and predict the end of the series and assume the series continues to extend to beyond the samples in the range. However, not predicting the end of the series could inflate the rate/increase value, which can be especially problematic during rollouts when old series are replaced by new ones.

Assuming the delta rate function only has information about the sample within the range, guessing the end of series is probably the least worst option - this will at least work in delta cases where the samples are continuously ingested. To predict if a series has ended in the range, check if the timestamp of the last sample are within 1.1x of an interval between their respective boundaries (aligns with the cumulative check for start/end of a series). To calculate the interval, use the average spacing between samples.

The final result will be the increase over the query range. To calculate the rate, divide the increase by the query range.

Downsides:

* This will not work if there is only a single sample in the range, which is more likely with delta metrics (due to sparseness, or being used in short-lived jobs).
  * A possible adjustment is to just take the single value as the increase for the range. This may be more useful on average than returning no value in the case of a single sample. However, the mix of extrapolation and non-extrapolation logic may end up surprising users. If we do decide to generally extrapolate to fill the whole window, but have this special case for a single datapoint, someone might rely on the non-extrapolation behaviour and get surprised when there are two points and it changes.
* Harder to predict the start and end of the series vs cumulative.
* The average spacing may not be a good estimation for the collection interval when delta metrics are sparse or irregularly spaced.
* Additional downsides can be found in [this review comment](https://github.com/prometheus/proposals/pull/48#discussion_r2047990524).

The numerous downsides likely outweigh the argument for consistency. Additionally, lookahead/lookbehind techniques are already being explored for cumulative metrics with the `smoothed` modifier. This means we could likely do something similar for deltas. Lookahead/lookbehind aims to do a similar thing to this calculation - estimate the increase/rate for the series within the selected query range. However, since it can look beyond the boundary of the query range, it should get better results.

### Function overloading

`rate()` and `increase()` could be extended to work transparently with both cumulative and delta metrics. The PromQL engine could check the `__temporality__="delta"` label and specific delta logic, otherwise treat as a cumulative counter.

Function overloading could work on all metrics where `__type__="gauge"` label is added, but then `rate()` and `increase()` could run on gauges that are unsuited to being summed over time, not add any warnings, and produce nonsensical results.

Pros:

* Users would not need to know the temporality of their metric to write queries. Users often don’t know or may not be able to control the temporality of a metric (e.g. if they instrument the application, but the metric processing pipeline run by another team changes the temporality).
* This is helpful when there are different sources which ingest metrics with different temporalities, as a single function can be used for all cases.
* Greater query portability and reusability. Published generic dashboards and alert rules (e.g. [Prometheus monitoring mixins](https://monitoring.mixins.dev/)) can be reused for metrics of any temporality, reducing operational overhead.

Cons:

* The increased internal complexity could end up being more confusing.
* Inconsistent functions depending on type and temporality. Both `increase()` and `sum_over_time()` could be used for aggregating deltas over time. However, `sum_over_time()` would not work for cumulative metrics, and `increase()` would not work for gauges.
  * This gets further complicated when considering how functions could be combined. For example, a user may use recording rules to compute the sum of a delta metric over a shorter period of time, so they can later for the sum over a longer period of time faster by using the pre-computed results. `increase()` and `sum_over_time()` would both work for the recording rule. For the longer query, `increase()` will not work - it would return a warning (as the pre-computed values would be gauges/untyped and should not be used with `increase()`) and a wrong value (if the cumulative counter logic is applied when there is no `__temporality__="delta"` label). `sum_over_time()` for the longer query would work in the expected manner, however.
* Migration between delta and cumulative temporality for a series may seem seamless at first glance - there is no need to change the functions used. However, the `__temporality__` label would mean that there would be two separate series, one delta and one cumulative. If you have a long query (e.g. `increase(...[30d]))`, the transition point between the two series will be included for a long time in queries. Assuming the [proposed metadata labels behaviour](https://github.com/prometheus/proposals/blob/main/proposals/0039-metadata-labels.md#milestone-1-implement-a-feature-flag-for-type-and-unit-labels), where metadata labels are dropped after `rate()` or `increase()` is applied, two series with the same labelset will be returned (with an info annotation about the query containing mixed types).
  * One possible extension could be to stitch the cumulative and delta series together and return a single result.
* There is currently no way to correct the metadata labels for a stored series during query time. While there is the `label_replace()` function, that only works on instant vectors, not range vectors which are required by `rate()` and `increase()`. If `rate()` has different behaviour depending on a label, there is no way to get it to switch to the other behaviour if you've accidentally used the wrong label during ingestion.

Open questions and considerations:

* While there is some precedent for function overloading with both counters and native histograms being processed in different ways by `rate()`, those are established types with obvious structual differences that are difficult to mix up. The metadata labels (including the proposed `__temporality__` label) are themselves experimental and require more adoption and validation before we start building too much on top of them.
* There are open questions on how to best calculate the rate or increase of delta metrics (see [`rate()` behaviour for deltas](#rate-behaviour-for-deltas) below), and there is currently ongoing work with [extending range selectors for cumulative counters](https://github.com/prometheus/proposals/blob/main/proposals/2025-04-04_extended-range-selectors-semantics.md), which should be taken into account for deltas too.
* Once we start with overloading functions, users may ask for more of that e.g. should we change `sum_over_time()` to also allow calculating the increase of cumulative metrics rather than just summing samples together. Where would the line be in terms of which functions should be overloaded or not? One option would be to only allow `rate()` and `increase()` to be overloaded, as they are the most popular functions that would be used with counters.

#### `rate()` behaviour for deltas

If we were to implement function overloading for `rate()` and `increase()`, how exactly will it behave for deltas? A few possible ways to do rate calculation have been outlined, each with their own pros and cons.

Also to take into account are the new `smoothed` and `anchored` modifiers in the extended range selectors proposal.

A possible proposal would be:

* no modifier - just use use `sum_over_time()` to calculate the increase (and divide by range to get rate).
* `anchored` - same as no modifer. In the extended range selectors proposal, anchored will add the sample before the start of the range as a sample at the range start boundary before doing the usual rate calculation. Similar to the `smoothed` case, while this works for cumulative metrics, it does not work for deltas (if CT-per-sample is not implemented). To get the same output in the cumulative and delta cases given the same input to the initial instrumented counter, the delta case should use `sum_over_time()`.
* `smoothed` - Logic as described in [Lookahead and lookbehind](#lookahead-and-lookbehind-of-range).

One problem with reusing the range selector modifiers is that they are more generic than just modifiers for `rate()` and `increase()`, so adding delta-specific logic for these modifiers for `rate()` and `increase()` may be confusing.

### `delta_*` functions

An alternative to function overloading, but allowing more choices on how rate calculation can be done would be to introduce `delta_*` functions like `delta_rate()` and having range selector modifiers.

This has the problem of having to use different functions for delta and cumulative metrics (switching cost, possibly poor user experience).

### Treat as “mini-cumulative”

Deltas can be thought of as cumulative counters that reset after every sample. So it is technically possible to ingest as cumulative and on querying just use the cumulative functions.

This requires CT-per-sample (or some kind of precise CT tracking) to be implemented. Just zero-injection of StartTimeUnixNano would not work all the time. If there are samples at consecutive intervals, the StartTimeUnixNano for a sample would be the same as the TimeUnixNano for the preceding sample and cannot be injected.

The standard `rate()`/`increase()` functions do not work well with delta-specific characteristics, especially without CT-per-sample. The OTEL SDKs only emit datapoints when there is a change in the interval so samples might not come at consistent intervals. But `rate()` assumes samples in a range are equally spaced to figure out how much to extrapolate.

With CT-per-sample, `rate()` can make this information to more accurately calculate the intervals between samples. Assuming `rate()` continues to be constrained to only looking at the samples with timestamps within its bounds though, it will still not be able to accurately predict whether to extrapolate at the end of the time range is. The reason for extrapolating is that there might be a sample with timestamp outside of the range, but its CT is within the range of the query. With sparse delta series which only push updates when there is a change, a long gap between samples does not mean the series is definitively ending.

However, the experimental `anchored` and `smoothed` modifiers could be used in conjunction with CT-per-sample to be able to calculate `rate()` without needing to extrapolate (and so does not encounter the issue not being able to accurately guess when a series ends). The improvement of having CT-per-sample over [extending these modifiers but without CT-per sample](#rate-calculation-extensions-without-ct-per-sample) is that, aside from not needing delta special-casing, is that `smoothed` has better information about the actual interval for samples rather than having to assume samples are evenly spaced and continuous.

For samples missing missing StartTimeUnixNano, the CT can be set equal to the sample timestamp, indicating the value was recorded for a single instant in time. `rate()` might be able to work with this without any special adjustments (it would see sample interval is equal to 0 and this would stop any extrapolation).

The benefit of this "mini-cumulative" approach is that we would not need to introduce a new type (or subtype) for deltas, the current counter type definition would be sufficient for monotonic deltas. Additionally, `rate()` could be used without needing function overloading - deltas will be operated on as regular cumulative counters without special casing.

Additionally, having CT-per-sample could allow for non-monotonic OTELs sums for both cumulative and delta temporality to be supported as counters (as we will not need to use drops in the metric value to detect counter resets).

In comparison to the initial proposal: The distinguishing labels suggested in the initial proposal (like `__temporality__`) would not be necessary in terms of querying, however, they could be kept for enabling translation back into OTEL. Knowing the temporality could also be useful for understanding the raw data. `sum_over_time()` would still be able to be used on the ingested delta metrics. `__type__` would change from `gauge` to `counter`.

### How to proceed

Before committing to moving forward with any of the extensions , we should first gain practical experience with treating delta metrics as gauges and using `sum_over_time()` to query, and observe how the `smoothed` and `anchored` modifiers work in practice for cumulative metrics.

## Discarded alternatives

### Ingesting deltas alternatives

#### Convert to rate on ingest

Convert delta metrics to per-second rate by dividing the sample value with (`TimeUnixNano` - `StartTimeUnixNano`) on ingest, and also append `:rate` to the end of the metric name (e.g. `http_server_request_duration_seconds` -> `http_server_request_duration_seconds:rate`). So the metric ends up looking like a normal Prometheus counter that was rated with a recording rule.

The difference is that there is no interval information in the metric name (like :rate1m) as there is no guarantee that the interval from sample to sample stays constant.

To averages rates over more than the original collection interval, a new time-weighted average function is required to accommodate cases like the collection interval changing and having a query range which isn't a multiple of the interval.

This would also require zero timestamp injection or CT-per-sample for better rate calculations.

Users might want to convert back to original values (e.g. to sum the original values over time). It can be difficult to reconstruct the original value if the start timestamp is far away (as there are probably limits to how far we could look back). Having CT-per-sample would help in this case, as both the StartTimeUnixNano and the TimeUnixNano would be within the sample. However, in this case it is trivial to convert between the rated and unrated count, so there is no additional benefit of storing as the calculated rate. In that case, we should prefer to store the original value as that would cause less confusion to users who look at the stored values.

This also does not work for samples missing StartTimeUnixNano.

#### Add delta `__type__` label values

Extend `__type__` from PROM-39 with additional delta types for any counter-like types (e.g. `delta_counter`, `delta_histogram`). The original types (e.g. `counter`) will indicate cumulative temporality.

This would prevent the problems of mixups with the `counter` type that [Ingest as counter](#ingest-as-counter) has as it's a completely new type.

An additional `__monotonicity__` property would need to be added as well.

A downside is that querying for all counter types or all delta series is less efficient compared to the `__temporality__` case - regex matchers like `__type__=~”(delta_counter|counter)”` or `__type__=~”delta_.*”` would have to be used. (However, this does not seem like a particularly necessary use case to optimise for.)

Additionally, combining temporality and type means that every time a new type is added to Prometheus/OTEL, two `__type__` values would have to be added. This is unlikely to happen very often, so only a minor con.

This option was discarded because, for the initial proposal, we want to reuse the existing gauge type in Prometheus (since it is already used for deltas) instead of introducing changes to the Prometheus data model. If we later decide to extend the Prometheus types, it is better to treat temporality as a property of a counter rather than as part of the type itself, since temporality is an property that can apply to multiple metric types (for both counter and histograms).

#### Metric naming convention

Have a convention for naming metrics e.g. appending `_delta_counter` to a metric name. This could make the temporality more obvious at query time. However, assuming the type and unit metadata proposal is implemented, having the temporality as part of a metadata label would be more consistent than having it in the metric name.

### Querying deltas alternatives

#### Convert to cumulative on query

Delta to cumulative conversion at query time doesn’t have the same out of order issues as conversion at ingest. When a query is executed, it uses a fixed snapshot of data. The order the data was ingested does not matter, the cumulative values are correctly calculated by processing the samples in timestamp-order.

No function modification is needed - all cumulative functions will work for samples ingested as deltas.

However, it can be confusing for users that the delta samples they write are transformed into cumulative samples with different values during querying. The sparseness of delta metrics also do not work well with the current `rate()` and `increase()` functions.
