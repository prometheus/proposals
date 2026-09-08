## Query cost estimation and limits

* **Owners:**
  * Julien Pivotto [@roidelapluie](https://github.com/roidelapluie)

* **Implementation Status:** Not Implemented.

* **Related Issues and PRs:**
  * `<GH Issues/PRs>`

* **Other docs or links:**

> TL;DR: A single expensive query can hurt a whole Prometheus. We have knobs to cap it (`--query.max-samples`, `--query.timeout`), but no way to tell a user *before* they run a query how expensive it is, and no per-query, reloadable ceilings. This proposal adds an approximate storage-input cost *estimate* (series touched, samples scanned) exposed through `/api/v1/query_cost`, reloadable cost *limits* enforced during execution, and an estimated-vs-actual `cost` object on the query response. All behind a `query-cost` feature flag.

## Why

Without this feature, Prometheus protects itself from runaway queries with startup limits:

* `--query.max-samples` caps peak samples in memory, not the total scanned.
* `--query.timeout` and `--query.max-concurrency` are startup ceilings and are not reloadable. The existing `timeout` request parameter can already tighten a query's duration.
* Nothing tells a user, an autocomplete UI, or an alerting rule author how heavy a query is *before* it runs.

Operators want ceilings they can tune without a restart. Users and tools (Grafana, dashboards, recording rules) want a cheap way to gauge cost up front so they can refuse or rewrite a query before it lands on the server.

### Pitfalls of the current solution

* The existing limits are set at startup. Changing them means a restart.
* Per-query series and scanned-sample budgets are unavailable, even though duration can already be lowered with `timeout`.
* There is no pre-execution estimate. The only way to learn a query's cost today is to run it, which is exactly what we want to avoid for the expensive ones.
* `--query.max-samples` measures peak in-memory samples, which does not map cleanly to "how much index and how many samples did this touch".

## Goals

* Give a cost *estimate* (series touched, samples scanned) without evaluating the expression, using bounded chunk sampling and index enumeration.
* Expose the estimate through a new API so clients can gauge cost before running a query.
* Add reloadable cost limits (`query_max_series`, `query_max_samples_scanned`, `query_max_duration`) enforced during execution.
* Let a client *lower* those ceilings per query, never raise them.
* Surface estimated-vs-actual cost on the normal query response, so the estimate can be validated against reality.
* Keep it all opt-in behind a feature flag until the model is proven.

### Audience

Operators running shared Prometheus servers, and UI/tooling authors (Grafana) that build queries on a user's behalf.

## Non-Goals

* Not replacing `--query.max-samples`, `--query.timeout`, or `--query.max-concurrency`.
* Not a billing or chargeback system. Estimates can be too high or too low; neither is a guaranteed upper bound.
* Not a slow-query log.
* Not per-tenant configuration, as Prometheus is not multi-tenant. Limits are global, with per-query lowering only.
* Not exact CPU, memory, latency or byte prediction. The estimate measures approximate storage input, not the full work of joins, sorting, aggregation or result construction.

## How

The proposal has three parts, initially gated by `--enable-feature=query-cost`.

**1. Estimation.** Estimate storage input without evaluating the expression. The estimator should use the same query semantics as execution, including selector windows, nested subqueries, offsets, `@`, `start()`/`end()`, and expressions evaluated only once. Series counting should use the storage query interface so the design can support different storage backends.

`SeriesTouched` estimates series reads summed across selectors. Repeated selectors may count a series more than once, as execution also can. It is not a distinct-series count. Index entries may lack in-window samples, and expressions such as `info()` can select additional series at runtime. When such selections cannot be estimated without evaluation, the response should warn that the estimate is incomplete. Neither this figure nor the sample estimate is a guaranteed upper bound.

`SamplesScanned` should approximate the engine's `samplesRead` statistic. Range queries should account for incremental reads as evaluation advances, rather than counting every overlapping range window in full. Disjoint windows, nested evaluation grids and expressions evaluated only once must be treated according to their execution semantics.

Estimates and actual counters must use the same sample units: one per float, with native histograms weighted consistently with the engine's sample accounting. Histogram estimates should account for whether the expression needs bucket data or only histogram statistics. `samplesRead` differs from `totalQueryableSamples`, which includes samples reused across evaluation steps. `peakSamples` is the separate peak-in-memory sample statistic. These measures do not represent process memory in bytes.

The proposed sampling approach has two components:

* **Sample density.** Use a bounded sample of chunks from the selector's actual time window. Observed counts from fully sampled series should constrain extrapolation across leading, trailing and internal gaps. A series cut short by the sampling budget must not be treated as fully observed. Where no complete series can be sampled, observed sample intervals may still inform the estimate.
* **Histogram size.** Use a bounded sample of points to estimate their average cost in engine sample units. A shorter sampling window may reduce work, but it must follow the selector's own timestamp when offsets or `@` modifiers are present. Its representativeness over the full query window remains an assumption.

Both sampling budgets should apply per selector, rather than independently to every matching series. They must bound all chunks or series examined, including those that provide no usable measurement. Exact budget sizes and selection strategies should be chosen through validation rather than exposed as part of the API contract.

Sampling should be automatic wherever storage exposes the required chunk metadata, without a separate request parameter. For storage that cannot provide it, the global scrape interval and float-sized points provide a fallback. That fallback is approximate: job-specific scrape intervals and remote-written data may have different densities.

Bounded sampling does not make estimation constant-cost. Chunk access may require I/O, integrity checks and boundary decoding; index enumeration still scales with matching cardinality and storage blocks. Storage may also buffer work before yielding data. Estimation therefore needs duration and concurrency limits even though it does not evaluate the expression.

**2. API.** Add two endpoints to estimate cost without executing:

```
GET|POST /api/v1/query_cost
GET|POST /api/v1/query_range_cost
```

They accept the corresponding instant or range query parameters, including the same result-type restrictions for range queries. Response-only parameters (`limit`, `stats`, `cost`) are validated and then ignored. The `data` payload is:

```json
{
  "estimate": {
    "seriesTouched": 42,
    "samplesScanned": 5040
  }
}
```

The instant and range endpoints would also gain a `cost=true` boolean parameter. When set, the response `data` carries an estimated-vs-actual comparison:

```json
{
  "cost": {
    "estimated": { "seriesTouched": 42, "samplesScanned": 5040 },
    "actual":    { "seriesTouched": 40, "samplesScanned": 4980, "peakSamples": 320 }
  }
}
```

`cost` is a boolean on/off switch, not a set of levels. It runs a fresh estimation after execution, so it adds work and can cost more than executing a cheap query. If that estimation fails, the successful query result is preserved, `cost` is omitted, and a warning explains the failure.

Actual counters should also be available without another estimation through `stats=true`: `data.stats.samples.seriesTouched`, `samplesRead`, and `peakSamples`. This lets calibration tools call an estimate endpoint and then execute with `stats=true`, without triggering a second estimate through `cost=true`.

Both standalone estimation and post-execution comparisons must respect the engine's query-concurrency limit and apply the effective duration limit, including a lower per-request `max_query_duration`. They also honor the request context and any `timeout` deadline. The comparison is additional work after execution, not a promise that execution plus estimation fits within one engine execution budget; an enclosing request deadline can bound both.

Clients displaying cost should distinguish estimates from actual counters and show warnings about incomplete estimates. They should explain the sample units and avoid presenting estimates as exact predictions.

**3. Limits.** Add three reloadable settings under `global:`:

```yaml
global:
  query_max_series: 0            # 0 = no limit
  query_max_samples_scanned: 0
  query_max_duration: 0s        # 0s = fall back to --query.timeout
```

Enforce these limits *during* execution against actual running cost, not the estimate. The budget must cover the entire query, including input consumed by nested subqueries and expressions evaluated only once. Series and sample limit violations return a `cost_limit` API error; duration limits surface as timeouts. These counters constrain evaluator consumption, but do not prevent all index enumeration or buffering that storage may perform before yielding data.

Clients may lower ceilings through `max_series`, `max_samples_scanned`, and `max_query_duration`. An override above a configured ceiling is rejected rather than silently clamped. Zero or omission does not disable a configured server ceiling; where no series or sample ceiling is configured, a client may introduce one. Estimates are advisory and never reject a query based on their predicted series or sample count.

`query_max_duration` supplies a reloadable execution timeout when the feature is enabled. When unset, the engine falls back to `--query.timeout`. Retain the startup flag while the configuration alternative is experimental and feature-gated; this proposal does not require deprecating it. The `timeout` URL parameter remains available; with the feature enabled it may tighten the effective ceiling, but an explicit request above that ceiling is rejected.

### Testing and verification

Validation should cover both correctness and estimation overhead:

* Verify limit enforcement across the entire query, including nested subqueries, and ensure per-query overrides cannot loosen server ceilings.
* Test parameter validation, cancellation, duration and concurrency limits, API response schemas, and preservation of successful query results when a cost comparison fails.
* Compare estimates with actual counters for representative expressions and data: sparse and short-lived series, gaps across blocks, mixed scrape intervals, native histograms, repeated selectors, joins, nested subqueries, offsets and fixed timestamps.
* Verify sampling budgets when a series is only partially observed or sampled chunks contain no useful interval measurement.
* Measure time and allocations across small queries, high cardinality, multiple blocks and histogram-heavy data, including cold and warm storage.

For accuracy calibration, replay fixed queries against fixed datasets with identical evaluation parameters. Obtain estimates through the cost endpoints and actual counters through execution with `stats=true`. Record warnings, failures and limit rejections as well as counts and timings. This avoids an extra estimation through `cost=true` when comparing the two endpoints separately.

Report estimated/actual ratios and relative error by query shape and data characteristics. Handle zero actual counts separately, and exclude failed executions and unavailable counters from accuracy ratios. Keep HTTP timing distinct from engine execution time, and report peak sample units separately from any process-memory measurements.

Repeated runs can characterize timing variability but do not provide independent accuracy observations on the same dataset. Representative production snapshots and query corpora are needed before making accuracy guarantees or reconsidering the feature flag.

### Migration

The estimate endpoints and reloadable limits are opt-in behind the feature flag. Zero series/sample limits add no ceiling, and zero duration retains the existing `--query.timeout` behavior. Existing startup limits remain available. Enabling the feature also enables its per-query override validation, including rejection of requests above the effective duration ceiling.

### Open questions and tradeoffs

* **Accuracy contract.** Both estimates may overestimate or underestimate. Observed sample counts can constrain extrapolation, but index matches, evaluation-grid alignment and incomplete sampling still matter. What accuracy is useful enough for clients to make decisions?
* **Sampling representativeness.** Taking only the first chunks or series may favor particular populations or earlier periods. Long series can exhaust a budget before any series is fully observed. Density and histogram-size samples may also describe different populations. How should bounded sampling cover heterogeneous data?
* **Runtime selections.** Functions such as `info()` can select additional series during evaluation. Can those reads be estimated meaningfully without evaluating the expression, or should they remain explicitly outside the estimate? Runtime enforcement must include them either way.
* **Scrape interval.** The global interval is an imperfect fallback for job-specific intervals and remote-written data. Could storage expose better density information without making the design dependent on one backend?
* **Execution work and units.** Storage input does not predict join complexity, aggregation, sorting, result construction, CPU time or total memory. Should a future model expose additional measures, including bytes?
* **Overhead.** Index enumeration and storage buffering can dominate despite bounded sampling. Cold blocks, long ranges, large cardinalities and remote storage need separate evaluation. Estimation may cost more than executing a cheap query.
* **Provenance and confidence.** Would clients benefit from knowing the sampling coverage, fallback assumptions and omitted runtime selections? Any confidence measure would need calibration against representative workloads.
* **Config surface.** This proposal places limits under `global:`. Would a dedicated `query:` section be preferable?

## Alternatives

1. **Estimate from postings cardinality directly, bypassing `storage.Querier`.** Cheaper, but ties the estimator to the TSDB index and breaks for any other `storage.Queryable` (remote read, federation). Using the portable `Select` path keeps it storage-agnostic.
2. **Reject queries based on the estimate.** Rejected as the default: the estimate can be wrong in both directions, so rejecting on it would refuse queries that would actually run fine. Enforcement is on real cost; the estimate is advisory only. There is a fair argument that letting a query that will almost certainly be limited run and fetch data anyway is wasteful. If the estimate proves accurate enough in practice (validated via the `cost` object's estimated-vs-actual comparison), an *opt-in* upfront rejection — reject before execution when the estimate clearly exceeds a ceiling — could be added later as a follow-up without changing the real-cost enforcement that remains the backstop.
3. **Reuse `--query.max-samples` and friends.** Existing startup flags cover peak samples, duration and concurrency; they do not supply series or scanned-sample budgets. The new series/sample settings measure different quantities, while `query_max_duration` adds a reloadable duration setting and retains the startup fallback.
4. **Do nothing / client-side estimation.** Clients cannot cheaply see the server's index cardinality, so any client-side guess is worse than a server estimate.

## Action Plan

1. Agree on cost semantics, API shape, configuration and the experimental rollout.
2. Add estimation endpoints, actual-cost statistics and optional comparisons.
3. Add reloadable limits with query-wide accounting and bounded estimation work.
4. Validate correctness, accuracy and overhead using synthetic fixtures and representative production workloads.
5. Gather operator and client feedback, then revisit sampling choices and the feature flag.
