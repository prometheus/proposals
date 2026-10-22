## Scrape-time Rule Evaluation

* **Owners:**
  * [@roidelapluie](https://github.com/roidelapluie)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [Original feature request](https://github.com/prometheus/prometheus/issues/394)

> This proposal introduces the ability to evaluate PromQL expressions at scrape time against raw metrics from a single scrape, before any relabeling occurs. This enables the creation of derived metrics that combine values from the same scrape without the time skew issues inherent in recording rules or query-time calculations. Additionally, by evaluating before relabeling, this enables powerful cardinality reduction strategies where aggregated metrics can be computed and stored while dropping the original high-cardinality metrics.

## Why

Prometheus users frequently need to calculate derived metrics by combining values from multiple related metrics. A common example is calculating "Memory Used" from /proc/meminfo statistics, which requires subtracting available memory from total memory. Currently, users must either:

1. Calculate these at query time, which can become complex and repetitive
2. Use recording rules, which run at their own interval separate from scraping

Beyond that, scrape-time rules enable powerful cardinality management strategies. For example, an application might expose 100 detailed per-component metrics, but for long-term storage, you only need the aggregate total. With scrape-time rules, you can:

1. Create a `sum()` rule that aggregates the 100 metrics into a single metric
2. Use `metric_relabel_configs` to drop the original 100 detailed metrics
3. Store only the aggregate, reducing cardinality by 99%

This is only possible because rules evaluate before relabeling. If you tried to do this with recording rules, you'd need to scrape and store all 100 metrics first, defeating the purpose of cardinality reduction at ingestion time.

### Pitfalls of the current solution

The recording rule approach is problematic because it introduces time skew, which could be avoided. It also means that staleness markers will be inserted when the rule executes rather than when the target is down. A derived metric could be calculated up to `scrape_interval` after a target is down. It also means that if multiple targets have different scrape intervals, there should be different rule evaluation times.

In the use case of cardinality reduction, extra work is also needed if you do not want to send the non-aggregated metrics to remote storage, but they would still take some place on disk locally.

## Goals

* Enable evaluation of PromQL expressions at scrape time against raw scraped metrics
* Guarantee that all input metrics come from the same scrape, eliminating time skew
* Evaluate rules after parsing but before relabeling, ensuring rules work with original metric names
* Enable cardinality reduction by aggregating metrics before storage and dropping originals via relabeling
* Support instant vector PromQL operations (arithmetic, aggregations, functions operating on current values)
* Pre-process and validate rules at configuration load time to fail fast on invalid rules
* Maintain scrape performance by running rule evaluation in the existing scrape pipeline only when configured

## Non-Goals

* Support for range vector operations (e.g., `rate()`, `increase()`, selectors with `[5m]`)
  * These require historical data which is not available at scrape time
* Support for time-based modifiers (`offset`, `@` timestamp)
  * Only the current scrape's data is available
* Support for rules that reference target labels
  * Rules evaluate before target labels are added
* Replacement of recording rules for all use cases
  * Recording rules remain useful for expensive aggregations over time ranges
* Support for rules that span multiple scrapes or targets
  * Each scrape is evaluated independently with only its own metrics
* Support alerting
  * Out of scope for now

## How

### Configuration

Scrape-time rules will be configured in the scrape configuration under a new `scrape_rules` field:

```yaml
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
    scrape_rules:
      - record: node_memory_used_bytes
        expr: node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
      - record: node_filesystem_avail_percent
        expr: 100 * node_filesystem_avail_bytes / node_filesystem_size_bytes
      - record: node_cpu_busy_percent
        expr: 100 - (avg by (instance) (node_cpu_seconds_total{mode="idle"}) * 100)
```

Each rule consists of:

- `record`: The name of the metric to create (must be a valid metric name)
- `expr`: A PromQL expression to evaluate (must be an instant vector expression)

#### Example: Cardinality Reduction

```yaml
scrape_configs:
  - job_name: 'application'
    static_configs:
      - targets: ['localhost:8080']
    scrape_rules:
      # Aggregate 100 per-component metrics into a total
      - record: http_requests_total
        expr: sum(http_requests_by_component_total)
    metric_relabel_configs:
      # Drop the detailed per-component metrics
      - source_labels: [__name__]
        regex: 'http_requests_by_component_total'
        action: drop
```

This pattern:
- Creates `http_requests_total` as the sum of all components at scrape time
- Drops the original 100 `http_requests_by_component_total` metrics via relabeling
- Reduces cardinality by 99% while preserving the aggregate view
- Only works because scrape rules evaluate before relabeling

### Scraping Pipeline Integration

The scrape-time rule evaluation will be inserted as a new stage in the scraping pipeline, between parsing and relabeling:

```
Current Flow:
1. FETCH (HTTP GET)
2. PARSE (Text Format Parser)
3. RELABEL (Apply target labels + metric_relabel_configs)
4. VALIDATE
5. APPEND TO STORAGE

New Flow:
1. FETCH (HTTP GET)
2. PARSE (Text Format Parser)
3. SCRAPE-TIME RULES ← NEW STAGE
4. RELABEL (Apply target labels + metric_relabel_configs)
5. VALIDATE
6. APPEND TO STORAGE
```

This positioning ensures:

- Rules have access to all scraped metrics with their original names
- Rules don't have access to target labels (job, instance), which aren't available yet
- Synthetic metrics flow through the same relabeling and validation as scraped metrics
- Cache and staleness tracking work correctly for both scraped and synthetic metrics
- Cardinality reduction is possible: aggregated metrics can be created and original high-cardinality metrics dropped via `metric_relabel_configs` before they reach storage

### Implementation Details

#### Rule Pre-processing (at ApplyConfig time)

**In `scrape.go: NewManager()`:**

The scrape manager is initialized with a PromQL engine instance configured with essential options from the query engine. This engine will be reused for all scrape-time rule evaluations across all scrape pools.

The scrape-time PromQL engine will have the same configuration compared as the query engine. It could be instrumented with its own Prometheus metrics collector using a distinct prefix (such as `scrape_rules_engine_`) to allow separate monitoring of scrape-time vs query-time PromQL performance.

**In `scrape.go: newScrapePool()`:**

1. Parse each `scrape_rules` expression using the standard PromQL parser
2. Validate that expressions don't use disallowed features (ranged, @, , offset, etc)
3. Extract metric selectors/matchers from each rule for optimization
5. Store parsed matchers and selectors in the scrapePool config

#### Rule Evaluation (at scrape time)

In `scrape.go: scrapeLoop.append()`, after parsing is complete but before relabeling:

1. Collect all scraped samples that matches the selectos in the rules into an in-memory storage implementation
2. For each scrape rule:
   a. Use the scrape manager's PromQL engine (configured with the same options as the query engine)
   b. Create a query context that points to the in-memory storage containing only the current scrape's samples
   c. Evaluate the pre-parsed expression against the in-memory sample set via the context
   d. Add result samples to the in-memory storage for subsequent rules
3. After all rules are evaluated, merge results with scraped samples (or directly at `2.d` ?)
5. Continue with normal relabeling pipeline

This design ensures:
- No modifications to the PromQL engine itself
- Consistent behavior between scrape-time and query-time evaluation
- The in-memory storage naturally prevents access to historical data

#### PromQL Expression Restrictions

**Disallowed (will fail config validation with descriptive error):**
- Range vector selectors: `metric_name[5m]`
- Time-based modifiers: `offset 5m`, `@ 1234567890`
- Range-dependent functions should all use range vectors so need to explicitly disallow them.
- Subqueries: `rate(metric[5m])[10m:1m]`

### Action plan

This should be straightforward to implement.

There should be performance tests to measure that the performances of the default scrape path (without rules) is not impacted.

Better behind a feature flag as this is experimental.
