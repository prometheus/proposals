# Prometheus Internal Telemetry as an OTel Semantic Convention Registry

* **Owners:**
  * Nicolas Takashi [@nicolastakashi](https://github.com/nicolastakashi) [nicolas.takashi@coralogix.com](mailto:nicolas.takashi@coralogix.com)
  * Arthur Silva Sens [@ArthurSens](https://github.com/ArthurSens) [arthursens2005@gmail.com](mailto:arthursens2005@gmail.com)

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [WIP: Prometheus semconvs](https://github.com/prometheus/prometheus/pull/17868)
  * [Weaver: Implement `weaver registry infer` command](https://github.com/open-telemetry/weaver/pull/1138)

* **Other docs or links:**
  * [Dev Summit notes: internal telemetry consensus](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit?tab=t.0#bookmark=id.ojugisgspwvq)
  * [OpenTelemetry Weaver](https://github.com/open-telemetry/weaver)
  * [OTel Semantic Convention specification](https://opentelemetry.io/docs/specs/semconv/)

> TL;DR: We propose defining all metrics exported by the Prometheus binary as a formal [OTel semantic convention registry](https://opentelemetry.io/docs/specs/semconv/). A machine-readable schema per package serves as the single source of truth, enabling auto-generated instrumentation code, always-up-to-date metric documentation, contract testing against live instances, and a foundation for safe metric evolution across the Prometheus ecosystem.

## Why

Prometheus defines its own internal metrics as scattered `prometheus/client_golang` constructor calls across dozens of files. There is no machine-readable description of what Prometheus emits.

This creates the following concrete problems:

* Dashboard and alert authors who depend on these metrics have no canonical reference. They reverse-engineer what Prometheus emits by reading Go source or running a live instance.
* There is no contract distinguishing stable public API metrics from internal implementation details. Metrics can be renamed, removed, or semantically changed without versioned signals.
* Documentation, if it exists, is written separately from the code and drifts. There is no mechanism to keep it in sync.
* There is no regression safety. Nothing prevents a code change from silently altering which metrics Prometheus emits or what labels they carry.
* As Prometheus increasingly interoperates with OTel (OTLP ingestion, remote write, collectors), its own telemetry remains outside the OTel schema world and is invisible to tools that understand semantic conventions.

### Pitfalls of the current solution

* Metric help strings are inconsistent: some describe counter semantics, others describe the event being counted.
* Histogram bucket configurations are chosen ad hoc with no enforcement.
* Units are absent from most metric definitions.
* No lifecycle model exists: no way to mark a metric as experimental, stable, or deprecated in a way that tooling understands.
* Ecosystem consumers (Thanos, Mimir, Grafana dashboards, alerting rules) have no authoritative reference for what a running Prometheus exposes.

## Goals

* [Required] Define Prometheus' internal telemetry as a formal OTel semantic convention registry (`registry.yaml` per package), making it the single machine-readable source of truth for every metric Prometheus exposes.
* [Required] Generate instrumentation code from the registry, eliminating hand-written metric definitions in Go.
* [Required] Generate metric documentation from the registry that cannot drift from the implementation.
* [Nice to have] Enable contract testing via `weaver registry live-check`: validate that a running Prometheus instance emits exactly what the registry declares.
* [Required] Establish a metric lifecycle model using OTel stability levels (`development`, `stable`, `deprecated`) as first-class schema information.
* [Nice to have] Lay the foundation for multi-language instrumentation code generation and ecosystem tooling (dashboards, alerting rules) derived from the same registry.

### Audience

Prometheus maintainers and contributors. Operators and SREs who build dashboards and alerts on top of Prometheus' internal metrics. OTel ecosystem tools that consume or validate Prometheus telemetry.

## Non-Goals

* Changing existing metric names, label names, or semantics. This is a schema-first refactor of how metrics are defined, not what they measure.
* Adopting the OTel SDK for instrumentation. `prometheus/client_golang` remains the instrumentation layer.
* Migrating exporters or other ecosystem projects (a natural follow-on, out of scope here).
* Publishing the registry as part of OTel upstream semantic conventions (possible long term, not required now).

## How

### The registry

Each package that exposes internal metrics has a `registry.yaml` file that fully describes every metric it owns. The exact layout (one file per package vs. a single file for the whole project) is an open question discussed below. The example below uses a per-package layout:

```yaml
groups:
  - id: metric.prometheus_tsdb_compaction_duration_seconds
    type: metric
    stability: stable
    brief: Duration of compaction runs.
    metric_name: prometheus_tsdb_compaction_duration_seconds
    instrument: histogram
    unit: s
    annotations:
      prometheus:
        histogram_type: mixed_histogram
        exponential_buckets: {start: 1, factor: 2, count: 14}
        bucket_factor: 1.1
        max_bucket_number: 100
        min_reset_duration: "1h"
```

This file is the contract. Go code, documentation, and contract tests are all derived from it. The `annotations.prometheus` block carries Prometheus-specific details invisible to OTel (histogram variant, bucket configuration, callback-based gauges, labels fixed at construction time).

The repository structure is:

```
pkg/semconv/
  registry.yaml    ← source of truth, hand-authored
  metrics.gen.go   ← generated, DO NOT EDIT
  README.md        ← generated, DO NOT EDIT
```

The Weaver templates and Rego policies used during generation are not committed to this repository. Where they live is an open question discussed below; the generation step resolves them at build time.

### Instrumentation code generation

[OTel Weaver](https://github.com/open-telemetry/weaver) renders `registry.yaml` files into typed Go code via Jinja2 templates. A Makefile target regenerates all `semconv/metrics.gen.go` files across the repository. CI enforces that generated files stay in sync with their registries.

A metric without labels generates a plain embedded type:

```go
type PrometheusTSDBCompactionDurationSeconds struct { prometheus.Histogram }

func NewPrometheusTSDBCompactionDurationSeconds() PrometheusTSDBCompactionDurationSeconds { ... }
```

A metric with dynamic labels generates a typed `.With()` method that accepts a sealed per-metric interface, catching incorrect label usage at compile time:

```go
func (m PrometheusTargetIntervalLengthSeconds) With(
    interval IntervalAttr,
    extra ...PrometheusTargetIntervalLengthSecondsAttr,
) prometheus.Observer { ... }
```

A metric with labels fixed at construction time (`const_labels`) accepts those as typed constructor parameters:

```go
func NewPrometheusSDDiscoveredTargets(name NameAttr) PrometheusSDDiscoveredTargets { ... }
```

A callback-based gauge (`prometheus.GaugeFunc`) is special: its value is pulled from a closure at scrape time rather than `Set()` by the program, so the no-argument constructor that the other instruments get does not fit. For these metrics the registry sets `only_opts: true`:

```yaml
  - id: metric.prometheus_tsdb_head_series
    type: metric
    stability: development
    brief: Total number of series in the head block.
    metric_name: prometheus_tsdb_head_series
    instrument: gauge
    unit: "{series}"
    annotations:
      prometheus:
        only_opts: true  # implemented as a GaugeFunc
```

Weaver then generates only an `Opts()` accessor carrying the schema-owned name, help, and unit — not a full constructor:

```go
func PrometheusTSDBHeadSeriesOpts() prometheus.GaugeOpts {
    return prometheus.GaugeOpts{
        Name: "prometheus_tsdb_head_series",
        Help: "Total number of series in the head block.",
    }
}
```

The package keeps ownership of the callback and wires it into `NewGaugeFunc`, passing the generated opts in place of the hand-written ones:

```go
// Before: name and help are written inline, free to drift from any schema.
m.series = prometheus.NewGaugeFunc(prometheus.GaugeOpts{
    Name: "prometheus_tsdb_head_series",
    Help: "Total number of series in the head block.",
}, func() float64 {
    return float64(h.NumSeries())
})

// After: name, help, and unit come from the registry; only the callback stays in code.
m.series = prometheus.NewGaugeFunc(semconv.PrometheusTSDBHeadSeriesOpts(), func() float64 {
    return float64(h.NumSeries())
})
```

The metric's identity (name, help, unit, stability) is now under schema control, while the runtime value source — the part that genuinely depends on live state — stays in hand-written code.

Package code then imports the generated types directly:

```go
import semconv "github.com/prometheus/prometheus/tsdb/semconv"

duration: semconv.NewPrometheusTSDBCompactionDurationSeconds(),
```

### Documentation generation

The same Weaver invocation that produces `metrics.gen.go` also produces a `README.md` per package: a complete structured reference of every metric, including name, type, unit, label semantics, stability level, and examples. Because both files are rendered from the same `registry.yaml`, documentation cannot drift from the code.

### Contract testing

`weaver registry live-check` validates live OTLP telemetry against a registry. By routing a running Prometheus' metrics through an OTel collector (Prometheus receiver → OTLP exporter) and into `live-check`, we can assert that what Prometheus emits matches the declared schema in terms of metric names, label names, types, and units.

The exact approach to contract testing is an open question discussed below.

### Metric lifecycle and evolution

OTel stability levels are first-class fields in `registry.yaml`:

* `development`: internal or experimental, may change without notice.
* `stable`: public API, changes require a deprecation cycle.
* `deprecated`: kept for backward compatibility, will be removed in a future major version.

Weaver's code generator can use these levels to emit deprecation warnings in generated code and to omit deprecated metrics from new generation targets. This gives Prometheus a formalized metric evolution model: a stable metric cannot be removed without a schema change that goes through proposal review, and the schema change is auditable in git history.

### Rego validation policies

A set of [OPA Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) policies validates each `registry.yaml` before code generation. Where those policies are hosted is part of the open question on template hosting below.

* Every `histogram` instrument must declare `annotations.prometheus.histogram_type`.
* Valid values for `histogram_type` are `classic_histogram`, `native_histogram`, `mixed_histogram`, `summary`.
* Classic and mixed histograms must declare `buckets` or `exponential_buckets`.
* Native and mixed histograms must declare `bucket_factor`, `max_bucket_number`, `min_reset_duration`.

Validation runs as part of the generation step and fails the build if any registry violates the policies.

### Open questions

* **`.With()` allocations on hot paths**: The generated `.With()` method allocates a `prometheus.Labels` map on each call. For high-frequency paths such as per-scrape counters or per-sample append metrics, this may be too expensive. A typed `WithX(value string)` fast path should be benchmarked before broad rollout. See the related [reviewer comment](https://github.com/prometheus/prometheus/pull/17868#discussion_r2716984753).

* **Contract testing coverage**: Many Prometheus metrics are only emitted when specific server state is reached. Compaction metrics require a compaction to be triggered; out-of-order sample counters require out-of-order writes; per-alertmanager metrics require an alertmanager to be configured. A `live-check` run against a basic Prometheus instance will therefore not cover the full registry. Two approaches are possible: (1) build a comprehensive integration test harness that exercises all code paths before running `live-check`; (2) ensure Prometheus initializes all metric vectors at startup even if their values are zero, so the schema can be validated structurally without requiring the underlying events. The right approach needs to be decided.

* **Registry layout**: The registry could live as one `registry.yaml` per package (co-located with the package it describes, ownership is clear, changes are scoped) or as a single `registry.yaml` at the repository root (one place to look, simpler Weaver invocation, but creates a merge bottleneck and couples all metrics to a single file). The per-package layout matches how Go code is already structured and was used in the proof-of-concept, but a single-file layout may be preferable for cross-cutting concerns like stability level audits or global name uniqueness checks.

* **Template and policy hosting**: The Jinja2 templates and Rego policies that drive code generation need to live somewhere accessible at build time. Three options are under consideration: (1) in this repository under a `build/` directory, keeping everything self-contained but coupling the templates to the Prometheus server; (2) in `prometheus/client_golang`, making them reusable across the ecosystem; (3) bundled into the Weaver binary itself, which Weaver is actively developing ([weaver#1145](https://github.com/open-telemetry/weaver/pull/1145)) and would remove the hosting question entirely. This decision needs to be made before the migration can be considered stable.

* **Generated file naming**: This proposal adopts a `.gen.go` suffix (e.g. `metrics.gen.go`) to make the generated nature of these files unambiguous to tooling and contributors. This is open only to the extent that the community may prefer a different convention.

* **Package visibility**: Generated packages are currently exported. Making them `internal` would prevent accidental external imports but would complicate any cross-package metric sharing.

## Alternatives

### Hand-written schema with a custom linter

A custom linter enforces naming conventions, unit presence, and histogram type rules on existing `prometheus.NewCounter(...)` definitions, without introducing Weaver or YAML.

This solution is not chosen because a linter validates code but cannot generate documentation, drive contract tests, or express metric lifecycle. It solves only the consistency problem while leaving the schema-as-contract and ecosystem tooling problems completely unaddressed. It is also more engineering effort to build and maintain than adopting an existing tool.

### Adopt OTel SDK for instrumentation

Replace `prometheus/client_golang` with the OTel Go SDK and emit metrics via OTLP natively, using OTel's toolchain end-to-end.

This solution is not chosen because Prometheus is the reference implementation of the Prometheus data model. Using a different SDK for its own instrumentation would be surprising to contributors and would add a heavyweight dependency. This proposal deliberately keeps `client_golang` as the instrumentation layer and uses Weaver only at the schema and generation layer. The two concerns are separable.

### Publish registry as upstream OTel semantic conventions

Contribute `prometheus_*` metric definitions directly to `open-telemetry/semantic-conventions`.

This solution is not chosen because Prometheus' internal metrics describe Prometheus' own implementation, not a general convention for other software to follow. If the schema matures and becomes relevant for compatible implementations (e.g. Thanos, Mimir), contributing upstream is a natural follow-on. It is not a prerequisite.

## Action Plan

To be defined based on community feedback and resolution of the open questions above.
