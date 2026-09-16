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
* [Required] Stability (`development`, `stable`) and structured deprecation as schema fields, so lifecycle changes are reviewable.
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

A metric is ours when the server binary exposes it *and* we define its descriptor in this repository. Both halves matter. The second excludes `go_*`, `process_*`, and `promhttp_*`, whose metadata we do not define. Two of them are not even a fixed set. `go_*` varies with the Go version and with the `WithGoCollectorRuntimeMetrics` options `cmd/prometheus` passes, and `process_*` exists on Linux only. The first half excludes descriptors defined here but never served. `documentation/examples/remote_storage/remote_storage_adapter` alone defines `received_samples_total`, `sent_samples_total`, `failed_samples_total`, and `prometheus_influxdb_ignored_samples_total`. Deciding by descriptor definition rather than name prefix also means no tool has to guess whether an unfamiliar family is ours.

`prometheus_build_info` is the one case on the line. `client_golang` defines its descriptor, but we choose its namespace and our own mixin queries it. The rule excludes it and it stays excluded until we decide otherwise. Adopting it would mean describing metadata we can detect changing but cannot change.

### The registry

One `semconv/registry.yaml` is the authoring source for every metric in scope above, populated package by package during migration. A single file keeps name uniqueness and stability audits trivial. Split it per package later if it gets unwieldy; tests and consumers read the resolved artifact described below.

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

Two fields hold the same sentence on purpose. `brief` follows OTel conventions, terminal period included; `annotations.prometheus.help` is the `client_golang` `Help` string verbatim and is what the contract test compares. Without the split, `prometheus_tsdb_compaction_duration_seconds` fails on punctuation alone, because its help is `Duration of compaction runs`, with no period. A policy keeps the two in step.

Labels are OTel attributes, but an attribute ID names a *concept* while a label name is a *wire name*. WAL record type and appended-sample type both carry `label_name: type` and mean different things, so they need separate definitions rather than one shared `type`. Each attribute gets a namespaced ID and records its label name in `annotations.prometheus.label_name`, which Weaver preserves in the resolved output. The examples propose `prometheus.<package>.<label>` for attribute IDs and `attr.<namespace>` for their group IDs; confirm both before the first package lands, since they set precedent across roughly 250 metrics and are churn to change afterwards.

Generated output lands in `<package>/internal/semconv/` as `metrics.gen.go` and `README.md`. `internal` keeps generated types out of the public API and `.gen.go` marks their origin, both per review feedback on the [proof-of-concept](https://github.com/prometheus/prometheus/pull/17868). Templates and policies are not committed here; see the hosting question.

### Generation and publication

Check in `semconv/registry.resolved.json` alongside the authoring source in the Prometheus repository. An export template run through `weaver registry generate` writes a JSON object containing the resolved v1 `groups`, with `ref`, `extends`, imports, and group merging already resolved. Each metric carries its expanded attributes, whose `name` fields retain the semantic IDs while `annotations.prometheus.label_name` retains the wire names. Preserve the remaining definition metadata, including Prometheus annotations, stability, and structured deprecation, and keep deprecated definitions. Omit the top-level `registry_url` and each group's diagnostic `lineage`, which can contain checkout paths, and use deterministic ordering and serialization.

One Makefile target validates policies and regenerates the JSON, instrumentation, and documentation from the same registry. Pin Weaver, templates, policies, and any registry dependencies, and pin the resolved output format version explicitly rather than taking Weaver's default; format changes require corresponding exporter and reader changes. Establish the JSON generation target and its CI freshness check before the first contract test, then add code and documentation generation as packages migrate. CI regenerates all applicable output and fails on changed, missing, or unexpected generated files. Ordinary Go tests read the committed JSON and do not invoke Weaver.

Consumers fetch this same file from Prometheus Git history at a commit SHA or a release tag containing it. The first package demonstrates consumption by commit SHA; expanding migration does not wait for a release. Coverage grows as package registry entries and contract fixtures land. An omitted metric may belong to an unmigrated package or be outside this proposal's ownership scope, so absence from a partial registry alone is not proof of removal.

Before expanding migration, verify that two checkout locations produce identical generated output, that the resolved artifact preserves label annotations and lifecycle metadata, that CI rejects stale or missing generated output, and that ordinary Go contract tests pass without Weaver installed.

### Instrumentation code generation

Weaver renders the registry into typed Go through Jinja2 templates, using the generation target above.

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

A Go test compares what the code declares against the registry, plus collection fixtures for what descriptors cannot expose. No running Prometheus, nothing installed.

For registered checked collectors, `Collector.Describe()` yields a descriptor for every declared metric, sample or no sample. The test reads descriptors from a Go registry populated through production construction and registration paths, then compares them to the semantic convention registry. This needs read-only accessors on `prometheus.Desc`, which today exposes only `Err()` and `String()`. Additive, no new dependencies.

`Desc` must also store and expose metric type, populated by typed constructors. This distinguishes counter, gauge, summary, and histogram, catching a gauge-to-counter change even in a vector with no children. Classic, native, and mixed histograms all report `HISTOGRAM`, so descriptor comparison cannot distinguish those representations or validate their bucket configuration. `prometheus.NewDesc` continues to report `UNTYPED`; the custom collectors using it need the supplemental type checks below.

Units need care in the other direction. `prometheus.Opts` has a `Unit` field and no Prometheus metric sets it, so every descriptor reports an empty unit while the registry declares the real one. The first phase keeps the registry's unit as metadata and requires the descriptor's to stay empty, reporting any non-empty value as a difference. An attempt to populate `Opts.Unit` then becomes visible rather than silently unchecked, and no package waits on a repository-wide edit. That edit would change behaviour. `Opts.Unit` reaches the descriptor hash, `MetricFamily.Unit`, and `# UNIT` in OpenMetrics, and from there scrape and TSDB metadata, remote write, and `/api/v1/metadata`. Names are unaffected; the encoder only rewrites `_total` on counters.

The comparison runs per package. Each migrated package builds its collectors in deterministic fixtures and compares the union of their descriptors against the registry entries whose `annotations.prometheus.package` names it. That value is a repository-relative package directory such as `tsdb`, `scrape`, or `tsdb/wlog`, so it doubles as the `<package>/internal/semconv/` output path generation already needs. Where collectors depend on configuration, table-driven fixtures cover the supported variants. A metric need not appear in every variant, but the union must equal what that package declares. Generation needs the same annotation to know which package owns a metric, so one annotation serves both.

Declarations beat scrapes, because a running instance emits much less than it declares. Configure no Alertmanager and the notifier's per-alertmanager metrics never appear. `Describe()` returns them anyway, with the const-versus-variable label split that a scrape drops. It also carries a unit field, though as noted above nothing populates it today.

It also catches a metric nobody registered. Delete one collector from a `MustRegister` call and it compiles, `go vet` stays quiet, regeneration produces no diff, and the metric never exists at runtime. Generation cannot help, because the wiring is hand-written.

Supplemental fixtures call `Registry.Gather()` directly and inspect its protobuf results, covering the two things descriptors cannot answer. For histograms, they record deterministic observations and check the gathered classic and native representations against `histogram_type`, so removing either from a declared mixed histogram fails. For the `NewDesc` sites in scrape metadata and file discovery, which retain hand-written collection and report `UNTYPED`, they check the emitted type against the registry, so a custom collector switching a gauge to a counter fails even though its descriptor is unchanged. These checks establish the representation; they do not validate every construction option, such as bucket limits or reset durations. Fixtures must populate every family needing a supplemental check at least once and fail on missing coverage.

The test reads metric groups from the committed `semconv/registry.resolved.json`, using their package annotations to select the expected definitions. The Go reader does not resolve authoring constructs. This catches drift before it ships; applying renames for deployed downstreams needs a versioned rename schema per release, a follow-on.

### Metric lifecycle and evolution

`registry.yaml` carries OTel stability levels: `development` for anything that may change without notice and `stable` for public API needing a deprecation cycle. Deprecation is a separate structured field rather than a third level. The `deprecated` stability value still parses, but upstream marks it deprecated, and the structured field carries a reason (`renamed`, `obsoleted`, `uncategorized`) plus `renamed_to` for a rename. A deprecated metric therefore keeps its stability and gains that field. Weaver can emit deprecation warnings from these, and removing a stable metric requires a schema change visible in review and in git history.

This proposal adds the field and makes changes to it reviewable. It does not define what `stable` obligates, how long a deprecation cycle runs, or which of today's metrics qualify. That is policy, not schema, and marking a metric `stable` commits us to compatibility we have never promised. Migrated metrics carry `development` until a follow-on decides otherwise.

### What "across the ecosystem" means

Downstream projects hardcode our internal metric names and learn about a change when a user reports a dead panel. [`samber/awesome-prometheus-alerts`](https://github.com/samber/awesome-prometheus-alerts) hardcodes 37 distinct `prometheus_*` names across roughly 1,150 rule entries, spanning the same packages this proposal migrates. [`perses/community-mixins`](https://github.com/perses/community-mixins) writes metric names into Go queries. Neither has an authoritative registry of our declared metrics to check those references against.

A published registry gives them something to read. A mixin can compare its references against the declared metrics and fail its own CI when one stops resolving, changes type, or loses a label it groups by. That runs on the consumer's schedule and needs nothing from us beyond a fetchable artifact. Exporters adopting the format get the same, though migrating them is out of scope.

The registry describes metric *families*, and PromQL queries *series*, so the gap between them is the consumer's to close. A summary's `_sum`, `_count`, and `quantile` series, a classic histogram's `_bucket` and `le`, and a native histogram's single sample all follow from `histogram_type` ([histogram and summary representations](https://prometheus.io/docs/practices/histograms/)). `job` and `instance` come from scraping, relabeling can rewrite anything after exposition, and recording rules add more. So a label missing from the registry is not necessarily invalid, and a declared family may have no samples in a given configuration. This proposal publishes the family registry as input to that tooling; it does not implement a PromQL validator.

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

* **Validator module home**: the `client_golang` changes are limited to `Desc` metadata accessors and metric type storage populated by typed constructors. Supplemental collection checks use the existing `Registry.Gather()` API. Keep optional registry parsing and validation tooling separate from the broadly used main module so its dependencies can evolve independently. The repository already has an [`exp` submodule](https://github.com/prometheus/client_golang/blob/main/exp/go.mod); a separate module there, a new repository under `prometheus`, or another home could host the validator. Ordinary Go tests need only a reader for the resolved JSON, not the Weaver authoring schema resolver. Decide its home when implementing the first contract test.

* **Template and policy hosting**: in this repository under `build/`, in `client_golang` for ecosystem reuse, or bundled into Weaver itself ([weaver#1145](https://github.com/open-telemetry/weaver/pull/1145)), which would end the question. Decide before the migration is stable.

## Alternatives

### Use Weaver `live-check` for contract testing

Weaver ships `registry live-check`, which accepts OTLP and [JSON samples from a file or stdin](https://github.com/open-telemetry/weaver/blob/v0.26.1/crates/weaver_live_check/README.md#ingesters). A Collector with a Prometheus receiver and OTLP exporter is one input path. A direct adapter from Go fixtures to Weaver's JSON sample format can avoid the Collector; its text input accepts attribute names or name/value pairs, not Prometheus exposition.

Either path requires mapping Prometheus names, labels, and representations to Weaver's sample model. The Collector path also checks post-translation telemetry, so a translation bug fails the check as if the registry were wrong. Observed samples alone never establish the complete descriptor inventory, dormant vectors included, so we still write fixtures and completeness checks. Both paths put the Weaver executable in the test path, though prebuilt binaries spare contributors a Rust toolchain.

We are not choosing it. It saves none of the fixture work and checks a translated copy of the contract rather than the contract itself. Go descriptor checks keep ordinary tests independent of the authoring toolchain.

### Hand-written definitions with linting only

Keep the constructor calls and enforce naming, units, and histogram rules with `promlint`, which wires into any registry through `testutil.GatherAndLint`. A linter has no notion of which metrics are *supposed* to exist, so it misses a removal, a rename, or a new label, which are the changes that break consumers. It also cannot generate documentation or hold a lifecycle.

### Generate the registry from instrumentation code

Invert the direction: emit `registry.yaml` from the binary using the same `Desc` introspection and commit it as a golden file, the way Go tracks its own API in `api/go1.*.txt`. CI fails on a diff.

This costs contributors almost nothing and gives regression safety on its own. It can also carry lifecycle and label semantics, as long as we attach that metadata in Go or a companion source. Introspection cannot recover it, and today's empty descriptor units do not even reveal the intended unit.

That condition decides it. Code stays the authority, the metadata it cannot infer needs its own conventions and its own enforcement, and we maintain two sources anyway. Authoring the schema removes hand-written descriptors and keeps the contract in one place. This alternative stays available as a fallback.

### Adopt OTel SDK for instrumentation

Prometheus is the reference implementation of its own data model. Instrumenting it with a different SDK would surprise contributors and add a heavy dependency. Weaver stays at the schema layer, `client_golang` at the instrumentation layer.

### Publish registry as upstream OTel semantic conventions

These metrics describe Prometheus' own implementation, not a convention for others to follow. If the schema matures and fits Thanos or Mimir, contributing upstream is a follow-on rather than a prerequisite.

## Action Plan

* [ ] Get consensus on this proposal.
* [ ] Add `Desc` metadata accessors and metric type storage to `client_golang`, populated by typed constructors while `NewDesc` remains untyped.
* [ ] Write `semconv/registry.yaml` by hand, package by package.
* [ ] Add the pinned generation target for `semconv/registry.resolved.json` and its CI freshness check before the first contract test.
* [ ] Build in-process contract testing with descriptor inventory checks and supplemental collection fixtures for histogram representations and custom-collector types, one package at a time, and run it in CI.
* [ ] Generate code and documentation for one small package through the same target, extend the freshness check to those outputs, and settle the generated API there.
* [ ] Verify the generation acceptance checks above and demonstrate reading the first package's artifact by commit SHA; release tags containing the file provide release-version lookup without gating further migration.
* [ ] Benchmark `.With()` before touching hot paths.
* [ ] Generate the rest, one pull request per package.
