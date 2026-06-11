# Supporting Entities in Prometheus

## Abstract

This proposal introduces native support for **Entities** in Prometheus—a first-class concept representing **the "things" that produce telemetry**.

A Kubernetes pod, a service instance, a physical host—these are not metrics themselves, but rather the *sources* of metrics. They have their own identity, lifecycle, and attributes that provide context for understanding the telemetry they produce. Today, Prometheus lacks a native way to represent these "things". While the ecosystem has developed conventions (like info metrics) to work around this gap, Prometheus itself doesn't understand what these conventions represent.

**This proposal establishes Entities as a foundational concept in Prometheus.** An Entity represents a distinct object of interest in your infrastructure or application—something that has an identity, produces telemetry, and whose metadata helps you understand that telemetry. 

By making Entities first-class, this proposal enables Prometheus to support them consistently across all layers. Exposition formats gain semantics to declare entity information; SDKs provide clean abstractions for instrumenting entities; storage optimizes for entity metadata and relationships; the query language automatically correlates entity context with metrics; and alerting maintains stable alert identity as entity attributes change.

This proposal also aligns with Prometheus's commitment to being the default store for OpenTelemetry metrics, which has a well-defined Entity model. Native Entity support enables seamless integration between OpenTelemetry's view of the world and Prometheus's.

---

## Terminology

Before diving into the problem and proposed solution, let's establish a shared vocabulary:

#### Info Metric

A metric that exposes metadata about a monitored entity rather than a measurement. In current Prometheus convention, these are gauges with a constant value of `1` and labels containing the metadata. Examples include `node_uname_info`, `kube_pod_info`, and `target_info`.

```
build_info{version="1.2.3", revision="abc123", goversion="go1.21"} 1
```

#### Entity

An **Entity** represents a distinct object of interest that produces or is associated with telemetry. Unlike Info metrics, Entities are not metrics—they are first-class objects with their own identity, labels, and 
lifecycle.

Examples: a Kubernetes pod, a physical host, a service instance, a database table.

Each entity has:
- A **type** (e.g., `k8s.pod`, `host`, `service`)
- **Identifying labels** that uniquely define it (immutable for the entity's lifetime)
- **Descriptive labels** that provide additional context (may change over time)
- **Lifecycle boundaries** (creation time, end time)

In OpenTelemetry, an entity is an object of interest that produces telemetry data. This proposal adopts a compatible Entity concept as Prometheus's native representation for what was previously expressed only through info metric conventions.

**The relationship:** Entities are the concept; info metrics are how they're serialized in the exposition format.

#### Resource Attributes

In OpenTelemetry, **resource attributes** are key-value pairs that describe the entity producing telemetry. These attributes are attached to all telemetry (metrics, logs, traces) from that entity. When OTel metrics are exported to Prometheus, resource attributes typically become labels on a `target_info` metric.

#### Identifying Labels

**Identifying labels** uniquely distinguish one entity from another of the same type. These labels:
- Must remain constant for the lifetime of the entity
- Together form a unique identifier for the entity
- Are required to identify which entity produced the telemetry

Examples:
- `k8s.pod.uid` or (`k8s.pod.name`,`k8s.namespace.name`) for a Kubernetes pod
- `host.id` for a host
- `service.instance.id` for a service instance

#### Descriptive Labels

**Descriptive labels** provide additional context about an entity but do not serve to uniquely identify it. These labels:
- May change during the entity's lifetime
- Provide useful metadata for querying and visualization
- Are optional and supplementary

Examples:
- `k8s.pod.label.app_name` (pods labels can change)
- `host.name` (hostnames can change)
- `service.version` (versions change with deployments)

---

## Problem Statement

### Prometheus Is Missing the Entity Concept

Prometheus has a powerful data model for representing **metrics**—time series of numeric measurements identified by labels. But it lacks a native representation for "things" that produce metrics.

Consider a Kubernetes pod. It has an identity (namespace, UID), labels that describe it (name, node, status), a lifecycle (creation time, termination), and it produces telemetry (CPU usage, memory consumption, request counts). The pod is the *source* of metrics—it is conceptually distinct from the metrics it produces.

Today, the Prometheus ecosystem uses **info metrics** to represent entity metadata:

```promql
kube_pod_info{namespace="production", pod="api-server-7b9f5", uid="550e8400", node="worker-2"} 1
```

Info metrics have served the community well as a **pragmatic convention** for representing entity information. They work, and thousands of dashboards and exporters rely on them. However, because Prometheus treats them as regular metrics rather than recognizing them as entity representations, several limitations emerge:

1. **The value is a placeholder**: The `1` carries no information—it exists only because Prometheus's storage requires a numeric value for every series.
2. **Identity is conflated with description**: All labels are treated equally. There's no way to declare that `uid` uniquely identifies the pod while `node` is descriptive metadata that may change.
3. **Lifecycle is implicit**: When a pod is deleted and recreated, Prometheus sees label churn. There's no first-class representation of "this entity ended; a new one began."
4. **Correlation is manual**: To associate entity metadata with metrics, users must write complex `group_left` joins—reconstructing a relationship that should be understood by the system.

What Prometheus needs is not a replacement for info metrics, but rather **recognition of Entities as a first-class concept**. Info metrics are already representing entities—this proposal gives Prometheus the semantics to understand what they represent.

### Joining Info Metrics Requires `group_left`

The most common use case for info metrics is attaching their labels to other metrics. For example, adding Kubernetes pod metadata to container CPU metrics:

```promql
container_cpu_usage_seconds_total
  * on(namespace, pod) group_left(node, created_by_kind, created_by_name)
  kube_pod_info
```

This pattern has several problems:

1. **Verbose**: Every query that needs pod metadata must include the full `group_left` clause. Dashboards with dozens of panels repeat this join logic everywhere.
2. **Error-Prone**: The `on()` clause must list exactly the right matching labels. Miss one, and the join fails silently or produces incorrect results. List too many, and you get "many-to-many matching not allowed" errors.
3. **Confusing Semantics**: The `group_left` modifier is one of the most confusing aspects of PromQL for new users. "Many-to-one matching" and "group modifiers" require significant mental overhead to understand and use correctly.
4. **Fragile to label changes**: If `kube_pod_info` adds a new label, existing queries may break. If a label is removed, dashboards silently lose data. There's no contract about which labels are stable identifiers vs. which are descriptive metadata.

### No Distinction Between Identifying and Descriptive Labels

Current info metrics treat all labels equally. There's no way to express that some labels are stable identifiers while others are mutable metadata:

```promql
kube_pod_info{
  namespace="production",      # Identifying: part of pod identity
  pod="api-server-7b9f5",      # Identifying: part of pod identity  
  uid="abc-123-def",           # Identifying: globally unique
  node="worker-2",             # Descriptive: can change if rescheduled
  created_by_kind="Deployment", # Descriptive: additional context
  created_by_name="api-server"  # Descriptive: additional context
} 1
```

This lack of distinction causes problems:
- Queries cannot reliably join on "the identity" of an entity
- OTel Entities cannot be accurately translated (OTel's identifying vs descriptive attributes map to our identifying vs descriptive labels)

### Storage and Lifecycle Are Not Optimized

Info metrics are stored like any other time series, despite their unique characteristics:
- The value is always `1`—storing it repeatedly wastes space
- Metadata changes infrequently, but samples are scraped every interval
- Staleness handling treats info metrics like measurements, not metadata

---

## Motivation

### Prometheus's Commitment to OpenTelemetry

In March 2024, Prometheus announced its commitment to being the default store for OpenTelemetry metrics. This includes:
- Native OTLP ingestion
- UTF-8 support for metric and label names
- Native support for resource attributes

OpenTelemetry's data model distinguishes between **metric attributes** (dimensions on individual metrics) and **resource attributes** (properties of the entity producing metrics). Currently, Prometheus flattens resource attributes into `target_info` labels, losing the semantic distinction.

Native Entity support is a important step toward proper resource attribute handling.

### The Entity Model

OpenTelemetry's Entity model provides a structured way to represent monitored objects:

```
Entity {
  type: "k8s.pod"
  identifying_attributes: {
    "k8s.namespace.name": "production",
    "k8s.pod.uid": "abc-123-def"
  }
  descriptive_attributes: {
    "k8s.pod.name": "api-server-7b9f5",
    "k8s.node.name": "worker-2",
    "k8s.deployment.name": "api-server"
  }
}
```

This model enables:
- Clear semantics about what identifies an entity
- Lifecycle management (entities can be created, updated, deleted)
- Correlation across telemetry signals (metrics, logs, traces)

Prometheus can benefit from similar semantics. In this proposal, OTel's "identifying attributes" map to Prometheus identifying labels, and OTel's "descriptive attributes" map to descriptive labels.

### Users Already Rely on Info Metrics

Info metrics are a well-established pattern in the Prometheus ecosystem:

| Metric | Source | Labels |
|--------|--------|--------|
| `node_uname_info` | Node Exporter | `nodename`, `release`, `version`, `machine`, `sysname` |
| `kube_pod_info` | kube-state-metrics | `namespace`, `pod`, `uid`, `node`, `created_by_*`, etc. |
| `kube_node_info` | kube-state-metrics | `node`, `kernel_version`, `os_image`, `container_runtime_version` |
| `target_info` | OTel SDK | All resource attributes |
| `build_info` | Various | `version`, `revision`, `branch`, `goversion` |

These metrics are used in thousands of dashboards and alerts. Introducing native Entities improves the ergonomics and semantics while maintaining the utility users depend on.

---

## Use Cases

### Enriching Metrics with Producer Metadata

A common need in observability is to enrich metrics with information about what produced them. When analyzing CPU usage, you often want to know which version of the software is running, what node a container is scheduled on, or what deployment owns a pod. This context transforms raw numbers into actionable insights.

**The Problem:**

Today, this requires complex `group_left` joins between metrics and info metrics:

```promql
sum by (namespace, pod, node) (
  rate(container_cpu_usage_seconds_total{namespace="production"}[5m])
    * on(namespace, pod) group_left(node)
    kube_pod_info
)
```

This pattern appears everywhere: adding `build_info` labels to application metrics, enriching host metrics with `node_uname_info`, correlating service metrics with `target_info` from OTel. Every query must:

- Know which labels to match on (`namespace`, `pod`, `job`, `instance`, etc.)
- Explicitly list which metadata labels to bring in
- Handle edge cases when labels change (pod rescheduling, version upgrades)


Users should be able to say "give me this metric, enriched with information about its producer" without writing complex joins. The query engine should understand the relationship between metrics and the entities that produced them.

With native Entity support, the query engine knows which labels identify an entity and which describe it. Enrichment becomes automatic or requires minimal syntax—no need to manually specify join keys or enumerate which labels to include.

### OpenTelemetry Resource Translation

**Current State:**

When OTel metrics are exported to Prometheus, resource attributes become labels on `target_info`:

```promql
target_info{
  job="otel-collector",
  instance="collector-1:8888",
  service_name="payment-service",
  service_version="2.1.0",
  service_instance_id="i-abc123",
  deployment_environment="production",
  host_name="prod-vm-42",
  host_id="550e8400-e29b-41d4-a716-446655440000"
} 1
```

To use these attributes with application metrics:

```promql
http_request_duration_seconds_bucket
  * on(job, instance) group_left(service_name, service_version, deployment_environment)
  target_info
```

**Pain Points:**
- OTel distinguishes identifying vs. descriptive attributes; Prometheus loses this
- Entity lifecycle (creation, updates) is not represented
- Every query must know the OTel schema to write correct joins

**Desired State:**

Native translation of OTel Entities to Prometheus Entities, where OTel's identifying attributes (like `k8s_pod_uid`) become identifying labels, and OTel's descriptive attributes (like `k8s_pod_annotation_created_by`, `k8s_pod_status`) become descriptive labels. This would preserve the semantic richness of the OTel data model and enable better query ergonomics.

### Collection Architectures: Direct Scraping vs. Gateways

Prometheus deployments follow two main patterns for collecting metrics, and this proposal must support both.

**Direct Scraping**

In direct scraping, Prometheus discovers and scrapes each target individually. Service Discovery provides accurate metadata about each target, because the target *is* the entity producing metrics.

```
┌─────────────┐
│  Service A  │◀────┐
│  (pod-xyz)  │     │
└─────────────┘     │
                    │ scrape    ┌───────────┐
┌─────────────┐     ├──────────▶│           │
│  Service B  │◀────┤           │Prometheus │
│  (pod-abc)  │     │           │           │
└─────────────┘     │           └───────────┘
                    │
┌─────────────┐     │
│  Service C  │◀────┘
│  (pod-def)  │
└─────────────┘
```

Here, Kubernetes SD knows that `pod-xyz` runs Service A with specific labels, resource limits, and node placement. This metadata accurately describes the entity producing metrics—SD-derived entities work well.

**Gateway and Federation**

In gateway architectures, metrics flow through an intermediary before reaching Prometheus. The intermediary aggregates metrics from multiple sources.

```
┌───────────┐     ┌───────────┐       ┌───────────┐
│ Service A │────▶│           │       │           │
│           │push │   OTel    │──────▶│Prometheus │
├───────────┤     │ Collector │scrape │           │
│ Service B │────▶│           │       │           │
│           │     │(gateway)  │       │           │
├───────────┤     │           │       │           │
│ Service C │────▶│           │       │           │
└───────────┘     └───────────┘       └───────────┘
```

Here, SD only sees the OTel Collector—not Services A, B, or C. Any SD-derived metadata would describe the collector, not the actual metric producers. The same applies to Prometheus federation and pushgateway patterns.

| What SD Sees | What Actually Produced Telemetry |
|--------------|----------------------------------|
| `otel-collector-pod-xyz` | `payment-service`, `auth-service`, `user-service` |
| `prometheus-federation-1` | Hundreds of scraped targets from regional Prometheus |
| `pushgateway-xyz` | Various batch jobs and short-lived processes |
| `kube-state-metrics-0` | Workloads running in K8s and K8s API itself |

**Supporting Both Models**

This proposal must support both architectures:

1. **Direct scraping**: Entity information can be derived from Service Discovery metadata, since SD accurately describes each target.
2. **Gateway/federation**: Entity information must be embedded in the exposition format to travel with the metrics through intermediaries.

Users choose the appropriate approach for their architecture. See [Service Discovery](./04-service-discovery.md) for configuration details.

---

## Goals

This proposal aims to achieve the following:

### 1. Define Entity as a Native Concept

Prometheus should recognize Entities as a distinct concept with their own semantics, separate from metrics. Entities represent the things that produce telemetry, not the telemetry itself.

### 2. Support Identifying and Descriptive Label Semantics

Entities should allow declaring which labels are identifying (forming the entity's identity) and which are descriptive (providing additional context that may change over time).

### 3. Improve Query Ergonomics

Reduce or eliminate the need for `group_left` when attaching entity labels to related metrics. The common case should be simple.

### 4. Optimize Storage for Metadata

Entities store string labels and change infrequently. Storage and ingestion should be optimized for this pattern, rather than treating them as time series with constant values.

### 5. Enable OTel Entity Translation

Provide a natural mapping between OpenTelemetry Entities and Prometheus Entities, translating OTel's identifying and descriptive attributes to Prometheus's identifying and descriptive labels.

### 6. Support Both Direct and Gateway Collection Models

Entity information must work correctly whether Prometheus scrapes targets directly (where SD metadata is accurate) or through intermediaries like OTel Collector or federation.

---

## Non-Goals

The following are explicitly out of scope for this proposal:

### Changing behavior for existing `*_info` Gauges

This proposal defines new semantics for Entities. Existing **gauges** with `_info` suffix will continue to work as gauges and joins will continue to work. Migration or automatic conversion is not in scope.

### Complete OTel Data Model Parity

This proposal focuses on Entities. Full parity with OTel's data model (exemplars, exponential histograms, etc.) is addressed elsewhere.

---

## Related Work

### OpenMetrics Specification

OpenMetrics 1.0 (November 2020) formally defines the Info metric type. The specification describes Info as "used to expose textual information which SHOULD NOT change during process lifetime."

- [OpenMetrics 1.0 Specification](https://prometheus.io/docs/specs/om/open_metrics_spec/)
- [OpenMetrics 2.0 Draft](https://prometheus.io/docs/specs/om/open_metrics_spec_2_0/)

### The `info()` PromQL Function

Prometheus 2.x introduced an experimental `info()` function in PromQL to simplify joins between metrics and info metrics. Instead of writing verbose `group_left` queries, users can write:

```promql
info(rate(http_requests_total[5m]))
```

This automatically enriches the result with labels from `target_info`. The function reduces boilerplate and makes queries more readable.

However, the current implementation hardcodes `job` and `instance` as identifying labels—the labels used to correlate metrics with their info series. This works for `target_info` but fails for other entity types like `kube_pod_info` (which uses `namespace` and `pod`) or `kube_node_info` (which uses `node`). The community is actively discussing improvements to make the function more flexible.

More fundamentally, `info()` still operates on info metrics—it makes joins easier but doesn't change the underlying model where entity information is encoded as a metric with a constant value. Native Entity support would allow the query engine to understand entity relationships directly, making enrichment automatic without needing explicit function calls or hardcoded identifying labels.

- [PromQL info() function documentation](https://prometheus.io/docs/prometheus/latest/querying/functions/#info)

### OpenTelemetry Entity Data Model

OpenTelemetry defines Entities as "objects of interest associated with produced telemetry." The data model specifies:
- Entity types and their schemas
- Identifying vs. descriptive attributes
- Entity lifecycle events

- [OTel Entities Data Model](https://opentelemetry.io/docs/specs/otel/entities/data-model/)
- [Resource and Entity Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/how-to-write-conventions/resource-and-entities/)

### OpenTelemetry Prometheus Compatibility

OpenTelemetry provides specifications for bidirectional conversion between OTel and Prometheus formats:
- Resource attributes → `target_info` labels
- Metric attributes → metric labels
- Handling of Info and StateSet types

- [Prometheus and OpenMetrics Compatibility](https://opentelemetry.io/docs/specs/otel/compatibility/prometheus_and_openmetrics/)
- [Prometheus Exporter Specification](https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/prometheus/)

### Prometheus Commitment to OpenTelemetry

In March 2024, Prometheus announced plans to be the default store for OpenTelemetry metrics:
- OTLP ingestion
- UTF-8 metric and label name support
- Native resource attribute support

As of late 2024, most of this work has been implemented: OTLP ingestion is generally available in Prometheus 3.0 and UTF-8 support for metric and label names is complete. The notable exception is **native support for resource attributes**—which is precisely what this proposal aims to address through proper Entity semantics.

- [Prometheus Commitment to OpenTelemetry](https://prometheus.io/blog/2024/03/14/commitment-to-opentelemetry/)

---

## What's Next

This document establishes the context and motivation for native Entity support in Prometheus. The following documents detail the implementation:

- **[Exposition Formats](./02-exposition-formats.md)**: How entities are represented in text and protobuf formats
- **[SDK](./03-sdk.md)**: How Prometheus client libraries support entities
- **[Service Discovery](./04-service-discovery.md)**: How entities relate to Prometheus targets and discovered metadata
- **[Storage](./05-storage.md)**: How entities are stored efficiently in the TSDB
- **[Querying](./06-querying.md)**: PromQL extensions for working with entities
- **[Web UI and APIs](./07-web-ui-and-apis.md)**: How entities are displayed and accessed
- **[Alerting](./08-alerting.md)**: How entities interact with alerting rules and Alertmanager
- **Remote Write (TBD)**: Protocol changes for transmitting entities over remote write

---

*This proposal is a work in progress. Feedback from Prometheus maintainers, users, and the broader observability community is welcome.*
