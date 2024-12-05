## Type and Unit Metadata Labels

* **Owners:**
  * David Ashpole [@dashpole](https://github.com/dashpole)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/open-telemetry/opentelemetry-specification/issues/2497

* **Other docs or links:**
  * Survey Results: https://opentelemetry.io/blog/2024/prometheus-compatibility-survey/
  * Slack thread: https://cloud-native.slack.com/archives/C01AUBA4PFE/p1726399373207819
  * Doc with Options: https://docs.google.com/document/d/1t4ARkyOoI4lLNdKb0ixbUz7k7Mv_eCiq7sRKHAGZ9vg
  * Prometheus PoC: https://github.com/prometheus/prometheus/compare/main...dashpole:prometheus:type_and_unit_labels

This document proposes adding the metric type and unit as labels on metrics.

## Why

Per [dev-summit consensus](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit#bookmark=id.q6upqm7itl24), we would like to avoid adding type and unit suffixes to metric names when translating from OpenTelemetry to Prometheus. These suffixes are currently required by the [compatibility specification](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/compatibility/prometheus_and_openmetrics.md). However, OpenTelemetry currently considers the metric type and unit identifying, whereas Prometheus does not. Simply removing suffixes might result in "collisions" between distinct OpenTelemetry metrics which have the same name, but different types (less commonly) or units. Additionally, it is possible in Prometheus to metrics with the same name, but different value types (float64 vs native histogram).

### Pitfalls of the current solution

Roughly half of OpenTelemetry users surveyed preferred keeping metric names unmodified when translating to Prometheus. With our goal of being the default choice to store OpenTelemetry metrics, we should find a way to preserve metric names without introducing potential issues for users.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* [Required] OpenTelemetry users can query for the original names of their metrics.
* [Required] Users can filter by the metric type or unit in PromQL queries.
* [Required] PromQL returns a warning when querying across metrics with different units or types, or when using "inappropriate" operations for a metric type.
* [Nice to have] OpenTelemetry users can grep for the original names in the text exposition.

### Audience

This document is for Prometheus server maintainers, PromQL maintainers, and anyone interested in furthering compatibility between Prometheus and OpenTelemetry.

## Non-Goals

* Prometheus will not attempt to auto-convert between units when there is a conflict.
* Prometheus will not attempt to auto-convert between types (e.g. native histogram vs float series).
* Prometheus client libraries will not allow mixing metrics with the same name, but different type or unit in the exposition format. See potential future extensions.

## User Experience

When querying for a metric, users can filter for a type or unit by specifying a filter on the `__unit__` or `__type__` labels, which use the reserved `__` prefix to ensure they do not collide with user-provided labels.

For example, querying the query API for:

* `my_metric{}` returns all series with any type or unit, including `__type__` and `__unit__` labels.
* `my_metric{__unit__="seconds", __type__="counter"}` returns only series with the specified type and unit.

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, the query returns an info annotation, which is surfaced to the user in the UI.

Users don't see the `__type__` or `__unit__` labels in the Prometheus UI next to other labels by default.

Users see no change to exposition formats as a result of this proposal.

## How

### PromQL Changes

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, an info annotation will be returned with the PromQL response, which is otherwise unmodified.

Aggregations and label matches ignore `__unit__` and `__type__` and any operation removes the `__unit__` and `__type__` label (with the exception of `label_replace`).

### Prometheus UI Changes

When displaying a metric's labels in the table or in the graph views, the UI will hide labels starting with `__` (double underscore) by default, similar to the current handling of `__name__`. A "Show System Labels" check-box will be added, which shows hidden labels when checked.

### Prometheus Server Ingestion

When receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats, the type and unit of the metric are added as the `__type__` and `__unit__` labels, if not already present.

PRW 1.0 is omitted because metadata is sent separately from timeseries, making it infeasible to add the labels at ingestion time.

Users can modify the type and unit of a metric at ingestion time by using `metric_relabel_configs`, and relabeling the `__type__` and `__unit__` labels.

### Implementation Plan

#### Milestone 1: Feature flag for adding labels

Add a feature flag: `--enable-feature=identifying-type-and-unit`. When enabled, `__type__` and `__unit__` labels are added when receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats. Implement any changes required to allow relabeling `__type__` and `__unit__` in `metric_relabel_configs`.

#### Milestone 2: UI and PromQL changes

During this stage, implement the UI and PromQL changes above. Iterate based on feedback. Changes should have no effect unless the identifying-type-and-unit feature flag is enabled.

#### Milestone 3: Add NoNameChanges option for OTLP translation

Add an option, `NoNameChanges` for the OTLP translation strategy. When enabled, it disables UTF-8 sanitization and the addition of suffixes. In the documentation for this option, recommend that `--enable-feature=identifying-type-and-unit` is enabled.

## Alternatives

### “Real” Type and Unit suffixes in **name**

Similar to suffixes of _<unit> and _<type/total> but make it an explicit suffix using a delimiter not currently permitted in metric names. Specifying suffixes is optional when querying for a metric. When the type or unit suffix is omitted from a query, it would (design TBD) return results which include any type or unit suffix which exists for that name.

NOTE: `~` for units and `.` for type is just one example, there might be better operators/characters to use.

Writing queries that include the type and unit would be recommended as a best-practice by the community.

For example:

* Querying for `foo.histogram` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.histogram`.
* Querying for `foo~seconds` would return results that include both `foo~seconds.histogram` and `foo~seconds.counter`.
* Querying for `http_server_duration` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.counter`.
* Querying for an OpenTelemetry metric, such as `http.server.duration`, with suffixes would require querying for `”http.server.duration”~seconds.histogram`. Note that suffixes are outside of quotes.

This solution is not chosen because:

* Requires PromQL changes (intrusive), touches on “dot” operator ideas.
* Adding suffixes outside of quotes looks strange: `{“http.server.duration”~seconds.histogram}`
* Rolling this out would be breaking for existing Prometheus users: E.g. `{foo_seconds}` becomes `{foo~seconds.histogram}`. Could this be part of OM 2.0?
  * Mitigation: users just stay with `{foo_seconds~seconds.histogram}`
* Users might be surprised by, or dislike the additional suffixes and delimiters in the metric name results
  * Mitigation: Opt-in for query engines?

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

## Action Plan

* [ ] Feature flag for adding labels
* [ ] UI and PromQL changes
* [ ] Add NoNameChanges option for OTLP translation
