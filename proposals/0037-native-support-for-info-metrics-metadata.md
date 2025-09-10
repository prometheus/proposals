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

Info metrics are [defined by the OpenMetrics specification](https://github.com/prometheus/OpenMetrics/blob/v1.0.0/specification/OpenMetrics.md#info) as "used to expose textual information which SHOULD NOT change during process lifetime".
Furthermore the OpenMetrics specification states that info metrics ["MUST have the suffix `_info`"](https://github.com/prometheus/OpenMetrics/blob/v1.0.0/specification/OpenMetrics.md#info-1).
Despite the latter OpenMetrics requirement, there are metrics with the info metric usage pattern that don't have the `_info` suffix, e.g. `kube_pod_labels`.
In this proposal, we shall include the latter in the definition of info metrics.

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
Most info metrics' identifying labels will be `job` and `instance`, but there are some exceptions (e.g. `kube_pod_labels`).
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
* Simplify enriching of query results with info metric data (non-identifying) labels in PromQL, e.g. via a new function.
* Ensure backwards compatibility with current Prometheus usage.
* Minimize potential conflicts with existing metric labels.

### Audience

Prometheus maintainers.

## How

* Simplify the inclusion of info metric labels in PromQL through a new `info` function: `info(v instant-vector[, ls data-label-selector])`.
  * If no data label matchers are provided, *all* the data labels of found info metrics are added to the resulting time series.
  * If data label matchers are provided, only info metrics with matching data labels are considered.
  * If data label matchers are provided, *precisely* the data labels specified by the label matchers are added to the returned time series.
  * If data label matchers are provided, time series are only included in the result if matching data labels from info metrics were found.
  * A data label matcher like `k8s_cluster_name=~".+"` guarantees that each returned time series has a non-empty `k8s_cluster_name` label, implying that time series for which no matching info metrics have a data label named `k8s_cluster_name` (including the case where no matching info metric exists at all) will be excluded from the result.
  * A special case: If a data label matcher allows empty labels (equivalent to missing labels, e.g. `k8s_cluster_name=~".*"`), it will not exclude time series from the result even if there's no matching info metric.
  * A data label matcher like `__name__="target_info"` can be used to restrict the info metrics used.
    However, the `__name__` label itself will not be copied.
  * In the case of multiple versions of the same info metric being found (with the same identifying labels), the one with the newest sample wins.
  * Label collisions: The input instant vector could already contain labels that are also part of the data labels of a matching info metric.
    Furthermore, since multiple differently named info metrics with matching identifying labels might be found, those might have overlapping data labels.
    In this case, the implementation has to check if the values of the affected labels match or are different.
    The former case is not really a label collision and therefore causes no problem.
    In the latter case, however, an error has to be returned to the user.
    The collision can be resolved by constraining the labels via data label matchers.
    And of course, the user always has the option to go back to the original join syntax (or, even better, avoiding ingesting conflicting info metrics in the first place).
* Track each info metric's identifying label set over time (in case it changes) - storage model details to be elaborated in separate proposal.
  * This allows determining on a per-timestamp basis, which are an identifying metric's identifying labels.
* Keep info metric indexes in storage - storage model details to be elaborated in separate proposal.
  * Info metric indexes maintaining per info metric the different identifying label sets it has had over its lifetime.
  * Indexing the different identifying label sets an info metric has had over its lifetime allows determining which are potential matches for a given metric, before considering the time dimension.

Using the `info` function, we can simplify the previously given PromQL join example as follows:

```
sum by (k8s_cluster_name, http_status_code) (
  info(
    rate(http_server_request_duration_seconds_count[2m]),
    {k8s_cluster_name=~".+"}
  )
)
```

## Alternatives

### Add metadata as prefixed labels

Instead of encoding metadata, e.g. OTel resource attributes, as info metric labels, add them directly as labels to corresponding metrics.

#### Pros

* Simplicity, removes need for joining with info metrics

#### Cons

* Metrics will have potentially far more labels than what's strictly necessary to identify them
* Temporary series churn when migrating existing metrics to this new scheme
* Increased series churn when metadata labels change
* More labels per metric increases CPU/memory usage

### Make the `info` function require specifying the info metric(s)

Instead of letting `info` by default join with all matching info metrics, have it require specifying the info metric name(s).

#### Pros

* The user won't be confused about data labels being included from info metrics they didn't expect

#### Cons

* The UX becomes more complex, as the user is required to specify which info metric(s) to join with

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] [Add experimental PromQL `info` function MVP](https://github.com/prometheus/prometheus/pull/14495)
* [ ] Extend `info` function MVP with the ability to support `info` metrics in general, with persistence of info metrics metadata
