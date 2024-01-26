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

> Options 1,2,3 are in the original Google [doc](https://docs.google.com/document/d/1aWNKUagsqUNlZWNjowOItx9JPueyuZ0ZWPyAhq6M8I8/edit#heading=h.kdvznfdr2b0o).

In this option only instrumentation backwards compatibility is guaranteed(*). The user needs to switch to native histogram style queries, which makes this solution forward compatible with exponential histograms. Documented for example [here](https://grafana.com/docs/mimir/latest/visualize/native-histograms/#prometheus-query-language). In a later stage we could add an emulation layer on top of this to get backwards compatible queries.

*: there is still the option to keep scraping classic histograms series beside custom histograms to be able to use the old queries, in fact it’s a recommended migration tactic, see later.

### Scrape

* Create the new representation in a series named `<metric>` without the `le` label. The resulting series name would be the same as if the user enabled exponential histograms. For example `http_request_latency_seconds_bucket`, `http_request_latency_seconds_count` and `http_request_latency_seconds_sum` will simply be stored as a one metric called `http_request_latency_seconds` from now on.
* Resulting samples at scrape time reuse the existing data structures for native histograms, but use a special schema number to indicate custom buckets. A sample would have either custom bucket definitions or exponential schema and buckets, but not both. It would be the exponential buckets that would be preferred by scrape if both are present and custom buckets would be dropped.
* If all bucket counters and the overall counter of the histogram is determined to be a whole number, use integer histogram, otherwise use float histogram.
  * In the Prometheus text exposition format values are represented as floats. The dot (`.`) is not mandatory.
  * In the OpenMetrics text exposition [format](https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#numbers) floats and integers are explicitly distinguished by the dot (`.`) sign being present or not in the value.
  * In the Prometheus/OpenMetrics ProtoBuf [format](https://github.com/prometheus/client_model/blob/d56cd794bca9543da8cc93e95432cd64d5f99635/io/prometheus/client/metrics.proto#L115-L122) float and integer numbers are explicitly transferred in different fields.

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

### Data structures

New constant to define the schema number to mean custom buckets (e.g. 127 ?).

Remote write protocol

The `message.Histogram` type to be expanded with nullable repeated custom_buckets field that list the custom bucket definitions (except `+Inf`, which is implicit). There should be a comment which specifies which schema number means that we need to even look at this field. It should be a validation error to find this field null if the custom bucket schema number is used.

Internal representation

The `histogram.Histogram` and `histogram.FloatHistogram` types to get an additional field that has the custom bucket definitions or reference id for interned custom bucket definition. Doesn’t matter as it should be accessible via getter interface. (We’d have to see how the PromQL engine uses the bucket definitions to nail down what exact interface to put here.)

Chunk representation

TBD, leaving to [beorn](beorn@grafana.com), but we can assume that the current integer histogram and float histogram chunk is just expanded with custom bucket definitions encoded after headers if the schema is set.

Chunk iterator

No change to interface. The raw chunk iterator can load the custom bucket definitions once and reuse that (like it does with counter reset hint header).

## Open questions

* How to enable the feature, what should be the name of the flags / configuration. Relation to native histograms feature.

## Answered questions

* Would we ever want to store the old representation and the new one at the same time?
  *Answer:* YES. Already should work via the `existing scrape_classic_histograms` option.
* What to do in queries if custom bucket and native histogram meet?
  *Answer:* same as today with float vs native histogram.
* Should we use a bigger chunk size for such custom histograms? To offset that we’d want to store the bucket layout in the chunk header. ~4K?
  *Answer:* NO. Classic histograms typically have less buckets than exponential native histograms which should offset any additional information encoded in the chunk.
* Do we allow custom buckets to be stored in the **same samples** where exponential buckets are stored?
  *Answer:* NO. Prefer exponential buckets if present.
  Does not affect the migration path since we’d require changing the queries first before turning on the feature.
* Do we allow custom buckets to be stored in the **same series** but different samples, for example the arriving samples until timestamp T have custom buckets and then from T have exponential buckets.
  *Answer:* Yes, custom histograms are native histograms like exponential histograms. Switching between them is nothing else than a schema change, which is already happening now, i.e. we just have to cut a new chunk. Just that the “custom bucket boundary” schema doesn’t provide a mergeability guarantee.
* Do we add a metric relabel config to govern the feature on a metric level?
  *Answer:* NO. Already possible to achieve by enabling `scrape_classic_histograms` and selectively dropping metrics at scrape.
* Would we want to implement the conversion from classic histogram to custom histogram on the remote write receiver side?
  *Answer:* NO. It would require stateful receiver and probably transaction support on sender side, both of which we’d want to avoid.
* Would we want to make the remote write endpoint configurable in storing the custom histogram? Potentially it could resolve the custom histogram into a classic histogram and store the series as separate again to only solve for the atomicity , but not performance.
  *Answer:* YES, but not in the first iteration, not part of MVP.

## Alternatives

> Options 1,2,3 and a comparision is in the original Google [doc](https://docs.google.com/document/d/1aWNKUagsqUNlZWNjowOItx9JPueyuZ0ZWPyAhq6M8I8/edit#heading=h.kdvznfdr2b0o).

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
