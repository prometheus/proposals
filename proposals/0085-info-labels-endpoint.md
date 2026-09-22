## Info-metric label discovery APIs for `info()` autocomplete

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) arve.knudsen@gmail.com
  * Ismail Simsek [@itsmylife](https://github.com/itsmylife) ismail.simsek@grafana.com

* **Implementation Status:** Not implemented upstream ([WIP implementation PR](https://github.com/prometheus/prometheus/pull/17930)).

* **Related Issues and PRs:**
  * [PROM-74 — V2 API for labels and values discovery](https://github.com/prometheus/proposals/pull/74). This proposal builds on PROM-74's NDJSON model, feature gate, search behavior, and storage interfaces. The request defaults and bounds below follow the current search implementation and are authoritative where PROM-74's original text differs.
  * [PROM-37 — Simplify joins with info metrics in PromQL](./0037-native-support-for-info-metrics-metadata.md). Introduces the `info()` PromQL function supported by this autocomplete API.
  * [Prometheus PR #19557 — fix `info()` with mixed identifying-label presence](https://github.com/prometheus/prometheus/pull/19557). Independent correctness fix for the existing experimental evaluator; it is not part of this proposal.
  * [Grafana Prometheus datasource PR #244](https://github.com/grafana/grafana-prometheus-datasource/pull/244). Independent client PoC and source of the client-integration feedback incorporated here.

> TL;DR: Add `GET|POST /api/v1/search/info_labels` and `GET|POST /api/v1/search/info_label_values` as dedicated info-metric operations within PROM-74's experimental search API. Both endpoints apply the same `expr` and repeated `data_match[]` scope. The first searches data-label names; the second searches values for one exact data-label name. They reuse the current search API's NDJSON, search, sort, score, limit, batch, and storage behavior, apply one timeout across expression evaluation and storage search, and require both `search-api` and `promql-experimental-functions`.

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
* Modify the `info()` evaluator; mixed identifying-label presence correctness is tracked independently.
* Add cursor-based pagination. As in PROM-74, `has_more` reports truncation but is not a cursor.
* Make identifying labels configurable per request. The initial set is `job` and `instance`.

## How

Add two dual-gated endpoints with a shared scope and distinct result types:

| Endpoint                           | Search target                         | Result record                           |
|------------------------------------|---------------------------------------|-----------------------------------------|
| `/api/v1/search/info_labels`       | Non-identifying label names           | `{ "name": string, "score"?: number }`  |
| `/api/v1/search/info_label_values` | Values of the exact `label` parameter | `{ "value": string, "score"?: number }` |

These are dedicated operations within the Search API family. They share PROM-74's `Searcher`, search parameters, and NDJSON contract, while separate routes keep the info-specific `expr` and `data_match[]` scope, expression-dependent time semantics, and dual feature gate explicit.

The separation follows the two editor interactions and PROM-74's label-name and label-value split. It avoids a combined `{name, values[]}` response whose two independent cardinality dimensions require `values_limit`, encourages eager value retrieval, and cannot give the selected label first-class exact semantics.

Requests that reach streaming return `200 OK` with `application/x-ndjson` using PROM-74's zero-or-more batch lines followed by exactly one terminal success or error record. Validation and setup failures, plus first-iteration failures that produce no batch results, return the usual non-2xx Prometheus JSON error. Both endpoints use the `storage.Searcher` interface: `SearchLabelNames` for names and `SearchLabelValues` for values.

Search capability is fail-closed across the full active query path. Before streaming begins, every participating non-noop storage querier must implement `storage.Searcher`; otherwise the request returns the standard non-streaming Prometheus JSON error with `errorType: unavailable`. A federated or fanout implementation must not silently omit results from a storage backend that lacks search support. Runtime errors from search-capable secondary storage retain PROM-74's best-effort warning behavior.

### Shared request parameters

| Name             | Type                          | Required | Default                  | Description                                                                                                                                                                                      |
|------------------|-------------------------------|----------|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `expr`           | string (PromQL)               | No       |                          | Instant-vector expression evaluated to derive `job` and `instance` values that restrict the info-series scope.                                                                                   |
| `data_match[]`   | []string                      | No       | `__name__="target_info"` | Repeated full PromQL matchers from `info()`'s data-label selector, including its special `__name__` matcher. Multiple matchers have AND semantics.                                               |
| `time`           | rfc3339 / unix timestamp      | No       | `end`                    | Instant evaluation time for `expr`.                                                                                                                                                              |
| `lookback_delta` | duration / float seconds      | No       | server default           | Lookback used both to evaluate `expr` and to select matching info series.                                                                                                                        |
| `timeout`        | duration / float seconds      | No       | `--query.timeout`        | Shared timeout for expression evaluation and the subsequent info-series search. Explicit values are capped by `--query.timeout`.                                                                 |
| `start`, `end`   | rfc3339 / unix timestamp      | No       | last 1h                  | Storage search window when `expr` is absent. With `expr`, `start` must parse but is ignored for range selection and ordering validation; `end` supplies the default `time`.                      |
| `search[]`       | []string                      | No       |                          | At most 32 search terms, matched against names or values according to the endpoint. Multiple terms have OR semantics.                                                                            |
| `fuzz_threshold` | int [0..100]                  | No       | 0                        | Fuzzy-score threshold. At 0, `subsequence` accepts any subsequence match; `jarowinkler` performs substring matching only.                                                                        |
| `fuzz_alg`       | `jarowinkler` / `subsequence` | No       | `subsequence`            | Fuzzy algorithm, following the current Prometheus search implementation.                                                                                                                         |
| `case_sensitive` | bool                          | No       | true                     | Case sensitivity, as in PROM-74.                                                                                                                                                                 |
| `sort_by`        | `alpha` / `score`             | No       | value ascending          | Ordering, as in PROM-74. `sort_by=score` requires `search[]`.                                                                                                                                    |
| `sort_dir`       | `asc` / `dsc`                 | No       | `asc`                    | Direction for alphabetical ordering. Accepted only with explicit `sort_by=alpha`.                                                                                                                |
| `include_score`  | bool                          | No       | false                    | Include the deterministic relevance score in each record.                                                                                                                                        |
| `limit`          | positive int                  | No       | 100                      | Maximum records returned after filtering and ordering. A positive `--web.search.max-limit` caps explicit values and may reduce the default; 0 disables that operator cap, not the request limit. |
| `batch_size`     | positive int, at most 10000   | No       | 100                      | Requested records per NDJSON batch line. Its effective value is no greater than `limit`.                                                                                                         |

`limit` bounds the endpoint's retained result state and response size. It is passed to the storage search as a hint, but the API does not promise that an implementation can avoid scanning or enumerating additional index data to determine the requested ordered results or `has_more`. Unlike PROM-74's original request table, `limit=0` and `batch_size=0` are rejected.

At most 32 `data_match[]` values may be supplied. Each value must parse as exactly one full PromQL matcher. Clients can therefore preserve every completed matcher from the data-label selector as its original source without classifying `__name__` separately or inventing an operator-prefix encoding.

`match[]` is rejected on both endpoints. It would introduce a second series-scoping mechanism with unclear precedence relative to `data_match[]` and `expr`.

### Scope semantics

`data_match[]` carries the completed matchers from `info()`'s data-label selector. The server partitions them by label name: `__name__` matchers select which info metric families to search, while all remaining matchers filter those info series.

* No name matcher means `__name__="target_info"`.
* `data_match[]=__name__=~".+_info"` selects matching info metric names.
* Repeated name matchers are ANDed, for example `__name__=~".+_info"` and `__name__!="custom_info"`.
* A negative-only request is implicitly restricted by `__name__=~".+_info"`, so `__name__!="target_info"` cannot broaden the search to every non-target metric.

The remaining matchers filter the selected info series before either endpoint discovers names or values. They are ANDed with one another, the effective name matchers, and the expression-derived scope.

When `expr` is present, Prometheus evaluates it as an instant query at `time`, which defaults to `end`. The expression must have instant-vector type; matrix, scalar, and string expressions are rejected before execution. Series already matching the effective info-metric name scope are ignored, consistent with `info()` not enriching info series. An expression that produces no remaining series with a non-empty identifying label returns a successful empty stream rather than falling back to an unscoped search.

The subsequent info-series search uses the same temporal selection hints as an instant `info(expr, ...)` evaluation: it applies the effective lookback delta and honors selector `offset` and `@` modifiers. The general search `start` parameter does not broaden or narrow this expression-derived range.

When every vector-producing path has the same effective reference, including enclosing subquery offsets and `@` anchors, the search uses that shared reference. If the paths disagree or any vector-producing path is selector-free, selection falls back to the query evaluation time rather than choosing an arbitrary selector.

The handler groups expression results by identifying-label presence: `job` only, `instance` only, and both. A missing identifying label becomes an exact empty matcher instead of a wildcard. Within a presence group, observed values become escaped regular-expression alternatives. This avoids false negatives and keeps the number of storage selections bounded by the number of presence patterns rather than the number of expression series. A group containing both labels may conservatively inspect cross-pairs of independently observed `job` and `instance` values. That can make autocomplete suggestions broader, but it cannot change query results: `info()` performs the exact identifying-label join when the completed query executes.

Matcher construction is also bounded before the info-series `Searcher` is opened. At most 10,000 unique `(presence group, identifying label, value)` entries and 1,048,576 total escaped regular-expression bytes, including alternation separators, are accepted. Duplicate values do not consume the value budget. Exceeding either bound returns a pre-stream `bad_data` error asking the caller to narrow `expr`; values are never truncated because truncation could silently omit valid completions.

The name matchers, data matchers, and `expr` apply jointly. Expression warnings are merged with storage warnings and exposed on the stream.

Suggestions are indexed candidates within this scope. The temporal selection hints restrict which storage ranges are searched, but do not guarantee that every returned candidate has a sample in that range. Together with conservative identifying-label cross-pairs, this means a suggestion does not establish that the completed query will find a matching sample or successfully join it with `info()`. The endpoints do not provide sample-presence or cardinality guarantees.

Clients must resolve editor-specific variables and macros before sending `expr`, using the same semantics as normal query execution. Otherwise autocomplete and query execution can observe different expressions.

### Security and admission control

An `expr` request is a query, not metadata-only discovery. Response presence can depend on sample values, for example `expr=up == 0`, even though the response contains only label names or values. Expression evaluation and the subsequent info-series search must therefore use the same request and tenant context, and callers must have the same query authorization required by `/api/v1/query`.

Deployments whose authorization layer cannot distinguish requests by form or query parameter must protect both endpoint routes as query surfaces, including requests that omit `expr`. The endpoints consolidate existing discovery operations, but `expr` makes it incorrect to claim that their observable result is limited to metadata already available through label APIs.

### `GET|POST /api/v1/search/info_labels`

This endpoint searches non-identifying label names on the scoped info series. `__name__`, `job`, and `instance` are filtered before the result limit is applied, so they cannot consume autocomplete slots.

The `label` parameter is rejected; callers seeking values must use `/api/v1/search/info_label_values`.

Example:

```bash
curl -N -g 'http://localhost:9090/api/v1/search/info_labels?expr=rate(http_requests_total{job="api"}[5m])&data_match[]=__name__=~".+_info"&data_match[]=env="prod"&search[]=ver&sort_by=score&include_score=true'
```

```ndjson
{"results":[{"name":"version","score":1},{"name":"server","score":0.9435}]}
{"status":"success","has_more":false}
```

### `GET|POST /api/v1/search/info_label_values`

This endpoint requires `label`, interpreted as one exact decoded label name. It is a query parameter rather than a path component so UTF-8 label names do not require a second path-specific quoting contract.

Empty `label`, `__name__`, `job`, and `instance` are rejected because they are not info data labels. `search[]`, if present, filters and ranks values of the selected label; it never changes which label is selected.

Example:

```bash
curl -N -g 'http://localhost:9090/api/v1/search/info_label_values?label=version&expr=rate(http_requests_total{job="api"}[5m])&search[]=v2&sort_by=score'
```

```ndjson
{"results":[{"value":"v2.0"},{"value":"v2.1"}]}
{"status":"success","has_more":false}
```

### Feature gating

Both endpoints require:

* `--enable-feature=search-api`, for the experimental search and NDJSON infrastructure.
* `--enable-feature=promql-experimental-functions`, because this API serves the experimental `info()` function.

Missing gates return the standard non-streaming Prometheus JSON error with `errorType: unavailable`; the message names every missing feature in one response.

`GET /api/v1/features` advertises the pair through `data.api.info_label_search`. It is `true` only when both flags are enabled and Prometheus is running in server rather than Agent mode. This advertises that the routes are enabled, not that every storage backend participating in a particular request supports search; clients must still handle a per-request `unavailable` response. Clients must treat an absent or false value as unsupported and ignore unknown feature keys. Development PoCs targeting servers that predate this capability may retain an explicit, off-by-default operator override.

### Timeout and cancellation

`timeout` uses the same duration and float-seconds syntax as `/api/v1/query`. The effective duration is the shorter of the requested value and `--query.timeout`; when omitted, the server flag supplies the duration. One deadline covers expression evaluation and the subsequent context-aware storage search, so time spent evaluating `expr` reduces the time remaining for discovery.

Expiry before streaming returns the normal Prometheus JSON error with HTTP 503 and `errorType: timeout`. Expiry after a batch has been written terminates the NDJSON stream with an error record carrying `errorType: timeout`; partial results are not successful or cacheable. Caller cancellation remains an abrupt EOF without a terminal record.

### Stream completeness

A non-2xx response uses the standard Prometheus JSON error format and is not an NDJSON stream. A terminal `status: success` establishes that the stream completed successfully. For example, a complete name response without truncation is:

```ndjson
{"results":[{"name":"region"}]}
{"status":"success","has_more":false}
```

`has_more` reports whether additional distinct, eligible results remain beyond the effective limit after scoping, filtering, and deduplication. Reaching exactly the limit does not itself establish truncation. Neither does an operator reducing the default limit. For example, with `limit=1`, a response with another eligible name ends with:

```ndjson
{"results":[{"name":"region"}]}
{"status":"success","has_more":true}
```

Warnings are independent of stream completion and limit truncation. A backend warning may indicate incomplete discovery even when the stream succeeds with `has_more: false`; that flag does not certify coverage of unavailable backend data. Not every warning means results were lost. For example, a downstream backend that allows partial discovery could return:

```ndjson
{"results":[{"name":"region"}],"warnings":["Some storage sources were unavailable; discovery may be incomplete."]}
{"status":"success","has_more":false}
```

Clients must retain warnings from both batch records and the terminal record, without inferring completeness from warning text or treating every warning as truncation.

A client must reject a response when EOF arrives before a terminal record, a line is malformed, more than one terminal record appears, or content follows the terminal record. A mid-stream error record is terminal. Partial batches must not be returned or cached as a successful response.

Clients should cache only complete successful streams, preserving `has_more` and all warnings with the results. Such a cache entry need not represent exhaustive discovery. Clients should bound cache size and freshness, key entries by the effective resolved request, deduplicate identical in-flight requests, and evict failures so a later request can retry. Clients should normally omit `limit` and accept the operator-controlled default.

Editor integrations should forward every completed matcher in the second `info()` argument as its original full PromQL source. The matcher currently being edited must be omitted, while other matchers on the same label remain in scope. The second argument has no metric-name prefix syntax; clients encountering an unquoted identifier or quoted metric-name prefix must use generic completion rather than synthesizing a `__name__` matcher. Users select another info metric explicitly with a matcher such as `{__name__="build_info", ...}`. Variables and macros must be resolved before the request, and quoted UTF-8 label names must be decoded before use as the exact `label`. Completion for `__name__`, `job`, and `instance` remains the general metric or label completion path because those are not discoverable info data labels.

### Choosing a matching strategy

Clients that want contiguous substring matching can request `fuzz_alg=jarowinkler` with `fuzz_threshold=0`. For example, this searches data-label names containing `region` on production targets associated with the expression:

```sh
curl --no-buffer --get 'http://localhost:9090/api/v1/search/info_labels' \
  --data-urlencode 'expr=rate(http_requests_total{job="api"}[5m])' \
  --data-urlencode 'data_match[]=env="prod"' \
  --data-urlencode 'search[]=region' \
  --data-urlencode 'fuzz_alg=jarowinkler' \
  --data-urlencode 'fuzz_threshold=0'
```

Additional `search[]` terms broaden matching with OR, while additional `data_match[]` matchers narrow the info-series scope with AND. Search terms apply to names on `info_labels` and values on `info_label_values`; the latter still requires one exact `label` selected by the client. Scores describe lexical matching, not semantic confidence or the likelihood that a suggestion will produce query results.

### Storage and performance

The name endpoint calls `Searcher.SearchLabelNames` with the common scope and a filter that excludes identifying labels before applying search and limit. The value endpoint calls `Searcher.SearchLabelValues` with the exact label and the same scope. Composite storage advertises `Searcher` only when every participating non-noop querier does, including secondary and out-of-order readers. This keeps search, scoring, ordering, limiting, and downstream storage optimizations aligned with PROM-74 rather than reimplementing them in an info-specific series extractor.

The optional `expr` adds one standard instant-query evaluation. Existing max-samples and lookback behavior applies, while the endpoint-level deadline continues through the storage search. Query origin metadata is recorded as for `/api/v1/query`, and both phases retain the same request context. The storage search uses the derived matchers over the exact range that `info()` would select.

The `limit` contract bounds result retention and wire output, not the cardinality of the underlying index or the worst-case storage work. The actual work depends on the `Searcher` implementation, matcher selectivity, requested ordering, and whether it can stop early while still determining `has_more`.

### Extensibility for Mimir, Thanos, and Cortex

PROM-74's `include_metadata` illustrates optional enrichment of search results: on `/api/v1/search/metric_names`, it adds metric `type`, `help`, and `unit` when requested and available. That option is not part of this proposal's info-label request contract. Info-label results identify data-label names or values, and a deduplicated result can come from multiple info metrics; metadata about a source metric would not describe the returned label itself. Future enrichment of info-label results fits the Search API model, but needs a separately defined metadata source and schema.

As in PROM-74, downstream implementations may add optional per-record extensions without changing the core record shapes:

```ndjson
{"results":[{"name":"cluster","extensions":{"mimir":{"cardinality":42}}}]}
{"status":"success","has_more":false}
```

The Prometheus implementation does not emit extensions.

### Testing and verification

Required implementation coverage:

* both endpoints over GET and POST;
* the dual feature gate;
* `expr`, repeated `data_match[]` values including `__name__`, negative-only name matching, and their joint scope;
* mixed identifying-label presence and conservative cross-pair scoping without false negatives;
* instant-vector type validation, historical `end`, ignored `start`, and temporal equivalence with `info()` for lookback, offsets, `@` modifiers, equivalent and mixed references, selector-free vector paths, and enclosing subqueries;
* exact matcher-construction bounds, duplicate accounting, and rejection before the info `Searcher` opens;
* exact and UTF-8 label names for value lookup;
* identifying-label filtering and rejection;
* matcher count and syntax validation, and rejection of `match[]` and `label` on the name endpoint;
* search, Jaro-Winkler and subsequence fuzzy matching, scoring, ordering, limit, `has_more`, and batching;
* zero, fewer than, exactly, and more than the effective limit of eligible results, including filtering, cross-block deduplication, and a reduced operator-controlled default;
* substring-only matching at `fuzz_alg=jarowinkler&fuzz_threshold=0`, OR across search terms, and AND across scope matchers;
* successful streams with warnings in batches or the trailer, including `has_more: false`, and preservation of warnings and truncation metadata in cached responses;
* indexed historical candidates and conservative cross-pairs without inferring per-candidate sample presence or a successful runtime join;
* omitted, shorter, capped, invalid, pre-stream, and mid-stream timeout behavior, plus caller cancellation;
* route-capability advertisement for every feature-gate and Agent-mode combination;
* fail-closed behavior for mixed search-capable and incapable primary or secondary storage, while ignoring noop storage;
* searches whose matching labels exist only in out-of-order head data, including ordering and limiting;
* strict client parsing, bounded caches, in-flight deduplication, and retry after failure.

Manual verification can compare names and values against client-side aggregation of `/api/v1/series` for the same info-metric scope and time window.

### Migration

These are new, experimental, opt-in endpoints. No stored-data migration is required. Implementations and PoC clients should use the two-endpoint, repeated-full-matcher contract under `/api/v1/search/`.

## Alternatives

### 1. One combined `{name, values[]}` endpoint

Rejected. Name and value completion are separate user interactions with different search targets and cardinalities. A combined response either eagerly downloads unused values or requires a second `values_limit` dimension. It also turns exact label selection into a fuzzy-name-search workaround and does not map cleanly to PROM-74's `SearchLabelNames` and `SearchLabelValues` interfaces.

If measured client latency later justifies removing the second round trip, an optional `include_values` extension on the name endpoint could be proposed separately. The split endpoints remain the canonical bounded operations, and such an extension would need an explicit independent value bound.

### 2. Reuse `/api/v1/search/label_names` and `/api/v1/search/label_values`

The general endpoints have the right name/value split, but their existing contract does not derive info-series scope from an arbitrary PromQL expression. A mode such as `scope=info` would need a different scoping contract (`data_match[]` and optional `expr` in place of `match[]`) and expression-dependent time semantics. Dedicated endpoints within the same `/api/v1/search/` namespace keep those contracts explicit while sharing implementation and optional result-enrichment patterns.

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
