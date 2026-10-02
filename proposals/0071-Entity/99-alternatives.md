# Alternatives Considered

This document captures alternative approaches that were evaluated during the design of native Entity support in Prometheus. For each alternative, we describe what was considered, why it was appealing, and ultimately why it was not chosen.

The goal is to preserve institutional knowledge about design decisions and help future contributors understand the reasoning behind the current proposal.

---

## Exposition Formats

*See [Exposition Formats](./02-exposition-formats.md) for the chosen approach.*

### Alternative: Introduce a New "Entity" Concept in for OpenMetrics-text

#### Description

Instead of extending info metrics, introduce a completely new "Entity" concept with dedicated syntax:

```
# ENTITY_TYPE k8s.pod
# ENTITY_IDENTIFYING namespace pod_uid
k8s.pod{namespace="default",pod_uid="abc-123",pod="nginx"}

---

# TYPE container_cpu_usage_seconds_total counter
container_cpu_usage_seconds_total{namespace="default",pod_uid="abc-123",container="app"} 1234.5
```

Key differences from the chosen approach:
- New `# ENTITY_TYPE` declaration instead of `# TYPE ... info`
- New `# ENTITY_IDENTIFYING` declaration instead of `# IDENTIFYING_LABELS`
- Entity instances have **no value** (no `1` placeholder)
- Entity type is explicit in the declaration, not derived from the metric name

#### Motivation

- **Semantic clarity**: Entities truly aren't metrics—they don't have values because they represent the *producers* of telemetry, not telemetry itself
- **Cleaner data model**: No meaningless `1` value wasting storage
- **Better alignment with OpenTelemetry**: OTel's Entity model treats entities as first-class objects, not metrics
- **No breaking change for existing info metrics**: Since this introduces completely new syntax, existing applications exposing info metrics in any order would continue to work unchanged. The new Entity syntax would be opt-in for applications that want correlation features.

#### Concerns / Reasons for Rejection

- **Cognitive load**: Users must learn a new concept ("Entity") rather than building on the familiar info metric pattern they already understand
- **Larger syntax change**: Three new declarations vs. one (`# ENTITY_TYPE`, `# ENTITY_IDENTIFYING`, value-less lines vs. just `# IDENTIFYING_LABELS`)
- **Community familiarity**: The `*_info` metric pattern is well-established across the ecosystem (kube-state-metrics, node_exporter, OTel SDK). Extending it is less disruptive than replacing it.
- **Incremental evolution**: Prometheus has historically evolved through incremental changes rather than whole new concepts

The extended info metrics approach achieves the same functional goals (identifying vs. descriptive labels, automatic enrichment, correlation) while requiring less conceptual overhead.

---