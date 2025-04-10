## Metric Identity Extension: Type and Unit as Labels

* **Owners:**
  * David Ashpole [@dashpole](https://github.com/dashpole)
  * Bartek Plotka [@bwplotka](https://github.com/bwplotka)

* **Implementation Status:** `Accepted`

* **Related Issues and PRs:**
  * https://github.com/open-telemetry/opentelemetry-specification/issues/2497

* **Other docs or links:**
  * Initial implementation: https://github.com/prometheus/prometheus/pull/16228
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

Prometheus naming convention and OpenMetrics 1.0 recommend encoding metric unit as a metric name suffix. For counters, conventions recommend adding `_total` suffix. This technique was incredible useful for humans to know semantics of their metrics when using Prometheus metrics (e.g. PromQL in alerts, dashboards, adhoc queries, in plain YAML form). However, these days we are hitting twq main limitations of this solution:

1. Inability for automation to reliably parse unit and type from the metric name. For example, you never know for sure if unit (e.g. `bytes`) is part of metric name or unit. For the metric type we saw accidents of naming counters without total or vice versa. The `_total` only helps with counters too, we have more metric types. This logic is preventing various innovations and features (e.g. Type-aware PromQL, seamless renames, smarter tool for metric analysis and processing, e.g. GenAI).
2. Significant increase of the cases for series with the same metric name but different unit and type. For example, it is possible in Prometheus to have metrics with the same name, but different value types (float64 vs native histogram). Additionally with OpenTelemetry metrics, per [dev-summit consensus](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit#bookmark=id.q6upqm7itl24), we would like to avoid adding type and unit suffixes to metric names when translating from OpenTelemetry to Prometheus. Simply removing suffixes might result in "collisions" between distinct OpenTelemetry metrics which have the same name, but different types (less commonly) or units.

For those reasons this document explores ability to preserve type and unit as a separate pieces of information that can be reliably accessed, indexed and queried. **This essentially extends metric identity from just metric name to also unit and type**. We envision to solve it without breaking existing users (even when a feature flag is enabled).

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

We propose adding special `__unit__` and `__type__` labels that combined with `__name__` metric name compose a "metric identity". Initially behind a `type-and-unit-labels` feature flag, but opt-out once stable. Type and unit values are defined by the exposition and ingestion formats. We propose the initial PromQL handling of various type and unit to be initially tied to [OpenMetrics 1.0 types](https://prometheus.io/docs/specs/om/open_metrics_spec/#metric-types) and subject to a future breaking change (tackled in [a different proposal](#more-strict-unit-and-type-value-definition)).

When querying for a metric, users will be able to filter for a type or unit by specifying a filter on the `__unit__` or `__type__` labels, which use the reserved `__` prefix to ensure they do not collide with user-provided labels. Those labels will be populated on ingestion (scrape, PRW/OTLP receiving) from the existing metadata fields (e.g. TYPE text field in text exposition). **Any existing user provided labels for `__unit__` and `__type__` will be overridden or dropped**.

For example, querying the query API for:

* `my_metric{}` will return all series with any type or unit, including `__type__` and `__unit__` labels.
* `my_metric{__unit__="seconds", __type__="counter"}` will return only series with the specified type and unit.

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, the query returns an info annotation, which is surfaced to the user in the UI.

In the initial iteration of this feature flag we also propose that:

* In Prometheus UI, users will see the `__type__` or `__unit__` labels next to other labels if they are defined as API returns them. In the future [we might add UI elements that extract those and display type and unit in a different way than just labels](#prometheus-ui-changes).
* When a query drops the metric name in an effect of an operation or function, `__type__` and `__unit__` will also be dropped. In the future, [we might want to make certain functions return a useful type and unit e.g. a rate over a counter is technically a gauge metric](#handle-__type__-and-__unit__-in-promql-operations). 

Users should see no change to the current exposition formats as a result of this proposal.

### Complex metrics without native type e.g. classic Histogram and Summary

Given this proposal adds a type and unit dimension to every single series, we propose all the series of a single classic histograms and summaries "metric family", should use the same unit and type.
 
For example:

```
# TYPE foo histogram
# UNIT foo seconds  
foo_bucket{le="0.0"} 0
foo_bucket{le="1e-05"} 0
foo_bucket{le="0.0001"} 5
foo_bucket{le="0.1"} 8
foo_bucket{le="1.0"} 10
foo_bucket{le="10.0"} 11
foo_bucket{le="100000.0"} 11
foo_bucket{le="1e+06"} 15
foo_bucket{le="1e+23"} 16
foo_bucket{le="1.1e+23"} 17
foo_bucket{le="+Inf"} 17
foo_count 17
foo_sum 324789.3
```

In this case, semantically one could say `_count` and `_bucket` series values represent a unit of `observations` or `1`. The `seconds` unit relate only to `le` label and `_sum` values in this case.

For simplicity, we propose PromQL expect all the above series to have `__type__=histogram` and `__unit__=seconds`, despite. See [the related alternative](#omit-__unit__-label-from-counting-series-for-summaries-and-histograms).

### PromQL Changes

When a query for a metric returns multiple metrics with a different `__type__` or `__unit__` label, but the same `__name__`, an info annotation will be returned with the PromQL response, which is otherwise unmodified.

Aggregations and label matches ignore `__unit__` and `__type__` and any operation removes the `__unit__` and `__type__` label (except `label_replace`), similar to `__name__` semantics.

### Prometheus Server Ingestion

When receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats, the type and unit of the metric are interpreted and added as the `__type__` and `__unit__` labels. The Prometheus interpretation may change in the future and it depends on the parser/ingestion. 
 
For example for OpenMetrics parser, the [type is validated](https://github.com/prometheus/prometheus/blob/2aaafae36fc0ba53b3a56643f6d6784c3d67002a/model/textparse/openmetricsparse.go#L464) to be case-sensitive subset [the defined OpenMetrics 1,0 types](https://prometheus.io/docs/specs/om/open_metrics_spec/#metric-types). Unit can be any string, with [some soft recommendations from the OpenMetrics](https://prometheus.io/docs/specs/om/open_metrics_spec/#units-and-base-units). In other places where see unsupported type, Prometheus might normalize the value to "unknown". Again, this may change and [another proposal for PromQL type and unit definition is required](#more-strict-unit-and-type-value-definition).

Generally clients should never expose type and unit labels as it's a special label starting with `__`. However, it can totally happen by accident or for custom SDKs and exporters. That's why any existing user provided labels for `__unit__` and `__type__` should be overridden by the existing metadata mechanisms in current exposition and ingestion formats. Typeless (including unknown type), nameless and unless entries will NOT produce any labels.

For PRW 1.0, this logic is omitted because metadata is sent separately from timeseries, making it infeasible to add the labels at ingestion time.

Users can modify the type and unit of a metric at ingestion time by using `metric_relabel_configs`, and relabeling the `__type__` and `__unit__` labels.

### Considerations

This solution solves all goals mentioned in [Goals](#goals). It also comes with certain disadvantages:

* As [@pracucci mentioned](https://github.com/prometheus/proposals/pull/39/files#r19428174750), this change will technically allow users to query for "all" counters or "all" metrics with units which will likely pose DoS/cost for operators, long term storage systems and vendors. Given existing TSDB indexing, `__type__` and `__unit__` postings will have extreme amount of series referenced. More work **has to be done to detect, handle or even forbid such selectors, on their own.**. On top of that TSDB posting index size will increase too. This is however similar to any popular labels like `env=prod`.
* All API parts (Series, LabelNames, LabelValues, Recordings/Alerts, remote APIs) will expose new labels without control. This means ecosystem will start depending on this, once this feature gets more mature, **potentially prohibiting the alternative approaches (e.g. only exposing `~seconds.counter` special syntax instead of raw `__type__=~".*"` selectors)**. We accept that risk.
* Downstream users might be surprised by the new labels e.g. in Cortex, Thanos, Mimir, vendors.

## Potential Future Extensions

Potential extensions, likely requiring dedicated proposals.

### Prometheus UI Changes

When displaying a metric's labels in the table or in the graph views, the UI will hide labels starting with `__` (double underscore) by default, similar to the current handling of `__name__`. A "Show System Labels" check-box might be added, which shows hidden labels when checked.

This is scoped down from the initial implementation due to complexity of the special feature flags in UI and the fact that majority of PromQL users in general might not use Prometheus UI, so we have to educate users on new labels, no matter what we do here.

### More strict unit and type value definition

Current plan delegate definition to exposition and ingestion formats. Then also, generally it's not feasible to expect all the backends with all the
different types and units. For example for unit [OM unit is free-form string with the bias towards base units](https://prometheus.io/docs/specs/om/open_metrics_spec/#units-and-base-units) for OTLP semantic conventions it's [the UCUM](https://unitsofmeasure.org/ucum) standard. For types OpenMetrics define e.g. stateset, which neither Prometheus, or OTLP natively supports. OTLP defines `UpDownCounter` which does not natively exist in Prometheus or OpenMetrics.

One could try to define standard translations or required subset of supported types in PromQL e.g. [the lowercase OpenMetrics types](https://github.com/prometheus/prometheus/blob/2aaafae36fc0ba53b3a56643f6d6784c3d67002a/model/textparse/openmetricsparse.go#L464). This is essential if we want to have robust type or unit aware functions and operations in PromQL one day. Also, it's critical for the proposal of noticing mixed types being passed through the PromQL engine or auto-converting units.

One alternative is to say OpenMetrics types and units and everything else, before going to PromQL should be translated to OpenMetrics defined types and units. This is a bit limited, because Prometheus does not have native support to stateset and info metrics. We also plan to add delta type, which only exists in OTLP. For units, generally is not strictly defined in OpenMetrics, and [OTLP UCUM](https://unitsofmeasure.org/ucum) generally offers more functionality (e.g. standard way of representing concrete amount of batches of units e.g. 100 seconds).

We propose to raise this problem in the Prometheus ecosystem and tackle it in different proposal. For now, Prometheus will use OpenMetrics type normalization and no unit definition.

### Metric identity PromQL short syntax

For metric selection, currently our proposal aims for standard label matcher syntax like:

```
# All three ways are allowed: 
my_metric{__unit__="seconds", __type__="counter"}
{__name__"my_metric",__unit__="seconds", __type__="counter"}
{"my_metric",__unit__="seconds", __type__="counter"} 
``` 

This is functional and feels familiar for labels, but similar to special `__name__` label, it could have much more convenient syntax available e.g.

```
my_metric~seconds.counter{}
my_metric~seconds.total{...}
my_metric~seconds.counter{...} 
{"my_metric", ...}~seconds.total 

# We can do consider without tilde too e.g.
my_metric.seconds.total{...}
my_metric.seconds.counter{...} 
```

Further notes:

* `~` for units and `.` for type is just one example, there might be better operators/characters to use.
* This proposal is fully compatible with the proposal above. `http_request_duration{__unit__="seconds", __type__="histogram"}` could just be another syntax for `http_request_duration~seconds.histogram`. It would make it much easier to add units and/or types to the metric name, so it would address the concern that you cannot see the unit and type anymore by looking at a PromQL expression without supporting tooling. If we allowed `.total` as an alias of `.counter`, we would have very little visible change. `http_requests_total` would become `http_requests.total`.

Writing queries that include the type and unit would be recommended as a best-practice by the community.

For example:

* Querying for `foo.histogram` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.histogram`.
* Querying for `foo~seconds` would return results that include both `foo~seconds.histogram` and `foo~seconds.counter`.
* Querying for `http_server_duration` would return results that include both `foo~seconds.histogram` and `foo~milliseconds.counter`.
* Querying for an OpenTelemetry metric, such as `http.server.duration`, with suffixes would require querying for `”http.server.duration”~seconds.histogram`. Note that suffixes are outside of quotes.

This extension/alternative has been discussed and rejected initially on the [2025-03-31 Prometheus DevSummit](https://docs.google.com/document/d/1uurQCi5iVufhYHGlBZ8mJMK_freDFKPG0iYBQqJ9fvA/edit?tab=t.0#bookmark=id.5gdzvuvgqaf5) due potentially surprising style and not visually appealing at the first glance look. It's true it might be too big of a leap and change for the ecosystem, given type and unit label has to be first proven and adopted in the ecosystem.

While rejected, we ([@bwplotka](https://github.com/bwplotka), [@beorn7](https://github.com/beorn7)) still believe it's a valid alternative or extension to do. Something to consider once/if type and unit labels with get adoption.

### Handle __type__ and __unit__ in PromQL operations

Initially, aggregations and label matches will ignore `__unit__` and `__type__` and all PromQL operations remove the `__unit__` and `__type__` label (except `label_replace`). Over time, we can update each function to keep these labels by implementing the appropriate logic. For example, adding two gauges together should yield a gauge, a rate of a counter, should probably be assumed to be a gauge.

### Support PromQL operations on timeseries with the same base unit, but different scale

A PromQL query which sums a metric in "seconds" and a metric in "milliseconds".

### More metadata labels

OpenTelemetry has lots of other metadata that may be a good fit for this "metadata label" pattern. For example, OpenTelemetry's scope name and version, or the schema URL are technically identifying for a time series, but are unlikely to be something that we want to display prominently in the UI.

If the pattern of adding `__type__` and `__unit__` works well for this metadata, we could consider making the pattern more generic.

On top of that we [investigate linking metric schemas for auto-renames and non-AI and AI generative tools](https://docs.google.com/document/d/14y4wdZdRMC676qPLDqBQZfaCA6Dog_3ukzmjLOgAL-k/edit?tab=t.0#heading=h.2bo9sxs50as). In the early prototype, `__schema_url__` was suggested.

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

As explained in [complex values](#complex-metrics-without-native-type-eg-classic-histogram-and-summary) `_count` and `_bucket` has a unit of `observations` or `1`, not the histogram unit that relates to boundaries (`le` label) and `_sum` value. We could drop `__unit__` label for the `_count` and `_bucket` series (and similar for summaries).

However, this would re-introduce part of the problem we are trying to solve. Histogram buckets' `le` label's value is in the units of the metric. If the unit is not included in the labels of the histogram bucket series, series with `le=1000` in seconds, for example, would collide with series with `le=1000` in milliseconds. We could include the unit in the `le` label (e.g. `le=1000s`), but that would be much more disruptive to users without much additional benefit.

The `_count` series of histograms and summaries could omit the `__unit__` label without this consequence, since the count does not have any relation to the unit. This proposal includes the `__unit__` label for consistency so that users can always query for metrics that have a specific unit.

### Special __type__ values for some classic histogram and summary series

We also discussed special [types](https://github.com/prometheus/proposals/pull/39#discussion_r1927374088) and could put to histogram e.g. _count series.

Rejected due to complexity.

### __type__ and __unit__ from client libraries

There is an unwritten rule, claiming that client libraries are not allowed to expose special labels starting with `__` e.g. see [the client_golang check](https://github.com/prometheus/client_golang/blob/34eaefd8a58ff01b243b36a369615859932de9d8/prometheus/labels.go#L187). This combined

One obvious extension of this proposal would be for Prometheus clients to start sending `__type__` and `__unit__` labels with the exposition format. This would:

* Allow mixing metrics with the same name, but different types and units in the same endpoint (an explicit non-goal of this proposal).

This is excluded from this proposal because:

* OpenTelemetry users can use [Views](https://opentelemetry.io/docs/specs/otel/metrics/sdk/#view) to resolve collisions. That should be "good enough".
* Doing this would require some changes to client libraries, which is significantly more work, and is harder to experiment with.
* There can be conflicts between `# TYPE` and `# UNIT` metadata for a metric, and `__type__` and `__unit__` labels. This adds complexity to understanding the exposition format, and requires establishing rules for dealing with conflicts.

## Open Questions

1. Should we actually clearly [define PromQL supported types and units in this proposal](#more-strict-unit-and-type-value-definition)? Is there a way to delegate it to another one given a scope?
2. Should we prohibit standalone type and unit selectors for performance reasons? This would be inconsistent with `__name__` though?

## Implementation Plan

### Milestone 1: Implement a feature flag for `type-and-unit-labels`

See: https://github.com/prometheus/prometheus/pull/16228

Add a feature flag: `--enable-feature=type-and-unit-labels`. When enabled, `__type__` and `__unit__` labels are added when receiving OTLP or PRW 2.0, or when scraping the text, OM, or proto formats. Implement any changes required to allow relabeling `__type__` and `__unit__` in `metric_relabel_configs`.

This will also handle basic PromQL semantics (when __name__ is dropped we also drop __type__ and __unit__). Also, the query should return info annotation, which is surfaced to the user in the UI, if the PromQL selection contains mixed units or types.

### Milestone 2: Add no translation option for OTLP translation

Add an option for the OTLP no translation strategy. When enabled, it disables UTF-8 sanitization and the addition of suffixes. In the documentation for this option, recommend that `--enable-feature=type-and-unit-labels` is enabled.

### Milestone 3: Explore extensions

Consider the mentioned [extensions](#potential-future-extensions). Iterate based on feedback.

Changes should have no effect unless the `type-and-unit-labels` feature flag is enabled.
