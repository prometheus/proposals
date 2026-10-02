# SDK Support for Entities

## Abstract

This document specifies how Prometheus client libraries should be extended to support the Entity concept. Using client_golang as the reference implementation, we define new types, interfaces, and patterns that enable applications to declare entities alongside metrics while maintaining backward compatibility with existing instrumentation code.

The design prioritizes simplicity for the common case—an application instrumenting itself as a single entity—while providing flexibility for advanced scenarios like exporters that expose metrics for multiple entities.

---

## Design Principles

Before diving into implementation details, it's worth understanding the key design decisions that shaped this proposal.

**Entities are not collectors.** In client_golang, metrics are managed through the Collector interface, which combines description and collection into a single abstraction. We considered making entities follow this pattern, but entities have fundamentally different characteristics: they represent the "things" that produce telemetry, not the telemetry itself. An entity like "this Kubernetes pod" cuts across multiple collectors (process metrics, Go runtime metrics, application metrics). Tying entities to collectors would create awkward ownership questions and unnecessary coupling.

**The EntityRegistry is global and separate from the metric Registry.** This separation reflects the conceptual difference between "what is producing telemetry" (entities) and "what telemetry is being produced" (metrics). Making the EntityRegistry global (via `DefaultEntityRegistry`) enables validation at metric registration time—if a metric references a non-existent entity ref, registration fails immediately rather than silently producing invalid output at scrape time.

**Descriptive labels are mutable, identifying labels are not.** An entity's identity (its type plus identifying labels) is immutable—changing it would make it a different entity. But descriptive labels like version numbers or human-readable names can change during the entity's lifetime. The API reflects this: `SetDescriptiveLabels()` atomically replaces all descriptive labels, while identifying labels are set only at construction.

---

## Entity Types

### Entity

The `Entity` type represents a single entity instance:

```go
type Entity struct {
    ref               uint64       // Assigned by EntityRegistry
    entityType        string       // e.g., "service", "k8s.pod"
    identifyingLabels Labels       // Immutable after creation
    descriptiveLabels Labels       // Mutable via SetDescriptiveLabels
    mtx               sync.RWMutex // Protects descriptiveLabels
}

// EntityOpts configures a new Entity
type EntityOpts struct {
    Type        string // Required: entity type name
    Identifying Labels // Required: labels that uniquely identify this instance
    Descriptive Labels // Optional: additional context labels
}

// NewEntity creates an entity.
func NewEntity(opts EntityOpts) *Entity

// Ref returns the entity's reference (0 if not yet registered)
func (e *Entity) Ref() uint64

// Type returns the entity type
func (e *Entity) Type() string

// IdentifyingLabels returns a copy of the identifying labels
func (e *Entity) IdentifyingLabels() Labels

// DescriptiveLabels returns a copy of the current descriptive labels
func (e *Entity) DescriptiveLabels() Labels

// SetDescriptiveLabels atomically replaces all descriptive labels
func (e *Entity) SetDescriptiveLabels(labels Labels)
```

### EntityRegistry

The `EntityRegistry` is a **global singleton**, similar to `prometheus.DefaultRegisterer`. This ensures that metrics can validate entity refs at registration time—if a metric references a non-existent entity, registration fails immediately rather than at scrape time.

```go
// Global EntityRegistry instance
var DefaultEntityRegistry = NewEntityRegistry()

type EntityRegistry struct {
    mtx        sync.RWMutex
    byHash     map[uint64]*Entity // hash(type+identifying) → Entity
    byRef      map[uint64]*Entity // ref → Entity
    refCounter uint64             // Auto-increments on Register
}


// Register adds an entity and assigns its ref.
// Returns error if an entity with the same type+identifying labels exists.
func (er *EntityRegistry) Register(e *Entity) error

// Unregister removes an entity by ref
func (er *EntityRegistry) Unregister(ref uint64) bool

// Lookup finds an entity by type and identifying labels, returns its ref
func (er *EntityRegistry) Lookup(entityType string, identifying Labels) (ref uint64, found bool)

// Get retrieves an entity by ref
func (er *EntityRegistry) Get(ref uint64) *Entity

// Gather collects entities and metrics together into a MetricPayload.
// Only entities referenced by the gathered metrics are included.
func (er *EntityRegistry) Gather(gatherers ...Gatherer) (*dto.MetricPayload, error)
```

---

## Metric Integration

Metrics declare their entity associations through the `EntityRefs` field in their options. This field contains the refs of entities that the metric correlates with.

### Updated Metric Options

```go
type CounterOpts struct {
    Namespace   string
    Subsystem   string
    Name        string
    Help        string
    ConstLabels Labels
    
    // EntityRefs lists the refs of entities this metric correlates with.
    // Obtain refs via Entity.Ref() after registering with EntityRegistry.
    EntityRefs []uint64
}

// Same pattern for GaugeOpts, HistogramOpts, SummaryOpts, etc.
```

### Validation at Registration

When a metric with `EntityRefs` is registered, the metric registry validates that all referenced entity refs exist in the global `DefaultEntityRegistry`. This catches configuration errors immediately:

```go
// This works: entity is registered first
serviceEntity := prometheus.NewEntity(prometheus.EntityOpts{...})
prometheus.RegisterEntity(serviceEntity)  // Uses DefaultEntityRegistry

counter := prometheus.NewCounter(prometheus.CounterOpts{
    Name:       "requests_total",
    EntityRefs: []uint64{serviceEntity.Ref()},
})
prometheus.MustRegister(counter)  // Validates that serviceEntity.Ref() exists

// This fails: entity ref doesn't exist
badCounter := prometheus.NewCounter(prometheus.CounterOpts{
    Name:       "bad_counter",
    EntityRefs: []uint64{999},  // No entity with this ref
})
prometheus.MustRegister(badCounter)  // PANIC: unknown entity ref 999
```

### Usage Example

```go
// Create and register entity
serviceEntity := prometheus.NewEntity(prometheus.EntityOpts{
    Type: "service",
    Identifying: prometheus.Labels{
        "service.namespace":   "production",
        "service.name":        "payment-api",
        "service.instance.id": os.Getenv("INSTANCE_ID"),
    },
    Descriptive: prometheus.Labels{
        "service.version": "1.0.0",
    },
})
prometheus.RegisterEntity(serviceEntity)

// Create metric that correlates with the entity
requestDuration := prometheus.NewHistogram(prometheus.HistogramOpts{
    Name:       "http_request_duration_seconds",
    Help:       "HTTP request latency",
    Buckets:    prometheus.DefBuckets,
    EntityRefs: []uint64{serviceEntity.Ref()},
})
prometheus.MustRegister(requestDuration)

// Later: update descriptive labels during rolling deploy
serviceEntity.SetDescriptiveLabels(prometheus.Labels{
    "service.version": "2.0.0",
})
```

### Multiple Entity Correlations

A single metric can correlate with multiple entities. This is useful when a metric describes something that spans entity boundaries:

```go
// Register both pod and node entities
podEntity := prometheus.NewEntity(prometheus.EntityOpts{
    Type: "k8s.pod",
    Identifying: prometheus.Labels{
        "k8s.namespace.name": "default",
        "k8s.pod.uid":        "abc-123",
    },
})
nodeEntity := prometheus.NewEntity(prometheus.EntityOpts{
    Type: "k8s.node",
    Identifying: prometheus.Labels{
        "k8s.node.uid": "node-456",
    },
})
entityRegistry.Register(podEntity)
entityRegistry.Register(nodeEntity)

// Container CPU correlates with both pod AND node
containerCPU := prometheus.NewCounter(prometheus.CounterOpts{
    Name:       "container_cpu_usage_seconds_total",
    Help:       "Total CPU usage by container",
    EntityRefs: []uint64{podEntity.Ref(), nodeEntity.Ref()},
})
```

---

## Gathering and Exposition

The `EntityRegistry.Gather()` method is the central coordination point. It accepts metric gatherers as arguments and returns a complete `dto.MetricPayload` containing both entities and metrics. This design enforces that entities are never gathered in isolation—they only make sense alongside their correlated metrics.

### How Gather Works

The `Gather()` method coordinates metric and entity collection:

1. **Collect metrics** from all provided gatherers
2. **Track entity references** — identify which entity refs are used by the gathered metrics
3. **Filter entities** — include only entities that are actually referenced by at least one metric
4. **Return payload** — combine entity families and metric families into a single `MetricPayload`

This filtering ensures that:
- **Metrics without entities** are still exposed
- **Entities without metrics** are excluded
- **Only the entities actually needed** are transmitted, reducing payload size

### HTTP Handler Updates

The promhttp package provides `HandlerFor()` that accepts an `EntityRegistry` and metric gatherers, returning an HTTP handler that:

1. Calls `EntityRegistry.Gather()` with the provided gatherers
2. Negotiates content type (text or protobuf)
3. Encodes the combined `MetricPayload` to the response

### Usage Example

```go
func main() {
    // Register entity (uses global DefaultEntityRegistry)
    serviceEntity := prometheus.NewEntity(prometheus.EntityOpts{...})
    prometheus.RegisterEntity(serviceEntity)
    
    // Register metrics
    counter := prometheus.NewCounter(prometheus.CounterOpts{
        Name:       "requests_total",
        EntityRefs: []uint64{serviceEntity.Ref()},
    })
    prometheus.MustRegister(counter)
    
    // Expose via HTTP - uses global registries
    http.Handle("/metrics", promhttp.Handler())  // Enhanced to use DefaultEntityRegistry
    http.ListenAndServe(":8080", nil)
}
```

For custom registries, pass them explicitly:

```go
entityReg := prometheus.NewEntityRegistry()
metricReg := prometheus.NewRegistry()

http.Handle("/metrics", promhttp.HandlerFor(entityReg, []prometheus.Gatherer{metricReg}, promhttp.HandlerOpts{}))
```

---

## Changes to Supporting Libraries

Implementing entity support requires coordinated changes across multiple repositories.

### client_model

The protobuf definitions need new message types:

```protobuf
// EntityFamily groups entities of the same type
message EntityFamily {
    required string type = 1;
    repeated string identifying_label_names = 2;
    repeated Entity entity = 3;
}

// Entity represents a single entity instance
message Entity {
    repeated LabelPair label = 1;  // All labels (identifying + descriptive)
}

// MetricPayload is the top-level message for combined exposition
message MetricPayload {
    repeated EntityFamily entity_family = 1;
    repeated MetricFamily metric_family = 2;
}
```

### common/expfmt

The exposition format library needs encoder support for `MetricPayload`:

```go
// PayloadEncoder encodes a complete MetricPayload
type PayloadEncoder interface {
    EncodePayload(payload *dto.MetricPayload) error
}

// NewPayloadEncoder creates an encoder for the combined format
func NewPayloadEncoder(w io.Writer, format Format) PayloadEncoder
```

For the text format, the encoder writes the payload in order: entity declarations first, then the `---` delimiter, then metric families. For the protobuf format, the encoder marshals the `MetricPayload` message directly.

### client_golang

The changes described in this document:
- New `Entity` and `EntityRegistry` types
- `EntityRegistry.Gather()` that accepts metric gatherers and returns `*dto.MetricPayload`
- Updated metric options with `EntityRefs` field
- Updated promhttp handlers

---

## Backward Compatibility

The design maintains full backward compatibility:

**Existing metrics continue to work.** The `EntityRefs` field is optional. Metrics without entity associations work exactly as before—they simply don't correlate with any entity.

**Existing registries are unaffected.** The metric `Registry` type is unchanged. Entity support is additive through the separate `EntityRegistry`.

**Existing HTTP handlers work.** The standard `promhttp.Handler()` continues to expose metrics without entities. Applications opt into entity support by using the new `HandlerFor()` that accepts an `EntityRegistry`.

**Gradual adoption is possible.** Applications can add entity support incrementally—register an entity, update a few metrics to reference it, and the rest continue working unchanged.

---

## Advanced: Dynamic Entity Associations

The design presented above works well for applications that instrument themselves, where entities are known at startup and metrics have fixed entity associations. However, some use cases require dynamic associations.

### Exporters with Many Entities

Exporters like kube-state-metrics expose metrics for thousands of entities (pods, nodes, deployments). Each metric sample correlates with a different entity based on its label values. For these cases, we propose a per-sample entity association:

```go
// GaugeVec with per-sample entity support
podInfo := prometheus.NewGaugeVec(prometheus.GaugeVecOpts{
    Name:           "kube_pod_info",
    VariableLabels: []string{"pod_name", "node"},
})

// When recording, specify which entity this sample correlates with
podInfo.WithEntityRef(podEntities[pod.UID].Ref()).
    WithLabelValues("nginx", "node-1").
    Set(1)
```

This API extension is optional and can be added in a future iteration once the core entity support is stable.

---

## Open Questions

Several aspects of this design warrant community feedback:

**promauto integration.** How should the promauto convenience package handle entities?

**Entity unregistration and metrics.** If an entity is unregistered while metrics still reference it, what should happen? Options: prevent unregistration while referenced, allow it and have Gather skip the missing entity, or error at gather time.

---

## Related Documents

- [01-context.md](./01-context.md) — Problem statement and entity concept
- [02-exposition-formats.md](./02-exposition-formats.md) — Wire format for entities
- [05-storage.md](./05-storage.md) — How Prometheus stores entities

