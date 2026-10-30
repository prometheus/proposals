# Web UI and APIs

## Abstract

This document specifies how Prometheus's HTTP API and Web UI should be extended to support entity-aware querying. The key principle is **progressive disclosure**: query results display entity context prominently while keeping the interface familiar for users who don't need entity details.

The wireframe below illustrates the concept—entity labels are displayed separately from metric labels, making it easy to understand the context of each time series.

![Wireframe showing query results with entity labels separated from metric labels](./wireframes/Wireframe%20-%20Simple%20idea%20-%20Complete%20flow.png)

---

## Background

### Current API Response Structure

Today, the `/api/v1/query` endpoint returns results like:

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "container_cpu_usage_seconds_total",
          "container": "nginx",
          "namespace": "production",
          "pod": "nginx-7b9f5"
        },
        "value": [1234567890, "1234.5"]
      }
    ]
  }
}
```

All labels are in a flat `metric` object. There's no distinction between:
- Labels that identify the metric itself (e.g., `container`, `method`)
- Labels that identify the entity producing the metric (e.g., `k8s.pod.uid`, `k8s.node.uid`)
- Labels that describe the entity (e.g., `k8s.pod.name`, `k8s.node.os`)

### Current UI Display

The Prometheus UI displays all labels together:

```
container_cpu_usage_seconds_total{container="nginx", namespace="production", pod="nginx-7b9f5", ...}
```

This becomes unwieldy when entity labels are added through enrichment—users see a long list of labels without understanding which provide entity context.

---

## API Changes

### Query Response Enhancement

The query endpoints (`/api/v1/query`, `/api/v1/query_range`) should return entity context alongside the metric:

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "container_cpu_usage_seconds_total",
          "container": "nginx"
        },
        "entities": [
          {
            "type": "k8s.pod",
            "identifyingLabels": {
              "k8s.namespace.name": "production",
              "k8s.pod.uid": "abc-123"
            },
            "descriptiveLabels": {
              "k8s.pod.name": "nginx-7b9f5",
              "k8s.pod.status.phase": "Running"
            }
          },
          {
            "type": "k8s.node",
            "identifyingLabels": {
              "k8s.node.uid": "node-001"
            },
            "descriptiveLabels": {
              "k8s.node.name": "worker-1",
              "k8s.node.os": "linux"
            }
          }
        ],
        "value": [1234567890, "1234.5"]
      }
    ]
  }
}
```

**Key changes:**

| Field | Description |
|-------|-------------|
| `metric` | Only the original metric labels (not entity labels) |
| `entities` | Array of correlated entities with their labels |
| `entities[].type` | Entity type (e.g., "k8s.pod", "service") |
| `entities[].identifyingLabels` | Immutable labels that identify the entity |
| `entities[].descriptiveLabels` | Mutable labels describing the entity |

### Backward Compatibility

For backward compatibility, a query parameter controls the response format:

```
GET /api/v1/query?query=...&entity_info=true
```

| Parameter | Behavior |
|-----------|----------|
| `entity_info=true` | Returns structured entity information |
| `entity_info=false` (default) | Returns flat labels (current behavior, entity labels merged in) |

When `entity_info=false` (default), all entity labels appear in the `metric` object as they do today with automatic enrichment. This ensures existing tooling continues to work.

### Response Type Definitions

```typescript
// Enhanced query result with entity context
interface EnhancedInstantSample {
  metric: Record<string, string>;  // Original metric labels only
  entities?: EntityContext[];       // Correlated entities (if entity_info=true)
  value?: [number, string];
  histogram?: [number, Histogram];
}

interface EntityContext {
  type: string;                           // e.g., "k8s.pod"
  identifyingLabels: Record<string, string>;
  descriptiveLabels: Record<string, string>;
}

// When entity_info=false (default), use existing format
interface LegacyInstantSample {
  metric: Record<string, string>;  // All labels merged (metric + entity labels)
  value?: [number, string];
  histogram?: [number, Histogram];
}
```

---

## New Entity Endpoints

### List Entity Types

```
GET /api/v1/entities/types
```

Returns all known entity types in the system:

```json
{
  "status": "success",
  "data": [
    {
      "type": "k8s.pod",
      "identifyingLabels": ["k8s.namespace.name", "k8s.pod.uid"],
      "count": 1523
    },
    {
      "type": "k8s.node", 
      "identifyingLabels": ["k8s.node.uid"],
      "count": 12
    },
    {
      "type": "service",
      "identifyingLabels": ["service.namespace", "service.name", "service.instance.id"],
      "count": 89
    }
  ]
}
```

### Get Entity Type Schema

```
GET /api/v1/entities/types/{type}
```

Returns detailed schema for an entity type:

```json
{
  "status": "success",
  "data": {
    "type": "k8s.pod",
    "identifyingLabels": ["k8s.namespace.name", "k8s.pod.uid"],
    "knownDescriptiveLabels": [
      "k8s.pod.name",
      "k8s.pod.status.phase",
      "k8s.pod.start_time",
      "k8s.pod.ip",
      "k8s.pod.owner.kind",
      "k8s.pod.owner.name"
    ],
    "activeEntityCount": 1523,
    "correlatedSeriesCount": 45230
  }
}
```

### List Entities

```
GET /api/v1/entities?type=k8s.pod&match[]={k8s.namespace.name="production"}
```

Returns entities matching the criteria:

```json
{
  "status": "success",
  "data": [
    {
      "type": "k8s.pod",
      "identifyingLabels": {
        "k8s.namespace.name": "production",
        "k8s.pod.uid": "abc-123"
      },
      "descriptiveLabels": {
        "k8s.pod.name": "nginx-7b9f5",
        "k8s.pod.status.phase": "Running"
      },
      "startTime": 1700000000,
      "endTime": 0,
      "correlatedSeriesCount": 42
    }
  ]
}
```

**Query parameters:**

| Parameter | Description |
|-----------|-------------|
| `type` | Entity type to query (required) |
| `match[]` | Label matchers for filtering entity labels (can specify multiple) |
| `start` | Start of time range (for historical queries) |
| `end` | End of time range |
| `limit` | Maximum entities to return |

### Get Entity Details

```
GET /api/v1/entities/{type}/{encoded_identifying_attrs}
```

The identifying labels are URL-encoded as a label set:

```
GET /api/v1/entities/k8s.pod/k8s.namespace.name%3D%22production%22%2Ck8s.pod.uid%3D%22abc-123%22
```

Returns detailed information about a specific entity:

```json
{
  "status": "success",
  "data": {
    "type": "k8s.pod",
    "identifyingLabels": {
      "k8s.namespace.name": "production",
      "k8s.pod.uid": "abc-123"
    },
    "descriptiveLabels": {
      "k8s.pod.name": "nginx-7b9f5",
      "k8s.pod.status.phase": "Running"
    },
    "startTime": 1700000000,
    "endTime": 0,
    "descriptiveHistory": [
      {
        "timestamp": 1700000000,
        "labels": {
          "k8s.pod.name": "nginx-7b9f5",
          "k8s.pod.status.phase": "Pending"
        }
      },
      {
        "timestamp": 1700000030,
        "labels": {
          "k8s.pod.name": "nginx-7b9f5",
          "k8s.pod.status.phase": "Running"
        }
      }
    ],
    "correlatedSeries": [
      "container_cpu_usage_seconds_total",
      "container_memory_usage_bytes",
      "container_network_receive_bytes_total"
    ]
  }
}
```

### Get Correlated Metrics for Entity

```
GET /api/v1/entities/{type}/{encoded_identifying_attrs}/metrics
```

Returns all metric names correlated with a specific entity:

```json
{
  "status": "success",
  "data": [
    {
      "name": "container_cpu_usage_seconds_total",
      "seriesCount": 3,
      "labels": ["container"]
    },
    {
      "name": "container_memory_usage_bytes",
      "seriesCount": 3,
      "labels": ["container"]
    }
  ]
}
```

---

## Web UI Changes

### Query Results Display

Based on the wireframe concept, query results should display entity context prominently but separately from metric labels.

**Current display:**
```
container_cpu_usage_seconds_total{container="nginx", k8s.namespace.name="production", k8s.pod.uid="abc-123", k8s.pod.name="nginx-7b9f5", k8s.node.uid="node-001", k8s.node.name="worker-1", ...} 1234.5
```

**Enhanced display:**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ container_cpu_usage_seconds_total{container="nginx"}              1234.5    │
│                                                                             │
│ Entities:                                                                   │
│   k8s.pod                                                                   │
│     k8s.namespace.name="production", k8s.pod.uid="abc-123"                  │
│     k8s.pod.name="nginx-7b9f5", k8s.pod.status.phase="Running"              │
│                                                                             │
│   k8s.node                                                                  │
│     k8s.node.uid="node-001"                                                 │
│     k8s.node.name="worker-1", k8s.node.os="linux"                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### UI Components

**1. SeriesName Enhancement**

The `SeriesName` component should accept entity context:

```typescript
interface SeriesNameProps {
  labels: Record<string, string>;
  entities?: EntityContext[];
  format: boolean;
  showEntities?: boolean;  // Toggle entity display
}
```

**2. EntityBadge Component**

A new component for displaying entity information:

```typescript
interface EntityBadgeProps {
  entity: EntityContext;
  expanded?: boolean;
  onToggle?: () => void;
}
```

Displays entity type with expandable labels:

```
┌─────────────────────────────────────────────┐
│ 📦 k8s.pod                              [▼] │
│   k8s.namespace.name="production"           │
│   k8s.pod.uid="abc-123"                     │
│   ─────────────────────────────             │
│   k8s.pod.name="nginx-7b9f5"                │
│   k8s.pod.status.phase="Running"            │
└─────────────────────────────────────────────┘
```

**3. Collapsible Entity Section**

For tables with many results, entities can be collapsed by default:

```typescript
interface DataTableProps {
  data: InstantQueryResult;
  showEntities: boolean;
  entityDisplayMode: 'collapsed' | 'expanded' | 'inline';
}
```

### New Pages

**1. Entity Explorer Page**

A dedicated page for browsing entities:

```
/entities
  ├── List all entity types
  ├── Filter by type
  ├── Search by labels
  └── Click to see entity details

/entities/{type}
  ├── List all entities of type
  ├── Filter by identifying/descriptive labels
  └── Click to see entity details

/entities/{type}/{id}
  ├── Entity details
  ├── Label history timeline
  ├── Correlated metrics list
  └── Quick query links
```

**2. Entity Type Schema Page**

Shows the schema for an entity type:

```
/entities/types/{type}
  ├── Identifying labels list
  ├── Known descriptive labels
  ├── Entity count statistics
  └── Related entity types
```

### Graph View Integration

When viewing graphs, entity context can be shown on hover:

```
┌───────────────────────────────────────────────────────────────┐
│                         Graph                                 │
│     ╱╲    ╱╲                                                  │
│    ╱  ╲  ╱  ╲    ╱╲                                           │
│   ╱    ╲╱    ╲  ╱  ╲                                          │
│  ╱            ╲╱    ╲                                         │
│ ╱                    ╲                                        │
├───────────────────────────────────────────────────────────────┤
│ Hovering: container_cpu_usage_seconds_total{container="nginx"}│
│                                                               │
│ 📦 k8s.pod: nginx-7b9f5 (production)                          │
│ 🖥️ k8s.node: worker-1                                         │
│                                                               │
│ Value: 1234.5 @ 2024-01-15 10:30:00                           │
└───────────────────────────────────────────────────────────────┘
```

### Settings

New user preferences for entity display:

```typescript
interface EntityDisplaySettings {
  // Show entity information in query results
  showEntitiesInResults: boolean;
  
  // Default display mode
  entityDisplayMode: 'collapsed' | 'expanded' | 'inline';
  
  // Show identifying vs descriptive separation
  separateIdentifyingLabels: boolean;
  
  // Entity types to always show
  pinnedEntityTypes: string[];
}
```

---

## Implementation Considerations

### API Response Size

Adding entity context increases response size. Mitigations:

1. **Optional via query parameter**: `entity_info=true` to opt-in
2. **Compression**: gzip reduces impact significantly
3. **Pagination**: Limit results and paginate large responses
4. **Streaming**: Consider streaming for very large result sets

### Frontend Performance

With potentially many entities per series:

- Lazy load entity details on expand
- Virtualize long lists
- Use `entity_info=false` for performance-critical views
- Progressive loading for entity explorer

---

## API Summary

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/query` | GET/POST | Query with optional `entity_info=true` |
| `/api/v1/query_range` | GET/POST | Range query with optional `entity_info=true` |
| `/api/v1/entities/types` | GET | List all entity types |
| `/api/v1/entities/types/{type}` | GET | Get entity type schema |
| `/api/v1/entities` | GET | List entities with filters |
| `/api/v1/entities/{type}/{id}` | GET | Get specific entity details |
| `/api/v1/entities/{type}/{id}/metrics` | GET | Get metrics for entity |

---

## UI Summary

| Feature | Description |
|---------|-------------|
| Enhanced SeriesName | Shows entities separately from labels |
| EntityBadge | Compact entity display with expand |
| Entity Explorer | Browse and search entities |
| Graph hover | Shows entity context on hover |
| Settings | Control entity display preferences |

---

## Migration Path

**Phase 1: API additions**
- Add `entity_info` parameter (default false)
- Add new `/api/v1/entities/*` endpoints
- Existing behavior unchanged

**Phase 2: UI enhancements**
- Add EntityBadge component
- Enhance SeriesName with entity support
- Add Entity Explorer page

**Phase 3: Default behavior**
- Consider making `entity_info=true` the default
- Deprecation warnings for flat-label-only usage

---

*This proposal is a work in progress. Feedback on API design and UI mockups is welcome.*

