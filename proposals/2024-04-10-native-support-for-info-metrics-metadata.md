## Native Support for Info Metrics Metadata

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) [arve.knudsen@grafana.com](mailto:arve.knudsen@grafana.com)

* **Implementation Status:** Partially implemented

* **Related Issues and PRs:**
  * [WIP: Info PromQL function prototype](https://github.com/grafana/mimir-prometheus/pull/598)

* **Other docs or links:**
  * [Proper support for OTEL resource attributes](https://docs.google.com/document/d/1FgHxOzCQ1Rom-PjHXsgujK8x5Xx3GTiwyG__U3Gd9Tw/edit#heading=h.unv3m5m27vuc)
  * [Special treatment of info metrics in Prometheus](https://docs.google.com/document/d/1ebhGNLs3uhdeprJCullM-ywA9iMRDg_mmnuFAQCloqY/edit#heading=h.2rmzk7oo6tu8)

> This proposal collects the requirements and implementation proposals for enhancing Prometheus with native support for info metrics metadata.

## Why

Currently Prometheus "forgets" which are the identifying labels of info metrics upon ingestion, even though this information is present in at least the OpenMetrics protobuf exposition format (the OpenMetrics text exposition format unfortunately lacks this capability).
The fact that Prometheus lacks a notion of which are info metrics' identifying labels leads to certain problems:

* Explicit knowledge of each info metric's identifying labels must be embedded in join queries for when you wish to enrich queries with data (non-identifying) labels from info metrics.
* Complex join queries must be written in order to enrich time series with corresponding labels from info metrics.
  This is particularly problematic in the OpenTelemetry (AKA OTel) context, since users depend on (joining with) the `target_info` info metric in order to add relevant [resource attributes](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md) back to their Prometheus metrics.
* If an info metric's data (non-identifying) labels change (a situation that should become more frequent with OTel in the future, as the model will probably start allowing for non-identifying resource attribute mutations), join queries against the info metric (e.g. `target_info`) will temporarily fail due to resolving the join keys to two different metrics, until the old metric is marked stale (by default after five minutes).

Especially in order to provide the best possible OTel experience, the info metric (`target_info` in the case of OTel) staleness problem needs to be solved, so users won't experience temporarily failing join queries while trying to include OTel resource attributes.
Also, it would be much better if we could provide a simpler query experience where the user doesn't have to know how to write PromQL joins (a fairly complex matter), in order to include e.g. OTel resource attributes.
Another possible positive outcome might be dedicated support in the Grafana UI for visualizing the resource attributes of each OTel metric.

### Pitfalls of the current solution

Prometheus currently persists info metrics as if they were normal float samples.
This means that knowledge of info metrics' identifying labels are lost, and you have to base yourself on convention when querying on them (for example that `target_info` should have `job` and `instance` as identifying labels).
The consequence is that you need relatively expert level PromQL knowledge to include info metric labels in your query results; as OTel grows in popularity, this becomes more and more of a problem as users will want to include certain labels from `target_info` (corresponding to OTel resource attributes).
Without persisted info metric metadata, one can't build more user friendly abstractions (e.g. a PromQL function) for including OTel resource attributes (or other info metric labels) in query results. Neither can you build dedicated UI for OTel resource attributes (or other info metric labels).

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Persist info metrics with known identifying labels as a new info metric sample type.
* Store for each info metric sample (of the new type) which are the identifying labels.
* Store in the TSDB immediately that the previous version of an info metric is stale, when its data labels change.
* Add TSDB API for, given a certain time series and a certain timestamp, getting data labels, potentially filtered by certain matchers, from info metrics with identifying labels in common with the time series in question.
* Simplify inclusion of info metric labels in PromQL.

### Audience

Prometheus maintainers.

## Non-Goals

## How

* A new info metric sample type will be introduced, where the sample value is the info metric's identifying labels.
* The head and block indexes will be augmented with indexes of info metrics.
* A method will be added to the TSDB API for matching info metric data labels to a time series, given a certain timestamp and potentially data label matchers - the method will use the aforementioned head and block info metric indexes.
* Thanks to the head and block info metric indexes, the info metric staleness problem should be solved, since one can pick the latest version of the info metric for overlapping time ranges.
* We propose simplifying the inclusion of info metric labels in PromQL through a new `info` function (TODO: describe).

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
