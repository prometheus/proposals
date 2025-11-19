## Feature Flags API

* **Owners:**
  * `@roidelapluie`

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [Feature request](https://github.com/prometheus/prometheus/issues/10022)
  * [Example use case](https://github.com/grafana/grafana/issues/33487)

This design document proposes introducing a "features list" API within the Prometheus ecosystem. This API would allow Prometheus-like endpoints to advertise which features they support and have enabled. By exposing this information, clients can determine in advance what functionality is available on a given endpoint, leading to more efficient API usage, optimized PromQL queries, and clearer expectations about endpoint capabilities.

The primary objectives are to create a solution that is broadly applicable across various targets, encouraging wide adoption, and to address practical needs and optimizations that arise when such capability information is easily accessible.

## Why

Over time, the Prometheus APIs have undergone numerous optimizations, such as supporting POST in addition to GET requests and allowing filtering on certain API endpoints. Additionally, new APIs, PromQL functions, and capabilities are regularly introduced. Some of these features are optional and can be enabled or disabled by users.

Without a "features API," new advancements are often underutilized because API clients are hesitant to adopt them before widespread support exists among users. By creating an API that clearly communicates available and enabled features, clients can take advantage of new capabilities as soon as they are released. For instance, HTTP POST support was added to Prometheus in version 2.1.0 (2018) but was not adopted as the default in Grafana until version 8.0 (2021), illustrating a three-year delay caused by limited visibility of feature availability.

### Pitfalls of the current solution

Currently, there is no proper solution for feature discovery. While users can retrieve configs or version flags, these APIs are tightly coupled to Prometheus, not machine-friendly, and unsuitable for third-party or generic integrations.

There are client-side workarounds. In Grafana, users can configure datasources like this:

```yaml
prometheusType: Prometheus # Options: Cortex | Mimir | Prometheus | Thanos
prometheusVersion: 2.40.0
```

Grafana infers compatibility from these values and selects endpoints accordingly. For instance, all of the following support label matchers in the Labels API:

- Prometheus >= 2.24.0
- Mimir >= 2.0.0
- Cortex >= 1.11.0
- Thanos >= 0.18.0

If the criteria are met, Grafana chooses more efficient label endpoints (`/api/v1/labels`, `/api/v1/label/<name>/values` with `match[]`). Otherwise, it falls back to the less efficient `/api/v1/series` for label queries.

Key limitations of this approach:

1. Configuration errors (wrong type or version) can lead to incompatible or missing features.
2. Backend upgrades alone do not enable new features in clients—client logic must also be updated and released.
3. New Prometheus-compatible backends require explicit code changes in Grafana, slowing adoption.
4. Type and version checks are coarse; they do not reflect actual enabled features, which may depend on flags or configuration.

Alternatives already exist in some downstream projects and demonstrate the need for such kind of APIs. However, the current approach is based on extending the [`buildinfo` endpoint](https://prometheus.io/docs/prometheus/latest/querying/api/#build-information) with a [`features` field](https://github.com/grafana/mimir/blob/9fccbacdabdd236cb7ff97cf154643b409078178/pkg/util/version/info_handler.go#L11-L30), which is very vendor specific. Grafana already uses this approach for some [alertmanager features](https://github.com/grafana/grafana/blob/8863ed9d6f8395808196b5d81d436fb637a43d37/public/app/features/alerting/unified/api/buildInfo.ts#L137-L145).

## Goals

- Provide a machine-readable API to report enabled features.
- Ensure the solution is lightweight to encourage broad adoption in the ecosystem.
- Cover a comprehensive and relevant subset of Prometheus features.
- Design the API to be extensible, allowing third-party projects to declare their own features.

### Audience

The intended audience for this proposal includes:

- Developers creating software that exposes the Prometheus API
- Consumers of the Prometheus API

## Non-Goals

Implementing a unified feature gate in the code is out of scope

## How

The `/api/v1/features` endpoint returns a JSON object with top-level categories inspired by Prometheus package organization. Each category key contains a map of unique feature names (strings) to `true`/`false` booleans indicating whether the feature is enabled.

Initial categories:

- `api` - API endpoint features and capabilities
- `otlp_receiver` - OTLP receiver features
- `prometheus` - Prometheus-specific features
- `promql` - PromQL language features (syntax, modifiers)
- `promql_functions` - Individual PromQL functions
- `promql_operators` - PromQL operators and aggregations
- `rules` - Rule evaluation features
- `scrape` - Scraping capabilities
- `service_discovery_providers` - Service discovery mechanisms
- `templating_functions` - Template functions for alerts and rules
- `tsdb` - Time series database features
- `ui` - Web UI capabilities

Example response:

```json
{
  "status": "success",
  "data": {
    "api": {
      "exemplars": true,
      "labels_matchers": true,
      "query_post": true
    },
    "promql": {
      "negative_offset": true,
      "at_modifier": true,
      "subqueries": true
    },
    "promql_functions": {
      "last_over_time": true,
      "limitk": true
    },
    "prometheus": {
      "stringlabels": true,
    }
  }
}
```

Semantics:
- All names MUST use `snake_case`
- Each category value is a map from unique feature name to a boolean
- Clients MUST ignore unknown feature names and categories
- The response follows standard Prometheus API conventions with `status` and `data` fields
- The endpoint returns HTTP 200 OK, like other Prometheus APIs
- Vendors MAY add vendor-specific categories (e.g., `prometheus`, `mimir`, `cortex`, or other categories such as `clustering`) to expose vendor's unique abilities. Vendors implementing custom PromQL functions SHOULD register them under a vendor-specific category (e.g. `vendor_functions`, `metricsql_functions`), in case a future prometheus function gets implemented with a different signature.

Some items might exist in multiple categories.

We do not differentiate between a feature that is simply disabled and one that is missing because it was not compiled in. There is no separate "build" category. Instead, if a feature depends on a compile-time flag, it will appear under its relevant category. If it is not built-in or disabled, it should be set to `false`. Implementations MAY omit features set to `false`, and clients MUST treat absent features as equivalent to `false`.

## Stability

The `/api/v1/features` endpoint is stable for 3.x as part of the v1 HTTP API. Category names and feature names are stable within a major version and MUST NOT be renamed or removed. New categories and features MAY be added at any time. Features that need to be removed SHOULD be set to `false` and only removed in the next major version.

## Alternatives

- Flat list: Having categories makes it easier for things like PromQL functions.
- No booleans (only trues): clients might use false to hint the user that they could enable a feature.
- Richer information than booleans (limits, etc): primarily to keep things simple

## Action Plan

The package will be located in the prometheus/prometheus repository.

Instead of actively collecting features from other packages, this package will allow other components to register their supported features with it.

For the initial launch, I plan to include a substantial set of already existing features.
