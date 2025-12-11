# Exposition Formats

## Abstract

This document specifies how Prometheus exposition formats should be extended to support the Entity concept introduced in [01-context.md](./01-context.md). It covers syntax additions to the text format and new protobuf message definitions.

The goal is to enable first-class representation of entities—the things that produce telemetry—while maintaining backward compatibility with existing scrapers that don't understand entities.

---

## The Entity Concept

An **Entity** represents a distinct object of interest that produces or is described by telemetry. Examples include:

| Component | Description |
|-----------|-------------|
| **Type** | The entity type this instance belongs to (e.g., `k8s.pod`) |
| **Identifying Labels** | Labels that uniquely identify this entity instance. Must remain constant for the entity's lifetime. |
| **Descriptive Labels** | Additional context about the entity. May change over time. |

Examples of entities:

- A Kubernetes pod (`k8s.pod`) identified by namespace and UID
- A host or node (`k8s.node`) identified by node UID
- A service instance (`service`) identified by namespace, name, and instance ID

---

## Text Format

### New Syntax Elements

| Element | Syntax | Description |
|---------|--------|-------------|
| Entity type declaration | `# ENTITY_TYPE <type>` | Declares an entity type for subsequent entities |
| Identifying labels | `# ENTITY_IDENTIFYING <label1> <label2> ...` | Lists which labels form the identity |
| Entity instance | `<type>{<labels>}` | An entity instance (no value) |

### Complete Example

```
# ENTITY_TYPE k8s.pod
# ENTITY_IDENTIFYING k8s.namespace.name k8s.pod.uid
k8s.pod{k8s.namespace.name="default",k8s.pod.uid="550e8400-e29b-41d4-a716-446655440000",k8s.pod.name="nginx-7b9f5"}
k8s.pod{k8s.namespace.name="default",k8s.pod.uid="660e8400-e29b-41d4-a716-446655440001",k8s.pod.name="redis-cache-0"}
k8s.pod{k8s.namespace.name="kube-system",k8s.pod.uid="770e8400-e29b-41d4-a716-446655440002",k8s.pod.name="coredns-5dd5756b68-abcde"}

# ENTITY_TYPE k8s.node
# ENTITY_IDENTIFYING k8s.node.uid
k8s.node{k8s.node.uid="node-uid-001",k8s.node.name="worker-1",k8s.node.os="linux",k8s.node.kernel="5.15.0"}
k8s.node{k8s.node.uid="node-uid-002",k8s.node.name="worker-2",k8s.node.os="linux",k8s.node.kernel="5.15.0"}

# ENTITY_TYPE service
# ENTITY_IDENTIFYING service.namespace service.name service.instance.id
service{service.namespace="production",service.name="payment-service",service.instance.id="i-abc123",service.version="2.1.0"}

---

# TYPE container_cpu_usage_seconds counter
# HELP container_cpu_usage_seconds Total CPU usage in seconds
# This metric correlates with BOTH k8s.pod and k8s.node entities
# (it contains the identifying labels of both)
container_cpu_usage_seconds_total{k8s.namespace.name="default",k8s.pod.uid="550e8400-e29b-41d4-a716-446655440000",k8s.node.uid="node-uid-001",container="nginx"} 1234.5
container_cpu_usage_seconds_total{k8s.namespace.name="default",k8s.pod.uid="660e8400-e29b-41d4-a716-446655440001",k8s.node.uid="node-uid-002",container="redis"} 567.8

# TYPE http_requests counter
# HELP http_requests Total HTTP requests
http_requests_total{service.namespace="production",service.name="payment-service",service.instance.id="i-abc123",method="GET",status="200"} 9999

# EOF
```

### Parsing Rules

1. `# ENTITY_TYPE` starts a new entity family block
2. `# ENTITY_IDENTIFYING` must follow `# ENTITY_TYPE` before any entity instances
3. Entity instances (lines matching `<type>{...}` with no value) are ONLY valid after an `# ENTITY_TYPE` declaration. A line like `foo{bar="baz"}` without a preceding entity type declaration is a parse error.
4. Entity instances MUST contain all identifying labels declared in `# ENTITY_IDENTIFYING`
5. The entity type name in the instance line MUST match the declared `# ENTITY_TYPE`

### Entity Section Ordering

**All entities MUST appear at the beginning of the scrape response, before any metrics.** The entity section ends with a `---` delimiter on its own line.

This ordering requirement exists for practical reasons: when Prometheus parses a metric, it needs to immediately correlate that metric with any relevant entities. If entities could appear anywhere in the response, Prometheus would need to either buffer all metrics until the entire response is parsed, or make a second pass through the data. Both approaches add complexity and memory overhead.

By requiring entities first, the parser can process the exposition in a single pass. When it encounters a metric, all potentially correlated entities are already in memory and correlation can happen immediately.

If no entities are present, the `---` delimiter may be omitted. If entities are present but metrics appear before the `---` delimiter (or without one), the scrape fails with a parse error.

---

## Protobuf Format

### New Message Definitions

```protobuf
syntax = "proto2";

package io.prometheus.client;

// EntityFamily groups entities of the same type
message EntityFamily {
  // Entity type name (e.g., "k8s.pod", "service", "build")
  required string type = 1;
  
  // Names of labels that form the unique identity
  repeated string identifying_label_names = 2;
  
  // Entity instances of this type
  repeated Entity entity = 3;
}

// Entity represents a single entity instance
message Entity {
  // All labels (both identifying and descriptive)
  repeated LabelPair label = 1;
}
```

### Integration with Existing Messages

The existing `MetricFamily` structure remains unchanged. A new top-level message wraps both:

```protobuf
// MetricPayload is the top-level message for scrape responses
// that include both entities and metrics
message MetricPayload {
  // Entity families
  repeated EntityFamily entity_family = 1;
  
  repeated MetricFamily metric_family = 2;
}
```

### Content-Type

For protobuf with entity support:

```
application/vnd.google.protobuf;proto=io.prometheus.client.MetricPayload;encoding=delimited
```

For protobuf with entity support, the `proto` parameter changes from `MetricFamily` to `MetricPayload` to indicate the new top-level message type.

---

## Entity-Metric Correlation

### How Correlation Works

Entities correlate with metrics through **shared identifying labels**:

- If a metric has labels that match ALL identifying labels of an entity (same names, same values), that metric is associated with that entity.
- A single metric can correlate with multiple entities (of different types) if it contains the identifying labels of each.

**Example:**

```
# ENTITY_TYPE k8s.pod
# ENTITY_IDENTIFYING k8s.namespace.name k8s.pod.uid
k8s.pod{k8s.namespace.name="default",k8s.pod.uid="550e8400",k8s.pod.name="nginx"}

---

# This metric correlates with the entity above (has both identifying labels)
container_cpu_usage_seconds_total{k8s.namespace.name="default",k8s.pod.uid="550e8400",container="app"} 1234.5
```

Correlation is computed at ingestion time when Prometheus parses the exposition format. See [05-storage.md](./05-storage.md#correlation-index) for how Prometheus builds and maintains these correlations in storage.

### Conflict Detection

When a metric correlates with an entity, the query engine enriches the metric's labels with the entity's descriptive labels (see [06-querying.md](./06-querying.md)). This creates the possibility of label conflicts—a metric might have a label with the same name as an entity's descriptive label.

A conflict occurs when:
- A metric correlates with an entity (has all identifying labels)
- The metric has a label with the same name as one of the entity's descriptive labels
- The values differ

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Label Conflict Detection                            │
└─────────────────────────────────────────────────────────────────────────────┘

Entity (k8s.pod)                              Metric (my_metric)
┌─────────────────────────────────┐           ┌─────────────────────────────────┐
│ Identifying Labels:             │           │ Labels:                         │
│   k8s.namespace.name = "default"│◄─────────►│   k8s.namespace.name = "default"│ ✓ Match
│   k8s.pod.uid = "abc-123"       │◄─────────►│   k8s.pod.uid = "abc-123"       │ ✓ Match
├─────────────────────────────────┤           ├─────────────────────────────────┤
│ Descriptive Labels:             │           │                                 │
│   version = "2.0"               │◄────╳────►│   version = "1.0"               │ ✗ CONFLICT!
│   k8s.pod.name = "nginx"        │           │                                 │
└─────────────────────────────────┘           │ Value: 42                       │
                                              └─────────────────────────────────┘

Correlation established via matching identifying labels,
but "version" exists in both with different values → Scrape fails!
```

**Example conflict in exposition format:**
```
# ENTITY_TYPE k8s.pod
# ENTITY_IDENTIFYING k8s.namespace.name k8s.pod.uid
k8s.pod{k8s.namespace.name="default",k8s.pod.uid="abc-123",version="2.0"}

---

# This metric has k8s.pod identifying labels, so it correlates with the entity.
# But it also has a "version" label that conflicts with the entity's "version" label!
my_metric{k8s.namespace.name="default",k8s.pod.uid="abc-123",version="1.0"} 42
```

When a conflict is detected during scrape, **the scrape fails with an error**. 

Note that **identifying labels cannot conflict** because they must be present on the metric for correlation to occur—if the metric has the same label name with a different value, it simply won't correlate with that entity.

---

## Technical Implementation

This section provides detailed implementation guidance for parsing entities and integrating with the scrape loop. The implementation should align with the storage layer defined in [05-storage.md](./05-storage.md).

### Parser Interface Extensions

The existing `Parser` interface in `model/textparse/interface.go` needs new methods and entry types to handle entities:

#### New Entry Types

The `Entry` type is extended with new values for entity handling:

```go
// Current Entry types (model/textparse/interface.go:206-213)
const (
    EntryInvalid   Entry = -1
    EntryType      Entry = 0
    EntryHelp      Entry = 1
    EntrySeries    Entry = 2
    EntryComment   Entry = 3
    EntryUnit      Entry = 4
    EntryHistogram Entry = 5
    
    // New entity entry types
    EntryEntityType        Entry = 6  // # ENTITY_TYPE <type>
    EntryEntityIdentifying Entry = 7  // # ENTITY_IDENTIFYING <label1> <label2> ...
    EntryEntity            Entry = 8  // <type>{<labels>} (no value)
    EntryEntityDelimiter   Entry = 9  // --- (marks end of entity section)
)
```

When the parser encounters `---`, it returns `EntryEntityDelimiter`. After this point, any entity declarations are a parse error—all entities must appear before the delimiter.

#### New Parser Methods

```go
// Parser interface additions
type Parser interface {
    // ... existing methods (Series, Histogram, Help, Type, Unit, etc.) ...
    
    // EntityType returns the entity type name from an ENTITY_TYPE declaration.
    // Must only be called after Next() returned EntryEntityType.
    // The returned byte slice becomes invalid after the next call to Next.
    EntityType() []byte
    
    // EntityIdentifying returns the list of identifying label names.
    // Must only be called after Next() returned EntryEntityIdentifying.
    // The returned slice becomes invalid after the next call to Next.
    EntityIdentifying() [][]byte
    
    // EntityLabels writes the entity labels into the passed labels.
    // Must only be called after Next() returned EntryEntity.
    // All labels (both identifying and descriptive) are included.
    EntityLabels(l *labels.Labels)
}
```

### Scrape Loop Integration

The scrape loop in `scrape/scrape.go` needs significant changes to process entities alongside metrics.

#### Entity Cache

Extend `scrapeCache` to track entities similar to how it tracks series:

```go
// Entity cache entry (analogous to cacheEntry for series)
type entityCacheEntry struct {
    ref               storage.EntityRef
    lastIter          uint64
    hash              uint64
    identifyingLabels labels.Labels
    descriptiveLabels labels.Labels
}

type scrapeCache struct {
    // ... existing fields (series, droppedSeries, seriesCur, seriesPrev, metadata) ...
    
    // Entity parsing state (reset each scrape)
    currentEntityType       string
    currentIdentifyingNames []string
    
    // Entity tracking (persists across scrapes)
    entities     map[string]*entityCacheEntry  // key: hash of identifying attrs
    entityCur    map[storage.EntityRef]*entityCacheEntry
    entityPrev   map[storage.EntityRef]*entityCacheEntry
}

func newScrapeCache(metrics *scrapeMetrics) *scrapeCache {
    return &scrapeCache{
        // ... existing initialization ...
        entities:   map[string]*entityCacheEntry{},
        entityCur:  map[storage.EntityRef]*entityCacheEntry{},
        entityPrev: map[storage.EntityRef]*entityCacheEntry{},
    }
}
```

#### Entity Processing in append()

The main append loop in `scrapeLoop.append()` is extended:

```go
func (sl *scrapeLoop) append(app storage.Appender, b []byte, contentType string, ts time.Time) (total, added, seriesAdded int, err error) {
    defTime := timestamp.FromTime(ts)
    
    // ... existing parser creation ...
    
    var (
        // ... existing variables ...
        entitiesTotal  int
        entitiesAdded  int
    )

loop:
    for {
        et, err := p.Next()
        if err != nil {
            if errors.Is(err, io.EOF) {
                err = nil
            }
            break
        }
        
        switch et {
        case textparse.EntryEntityType:
            sl.cache.currentEntityType = string(p.EntityType())
            sl.cache.currentIdentifyingNames = nil
            continue
            
        case textparse.EntryEntityIdentifying:
            names := p.EntityIdentifying()
            sl.cache.currentIdentifyingNames = make([]string, len(names))
            for i, name := range names {
                sl.cache.currentIdentifyingNames[i] = string(name)
            }
            continue
            
        case textparse.EntryEntity:
            entitiesTotal++
            if err := sl.processEntity(app, p, defTime); err != nil {
                sl.l.Debug("Entity processing error", "err", err)
                // Depending on error type, may break or continue
                if isEntityLimitError(err) {
                    break loop
                }
                continue
            }
            entitiesAdded++
            continue
            
        case textparse.EntryType:
            // ... existing handling ...
        case textparse.EntryHelp:
            // ... existing handling ...
        case textparse.EntrySeries, textparse.EntryHistogram:
            // ... existing metric handling ...
            // ADD: conflict detection before appending
        }
    }
    
    // Update stale markers for both series AND entities
    if err == nil {
        err = sl.updateStaleMarkers(app, defTime)
        sl.updateEntityStaleMarkers(app, defTime)
    }
    
    return total, added, seriesAdded, err
}
```

#### Entity Processing Method

```go
func (sl *scrapeLoop) processEntity(app storage.Appender, p textparse.Parser, ts int64) error {
    var allLabels labels.Labels
    p.EntityLabels(&allLabels)
    
    // Validate: all identifying labels must be present
    identifying, descriptive := sl.splitEntityLabels(allLabels)
    if len(identifying) != len(sl.cache.currentIdentifyingNames) {
        return fmt.Errorf("entity missing required identifying labels: expected %v", 
            sl.cache.currentIdentifyingNames)
    }
    
    // Check entity limit
    if sl.entityLimit > 0 && len(sl.cache.entities) >= sl.entityLimit {
        return errEntityLimit
    }
    
    hash := identifying.Hash()
    hashKey := fmt.Sprintf("%s:%d", sl.cache.currentEntityType, hash)
    
    // Check cache for existing entity
    ce, cached := sl.cache.entities[hashKey]
    if cached {
        ce.lastIter = sl.cache.iter
        
        // Check if descriptive labels changed
        if !labels.Equal(ce.descriptiveLabels, descriptive) {
            ce.descriptiveLabels = descriptive
            // Will trigger a WAL write via AppendEntity
        }
    }
    
    // Call storage appender
    ref, err := app.AppendEntity(
        sl.cache.currentEntityType,
        identifying,
        descriptive,
        ts,
    )
    if err != nil {
        return err
    }
    
    // Update cache
    if !cached {
        ce = &entityCacheEntry{
            ref:               ref,
            lastIter:          sl.cache.iter,
            hash:              hash,
            identifyingLabels: identifying,
            descriptiveLabels: descriptive,
        }
        sl.cache.entities[hashKey] = ce
    } else {
        ce.ref = ref
    }
    
    sl.cache.entityCur[ref] = ce
    return nil
}

func (sl *scrapeLoop) splitEntityLabels(allLabels labels.Labels) (labels.Labels, labels.Labels) {
    identifyingSet := make(map[string]struct{})
    for _, name := range sl.cache.currentIdentifyingNames {
        identifyingSet[name] = struct{}{}
    }
    
    var identifying, descriptive labels.Labels
    allLabels.Range(func(l labels.Label) {
        if _, ok := identifyingSet[l.Name]; ok {
            identifying = append(identifying, l)
        } else {
            descriptive = append(descriptive, l)
        }
    })
    
    return identifying, descriptive
}
```

#### Entity Staleness

Entity staleness works similarly to series staleness, but marks entities as dead rather than writing StaleNaN:

```go
func (sl *scrapeLoop) updateEntityStaleMarkers(app storage.Appender, ts int64) error {
    for ref, ce := range sl.cache.entityPrev {
        if _, ok := sl.cache.entityCur[ref]; ok {
            continue // Entity still present
        }
        
        // Entity disappeared - mark it dead
        // The storage layer handles this by setting endTime
        if err := app.MarkEntityDead(ref, ts); err != nil {
            sl.l.Debug("Error marking entity dead", "ref", ref, "err", err)
        }
        
        // Remove from cache
        for hashKey, e := range sl.cache.entities {
            if e.ref == ref {
                delete(sl.cache.entities, hashKey)
                break
            }
        }
    }
    
    return nil
}

func (c *scrapeCache) entityIterDone(flush bool) {
    // Swap current and previous (same pattern as series)
    c.entityPrev, c.entityCur = c.entityCur, c.entityPrev
    clear(c.entityCur)
}
```

### Scrape Configuration

New configuration options in `config/config.go`:

```go
type ScrapeConfig struct {
    // ... existing fields ...
    
    // EnableEntityScraping enables parsing of entity declarations.
    // Default: false for backward compatibility.
    EnableEntityScraping bool `yaml:"enable_entity_scraping,omitempty"`
    
    // EntityLimit is the maximum number of entities per scrape target.
    // 0 means no limit.
    EntityLimit int `yaml:"entity_limit,omitempty"`
}
```

### Data Flow Summary

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                           Scrape Data Flow                                    │
└───────────────────────────────────────────────────────────────────────────────┘

  Target /metrics                    Prometheus Scrape Loop
  ┌─────────────────┐                ┌─────────────────────────────────────────┐
  │ # ENTITY_TYPE   │                │                                         │
  │ # ENTITY_IDENT  │ ──HTTP GET──►  │  1. Create Parser (textparse.New)       │
  │ entity{...}     │                │                                         │
  │                 │                │  2. Loop: p.Next()                      │
  │ # TYPE metric   │                │     ├─ EntryEntityType → cache type     │
  │ metric{...} 123 │                │     ├─ EntryEntityIdent → cache names   │
  │ # EOF           │                │     ├─ EntryEntity → processEntity()    │
  └─────────────────┘                │     │   └─ app.AppendEntity()           │
                                     │     ├─ EntrySeries → checkConflicts()   │
                                     │     │   └─ app.Append()                 │
                                     │     └─ EntryHistogram → ...             │
                                     │                                         │
                                     │  3. updateStaleMarkers()                │
                                     │     ├─ Series: Write StaleNaN           │
                                     │     └─ Entities: app.MarkEntityDead()   │
                                     │                                         │
                                     │  4. app.Commit()                        │
                                     │     ├─ Write WAL records                │
                                     │     ├─ Update Head structures           │
                                     │     └─ Build correlation index          │
                                     └─────────────────────────────────────────┘
                                                        │
                                                        ▼
                                     ┌─────────────────────────────────────────┐
                                     │             Storage (TSDB)              │
                                     │  ┌─────────────┐  ┌─────────────────┐   │
                                     │  │ WAL Records │  │ Head Block      │   │
                                     │  │ - Series    │  │ - memSeries     │   │
                                     │  │ - Samples   │  │ - memEntity     │   │
                                     │  │ - Entities  │  │ - Correlation   │   │
                                     │  └─────────────┘  │   Index         │   │
                                     │                   └─────────────────┘   │
                                     └─────────────────────────────────────────┘
```

In the [storage](04-storage.md) document, we go over the correlation index, WAL and memEntity struct in greater details.

---

## Related Documents

- [01-context.md](./01-context.md) - Problem statement and motivation
- [03-sdk.md](./03-sdk.md) - How Prometheus client libraries support entities
- [04-service-discovery.md](./04-service-discovery.md) - How entities relate to Prometheus targets
- [05-storage.md](./05-storage.md) - How entities are stored in the TSDB
- [06-querying.md](./06-querying.md) - PromQL extensions for working with entities
- [07-web-ui-and-apis.md](./07-web-ui-and-apis.md) - How entities are displayed and accessed

---

*This proposal is a work in progress. Feedback is welcome.*

