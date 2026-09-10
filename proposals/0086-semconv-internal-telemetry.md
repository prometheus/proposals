# Prometheus Internal Telemetry as an OTel Semantic Convention Registry

* **Owners:**
  * Nicolas Takashi [@nicolastakashi](https://github.com/nicolastakashi) [nicolas.takashi@coralogix.com](mailto:nicolas.takashi@coralogix.com)
  * Arthur Silva Sens [@ArthurSens](https://github.com/ArthurSens) [arthursens2005@gmail.com](mailto:arthursens2005@gmail.com)

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [WIP: Prometheus semconvs](https://github.com/prometheus/prometheus/pull/17868)

* **Other docs or links:**
  * [Dev Summit notes: internal telemetry consensus](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit?tab=t.0#bookmark=id.ojugisgspwvq)
  * [OTel Semantic Convention specification](https://opentelemetry.io/docs/specs/semconv/): YAML schemas describing telemetry, with tooling to generate code and docs from them.
  * [OpenTelemetry Weaver](https://github.com/open-telemetry/weaver): the toolchain that resolves, validates, and renders those schemas.

> TL;DR: Define the metrics Prometheus itself owns in one [OTel semantic convention registry](https://opentelemetry.io/docs/specs/semconv/). Generate the instrumentation code and the docs from it, check the code against it in CI, and publish it so downstream projects can check their own references.

## Why

Prometheus' internal metrics are `client_golang` constructor calls scattered across dozens of files. Nothing describes them in machine-readable form, which costs us four ways:

* Dashboard and alert authors reverse-engineer it from Go source or a live instance.
* Nothing separates stable metrics from implementation details, so renames and semantic changes ship unannounced.
* Documentation is hand-written, with nothing keeping it honest.
* No test notices when a code change alters which metrics exist or what labels they carry.

### Pitfalls of the current solution

Help strings are inconsistent, some describing counter semantics and some the event counted. Histogram buckets are picked ad hoc and most metrics carry no unit. Nothing marks a metric experimental, stable, or deprecated in a way tooling can act on. Thanos, Mimir, and every dashboard built on our internals can only check against a live instance, and only for whatever that instance happened to emit.

## Goals

* [Required] One machine-readable registry describes every Prometheus-owned metric, in the sense fixed under Scope. The Go code stops being a second source of truth.
* [Required] No hand-written metric descriptors. Instrumentation code comes from the registry.
* [Required] Generated documentation, which therefore cannot drift.
* [Required] A CI check that catches drift between the registry and the binary, with no OTel Collector and no Weaver binary in the test path.
* [Required] Maturity (`development`, `stable`) and structured deprecation as schema fields, so lifecycle changes are reviewable.
* [Nice to have] A base for multi-language generation and ecosystem tooling built on the same registry.

### Audience

Prometheus maintainers and contributors. Operators who build dashboards and alerts on these metrics. OTel tools that consume our telemetry.

## Non-Goals

* Changing metric names, labels, or semantics. It changes how metrics are defined, not what they measure.
* Adopting the OTel SDK. `client_golang` stays the instrumentation layer.
* Owning metrics whose descriptors a dependency defines, including `go_*`, `process_*`, and `promhttp_*`, even though we register them.
* Settling whether `prometheus_build_info` is an exception to that rule. Scope explains the case; until it is decided the metric stays out.
* Migrating exporters or other ecosystem projects.
* Publishing the registry as upstream OTel semantic conventions.

## How

### Scope

A metric is ours when the server binary exposes it *and* its descriptor is defined in this repository. Both halves matter. The second excludes `go_*`, `process_*`, and `promhttp_*`, whose metadata we do not define. Two of them are not even a fixed surface: `go_*` varies with the Go version and with the `WithGoCollectorRuntimeMetrics` options at `cmd/prometheus/main.go:379-388`, and `process_*` is registered on Linux only (`client_golang/prometheus/registry.go:46-47`). The first excludes descriptors defined here but never served: `documentation/examples/remote_storage/remote_storage_adapter` alone defines `received_samples_total`, `sent_samples_total`, `failed_samples_total`, and `prometheus_influxdb_ignored_samples_total`. Deciding by descriptor definition rather than name prefix also means no tool has to guess whether an unfamiliar family is ours.

`prometheus_build_info` is the one case on the line: its descriptor lives in `client_golang/prometheus/collectors/version`, but we choose its namespace at `cmd/prometheus/main.go:155` and our own mixin queries it. The rule above excludes it and it stays excluded until we decide otherwise, which is a decision worth making explicitly rather than by omission — adopting it would mean describing metadata we can detect changing but cannot change.

### The registry

One `semconv/registry.yaml` describes every metric in scope above. A single file keeps name uniqueness and stability audits trivial and gives consumers one artifact to fetch. Split it per package later if it gets unwieldy.

```yaml
groups:
  - id: metric.prometheus_tsdb_compaction_duration_seconds
    type: metric
    stability: development
    brief: Duration of compaction runs.
    metric_name: prometheus_tsdb_compaction_duration_seconds
    instrument: histogram
    unit: s
    annotations:
      prometheus:
        package: tsdb
        help: Duration of compaction runs
        histogram_type: mixed_histogram
        exponential_buckets: {start: 1, factor: 2, count: 14}
        bucket_factor: 1.1
        max_bucket_number: 100
        min_reset_duration: "1h"

  - id: attr.prometheus.scrape
    type: attribute_group
    brief: Attributes for scrape metrics.
    attributes:
      - id: prometheus.scrape.interval
        type: string
        stability: development
        brief: The configured scrape interval the observation belongs to.
        examples: ["15s", "1m"]
        annotations:
          prometheus:
            label_name: interval

  - id: metric.prometheus_target_interval_length_seconds
    type: metric
    stability: development
    brief: Actual intervals between scrapes.
    metric_name: prometheus_target_interval_length_seconds
    instrument: histogram
    unit: s
    attributes:
      - ref: prometheus.scrape.interval
    annotations:
      prometheus:
        package: scrape
        help: Actual intervals between scrapes.
        histogram_type: summary
        objectives: {0.01: 0.001, 0.05: 0.005, 0.5: 0.05, 0.90: 0.01, 0.99: 0.001}
```

Go code, documentation, and the contract test all derive from this file. `annotations.prometheus` carries what OTel has no field for: the owning package, the `client_golang` help string, each attribute's Prometheus label name, the histogram variant and its bucket or objective configuration, callback gauges, and construction-time labels.

Two fields hold the same sentence on purpose. `brief` follows OTel conventions, terminal period included; `annotations.prometheus.help` is the `client_golang` `Help` string verbatim and is what the contract test compares. Without the split, `prometheus_tsdb_compaction_duration_seconds` fails on punctuation alone — its help is `Duration of compaction runs`, no period (`tsdb/compact.go:121-128`). A policy keeps the two in step.

Labels are OTel attributes, but an attribute ID names a *concept* while a label name is a *wire name*. WAL record type and appended-sample type both carry `label_name: type` and mean different things, so they need separate definitions rather than one shared `type`. Each attribute gets a namespaced ID and records its label name in `annotations.prometheus.label_name`, which Weaver preserves in the resolved output. The examples propose `prometheus.<package>.<label>` for attribute IDs and `attr.<namespace>` for their group IDs; confirm both before the first package lands, since they set precedent across roughly 250 metrics and are churn to change afterwards.

Generated output lands in `<package>/internal/semconv/` as `metrics.gen.go` and `README.md`. `internal` keeps generated types out of the public API and `.gen.go` marks their origin, both per review feedback on the [proof-of-concept](https://github.com/prometheus/prometheus/pull/17868). Templates and policies are not committed here; see the hosting question.

### Instrumentation code generation

Weaver renders the registry into typed Go through Jinja2 templates. A Makefile target regenerates everything and CI fails on drift.

Labelled metrics get a typed `.With()` taking a sealed per-metric interface, so a wrong label is a compile error:

```go
func (m PrometheusTargetIntervalLengthSeconds) With(
    interval IntervalAttr,
    extra ...PrometheusTargetIntervalLengthSecondsAttr,
) prometheus.Observer { ... }
```

Unlabelled metrics get a plain constructor and `const_labels` become constructor parameters. For `GaugeFunc`, the value comes from a closure at scrape time, so the registry marks it `only_opts: true`, Weaver emits only an `Opts()` accessor, and the closure stays hand-written. Custom collectors use generated descriptor factories while keeping their collection-time metric creation hand-written.

Package code imports these types from `<package>/internal/semconv`. The generated API shape is not settled; we fix it while migrating the first package.

The same Weaver run also emits a `README.md` per package covering name, type, unit, label semantics, stability, and examples for every metric. Same input as the code, so the two cannot disagree.

### Contract testing

A Go test compares what the code declares against the registry, with supplemental collection fixtures for information descriptors cannot expose. No running Prometheus, nothing installed.

For registered checked collectors, `Collector.Describe()` yields a descriptor for every declared metric, sample or no sample. The test reads descriptors from a Go registry populated through production construction and registration paths, then compares them to the semantic convention registry. This needs read-only accessors on `prometheus.Desc`, which today exposes only `Err()` and `String()`. Additive, no new dependencies.

`Desc` must also store and expose metric type, populated by typed constructors. This distinguishes counter, gauge, summary, and histogram, catching a gauge-to-counter change even in a vector with no children. Classic, native, and mixed histograms all report `HISTOGRAM`, so descriptor comparison cannot distinguish those representations or validate their bucket configuration. `prometheus.NewDesc` continues to report `UNTYPED`; the custom collectors using it need the supplemental type checks below.

Units need care in the other direction. `prometheus.Opts` has a `Unit` field and no Prometheus metric sets it, so every descriptor reports an empty unit while the registry declares the real one. The first phase keeps the registry's unit as metadata and requires the descriptor's to stay empty, reporting any non-empty value as a difference — an attempt to populate `Opts.Unit` becomes visible rather than silently unchecked, and no package waits on a repository-wide edit. That edit is observable, not cosmetic: `Opts.Unit` reaches the descriptor hash, `MetricFamily.Unit`, and `# UNIT` in OpenMetrics, and from there scrape and TSDB metadata, remote write, and `/api/v1/metadata`. Names are unaffected; the encoder only rewrites `_total` on counters.

The comparison runs per package, not over one global surface. Each migrated package builds its collectors in deterministic fixtures and compares the union of their descriptors against the registry entries whose `annotations.prometheus.package` names it. That value is a repository-relative package directory — `tsdb`, `scrape`, `tsdb/wlog` — so it doubles as the `<package>/internal/semconv/` output path generation already needs. Where collectors depend on configuration, table-driven fixtures cover the supported variants: a metric need not appear in every variant, but the union must equal that package's declared surface. This is the same group annotation generation needs in order to know which package owns a metric, so one annotation serves both.

Declarations beat scrapes, because a running instance emits much less than it declares. Configure no Alertmanager and the notifier's per-alertmanager metrics never appear. `Describe()` returns them anyway, with the const-versus-variable label split that a scrape drops. It also carries a unit field, though as noted above nothing populates it today.

It also catches a metric nobody registered. Delete one collector from a `MustRegister` call and it compiles, `go vet` stays quiet, regeneration produces no diff, and the metric never exists at runtime. Generation cannot help, because the wiring is hand-written.

Supplemental fixtures call `Registry.Gather()` directly and inspect its protobuf results. For histograms, they instantiate vector children, record deterministic observations, and check each gathered histogram's classic and native representations against `histogram_type`. Native schema presence identifies native data, including schema zero. Configured finite classic buckets identify the classic representation; an optional `+Inf` bucket carrying an exemplar alone does not establish mixed-histogram mode. Removing either representation from a declared mixed histogram must fail. These checks establish the representation; they do not claim to validate every construction option, such as bucket limits or reset durations.

The three `NewDesc` sites in scrape metadata (`scrape/metrics.go`) and file timestamps (`discovery/file/file.go`) retain their custom collection logic and use generated descriptors. Descriptor comparison checks names, help, labels, and the empty-unit requirement. Their `UNTYPED` descriptor result means declaration-time type information is unavailable; the expected emitted type still comes from the registry and is checked against gathered metric families. A custom collector changing its emitted gauge to a counter must fail even though its descriptor is unchanged.

Sample coverage is tracked separately from the full descriptor inventory. The fixtures must collectively produce every custom or histogram family requiring supplemental checks in at least one populated case, validate every exercised configuration, and fail on missing coverage or gathering errors. Empty or removal cases can legitimately emit no samples while retaining their descriptors. Custom-collector fixtures cover empty, populated, and removed jobs or files: removed sources stop producing their former series, while a configured scrape job with no targets retains its existing zero-valued metadata metrics.

The test reads a flat, already-resolved registry, leaving `ref`, `extends`, imports, and group merging to Weaver at authoring time. It catches drift before it ships, but tells a deployed downstream nothing about how to follow a rename. That needs a versioned rename schema per release, a follow-on.

### Metric lifecycle and evolution

`registry.yaml` carries OTel stability levels: `development` for anything that may change without notice and `stable` for public API needing a deprecation cycle. Deprecation is a separate structured field rather than a third level: the `deprecated` stability value still parses, but upstream marks it deprecated, and the structured field carries a reason (`renamed`, `obsoleted`, `uncategorized`) plus `renamed_to` for a rename. A deprecated metric therefore keeps its maturity and gains that field. Weaver can emit deprecation warnings from these, and removing a stable metric requires a schema change visible in review and in git history.

This proposal adds the field and makes changes to it reviewable. It does not define what `stable` obligates, how long a deprecation cycle runs, or which of today's metrics qualify. That is policy, not schema, and marking a metric `stable` commits us to compatibility we have never promised. Migrated metrics carry `development` until a follow-on decides otherwise.

### What "across the ecosystem" means

Downstream projects hardcode our internal metric names and learn about a change when a user reports a dead panel. [`samber/awesome-prometheus-alerts`](https://github.com/samber/awesome-prometheus-alerts) hardcodes 37 distinct `prometheus_*` names across roughly 1,150 rule entries, spanning the same packages this proposal migrates. [`perses/community-mixins`](https://github.com/perses/community-mixins) writes metric names into Go queries. Neither can validate those references against anything.

A published registry gives them something to read. A mixin can compare its references against the declared metrics and fail its own CI when one stops resolving, changes type or unit, or loses a label it groups by. That runs on the consumer's schedule and needs nothing from us beyond a fetchable registry. Exporters adopting the format get the same, though migrating them is out of scope.

So "safe metric evolution across the ecosystem" means consumers detect drift themselves, and nothing more.

### Rego validation policies

[OPA Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) policies validate the registry during generation and fail the build on a violation:

* Every `histogram` declares `annotations.prometheus.histogram_type`, one of `classic_histogram`, `native_histogram`, `mixed_histogram`, `summary`.
* Classic and mixed histograms declare `buckets` or `exponential_buckets`.
* Native and mixed histograms declare `bucket_factor`, `max_bucket_number`, and `min_reset_duration`.
* Summaries declare `objectives`, the one variant in that enum with no rule behind it today.
* Every metric declares `annotations.prometheus.package`, and every metric attribute declares `label_name`.

### Open questions

* **`.With()` allocations on hot paths**: `.With()` allocates a `prometheus.Labels` map per call, likely too much for per-scrape or per-sample metrics. Benchmark a typed `WithX(value string)` fast path first ([reviewer comment](https://github.com/prometheus/prometheus/pull/17868#discussion_r2736198866)).

* **Validator module home**: the `client_golang` changes are limited to `Desc` metadata accessors and metric type storage populated by typed constructors. Supplemental collection checks use the existing `Registry.Gather()` API. Registry parsing stays out, because `client_golang` is one module with no nested `go.mod`, so a schema package there would push YAML and OTel-schema dependencies onto nearly every exporter. It could live in a nested module there, a new repository under `prometheus`, or elsewhere. Blocks nothing else.

* **Template and policy hosting**: in this repository under `build/`, in `client_golang` for ecosystem reuse, or bundled into Weaver itself ([weaver#1145](https://github.com/open-telemetry/weaver/pull/1145)), which would end the question. Decide before the migration is stable.

## Alternatives

### Use Weaver `live-check` for contract testing

Weaver ships `registry live-check`. Route a running Prometheus through a Collector (Prometheus receiver → OTLP exporter) into it and contract testing needs no new code.

Three problems. It checks post-translation telemetry, so the registry describes the OTLP form rather than what Prometheus emits, and a translation bug fails the check as if the registry were wrong. It puts a Collector in the test harness, for us and for every consumer. It needs the Weaver binary at test time, turning a Rust toolchain maintainers install once to generate into one every contributor installs to run tests. A Go test reading `Describe()` needs none of that.

### Hand-written definitions with linting only

Keep the constructor calls and enforce naming, units, and histogram rules with `promlint`, which wires into any registry through `testutil.GatherAndLint`. A linter has no notion of which metrics are *supposed* to exist, so it misses a removal, a rename, or a new label, which are the changes that break consumers. It also cannot generate documentation or hold a lifecycle.

### Generate the registry from instrumentation code

Invert the direction: emit `registry.yaml` from the binary using the same `Desc` introspection and commit it as a golden file, the way Go tracks its own API in `api/go1.*.txt`. CI fails on a diff.

This costs contributors almost nothing and gives regression safety on its own. It is not chosen because the registry stops being authoritative: help text, units, and stability go back to living inline in Go with nothing enforcing them, and there is no schema to generate docs from or hang a lifecycle on. It stays available as a fallback.

### Adopt OTel SDK for instrumentation

Prometheus is the reference implementation of its own data model. Instrumenting it with a different SDK would surprise contributors and add a heavy dependency. Weaver stays at the schema layer, `client_golang` at the instrumentation layer.

### Publish registry as upstream OTel semantic conventions

These metrics describe Prometheus' own implementation, not a convention for others to follow. If the schema matures and fits Thanos or Mimir, contributing upstream is a follow-on rather than a prerequisite.

## Action Plan

* [ ] Get consensus on this proposal.
* [ ] Add `Desc` metadata accessors and metric type storage to `client_golang`, populated by typed constructors while `NewDesc` remains untyped.
* [ ] Write `semconv/registry.yaml` by hand, package by package.
* [ ] Build in-process contract testing with descriptor inventory checks and supplemental collection fixtures for histogram representations and custom-collector types, one package at a time, and run it in CI.
* [ ] Generate code for one small package and settle the generated API there.
* [ ] Benchmark `.With()` before touching hot paths.
* [ ] Generate the rest, one pull request per package.
* [ ] Add the Makefile target and CI check that generated files match the registry.
