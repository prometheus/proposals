## Info-metric label discovery APIs for `info()` autocomplete

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) arve.knudsen@gmail.com
  * Ismail Simsek [@itsmylife](https://github.com/itsmylife) ismail.simsek@grafana.com

* **Implementation Status:** Not implemented upstream ([WIP implementation PR](https://github.com/prometheus/prometheus/pull/17930))

* **Related Issues and PRs:**
  * [PROM-74 — V2 API for labels and values discovery](https://github.com/prometheus/proposals/pull/74). This proposal builds on PROM-74's NDJSON model, feature gate, search behavior, and storage interfaces. The request bounds below follow the current search implementation and are authoritative where PROM-74's original text differs.
  * [PROM-37 — Simplify joins with info metrics in PromQL](./0037-native-support-for-info-metrics-metadata.md). Introduces the `info()` PromQL function supported by this autocomplete API.
  * [Grafana Prometheus datasource PR #244](https://github.com/grafana/grafana-prometheus-datasource/pull/244). Independent client PoC and source of the client-integration feedback incorporated here.

> TL;DR: Add `GET|POST /api/v1/info_labels` and `GET|POST /api/v1/info_label_values` as info-metric companions to PROM-74's experimental search API. Both endpoints apply the same `expr`, repeated `metric_match[]`, and repeated `data_match[]` scope. The first searches data-label names; the second searches values for one exact data-label name. They reuse the current search API's NDJSON, search, sort, score, limit, batch, and storage behavior and require both `search-api` and `promql-experimental-functions`.

## Why

The PromQL `info()` function enriches base series with data labels from info metrics such as `target_info`. An editor completing `info(<expr>, {…})` must first discover which data-label names exist for the in-scope info series, then discover values only for the name the user selected.

This is not editor-specific. The Prometheus UI and the Grafana Prometheus datasource use different editor implementations, but both require the same server-side operations.

Existing APIs cannot express those operations efficiently and consistently:

* `/api/v1/labels` and `/api/v1/label/{name}/values` include labels from base metrics as well as info metrics and cannot derive the info scope from arbitrary PromQL.
* `/api/v1/series` transfers one row per series and requires the client to deduplicate labels and remove identifying labels.
* PROM-74's general label search endpoints support filtering and ranking, but do not evaluate an arbitrary expression to derive the identifying-label values that scope the relevant info series.
* `match[]` can express selectors, not expressions such as `rate(http_requests_total[5m])` that users actually type.

## Goals

* One bounded request for each autocomplete phase: names first, values for one selected name second.
* Identical server-side scoping for both phases, using full PromQL name and data-label matchers and optionally the identifying labels harvested from a PromQL expression.
* Exact label-name semantics for value lookup. Fuzzy name search must not be used to emulate selecting one label.
* Reuse the current search API's request, streaming, storage, and feature-gate behavior, with the explicit bounds below.
* Keep the response units simple and independently bounded: one name per name record, one value per value record.

## Non-Goals

* Replace or modify the existing label or series endpoints.
* Add server-side evaluation of `info()`; query evaluation remains on `/api/v1/query`.
* Add cursor-based pagination. As in PROM-74, `has_more` reports truncation but is not a cursor.
* Make identifying labels configurable per request. The initial set is `job` and `instance`.

## How

Add two dual-gated endpoints with a shared scope and distinct result types:

| Endpoint                    | Search target                         | Result record                           |
|-----------------------------|---------------------------------------|-----------------------------------------|
| `/api/v1/info_labels`       | Non-identifying label names           | `{ "name": string, "score"?: number }`  |
| `/api/v1/info_label_values` | Values of the exact `label` parameter | `{ "value": string, "score"?: number }` |

These are top-level `info_*` endpoints rather than `/api/v1/search/*` resources because `expr`, the info-specific matcher split, and the dual `info()` feature gate are function-specific semantics. Reusing PROM-74's `Searcher`, request parameters, and NDJSON contract does not make the operations general label search.

The separation follows the two editor interactions and PROM-74's label-name and label-value split. It avoids a combined `{name, values[]}` response whose two independent cardinality dimensions require `values_limit`, encourages eager value retrieval, and cannot give the selected label first-class exact semantics.

Requests that reach streaming return `200 OK` with `application/x-ndjson` using PROM-74's zero-or-more batch lines followed by exactly one terminal success or error record. Validation and setup failures, plus first-iteration failures that produce no batch results, return the usual non-2xx Prometheus JSON error. Both endpoints use the `storage.Searcher` interface: `SearchLabelNames` for names and `SearchLabelValues` for values.

### Shared request parameters

| Name             | Type                          | Required | Default                  | Description                                                                                                                                                                                      |
|------------------|-------------------------------|----------|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `expr`           | string (PromQL)               | No       |                          | Instant-vector expression evaluated to derive `job` and `instance` values that restrict the info-series scope.                                                                                   |
| `metric_match[]` | []string                      | No       | `__name__="target_info"` | Repeated full PromQL matchers on `__name__`. Multiple matchers have AND semantics.                                                                                                               |
| `data_match[]`   | []string                      | No       |                          | Repeated full PromQL matchers on labels other than `__name__`. Multiple matchers have AND semantics.                                                                                             |
| `time`           | rfc3339 / unix timestamp      | No       | `end`                    | Instant evaluation time for `expr`.                                                                                                                                                              |
| `lookback_delta` | duration / float seconds      | No       | server default           | Lookback used both to evaluate `expr` and to select matching info series.                                                                                                                        |
| `start`, `end`   | rfc3339 / unix timestamp      | No       | last 1h                  | Storage search window when `expr` is absent. With `expr`, `start` must parse but is ignored for range selection and ordering validation; `end` supplies the default `time`.                      |
| `search[]`       | []string                      | No       |                          | At most 32 search terms, matched against names or values according to the endpoint. Multiple terms have OR semantics.                                                                            |
| `fuzz_threshold` | int [0..100]                  | No       | 0                        | Fuzzy threshold, as in PROM-74.                                                                                                                                                                  |
| `fuzz_alg`       | `jarowinkler` / `subsequence` | No       | `jarowinkler`            | Fuzzy algorithm, as in PROM-74.                                                                                                                                                                  |
| `case_sensitive` | bool                          | No       | true                     | Case sensitivity, as in PROM-74.                                                                                                                                                                 |
| `sort_by`        | `alpha` / `score`             | No       |                          | Ordering, as in PROM-74. `sort_by=score` requires `search[]`.                                                                                                                                    |
| `sort_dir`       | `asc` / `dsc`                 | No       | `asc`                    | Direction for alphabetical ordering. Not accepted with `sort_by=score`.                                                                                                                          |
| `include_score`  | bool                          | No       | false                    | Include the deterministic relevance score in each record.                                                                                                                                        |
| `limit`          | positive int                  | No       | 100                      | Maximum records returned after filtering and ordering. A positive `--web.search.max-limit` caps explicit values and may reduce the default; 0 disables that operator cap, not the request limit. |
| `batch_size`     | positive int, at most 10000   | No       | 100                      | Requested records per NDJSON batch line. Its effective value is no greater than `limit`.                                                                                                         |

`limit` bounds the endpoint's retained result state and response size. It is passed to the storage search as a hint, but the API does not promise that an implementation can avoid scanning or enumerating additional index data to determine the requested ordered results or `has_more`. Unlike PROM-74's original request table, `limit=0` and `batch_size=0` are rejected.

At most 32 `metric_match[]` and `data_match[]` values may be supplied in total. Each value must parse as exactly one full PromQL matcher. `metric_match[]` accepts only `__name__`; `data_match[]` rejects `__name__`. This separation lets clients preserve matcher source text directly without inventing an operator-prefix encoding.

`match[]` is rejected on both endpoints. It would introduce a second series-scoping mechanism with unclear precedence relative to the info matchers and `expr`.

The legacy singular `metric_match` and `data_match` parameters and the removed combined-response parameter `values_limit` are also rejected. Value cardinality is now controlled by `limit` on `/api/v1/info_label_values`.

### Scope semantics

`metric_match[]` specifies which info metric families to search:

* No name matcher means `__name__="target_info"`.
* `metric_match[]=__name__=~".+_info"` selects matching info metric names.
* Repeated name matchers are ANDed, for example `__name__=~".+_info"` and `__name__!="custom_info"`.
* A negative-only request is implicitly restricted by `__name__=~".+_info"`, so `__name__!="target_info"` cannot broaden the search to every non-target metric.

`data_match[]` filters the selected info series before either endpoint discovers names or values. Repeated data matchers are ANDed with one another, the effective name matchers, and the expression-derived scope.

When `expr` is present, Prometheus evaluates it as an instant query at `time`, which defaults to `end`. The expression must have instant-vector type; matrix, scalar, and string expressions are rejected before execution. Series already matching the effective info-metric name scope are ignored, consistent with `info()` not enriching info series. An expression that produces no remaining series with a non-empty identifying label returns a successful empty stream rather than falling back to an unscoped search.

The subsequent info-series search uses the same temporal selection hints as an instant `info(expr, ...)` evaluation: it applies the effective lookback delta and honors selector `offset` and `@` modifiers. The general search `start` parameter does not broaden or narrow this expression-derived range.

The handler groups expression results by identifying-label presence: `job` only, `instance` only, and both. A missing identifying label becomes an exact empty matcher instead of a wildcard. Within a presence group, observed values become escaped regular-expression alternatives. This avoids false negatives and keeps the number of storage selections bounded by the number of presence patterns rather than the number of expression series. A group containing both labels may conservatively inspect cross-pairs of independently observed `job` and `instance` values. That can make autocomplete suggestions broader, but it cannot change query results: `info()` performs the exact identifying-label join when the completed query executes.

Matcher construction is also bounded before the info-series `Searcher` is opened. At most 10,000 unique `(presence group, identifying label, value)` entries and 1,048,576 total escaped regular-expression bytes, including alternation separators, are accepted. Duplicate values do not consume the value budget. Exceeding either bound returns a pre-stream `bad_data` error asking the caller to narrow `expr`; values are never truncated because truncation could silently omit valid completions.

The name matchers, data matchers, and `expr` apply jointly. Expression warnings are merged with storage warnings and exposed on the stream.

Clients must resolve editor-specific variables and macros before sending `expr`, using the same semantics as normal query execution. Otherwise autocomplete and query execution can observe different expressions.

### `GET|POST /api/v1/info_labels`

This endpoint searches non-identifying label names on the scoped info series. `__name__`, `job`, and `instance` are filtered before the result limit is applied, so they cannot consume autocomplete slots.

The `label` parameter is rejected; callers seeking values must use `/api/v1/info_label_values`.

Example:

```bash
curl -N -g 'http://localhost:9090/api/v1/info_labels?expr=rate(http_requests_total{job="api"}[5m])&metric_match[]=__name__=~".+_info"&data_match[]=env="prod"&search[]=ver&sort_by=score&include_score=true'
```

```ndjson
{"results":[{"name":"version","score":1},{"name":"server","score":0.83}]}
{"status":"success","has_more":false}
```

### `GET|POST /api/v1/info_label_values`

This endpoint requires `label`, interpreted as one exact decoded label name. It is a query parameter rather than a path component so UTF-8 label names do not require a second path-specific quoting contract.

Empty `label`, `__name__`, `job`, and `instance` are rejected because they are not info data labels. `search[]`, if present, filters and ranks values of the selected label; it never changes which label is selected.

Example:

```bash
curl -N -g 'http://localhost:9090/api/v1/info_label_values?label=version&expr=rate(http_requests_total{job="api"}[5m])&search[]=v2&sort_by=score'
```

```ndjson
{"results":[{"value":"v2.1"},{"value":"v2.0"}]}
{"status":"success","has_more":false}
```

### Feature gating

Both endpoints require:

* `--enable-feature=search-api`, for the experimental search and NDJSON infrastructure.
* `--enable-feature=promql-experimental-functions`, because this API serves the experimental `info()` function.

Missing gates return the standard non-streaming Prometheus JSON error with `errorType: unavailable`; the message names every missing feature in one response.

### Stream completeness

A non-2xx response uses the standard Prometheus JSON error format and is not an NDJSON stream. A successful NDJSON stream ends with:

```ndjson
{"status":"success","has_more":false}
```

A client must reject a response when EOF arrives before a terminal record, a line is malformed, more than one terminal record appears, or content follows the terminal record. A mid-stream error record is terminal. Partial batches must not be returned or cached as a successful response.

Clients should cache only complete successful responses, bound cache size and freshness, key entries by the effective resolved request, deduplicate identical in-flight requests, and evict failures so a later request can retry. Clients should normally omit `limit` and accept the operator-controlled default.

Editor integrations should forward every completed matcher in the second `info()` argument as its original full PromQL source. The matcher currently being edited must be omitted, while other matchers on the same label remain in scope. The second argument has no metric-name prefix syntax; clients encountering an unquoted identifier or quoted metric-name prefix must use generic completion rather than synthesizing a `__name__` matcher. Users select another info metric explicitly with a matcher such as `{__name__="build_info", ...}`. Variables and macros must be resolved before the request, and quoted UTF-8 label names must be decoded before use as the exact `label`. Completion for `__name__`, `job`, and `instance` remains the general metric or label completion path because those are not discoverable info data labels.

### Storage and performance

The name endpoint calls `Searcher.SearchLabelNames` with the common scope and a filter that excludes identifying labels before applying search and limit. The value endpoint calls `Searcher.SearchLabelValues` with the exact label and the same scope. This keeps search, scoring, ordering, limiting, and downstream storage optimizations aligned with PROM-74 rather than reimplementing them in an info-specific series extractor.

The optional `expr` adds one standard instant-query evaluation. Existing query timeout, max-samples, lookback override, and authorization behavior applies. The storage search then uses the derived matchers over the exact range that `info()` would select. The endpoint exposes no metadata unavailable through existing label and series APIs; it provides a scoped and efficient autocomplete contract.

The `limit` contract bounds result retention and wire output, not the cardinality of the underlying index or the worst-case storage work. The actual work depends on the `Searcher` implementation, matcher selectivity, requested ordering, and whether it can stop early while still determining `has_more`.

### Extensibility for Mimir, Thanos, and Cortex

As in PROM-74, downstream implementations may add optional per-record extensions without changing the core record shapes:

```ndjson
{"results":[{"name":"cluster","extensions":{"mimir":{"cardinality":42}}}]}
{"status":"success","has_more":false}
```

The Prometheus implementation does not emit extensions.

### Testing and verification

Implementation tests cover:

* both endpoints over GET and POST;
* the dual feature gate;
* `expr`, repeated name and data matchers, negative-only name matching, and their joint scope;
* mixed identifying-label presence and conservative cross-pair scoping without false negatives;
* instant-vector type validation, historical `end`, ignored `start`, and lookback, `offset`, and `@` temporal equivalence with `info()`;
* exact matcher-construction bounds, duplicate accounting, and rejection before the info `Searcher` opens;
* exact and UTF-8 label names for value lookup;
* identifying-label filtering and rejection;
* matcher count and syntax validation, and rejection of `match[]`, singular legacy matcher parameters, `label` on the name endpoint, and `values_limit`;
* search, Jaro-Winkler and subsequence fuzzy matching, scoring, ordering, limit, `has_more`, and batching;
* strict client parsing, bounded caches, in-flight deduplication, and retry after failure.

Manual verification can compare names and values against client-side aggregation of `/api/v1/series` for the same info-metric scope and time window.

### Migration

These are new, experimental, opt-in endpoints. No migration is required. The earlier WIP combined `{name, values[]}` shape and singular matcher shorthand were never released; implementations and PoC clients should move to the two-endpoint, repeated-full-matcher contract and reject obsolete parameters so stale callers fail visibly.

## Alternatives

### 1. One combined `{name, values[]}` endpoint

Rejected. Name and value completion are separate user interactions with different search targets and cardinalities. A combined response either eagerly downloads unused values or requires a second `values_limit` dimension. It also turns exact label selection into a fuzzy-name-search workaround and does not map cleanly to PROM-74's `SearchLabelNames` and `SearchLabelValues` interfaces.

If measured client latency later justifies removing the second round trip, an optional `include_values` extension on the name endpoint could be proposed separately. The split endpoints remain the canonical bounded operations, and such an extension would need an explicit independent value bound.

### 2. Reuse `/api/v1/search/label_names` and `/api/v1/search/label_values`

These endpoints have the right split but cannot derive the info-series scope from an arbitrary PromQL expression. Adding `expr` and info-specific identifying-label behavior to the general endpoints would mix function-specific semantics into otherwise general label search.

### 3. Pure client-side composition

Combining labels, per-label values, or series endpoints is possible but transfers substantially more data, may require N+1 requests, and cannot evaluate arbitrary PromQL server-side to keep both completion phases consistently scoped.

### 4. Use `match[]` instead of `expr`

`match[]` handles selectors only. Autocomplete must work for arbitrary expressions users type, including functions and operators.

### 5. Add an `/api/v1/info()` query endpoint

Out of scope. `info()` already uses the normal PromQL query endpoints. This proposal is metadata discovery for building that query.

## Action Plan

* [X] Build a working Prometheus implementation.
* [X] Validate the contract in the Prometheus UI client.
* [X] Validate independent integration in the Grafana Prometheus datasource.
* [X] Split name and exact-label value discovery into separate endpoints based on client feedback.
* [ ] Finalize this proposal based on community feedback.
* [ ] Merge the implementation after proposal acceptance.
