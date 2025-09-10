# TSDB Index Lookup Planning

* **Owners:**
  * `@dimitarvdimitrov`

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [PR #16835: tsdb index: introduce scan matchers](https://github.com/prometheus/prometheus/pull/16835)
  * [Mimir issue #11916: TSDB index lookup planning](https://github.com/grafana/mimir/issues/11916)

* **Other docs or links:**
  * [Store-gateway optimization blog post](https://grafana.com/blog/2023/08/21/less-is-more-how-grafana-mimir-queries-run-faster-and-more-cost-efficiently-with-fewer-indexes/)
  * [Prometheus fast regexp label matcher](https://github.com/grafana/mimir-prometheus/blob/main/model/labels/regexp.go)
  * [Access Path Selection in a Relational Database Management System](https://15799.courses.cs.cmu.edu/spring2025/papers/02-systemr/selinger-sigmod1979.pdf)

> TL;DR: This proposal introduces extension points for TSDB index lookups that allow different execution strategies to address the problem of inefficient index lookup usage. The goal is to provide interfaces that enable downstream projects to implement custom optimization approaches for their specific use cases.

## Why

Prometheus' current index lookup approach creates performance bottlenecks in high-cardinality environments. Two major inefficiencies exist:

1. **Broad matcher inefficiency**: Wide matchers like `namespace != ""` select massive numbers of series, creating significant memory overhead for minimal filtering benefit
2. **Expensive regex evaluation**: Non-optimizable regex matchers against high-cardinality labels create CPU bottlenecks

Real-world profiling across high-cardinality Mimir deployments shows 34% of CPU time spent on string matching and 20% on posting list iteration. These patterns appear consistently in high-cardinality environments and significantly affect total cost of ownership.

### Pitfalls of the current solution

The current naive approach to index lookups has specific problems:

**Example 1: Broad matcher inefficiency**
- Query with 5 matchers, including `namespace != ""`
- Selects union of all series with any namespace value
- In a 2M series block: 2M series × 8 bytes = 16MB (roughly the equivalent of 16,000 XOR chunks)
- Other matchers (`job`, `pod`, `container`, metric name) are typically more selective
- Results in massive memory overhead for minimal filtering benefit

**Example 2: Expensive regex evaluation**
- Single TSDB block: 1.8M series
- One label with 220,000 distinct values
- Non-optimizable regex against high-cardinality label
- Runs regex against 200K values to select 2-10 series
- Shows up as double-digit CPU percentage in profiles with massive allocation impact

## Goals

* Provide extension points for TSDB index lookups that allow alternative execution strategies
* Enable downstream projects to implement custom optimization approaches for their specific use cases
* Support experimentation with different planning algorithms and storage characteristics
* Allow flexibility in addressing index lookup inefficiencies without changing core TSDB behavior

### Audience

This change primarily targets:
- High-cardinality Prometheus deployments (>1M series)
- Downstream projects like Mimir, Thanos, and Cortex that need different optimization strategies

## Non-Goals

* Replace existing regex optimizations
* Change the core TSDB storage format
* Provide immediate performance improvements without statistics collection
* Improve `/api/v1/labels` and `/api/v1/label/{}/values` requests

## How

### Core Approach

Building on the scan matchers foundation from [PR #16835](https://github.com/prometheus/prometheus/pull/16835), this proposal introduces a planning phase that:

1. Allows different execution strategies for each query
2. Partitions matchers into index-resolved vs series-resolved categories
3. Executes with lazy evaluation according to the chosen plan

The approach mirrors techniques used by database query planners when choosing between index scans and sequential scans.

### Interface Design

Introduce core planning interfaces that allow downstream projects to implement their own strategies:

```go
// LookupPlanner plans how to execute index lookups by deciding which matchers
// to apply during index lookup versus after series retrieval.
type LookupPlanner interface {
	PlanIndexLookup(ctx context.Context, plan LookupPlan, minT, maxT int64) (LookupPlan, error)
}

// LookupPlan represents the decision of which matchers to apply during
// index lookup versus during series scanning.
type LookupPlan interface {
	// ScanMatchers returns matchers that should be applied during series scanning
	ScanMatchers() []*labels.Matcher
	// IndexMatchers returns matchers that should be applied during index lookup
	IndexMatchers() []*labels.Matcher
}
```

### Simple Rule-Based Implementation

As a concrete example, [PR #16835](https://github.com/prometheus/prometheus/pull/16835) introduces a `ScanEmptyMatchersLookupPlanner` that implements a simple rule-based approach. This planner identifies matchers that are expensive to apply on the inverted index and usually don't filter any data, deferring them to scan matchers instead.

The rules are:
- `{label=""}` - converted to scan matcher (expensive index lookup, minimal filtering)
- `{label=~".+"}` - converted to scan matcher (expensive regex evaluation, broad selection)
- `{label=~".*"}` - removed entirely (matches everything, including unset values)

This demonstrates how the interface can be used to implement straightforward optimizations without requiring complex cost models or statistics collection. Such simple rule-based planners can provide immediate benefits for well-understood inefficient patterns while serving as building blocks for more sophisticated approaches.

## Alternatives

1. **Improve existing regex optimizations**: Continue optimizing the current approach with better regex compilation and caching. This approach has diminishing returns and doesn't address broad matcher inefficiency.

2. **Always use sequential scans**: Skip index lookups entirely and scan all series. This could be simpler but would hurt performance for selective queries.

3. **Static rule-based approach**: Use fixed rules instead of cost-based planning. This would be simpler to implement but usually misses the nuances of a cost model with cardinality estimations. However, the current `PostingsForMatchers` implementation already has some of these heuristics which always work.

The proposed approach provides the flexibility to adapt to different workload characteristics while maintaining compatibility with existing optimizations.

## Action Plan

* [ ] Add scan matchers to querier code
* [ ] Implement basic `LookupPlanner` interface with simple heuristics
* [ ] Validate approach with real-world high-cardinality workloads
