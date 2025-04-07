## Type and Unit Metadata Labels

* **Owners:**
  * David Ashpole [@dashpole](https://github.com/dashpole)
  * Bartek Plotka [@bwplotka](https://github.com/bwplotka)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/open-telemetry/opentelemetry-specification/issues/2497

* **Other docs or links:**
  * Survey Results: https://opentelemetry.io/blog/2024/prometheus-compatibility-survey/
  * Slack thread: https://cloud-native.slack.com/archives/C01AUBA4PFE/p1726399373207819
  * Doc with Options: https://docs.google.com/document/d/1t4ARkyOoI4lLNdKb0ixbUz7k7Mv_eCiq7sRKHAGZ9vg
  * Vision docs:
    * https://docs.google.com/document/d/10Z1XKeQXxJAc_jKW0qEC8G4krlPTmE89k31FJfPVbro
    * https://docs.google.com/document/d/1PY0SzpeEmuH4Uxt887hnKsHplHGR1FnmR-8mf9wp06A
  * Prometheus PoCs:
    * (first) https://github.com/prometheus/prometheus/compare/main...dashpole:prometheus:type_and_unit_labels
    * (second) https://github.com/prometheus/prometheus/pull/16025
  * Vision docs: 

> TL;DR: This document proposes extending metric identity to include the metric type and unit as separate labels.

## Why

Prometheus naming convention and OpenMetrics 1.0 recommend encoding metric unit as a metric name suffix. For counters, conventions recommend adding `_total` suffix. This technique was incredible useful for humans to know semantics of their metrics when using Prometheus metrics (e.g. PromQL in alerts, dashboards, adhoc queries, in plain YAML form). However, these days we are hitting three main limitations of this solution:

1. Inability for automation to reliably parse unit and type from the metric name. For example, you never know for sure if unit (e.g. `bytes`) is part of metric name or unit. For the metric type we saw accidents of naming counters without total or vice versa. The `_total` only helps with counters too, we have more metric types. This logic is preventing various innovations and features (e.g. Type-aware PromQL, seamless renames, smarter tool for metric analysis and processing, e.g. GenAI).
2. Significant increase of the cases for series with the same metric name but different unit and type. For example, it is possible in Prometheus to have metrics with the same name, but different value types (float64 vs native histogram). Additionally with OpenTelemetry metrics, per [dev-summit consensus](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit#bookmark=id.q6upqm7itl24), we would like to avoid adding type and unit suffixes to metric names when translating from OpenTelemetry to Prometheus. Simply removing suffixes might result in "collisions" between distinct OpenTelemetry metrics which have the same name, but different types (less commonly) or units.

For those reasons this document explores ability to preserve type and unit as a separate pieces of information that can be reliably accessed, indexed and queried.
We envision to solve it without breaking existing users (even when a feature flag is enabled).

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* [Required] Do not break existing users; [do not force them to use more complex PromQL](https://docs.google.com/document/d/1PY0SzpeEmuH4Uxt887hnKsHplHGR1FnmR-8mf9wp06A/edit?disco=AAABfCYLHl0).
* [Required] Handle correctly cases of multiple series with the same metric name but different type and unit.
  * This case can happen already with the native and classic histograms, especially during migrations.
  * Blocker for OTLP no-translation option.
* [Required] Richer Prometheus (e.g. PromQL, relabel, recording) functionality and UX depending on type and unit.
  * Blocker for [delta type](https://docs.google.com/document/d/15ujTAWK11xXP3D-EuqEWTsxWiAlbBQ5NSMloFyF93Ug/edit?tab=t.0#heading=h.5sybau7waq2q).
* [Required] OpenTelemetry users can query for the original names of their metrics.
* [Nice to have] Path for the further innovations around metric identity (e.g. [seamless renames](https://www.google.com/url?q=https://sched.co/1txHv&sa=D&source=docs&ust=1742288864071431&usg=AOvVaw06J0dGuqUNJPPPNF17Eeg8))
* [Nice to have] Improve PromQL UX that errors/warns when using "inappropriate" operations for a metric type.
* [Nice to have] OpenTelemetry users can grep for the original names in the text exposition.

### Audience

This document is for Prometheus server maintainers, PromQL maintainers, and anyone interested in furthering compatibility between Prometheus and OpenTelemetry.

## Non-Goals

* Propose auto-convert between units when there is a conflict.
* Propose auto-convert between types (e.g. native histogram vs float series).
* Allow mixing metrics with the same name, but different type or unit in the exposition format. See potential future extensions.
* Design special PromQL syntax for type and unit in this proposal.

## How

We propose adding special `__unit__` and `__type__` labels that combined with `__name__` metric name compose a "metric identity". Initially behind a `type-and-unit-labels` feature flag, but opt-out once stable.

When querying for a metric, users will be able to filter for a type or unit by specifying a filter on the `__unit__` or `__type__` labels, which use the reserved `__` prefix to ensure they do not collide with user-provided labels. Those labels will be populated on ingestion (scrape, PRW/OTLP receiving) from the existing metadata fields (e.g. TYPE text field in text exposition). **Any existing user provided labels for `__unit__` and `__type__` will be overridden or dropped**.

For example, querying the query API for:

* `my_metric{}` will return all series with any type or unit, including `__type__` and `__unit__` labels.
* `my_metric{__unit__="seconds", __type__="counter"}` will return only series with the specified type and unit.

In the future, we can come with extensions to [PromQL with nicer syntax e.g. `my_metric~seconds.counter`]().

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, the query returns an info annotation, which is surfaced to the user in the UI.

Users don't see the `__type__` or `__unit__` labels in the Prometheus UI next to other labels by default.

When a query drops the metric name in an effect of an operation or function, `__type__` and `__unit__` will also be dropped.

Users see no change to exposition formats as a result of this proposal.

### PromQL Changes

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, an info annotation will be returned with the PromQL response, which is otherwise unmodified.

Aggregations and label matches ignore `__unit__` and `__type__` and any operation removes the `__unit__` and `__type__` label (with the exception of `label_replace`), similar to `__name__` semantics.

### Prometheus UI Changes

When displaying a metric's labels in the table or in the graph views, the UI will hide labels starting with `__` (double underscore) by default, similar to the current handling of `__name__`. A "Show System Labels" check-box will be added, which shows hidden labels when checked.

### Prometheus Server Ingestion

When receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats, the type and unit of the metric are added as the `__type__` and `__unit__` labels. For simplicity, any existing user provided labels for `__unit__` and `__type__` will be overridden or dropped. Typeless (including unknown type), nameless and unitless entries will NOT produce any label.

PRW 1.0 is omitted because metadata is sent separately from timeseries, making it infeasible to add the labels at ingestion time.

Users can modify the type and unit of a metric at ingestion time by using `metric_relabel_configs`, and relabeling the `__type__` and `__unit__` labels.

### Considerations

This solution solves all goals mentioned in [Goals](#goals). It also comes with certain disadvantages:

* As [@pracucci mentioned](https://github.com/prometheus/proposals/pull/39/files#r19428174750), this change will technically allow users to query for "all" counters or "all" metrics with units which will likely pose DoS/cost for operators, long term storage systems and vendors. Given existing TSDB indexing, `__type__` and `__unit__` postings will have extreme amount of series referenced. More work **has to be done to detect, handle or even forbid such selectors, on their own.**. On top of that TSDB posting index size will increase too. This is however similar to any popular labels like `env=prod`.
* All API parts (Series, LabelNames, LabelValues, Recordings/Alerts, remote APIs) will expose new labels without control. This means ecosystem will start depending on this, once this feature gets more mature, **potentially prohibiting the alternative approaches (e.g. only exposing `~seconds.counter` special syntax instead of raw `__type__=~".*"` selectors)**. We accept that risk.
* Downstream users might be surprised by the new labels e.g. in Cortex, Thanos, Mimir, vendors.

### Open Questions

1. Should we prohibit standalone type and unit selectors for performance reasons? This would be inconsistent with __name__ though?

### Implementation Plan

#### Milestone 1: Feature flag for `type-and-unit-labels`

See: https://github.com/prometheus/prometheus/pull/16228

Add a feature flag: `--enable-feature=type-and-unit-labels`. When enabled, `__type__` and `__unit__` labels are added when receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats. Implement any changes required to allow relabeling `__type__` and `__unit__` in `metric_relabel_configs`. 

This will also handle basic PromQL semantics (when __name__ is dropped we also drop __type__ and __unit__)

#### Milestone 2: UI and further PromQL changes

During this stage, implement the UI changes. Iterate based on feedback. Changes should have no effect unless the `type-and-unit-labels` feature flag is enabled.

#### Milestone 3: Add no translation option for OTLP translation

Add an option for the OTLP no translation strategy. When enabled, it disables UTF-8 sanitization and the addition of suffixes. In the documentation for this option, recommend that `--enable-feature=type-and-unit-labels` is enabled.

## Alternatives

### Type and Unit in complex value types

Unlike other metric types, native histograms are a complex type and contain many fields in a single value. The metric type and unit could be added as fields of a complex value type in a similar way.

This solution is not chosen because:

* Requires intrusive changes to all formats (text, proto, etc.).
* Requires new PromQL syntax for querying the type and unit.

### "Hide" __type__ and __unit__ labels in PromQL, instead of UI

Existing UIs don't handle the `__type__` and `__unit__` labels. To mitigate this, PromQL could omit the `__type__` and `__unit__` labels from the query response. Doing this would avoid requiring UIs to update to handle the new labels.

This solution is not chosen because:

* It deviates from the current handling of the `__name__` label.
* We expect metadata, like type and unit to be useful to display in the UI, and want to enable these use-cases.
* It should be a small amount of effort to hide these labels.

### Omit __unit__ label from counting series for summaries and histograms

The unit of a `_count` or `_bucket` series of a histogram is always `1`, since these are counts.  Applying a `__unit__` label of `seconds`, for example, is confusing because the series themselves measure a counts of observations. Alternatively, we could only apply `__unit__` labels to the `_sum` series of histograms and summaries, and the quantile series of summaries.

However, this would re-introduce part of the problem we are trying to solve. Histogram buckets' `le` label's value is in the units of the metric. If the unit is not included in the labels of the histogram bucket series, series with `le=1000` in seconds, for example, would collide with series with `le=1000` in milliseconds. We could include the unit in the `le` label (e.g. `le=1000s`), but that would be much more disruptive to users without much additional benefit.

The `_count` series of histograms and summaries could omit the `__unit__` label without this consequence, since the count does not have any relation to the unit. This proposal includes the `__unit__` label for consistency so that users can always query for metrics that have a specific unit.

## Potential Future Extensions

### PromQL syntax for selecting type and unit

This requires a separate proposal, but to start the discussion, similar to suffixes of _<unit> and _<type/total> but make it an explicit suffix using a delimiter not currently permitted in metric names. Specifying suffixes is optional when querying for a metric. When the type or unit suffix is omitted from a query, it would (design TBD) return results which include any type or unit suffix which exists for that name.

NOTES:

* `~` for units and `.` for type is just one example, there might be better operators/characters to use.
* This proposal is fully compatible with the proposal above. `http_request_duration{__unit__="seconds", __type__="histogram"}` could just be another syntax for `http_request_duration~seconds.histogram`. It would make it much easier to add units and/or types to the metric name, so it would address the concern that you cannot see the unit and type anymore by looking at a PromQL expression without supporting tooling. If we allowed `.total` as an alias of `.counter`, we would have very little visible change. `http_requests_total` would become `http_requests.total`.

Writing queries that include the type and unit would be recommended as a best-practice by the community.

For example:

* Querying for `foo.histogram` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.histogram`.
* Querying for `foo~seconds` would return results that include both `foo~seconds.histogram` and `foo~seconds.counter`.
* Querying for `http_server_duration` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.counter`.
* Querying for an OpenTelemetry metric, such as `http.server.duration`, with suffixes would require querying for `”http.server.duration”~seconds.histogram`. Note that suffixes are outside of quotes.

This solution is not chosen because:

* Adding suffixes outside of quotes looks strange: `{“http.server.duration”~seconds.histogram}`.
  * Alternatives: `{“http.server.duration”}~seconds.histogram` or `{“http.server.duration”}{seconds,histogram}`
* Rolling this out may be breaking for existing Prometheus users: E.g. `foo_seconds` becomes either `foo~seconds.histogram` or `foo_seconds~seconds.histogram`. Could this be part of OM 2.0?
  * Mitigation: users just stay with `foo_seconds~seconds.histogram`
* Users might be surprised by, or dislike the additional suffixes and delimiters in the metric name results
  * Mitigation: Opt-in for query engines?

### Handle __type__ and __unit__ in PromQL operations

Initially, aggregations and label matches will ignore `__unit__` and `__type__` and all PromQL operations remove the `__unit__` and `__type__` label (with the exception of `label_replace`). Over time, we can update each function to keep these labels by implementing the appropriate logic.  For example, adding two gauges together should yeild a gauge.

### Support PromQL operations on timeseries with the same base unit, but different scale

A PromQL query which sums a metric in "seconds" and a metric in "milliseconds" 

### __type__ and __unit__ from client libraries

One obvious extension of this proposal would be for Prometheus clients to start sending `__type__` and `__unit__` labels with the exposition format. This would:

* Allow mixing metrics with the same name, but different types and units in the same endpoint (an explicit non-goal of this proposal).

This is excluded from this proposal because:

* OpenTelemetry users can use [Views](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#view) to resolve collisions. That should be "good enough".
* Doing this would require some changes to client libraries, which is significantly more work, and is harder to experiment with.
* There can be conflicts between `# TYPE` and `# UNIT` metadata for a metric, and `__type__` and `__unit__` labels. This adds complexity to understanding the exposition format, and requires establishing rules for dealing with conflicts.

### More metadata labels

OpenTelemetry has lots of other metadata that may be a good fit for this "metadata label" pattern. For example, OpenTelemetry's scope name and version, or the schema URL are technically identifying for a time series, but are unlikely to be something that we want to display prominently in the UI.

If the pattern of adding `__type__` and `__unit__` works well for this metadata, we could consider making the pattern more generic:

* UIs should hide _all_ labels starting with `__` by default, not just `__name__`, `__type__`, and `__unit__`.
* Introduce a mechanism to allow OTel libraries to provide additional metadata labels. However, this has the potential to introduce collisions, since `__` has been reserved thus far. Maybe a specific allowlist (e.g. `__otel`-prefixed labels) could work.
