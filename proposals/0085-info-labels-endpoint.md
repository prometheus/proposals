## Info-metric label discovery API for `info()` autocomplete

* **Owners:**
  * Arve Knudsen [@aknuds1](https://github.com/aknuds1) arve.knudsen@gmail.com
  * Ismail Simsek [@itsmylife](https://github.com/itsmylife) ismail.simsek@grafana.com

* **Implementation Status:** Not implemented upstream ([WIP implementation PR](https://github.com/prometheus/prometheus/pull/17930))

* **Related Issues and PRs:**
  * [PROM-74 — V2 API for labels and values discovery](https://github.com/prometheus/proposals/pull/74). This proposal builds on PROM-74's NDJSON contract, feature gate, and shared parameter set.
  * [PROM-37 — Simplify joins with info metrics in PromQL](./0037-native-support-for-info-metrics-metadata.md). Introduces the `info()` PromQL function; the proposed endpoint supports its autocomplete.
  * [Grafana Prometheus datasource PR #244](https://github.com/grafana/grafana-prometheus-datasource/pull/244). Independent client PoC for `info()` data-label autocomplete using this endpoint.

* **Other docs or links:**
  * PromQL `info()` function documentation in `docs/querying/functions.md`.

> TL;DR: Add `GET|POST /api/v1/info_labels` as the info-metric companion to the experimental `/api/v1/search/*` family. The endpoint streams the non-identifying data labels of info metrics (e.g. `target_info`) as NDJSON. Queries can be scoped either by an explicit info-metric specifier (`metric_match`), or by evaluating a PromQL expression (`expr`) and harvesting its identifying labels. The endpoint reuses PROM-74's NDJSON contract, fuzzy/sort/score/limit/batch parameters, and `--enable-feature=search-api` gate. It additionally requires `--enable-feature=promql-experimental-functions`, since its only purpose is to support autocomplete for the experimental `info()` function.

## Why

The PromQL `info()` function (added under `--enable-feature=promql-experimental-functions`) enriches base metrics with the data labels carried on info metrics like `target_info`. A PromQL editor offering autocomplete inside `info(<base>, {…})` needs to know **which data labels are available for the in-scope info metrics**, where the in-scope set is determined by the user's in-progress expression.

This is a new gap created by the introduction of `info()` itself — it is not specific to any one editor or vendor. Anyone building a PromQL editor that supports `info()` will hit the same problem.

The Prometheus UI PoC integrates the endpoint through `web/ui/module/lezer-promql/src/client/`. Grafana has a separate Monaco-based client PoC, demonstrating that the endpoint contract is usable without sharing Prometheus' editor implementation.

### Pitfalls of the current solution

Constructing an equivalently scoped interaction with the endpoints that exist today requires either fetching far more than needed or combining endpoints that cannot express arbitrary-PromQL info-metric scoping consistently.

* **`/api/v1/labels` + per-name `/api/v1/label/{name}/values`** returns *all* labels matching a selector, including labels carried by the base metric, not just data labels on info metrics. Filtering client-side requires downloading the full universe of labels and then making one `/label/{name}/values` call per label of interest (N+1).
* **`/api/v1/series` + client aggregation** returns one row per series, then the client must dedupe labels and prune identifying labels. The wire size is O(series), and there is no server-side scoring for relevance ranking.
* **`/api/v1/search/label_names` + `/api/v1/search/label_values`** (from PROM-74) is closer, but neither endpoint understands the info-metric scoping pattern (find label names on info metrics whose identifying labels intersect with a PromQL expression's result set). A client can defer the value lookup until the user selects a name, avoiding eager 1 + N calls, but it still has to reproduce the missing info-metric scoping across two endpoint families.
* **`/api/v1/search/*` with `match[]` alone** cannot scope autocomplete to be context-aware against arbitrary PromQL like `rate(http_requests_total[5m])`, which is what users actually type. The endpoint needs to evaluate an expression and harvest its identifying labels, not merely accept a series selector.

For interactive autocomplete this manifests as visible latency on every keystroke and unnecessary load on the server.

## Goals

* One bounded round-trip for each autocomplete interaction: discover label names, then fetch values only for the label the user selects.
* Server-side scoping by either an explicit info-metric specifier (`metric_match`) or by evaluating a PromQL expression (`expr`) and using its identifying labels.
* Reuse PROM-74's NDJSON contract, search/fuzzy/sort/score/limit/batch parameters, and `--enable-feature=search-api` gate so operators see one coherent experimental autocomplete API surface.
* Couple the endpoint to the function it serves: also require `--enable-feature=promql-experimental-functions`, so an operator cannot reach a state where the endpoint is up but `info()` queries fail to parse.
* Give callers independent caps for label names and values, and provide predictable degradation under pathological input (e.g. `target_info` with very high `version`/`env`/`region` cardinality, or a `metric_match` that matches far more than expected).

## Non-Goals

* Replace or modify `/api/v1/labels` or `/api/v1/label/{name}/values`.
* Add or modify the `/api/v1/search/*` family. This proposal *builds on* PROM-74; it does not extend it.
* Server-side evaluation of `info()`. This is a metadata endpoint; `info()` queries continue to use `/api/v1/query`.
* Cursor-based pagination. Same stance as PROM-74; `has_more` is informational only.
* Special handling of `__type__` / `__unit__` labels. They are not in `infohelper.DefaultIdentifyingLabels` (which is `{"instance", "job"}`), so they pass through the extractor as ordinary data labels and may appear in the response if set on info metrics.

## How

A new endpoint, gated behind two feature flags, that streams NDJSON using the same wire framing (batches + trailer) as `/api/v1/search/*`. The per-record shape is `/info_labels`-specific (`{name, values, score?}`).

### Implementation notes

* The parameter set extends PROM-74's shared parameters (`search[]`, `fuzz_*`, `sort_*`, `include_score`, `start`, `end`, `limit`, `batch_size`) with three /info_labels-specific parameters: `expr`, `metric_match`, and `values_limit`.
* `match[]` is not accepted. Scoping happens via `metric_match` (which info metrics to consider) and `expr` (which identifying-label values to restrict to). Accepting `match[]` as well would create two equivalent matcher mechanisms with unclear precedence.
* The response unit is one record per data label name, carrying that label's values inline. Clients should use different limits for the two autocomplete phases instead of eagerly retrieving all values for every candidate name.
* The response is NDJSON (`application/x-ndjson`) with the same batch + trailer contract as PROM-74.
* The endpoint is dual-gated: `--enable-feature=search-api` covers the NDJSON + parsing infrastructure it reuses; `--enable-feature=promql-experimental-functions` covers the only consumer (`info()`). Either missing flag returns the standard Prometheus JSON error with `errorType: unavailable` and a flag-specific message.

### Client integration feedback

The independent Grafana PoC validates the request and response shape while exposing several requirements that apply to PromQL editors generally:

* `expr` must be valid PromQL. Clients with editor-specific variables or macros must resolve them with the same semantics as normal query execution before sending the request.
* Each request must use the current query time range. A client cache should be bounded and freshness-limited, keyed by the effective resolved request, retain only complete successful responses, and allow retries after failures.
* A label-name completion request should send the current `start`/`end`, resolved `expr`, optional `metric_match`, and typed `search[]`. Omitting `limit` uses the server's at-most-100-name default, reduced further when the operator configures a lower maximum; `values_limit=1` prevents the name-completion response from carrying every value for every name.
* A label-value completion request can use the existing search contract with `search[]=<unquoted-label-name>`, `fuzz_alg=subsequence`, `fuzz_threshold=100`, `case_sensitive=true`, `sort_by=alpha`, `sort_dir=asc`, `limit=1`, and an explicit client-selected `values_limit`. Subsequence prefix matches can tie with the exact name, so the client must still verify that the returned record name equals the requested name before using its values.

The last request profile is a bounded workaround, not an exact-name API primitive. A first-class name-only mode and exact-name filter remain open design questions.

### `GET|POST /api/v1/info_labels`

#### Request

**Method:** `GET` or `POST`

`POST` is recommended when the `expr` parameter exceeds URL length limits.

**Path:** `/api/v1/info_labels`

**Query parameters:**

| Name             | Type                     | Required | Default                                 | Description                                                                                                                                                                                                               |
|------------------|--------------------------|----------|-----------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `expr`           | string (PromQL)          | No       |                                         | Optional PromQL expression evaluated server-side. Identifying labels (`job`, `instance`) extracted from the result restrict the info-metric query so autocomplete sees only the labels relevant to the user's expression. |
| `metric_match`   | string                   | No       | `target_info` (exact)                   | Info-metric specifier. Bare value (no prefix) is exact match; `=~` / `!=` / `!~` prefixes give the corresponding matcher type (e.g. `target_info`, `=~.*_info`, `!=target_info`, `!~build_info`).                         |
| `search[]`       | []string                 | No       |                                         | One or more search terms matched against data label NAMES (OR semantics). As per PROM-74.                                                                                                                                 |
| `fuzz_threshold` | int [0..100]             | No       | 0                                       | Fuzzy threshold. As per PROM-74.                                                                                                                                                                                          |
| `fuzz_alg`       | string                   | No       | `subsequence`                           | Fuzzy algorithm. As per PROM-74.                                                                                                                                                                                          |
| `case_sensitive` | bool                     | No       | true                                    | As per PROM-74.                                                                                                                                                                                                           |
| `sort_by`        | `alpha` / `score`        | No       |                                         | As per PROM-74.                                                                                                                                                                                                           |
| `sort_dir`       | `asc` / `dsc`            | No       | `asc`                                   | As per PROM-74.                                                                                                                                                                                                           |
| `include_score`  | bool                     | No       | false                                   | As per PROM-74.                                                                                                                                                                                                           |
| `start`, `end`   | rfc3339 / unix_timestamp | No       | last 1h                                 | As per PROM-74.                                                                                                                                                                                                           |
| `limit`          | int ≥ 0                  | No       | 100, capped by `--web.search.max-limit` | Maximum number of label NAMES returned. Same `has_more` semantics as PROM-74.                                                                                                                                             |
| `values_limit`   | int ≥ 0                  | No       | 0 (no cap)                              | Maximum number of values returned per label. New to this endpoint.                                                                                                                                                        |
| `batch_size`     | int > 0                  | No       | 100                                     | As per PROM-74.                                                                                                                                                                                                           |

**Notes:**

***Feature gating***

The endpoint requires *both* `--enable-feature=search-api` (NDJSON + parsing infrastructure) and `--enable-feature=promql-experimental-functions` (the only consumer is `info()` autocomplete; without `info()`, no client can use the response). The handler checks both flags upfront and, if either is missing, responds with the standard non-streaming JSON error (`errorType: unavailable`) carrying a single message that names every missing flag, so an operator sees the whole gap in one round-trip:

* `"info_labels requires --enable-feature=search-api"` — only search-api missing.
* `"info_labels requires --enable-feature=promql-experimental-functions"` — only experimental-functions missing.
* `"info_labels requires --enable-feature=search-api,promql-experimental-functions"` — both missing.

***expr***

If `expr` is provided, the server evaluates it as an instant query at the request's `end` timestamp. The result must be a Vector or Matrix; Scalar/String returns `errorBadData`. The server harvests the identifying labels (`job`, `instance`) from each sample/series and uses their values as additional matchers against the info-metric query. If the eval produces no identifying-label values, the stream consists of a single empty batch (carrying any warnings) followed by the success trailer.

The endpoint accepts PromQL, not editor-specific template syntax. A client must resolve local variables and macros before sending `expr`; using the same interpolation path as normal query execution avoids autocomplete evaluating a different expression than the query itself.

This is what makes the endpoint context-aware: `expr=rate(http_requests_total[5m])` gives an autocomplete experience scoped to the info metrics actually relevant to that PromQL expression, without requiring the client to interpret PromQL itself.

When `metric_match` is also set, the two filters apply jointly: an info-metric series must match `metric_match`'s name pattern AND have identifying labels intersecting the `expr` eval result. This lets callers narrow both the info-metric family (e.g. `metric_match==~.*_info`) and the relevant series (e.g. `expr=rate(http_requests_total[5m])`).

***metric_match***

Specifies which info metrics to consider. Prefix syntax mirrors PromQL matcher operators:

* `metric_match=target_info` → `__name__="target_info"` (default)
* `metric_match==~.*_info` → `__name__=~".*_info"`
* `metric_match=!=target_info` → `__name__!="target_info"`
* `metric_match=!~build_info` → `__name__!~"build_info"`

The double-equals in `metric_match==~.*_info` is not a typo — the first `=` is the URL form-value separator and the second `=` is the matcher-type prefix.

Clients deriving `metric_match` from a PromQL `__name__` matcher must preserve the full operator. In particular, a regex matcher is encoded as the form value `=~.*_info`; dropping the leading `=` changes it into an exact metric name.

***match[]***

Not accepted. Requests carrying `match[]` are rejected with `errorBadData`: `"match[] is not supported by info_labels; use metric_match or expr"`.

***values_limit***

Caps the number of values per label. Distinct from `limit`, which caps the number of records (per PROM-74's semantics). Values are sorted alphabetically and truncated after the sort, so the truncation is deterministic.

The two dimensions multiply: a response can contain up to `limit * values_limit` values when both are non-zero. Omitting `values_limit`, or setting it to zero, leaves value cardinality uncapped. Interactive clients should therefore always set it explicitly.

To make `values_limit` a server-memory bound as well as a wire bound, implementations must enforce it while collecting values, retaining only the lexicographically smallest values needed for the deterministic result. Collecting every distinct value and truncating only after the scan bounds the response but not extractor memory.

***start/end***

The default window is the last hour (inherited from PROM-74's `parseSearchParams`). This is conservative — info metrics like `target_info` typically only emit one sample per scrape and may be scraped infrequently, so a deployment with a long scrape interval and an idle window can land outside a 1-hour lookback and return no data. Operators with infrequent scrapes should pass an explicit `start` to widen the window; interactive clients should pass the current editor time range rather than retaining the range from editor initialization. See Known unknowns for the open question of whether `/info_labels` should ship with a longer default than `/search/*`.

***Storage***

The endpoint uses the existing `storage.Querier` interface, not PROM-74's `Searcher`. The unit of work — enumerate info-metric series, collect their non-identifying labels deduped across series, with values — does not map onto `SearchLabelNames` (which returns names without values and would force one `SearchLabelValues` call per name). The search-api `storage.Filter` produced by `buildSearchFilter` is applied to label names in-memory inside the extractor loop, so fuzzy/score behaviour is identical to `/api/v1/search/label_names` for the same input names (iteration order differs because `/info_labels` is series-driven rather than index-driven, but the difference is invisible once results pass through the post-sort).

***Security***

* `expr` is evaluated through the standard `QueryEngine`, so the existing per-query timeout, max-samples limit, and any deployed query authorisation policy apply unchanged. The endpoint adds no new evaluation path.
* The `namesLimit` cap described in the *Memory bound* note bounds the number of distinct label names, but not the number of values retained for each name. An implementation must apply the name cap to all retained per-name state and enforce a positive `values_limit` during extraction to bound both dimensions; requests with an omitted or zero `values_limit` remain unbounded in the value dimension.
* The endpoint exposes no metadata that a caller cannot already obtain by combining `/api/v1/labels`, `/api/v1/label/{name}/values`, and client-side post-filtering. It packages the same information more efficiently; it does not widen the read surface.
* Expensive `expr` is bounded by the existing QueryEngine timeout and max-samples (`--query.timeout`, `--query.max-samples`); `/info_labels` adds no further protection beyond what `/api/v1/query` already enforces.

***Memory bound***

The extractor drains all matching info-metric series before streaming the first batch. To prevent unbounded growth in distinct names on pathological `metric_match` values (e.g. one that matches the entire metric universe), the extractor caps the number of names it collects at `--web.search.max-limit` (default 10000; setting the flag to 0 disables the name cap). The cap applies to all retained per-name state, including memoized filter decisions. Once the cap is hit, the extractor keeps draining the series set to gather values for already-collected names but does not retain state for not-yet-seen names, and a warning is surfaced in the first batch.

Value cardinality is an independent dimension. With a positive `values_limit`, the extractor must retain at most that many values per collected name while preserving the lexicographically smallest values for deterministic output. With `values_limit` unset or zero, values remain unbounded by this endpoint. The extractor is fully memory-bounded by these dimensions only when both the operator name cap and a positive per-request value cap are active.

`sort_by=score` under a hit cap may miss the true top-N because some high-scoring names were never seen — documented as a known limitation; operators who want full coverage can raise the cap. Streaming gives clients incremental rendering after the storage scan completes; it does not eliminate the scan itself.

***Performance***

* Time: O(series matching `metric_match`) × O(labels per series). Per-series work is one label-set iteration plus filter evaluation. Decisions for retained names can be memoized; names encountered after the cap may be re-evaluated rather than retained, trading bounded memory for repeated filter work.
* Memory: with a positive `values_limit` enforced during extraction, bounded by `namesLimit` (distinct names) × `values_limit` (values per name) × average value length. With the defaults (`--web.search.max-limit=10000`, no `values_limit`), the values dimension is bounded only by the data's natural cardinality. A post-scan truncation does not provide this memory bound.
* No additional storage round-trips beyond the one info-metric `Select`. The optional `expr` adds one instant-query evaluation through the standard QueryEngine path.

#### Response

* `Content-Type: application/x-ndjson; charset=utf-8`

Zero or more `{results, warnings?}` batch lines, followed by a `{status, has_more, warnings?}` trailer, or — on mid-stream failure after the first batch has been written — a `{status, errorType, error}` line in place of the trailer. Errors that occur before the first batch is written are returned as the usual non-streaming Prometheus JSON error with the matching 4xx/5xx status code.

This is the same contract as the `/api/v1/search/*` endpoints.

The terminal record defines stream completeness. A client must reject the response if EOF occurs before a terminal success or error record, if a line is malformed, if more than one terminal record appears, or if content follows the terminal record. Partial batches must not be treated or cached as a successful response.

URLs in the examples below are shown unescaped for readability — single-quote them on the shell or let curl perform the percent-encoding.

##### Example: no scoping

```ndjson
{"results":[{"name":"cluster","values":["us-east","us-west"]},{"name":"env","values":["prod","staging"]},{"name":"region","values":["us-east"]},{"name":"version","values":["v1.0","v2.0","v2.1"]}]}
{"status":"success","has_more":false}
```

##### Example: scoped by expression

```bash
curl -N 'http://localhost:9090/api/v1/info_labels?expr=rate(http_requests_total{job="api-gateway"}[5m])'
```

```ndjson
{"results":[{"name":"cluster","values":["us-east","us-west"]},{"name":"env","values":["prod","staging"]},{"name":"version","values":["v1.0","v2.0"]}]}
{"status":"success","has_more":false}
```

##### Example: scoped by search with relevance scoring

```bash
curl -N 'http://localhost:9090/api/v1/info_labels?search[]=ver&sort_by=score&include_score=true'
```

```ndjson
{"results":[{"name":"version","values":["v1.0","v2.0","v2.1"],"score":1},{"name":"server","values":["nginx","envoy"],"score":0.83}]}
{"status":"success","has_more":false}
```

##### Example: `match[]` rejected

```bash
curl -N 'http://localhost:9090/api/v1/info_labels?match[]={job="prometheus"}'
```

```json
{"status":"error","errorType":"bad_data","error":"match[] is not supported by info_labels; use metric_match or expr"}
```

##### Example: names truncated at namesLimit

When the extractor hits the `--web.search.max-limit` cap, the first batch carries a warning naming the cap and what to do about it. The trailer's `status` stays `success` because the result set is still well-formed — just incomplete.

```ndjson
{"results":[{"name":"cluster","values":["us-east","us-west"]},...],"warnings":["info-labels names truncated at 10000; narrow metric_match or raise --web.search.max-limit"]}
{"status":"success","has_more":false}
```

### Interface changes

Smaller than PROM-74's contribution. This proposal does not introduce new storage interfaces:

* PROM-74's `Searcher.SearchLabelNames` is not used; the endpoint stays on `storage.Querier`.
* The search-api request preamble (CORS, feature-gate, form parsing, `parseSearchParams`, querier acquisition, `buildSearchFilter`, sort/order plumbing) is factored out of `newSearchRequest` into a reusable `newAutocompleteRequest` so both `/api/v1/search/*` and `/api/v1/info_labels` share it. This is a small refactor of code that landed with PROM-74: `newSearchRequest` is preserved as a thin wrapper that adds the `storage.Searcher` type assertion the search-api endpoints require.
* A small helper package (`promql/infohelper`) exposes `ExtractDataLabels(ctx, querier, infoMetricMatcher, identifyingLabelValues, hints, filter, namesLimit, valuesLimit) → []InfoLabelRecord` where `InfoLabelRecord = {Name, Values, Score}`. The filter is applied to label names; the score carries through to the wire when `include_score=true`.

### Extensibility for Mimir, Thanos, Cortex

The per-record JSON shape inherits PROM-74's extensibility story: downstream implementations can add an `extensions` field per record (and an `extensions` map keyed by provider name) without changing the core contract. No new mechanism is required.

```ndjson
{"results":[{"name":"cluster","values":["us-east","us-west"],"extensions":{"mimir":{"cardinality":42}}}]}
{"status":"success","has_more":false}
```

The pure Prometheus implementation does not include an `extensions` field. Downstream implementations adding it should tag it `json:",omitempty"` so records without provider-specific data stay clean on the wire.

### Testing and verification

* **Recommended manual verification (not automated today):** a client can enumerate `target_info` series via `/api/v1/series`, dedupe label names client-side, and compare against `/api/v1/info_labels` output for the same time window.
* The implementation's unit tests cover the parameter surface, the dual gate, `match[]` rejection, sort/score/fuzzy combinations, `values_limit` truncation, multi-batch streaming, and error paths (invalid expr, scalar result, queryable error).
* Extraction tests must also verify that the name and value limits constrain retained state during the scan, not only the final response.
* The Grafana client PoC validates independent editor integration, including expression scoping, metric matching, label-name and label-value completion, and buffered NDJSON consumption. Its production-readiness review motivated the bounded request profiles and completeness requirements documented above.

### Migration

New endpoint. Both feature flags it depends on are experimental and opt-in. No migration is required.

### Known unknowns

* **Default start/end lookback.** Aligned with PROM-74's 1h default via the shared `parseSearchParams` helper. Reasonable, but `target_info` can be sparse on short windows — reviewers may want a longer default specific to `/info_labels`.
* **Whether to accept `match[]` in addition to `expr`.** The current design rejects it on cohesion grounds; reviewers may push back.
* **Whether identifying labels should be configurable per request.** Today the set is `{"job", "instance"}` from `infohelper.DefaultIdentifyingLabels`. Per-request override is plausible if downstream implementations have different identifier conventions.
* **One combined `info-labels-api` flag.** Rejected here on grounds of flag proliferation, but worth re-litigating if reviewers prefer a single-flag operator UX.
* **First-class name-only and exact-name requests.** The current contract can bound name discovery with `values_limit=1` and emulate exact lookup with strict search parameters plus client-side verification, but dedicated semantics would be clearer and avoid returning an unused value during name completion.
* **A bounded default for values.** Leaving `values_limit` unset preserves all values but leaves response size and extractor memory unbounded in that dimension. A future revision may prefer a server default or operator cap.

## Alternatives

### 1. Extend `/api/v1/search/label_names` to optionally return values per name

Would collapse two endpoints into one. Rejected on cohesion grounds: PROM-74 keeps names and values in separate endpoints precisely so that each endpoint's response shape stays simple. The values payload is only useful when the names are scoped to info metrics, so the coupling does not belong on the general search endpoint.

### 2. Add per-name expansion via a follow-up `/api/v1/search/label_values` call

An interactive client can defer this call until the user selects a label, making the normal path two requests rather than an eager 1 + N requests. This is viable, but the search endpoints cannot apply the `expr`-derived info-metric scope, so the client cannot keep name and value results consistently scoped for arbitrary PromQL. The dedicated endpoint uses the same scoping contract for both phases.

### 3. Pure client-side composition (`/api/v1/labels` + `/api/v1/label/{name}/values` + filter)

Feasible today but slow at scale and does not address the info-metric-specific scoping. In particular it cannot evaluate a PromQL expression server-side to harvest identifying labels, so the autocomplete cannot be context-aware against arbitrary PromQL.

### 4. Subsume into a hypothetical `/api/v1/info()` evaluation endpoint

Out of scope. `info()` is a PromQL function that already uses the existing `/api/v1/query` flow. `/api/v1/info_labels` is a metadata endpoint that supports building the queries; it is not a query endpoint itself.

### 5. Use `match[]` instead of `expr`

`match[]` can only express series selectors, not arbitrary PromQL like `rate(http_requests_total[5m])`. Autocomplete must work against expressions users actually type, not the subset that fits inside a series selector.

## Action Plan

* [X] Build a working implementation (working branch `arve/info-autocomplete` in `aknuds1/prometheus`).
* [X] Add the dual feature-gate check to the implementation (search-api + promql-experimental-functions).
* [X] Open the [WIP upstream implementation PR](https://github.com/prometheus/prometheus/pull/17930).
* [ ] Finalize this proposal based on community feedback.
* [ ] Update `docs/querying/api.md` (the implementation already includes this; the action item is post-merge alignment).
