# Service Discovery and Entities

## Abstract

This document specifies how Prometheus Service Discovery (SD) integrates with the Entity concept introduced in this proposal. SD already collects rich metadata about scrape targets—metadata that naturally maps to entity labels. This document provides a comprehensive technical specification for deriving entities from SD metadata, including implementation details and resolution of the interaction between relabeling, entity generation, and metric correlation.

The document also addresses **attribute mapping standards**—how `__meta_*` labels translate to entity type names and attribute names. Rather than prescribing a specific convention, this document presents the available options (OpenTelemetry semantic conventions, Prometheus-native conventions, etc.) and their trade-offs. Standardized, non-customizable mappings are essential for enabling ecosystem-wide interoperability; the specific convention choice is left as an open decision for the Prometheus community.

Entities can come from two sources: the **exposition format** (embedded in scraped data) or **Service Discovery** (derived from target metadata). Each approach has trade-offs, and users choose based on their architecture.

---

## Background: How Service Discovery Works

### Discovery Manager Architecture

The Discovery Manager (`discovery/manager.go`) coordinates all service discovery mechanisms:

```go
type Manager struct {
    // providers keeps track of SD providers
    providers []*Provider
    
    // targets maps (setName, providerName) -> source -> TargetGroup
    targets map[poolKey]map[string]*targetgroup.Group
    
    // syncCh sends updates to the scrape manager
    syncCh chan map[string][]*targetgroup.Group
}
```

Each `Provider` wraps a `Discoverer` that implements:

```go
type Discoverer interface {
    // Run sends TargetGroups through the channel when changes occur
    Run(ctx context.Context, up chan<- []*targetgroup.Group)
}
```

### Target Group Structure

The fundamental unit of discovery is the `targetgroup.Group`:

```go
// From discovery/targetgroup/targetgroup.go
type Group struct {
    // Targets is a list of targets identified by a label set.
    // Each target is uniquely identifiable by its address label.
    Targets []model.LabelSet
    
    // Labels is a set of labels common across all targets in the group.
    Labels model.LabelSet
    
    // Source is an identifier that describes this group of targets.
    Source string
}
```

**Key insight**: SD mechanisms populate `__meta_*` labels into these `LabelSet` objects. These labels contain the raw metadata that will become entity attributes.

### Label Flow: Discovery to Scrape

The complete flow from discovery to metric labels:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Service Discovery Flow                               │
└─────────────────────────────────────────────────────────────────────────────┘

  1. DISCOVERY PHASE
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ Kubernetes API / AWS API / Consul / etc.                                │
  │                      │                                                  │
  │                      ▼                                                  │
  │ ┌─────────────────────────────────────────────────────────────────────┐ │
  │ │ Discoverer.Run() builds targetgroup.Group with:                     │ │
  │ │                                                                     │ │
  │ │   Targets[0] = {                                                    │ │
  │ │     __address__: "10.0.0.1:8080"                                    │ │
  │ │     __meta_kubernetes_namespace: "production"                       │ │
  │ │     __meta_kubernetes_pod_name: "nginx-7b9f5"                       │ │
  │ │     __meta_kubernetes_pod_uid: "550e8400-e29b-..."                  │ │
  │ │     __meta_kubernetes_pod_node_name: "worker-1"                     │ │
  │ │     __meta_kubernetes_pod_phase: "Running"                          │ │
  │ │     ...                                                             │ │
  │ │   }                                                                 │ │
  │ │                                                                     │ │
  │ │   Labels = {                                                        │ │
  │ │     __meta_kubernetes_namespace: "production"  (group-level)        │ │
  │ │   }                                                                 │ │
  │ └─────────────────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
  2. SCRAPE MANAGER RECEIVES TARGET GROUPS
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ scrapePool.Sync(tgs []*targetgroup.Group)                               │
  │                      │                                                  │
  │                      ▼                                                  │
  │ TargetsFromGroup() → PopulateLabels()                                   │
  └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
  3. LABEL POPULATION (scrape/target.go:PopulateLabels)
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ a) Merge target labels + group labels                                   │
  │ b) Add scrape config defaults (job, __scheme__, __metrics_path__, etc.) │
  │ c) Apply relabel_configs                                                │
  │ d) Delete all __meta_* labels                                           │
  │ e) Default instance to __address__                                      │
  │                                                                         │
  │ Result: Target with final label set                                     │
  │   {job="kubernetes-pods", instance="10.0.0.1:8080", namespace="prod"}   │
  └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
  4. SCRAPE LOOP
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ HTTP GET target → Parse metrics → Apply metric_relabel_configs          │
  │ → Append to storage with final labels                                   │
  └─────────────────────────────────────────────────────────────────────────┘
```

**Critical observation**: The `__meta_*` labels are deleted in step 3d. With entity support, we intercept these labels *before* deletion to generate entities.

---

## Entity Sources

Entities can originate from two sources, each suited to different deployment patterns:

### Source 1: Service Discovery

When Prometheus scrapes targets directly, SD metadata accurately describes the entity producing metrics:

| SD Mechanism | What It Discovers | Entity It Can Generate |
|--------------|-------------------|------------------------|
| Kubernetes pod SD | Pods | `k8s.pod` |
| Kubernetes node SD | Nodes | `k8s.node` |
| Kubernetes service SD | Services | `k8s.service` |
| EC2 SD | EC2 instances | `host`, `cloud.instance` |
| Azure VM SD | Azure VMs | `host`, `cloud.instance` |
| GCE SD | GCE instances | `host`, `cloud.instance` |
| Consul SD | Services | `service` |

**When to use**: Direct scraping where the target IS the entity.

### Source 2: Exposition Format

When metrics flow through intermediaries, SD sees the intermediary, not the actual sources:

```
┌───────────┐     ┌───────────┐       ┌───────────┐
│ Service A │────▶│   OTel    │◀─────▶│Prometheus │
│ (pod-xyz) │push │ Collector │scrape │           │
└───────────┘     │           │       │ SD sees:  │
┌───────────┐     │ (pod-abc) │       │ pod-abc   │
│ Service B │────▶│           │       │           │
└───────────┘     └───────────┘       └───────────┘
                                            │
                  Entity info must travel   │
                  WITH the metrics ─────────┘
```

**When to use**: Gateways, federation, pushgateway, kube-state-metrics.

See [01-context.md](./01-context.md#collection-architectures-direct-scraping-vs-gateways) for detailed use cases.

---

## Configuration

### New Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `entity_from_sd` | bool | `false` | When true, generates entities from `__meta_*` labels using built-in mappings |
| `entity_limit` | int | `0` | Maximum distinct entities per target (0 = no limit) |

### Configuration Examples

```yaml
scrape_configs:
  # Direct scraping with entity generation enabled
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    entity_from_sd: true
    
  # Gateway pattern - entities come from exposition format
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:8889']
    entity_from_sd: false  # Default
    
  # Federation - entities flow through metrics
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    static_configs:
      - targets: ['prometheus-regional:9090']
    entity_from_sd: false
```

---

## Attribute Mapping Standards

A critical design decision for SD-derived entities is how `__meta_*` labels translate to entity type names and attribute names. This section outlines the requirements, available options, and trade-offs for establishing a mapping standard.

### The Problem

Service Discovery mechanisms produce `__meta_*` labels with provider-specific naming:

```
__meta_kubernetes_pod_uid
__meta_kubernetes_namespace
__meta_ec2_instance_id
__meta_azure_machine_id
```

These must be transformed into entity attributes. The key questions are:

1. **Entity type names**: What should we call the entity? (`k8s.pod`? `kubernetes_pod`? `pod`?)
2. **Attribute names**: How should attributes be named? (`k8s.pod.uid`? `pod_uid`? `uid`?)
3. **Which labels become identifying vs. descriptive?**

The answers to these questions affect:
- **Correlation**: Metrics and entities must share the same identifying label names and values
- **Interoperability**: Other systems querying Prometheus data need predictable attribute names
- **Ecosystem alignment**: Conventions should facilitate integration with dashboards, alerting, and other tools

### Design Requirements

Whatever convention is chosen, the mapping must satisfy these requirements:

1. **Deterministic**: Given the same `__meta_*` labels, the resulting entity attributes must always be identical
2. **Complete**: All meaningful metadata should be captured—useful information should not be silently dropped
3. **Unambiguous**: Each `__meta_*` label maps to exactly one attribute; no conflicts or overlaps
4. **Stable**: Once established, mappings should not change without a clear migration path

### Available Options

#### Option 1: OpenTelemetry Semantic Conventions

Adopt attribute names from [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/), which define standardized names for resource attributes across the industry.

**Example mappings:**

| SD Label | OTel-style Entity Attribute |
|----------|----------------------------|
| `__meta_kubernetes_pod_uid` | `k8s.pod.uid` |
| `__meta_kubernetes_namespace` | `k8s.namespace.name` |
| `__meta_ec2_instance_id` | `host.id` |
| `__meta_ec2_instance_type` | `host.type` |
| `__meta_azure_machine_id` | `host.id` |
| `__meta_gce_project` | `cloud.account.id` |

**Advantages:**
- Industry-wide standardization enables correlation across tools (Grafana, OTel Collector, etc.)
- Reduces cognitive load for teams already using OTel conventions
- Future-proofs Prometheus for deeper OTel integration
- Extensive documentation and community support

**Disadvantages:**
- Not all conventions are stable; Kubernetes conventions are currently "Experimental" and may change
- Introduces dot-separated names (e.g., `k8s.pod.uid`) which differ from Prometheus's traditional underscore convention
- Requires Prometheus to track and potentially adapt to external convention changes

**Stability considerations:**

If OTel conventions are adopted, Prometheus should consider:
- Only adopting conventions that have reached **Stable** status
- For widely-used Experimental conventions (like Kubernetes), accepting the risk with clear user documentation
- Establishing a migration strategy for when conventions change

#### Option 2: Prometheus-Native Conventions

Define Prometheus-specific conventions that align with existing Prometheus naming patterns (lowercase, underscore-separated).

**Example mappings:**

| SD Label | Prometheus-style Entity Attribute |
|----------|----------------------------------|
| `__meta_kubernetes_pod_uid` | `kubernetes_pod_uid` |
| `__meta_kubernetes_namespace` | `kubernetes_namespace` |
| `__meta_ec2_instance_id` | `ec2_instance_id` |
| `__meta_ec2_instance_type` | `ec2_instance_type` |
| `__meta_azure_machine_id` | `azure_machine_id` |
| `__meta_gce_project` | `gce_project` |

**Advantages:**
- Consistent with existing Prometheus label naming conventions
- Full control over naming without external dependencies
- No risk of upstream convention changes
- Simpler—direct transformation from `__meta_*` labels

**Disadvantages:**
- No industry standardization; correlation with OTel-based systems requires translation
- Prometheus would need to define and maintain its own convention documentation
- May diverge from where the broader observability ecosystem is heading
- Less intuitive for teams already using OTel conventions

#### Option 3: Minimal Transformation

Strip the `__meta_` prefix and SD-type prefix, keeping attribute names close to the original.

**Example mappings:**

| SD Label | Minimal Entity Attribute |
|----------|-------------------------|
| `__meta_kubernetes_pod_uid` | `pod_uid` |
| `__meta_kubernetes_namespace` | `namespace` |
| `__meta_ec2_instance_id` | `instance_id` |
| `__meta_ec2_instance_type` | `instance_type` |
| `__meta_azure_machine_id` | `machine_id` |
| `__meta_gce_project` | `project` |

**Advantages:**
- Simplest transformation logic
- Shortest attribute names
- Easy to understand and predict

**Disadvantages:**
- No namespace to distinguish provider-specific attributes
- Poor interoperability with any external standard

### Identifying vs. Descriptive Label Classification

Beyond naming, each mapping must classify labels as **identifying** (immutable, define identity) or **descriptive** (mutable, provide context). This classification must be:

1. **Consistent with the data source**: If the underlying resource uses a UID for identity, so should the entity
2. **Globally unique when combined**: Identifying labels together must uniquely identify one entity
3. **Stable over the entity's lifetime**: Identifying label values must not change

### SD Mechanisms Without Entity Mappings

The following SD mechanisms do not generate entities automatically because they lack sufficient metadata to construct meaningful entities:

| SD Mechanism | Reason |
|--------------|--------|
| `static_configs` | No metadata—just addresses |
| `file_sd_configs` | User-defined, no standard schema |
| `http_sd_configs` | User-defined, no standard schema |
| `dns_sd_configs` | Only provides addresses |

Users requiring entities from these sources should embed entity information in the exposition format (see [02-exposition-formats.md](./02-exposition-formats.md)).

### Non-Customizable by Design

**Attribute mappings are not user-configurable.** This is intentional:

1. **Standardization requires consistency**: If every deployment uses different attribute names, the benefits of entities (correlation, interoperability, ecosystem tooling) are lost
2. **Ecosystem tooling depends on predictability**: Dashboards, alerting rules, and integrations assume specific attribute names
3. **Reduced cognitive load**: Users don't need to understand or maintain mapping configurations
4. **Simpler implementation**: No configuration parsing, validation, or per-scrape-config mapping logic

Users who need different attribute names can transform data downstream (e.g., in recording rules or remote write pipelines), but the source of truth in Prometheus uses the standard mappings.

### Open Decision

This proposal does not prescribe which naming convention Prometheus should adopt. The choice between OTel alignment, Prometheus-native conventions, or another approach should be made by the Prometheus community based on:

- Strategic direction for OTel integration
- Compatibility requirements with existing tooling
- Long-term maintenance considerations
- Community feedback

The implementation will be straightforward once a convention is chosen—the technical complexity is in the entity infrastructure, not the naming.

---

## Implementation Overview

### Where Entity Generation Happens

Entity generation occurs during target creation in `PopulateLabels()`, **before** `__meta_*` labels are discarded. This timing is critical—once relabeling deletes the meta labels, the raw SD metadata is lost.

When `entity_from_sd: true`:

1. **Detect SD type** — Examine `__meta_*` label prefixes to determine which SD mechanism provided the target
2. **Apply built-in mappings** — Use the standard mappings for that SD type to extract entity attributes
3. **Classify labels** — Separate identifying labels (for identity) from descriptive labels (for context)
4. **Create entities** — Build entity structures with type, identifying labels, and descriptive labels
5. **Associate with target** — Store the generated entities alongside the target for transmission during scrape

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   Entity Generation Data Flow                               │
└─────────────────────────────────────────────────────────────────────────────┘

┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│  Kubernetes   │    │     EC2       │    │    Consul     │
│     API       │    │     API       │    │     API       │
└───────┬───────┘    └───────┬───────┘    └───────┬───────┘
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                       Discovery Manager                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    targetgroup.Group                                │  │
│  │  Targets: [ { __meta_kubernetes_pod_uid: "abc", ... } ]             │  │
│  │  Labels:  { __meta_kubernetes_namespace: "prod" }                   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                         Scrape Manager                                    │
│                                                                           │
│  scrapePool.Sync(tgs) → TargetsFromGroup() → PopulateLabels()             │
│                                   │                                       │
│              ┌────────────────────┴────────────────────┐                  │
│              │                                         │                  │
│              ▼                                         ▼                  │
│  ┌─────────────────────────┐            ┌─────────────────────────┐       │
│  │   Entity Generation     │            │   Label Processing      │       │
│  │   (from __meta_* labels)│            │   (relabel_configs)     │       │
│  │                         │            │                         │       │
│  │  IF entity_from_sd:     │            │  1. Apply relabel rules │       │
│  │    Extract identifying  │            │  2. Delete __meta_*     │       │
│  │    Extract descriptive  │            │  3. Set instance default│       │
│  │    Create Entity struct │            │                         │       │
│  └───────────┬─────────────┘            └──────────┬──────────────┘       │
│              │                                     │                      │
│              │      ┌──────────────────────────────┘                      │
│              │      │                                                     │
│              ▼      ▼                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                            Target                                   │  │
│  │                                                                     │  │
│  │  labels: { job="k8s-pods", instance="10.0.0.1:8080", ns="prod" }    │  │
│  │                                                                     │  │
│  │  sdEntities: [                                                      │  │
│  │    Entity{                                                          │  │
│  │      type: "k8s.pod",                                               │  │
│  │      identifyingLabels: {namespace="prod", pod_uid="abc-123"}       │  │
│  │      descriptiveLabels: {pod_name="nginx", node_name="worker-1"}    │  │
│  │    }                                                                │  │
│  │  ]                                                                  │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                          Scrape Loop                                      │
│                                                                           │
│  For each scrape:                                                         │
│    1. HTTP GET target                                                     │
│    2. Parse exposition format                                             │
│    3. Extract exposition-format entities (if any)                         │
│    4. Merge SD entities + exposition entities                             │
│    5. app.AppendEntity() for each entity                                  │
│    6. app.Append() for each metric (with correlation via shared labels)   │
│    7. app.Commit()                                                        │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                            Storage (TSDB)                                 │
│                                                                           │
│  ┌─────────────────────┐    ┌─────────────────────┐                       │
│  │   Entity Storage    │    │   Series Storage    │                       │
│  │                     │    │                     │                       │
│  │  memEntity          │◄──►│  memSeries          │                       │
│  │  stripeEntities     │    │  stripeSeries       │                       │
│  │  EntityMemPostings  │    │  postings           │                       │
│  │                     │    │                     │                       │
│  │  Correlation Index  │────┤                     │                       │
│  └─────────────────────┘    └─────────────────────┘                       │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Relabeling and Entities

This section specifies how relabeling interacts with entity generation.

### Principle: Entities Are Generated Before Relabeling

Entity generation uses the **raw** `__meta_*` labels before any relabeling is applied. This ensures:

1. **Predictability**: Entity structure is consistent regardless of user relabeling rules
2. **Correctness**: Identifying labels match the actual resource identity
3. **Simplicity**: Users don't need to coordinate relabeling with entity generation

### relabel_configs Do Not Affect Entity Labels

```yaml
scrape_configs:
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    entity_from_sd: true
    relabel_configs:
      # This ONLY affects metric labels, NOT entity labels
      - source_labels: [__meta_kubernetes_namespace]
        target_label: ns  # Metric label becomes "ns"
                          # Entity attribute uses the standard mapping (unchanged)
```

**Rationale**: Entity identifying labels are derived from `__meta_*` labels using the standard mapping, independent of `relabel_configs`. This ensures entity structure is predictable regardless of user relabeling rules.

### metric_relabel_configs and Entity Labels

`metric_relabel_configs` operates on metrics **after** they're scraped but **before** correlation happens. Entity-enriched labels (descriptive labels added during query) are **not** subject to `metric_relabel_configs`.

```yaml
scrape_configs:
  - job_name: 'kubernetes-pods'
    entity_from_sd: true
    metric_relabel_configs:
      # This drops metrics, but entities remain
      - source_labels: [__name__]
        regex: 'go_.*'
        action: drop
```

### honor_labels Interaction

When `honor_labels: true`, labels from the scraped payload take precedence over target labels. This affects correlation:

```yaml
scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    entity_from_sd: false  # Entities come from federated metrics
```

If `entity_from_sd: true` with `honor_labels: true`:
- SD-derived entities are still generated
- Correlation uses the **final** metric labels (which may come from the payload)
- This could cause correlation mismatches if payload labels differ from SD labels

**Recommendation**: When using `honor_labels: true`, set `entity_from_sd: false` and rely on exposition-format entities.

---

## Conflict Resolution

> **TODO**: This section needs further design work. When entities come from both SD and the exposition format for the same scrape, we need to define:
> - How to detect that two entities refer to the same resource
> - Whether to merge, prefer one source, or treat them as distinct
> - How to handle conflicting descriptive labels
> - Edge cases around timing and ordering
>
> This interacts with the exposition format design in [02-exposition-formats.md](./02-exposition-formats.md) and needs to be addressed holistically.

---

## Entity Lifecycle with SD

### Entity Creation

An SD-derived entity is created when a target with matching `__meta_*` labels first appears in discovery.

### Entity Updates

When a target is re-discovered (on each SD refresh) and `entity_from_sd: true`:
1. Entity identifying labels are checked against existing entities
2. If entity exists, descriptive labels are compared
3. If descriptive labels changed, a new snapshot is recorded (see [05-storage.md](./05-storage.md))

### Entity Staleness

When a target disappears from SD:

1. **Immediate behavior**: The target's scrape loop is stopped
2. **Reference counting**: The scrape pool tracks how many targets reference each entity
3. **Entity marking**: When the last target referencing an entity disappears, the entity's `endTime` is set
4. **Grace period**: Entities remain queryable for historical analysis until retention removes them

### Entity Deduplication

Multiple targets may correlate with the same entity (e.g., multiple containers in a pod). Entity identity is determined by type + identifying labels—if two targets generate entities with the same identity, only one entity is stored.

When the same entity is discovered from multiple targets:
- First discovery creates the entity
- Subsequent discoveries update `lastSeen` timestamp
- Descriptive labels are merged (last write wins for conflicts)

---

## Open Questions Resolved

### Q: Entity deduplication across multiple discovery mechanisms

**Answer**: Entities are deduplicated by their identifying labels. If Kubernetes pod SD and endpoints SD both discover the same pod, only one entity is stored. The entity's descriptive labels are updated from whichever source provides the most recent data.

### Q: SD entity lifecycle when target disappears

**Answer**: When the last target referencing an entity disappears from SD, the entity's `endTime` is set to the current timestamp. The entity remains in storage for historical queries until retention deletes it.

## Open Questions

### Q: Which naming convention should Prometheus adopt for entity attributes?

This proposal presents the available options (OTel semantic conventions, Prometheus-native, minimal transformation) and their trade-offs, but does not prescribe a specific choice. The decision should be made by the Prometheus community considering:

- Strategic alignment with OpenTelemetry
- Existing ecosystem tooling and dashboards
- Long-term maintenance burden
- Community preferences

### Q: How should Prometheus handle OTel conventions that are not yet stable?

If OTel semantic conventions are chosen, Prometheus must decide how to handle conventions that haven't reached "Stable" status (e.g., Kubernetes conventions are currently "Experimental"). Options include:

1. **Strict stability requirement**: Only adopt stable conventions; define Prometheus-specific names for unstable areas
2. **Pragmatic adoption**: Adopt widely-used experimental conventions with clear documentation about potential future changes
3. **Hybrid approach**: Use stable OTel conventions where available, Prometheus-native names elsewhere

### Q: Should entity types be namespaced by SD mechanism?

When multiple SD mechanisms can discover similar resources (e.g., EC2, Azure, GCE all discover "hosts"), should entity types be:

- **Generic**: `host` (requires merging semantics across providers)
- **Provider-specific**: `ec2.instance`, `azure.vm`, `gce.instance` (clearer provenance, no collision risk)
- **Hierarchical**: `host` with `cloud.provider` as an identifying label

---

## Related Documents

- [01-context.md](./01-context.md) - Problem statement, motivation, and use cases
- [02-exposition-formats.md](./02-exposition-formats.md) - How entities are represented in wire formats
- [05-storage.md](./05-storage.md) - How entities are stored in the TSDB
- [06-querying.md](./06-querying.md) - PromQL extensions for working with entities
- [07-web-ui-and-apis.md](./07-web-ui-and-apis.md) - How entities are displayed and accessed

---

*This proposal is a work in progress. Feedback is welcome.*

