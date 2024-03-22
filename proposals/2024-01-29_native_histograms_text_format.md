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

Today it is only possible to export native histograms using the Protocol Buffers (protobuf) scrape format. Many users prefer the text format, and some client libraries, such as the Python client, want to avoid adding a dependency on protobuf. 

During a [dev summit in 2022](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit#bookmark=id.c3e7ur6rn5d2) there was consensus we would continue to support the text format. Including native histograms as part of the text format shows commitment to that consensus.

### Pitfalls of the current solution

Prometheus client libraries such as Python do not want to require a dependency on protobuf in order to expose native histograms, and in some languages protobuf is painful to use. Gating native histograms only to clients/users willing to use protobuf hurts adoption of native histograms, therefore, we would like a way to represent a native histogram in the text based format.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Support native histograms in the text format
* (Secondary) Encode/decode efficiency
* (Secondary) Ease of implementation for client libraries
* (Secondary) Human readibility of the format

Note that the goals of efficiency and human readability are commonly at odds with each other.

### Audience

Client library maintainers, OpenMetrics, and Prometheus scrape maintainers.

## Non-Goals

* Requiring backwards compatability (OpenMetrics 2.0 would be ok)

## How

Extend the OpenMetrics text format to allow structured values instead of only float values. This structured value will be used to encode a structure with the same fields as is exposed using the [protobuf exposition format](https://github.com/OpenObservability/OpenMetrics/pull/256). Starting with an example and then breaking up the format:
```
# TYPE nativehistogram histogram
nativehistogram {count:24,sum:100,schema:0,zero_threshold:0.001,zero_count:4,positive_span:[0:2,1:2],negative_span:[0:2,1:2],positive_delta:[2,1,-2,3],negative_delta:[2,1,-2,3]}
```
The metric will have no "magic" suffixes, then the value for each series is a custom struct format with the following fields:
* `sum: float64` - The sum of all observations for this histogram. Could be negative in cases with negative observations.
* `count: uint64` - The number of samples that were observed for this histogram.
* `schema: int32` - The schema used for this histogram, currently supported values are -4 -> 8.
* `zero_threshold: float64` - The width of the zero bucket.
* `zero_count: uint64` - The number of observations inside the zero bucket.
* `negative_span: []BucketSpan` - The buckets corresponding to negative observations, optional.
* `negative_delta: []int64` - The delta of counts compared to the previous bucket. 
* `positive_span: []BucketSpan` - The buckets corresponding to negative observations, optional.
* `positive_delta: []int64` - The delta of counts compared to the previous bucket. 

A bucket span is the combination of an `int32` offset and a `uint32` length. It is encoded as `<offset>:<length>`. Lists/arrays are encoded within square brackets with elements separated by commas. Compared to JSON this avoids consistently repeating keys and curly braces.

Positive infinity, negative infinity, and non number values will be represented as case insensitive versions of `+Inf`, `-Inf`, and `NaN` respectively in any field. This is the same behavior for values in OpenMetrics today.

Note that in this initial implementation float histograms are not supported.

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
