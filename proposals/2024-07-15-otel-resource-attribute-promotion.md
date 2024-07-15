# OTel resource attribute promotion

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) [arve.knudsen@grafana.com](mailto:arve.knudsen@grafana.com)

* **Implementation Status:** Partially implemented

* **Related Issues and PRs:**
  * [WIP: OTLP Translator prometheusremotewrite: Support resource attribute promotion](https://github.com/prometheus/prometheus/pull/14200)

* **Other docs or links:**

> This proposal collects the requirements and implementation proposals for supporting OTel resource attribute promotion to labels.

## Why

Currently, Prometheus encodes OpenTelemetry (OTel for short) [resource attributes](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/resource/sdk.md) as labels of the `target_info` metric.
OTel resource attributes model metadata about the environment producing metrics received by the backend (e.g. Prometheus).
Typically, OTel users want to include some of these attributes (as `target_info` labels) in their Prometheus query results, to correlate them with entities of theirs (e.g. K8s pods).

Based on user demand, it would be preferable if Prometheus were to have better UX for including OTel resource attributes in query results.
The current solution is to join with `target_info in queries, to pick also the labels one is interested in (corresponding to OTel resource attributes).
This requires relatively advanced knowledge of PromQL though and is a barrier to many users.
Take as an example querying HTTP request rates per K8s cluster and status code, while having to join with the `target_info` metric to obtain the `k8s.cluster.name` resource attribute (encoded as `k8s_cluster_name`):

```promql
# Join with target_info on job and instance labels, to include k8s_cluster_name.
sum by (k8s_cluster_name, http_status_code) (
    rate(http_server_request_duration_seconds_count[2m])
  * on (job, instance) group_left (k8s_cluster_name)
    target_info
)
```

### Pitfalls of the current solution

As already mentioned, the current solution of including OTel resource attributes in query results through join queries represents a technical barrier to users.
Also, it requires the user to know which `target_info` labels can be joined on (i.e., `job` and `instance`), plus which labels represent the various OTel resource attributes.
All in all, the UX for including OTel resource attributes in Prometheus query results is not very smooth.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Support, in the OTLP endpoint, automatic promotion of a configurable set of OTel resource attributes to metric labels.

### Audience

Prometheus maintainers.

## How

* Make the OTLP endpoint support a configurable set of OTel resource attributes to promote to metric labels.
* Add a Prometheus configuration parameter for which OTel resource attributes to promote (default: none).

With OTel resource attribute promotion configured to `[k8s.cluster.name]`, we can simplify the previously given PromQL join example as follows:

```
sum by (k8s_cluster_name, http_status_code) (
  rate(http_server_request_duration_seconds_count[2m])
)
```

## Alternatives

### Simplify joins with info metrics in PromQL

Instead of promoting selected OTel resource attributes to labels at ingest time, another [proposal](https://github.com/prometheus/proposals/pull/37) is to simplify the joining with `target_info` in queries.
These proposals are not necessarily competing though, as the respective proposed features can co-exist.

#### Pros

* Avoids having to add more labels to metrics than strictly required to identify them.
* Avoids series churn when one or more of the promoted OTel resource attributes change.
* More labels per metric increases CPU/memory usage.
* Avoids the user having to decide up front which OTel resource attributes to promote at ingestion time.
* Avoids series churn when the user changes which OTel resource attributes to promote.
* Simply improves the UX for the existing solution of encoding OTel resource attributes as `target_info` labels.

#### Cons

* Much more complicated to implement.
* Requires the user to call `info` in their queries.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] https://github.com/prometheus/prometheus/pull/14200
