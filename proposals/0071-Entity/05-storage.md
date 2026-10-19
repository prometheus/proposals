# Entity Storage

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
    // Immutable after creation
    ref              EntityRef      // Unique identifier (uint64, auto-incrementing)
    entityType       string         // e.g., "k8s.pod", "service", "k8s.node"
    identifyingLabels labels.Labels // Immutable labels that define identity
    
    // Lifecycle timestamps
    startTime     int64          // When this entity incarnation was created
    endTime       int64          // When deleted (0 if still alive)
    
    // Mutable
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

The Head block is extended with:

| Component | Purpose |
|-----------|---------|
| **Entity storage** | Sharded map (like `stripeSeries`) storing `memEntity` by ref or identifying labels hash |
| **Entity postings** | Inverted index mapping `(label_name, label_value)` → entity refs |
| **Correlation index** | Bidirectional maps: `series_ref ↔ entity_refs` |

The entity storage and postings follow the same sharding patterns as the existing series storage to support concurrent access.

#### Correlation Index

The correlation index maintains the many-to-many relationship between series and entities as two bidirectional maps:
- **Series → Entities**: "which entities does this series correlate with?"
- **Entities → Series**: "which series are associated with this entity?"

**Building correlations at ingestion time:**

When a **new series** is created, Prometheus checks each registered entity type. If the series labels contain all of an entity type's identifying labels, it looks up the corresponding entity and adds the correlation.

When a **new entity** is created, Prometheus uses the postings index to find all series whose labels contain all of the entity's identifying labels, then adds correlations for each match.

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

### AppendEntity Behavior

When `AppendEntity` is called:

1. **Validate** — Entity type and identifying labels must be non-empty
2. **Lookup** — Search for an existing alive entity with the same identifying labels
3. **If not found** — Create a new entity with a fresh EntityRef, set `startTime` to now, stage for WAL write
4. **If found** — Update `lastSeen` timestamp; if descriptive labels changed, append a new snapshot and stage a WAL record

New entities and WAL records are staged (not committed) until `Commit()` is called, following the same transactional pattern as sample appends.

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
- **isAliveAt(t)**: True if `startTime <= t` and (`endTime == 0` or `endTime > t`)
- **overlapsRange(mint, maxt)**: True if the entity's lifecycle overlaps the query range

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

## What's Next

- [Querying](06-querying.md): How PromQL is extended to query entities and correlations
- [Web UI and APIs](07-web-ui-and-apis.md): HTTP API endpoints and UI for entity exploration

