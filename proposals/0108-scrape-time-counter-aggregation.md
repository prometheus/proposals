## Scrape-time Aggregation (of Counters)

* **Owners:**
  * Walther Lee [@waltherlee](https://github.com/waltherlee)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/pull/67
  * https://github.com/prometheus/proposals/pull/67#issuecomment-3484840178
  * https://github.com/prometheus/prometheus/issues/394
  * https://github.com/prometheus/prometheus/pull/10529
  * https://github.com/prometheus/prometheus/pull/19563
  * https://github.com/prometheus/prometheus/issues/17109

* **Other docs or links:**
  * [Prometheus docs: recording rules best practices](https://prometheus.io/docs/practices/rules/)
  * [VictoriaMetrics stream aggregation](https://docs.victoriametrics.com/victoriametrics/stream-aggregation/) (`total`/`increase` outputs with `without`, and [aggregation windows](https://docs.victoriametrics.com/victoriametrics/stream-aggregation/#aggregation-windows), the closest prior art)
  * [M3 mapping and rollup rules](https://m3db.io/docs/operational_guide/mapping_rollup/)
  * [Grafana Cloud Adaptive Metrics](https://grafana.com/docs/grafana-cloud/adaptive-telemetry/adaptive-metrics/) (similar idea applied at ingestion)
  * OpenTelemetry Collector [metricstransform](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstransformprocessor) and [interval](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/intervalprocessor) processors

> TL;DR: Let Prometheus sum counter increments across series while they are
> ingested, removing configured labels (for example `pod`), and write the result
> on a fixed interval as an ordinary counter series. `rate()` over the
> aggregated series matches `sum without (pod) (rate(...))` over the source
> (with the differences listed in [Differences from querying the source series](#differences-from-querying-the-source-series)).
> The change touches configuration, the TSDB Head
> append path, and per-series retention of the metric type. Source series are kept,
> so this reduces query cost, not storage or ingested cardinality, and nothing on
> the query path changes.

## Why

A common query in Prometheus is some form of
`sum without/by (...) (rate(x[5m]))`, whose cost
scales with the number of series touched.

Currently, users use recording rules to aggregate these series and lower cardinality. However, for operations like `sum` in the query above, rules have 3 downsides:

1. Counters have to be converted into rates before sum to account for restarts, which hardcodes a rate interval in the query.

2. They load redundant data in every evaluation, even when only the latest sample is necessary to calculate it incrementally.

3. One rule evaluation is single-threaded. The PromQL engine evaluates a query on one goroutine and doesn't split it up internally, even for operations that could be, like `sum`.

Instead of using recording rules, the sum could be done concurrently at scrape time without `rate`, aggregating the counter's increments between consecutive samples to account for restarts at ingestion. The TSDB `Head` already knows this increment at commit time because it hold the previous value of every series in `memSeries.lastValue`.

This proposal accumulates those increases, and aggregates them into new counters grouped by label set, so that `rate()` over the output gives the same result as rate-then-sum over the source series.

The main benefit is on the query side: queries read one
series per output label set instead of every source series. The source series are still
ingested and stored, so storage grows by the aggregated series rather than
shrinking. This differs from the cardinality reduction in PROM-67, which comes from
dropping the inputs after aggregating them.

On the processing side, these aggregation are multi-threaded and use less memory than the recording rules they replace.

Glossary:

* Aggregation rule: a scrape-time aggregation configured from a subset of source series. See [Configuration](#configuration).
* Source series: an existing pre-aggregation series that matches an aggregation rule.
* Aggregated series: the output series, which has a subset of the source's labels.
* Window: an epoch-aligned interval of fixed length. An aggregated counter's increments are
  attributed to the window their sample timestamp falls in.

### Pitfalls of the current solution

* Recording rules. See the three points above.
* `labeldrop` in `metric_relabel_configs` doesn't aggregate. Series that differ
  only in the dropped label collide and are rejected as duplicates.
* PROM-67 scrape-time rules evaluate over one scrape of one target, and exclude
  `rate()`/`increase()`. That can't produce an aggregate across pods or any other label sourced from multiple targets.
* External stream aggregators (vmagent, the OTel Collector) work, but add a
  component and a network hop in front of every Prometheus, and the aggregates
  exist only downstream of it.

## Goals

* Create aggregated counters that account for resets, series churn, and late scrapes.
* Output is an ordinary counter series: `rate()`, `increase()`, remote write,
  compaction, WAL, and federation work unchanged.
* Opt-in. When disabled, the append path is unchanged.
* Make it easy to expand to more aggregation action types and metric types.
  * The only action for now is `incr_without` (sum counter increments with labels
    removed), but the rule format should allow for other parallelizable operations (min,
    max, sum, etc.) later.

### Audience

Operators of Prometheus servers where high-cardinality counters dominate query and recording-rule cost.

## Non-Goals

* Rewriting queries to use aggregated series automatically. Users query the
  aggregated series by name. Query substitution can be done
  cheaply, but it is left for a follow-up.
* Dropping the source series. Aggregation happens after samples are committed, so dropping
  them before commit would also remove them from aggregation.
  * This may be possible later if aggregation can include uncommitted samples, but that
    needs more thought.
* Gauges, native histograms, and any operation other than summing increments.

## How

```
scrape / remote write / OTLP
          │
          ▼
  Head appender Commit()
    ├─ commit metadata (type)   ◄── prerequisite
    ├─ commit float samples ──► aggregateSeries: increment = v - prev (or v on reset)
    │                                  │
    │                                  ▼
    │                 aggregatedHead: output series → per-window sums
    │                                  │
    │                 aggregationFlusher: flushes every flush_interval + grace
    │                                  │
    └───────────► Head appender ◄──────┘  (WAL, blocks, remote write as usual)
```

### Example

A service runs 200 pods, and each exposes `http_requests_total` with `path` and `code`
labels. Its dashboards and alerts all use some form of:

```promql
sum without (pod, instance) (rate(http_requests_total[5m]))
```

With Prometheus started with `--enable-feature=ingestion-aggregation --aggregation.config-file=aggregations.yml`:

```yaml
# aggregations.yml
flush_interval: 15s
aggregations:
  - source_labels: [__name__]
    regex: http_requests_total
    drop_labels: [pod, instance]
```

For source series like:

```
http_requests_total{job="api", instance="10.0.0.1:8080", pod="api-7d9f-x2k4p", path="/login", code="200"}
http_requests_total{job="api", instance="10.0.0.2:8080", pod="api-7d9f-q8w1z", path="/login", code="200"}
...
```

Prometheus writes one aggregated series per remaining label set, every 15s:

```
http_requests_total:materialized{job="api", path="/login", code="200", __aggregation_action_type="incr_without"}
```

The query becomes the following, and reads one series per `job`, `path`, and `code`
instead of 200, no matter how many pods have been replaced within the range:

```promql
rate(http_requests_total:materialized[5m])
```

### Semantics

An **aggregation rule** has a relabel-style selector (`source_labels`, `separator`,
`regex`), a list of labels to remove (`drop_labels`), an action, and a name suffix.
The only action for now is `incr_without`, which sums the increments of every matching series, with
`drop_labels` removed. A series is aggregated by the first rule that matches it.

The aggregated series has the source's labels minus `drop_labels`, the metric
name plus `suffix`, and an internal label identifying the action: `__aggregation_action_type`.
Its value is a counter whose increase over each window equals the sum of source
increments whose samples fall in that window. One sample is written per window,
stamped at the window's end.

Per source sample, the increment is `v - prev`, or `v` if `v < prev` (the same
reset rule `rate()` uses). Stale markers contribute nothing. A new series' first
sample contributes nothing, because there is no previous value. This matches what
`rate()` does with the first sample of a series too.

Example with `drop_labels: [pod]`, `flush_interval: 15s`, scrapes at `:05`, `:20`, `:35`:

| t   | `x{pod="a"}` | `x{pod="b"}` | increments in window | `x:materialized` written |
|-----|--------------|--------------|----------------------|--------------------------|
| :05 | 10           | 100          | (first samples)      |                          |
| :20 | 15           | 103          | [15s,30s): 5 + 3     | 8 at t=30s               |
| :35 | 20           | 2 (reset)    | [30s,45s): 5 + 2     | 15 at t=45s              |

Each step of `x:materialized` (8, then 7) is the sum of the source increments in that window,
including across `pod="b"`'s reset, where summing the raw values would have dropped from 118 to 22.

Only counters are aggregated, including the `_bucket`, `_sum` and `_count` series of classic
histograms and the `_sum` and `_count` series of summaries (summary quantiles are excluded). The type comes from scraped metadata, not the metric name.

Series with unknown type are not aggregated. Already-aggregated series are never
aggregated again by the same rule (see Open questions for other rules).

### Configuration

Aggregations are configured outside the global config, in a new file, using the flag `--aggregation.config-file`.

```yaml
flush_interval: <global.scrape_interval> # window width and output sample interval
stale_timeout: 5m                        # retire an aggregated series after this long without input
bucket_grace_period: 1s                  # wait after a window closes before emitting it
aggregations:
  - source_labels: [__name__]
    regex: http_requests_total|grpc_server_handled_total
    drop_labels: [pod, instance]
    action: incr_without      # default
    suffix: ":materialized"   # default
```

There are pros of having the configuration live in a separate file and be reloaded together with the main configuration. A separate file follows how rule
files work and keeps a potentially long list out of `prometheus.yml`. A top-level
block in the global config is a reasonable alternative (see [Open questions](#open-questions)).

Validation at start time and after a config reload rejects an empty `drop_labels` list, suffixes that are suffixes of each other
(which would make it ambiguous which rule an aggregated series came from), generated names that are invalid under the
configured name validation scheme, and a `bucket_grace_period` of `flush_interval` or more.
A grace period of 10% of the interval or more is accepted with a warning, because
the newest output sample then trails far enough behind that `rate()` stops
extrapolating to the end of the range.

Everything except `flush_interval` is reloadable. The interval defines the window
grid that pending state is stored on, so a change is rejected and requires a restart.

### Feature flag

The feature is gated behind `--enable-feature=ingestion-aggregation`. Without the
flag, the aggregation configuration is ignored even if `--aggregation.config-file`
is set, and the commit path is unchanged.

### Prerequisite: keep the metric type per series

The Head currently keeps metadata only with `--enable-feature=metadata-wal-records`.

This proposal keeps the type (one byte in `memSeries`) unconditionally if the `ingestion-aggregation` feature is enabled. Help, unit, and
the metadata WAL records stay behind the existing flag. Metadata is also committed before
samples in the same batch, so the first samples of a new series are aggregated with its type
already known. After a restart without metadata WAL records, the type is unknown
until the next scrape reports it, and aggregation for those series resumes from that scrape.

This requirement overlaps with [#19563](https://github.com/prometheus/prometheus/pull/19563). If that PR is merged, this
proposal would read the type from it instead.

### Accumulating increments

The hook sits in the Head's commit path for [in-order float](https://github.com/prometheus/prometheus/blob/v3.15.1/tsdb/head_append.go#L1373) samples, where the series
[lock is held](https://github.com/prometheus/prometheus/blob/v3.15.1/tsdb/head_append.go#L1379) and the previous value is [already stored](https://github.com/prometheus/prometheus/blob/v3.15.1/tsdb/head_append.go#L1913) in `memSeries`. It sees every append,
so it doesn't matter if it comes from a scrape, remote write, OTLP, or rule evaluation. Out-of-order samples are
not aggregated, since their increment relative to neighbouring samples isn't known at
commit time. WAL replay doesn't use this path, so nothing is counted twice.

However, since appends are the busiest path in Prometheus, aggregation rule conditions cannot be evaluated every single time a new
sample is committed. Each source `memSeries` has to cache the aggregated series it feeds, tagged with a generation number from the first matching aggregation rule set.
After the first sample loads the cache, following commits become just a generation check and an append.

In case of a config change, the reload bumps the generation, and series re-resolve
lazily on their next sample.

After the source samples are committed, their increments are aggregated in a new `aggregatedHead`, stored as a map in the `Head` sharded by label hash. There, each aggregated series keeps a small ring of
per-window partial sums, so an incoming sample is credited to the window of its own timestamp
rather than to whenever the flusher runs.

The accumulated window values are periodically flushed and committed to the TSDB as ordinary counter samples. Increments for windows that have already been emitted, or have been evicted
from the ring during a flush stall, go to an overflow value that is added to the next emitted window. This guarantees that increments are never lost, but degradation can move the accumulated totals to following windows.

### Flushing

A flusher goroutine runs on the epoch-aligned window grid every `flush_interval`, offset by
`bucket_grace_period`, so that scrape commits that land slightly late still count in their own
window. Each run emits every window that has closed since the last run, writing
`previous value + window sum` at the window's end timestamp through a normal `Head`
appender, in batches. Output samples go to the WAL, blocks, and remote write
like any other sample.

On every flush, an emission process is used to release the series partial sum that the flush reported but left in place until the commit succeeded.

- The pending sums are cleared after **each** successful batch commit.
  - Since commits can fail after a flush, the increments are kept pending in the window until they are committed. This way, a failed commit is retried on the next run.
- After **all** the commits succeed, aggregated series that haven't received new increments since `stale_timeout` get a stale marker in the TSDB and are removed from the `aggregatedHead`, unless they still hold unemitted increments.

### Restarts

The `aggregatedHead` lives in memory only. On restart, increments that were committed
but not yet emitted are lost, which is at most one window plus the grace period. The aggregated counter itself restarts
from zero, which `rate()` treats as an ordinary counter reset.

### Differences from querying the source series

`rate()` over an aggregated series matches `sum without (...) (rate(...))` over its
source series, except for:

* Lag: a window is written only after it closes, so the newest output sample trails
  the source series by up to `flush_interval + bucket_grace_period`.
* Resolution: there is one output sample per `flush_interval`, so a range has to
  cover at least two windows for `rate()` to return a value, regardless of the scrape
  interval.
* Extrapolation: `rate()` extrapolates each source series to the range boundaries
  individually. Over the aggregated series it extrapolates the sum once, so series that
  start or end inside the range contribute slightly differently.
* First samples: like `rate()` on the source series, the increase before a series'
  first sample is not counted.
* Skipped samples: out-of-order samples, and samples of series whose type is not
  yet known (for example after a restart without metadata WAL records), are not counted.

### Observability

* `prometheus_tsdb_aggregation_flusher_flushed_series`
* `prometheus_tsdb_aggregation_flusher_stale_removed_series`
* `prometheus_tsdb_aggregation_flusher_emission_lag_seconds`: how far output trails the
  wall clock. It should stay near `bucket_grace_period`.
* `prometheus_tsdb_aggregation_flusher_straggler_increments_total`: increments that missed
  their window. A steady rate means the grace period is too short.

If the aggregation rules are not in the global config, the applied rules are logged on every load, since they aren't visible through any API or the config UI.

### Testing

Unit tests cover config validation, increment and reset handling, window attribution with
late and evicted increments, failed commits, and staleness.
Benchmarks cover the TSDB append path with aggregation rules and the flusher.

### Open questions

* Config location: a separate file or a top-level block in `prometheus.yml`.
* Output naming: the default suffix, and whether the action label should be a reserved
  `__aggregation_action_type="incr_without"`.
* Should an aggregated series be eligible for a different rule (chained aggregation), or
  be excluded from all rules?
* Should non-scrape appends (remote write, OTLP, rules) be aggregated as well?
* Is an extension to make HA replicas produce similar/deduplicable aggregated counters worth including in this same proposal?
* When flushing, the increments could be committed using the newly supported delta temporality, instead of adding them up to be cumulative.

## Alternatives

1. Recording rules. Their cost follows raw cardinality on every evaluation, which
   is the problem being solved. They also cannot aggregate counters without hardcoding a rate interval.
2. Aggregate in the scrape loop (PROM-67 style). The scrape loop only sees one
   target.
3. Infer counters from the metric name. This is cheaper, but produced wrong aggregates in
   production for gauges named like counters.
4. Configure rules per `scrape_config`. This keeps rules next to the targets they
   apply to, but only covers scraped input, not remote write or OTLP. It also lets two
   scrape configs define conflicting rules for the same output series, unless the
   accumulator is separated across targets.
5. Use PromQL instead of action types in the configuration. We could validate the query to fail if it includes operations
   that cannot be executed at scrape time. However, the closest to `incr_without` would be `sum without (label) (counter)` without `rate`,
   which doesn't account for restarts as `incr_without` do.

## Action Plan

* [ ] Keep the metric type per series independently of `metadata-wal-records`. Commit metadata before samples.
* [ ] Configuration types, parsing, validation, and reload plumbing behind the feature flag.
* [ ] `aggregatedHead` and the commit-path hook.
* [ ] Flusher: aligned schedule, window emission, failure handling, and staleness.
* [ ] Flusher metrics listed in Observability above.
* [ ] Wiring in `cmd/prometheus`, and documentation in `docs/feature_flags.md` and the configuration docs.
