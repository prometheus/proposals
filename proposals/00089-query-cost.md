## Query cost estimation and limits

* **Owners:**
  * Julien Pivotto [@roidelapluie](https://github.com/roidelapluie)

* **Implementation Status:** Not Implemented.

* **Related Issues and PRs:**
  * `<GH Issues/PRs>`

* **Other docs or links:**

> TL;DR: A single expensive query can hurt a whole Prometheus. We have knobs to cap it (`--query.max-samples`, `--query.timeout`), but no way to tell a user *before* they run a query how expensive it is, and no per-query, reloadable ceilings. This proposal adds a cheap cost *estimate* (series touched, samples scanned) exposed through `/api/v1/query_cost`, reloadable cost *limits* enforced during execution, and an estimated-vs-actual `cost` object on the query response. All behind a `query-cost` feature flag.

## Why

Prometheus already protects itself from runaway queries, but the tools are blunt:

* `--query.max-samples` caps peak samples in memory, not the total scanned.
* `--query.timeout` and `--query.max-concurrency` are process-wide flags, not reloadable and not per-query.
* Nothing tells a user, an autocomplete UI, or an alerting rule author how heavy a query is *before* it runs.

Operators want ceilings they can tune without a restart. Users and tools (Grafana, dashboards, recording rules) want a cheap way to gauge cost up front so they can refuse or rewrite a query before it lands on the server.

### Pitfalls of the current solution

* The existing limits are set at startup. Changing them means a restart.
* They are global. A single tenant or dashboard cannot be given a tighter budget.
* There is no pre-execution estimate. The only way to learn a query's cost today is to run it, which is exactly what we want to avoid for the expensive ones.
* `--query.max-samples` measures peak in-memory samples, which does not map cleanly to "how much index and how many samples did this touch".

## Goals

* Give a cheap, index-based cost *estimate* (series touched, samples scanned) without executing the query.
* Expose the estimate through a new API so clients can gauge cost before running a query.
* Add reloadable cost limits (`query_max_series`, `query_max_samples_scanned`, `query_max_duration`) enforced during execution.
* Let a client *lower* those ceilings per query, never raise them.
* Surface estimated-vs-actual cost on the normal query response, so the estimate can be validated against reality.
* Keep it all opt-in behind a feature flag until the model is proven.

### Audience

Operators running shared Prometheus servers, and UI/tooling authors (Grafana, recording rules) that build queries on a user's behalf.

## Non-Goals

* Not replacing `--query.max-samples`, `--query.timeout`, or `--query.max-concurrency`.
* Not a billing or chargeback system. The numbers are upper bounds, not exact accounting.
* Not a slow-query log.
* Not per-tenant configuration, as Prometheus is not multi-tenant. Limits are global, with per-query lowering only.
* Not exact cost prediction. The estimate is intentionally cheap and approximate.

## How

Three pieces, all gated by `--enable-feature=query-cost`.

**1. Estimation (`promql.EstimateCost`).** Parse the query, walk it for every vector and matrix selector, compute the effective time window each selector reads (mirroring the engine's `getTimeRangesForSelector`/`populateSeries`), and ask storage for the series count per selector via a single querier over the union window. `SeriesTouched` is the sum across selectors — an upper bound, because a series shared between selectors is counted once per selector. `SamplesScanned` models the engine's incremental per-step reads (full range window at step 0, then only the samples that advance past the previous cutoff), scaled by a measured average per-point cost so native-histogram points are sized by bucket rather than counted as one float unit. The estimate is index-only apart from decoding at most `histogramSampleLimit` (50) points per selector to size histograms.

**2. API.** Two new endpoints estimate cost without executing:

```
GET|POST /api/v1/query_cost
GET|POST /api/v1/query_range_cost
```

They take the same parameters as `/api/v1/query` and `/api/v1/query_range` and return:

```json
{
  "estimate": {
    "seriesTouched": 42,
    "samplesScanned": 5040
  }
}
```

The instant and range endpoints also gain a `cost` parameter. When set, the response `data` carries an estimated-vs-actual comparison:

```json
"cost": {
  "estimated": { "seriesTouched": 42, "samplesScanned": 5040 },
  "actual":    { "seriesTouched": 40, "samplesScanned": 4980, "peakSamples": 320 }
}
```

Note: `cost=1` adds a second index lookup on top of executing the query.

**3. Limits.** Three reloadable knobs under `global:`:

```yaml
global:
  query_max_series: 0            # 0 = no limit
  query_max_samples_scanned: 0
  query_max_duration: 0s
```

These are enforced *during* execution against the query's actual running cost, not against the estimate: a query is rejected as soon as it loads too many series or scans too many samples, and `query_max_duration` surfaces as a query timeout. A client may lower any ceiling for a single request via `max_series`, `max_samples_scanned`, `max_query_duration`; these can only tighten, never loosen, the operator-set value. The estimate is never used to reject a query — enforcement is always on the real cost.

### Testing and verification

* Unit tests for limit enforcement (reject paths) in `promql`.
* Estimation-accuracy tests against known fixtures, plus the `cost` object which lets us compare estimated and actual on every executed query.
* API tests for the new endpoints and the `cost` parameter.
* OpenAPI golden files updated for the new paths and schemas.

### Migration

Purely additive and behind a feature flag. Default config (all limits `0`) changes no behaviour. Nothing to migrate.

### Known unknowns

* **Estimate accuracy.** `SeriesTouched` over-counts shared series and series with no in-window samples; `SamplesScanned` assumes samples land exactly at the scrape interval and that sampled series are representative. Is an upper bound the right contract, or do we want something tighter?
* **Scrape interval.** The estimator uses the global scrape interval; per-target intervals are not modelled.
* **Subqueries.** Only one level of nesting is modelled exactly.
* **Lookback delta.** The storage-only estimator uses the package default, not the engine's configured value.
* **Agent mode.** Estimation is unavailable (no queryable index).
* **Config surface.** Should limits live under `global:`, or a dedicated `query:` section?

## Alternatives

1. **Estimate from postings cardinality directly, bypassing `storage.Querier`.** Cheaper, but ties the estimator to the TSDB index and breaks for any other `storage.Queryable` (remote read, federation). Using the portable `Select` path keeps it storage-agnostic.
2. **Reject queries based on the estimate.** Rejected: the estimate is an upper bound and can be wrong in both directions. Rejecting on an estimate would refuse queries that would actually run fine. Enforcement is on real cost; the estimate is advisory only.
3. **Reuse `--query.max-samples` and friends.** They are start-time flags measuring peak in-memory samples, not reloadable and not per-query. Extending them to be reloadable and per-query would overload their meaning; new, clearly-scoped knobs are cleaner.
4. **Do nothing / client-side estimation.** Clients cannot cheaply see the server's index cardinality, so any client-side guess is worse than a server estimate.

## Action Plan

* [ ] `promql.EstimateCost` and the sample-unit cost model
* [ ] `/api/v1/query_cost` and `/api/v1/query_range_cost` endpoints
* [ ] `cost` parameter on instant/range queries (estimated vs actual)
* [ ] Reloadable `query_max_series` / `query_max_samples_scanned` / `query_max_duration` under `global:`
* [ ] Per-query lowering via `max_series` / `max_samples_scanned` / `max_query_duration`
* [ ] `query-cost` feature flag, docs, OpenAPI spec, UI surfacing
