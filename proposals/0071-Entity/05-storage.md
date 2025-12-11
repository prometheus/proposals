# Entity Storage

> **Recommended Approach**: This document describes the correlation-based storage design, which we recommend for initial implementation due to its incremental nature and backward compatibility. An alternative design that fundamentally changes how series identity works is described in [05b-storage-entity-native.md](05b-storage-entity-native.md).

## Abstract

This document specifies how Prometheus stores entities reliably and efficiently. Entities represent the things that produce telemetry (pods, nodes, services) and need different storage semantics than traditional time series: they have immutable identifying labels, mutable descriptive labels that change over time, and lifecycle boundaries (creation and deletion). This document covers the in-memory structures, Write-Ahead Log integration, block persistence, and the correlation index that links entities to their associated metrics.

## Background

### Current Prometheus Storage Architecture

Prometheus uses a time series database (TSDB) optimized for append-heavy workloads with the following key components:

**Head Block**: The in-memory component that stores the most recent data. New samples are appended here first. The Head contains:
- `memSeries`: In-memory representation of each time series, holding recent samples in chunks
- `stripeSeries`: A sharded map for concurrent access to series by ID or label hash
- `MemPostings`: An inverted index mapping label name/value pairs to series references

**Write-Ahead Log (WAL)**: Ensures durability by writing all incoming data to disk before acknowledging. On crash recovery, the WAL is replayed to reconstruct the Head. WAL records include:
- Series records (new series with their labels)
- Sample records (timestamp + value for a series)
- Metadata records (type, unit, help for metrics)
- Exemplar and histogram records

**Persistent Blocks**: Periodically, the Head is compacted into immutable blocks stored on disk. Each block contains:
- Chunk files (compressed time series data)
- Index file (label index, postings lists, series metadata)
- Meta file (time range, stats)

**Appender Interface**: The primary interface for writing data to storage:

```go
type Appender interface {
    Append(ref SeriesRef, l labels.Labels, t int64, v float64) (SeriesRef, error)
    Commit() error
    Rollback() error
    // ... other methods for histograms, exemplars, metadata
}
```

The scrape loop uses Appender to write scraped metrics. Each scrape creates an Appender, appends all samples, then calls Commit() to atomically persist everything to the WAL.

### Why Entities Need Different Storage

Entities differ from time series in fundamental ways:

| Aspect | Time Series | Entities |
|--------|-------------|----------|
| Identity | Labels (all mutable in theory) | Identifying labels (immutable) |
| Values | Numeric samples over time | String labels (descriptive) |
| Cardinality | High (many series per entity) | Lower (one entity, many series) |
| Lifecycle | Implicit (staleness) | Explicit (start/end timestamps) |
| Correlation | Self-contained | Links to multiple series |

These differences motivate a dedicated storage approach rather than trying to fit entities into the existing series model.

## Entity Data Model

### The memEntity Structure

Each entity in memory is represented by the following structure:

```go
type memEntity struct {
    // Immutable after creation - no lock needed for these fields
    ref              EntityRef      // Unique identifier (uint64, auto-incrementing)
    entityType       string         // e.g., "k8s.pod", "service", "k8s.node"
    identifyingLabels labels.Labels // Immutable labels that define identity
    
    // Lifecycle timestamps
    startTime     int64          // When this entity incarnation was created
    endTime       int64          // When deleted (0 if still alive)
    
    // Mutable - requires lock
    sync.Mutex
    descriptiveSnapshots []labelSnapshot // Historical descriptive labels
    lastSeen      int64          // Last scrape timestamp (for staleness checking)
}

type labelSnapshot struct {
    timestamp int64
    labels    labels.Labels
}
```

### Identifying vs Descriptive Labels

**Identifying Labels** define what an entity *is*. They are immutable for the lifetime of an entity incarnation:

```
Entity Type: k8s.pod
Identifying Labels:
  - k8s.namespace.name = "production"
  - k8s.pod.uid = "550e8400-e29b-41d4-a716-446655440000"
```

Two entities with the same identifying labels are considered the same entity (within their lifecycle bounds).

**Descriptive Labels** provide additional context that may change over time:

```
Descriptive Labels (at t1):
  - k8s.pod.name = "nginx-7b9f5"
  - k8s.node.name = "worker-1"
  - k8s.pod.status = "Running"

Descriptive Labels (at t2, pod migrated):
  - k8s.pod.name = "nginx-7b9f5"
  - k8s.node.name = "worker-2"      ← changed
  - k8s.pod.status = "Running"
```

### Snapshot Storage for Descriptive Labels

Descriptive labels are stored as complete snapshots at each change point. When new descriptive labels arrive:

1. Compare with the most recent snapshot
2. If different, append a new snapshot with current timestamp
3. If identical, update `lastSeen` but don't create new snapshot

```
descriptiveSnapshots: [
    { t1, {name="nginx-7b9f5", node="worker-1", status="Running"} },
    { t5, {name="nginx-7b9f5", node="worker-2", status="Running"} },  // node changed
    { t9, {name="nginx-7b9f5", node="worker-2", status="Terminating"} },  // status changed
]
```

**Why snapshots instead of an event log?**

An event log (storing only deltas) would save storage space but impose query-time costs. To answer "what were the descriptive labels at time T?", a query would need to:
1. Find all change events before T
2. Replay them to reconstruct the state

With snapshots, the query simply finds the latest snapshot where `snapshot.timestamp <= T`.

### Entity Lifecycle

Each entity has explicit lifecycle boundaries:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Entity Lifecycle                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  startTime                                              endTime     │
│      │                                                      │       │
│      ▼                                                      ▼       │
│      ┌──────────────────────────────────────────────────────┐       │
│      │              Entity is "alive"                       │       │
│      │  - Correlates with metrics in this time range        │       │
│      │  - Descriptive labels tracked                        │       │
│      └──────────────────────────────────────────────────────┘       │
│                                                                     │
│  Before startTime: Entity doesn't exist                             │
│  After endTime: Entity is "dead" (historical only)                  │
│  endTime == 0: Entity is currently alive                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Entity Staleness**

An entity's `endTime` is determined by staleness, similar to series staleness:
- Each scrape updates `lastSeen` timestamp
- If `now - lastSeen > staleness_threshold`, entity is marked dead
- `endTime` is set to `lastSeen + staleness_threshold`

**Entity Reincarnation**

The same identifying labels can appear again after an entity ends:

```
Timeline:
  t1:  Entity A created  (ref=1, identifying={pod.uid="abc"}, startTime=t1)
  t5:  Entity A deleted  (ref=1, endTime=t5)
  t10: Entity B created  (ref=2, identifying={pod.uid="abc"}, startTime=t10)
```

Entity A and Entity B have the same identifying labels but different EntityRefs and non-overlapping lifecycles. At any point in time, at most one entity with a given set of identifying labels should be alive.

## Storage Components

### In-Memory Structures

#### Entity Storage in Head

The Head block is extended with entity storage:

```go
type Head struct {
    // ... existing fields ...
    
    // Entity storage
    entities       *stripeEntities       // All entities by ref or identifying attrs hash
    entityPostings *EntityMemPostings    // Inverted index for entity labels
    
    // Correlation index
    seriesToEntities map[HeadSeriesRef][]EntityRef
    entitiesToSeries map[EntityRef][]HeadSeriesRef
    correlationMtx   sync.RWMutex
    
    lastEntityID     atomic.Uint64        // For generating EntityRefs
}
```

#### stripeEntities

Similar to `stripeSeries`, provides sharded concurrent access to entities:

```go
type stripeEntities struct {
    size   int
    series []map[EntityRef]*memEntity
    hashes []map[uint64][]*memEntity  // hash(identifyingAttrs) -> entities
    locks  []sync.RWMutex
}

// Get entity by ref
func (s *stripeEntities) getByRef(ref EntityRef) *memEntity

// Get entity by identifying labels (may return multiple for historical)
func (s *stripeEntities) getByIdentifyingLabels(hash uint64, lbls labels.Labels) []*memEntity

func (s *stripeEntities) getAliveByIdentifyingLabels(hash uint64, lbls labels.Labels) *memEntity
```

#### EntityMemPostings

An inverted index mapping label name/value pairs to entity references:

```go
type EntityMemPostings struct {
    mtx sync.RWMutex
    m   map[string]map[string][]EntityRef  // label name -> label value -> entity refs
}

// Example contents:
// "k8s.namespace.name" -> "production" -> [EntityRef(1), EntityRef(5), EntityRef(12)]
// "k8s.node.name" -> "worker-1" -> [EntityRef(1), EntityRef(3)]
```

This enables efficient lookups like "find all entities in namespace X" or "find all entities on node Y".

#### Correlation Index

The correlation index maintains the many-to-many relationship between series and entities:

```go
// Series -> Entities: "which entities does this series correlate with?"
seriesToEntities map[HeadSeriesRef][]EntityRef

// Entities -> Series: "which series are associated with this entity?"
entitiesToSeries map[EntityRef][]HeadSeriesRef
```

**Building the correlation at ingestion time:**

When a new series is created:
```
series.labels = {__name__="container_cpu", k8s.namespace.name="prod", k8s.pod.uid="abc", k8s.node.uid="xyz"}

For each registered entity type:
  k8s.pod: requires {k8s.namespace.name, k8s.pod.uid}
    → series has both → find entity with these identifying attrs
    → if found and alive: add to correlation index
    
  k8s.node: requires {k8s.node.uid}
    → series has this → find entity with this identifying attr
    → if found and alive: add to correlation index

Result: seriesToEntities[series.ref] = [podEntityRef, nodeEntityRef]
```

When a new entity is created:
```
entity.identifyingAttrs = {k8s.namespace.name="prod", k8s.pod.uid="abc"}

Find all series whose labels contain ALL of entity's identifying attrs:
  → Use postings index: intersect(postings["k8s.namespace.name"]["prod"], 
                                  postings["k8s.pod.uid"]["abc"])
  → For each matching series: add to correlation index
```

**Correlation and Entity Lifecycle**

When an entity becomes stale (endTime set), it remains in the correlation index. This preserves historical correlations for queries over past time ranges. The query layer filters based on timestamp overlap between the query range and entity lifecycle.

### Write-Ahead Log

#### New WAL Record Type

A single new record type captures all entity state:

```go
const (
    // ... existing types ...
    Entity Type = 11  // Entity record
)

type RefEntity struct {
    Ref               EntityRef
    EntityType        string
    IdentifyingLabels []labels.Label
    DescriptiveLabels []labels.Label
    StartTime         int64
    EndTime           int64  // 0 if alive
    Timestamp         int64  // When this record was written
}
```

#### Record Encoding

Entity records follow the same encoding pattern as other WAL records:

```
┌───────────┬──────────┬────────────┬──────────────┐
│ type <1b> │ len <2b> │ CRC32 <4b> │ data <bytes> │
└───────────┴──────────┴────────────┴──────────────┘
```

The data section for an Entity record:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Entity Record Data                                                  │
├─────────────────────────────────────────────────────────────────────┤
│ ref <8b, big-endian>                                                │
│ entityType <uvarint len> <bytes>                                    │
│ numIdentifyingLabels <uvarint>                                      │
│   ┌─ name <uvarint len> <bytes>                                     │
│   └─ value <uvarint len> <bytes>                                    │
│   ... repeated for each identifying label                           │
│ numDescriptiveLabels <uvarint>                                      │
│   ┌─ name <uvarint len> <bytes>                                     │
│   └─ value <uvarint len> <bytes>                                    │
│   ... repeated for each descriptive label                           │
│ startTime <varint>                                                  │
│ endTime <varint>                                                    │
│ timestamp <varint>                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

#### When Entity Records Are Written

Entity records are written to WAL in these situations:

1. **New entity created**: Full record with startTime set, endTime=0
2. **Descriptive labels changed**: Full record with updated labels and new timestamp
3. **Entity marked dead**: Full record with endTime set

Writing full records (not deltas) simplifies replay and allows any single record to fully describe entity state at that point.

#### WAL Replay Behavior

On startup, entity records are replayed to reconstruct the Head's entity state:

```go
func (h *Head) replayEntityRecord(rec RefEntity) error {
    existing := h.entities.getByRef(rec.Ref)
    
    if existing == nil {
        // New entity - create it
        entity := &memEntity{
            ref:               rec.Ref,
            entityType:        rec.EntityType,
            identifyingLabels: rec.IdentifyingLabels,
            startTime:         rec.StartTime,
            endTime:           rec.EndTime,
        }
        if len(rec.DescriptiveLabels) > 0 {
            entity.descriptiveSnapshots = []labelSnapshot{
                {timestamp: rec.Timestamp, labels: rec.DescriptiveLabels},
            }
        }
        h.entities.set(entity)
    } else {
        // Update existing entity
        existing.Lock()
        existing.endTime = rec.EndTime
        if len(rec.DescriptiveLabels) > 0 {
            // Check if labels changed from last snapshot
            if shouldAddSnapshot(existing, rec.DescriptiveLabels) {
                existing.descriptiveSnapshots = append(
                    existing.descriptiveSnapshots,
                    labelSnapshot{timestamp: rec.Timestamp, labels: rec.DescriptiveLabels},
                )
            }
        }
        existing.Unlock()
    }
    
    // Update lastEntityID if needed
    if uint64(rec.Ref) > h.lastEntityID.Load() {
        h.lastEntityID.Store(uint64(rec.Ref))
    }
    
    return nil
}
```

The correlation index is rebuilt after all WAL records are replayed, by iterating all entities and series and computing correlations.

### Block Persistence

When the Head is compacted into a persistent block, entities must also be persisted.

#### Entity Index in Blocks

Each block includes an entity index alongside the existing series index:

```
Block Directory Structure:
  block-ulid/
    ├── chunks/           # Chunk files (existing)
    ├── index             # Series index (existing)
    ├── entities          # Entity index (new)
    ├── meta.json         # Block metadata (extended)
    └── tombstones        # Deletion markers (existing)
```

The entity index file structure:

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Entity Index File                              │
├─────────────────────────────────────────────────────────────────────┤
│ Magic Number (4 bytes)                                              │
│ Version (1 byte)                                                    │
├─────────────────────────────────────────────────────────────────────┤
│ Symbol Table                                                        │
│   - All unique strings (entity types, attr names, attr values)      │
├─────────────────────────────────────────────────────────────────────┤
│ Entity Table                                                        │
│   For each entity:                                                  │
│   - EntityRef                                                       │
│   - EntityType (symbol ref)                                         │
│   - IdentifyingLabels (symbol ref pairs)                            │
│   - StartTime, EndTime                                              │
│   - DescriptiveSnapshots offset (pointer to snapshots section)      │
├─────────────────────────────────────────────────────────────────────┤
│ Descriptive Snapshots Section                                       │
│   For each entity's snapshots:                                      │
│   - Number of snapshots                                             │
│   - For each snapshot: timestamp, labels (symbol ref pairs)         │
├─────────────────────────────────────────────────────────────────────┤
│ Entity Postings                                                     │
│   - Inverted index: (label_name, label_value) -> [EntityRefs]       │
├─────────────────────────────────────────────────────────────────────┤
│ Table of Contents                                                   │
│ CRC32                                                               │
└─────────────────────────────────────────────────────────────────────┘
```

#### Compaction Behavior

During compaction:

1. **Entity Selection**: Include entities whose lifecycle overlaps with the block's time range
   ```
   Include entity if: entity.startTime < block.maxTime AND 
                      (entity.endTime == 0 OR entity.endTime > block.minTime)
   ```

2. **Snapshot Filtering**: Only include descriptive snapshots within the block's time range

3. **Deduplication**: If compacting multiple blocks, entities with the same EntityRef are merged, keeping all unique snapshots

#### Entity Retention

Entities follow the same retention policy as series data. Prometheus deletes blocks based on `RetentionDuration` (time-based) or `MaxBytes` (size-based). When blocks are deleted, entities are handled as follows:

**Retention Rule**: An entity persists as long as **any block overlapping its lifecycle** exists.

```
Block Timeline:
  Block 1        Block 2        Block 3        Block 4
  [t0, t1]       [t1, t2]       [t2, t3]       [t3, t4]

Entity A: ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
          startTime=t0    endTime=t1.5
          (lifecycle spans Block 1 and Block 2)

Entity B: ░░░░░░░░░░░░████████████████████████████████
          startTime=t1.2      endTime=0 (still alive)
          (lifecycle spans Block 2, Block 3, Block 4, Head)

When Block 1 and Block 2 are deleted due to retention:
- Entity A is deleted (no remaining blocks contain its lifecycle)
- Entity B persists (Block 3, Block 4, Head still overlap its lifecycle)
```

This ensures historical queries can always resolve entity correlations for the data that remains.

#### Head Entity Garbage Collection

The Head block periodically runs garbage collection to remove entities that are no longer needed in memory. This mirrors how series GC works in `Head.gc()`.

**GC Eligibility**: An entity in the Head is eligible for garbage collection when:
1. The entity is dead (`endTime != 0`), AND
2. The entity's entire lifecycle is before `Head.MinTime()` (fully compacted to blocks)

```go
func (h *Head) gcEntities() map[EntityRef]struct{} {
    mint := h.MinTime()
    deleted := make(map[EntityRef]struct{})
    
    h.entities.iter(func(entity *memEntity) {
        // Only consider dead entities
        if entity.endTime == 0 {
            return  // Still alive, keep in Head
        }
        
        // If the entity's entire lifecycle is before Head's minTime,
        // it has been fully compacted to blocks and can be removed
        if entity.endTime < mint {
            deleted[entity.ref] = struct{}{}
        }
    })
    
    // Remove from entity storage
    for ref := range deleted {
        entity := h.entities.getByRef(ref)
        h.entities.delete(ref)
        h.entityPostings.Delete(ref, entity.identifyingLabels)
    }
    
    // Clean up correlation index
    h.correlationMtx.Lock()
    for ref := range deleted {
        // Remove entity from all series correlations
        for _, seriesRef := range h.entitiesToSeries[ref] {
            h.seriesToEntities[seriesRef] = removeEntityRef(
                h.seriesToEntities[seriesRef], ref)
        }
        delete(h.entitiesToSeries, ref)
    }
    h.correlationMtx.Unlock()
    
    return deleted
}
```

**Integration with Head.gc()**: Entity GC runs alongside series GC during `truncateMemory()`:

```go
func (h *Head) truncateSeriesAndChunkDiskMapper(caller string) error {
    // ... existing series GC ...
    actualInOrderMint, minOOOTime, minMmapFile := h.gc()
    
    // Entity GC
    deletedEntities := h.gcEntities()
    h.metrics.entitiesRemoved.Add(float64(len(deletedEntities)))
    
    // ... rest of truncation ...
}
```

## Ingestion Flow

### Extended Appender Interface

The Appender interface is extended to support entity ingestion:

```go
type Appender interface {
    // ... existing methods ...
    
    // AppendEntity adds or updates an entity.
    // Returns the EntityRef (existing or newly assigned).
    AppendEntity(
        entityType string,
        identifyingAttrs labels.Labels,
        descriptiveAttrs labels.Labels,
        timestamp int64,
    ) (EntityRef, error)
}
```

### headAppender Implementation

```go
func (a *headAppender) AppendEntity(
    entityType string,
    identifyingAttrs labels.Labels,
    descriptiveAttrs labels.Labels,
    timestamp int64,
) (EntityRef, error) {
    
    // Validate inputs
    if entityType == "" {
        return 0, fmt.Errorf("entity type cannot be empty")
    }
    if len(identifyingLabels) == 0 {
        return 0, fmt.Errorf("identifying labels cannot be empty")
    }
    
    // Sort labels for consistent hashing
    sort.Sort(identifyingLabels)
    sort.Sort(descriptiveLabels)
    
    hash := identifyingLabels.Hash()
    
    // Check for existing alive entity
    entity := a.head.entities.getAliveByIdentifyingLabels(hash, identifyingLabels)
    
    if entity == nil {
        // Create new entity
        ref := EntityRef(a.head.lastEntityID.Inc())
        entity = &memEntity{
            ref:               ref,
            entityType:        entityType,
            identifyingLabels: identifyingLabels,
            startTime:         timestamp,
            endTime:           0,
            lastSeen:          timestamp,
        }
        
        if len(descriptiveLabels) > 0 {
            entity.descriptiveSnapshots = []labelSnapshot{
                {timestamp: timestamp, labels: descriptiveLabels},
            }
        }
        
        // Stage for commit
        a.pendingEntities = append(a.pendingEntities, entity)
        a.pendingEntityRecords = append(a.pendingEntityRecords, RefEntity{
            Ref:               ref,
            EntityType:        entityType,
            IdentifyingLabels: identifyingLabels,
            DescriptiveLabels: descriptiveLabels,
            StartTime:         timestamp,
            EndTime:           0,
            Timestamp:         timestamp,
        })
        
        return ref, nil
    }
    
    // Update existing entity
    entity.Lock()
    entity.lastSeen = timestamp
    
    // Check if descriptive labels changed
    needsSnapshot := false
    if len(entity.descriptiveSnapshots) == 0 {
        needsSnapshot = len(descriptiveLabels) > 0
    } else {
        lastSnapshot := entity.descriptiveSnapshots[len(entity.descriptiveSnapshots)-1]
        needsSnapshot = !labels.Equal(lastSnapshot.labels, descriptiveLabels)
    }
    
    if needsSnapshot {
        entity.descriptiveSnapshots = append(entity.descriptiveSnapshots, labelSnapshot{
            timestamp: timestamp,
            labels:    descriptiveLabels,
        })
        
        // Stage WAL record for changed labels
        a.pendingEntityRecords = append(a.pendingEntityRecords, RefEntity{
            Ref:               entity.ref,
            EntityType:        entity.entityType,
            IdentifyingLabels: entity.identifyingLabels,
            DescriptiveLabels: descriptiveLabels,
            StartTime:         entity.startTime,
            EndTime:           0,
            Timestamp:         timestamp,
        })
    }
    
    entity.Unlock()
    return entity.ref, nil
}
```

### Commit and Rollback

**Commit** persists all pending entities to WAL and updates indexes:

```go
func (a *headAppender) Commit() error {
    // ... existing commit logic for samples ...
    
    // Write entity records to WAL
    if len(a.pendingEntityRecords) > 0 {
        if err := a.logEntities(); err != nil {
            return err
        }
    }
    
    // Add new entities to Head
    for _, entity := range a.pendingEntities {
        a.head.entities.set(entity)
        a.head.entityPostings.Add(entity.ref, entity.identifyingLabels)
        
        // Build correlations with existing series
        a.head.buildEntityCorrelations(entity)
    }
    
    // Clear pending state
    a.pendingEntities = a.pendingEntities[:0]
    a.pendingEntityRecords = a.pendingEntityRecords[:0]
    
    return nil
}
```

**Rollback** discards all pending changes:

```go
func (a *headAppender) Rollback() error {
    // ... existing rollback logic ...
    
    // Simply discard pending entities - they were never added to Head
    a.pendingEntities = a.pendingEntities[:0]
    a.pendingEntityRecords = a.pendingEntityRecords[:0]
    
    return nil
}
```

### Correlation Index Updates

When building correlations for a new entity:

```go
func (h *Head) buildEntityCorrelations(entity *memEntity) {
    // Find all series that have ALL of the entity's identifying labels
    var postingsLists []Postings
    
    entity.identifyingLabels.Range(func(l labels.Label) {
        postingsLists = append(postingsLists, h.postings.Get(l.Name, l.Value))
    })
    
    // Intersect all postings lists
    intersection := Intersect(postingsLists...)
    
    h.correlationMtx.Lock()
    defer h.correlationMtx.Unlock()
    
    for intersection.Next() {
        seriesRef := intersection.At()
        
        // Add bidirectional correlation
        h.seriesToEntities[seriesRef] = append(h.seriesToEntities[seriesRef], entity.ref)
        h.entitiesToSeries[entity.ref] = append(h.entitiesToSeries[entity.ref], seriesRef)
    }
}
```

When a new series is created, correlations are built similarly by finding all alive entities whose identifying labels are a subset of the series labels.

## Query Support

This section provides an overview of how storage exposes entities for queries. Detailed query semantics are covered in the Querying document.

### Storage Query Interface

```go
type EntityQuerier interface {
    // Get entity by ref
    Entity(ref EntityRef) (*Entity, error)
    
    // Find entities by type and/or labels
    Entities(ctx context.Context, entityType string, matchers ...*labels.Matcher) (EntitySet, error)
    
    // Get entities correlated with a series at a specific time
    EntitiesForSeries(seriesRef SeriesRef, timestamp int64) ([]EntityRef, error)
    
    // Get series correlated with an entity
    SeriesForEntity(entityRef EntityRef) ([]SeriesRef, error)
    
    // Get descriptive labels at a point in time
    DescriptiveLabelsAt(entityRef EntityRef, timestamp int64) (labels.Labels, error)
}
```

### Time-Range Filtering

Queries specify a time range `[mint, maxt]`. Entity results are filtered by lifecycle:

```go
func (e *memEntity) isAliveAt(t int64) bool {
    return e.startTime <= t && (e.endTime == 0 || e.endTime > t)
}

func (e *memEntity) overlapsRange(mint, maxt int64) bool {
    return e.startTime < maxt && (e.endTime == 0 || e.endTime > mint)
}
```

### Descriptive Label Lookup

To get descriptive labels at a specific timestamp:

```go
func (e *memEntity) descriptiveLabelsAt(t int64) labels.Labels {
    if !e.isAliveAt(t) {
        return labels.EmptyLabels()
    }
    
    snapshots := e.descriptiveSnapshots
    if len(snapshots) == 0 {
        return labels.EmptyLabels()
    }
    
    // Binary search: find the first snapshot where timestamp > t
    // Then the snapshot we want is at index i-1
    i := sort.Search(len(snapshots), func(i int) bool {
        return snapshots[i].timestamp > t
    })
    
    if i == 0 {
        // All snapshots are after time t
        return labels.EmptyLabels()
    }
    
    return snapshots[i-1].labels
}
```

## Remote Write Considerations

Entities need to be transmitted over Prometheus remote write protocol. This requires extending the protobuf definitions:

```protobuf
message EntityWriteRequest {
    repeated Entity entities = 1;
}

message Entity {
    string entity_type = 1;
    repeated Label identifying_labels = 2;
    repeated Label descriptive_labels = 3;
    int64 start_time_ms = 4;
    int64 end_time_ms = 5;  // 0 if alive
    int64 timestamp_ms = 6; // When this state was observed
}
```

Key considerations for remote write:

1. **Incremental Updates**: Only send entity records when state changes (new entity, attrs changed, entity died)
2. **Receiver Reconciliation**: Receivers must handle out-of-order entity records and merge appropriately
3. **Correlation Rebuild**: Receivers rebuild correlation indexes locally based on their series data

Detailed remote write protocol changes are specified in a separate document.

## Trade-offs and Design Decisions

### Separate Entity Storage vs Embedding in Series

**Decision**: Separate storage structure for entities

**Rationale**:
- Entities have different access patterns (lookup by identifying labels vs. time-range queries)
- Many-to-many relationship with series doesn't fit the one-to-one series model
- Entity lifecycle (explicit start/end) differs from series staleness
- Descriptive labels are string-valued, not numeric samples

**Trade-off**: Additional complexity in storage layer, but cleaner semantics and better query performance.

### Snapshots vs Event Log for Descriptive Labels

**Decision**: Store complete snapshots at each change point

**Rationale**:
- Point-in-time queries are common ("what was this pod's node at time T?")
- Snapshots enable O(log n) lookup via binary search
- Event log would require O(n) replay to reconstruct state
- Descriptive labels change infrequently, limiting snapshot count

**Trade-off**: Higher storage per change, but faster queries and simpler implementation.

### Correlation at Ingestion Time vs Query Time

**Decision**: Build correlation index at ingestion time

**Rationale**:
- Queries should be fast; correlation lookup is O(1) with pre-built index
- Ingestion can afford extra work; it's already doing label processing
- Correlation relationships are stable (based on immutable identifying labels)

**Trade-off**: Ingestion overhead for maintaining correlation index, but significantly faster queries.

### Single WAL Record Type vs Multiple

**Decision**: Single comprehensive entity record type

**Rationale**:
- Simplifies WAL encoding/decoding logic
- Any single record fully describes entity state (no partial records)
- Replay is straightforward—each record is self-contained
- Matches pattern used for series (full labels in each Series record)

**Trade-off**: Slightly larger WAL records, but simpler and more robust.

## Open Questions / Future Work

### Retention Alignment

How exactly should entity retention align with block retention?
- Current proposal: entities persist while any block containing their lifecycle exists
- May need refinement based on operational experience

### Memory Management

Long-running Prometheus instances may accumulate many historical entities:
- Consider memory-mapped entity storage for historical entities
- Investigate entity compaction/summarization for very old data

### Federation and Multi-Prometheus

When multiple Prometheus instances scrape the same entities:
- Entity deduplication across instances
- Consistent EntityRef assignment (or ref translation)
- Correlation index consistency

### Entity Type Registry

Should Prometheus maintain a registry of known entity types with their identifying label schemas?
- Would enable validation at ingestion time
- Could optimize correlation index building
- Trade-off: flexibility vs. consistency

---

## TODO: Memory and WAL Replay Performance

This section requires further investigation and benchmarking:

### Memory Concerns

- **Entity memory footprint estimation**: We need to quantify the memory cost per entity, including the `memEntity` struct, descriptive snapshots, and correlation index entries. This will help users estimate memory requirements based on expected entity counts.

- **Impact on existing memory settings**: How do entity storage requirements interact with `--storage.tsdb.head-chunks-*` and other memory-related flags? Should there be dedicated entity memory limits?

- **Memory-mapped entity storage**: For Prometheus instances with very long uptimes and high entity churn, historical entities may accumulate. Investigate whether memory-mapping historical entities (similar to mmapped chunks) could reduce memory pressure.

- **Correlation index memory scaling**: The bidirectional correlation maps (`seriesToEntities` and `entitiesToSeries`) could become large with high series and entity counts. Consider more memory-efficient data structures (e.g., roaring bitmaps) if benchmarks show this is a bottleneck.

### WAL Replay Performance

- **Correlation index rebuild time**: The current proposal rebuilds the correlation index after WAL replay by iterating all entities and series. For large Prometheus instances (millions of series, thousands of entities), this could significantly increase startup time.

- **Incremental correlation during replay**: Instead of rebuilding correlations after replay, could we store correlation state in the WAL or maintain it incrementally during replay? This would trade WAL size for faster startup.

- **Checkpointing correlation state**: Consider extending WAL checkpointing to include entity and correlation state, reducing the amount of replay needed on restart.

- **Benchmark targets**: We should establish performance targets (e.g., "WAL replay should not increase by more than 10% with 10,000 entities") and validate them through benchmarks.

These topics need benchmarking with realistic workloads before finalizing the implementation approach.

---

## TODO: Columnar Storage Strategies

This section outlines potential optimizations for entity label storage that warrant further exploration:

### Background

Descriptive labels are fundamentally different from time series samples:
- They are **string-valued**, not numeric
- They change **infrequently** (entity metadata doesn't update every scrape)
- They are often **queried together** (users typically want all labels of an entity, not just one)
- They benefit from **compression** due to repetitive patterns (many pods have similar labels)

These characteristics suggest that columnar storage techniques, commonly used in analytical databases, might offer significant benefits.

### Areas to Explore

- **Column-oriented label storage**: Instead of storing all labels for a snapshot together (row-oriented), store each label name as a column with its values across entities. This could improve compression and enable efficient filtering by specific labels.

- **Dictionary encoding**: Entity labels often have low cardinality (e.g., `k8s.pod.status.phase` has only a few possible values). Dictionary encoding could dramatically reduce storage for descriptive labels.

- **Run-length encoding for temporal data**: When descriptive labels don't change across many snapshots, run-length encoding could eliminate redundant storage.

- **Label projection pushdown**: When queries only need specific entity labels (e.g., `sum by (k8s.node.name)`), the storage layer could avoid reading unnecessary labels.

- **Separate label storage files**: Similar to how chunks are stored separately from the index, entity labels could have dedicated storage with format optimized for their access patterns.

### Trade-offs to Consider

- Implementation complexity vs. storage/query benefits
- Read vs. write optimization (columnar is typically better for reads)
- Memory overhead of maintaining multiple storage formats
- Compatibility with existing TSDB compaction and retention logic

This is a potential future optimization and not required for the initial implementation.

---

## What's Next

- [Querying](05-querying.md): How PromQL is extended to query entities and correlations
- [Web UI and APIs](06-web-ui-and-apis.md): HTTP API endpoints and UI for entity exploration

