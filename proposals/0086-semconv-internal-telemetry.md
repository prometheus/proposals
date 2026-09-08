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

> TL;DR: Define every metric the Prometheus binary exports in one [OTel semantic convention registry](https://opentelemetry.io/docs/specs/semconv/). Generate the instrumentation code and the docs from it, check the code against it in CI, and publish it so downstream projects can check their own references.

## Why

Prometheus' internal metrics are `client_golang` constructor calls scattered across dozens of files. Nothing describes them in machine-readable form, which costs us four ways:

* Dashboard and alert authors reverse-engineer it from Go source or a live instance.
* Nothing separates stable metrics from implementation details, so renames and semantic changes ship unannounced.
* Documentation is hand-written, with nothing keeping it honest.
* No test notices when a code change alters which metrics exist or what labels they carry.

### Pitfalls of the current solution

Help strings are inconsistent, some describing counter semantics and some the event counted. Histogram buckets are picked ad hoc and most metrics carry no unit. Nothing marks a metric experimental, stable, or deprecated in a way tooling can act on. Thanos, Mimir, and every dashboard built on our internals can only check against a live instance, and only for whatever that instance happened to emit.

## Goals

* [Required] One machine-readable registry describes every metric Prometheus exposes. The Go code stops being a second source of truth.
* [Required] No hand-written metric descriptors. Instrumentation code comes from the registry.
* [Required] Generated documentation, which therefore cannot drift.
* [Required] A CI check that catches drift between the registry and the binary, with no OTel Collector and no Weaver binary in the test path.
* [Required] Stability (`development`, `stable`, `deprecated`) as a schema field, so lifecycle changes are reviewable.
* [Nice to have] A base for multi-language generation and ecosystem tooling built on the same registry.

### Audience

Prometheus maintainers and contributors. Operators who build dashboards and alerts on these metrics. OTel tools that consume our telemetry.

## Non-Goals

* Changing metric names, labels, or semantics. It changes how metrics are defined, not what they measure.
* Adopting the OTel SDK. `client_golang` stays the instrumentation layer.
* Migrating exporters or other ecosystem projects.
* Publishing the registry as upstream OTel semantic conventions.

## How

### The registry

One `semconv/registry.yaml` describes every metric the binary exposes. A single file keeps name uniqueness and stability audits trivial and gives consumers one artifact to fetch. Split it per package later if it gets unwieldy.

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

Go code, documentation, and the contract test all derive from this file. `annotations.prometheus` carries what OTel has no field for: histogram variant, buckets, callback gauges, and construction-time labels.

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

Unlabelled metrics get a plain constructor and `const_labels` become constructor parameters. `GaugeFunc` is the exception: its value comes from a closure at scrape time, so the registry marks it `only_opts: true`, Weaver emits only an `Opts()` accessor, and the closure stays hand-written.

Package code imports these types from `<package>/internal/semconv`. The generated API shape is not settled; we fix it while migrating the first package.

The same Weaver run also emits a `README.md` per package covering name, type, unit, label semantics, stability, and examples for every metric. Same input as the code, so the two cannot disagree.

### Contract testing

A Go test compares what the code declares against the registry. No running Prometheus, nothing installed.

`Collector.Describe()` yields a descriptor for every metric a collector declares, sample or no sample. The test registers the collectors, reads the descriptors, and compares them to the registry. This needs accessors on `prometheus.Desc`, which today exposes only `Err()` and `String()`. Additive, no new dependencies.

Declarations beat scrapes, because a running instance emits much less than it declares. Configure no Alertmanager and the notifier's per-alertmanager metrics never appear. `Describe()` returns them anyway, with the unit and the const-versus-variable label split that a scrape drops.

It also catches a metric nobody registered. Delete one collector from a `MustRegister` call and it compiles, `go vet` stays quiet, regeneration produces no diff, and the metric never exists at runtime. Generation cannot help, because the wiring is hand-written.

The test reads a flat, already-resolved registry, leaving `ref`, `extends`, imports, and group merging to Weaver at authoring time. It catches drift before it ships, but tells a deployed downstream nothing about how to follow a rename. That needs a versioned rename schema per release, a follow-on.

### Metric lifecycle and evolution

`registry.yaml` carries OTel stability levels: `development` for anything that may change without notice, `stable` for public API needing a deprecation cycle, `deprecated` for metrics kept until a major version drops them. Weaver can emit deprecation warnings from these, and removing a stable metric requires a schema change visible in review and in git history.

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

### Open questions

* **`.With()` allocations on hot paths**: `.With()` allocates a `prometheus.Labels` map per call, likely too much for per-scrape or per-sample metrics. Benchmark a typed `WithX(value string)` fast path first ([reviewer comment](https://github.com/prometheus/prometheus/pull/17868#discussion_r2716984753)).

* **Validator module home**: the `Desc` accessors are the only `client_golang` change proposed here. Registry parsing stays out, because `client_golang` is one module with no nested `go.mod`, so a schema package there would push YAML and OTel-schema dependencies onto nearly every exporter. It could live in a nested module there, a new repository under `prometheus`, or elsewhere. Blocks nothing else.

* **Mapping registry entries to packages**: generation needs to know which package owns each metric. A group annotation is the obvious mechanism; the shape is an implementation detail.

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
* [ ] Add `Desc` accessors to `client_golang` so declared metrics can be read.
* [ ] Write `semconv/registry.yaml` by hand, package by package.
* [ ] Build in-process contract testing, one package at a time, and run it in CI.
* [ ] Generate code for one small package and settle the generated API there.
* [ ] Benchmark `.With()` before touching hot paths.
* [ ] Generate the rest, one pull request per package.
* [ ] Add the Makefile target and CI check that generated files match the registry.
