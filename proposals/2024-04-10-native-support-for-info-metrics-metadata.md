# Simplify joins with info metrics in PromQL

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) [arve.knudsen@grafana.com](mailto:arve.knudsen@grafana.com)

* **Implementation Status:** Partially implemented

* **Related Issues and PRs:**
  * [WIP: Info PromQL function prototype](https://github.com/grafana/mimir-prometheus/pull/598)

* **Other docs or links:**
  * [Proper support for OTEL resource attributes](https://docs.google.com/document/d/1FgHxOzCQ1Rom-PjHXsgujK8x5Xx3GTiwyG__U3Gd9Tw/edit#heading=h.unv3m5m27vuc)
  * [Special treatment of info metrics in Prometheus](https://docs.google.com/document/d/1ebhGNLs3uhdeprJCullM-ywA9iMRDg_mmnuFAQCloqY/edit#heading=h.2rmzk7oo6tu8)
  * [Scenarios scratch pad](https://docs.google.com/document/d/1nV6N3pDfvZhmG2658huNbFSkz2rsM6SpkHabp9VVpw0/edit#heading=h.luf3yapzr29e)

> This proposal collects the requirements and implementation proposals for simplifying joins with info type metrics in PromQL.

## Why

Currently, enriching Prometheus query results with corresponding labels from info metrics is challenging.
More specifically, it requires writing advanced PromQL to join with the info metric in question.
Take as an example querying HTTP request rates per K8s cluster and status code, while having to join with the `target_info` metric to obtain the `k8s_cluster_name` label:

```promql
sum by (k8s_cluster_name, http_status_code) (
    rate(http_server_request_duration_seconds_count[2m])
  * on (job, instance) group_left (k8s_cluster_name)
    target_info
)
```

The `target_info` metric is in fact the motivation for this proposal, as it's how Prometheus encodes OpenTelemetry (OTel for short) [resource attributes](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md).
As a result, it's a very important info metric for those using Prometheus as an OTel backend.
OTel resource attributes model metadata about the environment producing metrics received by the backend (e.g. Prometheus), and Prometheus persists them as labels of `target_info`.
Typically, OTel users want to include some of these attributes (as `target_info` labels) in their query results, to correlate them with entities of theirs (e.g. K8s pods).

Based on user demand, it would be preferable if Prometheus were to have better UX for enriching query results with info metrics labels, especially with OTel in mind.
There are other problems with Prometheus' current method of including info metric labels in queries, beyond just the technical barrier:
* Explicit knowledge of each info metric's identifying labels must be embedded in join queries for when you wish to enrich queries with data (non-identifying) labels from info metrics.
  * A certain pair of OTel resource attributes (`service.name` and `service.instance.id`) are currently assumed to be the identifying pair and mapped to `target_info`'s `job` and `instance` labels respectively, but this may become a dynamic property of the OTel model.
  * Both attributes are in reality optional, so either of them might be missing (`service.name` is only mandatory for OTel SDK clients).
  * If both identifying attributes are missing, `target_info` isn't generated (there being no identifying labels to join against).
* If an info metric's data (non-identifying) labels change (a situation that should become more frequent with OTel in the future, as the model will probably start allowing for non-identifying resource attribute mutations), join queries against the info metric (e.g. `target_info`) will temporarily fail due to resolving the join keys to two different metrics, until the old metric is marked stale (by default after five minutes).

If Prometheus could persist info metrics' identifying labels (e.g. `job` and `instance` for `target_info`), human knowledge of the correct identifying labels may become unnecessary when "joining" with info metrics.
Information about info metric identifying labels is present in at least the OpenMetrics protobuf exposition format (the OpenMetrics text exposition format unfortunately lacks this capability).
It can also easily be deduced when ingesting metrics from OTLP (OTel Protocol).
Intrinsic knowledge of info metrics' identifying labels could also help in solving temporary conflicts between old and new versions of info metrics, when data (non-identifying) labels change.
Another possible positive outcome might be dedicated support in UIs (e.g. Grafana) for visualizing the resource attributes of OTel metrics.

### Pitfalls of the current solution

Prometheus currently persists info metrics as if they were normal float samples.
This means that knowledge of info metrics' identifying labels are lost, and you have to base yourself on convention when querying them (for example that `target_info` should have `job` and `instance` as identifying labels).
There's also no particular support for enriching query results with info metric labels in PromQL.
The consequence is that you need relatively expert level PromQL knowledge to include info metric labels in your query results; as OTel grows in popularity, this becomes more and more of a problem as users will want to include certain labels from `target_info` (corresponding to OTel resource attributes).
Without persisted info metric metadata, one can't build more user friendly abstractions (e.g. a PromQL function) for including OTel resource attributes (or other info metric labels) in query results.
Neither can you build dedicated UI for OTel resource attributes (or other info metric labels).

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Persist info metrics with labels categorized as either identifying or non-identifying (i.e. data labels).
* Track when info metrics' set of identifying labels changes. This shouldn't be a frequent occurrence, but it should be handled.
  * When enriching a query result's labels with data labels from info metrics, it should be considered per timestamp what are each potentially matching info metric's identifying labels (since the identifying label set may change over time).
* Automatically treat the old version of an info metric as stale for query result enriching purposes, when its data labels change (producing a new time series, but with same identity from an info metric perspective).
  * When enriching a query result's labels with data labels from info metrics, and there are several matches with equally named info metrics (e.g. `target_info`) for a timestamp, the one with the newest sample wins (others are considered stale).
* Add TSDB API for, given a certain time series and a certain timestamp, getting data labels, potentially filtered by certain matchers, from info metrics with identifying labels in common with the time series in question.
  * If no data label matchers are provided, _all_ the data labels of found info metrics are added to the resulting time series.
  * If data label matchers are provided, only info metrics with matching data labels are considered.
  * If data label matchers are provided, _precisely_ the data labels specified by the label matchers are added to the returned time series.
  * If data label matchers are provided, time series are only included in the result if matching data labels from info metrics were found.
  * A data label matcher like `k8s_cluster_name=~".+"` guarantees that each returned time series has a non-empty `k8s_cluster_name` label, implying that time series for which no matching info metrics have a data label named `k8s_cluster_name` (including the case where no matching info metric exists at all) will be excluded from the result.
  * A special case: If a data label matcher allows empty labels (equivalent to missing labels, e.g. `k8s_cluster_name=~".*"`), it will not exclude time series from the result even if there's no matching info metric.
  * A data label matcher like `__name__="target_info"` can be used to restrict the info metrics used.
    However, the `__name__` label itself will not be copied.
  * Label collisions: The input instant vector could already contain labels that are also part of the data labels of a matching info metric.
    Furthermore, since multiple differently named info metrics with matching identifying labels might be found, those might have overlapping data labels.
    In this case, the implementation has to check if the values of the affected labels match or are different.
    The former case is not really a label collision and therefore causes no problem.
    In the latter case, however, an error has to be returned to the user.
    The collision can be resolved by constraining the labels via data label matchers.
    And of course, the user always has the option to go back to the original join syntax (or, even better, avoiding ingesting conflicting info metrics in the first place).
* Simplify enriching of query results with info metric data (non-identifying) labels in PromQL, e.g. via a new function, based on aforementioned TSDB API.

### Audience

Prometheus maintainers.

## Non-Goals

## How

* Introduce a new info metric sample type, to track the info metric's identifying label set over time (in case it changes).
* Augment the head and block indexes with indexes of info metrics, for easy finding of info metrics matching time series.
  * The TSDB head and every block register their respective info metrics in a corresponding index, with the different identifying label sets each info metric has had over its lifetime.
* Augment the OTLP endpoint to specify `target_info`'s identifying labels when ingesting write requests, and to store it as the native info metric type.
* Add a method to the TSDB API for matching info metric data labels to a time series, given a certain timestamp and potentially data label matchers - the method will use the aforementioned head and block info metric indexes.
  * Candidate info metrics are found by searching the info metric index for info metrics with identifying labels contained in the input label set.
    * Each candidate info metric's identifying label set _for the timestamp in question_, is obtained from the info metric's samples.
    * If that identifying label set is not a match, the info metric is ignored.
    * If several info metrics with the same name are found, the one with the latest sample is chosen (i.e., older metrics are considered stale).
  * Data labels are picked from the found info metrics according to the rules defined in the Goals section.
    * Each info metric's data labels are determined by taking those of the metric's labels which are not in the identifying label set.
* Simplify the inclusion of info metric labels in PromQL through a new `info` function: `info(v instant-vector[, ls label-selector])`.
  This function will be UI for the aforementioned TSDB API.

Using the `info` function, we can simplify the previously given PromQL join example as follows:

```
sum by (k8s_cluster_name, http_status_code) (
  info(
    rate(http_server_request_duration_seconds_count[2m]),
    {k8s_cluster_name=~".+"}
  )
)
```

TODO:

* Specify detection of info metric identifying labels for other ingestion methods than OTLP.
* Define how this functionality would work together with OOO samples.

## Alternatives

The section stating potential alternatives. Highlight the objections reader should have towards your proposal as they read it. Tell them why you still think you should take this path [[ref](https://twitter.com/whereistanya/status/1353853753439490049)]

1. This is why not solution Z...

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
