## Store and query classic histograms as native histograms with custom buckets

* **Owners:**
  * György (krajo) Krajcsovits [@krajorama](https://github.com/krajorama/) [gyorgy.krajcsovits@grafana.com](mailto:gyorgy.krajcsovits@grafana.com)

* **Contributors:**
  * Bartłomiej (Bartek) Płotka[@bwplotka](https://github.com/bwplotka) [bwplotka@gmail.com](mailto:bwplotka@gmail.com)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [histograms: custom bucket layouts](https://github.com/prometheus/prometheus/issues/11277)
  * [remote write 2.0 - explore histogram atomicity](https://github.com/prometheus/prometheus/issues/13410)

* **Other docs or links:**
  * [Previous version of this proposal in Google doc](https://docs.google.com/document/d/1aWNKUagsqUNlZWNjowOItx9JPueyuZ0ZWPyAhq6M8I8/edit#heading=h.kdvznfdr2b0o)
  * [RW Self-Contained Histograms](https://docs.google.com/document/d/1mpcSWH1B82q-BtJza-eJ8xMLlKt6EJ9oFGH325vtY1Q/edit?pli=1#heading=h.ueg7q07wymku)

> TL;DR: This design document proposes a way to implement efficient storage of classic histograms by avoiding the need to use multiple independent time series to store the bucket, count and sum information.
> This is a subset of a wider feature called custom bucket layouts for native histograms.

## Why

To support [RW Self-Contained Histograms](https://docs.google.com/document/d/1mpcSWH1B82q-BtJza-eJ8xMLlKt6EJ9oFGH325vtY1Q/edit?pli=1#heading=h.ueg7q07wymku) which is about the need to make writing histograms atomic, in particular to avoid a situation when series of a classic histogram are partially written to (remote) storage. For more information consult the referenced design document.

To make storing classic histograms more efficient by taking advantage of the design of native histograms.

Finally, fully custom bucket layouts is a larger project with wider scope. By reducing the scope we can have a shorter development cycle and offer a good feature and savings sooner.

### Pitfalls of the current solution

* Classic histograms are split into time series and remote writes are not atomic above series level.
* TCO (for some users this matters more than exponential buckets of full on native histograms, which require a migration effort to use)

## Goals

* No change to instrumentation.
* No change to the query side. *Might not be achieved in the first iteration/ever. The ingestion and storage part can be fully implemented without any changes to the query part. A compatibility layer for querying can be introduced later as needed.*
* Classic histogram emitted by the application must be written to (local/remote) storage in the efficient native histogram representation.
* Allow future extension for other bucket layouts that have already been requested multiple times (linear, log-linear, …).

### Audience

* Operator, administrator of Prometheus infrastructure that deals with scraping and storing data.
* Users of the query and remote read interface.

## Non-Goals

* New instrumentation for defining the custom buckets.
* Interoperability with (exponential bucket) native histograms.

## How

### Naming convention

For the sake of brevity will use the following wording:
* Classic histogram = classic histogram implying separate series for buckets, count and sum.
* Native histogram = a histogram that uses a single series to store all relevant information in complex data type samples.
* Exponential histogram = a native histogram with exponential buckets.
* Custom histogram = a native histogram with custom (i.e. user defined) buckets.

### Overview

This proposal aims to minimize the changes needed to achieve the goals, but also let us optimize later.

Enhance the internal representation of histograms (both float and [integer](https://github.com/prometheus/prometheus/blob/main/model/histogram/histogram.go)) with a nil-able slice of custom bucket definitions. No need to change spans/deltas/values slices.

The counters for the custom buckets should be stored as integer values if possible. To be compatible with existing precision of the classic histogram representation within a to be defined 𝜎. The GO statement `x == math.Trunc(x)` has an error of around `1e-16` - experimentally.

### Option 4 no suffix in series name

> Options 1,2,3 are in the original Google [doc](https://docs.google.com/document/d/1aWNKUagsqUNlZWNjowOItx9JPueyuZ0ZWPyAhq6M8I8/edit#heading=h.es6bovk9enxw).

In this option only instrumentation backwards compatibility is guaranteed(*). The user needs to switch to native histogram style queries, which makes this solution forward compatible with exponential histograms. Documented for example [here](https://grafana.com/docs/mimir/latest/visualize/native-histograms/#prometheus-query-language). In a later stage we could add an emulation layer on top of this to get backwards compatible queries.

*: there is still the option to keep scraping classic histograms series beside custom histograms to be able to use the old queries, in fact it’s a recommended migration tactic, see later.

### Scrape configuration

1. The feature is disabled if the feature flag [`native-histograms`](https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms) is disabled.
2. If native histograms feature is enabled, custom histograms can be enabled in `scrape_config` by setting the configration option `scrape_custom_histograms` to `true`.

Scenarios provided that the native histograms feature is enabled:
* If the scraped metric has custom bucket definitions and `scrape_classic_histograms` is enabled, the original classic histogram series with suffixes shall be generated. This is independent of the setting for custom histograms.
* If `scrape_custom_histograms` is disabled, no effect.
* If `scrape_custom_histograms` is enabled:
  * If the scrape histogram has exponential buckets, no effect. Exponential buckets have higher priority.
  * Otherwise the new custom histograms are scraped in a series without suffix.

> Note: enabling native histograms comes with all notes and warnings described in the documentation, in particular the impact on the `le` label for the classic histograms for certain clients. See "Note about the format of le and quantile label values" in [Native Histograms](https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms).

### Scrape

* Create the new representation in a series named `<metric>` without the `le` label. The resulting series name would be the same as if the user enabled exponential histograms. For example `http_request_latency_seconds_bucket`, `http_request_latency_seconds_count` and `http_request_latency_seconds_sum` will simply be stored as a one metric called `http_request_latency_seconds` from now on.
* Resulting samples at scrape time reuse the existing data structures for native histograms, but use a special schema number to indicate custom buckets. A sample would have either custom bucket definitions or exponential schema and buckets, but not both.
* If the histogram has exponential buckets during scrape then only the exponential buckets are kept and the custom buckets would be dropped.
* If all bucket counters and the overall counter of the histogram is determined to be a whole number, use integer histogram, otherwise use float histogram.
  * In the Prometheus text exposition format values are represented as floats. The dot (`.`) is not mandatory.
  * In the OpenMetrics text exposition [format](https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#numbers) floats and integers are explicitly distinguished by the dot (`.`) sign being present or not in the value.
  * In the Prometheus/OpenMetrics ProtoBuf [format](https://github.com/prometheus/client_model/blob/d56cd794bca9543da8cc93e95432cd64d5f99635/io/prometheus/client/metrics.proto#L115-L122) float and integer numbers are explicitly transferred in different fields.

### Exemplars

* Reuse the same logic as with exponential histograms. Roughly: parse the exemplars from the classic histogram, discard exemplars without timestamp and sort by timestamp before forwarding.

### Writing/storage

* Remote write protocol to support transferring custom bucket definitions as part of the current Histogram DTO.
* TSDB should reuse the existing chunk types.
  * If the sample has exponential schema and buckets, store the exponential schema and buckets as currently.
  * Otherwise if the sample has custom bucket definition and buckets, use a special schema number and store the custom bucket definitions at the beginning of the chunk once and then the bucket values as before. In the rare case when the bucket layout changes, start a new chunk to only store the custom bucket definitions once per chunk.

### Reading via PromQL

* Direct series selection of `metric{}` would look up `metric{}` and return the exponential histograms or custom histograms as found in the chunks.

  > Note: the [exposition format](https://prometheus.io/docs/prometheus/latest/querying/api/#native-histograms) of histograms in PromQL is already forward compatible with custom buckets as the data contains the boundaries and inclusion settings.
* Regex series selector of `__name__=~”metric.*”` would return `metric{}` and revert to the direct case.
* Direct series selection of `metric_bucket{}`, `metric_count{}` and `metric_sum{}` would return nothing as these won’t exist.
* The function histogram_quantile, histogram_fraction, histogram_stddev, histogram_stdvar would now potentially select custom bucket and exponential histogram samples at the same time.
  * This is a pure math problem to find a good approximation when this happens. Will be worked out in the implementation.
* The function histogram_count would now potentially select custom bucket and exponential histogram samples at the same time. The interpretation of count is the same for custom and exponential histograms so this is not a problem.
* The function histogram_sum would now potentially select custom bucket and exponential histogram samples at the same time. The interpretation of count is the same for custom and exponential histograms so this is not a problem.

### Migration path for users

Related CNCF slack [thread](https://cloud-native.slack.com/archives/C02KR205UMU/p1706087513992019?thread_ts=1706019629.852979&cid=C02KR205UMU).

Use case: neither custom histograms nor exponential histograms in use (i.e. both features are off).

* Enable feature to store custom bucket native histograms, scrape them in parallel to classic (via `scrape_classic_histograms` option), and do nothing else for a while (i.e. production usage still uses classic, change no dashboards and alerts.
* Let it sit for as long as your longest range in any query.
* Then, at will, switch over/duplicate dashboards, alerts, ... to native histogram queries.

  > Note: while it is tempting to write (native query) OR (classic query) , it can introduce strange behavior when looking at data at the beginning of the native histogram samples (both custom and exponential). Imagine you have a fairly long rate_interval (the problem exists for all intervals, but the longer, the more serious it gets), e.g. multiple days or so. While migrating to native histograms, you ingest classic and native histograms in parallel. Very soon, the first leg of the query above will yield a result, but it will be based just on a few samples of native histograms, or the last few minutes of the multi-day range.
* Once you are done, switch off scraping classic histograms (or drop via metric relabel as needed).

Use case: custom histograms feature is off, but exponential histograms (current native histograms feature) is on.

* For histograms that have no exponential histogram version, the same applies as above.
* For histograms that have exponential histogram version, nothing happens, exponential histograms will be kept.

### Documentation

* Feature should be marked as experimental, it depends on another experimental feature, namely native histograms.
* Configuration option to be documented.
* Impact on queries and PromQL functions to be specified.

### Data structures

New constant to define the schema number to mean custom buckets (e.g. 127 ?).

Remote write protocol

The `message.Histogram` type to be expanded with nullable repeated custom_buckets field that list the custom bucket definitions (except `+Inf`, which is implicit). There should be a comment which specifies which schema number means that we need to even look at this field. It should be a validation error to find this field null if the custom bucket schema number is used.

Internal representation

The `histogram.Histogram` and `histogram.FloatHistogram` types to get an additional field that has the custom bucket definitions or reference id for interned custom bucket definition. Doesn’t matter as it should be accessible via getter interface. (We’d have to see how the PromQL engine uses the bucket definitions to nail down what exact interface to put here.)

Chunk representation

We propose that the current integer histogram and float histogram chunk is expanded with custom bucket field encoding (and type is encoded in schema). Leaving exact format to PR author.

Chunk iterator

No change to interface. The raw chunk iterator can load the custom bucket definitions once and reuse that (like it does with counter reset hint header).

## Open questions

* How to enable the feature, what should be the name of the flags / configuration. Relation to native histograms feature.

## Answered questions

* Would we ever want to store the old representation and the new one at the same time?
  *Answer:* YES. Already should work via the `existing scrape_classic_histograms` option.
* What to do in queries if custom histogram and exponential histogram meet or customer histogram and float sample?
  *Answer:* same as today with float vs native histogram, that is calculate the result if it makes mathematical sense. For example multiplying a custom histogram with the number 2.0 makes sense. In case of histograms they need to rescaled to match their schema.
* Should we use a bigger chunk size for such custom histograms? To offset that we’d want to store the bucket layout in the chunk header. ~4K?
  *Answer:* NO. Classic histograms typically have less buckets than exponential native histograms which should offset any additional information encoded in the chunk.
* Do we allow custom histogram to be stored in the **same samples** where exponential histograms are stored?
  *Answer:* NO. Prefer exponential histogram if present.
  Does not affect the migration path since we’d require changing the queries first before turning on the feature.
  In case of out of order ingestion it may happen that upon read we still have different type samples for the same timestamp, in this case prefer exponential histogram over customer histogram. Similarly compaction should drop the custom histogram.
* Do we allow custom buckets to be stored in the **same series** but different samples, for example the arriving samples until timestamp T have custom buckets and then from T have exponential buckets.
  *Answer:* Yes, custom histograms are native histograms like exponential histograms. Switching between them is nothing else than a schema change, which is already happening now, i.e. we just have to cut a new chunk. Just that the “custom bucket boundary” schema doesn’t provide a mergeability guarantee.
* Do we add a metric relabel config to govern the feature on a metric level?
  *Answer:* NO. Already possible to achieve by enabling `scrape_classic_histograms` and selectively dropping metrics at scrape.
* Would we want to implement the conversion from classic histogram to custom histogram on the remote write receiver side?
  *Answer:* NO. It would require stateful receiver and probably transaction support on sender side, both of which we’d want to avoid.
* Would we want to make the remote write endpoint configurable in storing the custom histogram? Potentially it could resolve the custom histogram into a classic histogram and store the series as separate again to only solve for the atomicity , but not performance.
  *Answer:* YES, but not in the first iteration, not part of MVP.

## Alternatives

### Option 1 with suffix in series name (discarded option)

In this idea, the resulting series has an extra suffix to distinguish from exponential native histograms. Compatibility with current queries is supported.

#### Writing

* Store the new representation in a series name called `<metric>_bucket` without the `le` label (e.g. `http_request_latency_seconds_bucket`, `http_request_latency_seconds_count` and `http_request_latency_seconds_sum` will simply be stored as a one metric `http_request_latency_seconds_bucket`) According to some not so scientific measurement, `_count` and `_bucket` is most queried in our environment, `_sum` lagging behind. But _bucket has higher cardinality, so it makes sense to target that. Probably due to RED metrics requiring rate (count) and percentile (buckets).
* Introduce two new kinds of chunk types that can store the custom bucket layout information at the beginning, but otherwise can reuse the same technology of existing exponential bucket native histograms.

#### Reading via PromQL

* Direct series selection of `metric{}` would look up `metric{}` and only return the exponential histograms.
* Regex series selector of `__name__=~”metric.*”` would return `metric{}` and `metric_bucket{}` by default. What about `le` labels? `_count`, `_sum` ?
  * When listing postings, every time we hit a metric called metric_bucket we could generate the corresponding metric_count and metric_sum, but what if we are lying? This sounds bad.
  * We could store postings for the `_bucket`, `_count`, `_sum` series but they would point to the same chunks. Basically keep the reverse index for all labels.
* Direct series selection of `metric_bucket{}` would look up `metric_bucket{}` and load the resulting floats or decode custom histograms.
* Direct series selection of `metric_count{}` would look up `metric_count{}` and `metric_bucket{}`.
* Direct series selection of `metric_sum{}` would look up `metric_sum{}` and `metric_bucket{}`.
  * For any lookup for a metric name that ends in `_count`, `_sum` also select the metric name ending in `_bucket`. This can be done inside TSDB (e.g. Queryable Select will return “old” classic histogram series, even though TSDB would store those as native histograms).

For remote write receivers who would like to receive new native histograms with custom bucketing, they can create a similar algorithm to the above for initial migration purposes.

#### Reading via remote read API

For timeseries/samples : as above, convert at select for sample return.
For chunks: return raw chunk.

#### Metadata

Not considering weird cases where series names are overlapped by users.
APIs: should return the original series names and label values, including “le”

```
/api/v1/series
/api/v1/labels
/api/v1/label/<label_name>/values
/api/v1/metadata
```

Type query: given a metric selector we could return a single type: float series , custom histogram, exponential histogram.

### Option 2 all suffixes (discarded option)

This is the same as option 1, but we keep the count and sum as separate series. So only `metric_bucket{}` series are merged.

The advantage being that looking up with a regex matcher on the metric name will just work.

### Option 3 no suffix in series name (discarded option)

Does not use the same series as classic histograms, rather the same as the native histograms, but compatibility with current queries is supported.

#### Writing

* Store the new representation in a series named `<metric>` without the `le` label. (e.g. `http_request_latency_seconds_bucket`, `http_request_latency_seconds_count` and `http_request_latency_seconds_sum` will simply be stored as a one metric `http_request_latency_seconds`).
  * The resulting series name would be the same as if the user enabled exponential native histogram buckets.
* Resulting samples would have custom bucket definitions and exponential schema and other information; as well as integer counters delta encoded for the exponential histograms and absolute float counters for the custom buckets.
  * We don’t have a chunk format for integer+float mixed together so this would have to be implemented.

#### Reading via PromQL

* Direct series selection of `metric{}` would look up `metric{}` and only return the exponential histograms.
  This can happen behind the select interface, but select will need a hint to know which data to return to avoid decoding data that’s not relevant.
* Regex series selector of `__name__=~”metric.*”` would return `metric{}` by default. What about `le` labels? `_bucket`, `_count`, `_sum` ?
  * When listing postings, every time we hit a metric called metric_bucket we could generate the corresponding metric_count and metric_sum, but what if we are lying? This sounds bad.
  * We could store postings for the `_bucket`, `_count`, `_sum` series but they would point to the same chunks.
* Direct series selection of `metric_bucket{}` would have to look up `metric_bucket{}` and `metric{}` and return the float buckets decoded directly or from the custom histogram.
  * This can happen behind the select interface, but select will need a hint to know which data to return to avoid decoding data that’s not relevant.
* Direct series selection of `metric_count{}` similar to buckets, look up both `metric{}` and `metric_count{}`.
* Direct series selection of `metric_sum{}` similar to buckets, look up both `metric{}` and `metric_sum{}`.

#### Reading via remote read API

For timeseries/samples : as above, convert at select for sample return.
For chunks: return raw chunk.

#### Metadata

Not considering weird cases where series names are overlapped by users.
APIs: should return the original series names and label values, including “le”

```
/api/v1/series
/api/v1/labels
/api/v1/label/<label_name>/values
/api/v1/metadata
```

For some series we’d have to say it’s both custom and exponential histogram.

#### Comparing options

Option 1, 2, 3 provide full compatibility however the index is kept as is, losing some performance benefits of native histograms. Gives no incentive for the user to move to native histograms and Prometheus would have to support this indefinitely.
* Migration path to use the feature: 1. Enable feature.
* Migration path to exponential native histograms: 1. Update queries to query both classic histograms and native histograms. 2. Start scraping exponential histograms along classic histograms. 3. Stop scraping classic histograms.

Option 4 (stage1) provides backward compatible instrumentation for the legacy systems and when the user just wants to reduce TCO. The tradeoff is that the user has to update their queries.
* Migration path to use the feature: 1. Update queries to query both classic histograms and native histograms. 2. Enable feature (if we reuse scrape_classic_histograms scrape option we could have the classic histograms as well). 3. Stop storing classic series after a transition period.
* Migration path to exponential native histograms:
* If feature is in use: 1. Enable native histograms.
* If feature is not in use: skip custom buckets feature. 1. Update queries to query both classic histograms and native histograms. 2. Start scraping exponential histograms along classic histograms. 3. Stop scraping classic histograms.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
