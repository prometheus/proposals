# Querying: Entity-Aware PromQL

## Abstract

This document specifies how Prometheus's query engine extends to support native entity awareness. The core principle is **automatic enrichment**: when querying metrics, correlated entity labels (both identifying and descriptive) are automatically included in results without requiring explicit join operations. A new **pipe operator** (`|`) enables filtering metrics by entity correlation using familiar syntax consistent with the exposition format.

## Background

### Current PromQL Value Types

PromQL expressions evaluate to one of four value types:

| Type | Description | Example |
|------|-------------|---------|
| **Scalar** | Single floating-point number | `42`, `3.14` |
| **String** | Simple string literal | `"hello"` |
| **Instant Vector** | Set of time series, each with one sample at a single timestamp | `http_requests_total{job="api"}` |
| **Range Vector (Matrix)** | Set of time series, each with multiple samples over a time range | `http_requests_total{job="api"}[5m]` |

Functions have specific type signatures:

```
rate(Matrix) → Vector
sum(Vector) → Vector
scalar(Vector) → Scalar  (single-element vector only)
```

### Current Query Execution Model

When Prometheus executes a PromQL query:

1. **Parsing**: Query string → Abstract Syntax Tree (AST)
2. **Preparation**: For each VectorSelector, call `querier.Select()` with label matchers
3. **Evaluation**: Traverse AST, evaluate functions and operators
4. **Result**: Return typed value (Scalar, Vector, or Matrix)

The query engine interacts with storage through the `Querier` interface:

```go
type Querier interface {
    Select(ctx context.Context, sortSeries bool, hints *SelectHints, 
           matchers ...*labels.Matcher) SeriesSet
    LabelValues(ctx context.Context, name string, ...) ([]string, error)
    LabelNames(ctx context.Context, ...) ([]string, error)
    Close() error
}
```

---

## Automatic Enrichment

### How It Works

When the query engine evaluates a VectorSelector or MatrixSelector, it automatically enriches each series with labels from correlated entities.

**Query:**
```promql
container_cpu_usage_seconds_total{k8s.namespace.name="production"}
```

**Before enrichment (raw series from storage):**
```
container_cpu_usage_seconds_total{
    container="nginx",
    k8s.namespace.name="production",
    k8s.pod.uid="abc-123",
    k8s.node.uid="node-001"
} 1234.5
```

**After enrichment (returned to user):**
```
container_cpu_usage_seconds_total{
    # Original metric labels
    container="nginx",
    
    # Identifying labels (correlation keys, already on series)
    k8s.namespace.name="production",
    k8s.pod.uid="abc-123",
    k8s.node.uid="node-001",
    
    # Descriptive labels from k8s.pod entity
    k8s.pod.name="nginx-7b9f5",
    k8s.pod.status.phase="Running",
    k8s.pod.start_time="2024-01-15T10:30:00Z",
    
    # Descriptive labels from k8s.node entity
    k8s.node.name="worker-1",
    k8s.node.os="linux",
    k8s.node.kernel.version="5.15.0"
} 1234.5
```

---

## Filtering by Entity Labels

Since entity labels appear as labels in query results, standard PromQL label matchers work:

### By Identifying Labels

```promql
# Filter by pod UID (identifying)
container_cpu_usage_seconds_total{k8s.pod.uid="abc-123"}
```

This is efficient because identifying labels are stored on the series and indexed.

### By Descriptive Labels

```promql
# Filter by pod name (descriptive)
container_cpu_usage_seconds_total{k8s.pod.name="nginx-7b9f5"}

# Filter by node OS (descriptive)
container_memory_usage_bytes{k8s.node.os="linux"}

# Regex matching on descriptive labels
http_requests_total{service.version=~"2\\..*"}
```

**Query Execution for Descriptive Label Filters:**

1. Select all series that might match (based on metric name and any indexed labels)
2. For each series, look up correlated entities
3. Get descriptive labels at evaluation timestamp
4. Apply the filter: keep series where enriched labels match

## Aggregation by Entity Labels

Standard PromQL aggregation works with entity labels:

```promql
# Sum CPU by node name (descriptive label)
sum by (k8s.node.name) (container_cpu_usage_seconds_total)

# Average memory by service version
avg by (service.version) (process_resident_memory_bytes)

# Count requests by pod status
count by (k8s.pod.status.phase) (rate(http_requests_total[5m]))
```

### Aggregation Semantics

Aggregation happens **after** enrichment:

```
1. Select series matching the selector
2. Enrich each series with entity labels
3. Group by the specified labels (which may include entity labels)
4. Apply aggregation function
```

**Example:**

```promql
sum by (k8s.node.name) (container_cpu_usage_seconds_total)
```

```
Step 1 - Select series:
  container_cpu{pod_uid="a", node_uid="n1"} 10
  container_cpu{pod_uid="b", node_uid="n1"} 20
  container_cpu{pod_uid="c", node_uid="n2"} 30

Step 2 - Enrich with entity labels:
  container_cpu{..., k8s.node.name="worker-1"} 10
  container_cpu{..., k8s.node.name="worker-1"} 20
  container_cpu{..., k8s.node.name="worker-2"} 30

Step 3 - Group by k8s.node.name:
  Group "worker-1": [10, 20]
  Group "worker-2": [30]

Step 4 - Sum:
  {k8s.node.name="worker-1"} 30
  {k8s.node.name="worker-2"} 30
```

---

## Range Queries and Temporal Semantics

### The Challenge

Descriptive labels can change over time. When querying a range, which label values should be used?

**Example scenario:**
- Pod `abc-123` runs on `worker-1` from T0 to T5
- Pod migrates to `worker-2` at T5
- Query: `container_cpu_usage_seconds_total{k8s.pod.uid="abc-123"}[10m]`

### Solution: Point-in-Time Label Resolution

Each sample is enriched with the descriptive labels **that were valid at that sample's timestamp**.

```promql
container_cpu_usage_seconds_total{k8s.pod.uid="abc-123"}[10m]
```

**Returns:**
```
# Samples before migration (T0-T4) have worker-1
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-1"} 100 @T0
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-1"} 110 @T1
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-1"} 120 @T2
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-1"} 130 @T3
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-1"} 140 @T4

# Samples after migration (T5+) have worker-2
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-2"} 150 @T5
container_cpu{k8s.pod.uid="abc-123", k8s.node.name="worker-2"} 160 @T6
...
```

### Implications for Range Functions

Functions like `rate()` operate on the raw sample values, but the returned instant vector has enriched labels:

```promql
rate(container_cpu_usage_seconds_total{k8s.pod.uid="abc-123"}[5m])
```

For rate calculation:
- Uses sample values regardless of label changes
- The result is enriched with labels **at the evaluation timestamp**

### Series Identity Across Label Changes

**Important:** Descriptive label changes do NOT create new series. The series identity is defined by:
- Metric name
- Original metric labels
- Entity identifying labels (correlation keys)

Descriptive labels are metadata that "rides along" with samples, not part of series identity.

---

## The Entity Type Filter Operator

Automatic enrichment means entity labels appear as labels in query results, so standard label matchers handle most filtering needs:

```promql
# Filter by entity label - just use label matchers
container_cpu_usage_seconds_total{k8s.pod.name="nginx"}
container_cpu_usage_seconds_total{k8s.pod.status.phase="Running"}
```

However, there's one thing label matchers **cannot** do: filter by entity type existence. The pipe operator (`|`) fills this gap.

### Syntax

```promql
vector_expr | entity_type_expr
```

Where `entity_type_expr` can be:
- A single entity type: `k8s.pod`
- Negated: `!k8s.pod`
- Combined with `and`: `k8s.pod and k8s.node`
- Combined with `or`: `k8s.pod or service`
- Grouped: `(k8s.pod and k8s.node) or service`

### When to Use

The pipe operator answers the question: **"Is this metric correlated with an entity of this type?"**

```promql
# Metrics that ARE correlated with any pod entity
container_cpu_usage_seconds_total | k8s.pod

# Metrics that ARE correlated with any node entity
container_memory_usage_bytes | k8s.node

# Metrics that ARE correlated with any service entity
http_requests_total | service
```

### Negation with `!`

Use `!` before an entity type to negate it:

```promql
# Metrics NOT correlated with any pod
container_cpu_usage_seconds_total | !k8s.pod

# Metrics NOT correlated with any service
http_requests_total | !service
```

### Combining Entity Type Filters

Use `and`/`or` keywords to combine entity type filters:

```promql
# Metrics correlated with BOTH a pod AND a node
container_cpu_usage_seconds_total | k8s.pod and k8s.node

# Metrics correlated with a pod OR a service
container_cpu_usage_seconds_total | k8s.pod or service

# Metrics correlated with a pod but NOT a node
container_cpu_usage_seconds_total | k8s.pod and !k8s.node
```

Operator precedence follows standard rules: `!` (not) binds tightest, then `and`, then `or`. Use parentheses for clarity:

```promql
# Explicit grouping
container_cpu | (k8s.pod and k8s.node) or service
```

### All Metrics for an Entity Type

To get all metrics correlated with a specific entity type, omit the metric selector:

```promql
# All metrics correlated with any pod
 | k8s.pod

# Equivalent to:
{__name__=~".+"} | k8s.pod
```

This is useful for exploring what metrics are available for a given entity type.

### Combining with Label Matchers

For label filtering, use label matchers (simpler and familiar). Use the pipe operator only when you need entity type filtering:

```promql
# Filter by label: use label matcher
container_cpu_usage_seconds_total{k8s.pod.name="nginx"}

# Filter by entity type existence: use pipe
container_cpu_usage_seconds_total | k8s.pod

# Both: label matcher for label, pipe for type
container_cpu_usage_seconds_total{k8s.namespace.name="production"} | k8s.pod | k8s.node
```

---

## Query Engine Implementation

### Extended Querier Interface

```go
// EntityQuerier provides entity lookup capabilities
type EntityQuerier interface {
    // Get entities correlated with a series
    EntitiesForSeries(ref storage.SeriesRef) []EntityRef
    
    // Get entity by reference
    GetEntity(ref EntityRef) Entity
    
    Close() error
}

// Entity represents a single entity
type Entity interface {
    Ref() EntityRef
    Type() string
    IdentifyingLabels() labels.Labels
    DescriptiveLabelsAt(timestamp int64) labels.Labels
    StartTime() int64
    EndTime() int64
}
```

### Query Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Query Execution Flow                            │
└─────────────────────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────┐
                    │       PromQL String         │
                    │                             │
                    │ cpu | k8s.pod and k8s.node  │
                    └─────────────┬───────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │          Parser             │
                    │                             │
                    │ - VectorSelector            │
                    │ - EntityTypeFilter          │◄── NEW
                    │ - EntityTypeExpr (and/or/!) │
                    └─────────────┬───────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │            AST              │
                    │                             │
                    │ EntityTypeFilter {          │
                    │   Expr: cpu                 │
                    │   TypeExpr: And {           │
                    │     Left: "k8s.pod"         │
                    │     Right: "k8s.node"       │
                    │   }                         │
                    │ }                           │
                    └─────────────┬───────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│                           Evaluator                                    │
│                                                                        │
│  1. Evaluate left side (VectorSelector)                                │
│     - querier.Select() → SeriesSet                                     │
│     - Enrich with entity labels                                        │
│     - Result: enriched Vector                                          │
│                                                                        │
│  2. Evaluate EntityTypeFilter                                          │
│     - For each series, get correlated entity types                     │
│     - Evaluate boolean expression against those types                  │
│     - Keep series where expression evaluates to true                   │
│     - Result: filtered Vector                                          │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │          Result             │
                    │                             │
                    │       Vector/Matrix         │
                    └─────────────────────────────┘
```

---

The next document will cover [Web UI and APIs](./07-web-ui-and-apis.md), detailing how these capabilities are exposed in Prometheus's user interface and HTTP APIs.
