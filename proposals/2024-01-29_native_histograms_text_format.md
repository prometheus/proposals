## Native Histograms Text Format

* **Owners:**
  * Chris Marchbanks [@csmarchbanks](https://github.com/csmarchbanks)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [Native Histogram Support in client_python](https://github.com/prometheus/client_python/issues/918)
  * [OpenMetrics Protobuf format PR](https://github.com/OpenObservability/OpenMetrics/pull/256)

* **Other docs or links:**
  * [Design Doc for choosing a proposal](https://docs.google.com/document/d/1qoHf24cKMpa1QHskIjgzyf3oFhIPvacyJj8Tbe6fIrY/edit#heading=h.5sybau7waq2q)

> TL;DR: This design doc is proposing a format for exposing native histograms in the OpenMetrics text format.

## Why

Today it is only possible to export native histograms using the classic (not OpenMetrics) Protocol Buffers (protobuf) scrape format. Many users prefer the text format, and some client libraries, such as the Python client, want to avoid adding a dependency on protobuf. Prometheus content negotiation prefers OpenMetrics to the classic Prometheus text based format, therefore to support native histograms in Prometheus the OpenMetrics text format will also need to support native histograms.

There is already an open pull request (see Related Issues and PRs above) to add support for native histograms to OpenMetrics, and during a [dev summit in 2022](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit#bookmark=id.c3e7ur6rn5d2) there was consensus we would continue to support the text format for new features as well. Including native histograms as part of the text format shows commitment to that consensus.

### Pitfalls of the current solution

Prometheus client libraries such as Python do not want to require a dependency on protobuf in order to expose native histograms, and in some languages protobuf is painful to use. Gating native histograms only to clients/users willing to use protobuf hurts adoption of native histograms, therefore, we would like a way to represent a native histogram in the text based format.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Support native histograms in the text format
* (Secondary) Encode/decode efficiency
* (Secondary) Ease of implementation for client libraries
* (Secondary) Human readability of the format

Note that the goals of efficiency and human readability are commonly at odds with each other.

### Audience

Client library maintainers, OpenMetrics, and Prometheus scrape maintainers.

## Non-Goals

* Requiring backwards compatability (OpenMetrics 2.0 would be ok), and especially forwards compatability (not required in the OpenMetrics spec).

## How

Extend the OpenMetrics text format to allow structured values instead of only float values for specific series of a histogram type. This structured value will be used to encode a structure with the same fields as is exposed using the [protobuf exposition format](https://github.com/prometheus/client_model/blob/master/io/prometheus/client/metrics.proto). Starting with examples and then breaking up the format:
```
# TYPE nativehistogram histogram
# HELP nativehistogram Is a basic example of a native histogram.
nativehistogram {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]}

# TYPE hist_with_labels histogram
# HELP hist_with_labels Is an example of a native histogram with labels.
hist_with_labels{foo="bar",baz="qux"} {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]}

# TYPE hist_with_classic_buckets histogram
# HELP hist_with_classic_buckets Is an example of native and classic histograms together.
hist_with_classic_buckets {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]}
hist_with_classic_buckets_bucket{le="0.001"} 4
hist_with_classic_buckets_bucket{le="+Inf"} 24
hist_with_classic_buckets_count 24
hist_with_classic_buckets_sum 100
```

Native histograms will share the "histogram" type with classic histograms. Classic and native histograms can be differentiated by looking at the "magic" suffixes for classic histogram series (`_bucket`, `_count`, `_sum`), and no suffix for native histogram series. This allows producers to expose native histograms and classic histograms together if desired, such as desiring custom bucket boundaries. An optional `_created` series can be created if desired just like a classic histogram as well.

The value for each series of a native histogram is a custom struct format with the following fields inside curly braces:
* `sum: float64` - The sum of all observations for this histogram. Could be negative in cases with negative observations.
* `count: uint64` - The number of samples that were observed for this histogram.
* `schema: int32` - The schema used for this histogram, currently supported values are -4 -> 8.
* `zero_threshold: float64` - The width of the zero bucket.
* `zero_count: uint64` - The number of observations inside the zero bucket.
* `negative_spans: []BucketSpan` - The buckets corresponding to negative observations, optional.
* `negative_deltas: []int64` - The delta of counts compared to the previous bucket, optional.
* `positive_spans: []BucketSpan` - The buckets corresponding to negative observations, optional.
* `positive_deltas: []int64` - The delta of counts compared to the previous bucket, optional.

A bucket span is the combination of an `int32` offset and a `uint32` length. It is encoded as `<offset>:<length>`. Lists/arrays are encoded within square brackets with elements separated by commas. Compared to JSON this avoids consistently repeating keys and curly braces. White space is not allowed inside of the structure to make a value as easy as possible to parse.

Positive infinity, negative infinity, and non number values will be represented as case insensitive versions of `+Inf`, `-Inf`, and `NaN` respectively in any field. This is the same behavior for values in OpenMetrics today.

Note that in this initial implementation float histograms are not supported. Float histograms are rarely used in exposition, and OpenMetrics does not support classic float histograms either. Support could be added in the future by adding fields for `count_float`, `zero_count_float`, `negative_counts`, and `positive_counts`.

If native histograms and a classic histogram are exposed simultaneously the native histogram must come first for any labelset. For example:
```
# TYPE hist_with_classic_buckets histogram
# HELP hist_with_classic_buckets Is an example of combining native and classic histograms for two labelsets.
hist_with_classic_buckets{foo="bar"} {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]}
hist_with_classic_buckets_bucket{foo="bar",le="0.001"} 4
hist_with_classic_buckets_bucket{foo="bar",le="+Inf"} 24
hist_with_classic_buckets_count{foo="bar"} 24
hist_with_classic_buckets_sum{foo="bar"} 100
hist_with_classic_buckets_created{foo="bar"} 1717536092
hist_with_classic_buckets{foo="baz"} {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]}
hist_with_classic_buckets_bucket{foo="baz",le="0.001"} 4
hist_with_classic_buckets_bucket{foo="baz",le="+Inf"} 24
hist_with_classic_buckets_count{foo="baz"} 24
hist_with_classic_buckets_sum{foo="baz"} 100
hist_with_classic_buckets_created{foo="baz"} 1717536098
```

Finally, multiple exemplars will also be supported in the exposition format by providing a list of exemplars at the end of any line, separated by `#`. Note that having spaces around the hashes is required and matches the [ABNF specification in OpenMetrics](https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#abnf). For example:
```
# TYPE exemplar_example histogram
# HELP exemplar_example Is an example of a native histogram with exemplars.
nativehistogram {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_spans:[0:2,1:2],negative_spans:[0:2,1:2],positive_deltas:[2,1,-2,3],negative_deltas:[2,1,-2,3]} # {trace_id="KOO5S4vxi0o"} 0.67 # {trace_id="oHg5SJYRHA0"} 9.8 1520879607.789
```

### Backwards compatibility and semantic versioning

After discussions with a few people it is believed that these changes can be made in a 1.x release of OpenMetrics. OpenMetrics 1.x parsers that support native histograms will still be able to read OpenMetrics 1.0 responses, therefore this change is backwards compatible. However, this change is not forwards compatible, i.e. an OpenMetrics 1.0 parser will not be able to read an OpenMetrics >= 1.1 response. Any producers implementing native histograms MUST also implement content negotiation and fall back to OpenMetrics 1.0.0, and therefore not expose native histograms, if a supported version cannot be negotiated. Note that the behavior to fall back to 1.0.0 is already part of the [OpenMetrics spec](https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#protocol-negotiation).

Until a version of OpenMetrics is released that contains a stable version of native histograms consumers can determine if native histograms may be present by asking for a `nativehistogram` pre-release identifier. For example,
```
Accept: application/openmetrics-text;version=1.1.0-nativehistogram.*,application/openmetrics-text;version=1.0.0,text/plain;version=0.0.4
```
would mean the consumer can accept any nativehistogram enabled pre-release version of OpenMetrics 1.1.0, the base 1.0.0 version of OpenMetrics, or the 0.0.4 version of the classic Prometheus text format. Producers must include the proper content type for their version, such as the first nativehistogram pre-release:
```
Content-Type: application/openmetrics-text;version=1.1.0-nativehistogram.0
```

## Alternatives

### Do nothing

One valid option is to avoid this extra format and require anyone who desires to use native histograms to use protobuf for exposition. It would go against the consensus of the Prometheus team members from 2022 however.

### Alternate exposition formats

See the alternate exposition formats proposed in the [design document](https://docs.google.com/document/d/1qoHf24cKMpa1QHskIjgzyf3oFhIPvacyJj8Tbe6fIrY/edit#heading=h.5sybau7waq2q). The other formats generally added in additional readability/verbosity at the expense of performance.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Implement an encoder and parser in client_python
* [ ] Implement an experimental parser in the Prometheus server
* [ ] Update OpenMetrics with formalized syntax
