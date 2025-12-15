# Alerting: Entity-Aware Alert Evaluation

## Abstract

This document specifies how Prometheus alerting rules and Alertmanager interact with the Entity concept introduced in [01-context.md](./01-context.md). The central challenge is ensuring that alerts remain stable when entity descriptive labels change—a pod migrating between nodes or a service being upgraded should not cause alerts to "flap" (appearing to resolve and re-fire).

We introduce the concept of **Alert Identity**—a stable identifier for an alert that persists even when some labels change. This builds on the existing Fingerprint mechanism but distinguishes between labels that define identity versus labels that provide context. The key insight is that labels explicitly used in an alert expression signal user intent and should contribute to identity, while labels added purely through automatic enrichment (as described in [06-querying.md](./06-querying.md)) are contextual metadata.

This document explores the implications for both Prometheus and Alertmanager, including trade-offs and the need for Alertmanager API changes to fully realize stable alert identity across the pipeline.

---

## Background

### Alert Figerprint

In current Prometheus, each alert has a **Fingerprint**—a hash computed from all of its labels:

```go
// rules/alerting.go - current implementation
type Alert struct {
    State       AlertState
    Labels      labels.Labels
    Annotations labels.Labels
    Value       float64
    // ... timestamps ...
}

func (a *Alert) Fingerprint() model.Fingerprint {
    return a.Labels.Fingerprint()  // Hash of ALL labels
}
```

The fingerprint determines:
- **State tracking:** Which alerts are currently active (the `active` map in `AlertingRule`)
- **`for` clause:** Whether an alert has been pending long enough to fire
- **Deduplication:** Whether to send an alert again or skip it

This works well today because labels are stable—they come from the metric's own labels, labels added by the rule configuration, and external labels. When any label changes, it's intentionally a different alert: `{instance="server-1"}` and `{instance="server-2"}` are distinct alerts tracking distinct issues.

### The Challenge: Enriched Labels Change

With entity support, query results are automatically enriched with entity labels as described in [06-querying.md](./06-querying.md). This enrichment includes **descriptive labels** that can change during an entity's lifetime:

- A pod's `k8s.pod.status.phase` changes from `Pending` to `Running`
- A service's `service.version` changes during deployment
- A node's `k8s.node.name` could theoretically change

If the existing fingerprint mechanism includes all enriched labels, alerts would "flap"—appearing to resolve and re-fire whenever a descriptive label changes, even though the underlying condition persists.

**Example of the problem:**

```yaml
alert: HighCPU
expr: container_cpu_usage_seconds_total > 0.9
for: 5m
```

1. T0: Alert becomes Pending with labels `{pod_uid="abc", k8s.node.name="worker-1"}`
2. T3: Pod migrates, `k8s.node.name` changes to `worker-2`
3. With naive fingerprinting, Prometheus sees:
   - Alert `{..., k8s.node.name="worker-1"}` disappeared (resolved?)
   - Alert `{..., k8s.node.name="worker-2"}` appeared (new!)
   - The `for: 5m` timer resets

This defeats the purpose of the `for` clause and creates confusing behavior.

---

## Introducing Alert Identity

### Why We Need a New Concept

The existing Fingerprint mechanism served Prometheus well because label stability was assumed. With entity enrichment, we need a more nuanced concept: **Alert Identity**.

Alert Identity answers the question: "Is this the same alert as before, or a different one?" While Fingerprint simply hashes all labels, Alert Identity considers which labels are semantically significant for distinguishing alerts.

The term "Alert Identity" is new to Prometheus—it doesn't exist in the current codebase. We introduce it here to describe the stable identifier we need, which will be implemented as a modified fingerprint computation that excludes certain labels.

### Identifying Labels vs. Descriptive Labels in Alert Identity

As established in [01-context.md](./01-context.md), entity labels fall into two categories: **identifying labels** (which uniquely identify an entity, like `k8s.pod.uid`) and **descriptive labels** (which provide additional context that may change, like `k8s.node.name`).

For Alert Identity, we treat these categories differently:

- **Entity identifying labels are always part of alert identity.** These labels uniquely identify the entity producing the alert. If two alerts have different `k8s.pod.uid` values, they're fundamentally about different pods and should be distinct alerts.

- **Entity descriptive labels are only part of identity if explicitly used in the expression.** This is where user intent matters.

Consider this rule:

```yaml
alert: PodHighMemory
expr: container_memory_usage_bytes > 1e9
```

When evaluated, the query engine enriches results with entity labels including both `k8s.pod.uid` (identifying) and `k8s.node.name` (descriptive). The identifying label `k8s.pod.uid` is always part of identity—different pods are different alerts. But the descriptive label `k8s.node.name` is NOT part of identity here because the user didn't filter on it. If a pod migrates from worker-1 to worker-2, it remains the same alert (same pod UID).

Now consider a rule that explicitly filters on a descriptive label:

```yaml
alert: NodeHighCPU
expr: cpu_usage{k8s.node.name="worker-1"} > 80
```

Here, the user explicitly filtered by `k8s.node.name="worker-1"`. They're saying: "I specifically care about worker-1." The descriptive label `k8s.node.name` becomes part of identity because the user declared it significant by including it in their expression. If they wrote another rule for worker-2, those would be separate alerts.

This leads to our core principle:

> **Labels explicitly used in the expression signal user intent and contribute to identity. Labels added purely through enrichment are context that doesn't affect identity.**

### What Constitutes Identity

Based on this principle, Alert Identity is computed from:

1. **Metric labels** — Original labels on the time series
2. **Entity identifying labels** — Labels that uniquely identify an entity (e.g., `k8s.pod.uid`)
3. **Explicit descriptive labels** — Descriptive labels the user filtered on in the expression
4. **Rule-defined labels** — Labels added in the rule's `labels:` configuration
5. **External labels** — Prometheus-wide labels from configuration

Labels **excluded** from identity:

1. **Enriched descriptive labels** — Descriptive labels added by automatic enrichment that weren't explicitly referenced

### The Alertmanager Challenge

Here's where things get complicated. Prometheus computes Alert Identity internally, but **Alertmanager also computes its own fingerprint** from the labels it receives. If we send all labels (including enriched descriptive) to Alertmanager:

```
Prometheus                              Alertmanager
┌──────────────────┐                    ┌──────────────────┐
│ Identity = hash( │                    │ Fingerprint =    │
│   metric_labels  │   sends all        │   hash(all       │
│   + identifying  │   labels           │     received     │
│   + explicit     │ ──────────────►    │     labels)      │
│   + rule_labels  │                    │                  │
│ )                │                    │                  │
│                  │                    │ If labels change,│
│ ✓ Stable         │                    │ fingerprint      │
│                  │                    │ changes!         │
└──────────────────┘                    └──────────────────┘
```

If descriptive labels change between alert sends:
- Prometheus sees the same alert (stable identity)
- Alertmanager sees a "new" alert (different fingerprint)
- Alertmanager might send duplicate notifications
- Alert might move between groups
- Silences might stop matching

This is a real problem that we must address explicitly.

---

## Design Options

We have three main approaches to handle this challenge:

### Option A: Identity is Prometheus-Internal Only

Prometheus uses Alert Identity internally for state tracking and the `for` clause. When sending to Alertmanager, it sends all labels. Alertmanager's behavior with changing labels is documented but accepted.

**Prometheus changes:**
- Compute identity from identity labels for internal state tracking
- Send all labels to Alertmanager

**Alertmanager changes:** None

**Trade-offs:**
- ✅ Simple—no Alertmanager API changes
- ✅ Prometheus internal state is stable
- ❌ Alertmanager may re-notify when descriptive labels change
- ❌ Groups may split/merge unexpectedly
- ❌ Silences by descriptive labels may break

**Mitigation:** Document that users should group/silence by stable labels (identifying labels) for predictable behavior.

### Option B: Alertmanager API Receives Identity Separately

Extend the Alertmanager API to receive identity labels separately from all labels.

**Prometheus changes:**
- Compute identity labels
- Send both `identityLabels` and `labels` to Alertmanager

**Alertmanager changes:**
- API accepts new `identityLabels` field
- Use `identityLabels` for fingerprinting and deduplication
- Use full `labels` for routing matchers and notification templates

**Trade-offs:**
- ✅ Full stability across the pipeline
- ✅ Alertmanager can correctly deduplicate
- ❌ Requires API version bump
- ❌ Requires coordinated changes to both systems
- ❌ Breaking change for existing Alertmanager integrations

### Option C: Only Send Identity Labels

Prometheus only sends identity labels to Alertmanager. Enriched descriptive labels are either dropped or moved to annotations.

**Trade-offs:**
- ✅ Simple Alertmanager, stable fingerprints
- ❌ Loses rich context in notification templates
- ❌ Awkward if users want to route by descriptive labels

### Recommendation

We recommend **Option B** for full correctness, with **Option A** as an acceptable intermediate step that doesn't require Alertmanager changes.

Option A is sufficient for ensuring Prometheus's `for` clause works correctly. The Alertmanager "churn" is manageable if users follow best practices (group and silence by stable labels). Option B can be implemented later as an enhancement.

The rest of this document assumes Option B as the target design, with notes on Option A where relevant.

---

## Prometheus Implementation

### Tracking Explicit Labels

The alerting rule must track which labels were explicitly used in the expression. During rule creation, we parse the expression AST and extract label names from all matchers:

```go
type AlertingRule struct {
    name         string
    vector       parser.Expr
    holdDuration time.Duration
    labels       labels.Labels
    annotations  labels.Labels
    
    // Labels explicitly referenced in matchers within the expression
    explicitLabels map[string]struct{}
    
    // Reference to entity store for identifying/descriptive label lookup
    entityStore storage.EntityQuerier
}

func NewAlertingRule(name string, expr parser.Expr, ...) *AlertingRule {
    rule := &AlertingRule{
        name:   name,
        vector: expr,
        // ...
    }
    rule.explicitLabels = extractExplicitLabels(expr)
    return rule
}

func extractExplicitLabels(expr parser.Expr) map[string]struct{} {
    explicit := make(map[string]struct{})
    
    parser.Inspect(expr, func(node parser.Node, _ []parser.Node) error {
        if vs, ok := node.(*parser.VectorSelector); ok {
            for _, matcher := range vs.LabelMatchers {
                if matcher.Name != labels.MetricName {
                    explicit[matcher.Name] = struct{}{}
                }
            }
        }
        return nil
    })
    
    return explicit
}
```

### Computing Identity Labels

When evaluating an alert, we separate identity labels from the full enriched label set. The query engine returns enriched results as described in [06-querying.md](./06-querying.md), and we filter them:

```go
func (r *AlertingRule) computeIdentityLabels(allLabels labels.Labels) labels.Labels {
    builder := labels.NewBuilder(nil)
    
    for _, lbl := range allLabels {
        if r.isIdentityLabel(lbl.Name) {
            builder.Set(lbl.Name, lbl.Value)
        }
    }
    
    return builder.Labels()
}

func (r *AlertingRule) isIdentityLabel(name string) bool {
    // Metric name is always part of identity
    if name == labels.MetricName {
        return true
    }
    
    // Entity identifying labels are always part of identity
    if r.entityStore != nil && r.entityStore.IsIdentifyingLabel(name) {
        return true
    }
    
    // Descriptive labels that were explicitly filtered are part of identity
    if _, explicit := r.explicitLabels[name]; explicit {
        return true
    }
    
    // If it's NOT a known entity label, it's an original metric label → identity
    if r.entityStore == nil {
        return true
    }
    if !r.entityStore.IsDescriptiveLabel(name) {
        return true
    }
    
    // Enriched descriptive label → NOT part of identity
    return false
}
```

### Alert Evaluation Flow

The `Eval` method uses identity labels for internal state while tracking full labels for sending:

```go
func (r *AlertingRule) Eval(ctx context.Context, ts time.Time, ...) (Vector, error) {
    // Query engine returns enriched results (see 06-querying.md)
    res, err := r.vector.Eval(ctx, ts, ...)
    if err != nil {
        return nil, err
    }
    
    for _, sample := range res {
        // Compute identity labels (subset used for fingerprinting)
        identityLabels := r.computeIdentityLabels(sample.Metric)
        
        // Full labels include everything (for sending to Alertmanager)
        fullLabels := sample.Metric
        
        // Add rule-defined labels to both
        for _, l := range r.labels {
            identityLabels = append(identityLabels, l)
            fullLabels = append(fullLabels, l)
        }
        
        // Look up or create alert using IDENTITY labels for fingerprint
        fp := identityLabels.Fingerprint()
        alert := r.active[fp]
        if alert == nil {
            alert = &Alert{
                IdentityLabels: identityLabels,
                Labels:         fullLabels,
                Annotations:    r.annotations,
                ActiveAt:       ts,
            }
            r.active[fp] = alert
        } else {
            // Alert exists—update full labels (descriptive may have changed)
            alert.Labels = fullLabels
        }
        
        alert.Value = sample.V
    }
    
    // ... rest of evaluation (state transitions, for clause, etc.)
}
```

### The Alert Struct

We rename the fields to make the distinction clear:

```go
type Alert struct {
    State AlertState
    
    // IdentityLabels are used for fingerprinting and state tracking.
    // These labels are stable even when descriptive labels change.
    IdentityLabels labels.Labels
    
    // Labels includes all labels: identity + enriched descriptive.
    // This is what gets sent to Alertmanager for routing and templates.
    Labels labels.Labels
    
    Annotations labels.Labels
    Value       float64
    
    ActiveAt        time.Time
    FiredAt         time.Time
    ResolvedAt      time.Time
    LastSentAt      time.Time
    ValidUntil      time.Time
    KeepFiringSince time.Time
}

// Fingerprint uses identity labels for stability
func (a *Alert) Fingerprint() model.Fingerprint {
    return a.IdentityLabels.Fingerprint()
}
```

Note that `Labels` (full labels) is **not** redundantly storing identity labels—it's the complete set. We could optimize storage by only storing the "extra" descriptive labels and computing full labels on demand, but this complicates the code for minimal gain.

---

## Alertmanager Changes

### Option A: No Changes (Intermediate)

If we proceed with Option A (Prometheus-internal identity only), Alertmanager receives alerts as today with `labels` containing all labels. Users must be aware:

- Grouping by descriptive labels may cause groups to change over time
- Silences by descriptive labels may stop matching if labels change
- Notification deduplication may re-notify on label changes

**Best practices for Option A:**
- Group by identifying labels: `group_by: [alertname, k8s.pod.uid]` not `k8s.pod.name`
- Silence by identifying labels for stability
- Accept that notifications may include different descriptive label values over time

### Option B: API Extension (Target Design)

Extend the Alertmanager API to accept identity label references. To avoid duplicating label strings, `identityLabelRefs` contains indices into the `labels` array:

```json
// POST /api/v2/alerts - Extended payload
[
  {
    "labels": [
      { "name": "alertname", "value": "HighCPU" },
      { "name": "k8s.pod.uid", "value": "abc-123" },
      { "name": "k8s.pod.name", "value": "nginx-7b9f5" },
      { "name": "k8s.node.name", "value": "worker-1" },
      { "name": "severity", "value": "warning" }
    ],
    "identityLabelRefs": [0, 1, 4],
    "annotations": { ... },
    "startsAt": "2024-01-15T10:30:00Z",
    "endsAt": "0001-01-01T00:00:00Z",
    "generatorURL": "..."
  }
]
```

Here, `identityLabelRefs: [0, 1, 4]` indicates that labels at positions 0 (`alertname`), 1 (`k8s.pod.uid`), and 4 (`severity`) constitute the alert's identity. Alertmanager reconstructs identity labels by indexing into the `labels` array.

Alertmanager changes:
1. Accept `identityLabelRefs` field (optional for backward compatibility)
2. If present, construct identity labels from the referenced indices in `labels`
3. Use identity labels for fingerprinting and deduplication
4. Use full `labels` for routing matchers and notification templates
5. Groups are keyed by identity labels, not full labels

This ensures the entire pipeline respects Alert Identity.

### Routing and Grouping

With either option, routing matchers operate on full `labels`:

```yaml
route:
  group_by: [alertname, k8s.namespace.name]  # Both are identity labels
  routes:
    - matchers:
        - k8s.node.name=~"worker-.*"  # Can match descriptive labels
      receiver: node-team
```

With Option B, even though `k8s.node.name` changes, the alert stays in the same group because grouping uses identity labels internally.

### Silencing and Inhibition

Silences match against full `labels`:

```yaml
matchers:
  - k8s.pod.uid="abc-123"     # Identifying - stable match
  - k8s.node.name="worker-1"  # Descriptive - may stop matching if pod migrates
```

With Option B, the silence correctly continues matching because the alert's identity hasn't changed, even if `k8s.node.name` changed.

---

## Temporal Semantics

### Which Label Values Are Sent?

When Prometheus evaluates an alerting rule at time T, the query engine enriches results with descriptive labels as they exist at time T (see [06-querying.md](./06-querying.md) for details on point-in-time label resolution). These are the values included in `Labels` when sending to Alertmanager.

If an alert persists across multiple evaluation cycles:
- T1: Labels include `{service.version="1.0.0"}`
- T2: Service upgrades
- T3: Labels include `{service.version="2.0.0"}`

With stable Alert Identity, this is still the same alert. Notifications at T3 reflect the current state.

### The `for` Clause

The `for` clause requires an alert to be continuously active for a duration before firing:

```yaml
alert: HighCPU
expr: cpu_usage > 0.9
for: 5m
```

This works correctly because Prometheus tracks alerts by `IdentityLabels.Fingerprint()`. Descriptive label changes don't reset the timer:

1. T0: Alert becomes Pending, identity `{instance="server-1", k8s.pod.uid="abc"}`
2. T1-T4: Entity's `k8s.node.name` changes multiple times
3. T5: Alert fires (5 minutes elapsed, same identity throughout)

---

## Examples

### Basic Alert with Enrichment

```yaml
alert: PodHighMemory
expr: container_memory_usage_bytes > 1e9
for: 2m
labels:
  severity: warning
annotations:
  summary: "Pod {{ $labels.k8s.pod.name }} high memory on {{ $labels.k8s.node.name }}"
```

**Identity labels:** `{__name__, container, k8s.pod.uid, alertname, severity}`

**Full labels (sent to Alertmanager):** Identity + `k8s.pod.name`, `k8s.node.name`, `k8s.pod.status.phase`, etc.

The annotation templates can reference enriched descriptive labels.

### Alert with Explicit Descriptive Filter

```yaml
alert: CriticalPodPending
expr: kube_pod_status_phase{k8s.pod.status.phase="Pending"} == 1
for: 10m
labels:
  severity: critical
```

**Identity labels:** `{__name__, k8s.pod.uid, k8s.pod.status.phase, alertname, severity}`

Here `k8s.pod.status.phase` IS part of identity because the user explicitly filtered on it. This alert resolves when the pod transitions to `Running`.

### Two Alerts Distinguished by Descriptive Labels

```yaml
# Alert 1
alert: WorkerOneHighCPU
expr: cpu_usage{k8s.node.name="worker-1"} > 80

# Alert 2
alert: WorkerTwoHighCPU
expr: cpu_usage{k8s.node.name="worker-2"} > 80
```

These have different `alertname` values, so they're distinct regardless of whether `k8s.node.name` is considered identity. But even with the same alert name, the explicit filter makes `k8s.node.name` part of identity for each rule.

---

## Backward Compatibility

For metrics without entity correlation:
- `explicitLabels` contains labels from the expression
- `entityStore.IsIdentifyingLabel()` and `IsDescriptiveLabel()` return false
- All labels are treated as identity labels
- Behavior matches current Prometheus exactly

Existing alerting rules work unchanged. Entity-aware behavior only activates for metrics that have entity correlations.

---

## Open Questions

### Migration Path for Alertmanager

If we implement Option B, what's the migration path?
- New API version with `identityLabels` field?
- Backward compatible: if `identityLabels` absent, use `labels`?
- How do we handle mixed Prometheus/Alertmanager versions during rollout?

### Recording Rules

If a recording rule aggregates entity-correlated metrics:

```yaml
record: job:requests:rate5m
expr: sum by (job) (rate(http_requests_total[5m]))
```

The recorded metric loses entity correlation (aggregated away). Alerting on this metric behaves as today (no entity enrichment). Is this acceptable, or should we track "derived" correlations?

### Relabeling Entity Labels

Should alert relabeling be able to manipulate entity labels?

```yaml
alerting:
  alert_relabel_configs:
    - source_labels: [k8s.node.name]
      action: drop
```

This works on full `labels`. Should there be restrictions or warnings when dropping identity labels?

---

## Summary

Entity-aware alerting introduces Alert Identity as a concept built on top of the existing Fingerprint mechanism. The core principle is that **explicit labels signal user intent**, while **enriched labels provide context**.

| Component | Change |
|-----------|--------|
| Prometheus alerting rules | Track explicit labels, compute identity separately |
| Prometheus `Alert` struct | Split into `IdentityLabels` and `Labels` |
| Alertmanager (Option A) | None—document behavioral implications |
| Alertmanager (Option B) | Accept `identityLabels` for fingerprinting |

The key insight: **"If you mentioned it, you meant it."** Labels in the expression contribute to identity. Labels from enrichment provide context without affecting identity.

---

## Related Documents

- [01-context.md](./01-context.md) — Problem statement and entity concept
- [05-storage.md](./05-storage.md) — How entities and correlations are stored
- [06-querying.md](./06-querying.md) — Entity-aware PromQL and automatic enrichment
- [07-web-ui-and-apis.md](./07-web-ui-and-apis.md) — UI and API exposure of alerts
