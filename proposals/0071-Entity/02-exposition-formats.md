# Exposition Formats

## Abstract

This document specifies how Prometheus exposition formats represent **Entities** using info metrics. As established in [01-context.md](./01-context.md), Entities are the first-class concept representing things that produce telemetry. This document defines how they are serialized in the wire format.

Info metrics have long been used to represent entity metadata in the Prometheus ecosystem. This proposal enhances them with markers that allow Prometheus to recognize them as entity representations rather than ordinary metrics. The key addition is the `# IDENTIFYING_LABELS` declaration, which distinguishes which labels uniquely identify the entity from which labels describe it.

---

## Entities vs. Info Metrics: Concepts and Representation

Before diving into syntax, it's important to clarify the relationship between two terms used in this proposal:

### Entity (Concept)

An **Entity** is the conceptual abstraction—the "thing" that produces telemetry:
- A Kubernetes pod
- A physical host
- A service instance
- A database table

Entities have:
- **Type** (e.g., `k8s.pod`, `service`, `host`)
- **Identifying labels** (immutable, define unique identity)
- **Descriptive labels** (mutable, provide context)
- **Lifecycle** (creation time, end time)

### Info Metric (Wire Format)

An **info metric** is how entities are represented in the exposition format:
- Uses the familiar `*_info` naming convention
- Declares `# TYPE ... info`
- Now includes `# IDENTIFYING_LABELS` to mark which labels are identifying
- Has a placeholder value of `1`

Throughout this proposal:
- When we say **"Entity,"** we mean the conceptual abstraction
- When we say **"info metric,"** we mean the wire format representation
- The two are closely related: info metrics *represent* entities

---

## Text Format

### New Syntax Elements

| Element | Syntax | Description |
|---------|--------|-------------|
| Identifying labels declaration | `# IDENTIFYING_LABELS <label1> <label2> ...` | Declares which labels uniquely identify the info metric instance |
| Info section delimiter | `---` | Marks the end of the info metrics section |

### Complete Example

```
# HELP kube_pod_info Information about pods
# TYPE kube_pod_info info
# IDENTIFYING_LABELS namespace pod_uid
kube_pod_info{namespace="default",pod_uid="550e8400-e29b-41d4-a716-446655440000",pod="nginx-7b9f5"} 1
kube_pod_info{namespace="default",pod_uid="660e8400-e29b-41d4-a716-446655440001",pod="redis-cache-0"} 1
kube_pod_info{namespace="kube-system",pod_uid="770e8400-e29b-41d4-a716-446655440002",pod="coredns-5dd5756b68-abcde"} 1

# HELP kube_node_info Information about nodes
# TYPE kube_node_info info
# IDENTIFYING_LABELS node_uid
kube_node_info{node_uid="node-uid-001",node="worker-1",os="linux",kernel_version="5.15.0"} 1
kube_node_info{node_uid="node-uid-002",node="worker-2",os="linux",kernel_version="5.15.0"} 1

# HELP target_info Target metadata from OpenTelemetry
# TYPE target_info info
# IDENTIFYING_LABELS job instance
target_info{job="payment-service",instance="10.0.1.5:8080",service_version="2.1.0",deployment_environment="production"} 1

---

# HELP container_cpu_usage_seconds_total Total CPU usage in seconds
# TYPE container_cpu_usage_seconds_total counter
container_cpu_usage_seconds_total{namespace="default",pod_uid="550e8400-e29b-41d4-a716-446655440000",node_uid="node-uid-001",container="nginx"} 1234.5
container_cpu_usage_seconds_total{namespace="default",pod_uid="660e8400-e29b-41d4-a716-446655440001",node_uid="node-uid-002",container="redis"} 567.8

# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{job="payment-service",instance="10.0.1.5:8080",method="GET",status="200"} 9999

# EOF
```

### Parsing Rules

1. `# TYPE ... info` MUST be followed by `# IDENTIFYING_LABELS` before any metric instances
2. `# IDENTIFYING_LABELS` applies to the info metric family declared by the preceding `# TYPE`
3. All labels listed in `# IDENTIFYING_LABELS` must be present on every instance of that info metric
4. Labels not listed in `# IDENTIFYING_LABELS` are considered descriptive labels
5. The info metrics section ends with a `---` delimiter on its own line
6. After the `---` delimiter, any info metric declarations are a parse error

### Ordering

**All info metrics MUST appear at the beginning of the scrape response, before any regular metrics.** The info metrics section ends with a `---` delimiter.

This ordering requirement exists for practical reasons: when Prometheus parses a metric, it needs to immediately correlate that metric with any relevant info metrics. If info metrics could appear anywhere in the response, Prometheus would need to either buffer all metrics until the entire response is parsed, or make a second pass through the data. Both approaches add complexity and memory overhead.

By requiring info metrics first, the parser can process the exposition in a single pass. When it encounters a regular metric, all potentially correlated info metrics are already in memory and correlation can happen immediately.

If no info metrics are present, the `---` delimiter may be omitted.

#### Breaking Change

**This ordering requirement is a breaking change.** Currently, Prometheus parses info metrics as regular gauges, allowing them to appear anywhere in the scrape response. Applications that expose info metrics after regular metrics will need to be updated to comply with this ordering requirement.

This trade-off was accepted because the benefits of single-pass parsing and immediate correlation outweigh the migration cost. See [99-alternatives.md](./99-alternatives.md#alternative-introduce-a-new-entity-concept) for an alternative approach that would not have this breaking change.

---

## Protobuf Format

While the text format uses info metrics to represent entities (for familiarity), the protobuf format uses a dedicated `EntityFamily` structure. This provides a cleaner representation without the need for placeholder values.

### New Message Definitions

```protobuf
syntax = "proto2";

package io.prometheus.client;

// EntityFamily groups entities of the same type
message EntityFamily {
  // Entity type name
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
  // Entity families (must come before metric families)
  repeated EntityFamily entity_family = 1;
  
  // Metric families
  repeated MetricFamily metric_family = 2;
}
```

### Content-Type

For protobuf with entity support:

```
application/vnd.google.protobuf;proto=io.prometheus.client.MetricPayload;encoding=delimited
```

The `proto` parameter changes from `MetricFamily` to `MetricPayload` to indicate the new top-level message type.

### Translation Between Formats

Entities can be losslessly translated between text and protobuf formats:

| Text Format | Protobuf |
|-------------|----------|
| `# TYPE kube_pod_info info` | `EntityFamily.type = "kube_pod"` |
| `# IDENTIFYING_LABELS namespace pod_uid` | `EntityFamily.identifying_label_names = ["namespace", "pod_uid"]` |
| `kube_pod_info{namespace="default",pod="nginx"} 1` | `Entity.label = [{name: "namespace", value: "default"}, {name: "pod", value: "nginx"}]` |

Note that the placeholder value `1` from the text format is not stored in protobuf—it's implicit for entities.

---

## Info Metric to Regular Metric Correlation

### How Correlation Works

Info metrics correlate with regular metrics through **shared identifying labels**:

- If a metric has labels that match ALL identifying labels of an info metric (same names, same values), that metric is associated with that info metric.
- A single metric can correlate with multiple info metrics if it contains the identifying labels of each.

**Example:**

```
# TYPE kube_pod_info info
# IDENTIFYING_LABELS namespace pod_uid
kube_pod_info{namespace="default",pod_uid="550e8400",pod="nginx",node="worker-1"} 1
---
# This metric correlates with kube_pod_info above (has both identifying labels)
container_cpu_usage_seconds_total{namespace="default",pod_uid="550e8400",container="app"} 1234.5
```

Correlation is computed at ingestion time when Prometheus parses the exposition format. See [05-storage.md](./05-storage.md#correlation-index) for how Prometheus builds and maintains these correlations in storage.

### Conflict Detection

When a metric correlates with an info metric, the query engine enriches the metric's labels with the info metric's descriptive labels (see [06-querying.md](./06-querying.md)). This creates the possibility of label conflicts.

A conflict occurs when:
- A metric correlates with an info metric (has all identifying labels)
- The metric has a label with the same name as one of the info metric's descriptive labels
- The values differ

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Label Conflict Detection                            │
└─────────────────────────────────────────────────────────────────────────────┘

Info Metric (kube_pod_info)                   Regular Metric (my_metric)
┌─────────────────────────────────┐           ┌─────────────────────────────────┐
│ Identifying Labels:             │           │ Labels:                         │
│   namespace = "default"         │◄─────────►│   namespace = "default"         │ ✓ Match
│   pod_uid = "abc-123"           │◄─────────►│   pod_uid = "abc-123"           │ ✓ Match
├─────────────────────────────────┤           ├─────────────────────────────────┤
│ Descriptive Labels:             │           │                                 │
│   version = "2.0"               │◄────╳────►│   version = "1.0"               │ ✗ CONFLICT!
│   pod = "nginx"                 │           │                                 │
└─────────────────────────────────┘           │ Value: 42                       │
                                              └─────────────────────────────────┘

Correlation established via matching identifying labels,
but "version" exists in both with different values → Scrape fails!
```

**Example conflict in exposition format:**

```
# TYPE kube_pod_info info
# IDENTIFYING_LABELS namespace pod_uid
kube_pod_info{namespace="default",pod_uid="abc-123",version="2.0",pod="nginx"} 1
---
# This metric has kube_pod_info identifying labels, so it correlates.
# But it also has a "version" label that conflicts!
my_metric{namespace="default",pod_uid="abc-123",version="1.0"} 42
```

When a conflict is detected during scrape, **the scrape fails with an error**.

Note that **identifying labels cannot conflict** because they must be present on the metric for correlation to occur—if the metric has the same label name with a different value, it simply won't correlate with that info metric.

---

## Technical Implementation

### Parser Interface Extensions

The existing `Parser` interface needs minimal changes:

#### New Entry Types

```go
const (
    EntryInvalid   Entry = -1
    EntryType      Entry = 0
    EntryHelp      Entry = 1
    EntrySeries    Entry = 2
    EntryComment   Entry = 3
    EntryUnit      Entry = 4
    EntryHistogram Entry = 5
    
    // NEW: Identifying labels declaration
    EntryIdentifyingLabels Entry = 6  // # IDENTIFYING_LABELS <label1> <label2> ...
    // NEW: Info section delimiter
    EntryInfoDelimiter     Entry = 7  // --- (marks end of info metrics section)
)
```

#### New Parser Method

```go
// Parser interface addition
type Parser interface {
    // ... existing methods (Series, Histogram, Help, Type, Unit, etc.) ...
    
    // IdentifyingLabels returns the list of identifying label names.
    // Must only be called after Next() returned EntryIdentifyingLabels.
    // The returned slice becomes invalid after the next call to Next.
    IdentifyingLabels() [][]byte
}
```

### Scrape Loop Integration

The scrape loop tracks info metrics with identifying labels separately:

```go
// Info metric cache entry
type infoMetricCacheEntry struct {
    ref               storage.SeriesRef
    lastIter          uint64
    hash              uint64
    identifyingLabels labels.Labels
    descriptiveLabels labels.Labels
    infoType          string  // Derived from metric name (e.g., "kube_pod" from "kube_pod_info")
}

type scrapeCache struct {
    // ... existing fields ...
    
    // Info metric parsing state (reset each scrape)
    currentInfoType          string   // Current info metric name being parsed
    currentIdentifyingNames  []string // Identifying label names for current info metric
    infoSectionEnded         bool     // True after --- delimiter is encountered
    
    // Info metric tracking (persists across scrapes)
    infoMetrics     map[string]*infoMetricCacheEntry  // key: hash of type + identifying labels
    infoMetricsCur  map[storage.SeriesRef]*infoMetricCacheEntry
    infoMetricsPrev map[storage.SeriesRef]*infoMetricCacheEntry
}
```

#### Processing in append()

```go
func (sl *scrapeLoop) append(app storage.Appender, b []byte, contentType string, ts time.Time) (total, added, seriesAdded int, err error) {
    defTime := timestamp.FromTime(ts)
    
    var currentMetricName string
    var currentMetricType textparse.MetricType
    
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
        case textparse.EntryType:
            currentMetricName, currentMetricType = p.Type()
            // Reset identifying labels for new metric family
            sl.cache.currentIdentifyingNames = nil
            if currentMetricType == textparse.MetricTypeInfo {
                // Info metrics not allowed after delimiter
                if sl.cache.infoSectionEnded {
                    return 0, 0, 0, fmt.Errorf("TYPE info not allowed after --- delimiter")
                }
                sl.cache.currentInfoType = deriveInfoType(string(currentMetricName))
            } else {
                sl.cache.currentInfoType = ""
            }
            continue
            
        case textparse.EntryIdentifyingLabels:
            // Only valid after TYPE info declaration
            if sl.cache.currentInfoType == "" {
                return 0, 0, 0, fmt.Errorf("IDENTIFYING_LABELS without preceding TYPE info declaration")
            }
            names := p.IdentifyingLabels()
            sl.cache.currentIdentifyingNames = make([]string, len(names))
            for i, name := range names {
                sl.cache.currentIdentifyingNames[i] = string(name)
            }
            continue
            
        case textparse.EntryInfoDelimiter:
            sl.cache.infoSectionEnded = true
            continue
            
        case textparse.EntrySeries:
            // Info metrics require IDENTIFYING_LABELS
            if sl.cache.currentInfoType != "" && len(sl.cache.currentIdentifyingNames) == 0 {
                return 0, 0, 0, fmt.Errorf("TYPE info requires IDENTIFYING_LABELS declaration")
            }
            
            // Process info metric
            if sl.cache.currentInfoType != "" {
                if err := sl.processInfoMetric(app, p, defTime); err != nil {
                    sl.l.Debug("Info metric processing error", "err", err)
                }
            }
            // Continue with normal series processing...
            
        // ... rest of existing handling ...
        }
    }
    
    return total, added, seriesAdded, err
}

// deriveInfoType extracts the type from an info metric name
func deriveInfoType(metricName string) string {
    if strings.HasSuffix(metricName, "_info") {
        return strings.TrimSuffix(metricName, "_info")
    }
    return metricName
}
```

#### Info Metric Processing

```go
func (sl *scrapeLoop) processInfoMetric(app storage.Appender, p textparse.Parser, ts int64) error {
    var allLabels labels.Labels
    p.Labels(&allLabels)
    
    // Split into identifying and descriptive labels
    identifying, descriptive := sl.splitInfoLabels(allLabels)
    
    // Validate: all identifying labels must be present
    if len(identifying) != len(sl.cache.currentIdentifyingNames) {
        return fmt.Errorf("info metric missing required identifying labels: expected %v",
            sl.cache.currentIdentifyingNames)
    }
    
    hash := identifying.Hash()
    hashKey := fmt.Sprintf("%s:%d", sl.cache.currentInfoType, hash)
    
    // Check cache and update
    ce, cached := sl.cache.infoMetrics[hashKey]
    if cached {
        ce.lastIter = sl.cache.iter
        
        // Check if descriptive labels changed
        if !labels.Equal(ce.descriptiveLabels, descriptive) {
            ce.descriptiveLabels = descriptive
        }
    }
    
    // Store info metric metadata for correlation
    ref, err := app.AppendInfoMetric(
        sl.cache.currentInfoType,
        identifying,
        descriptive,
        ts,
    )
    if err != nil {
        return err
    }
    
    if !cached {
        ce = &infoMetricCacheEntry{
            ref:               ref,
            lastIter:          sl.cache.iter,
            hash:              hash,
            identifyingLabels: identifying,
            descriptiveLabels: descriptive,
            infoType:          sl.cache.currentInfoType,
        }
        sl.cache.infoMetrics[hashKey] = ce
    } else {
        ce.ref = ref
    }
    
    sl.cache.infoMetricsCur[ref] = ce
    return nil
}

func (sl *scrapeLoop) splitInfoLabels(allLabels labels.Labels) (labels.Labels, labels.Labels) {
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

### Scrape Configuration

```go
type ScrapeConfig struct {
    // ... existing fields ...
    
    // EnableInfoMetricCorrelation enables processing of IDENTIFYING_LABELS
    // and automatic enrichment of correlated metrics.
    // Default: false for backward compatibility.
    EnableInfoMetricCorrelation bool `yaml:"enable_info_metric_correlation,omitempty"`
    
    // InfoMetricLimit is the maximum number of info metrics with identifying
    // labels per scrape target. 0 means no limit.
    InfoMetricLimit int `yaml:"info_metric_limit,omitempty"`
}
```

### Data Flow Summary

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                           Scrape Data Flow                                    │
└───────────────────────────────────────────────────────────────────────────────┘

  Target /metrics                    Prometheus Scrape Loop
  ┌─────────────────┐                ┌─────────────────────────────────────────┐
  │ # TYPE pod info │                │                                         │
  │ # IDENT_LABELS  │ ──HTTP GET──►  │  1. Create Parser (textparse.New)       │
  │ pod_info{...} 1 │                │                                         │
  │ ---             │                │  2. Loop: p.Next()                      │
  │ # TYPE metric   │                │     ├─ EntryType → check if info type   │
  │ metric{...} 123 │                │     ├─ EntryIdentifyingLabels → cache   │
  │ # EOF           │                │     ├─ EntrySeries (info) → process     │
  └─────────────────┘                │     │   └─ app.AppendInfoMetric()       │
                                     │     ├─ EntryInfoDelimiter → mark ended  │
                                     │     ├─ EntrySeries → checkConflicts()   │
                                     │     │   └─ app.Append()                 │
                                     │     └─ EntryHistogram → ...             │
                                     │                                         │
                                     │  3. updateStaleMarkers()                │
                                     │     ├─ Series: Write StaleNaN           │
                                     │     └─ Info metrics: mark stale         │
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
                                     │  │ - Samples   │  │ - infoMetric    │   │
                                     │  │ - InfoMeta  │  │   Metadata      │   │
                                     │  └─────────────┘  │ - Correlation   │   │
                                     │                   │   Index         │   │
                                     │                   └─────────────────┘   │
                                     └─────────────────────────────────────────┘
```

---

## Related Documents

- [01-context.md](./01-context.md) - Problem statement and motivation
- [03-sdk.md](./03-sdk.md) - How Prometheus client libraries support info metrics with identifying labels
- [04-service-discovery.md](./04-service-discovery.md) - How info metrics relate to Prometheus targets
- [05-storage.md](./05-storage.md) - How info metric metadata is stored in the TSDB
- [06-querying.md](./06-querying.md) - PromQL extensions for working with info metrics
- [07-web-ui-and-apis.md](./07-web-ui-and-apis.md) - How info metrics are displayed and accessed

---

*This proposal is a work in progress. Feedback is welcome.*
