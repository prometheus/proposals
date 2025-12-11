# Storage Design: Entity-Native Model

> **Alternative Approach**: This document describes an alternative storage design where series identity is based only on metric labels, with samples grouped into "streams" by entity. While this approach offers stronger alignment with OpenTelemetry's data model and addresses cardinality at a fundamental level, it requires significant changes to Prometheus's core architecture. We recommend the correlation-based approach described in [05-storage.md](05-storage.md) for initial implementation, as it can be built incrementally on the existing TSDB without breaking backward compatibility. This entity-native design remains valuable as a potential future evolution once entities prove their value in production.

## Executive Summary

This document proposes a fundamental redesign of Prometheus's storage model to natively support Entities as first-class concepts, separate from metric identity. The key insight is that **metric identity** (what is being measured) should be separate from **entity identity** (what is being measured about).

### Core Idea

```
Series:
  labels: {__name__="http_requests_total", method="GET", status="200"}  # metric labels only
  data: [
    { 
      entityRefs: [podRef1, nodeRef1, serviceRef1], 
      samples: [{t: 1000, v: 100}, {t: 1015, v: 120}] 
    },
    { 
      entityRefs: [podRef2, nodeRef3], 
      samples: [{t: 1000, v: 1020}, {t: 1015, v: 1203}] 
    }
  ]
```

This model separates:
- **What** is being measured → Series labels (metric name + metric-specific labels)
- **About what** it's being measured → Entity references (linking to entity storage)

---

## Part 1: Current TSDB Model (Reference)

Before diving into the new model, let's understand the current Prometheus TSDB architecture.

### Current Series Identity

In the current model, a series is uniquely identified by its **complete label set**:

```go
type memSeries struct {
    ref       chunks.HeadSeriesRef  // Unique identifier (auto-incrementing)
    lset      labels.Labels          // Complete label set (includes ALL labels)
    headChunks *memChunk             // In-memory samples
    mmappedChunks []*mmappedChunk    // Memory-mapped chunks on disk
    // ...
}
```

**Example:** These are THREE different series in current Prometheus:
```
http_requests_total{method="GET", status="200", pod="nginx-abc"}  # Series 1
http_requests_total{method="GET", status="200", pod="nginx-def"}  # Series 2  
http_requests_total{method="GET", status="200", pod="nginx-xyz"}  # Series 3
```

### Current Flow

```
Scrape → Labels → Hash(Labels) → getOrCreate(hash, labels) → memSeries → Append Sample
```

The hash of ALL labels determines series identity:

```go
func (a *appender) getOrCreate(l labels.Labels) (series *memSeries, created bool) {
    hash := l.Hash()  // Hash of ALL labels
    
    series = a.series.GetByHash(hash, l)
    if series != nil {
        return series, false
    }
    
    ref := chunks.HeadSeriesRef(a.nextRef.Inc())
    series = &memSeries{ref: ref, lset: l}
    a.series.Set(hash, series)
    return series, true
}
```

### Current Index Structure

The postings index maps `label_name=label_value` → list of series refs:

```
Postings Index:
  method="GET"    → [1, 2, 3, 5, 8, ...]
  status="200"    → [1, 3, 5, 7, 9, ...]
  pod="nginx-abc" → [1, 4, 7, ...]
  pod="nginx-def" → [2, 5, 8, ...]
```

Query `http_requests_total{method="GET", status="200"}` intersects posting lists.

---

## Part 2: Entity-Native Storage Model

### Core Concepts

#### 1. Metric Labels vs Entity Labels

**Metric Labels** describe the measurement itself:
- `method="GET"` - HTTP method being measured
- `status="200"` - Response status being counted
- `le="0.5"` - Histogram bucket boundary
- `quantile="0.99"` - Summary quantile

**Entity Labels** describe what the measurement is about:
- `k8s.pod.uid="abc-123"` - Which pod
- `k8s.node.name="worker-1"` - Which node
- `service.name="api-gateway"` - Which service

#### 2. New Series Definition

```go
// New: Series identity = metric name + metric labels only
type memSeries struct {
    ref        SeriesRef             // Unique identifier
    metricName string                // e.g., "http_requests_total"
    labels     labels.Labels         // Metric-specific labels only (method, status, etc.)
    
    // Multiple data streams, one per entity combination
    streams    []*dataStream         // Samples grouped by entity
}

// A stream of samples from a specific entity combination
type dataStream struct {
    entityRefs []EntityRef           // Which entities this stream is from
    headChunk  *memChunk             // Current in-memory chunk
    mmappedChunks []*mmappedChunk    // Historical chunks
    
    // Staleness tracking per stream
    lastSeen   int64                 // Last sample timestamp
}
```

#### 3. Entity Storage (Separate)

```go
type memEntity struct {
    ref            EntityRef         // Unique identifier (auto-incrementing)
    entityType     string            // e.g., "k8s.pod", "k8s.node", "service"
    identifyingLabels labels.Labels  // Immutable: what makes this entity unique
    
    // Mutable descriptive labels with history
    sync.Mutex
    descriptiveSnapshots []labelSnapshot
    
    // Lifecycle
    startTime      int64             // When this entity incarnation started
    endTime        int64             // 0 if still alive
}

type labelSnapshot struct {
    timestamp int64
    labels    labels.Labels
}
```

### Visual Representation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SERIES STORAGE                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Series 1: http_requests_total{method="GET", status="200"}                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Stream A: entityRefs=[pod:abc, node:worker-1, svc:api]                  ││
│  │   Chunks: [(t=1000,v=100), (t=1015,v=120), ...]                         ││
│  ├─────────────────────────────────────────────────────────────────────────┤│
│  │ Stream B: entityRefs=[pod:def, node:worker-2]                           ││
│  │   Chunks: [(t=1000,v=1020), (t=1015,v=1203), ...]                       ││
│  ├─────────────────────────────────────────────────────────────────────────┤│
│  │ Stream C: entityRefs=[pod:xyz, node:worker-1, svc:api]                  ││
│  │   Chunks: [(t=1020,v=5), (t=1035,v=15), ...]  ← Pod rescheduled here    ││
│  └─────────────────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────────────────┤
│  Series 2: http_requests_total{method="POST", status="201"}                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Stream A: entityRefs=[pod:abc, node:worker-1, svc:api]                  ││
│  │   Chunks: [(t=1000,v=50), (t=1015,v=55), ...]                           ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                           ENTITY STORAGE                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Entity: k8s.pod (ref=pod:abc)                                              │
│    Identifying: {k8s.pod.uid="abc-123"}                                     │
│    Descriptive @ t=1000: {k8s.pod.name="nginx-abc", version="1.0"}          │
│    Descriptive @ t=2000: {k8s.pod.name="nginx-abc", version="1.1"}          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Entity: k8s.node (ref=node:worker-1)                                       │
│    Identifying: {k8s.node.uid="node-uid-001"}                               │
│    Descriptive @ t=0: {k8s.node.name="worker-1", region="us-east-1"}        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Entity: service (ref=svc:api)                                              │
│    Identifying: {service.name="api-gateway", service.namespace="prod"}      │
│    Descriptive @ t=1000: {service.version="2.0", deployment="blue"}         │
│    Descriptive @ t=3000: {service.version="2.1", deployment="green"}        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 3: In-Memory Structures

### 3.1 Series Storage

```go
type Head struct {
    // Series storage - sharded for concurrent access
    series    *stripeSeries
    
    // Entity storage - separate sharded structure
    entities  *stripeEntities
    
    // Index structures
    metricPostings *MetricPostings  // metric labels → series refs
    entityPostings *EntityPostings  // entity refs → (series ref, stream index)
    
    // ... existing fields (WAL, chunks, etc.)
}

// stripeSeries holds series by SeriesRef and by metric label hash
type stripeSeries struct {
    size    int
    series  []map[SeriesRef]*memSeries     // Sharded by ref
    hashes  []seriesHashmap                 // Sharded by metric label hash
    locks   []stripeLock
}

// seriesHashmap - only uses metric labels for lookup
type seriesHashmap struct {
    unique    map[uint64]*memSeries
    conflicts map[uint64][]*memSeries
}
```

### 3.2 Series Lookup

```go
// Key change: Series lookup only uses metric labels
func (a *appender) getOrCreateSeries(metricLabels labels.Labels) (*memSeries, bool) {
    hash := metricLabels.Hash()  // Hash of METRIC labels only
    
    series := a.series.GetByHash(hash, metricLabels)
    if series != nil {
        return series, false
    }
    
    ref := SeriesRef(a.nextSeriesRef.Inc())
    series = &memSeries{
        ref:        ref,
        metricName: metricLabels.Get(labels.MetricName),
        labels:     metricLabels.WithoutEmpty(),
        streams:    make([]*dataStream, 0),
    }
    a.series.Set(hash, series)
    return series, true
}
```

### 3.3 Stream Management

```go
// Find or create a data stream for the given entity combination
func (s *memSeries) getOrCreateStream(entityRefs []EntityRef) (*dataStream, bool) {
    s.Lock()
    defer s.Unlock()
    
    // Look for existing stream with same entity combination
    for _, stream := range s.streams {
        if entityRefsEqual(stream.entityRefs, entityRefs) {
            return stream, false
        }
    }
    
    // Create new stream
    stream := &dataStream{
        entityRefs: entityRefs,
        headChunk:  nil,
        lastSeen:   0,
    }
    s.streams = append(s.streams, stream)
    return stream, true
}

func entityRefsEqual(a, b []EntityRef) bool {
    if len(a) != len(b) {
        return false
    }
    // Sort and compare - entity refs are unordered
    sortedA := sortEntityRefs(a)
    sortedB := sortEntityRefs(b)
    for i := range sortedA {
        if sortedA[i] != sortedB[i] {
            return false
        }
    }
    return true
}
```

### 3.4 Entity Storage

```go
// stripeEntities holds entities by EntityRef and by identifying label hash
type stripeEntities struct {
    size     int
    entities []map[EntityRef]*memEntity     // Sharded by ref
    hashes   []entityHashmap                 // Sharded by (type + identifying labels) hash
    locks    []stripeLock
}

func (a *appender) getOrCreateEntity(
    entityType string,
    identifyingLabels labels.Labels,
    descriptiveLabels labels.Labels,
    timestamp int64,
) (*memEntity, bool) {
    // Hash of type + identifying labels
    hash := hashEntityIdentity(entityType, identifyingLabels)
    
    entity := a.entities.GetByHash(hash, entityType, identifyingLabels)
    if entity != nil {
        // Update descriptive labels if changed
        entity.updateDescriptive(descriptiveLabels, timestamp)
        return entity, false
    }
    
    ref := EntityRef(a.nextEntityRef.Inc())
    entity = &memEntity{
        ref:               ref,
        entityType:        entityType,
        identifyingLabels: identifyingLabels,
        startTime:         timestamp,
        descriptiveSnapshots: []labelSnapshot{{
            timestamp: timestamp,
            labels:    descriptiveLabels,
        }},
    }
    a.entities.Set(hash, entity)
    return entity, true
}
```

---

## Part 4: Index Structures

### 4.1 Metric Postings Index

Maps metric labels to series refs (similar to current postings, but only for metric labels):

```go
type MetricPostings struct {
    mtx sync.RWMutex
    // label name → label value → series refs
    m   map[string]map[string][]SeriesRef
}

// Add a series to the postings index
func (p *MetricPostings) Add(ref SeriesRef, lset labels.Labels) {
    p.mtx.Lock()
    defer p.mtx.Unlock()
    
    lset.Range(func(l labels.Label) {
        if p.m[l.Name] == nil {
            p.m[l.Name] = make(map[string][]SeriesRef)
        }
        p.m[l.Name][l.Value] = append(p.m[l.Name][l.Value], ref)
    })
}

// Get series refs for a label pair
func (p *MetricPostings) Get(name, value string) []SeriesRef {
    p.mtx.RLock()
    defer p.mtx.RUnlock()
    
    if p.m[name] == nil {
        return nil
    }
    return p.m[name][value]
}
```

### 4.2 Entity Postings Index

Maps entity labels to (series, stream) pairs:

```go
type EntityPostings struct {
    mtx sync.RWMutex
    
    // entityRef → list of (seriesRef, streamIndex)
    byEntity map[EntityRef][]streamLocation
    
    // For reverse lookup: entity label → entity refs
    byLabel  map[string]map[string][]EntityRef
}

type streamLocation struct {
    seriesRef   SeriesRef
    streamIndex int
}

// Register that a stream uses an entity
func (p *EntityPostings) AddStreamEntity(
    seriesRef SeriesRef,
    streamIndex int,
    entityRef EntityRef,
) {
    p.mtx.Lock()
    defer p.mtx.Unlock()
    
    loc := streamLocation{seriesRef: seriesRef, streamIndex: streamIndex}
    p.byEntity[entityRef] = append(p.byEntity[entityRef], loc)
}

// Find all streams that use a specific entity
func (p *EntityPostings) GetStreamsByEntity(entityRef EntityRef) []streamLocation {
    p.mtx.RLock()
    defer p.mtx.RUnlock()
    
    return p.byEntity[entityRef]
}
```

### 4.3 Combined Query Flow

```go
// Query: http_requests_total{method="GET", k8s.pod.name="nginx-abc"}
func (q *querier) Select(matchers ...*labels.Matcher) SeriesSet {
    var metricMatchers, entityMatchers []*labels.Matcher
    
    for _, m := range matchers {
        if isEntityLabel(m.Name) {
            entityMatchers = append(entityMatchers, m)
        } else {
            metricMatchers = append(metricMatchers, m)
        }
    }
    
    // Step 1: Find series by metric labels
    seriesRefs := q.metricPostings.PostingsForMatchers(metricMatchers...)
    
    // Step 2: If entity matchers, filter streams
    if len(entityMatchers) > 0 {
        // Find entities that match
        entityRefs := q.findMatchingEntities(entityMatchers)
        
        // Find streams that use these entities
        return q.filterStreamsByEntities(seriesRefs, entityRefs)
    }
    
    // Return all streams from matching series
    return q.allStreamsFromSeries(seriesRefs)
}
```

---

## Part 5: Ingestion Flow

### 5.1 Scrape Processing

```go
func (a *appender) Append(
    metricLabels labels.Labels,    // Only metric-specific labels
    entityRefs []EntityRef,        // Pre-resolved entity references
    timestamp int64,
    value float64,
) error {
    // Step 1: Get or create series (by metric labels only)
    series, seriesCreated := a.getOrCreateSeries(metricLabels)
    
    // Step 2: Get or create stream (by entity combination)
    stream, streamCreated := series.getOrCreateStream(entityRefs)
    
    // Step 3: Append sample to stream
    if err := stream.append(timestamp, value); err != nil {
        return err
    }
    
    // Step 4: Update entity postings if new stream
    if streamCreated {
        streamIdx := len(series.streams) - 1
        for _, entityRef := range entityRefs {
            a.entityPostings.AddStreamEntity(series.ref, streamIdx, entityRef)
        }
    }
    
    // Record for WAL
    a.pendingSamples = append(a.pendingSamples, pendingSample{
        seriesRef:   series.ref,
        streamIndex: len(series.streams) - 1,
        timestamp:   timestamp,
        value:       value,
    })
    
    return nil
}
```

### 5.2 Entity Resolution During Scrape

```go
// During scrape, labels are split into metric vs entity
func (sl *scrapeLoop) processMetrics(
    metrics []parsedMetric,
    entities []parsedEntity,
) error {
    app := sl.appender()
    
    // First, resolve all entities from this scrape
    entityRefMap := make(map[string]EntityRef)
    for _, e := range entities {
        entity, _ := app.getOrCreateEntity(
            e.Type,
            e.IdentifyingLabels,
            e.DescriptiveLabels,
            sl.timestamp,
        )
        entityRefMap[entityKey(e.Type, e.IdentifyingLabels)] = entity.ref
    }
    
    // Then, process metrics with entity references
    for _, m := range metrics {
        metricLabels, entityTypes := splitLabels(m.Labels)
        
        // Resolve entity refs for this metric
        var entityRefs []EntityRef
        for _, et := range entityTypes {
            key := entityKeyFromMetric(et, m.Labels)
            if ref, ok := entityRefMap[key]; ok {
                entityRefs = append(entityRefs, ref)
            }
        }
        
        if err := app.Append(metricLabels, entityRefs, m.Timestamp, m.Value); err != nil {
            return err
        }
    }
    
    return app.Commit()
}
```

---

## Part 6: WAL Format

### 6.1 New Record Types

```go
const (
    // Existing types
    RecordSeries     Type = 1
    RecordSamples    Type = 2
    RecordTombstones Type = 3
    RecordExemplars  Type = 4
    RecordMetadata   Type = 6
    
    // New types for entity-native model
    RecordEntity          Type = 20  // Entity definition
    RecordEntityUpdate    Type = 21  // Descriptive label update
    RecordStream          Type = 22  // New stream in a series
    RecordStreamSamples   Type = 23  // Samples for a specific stream
)
```

### 6.2 Entity Record

```
┌────────────────────────────────────────────────────────────────┐
│ type = 20 <1b>                                                 │
├────────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ entityRef <8b>                                             │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ len(entityType) <uvarint>                                  │ │
│ │ entityType <bytes>                                         │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ n = len(identifyingLabels) <uvarint>                       │ │
│ │ identifyingLabels <labels>                                 │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ m = len(descriptiveLabels) <uvarint>                       │ │
│ │ descriptiveLabels <labels>                                 │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ startTime <8b>                                             │ │
│ └────────────────────────────────────────────────────────────┘ │
│                        . . .                                   │
└────────────────────────────────────────────────────────────────┘
```

### 6.3 Series Record

```
┌────────────────────────────────────────────────────────────────┐
│ type = 1 <1b>                                                  │
├────────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ seriesRef <8b>                                             │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ n = len(metricLabels) <uvarint>                            │ │
│ │ metricLabels <labels>                                      │ │
│ └────────────────────────────────────────────────────────────┘ │
│                        . . .                                   │
└────────────────────────────────────────────────────────────────┘
```

### 6.4 Stream Record

```
┌────────────────────────────────────────────────────────────────┐
│ type = 22 <1b>                                                 │
├────────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ seriesRef <8b>                                             │ │
│ │ streamIndex <uvarint>                                      │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ n = len(entityRefs) <uvarint>                              │ │
│ │ entityRef_0 <8b>                                           │ │
│ │ ...                                                        │ │
│ │ entityRef_n <8b>                                           │ │
│ └────────────────────────────────────────────────────────────┘ │
│                        . . .                                   │
└────────────────────────────────────────────────────────────────┘
```

### 6.5 Stream Samples Record

```
┌────────────────────────────────────────────────────────────────┐
│ type = 23 <1b>                                                 │
├────────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ seriesRef <8b>                                             │ │
│ │ streamIndex <uvarint>                                      │ │
│ │ baseTimestamp <8b>                                         │ │
│ ├────────────────────────────────────────────────────────────┤ │
│ │ timestamp_delta <varint>                                   │ │
│ │ value <8b>                                                 │ │
│ │ ...                                                        │ │
│ └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

---

## Part 7: Block Format

### 7.1 Block Directory Structure

```
<block_ulid>/
├── meta.json
├── index
├── chunks/
│   ├── 000001
│   ├── 000002
│   └── ...
├── entities/          # NEW: Entity storage
│   ├── index          # Entity index
│   └── snapshots/     # Descriptive label snapshots
│       ├── 000001
│       └── ...
└── tombstones
```

### 7.2 Modified Series Index Format

```
Series Entry:
┌──────────────────────────────────────────────────────────────────────────┐
│ len <uvarint>                                                            │
├──────────────────────────────────────────────────────────────────────────┤
│ labels count <uvarint64>                                                 │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ ref(metric_label_name) <uvarint32>                                   │ │
│ │ ref(metric_label_value) <uvarint32>                                  │ │
│ │ ...                                                                  │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────┤
│ streams count <uvarint64>                                                │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ Stream 0:                                                            │ │
│ │   entity_refs count <uvarint>                                        │ │
│ │   entityRef_0 <8b>                                                   │ │
│ │   ...                                                                │ │
│ │   chunks count <uvarint64>                                           │ │
│ │   chunk entries...                                                   │ │
│ ├──────────────────────────────────────────────────────────────────────┤ │
│ │ Stream 1:                                                            │ │
│ │   ...                                                                │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────┤
│ CRC32 <4b>                                                               │
└──────────────────────────────────────────────────────────────────────────┘
```

### 7.3 Entity Index Format

```
┌────────────────────────────┬─────────────────────┐
│ magic(0xENT1D700) <4b>     │ version(1) <1 byte> │
├────────────────────────────┴─────────────────────┤
│ ┌──────────────────────────────────────────────┐ │
│ │              Symbol Table                    │ │
│ ├──────────────────────────────────────────────┤ │
│ │              Entity Types                    │ │
│ ├──────────────────────────────────────────────┤ │
│ │              Entities                        │ │
│ ├──────────────────────────────────────────────┤ │
│ │         Entity Label Postings                │ │
│ ├──────────────────────────────────────────────┤ │
│ │         Postings Offset Table                │ │
│ ├──────────────────────────────────────────────┤ │
│ │                   TOC                        │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘

Entity Entry:
┌──────────────────────────────────────────────────────────────────────────┐
│ entityRef <8b>                                                           │
├──────────────────────────────────────────────────────────────────────────┤
│ ref(entityType) <uvarint32>                                              │
├──────────────────────────────────────────────────────────────────────────┤
│ identifyingLabels count <uvarint>                                        │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ ref(label_name) <uvarint32>                                          │ │
│ │ ref(label_value) <uvarint32>                                         │ │
│ │ ...                                                                  │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────┤
│ startTime <varint64>                                                     │
│ endTime <varint64>  (0 if still alive at block max time)                 │
├──────────────────────────────────────────────────────────────────────────┤
│ snapshot_file_ref <uvarint64>  (reference to descriptive snapshots)      │
├──────────────────────────────────────────────────────────────────────────┤
│ CRC32 <4b>                                                               │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Part 8: Query Execution

### 8.1 Query Result Model

```go
// A query result is now a series with potentially multiple streams
type SeriesResult struct {
    Labels  labels.Labels    // Metric labels
    Streams []StreamResult   // One per entity combination
}

type StreamResult struct {
    EntityRefs []EntityRef    // Which entities this stream is from
    Samples    []Sample       // The actual samples
    
    // Resolved entity labels (computed at query time)
    entityLabels labels.Labels
}
```

### 8.2 Entity Label Resolution

```go
func (q *querier) resolveEntityLabels(
    entityRefs []EntityRef,
    timestamp int64,
) labels.Labels {
    builder := labels.NewBuilder(nil)
    
    for _, ref := range entityRefs {
        entity := q.entities.GetByRef(ref)
        if entity == nil {
            continue
        }
        
        // Add identifying labels
        entity.identifyingLabels.Range(func(l labels.Label) {
            builder.Set(l.Name, l.Value)
        })
        
        // Add descriptive labels at the given timestamp
        descriptive := entity.DescriptiveLabelsAt(timestamp)
        descriptive.Range(func(l labels.Label) {
            builder.Set(l.Name, l.Value)
        })
    }
    
    return builder.Labels()
}
```

### 8.3 PromQL Integration

```go
// When PromQL asks for a vector at time T:
func (q *querier) Select(ctx context.Context, matchers ...*labels.Matcher) storage.SeriesSet {
    metricMatchers, entityMatchers := splitMatchers(matchers)
    
    // Find matching series by metric labels
    seriesRefs := q.metricPostings.PostingsForMatchers(ctx, metricMatchers...)
    
    // Build result set
    var results []storage.Series
    
    for seriesRefs.Next() {
        series := q.series.GetByRef(seriesRefs.At())
        
        for streamIdx, stream := range series.streams {
            // Check if stream's entities match entity matchers
            if len(entityMatchers) > 0 {
                entityLabels := q.resolveEntityLabels(stream.entityRefs, q.maxTime)
                if !matchAll(entityLabels, entityMatchers) {
                    continue
                }
            }
            
            // Create a "virtual series" for this stream
            results = append(results, &virtualSeries{
                metricLabels: series.labels,
                entityRefs:   stream.entityRefs,
                chunks:       stream.chunks,
                querier:      q,
            })
        }
    }
    
    return newSeriesSet(results)
}

// virtualSeries represents a single stream as a series
type virtualSeries struct {
    metricLabels labels.Labels
    entityRefs   []EntityRef
    chunks       []chunks.Meta
    querier      *querier
}

func (s *virtualSeries) Labels() labels.Labels {
    // Merge metric labels with entity labels
    builder := labels.NewBuilder(s.metricLabels)
    
    entityLabels := s.querier.resolveEntityLabels(s.entityRefs, s.querier.maxTime)
    entityLabels.Range(func(l labels.Label) {
        builder.Set(l.Name, l.Value)
    })
    
    return builder.Labels()
}
```

---

## Part 9: Migration and Compatibility

### 9.1 Feature Flag

```yaml
# prometheus.yml
storage:
  tsdb:
    entity_native_storage: true  # Enable new storage model
```

### 9.2 Backward Compatibility Mode

When `entity_native_storage: false` (default):
- Behave exactly like current Prometheus
- All labels treated as metric labels
- Single stream per series

When `entity_native_storage: true`:
- Entity labels are separated based on configuration/conventions
- Multiple streams per series possible
- Entity storage enabled

### 9.3 Migration Strategy

1. **Phase 1: Dual Write**
   - New data written in new format
   - Old blocks remain readable
   - Query merges old and new formats

2. **Phase 2: Background Conversion**
   - Old blocks gradually converted during compaction
   - No service interruption

3. **Phase 3: Full Migration**
   - All data in new format
   - Old format support can be deprecated

---

## Part 10: Trade-offs and Considerations

### Benefits

| Aspect | Improvement |
|--------|-------------|
| **Cardinality** | Series count = metric × metric_label_values (not × entities) |
| **Entity Changes** | Pod restart = new stream, not new series |
| **Storage Efficiency** | Entity labels stored once, not per-series |
| **Query Flexibility** | Natural entity-aware queries |
| **OTel Alignment** | Matches OTLP's resource/metric model |

### Challenges

| Aspect | Challenge | Mitigation |
|--------|-----------|------------|
| **Complexity** | Significant codebase changes | Phased rollout, feature flags |
| **Query Performance** | Entity label resolution overhead | Caching, pre-computation |
| **Index Size** | Additional entity postings | Efficient encoding, memory mapping |
| **Compatibility** | Breaking change for remote write | Version negotiation, adapters |

### Open Questions

1. **Stream Identity**: Should stream identity be based on sorted entity refs or preserve order?

2. **Staleness**: Per-stream staleness vs per-series staleness?

3. **Remote Write**: How to encode streams in the remote write protocol?

4. **Recording Rules**: How do recording rule results handle entity association?

5. **Exemplars**: Should exemplars be per-stream or per-series?

---
