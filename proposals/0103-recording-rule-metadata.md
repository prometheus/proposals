## Recording Rule Metadata Storage and Deduction

* **Owners:**
  * Bartek Plotka [@bwplotka](https://github.com/bwplotka)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/20027
  * https://github.com/prometheus/prometheus/issues/11969
  * https://github.com/prometheus/prometheus/pull/17864
  * https://github.com/prometheus/prometheus/pull/19555
  * https://github.com/prometheus/prometheus/pull/19563
  * https://github.com/prometheus/prometheus/issues/17632

* **Other docs or links:**
  * [PROM-39: Metric Family Identity Extension: Type and Unit as Labels](./0039-metadata-labels.md)

> TL;DR: This document proposes storing metric metadata (`type`, `unit`, `help`) for series produced by recording rules. It introduces runtime deduction algorithm (behind a feature flag or configuration option) that infers metadata from evaluated samples and preserved schema labels, paired with optional `type`, `unit`, and `help` fields in recording rule YAML definitions to override or enrich the deduced metadata.

## Why

Recording rules evaluate PromQL expressions and write the resulting samples back to storage as new time series. Today, the rule manager appends these samples without any metric metadata (`type`, `unit`, `help`).

As Prometheus evolves toward first-class metadata support through native TSDB metadata storage ([prometheus#19563](https://github.com/prometheus/prometheus/pull/19563)), Remote Write 2.0, and type-and-unit labels ([PROM-39](./0039-metadata-labels.md)), leaving recorded series without metadata creates several gaps:

1. Humans and AI tools rely on `/api/v1/metadata` (and UIs such as Grafana's metrics explorer) to discover metrics, understand what a pre-computed recording rule represents, and autocomplete PromQL queries. Recorded series are currently invisible in `/api/v1/metadata`.
2. Strongly typed backends receiving data via Remote Write 2.0 require a valid metric type for every series. Because recording rules emit `METRIC_TYPE_UNSPECIFIED` in Remote Write 2.0, receivers have to fall back to heuristics or reject recorded metrics. This is also relevant if we go with the [new RW2`stateless` modes](https://github.com/prometheus/docs/pull/3147)
3. Type-aware PromQL features (such as warning when `rate()` is applied to a non-counter, or future type-based aggregations) cannot reason about recorded series unless their type is stored.

### Pitfalls of the current solution

* Recording rule evaluation only writes sample values and labels, without deducing or storing metric metadata (`type`, `unit`, `help`) for the resulting series.
* Requiring users to manually annotate thousands of existing recording rules in YAML before getting any `type` metadata in Remote Write 2.0 or `/api/v1/metadata` is impractical.
* When `--enable-feature=type-and-unit-labels` ([PROM-39](./0039-metadata-labels.md)) is enabled, PromQL strips `__type__` and `__unit__` on any operation that drops `__name__` (such as `rate()`, `sum()`, or arithmetic). As a result, most recording rules produce series without `__type__` or `__unit__` labels, while rules that do not drop `__name__` (such as `label_replace()` or plain selectors) silently keep the input series' `__type__` and `__unit__` labels without writing corresponding `metadata.Metadata` records to the WAL.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Store metric metadata (`type`, `unit`, `help`) for all recording rule series so that WAL metadata records, Remote Write 2.0, `type-and-unit-labels`, and `/api/v1/metadata` (via [prometheus#19563](https://github.com/prometheus/prometheus/pull/19563)) receive consistent metadata.
* Provide a naive automatic type deduction mechanism that works out of the box for existing recording rules without requiring YAML changes.
* Allow users to optionally specify `type`, `unit`, and `help` in recording rule YAML files to document rules and override automatic deduction when needed.

### Audience

Prometheus server maintainers, PromQL maintainers, rule authors, and maintainers of Remote Write 2.0 / OTLP receivers and query UIs.

## Non-Goals

* Full static type and unit inference across arbitrary PromQL AST expressions (for example, deriving that dividing `bytes` by `seconds` yields `bytes_per_second`, or querying TSDB metadata during rule file parsing).
* Attaching resource or target metadata to recording rules (covered separately in proposals such as [PROM-99](https://github.com/prometheus/proposals/pull/99)).

## How

Once the rule manager migrates to `AppenderV2` ([prometheus#17632](https://github.com/prometheus/prometheus/issues/17632)), [`Group.Eval`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/rules/group.go#L598-L604) will append samples using `app.Append(0, s.Metric, 0, s.T, s.F, nil, s.H, storage.AOptions{Metadata: meta})`.

We propose rolling out recording rule metadata in two parts: automatic runtime deduction and optional YAML configuration.

### 1. Automatic metadata deduction (naive algorithm)

Behind a feature flag or configuration setting, Prometheus automatically deduces metadata for every sample `s` produced by a recording rule.

#### Why float samples can default to `gauge`, while native histograms need `CounterResetHint`

* For float samples (`s.H == nil`), almost all recording rules (`rate()`, `irate()`, `increase()`, `histogram_quantile()`, `avg()`, binary arithmetic) produce values that can increase and decrease. Even rules that aggregate counters without `rate()`, such as `sum by (job) (http_requests_total)`, do not produce true monotonic counters in Prometheus: when targets restart or series disappear, the sum decreases without a counter reset, which makes applying `rate()` to a pre-aggregated counter sum a known anti-pattern. Defaulting float samples to `gauge` is safe and accurate for the vast majority of rules.
* For native histogram samples (`s.H != nil`), marking a series as `gauge` is invalid in OpenMetrics, Remote Write 2.0, and OTLP, and breaks downstream typed backends. However, PromQL already tracks whether an evaluated native histogram is a counter histogram or a gauge histogram via `s.H.CounterResetHint` ([`model/histogram/histogram.go#L26-L33`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/model/histogram/histogram.go#L26-L33)). Functions such as `rate()`, `irate()`, `increase()`, `delta()`, `idelta()` ([`promql/functions.go#L441`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/promql/functions.go#L441)), histogram subtraction ([`promql/engine.go#L3628`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/promql/engine.go#L3628)), and negative scalar multiplication/division ([`model/histogram/float_histogram.go#L302`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/model/histogram/float_histogram.go#L302)) explicitly set `CounterResetHint = histogram.GaugeType`, and `sum()` / `avg()` preserve that hint ([`model/histogram/float_histogram.go#L2079-L2086`](https://github.com/prometheus/prometheus/blob/10f69629039e0215d056eb4948f0bd0fd22f5c89/model/histogram/float_histogram.go#L2079-L2086)). Therefore, inspecting `s.H.CounterResetHint` at runtime tells us directly whether the sample is a `gaugehistogram` or a `histogram`.

#### Algorithm

PromQL already tracks whether an expression changes the metric schema via the `DropName` flag on evaluated series and samples. Any operation that alters the metric's meaning (`rate()`, `sum()`, arithmetic, `histogram_quantile()`, `bool` comparisons) sets `DropName = true`, which strips `__name__`, `__type__`, and `__unit__` before the query returns. Conversely, if an expression only filters or relabels an existing metric (`label_replace(http_requests_total, ...)`, `topk(5, http_requests_total)`, `http_requests_total > 10`), `DropName` remains `false` (even when nested, whereas `label_replace(rate(http_requests_total[5m]), ...)` propagates `DropName = true`).

Therefore, inspecting the evaluated sample's `__name__` before overwriting it with the recording rule name tells us directly whether the sample preserved an input metric's schema (`__name__ != ""`) or was computed by a schema-changing operation (`__name__ == ""`).

For each sample `s` returned by a recording rule query:

1. Inspect preserved schema metadata on `s` before overwriting `__name__` with the rule's target name:
   * Preserved `__name__` is non-empty if and only if PromQL evaluation preserved the input metric's schema (`DropName == false`).
   * When `type-and-unit-labels` is enabled, preserved `__type__` and `__unit__` labels are already present on `s` whenever `__name__ != ""`.
   * When `type-and-unit-labels` is disabled and `__name__ != ""`, look up the preserved `__name__` in the storage metadata store ([prometheus#19563](https://github.com/prometheus/prometheus/pull/19563)) to obtain its `type` and `unit` (or fall back to naming convention suffixes such as `_total` if no metadata entry is found).
2. Determine `type`:
   1. If the rule YAML explicitly specifies `type`, use the configured `type`.
   2. Else if a preserved `type` is present and not `unknown`, use the preserved `type`.
   3. Else if `s` is a native histogram:
      * If `CounterResetHint == GaugeType`, set `type = gaugehistogram`.
      * Otherwise, set `type = histogram`.
   4. Else (`s` is a float sample), set `type = gauge`.
3. Determine `unit`:
   1. If the rule YAML explicitly specifies `unit`, use the configured `unit`.
   2. Else if a preserved `unit` is non-empty, use the preserved `unit`.
   3. Else set `unit = ""`.
4. Determine `help`:
   1. If the rule YAML explicitly specifies `help`, use the configured `help`.
   2. Else set `help = ""`.
5. Synchronize series labels and store metadata:
   1. When `type-and-unit-labels` is enabled, set `__name__`, `__type__`, and `__unit__` on the sample's labelset before checking for duplicate output series.
   2. When `type-and-unit-labels` is disabled, strip any reserved `__type__` and `__unit__` labels from the sample's labelset and set only `__name__`.
   3. Store the resulting `(type, unit, help)` metadata alongside the sample in storage.

```mermaid
flowchart TD
    A["Evaluated sample s from PromQL query"] --> B{"Rule YAML defines type?"}
    B -- Yes --> C["Use YAML type"]
    B -- No --> D{"Did __name__ survive eval (DropName == false)?"}
    D -- Yes --> E["Use __type__ label or lookup orig __name__ metadata"]
    E --> F{"Found preserved type?"}
    F -- Yes --> G["Use preserved type"]
    F -- No --> H{"Is s a native histogram?"}
    D -- No --> H
    H -- No --> I["Type = gauge"]
    H -- Yes --> J{"CounterResetHint == GaugeType?"}
    J -- Yes --> K["Type = gaugehistogram"]
    J -- No --> L["Type = histogram"]
    C --> M["Sync schema labels (if type-and-unit-labels) & store metadata"]
    G --> M
    I --> M
    K --> M
    L --> M
```

### 2. Optional YAML extension for recording rules

Extend recording rule YAML definitions with optional `help`, `type`, and `unit` fields:

```yaml
groups:
  - name: example
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
        help: "Per-job HTTP request rate over 5 minutes."
        type: gauge
        unit: requests_per_second
```

Validation rules in `rulefmt` and `promtool check rules`:

* `help`, `type`, and `unit` are only allowed on recording rules (`record:` is set). Setting them on an alerting rule (`alert:` is set) returns a validation error because alerting rules use `annotations` and do not record user-named metrics.
* If `type` is non-empty, it must be a valid OpenMetrics / Prometheus `model.MetricType` (`counter`, `gauge`, `histogram`, `gaugehistogram`, `summary`, `info`, `stateset`, `unknown`).

### 3. Edge cases

#### Recording rules that only `label_replace` or select an existing metric

A user can write a recording rule that does not change the metric's semantics or drop `__name__`, such as:

```yaml
- record: cluster:http_requests_total
  expr: label_replace(http_requests_total, "cluster", "$1", "instance", "(.*):.*")
```

or a simple filter:

```yaml
- record: prod:http_requests_total
  expr: http_requests_total{env="prod"}
```

How does the algorithm detect and handle this from `Eval`?

* PromQL's `DropName` tracking already distinguishes `label_replace(http_requests_total, ...)` (`DropName == false`, so the evaluated sample still carries `__name__="http_requests_total"`) from `label_replace(rate(http_requests_total[5m]), ...)` (`DropName == true`, because `label_replace` propagates the inner expression's `DropName`, stripping `__name__`).
* Before overwriting `__name__` with the recording rule's target name, we inspect the original `__name__` on the evaluated sample:
  * When `type-and-unit-labels` is enabled and the original `__name__` is non-empty, the sample already carries the preserved `__type__` and `__unit__` labels from the input series.
  * When `type-and-unit-labels` is disabled and the original `__name__` is non-empty, we still know the exact input metric family name from the sample and can query the TSDB metadata store ([prometheus#19563](https://github.com/prometheus/prometheus/pull/19563)) for its `type` and `unit` (falling back to naming convention suffixes such as `_total`, `_count`, `_sum`, `_bucket`, or `gauge` if no metadata is stored).

#### Inconsistency in `without` vs `by` aggregations with `type-and-unit-labels`

PromQL currently handles `without` and `by` inconsistently when `type-and-unit-labels` is enabled:

* `by (job)` keeps only the grouping labels, which drops `__name__`, `__type__`, and `__unit__`.
* `without (instance)` deletes the excluded labels and `__name__`, but accidentally keeps `__type__` and `__unit__`. For example, `count without (instance) (http_requests_total)` currently retains `__type__="counter"` and `__unit__="requests"`, violating [PROM-39](./0039-metadata-labels.md) ("When a query drops the metric name in an effect of an operation or function, `__type__` and `__unit__` will also be dropped").

`without` aggregations must drop all metadata labels (`__name__`, `__type__`, `__unit__`) just like `by` aggregations.

#### Alerting rules leaking `__type__` and `__unit__` into `ALERTS` and `ALERTS_FOR_STATE`

When `type-and-unit-labels` is enabled and an alerting rule expression does not drop `__name__` (such as `http_errors_total > 10`), the resulting `ALERTS` and `ALERTS_FOR_STATE` time series currently inherit `__type__` and `__unit__` from `http_errors_total` because only `__name__` is stripped when constructing alert labels.

Alerting rule evaluation must strip reserved metadata labels (`__type__`, `__unit__`) and record `ALERTS` and `ALERTS_FOR_STATE` with `type = gauge` metadata.

#### Synchronizing schema labels, duplicate detection, and staleness tracking

When `type-and-unit-labels` is enabled, setting `__name__`, `__type__`, and `__unit__` on the evaluated sample's labelset before duplicate detection and staleness tracking ensures:

1. If a rule combines two series that only differed by their input `__type__` or `__unit__` (for example via `or`), overriding their metadata to the recording rule's single `type` and `unit` is caught immediately as a duplicate recording labelset during rule evaluation.
2. Staleness tracking across rule evaluations retains the exact labelset (including `__type__` and `__unit__`) needed to write `StaleNaN` markers when a recorded series disappears on a subsequent evaluation.

#### Conflict between explicit YAML `type` and runtime sample type

Because PromQL vector expressions can evaluate to either float samples or native histogram samples depending on the data in TSDB, `promtool check rules` cannot always verify at parse time whether an expression returns a float or a native histogram. If a user configures `type: gauge` or `type: counter` in YAML, but the expression evaluates at runtime to a native histogram, or configures `type: histogram` on a rule that evaluates to a float, the runtime type deduced from the sample takes precedence (or fails the rule evaluation with an error) so that Prometheus never writes a float sample with `histogram` metadata or a native histogram sample with `gauge` metadata.

#### `/api/v1/rules` vs `/api/v1/metadata`

In `/api/v1/rules`, the recording rule JSON object already uses `"type": "recording"` to distinguish recording rules from `"type": "alerting"`. Once [prometheus#19563](https://github.com/prometheus/prometheus/pull/19563) lands, `/api/v1/metadata` will automatically serve the recording rule's metadata from TSDB storage. If we also expose the configured metadata in `/api/v1/rules`, it should be placed under a nested `metadata` field (or `metricType`, `unit`, `help`) to avoid colliding with `"type": "recording"`.

## Alternatives

### 1. Only support explicit YAML metadata (no automatic deduction)

We could only write metadata when a user explicitly configures `type`, `unit`, or `help` in the rule YAML, as proposed in [prometheus#17864](https://github.com/prometheus/prometheus/pull/17864) and [prometheus#19555](https://github.com/prometheus/prometheus/pull/19555).

We did not choose this as the sole mechanism because existing deployments have thousands of recording rules defined in mixins and community rule packs. Without automatic deduction, all existing recording rules would continue to emit `unknown` / unspecified types to Remote Write 2.0, OTLP receivers, and `/api/v1/metadata` until every rule file is manually edited.

### 2. Nested `metadata:` block in YAML vs flat fields

[prometheus#17864](https://github.com/prometheus/prometheus/pull/17864) proposed nesting `type`, `help`, and `unit` under a `metadata:` key in YAML, whereas [prometheus#19555](https://github.com/prometheus/prometheus/pull/19555) proposed top-level fields on the rule object.

Top-level `help`, `type`, and `unit` fields on the recording rule are flatter, match the existing `labels` and `annotations` style in `rulefmt`, and map 1:1 to `metadata.Metadata`. However, a nested `metadata:` block is also viable if maintainers prefer grouping metadata fields together.

### 3. Static AST-based type and unit inference

Instead of (or in addition to) runtime sample inspection, the rule manager could walk the PromQL AST (`parser.Expr`) to infer types and units (for example, inferring `counter` for `sum(my_counter_total)` or inferring `seconds` for `histogram_quantile(0.9, rate(http_request_duration_seconds_bucket[5m]))`).

We defer deep AST inference because:

* Without querying TSDB metadata at rule load time, the AST alone does not know the types or units of the input vector selectors.
* Even `sum(my_counter_total)` is not a monotonic counter when series churn occurs, so inferring `counter` from `sum()` can mislead downstream consumers.
* The naive runtime check (`s.H == nil` vs `s.H.CounterResetHint`, plus preserved `__type__`/`__unit__` labels) handles float gauges, counter histograms, gauge histograms, and `label_replace` rules with minimal code complexity.

## Action Plan

* [ ] Pass metadata when appending rule samples to storage ([prometheus#17632](https://github.com/prometheus/prometheus/issues/17632)).
* [ ] Fix `without` aggregations and alerting rule evaluation so `__type__` and `__unit__` labels are not leaked when `--enable-feature=type-and-unit-labels` is enabled.
* [ ] Implement naive automatic metadata deduction for recording rules behind a feature flag / config option ([prometheus#20027](https://github.com/prometheus/prometheus/issues/20027)).
* [ ] Extend `model/rulefmt` and `promtool` with optional `help`, `type`, and `unit` fields for recording rules ([prometheus#20027](https://github.com/prometheus/prometheus/issues/20027)).
