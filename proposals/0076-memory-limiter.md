# Memory Limiter

* **Owners:**
  * @dashpole

* **Implementation Status:** `Not started`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/17109
  * https://github.com/prometheus/prometheus/issues/13939
  * https://github.com/prometheus/prometheus/issues/11306
  * https://github.com/prometheus/prometheus/issues/16917

* **Other docs or links:**
  * Promcon 2025 - Scrape Trolley Dillema talk (credit to @bwplotka)
    * [YouTub Recording](https://www.youtube.com/watch?v=ulHQUCarjjo)
    * [Slides](https://docs.google.com/presentation/d/1jKrUklPdAor9292HrPWtJkIa6ruUhOGo9IFO7fNj-DE/edit?slide=id.p#slide=id.p)

> TL;DR: This proposal introduces a Memory Limiter for Prometheus. It allows the server to proactively and gracefully apply mitigations (such as pausing compaction, pausing recording rules, and dropping scrapes or rejecting OTLP metrics) when memory usage approaches configured limits, preventing out-of-memory (OOM) crashes.

## Why

Memory exhaustion is a common cause of Prometheus crashes (OOM kills). This can be triggered by many factors:
- Spikes in scrape load or metric cardinality (e.g., new workloads spun up in Kubernetes).
- Expensive PromQL queries or recording rules.
- High volume of incoming OTLP metrics or remote read requests.
- TSDB compaction requiring significant memory.

When Prometheus runs out of memory and crashes, it causes total monitoring unavailability, affecting all targets and users.

### Pitfalls of the current solution

Current mitigations are fragmented and often static:
- `sample_limit` applies on a per-scrape basis and requires prior knowledge of target sizes.
- There is no global mechanism to coordinate load shedding across different sources of memory usage (scrapes, OTLP, rules, etc.).
- Relying on OS-level boundaries (like cgroup limits) guarantees a hard crash of the entire process.

## Goals

- Prevent Prometheus from crashing due to memory exhaustion by applying graceful mitigations.
- Provide a unified, top-level global configuration similar to the OpenTelemetry Collector's memory limiter.
- Support both "soft" limits (non-destructive mitigations like pausing compaction) and "hard" limits (destructive mitigations like dropping data).
- Allow operators to enable/disable specific mitigations based on their needs.
- Provide clear debuggability when mitigations are triggered.

### Audience

Prometheus operators running in memory-constrained environments who need to protect the server from unpredictable memory spikes from various sources.

## Non-Goals

- Fairness and per-job QoS controls are out of scope for the initial implementation.
- This does not address long-term memory leaks. It is designed to handle spikes and overload scenarios.

## How

The Memory Limiter acts as a proactive circuit breaker. Periodically (configured by `check_interval`), a background routine checks the current memory usage of the Prometheus process.

The limiter maintains a **Soft Limit** and a **Hard Limit**.
* **Soft Limit** = `limit_mib` - `spike_limit_mib` (or calculated via percentages).
* **Hard Limit** = `limit_mib` (or calculated via `limit_percentage`).

### Mitigations

When memory usage exceeds the limits, the following mitigations are applied (if enabled):

**At Soft Limit:**
- **Pause Compaction**: Pause background TSDB compaction.
- **Pause Recording Rules**: Pause evaluation of recording rules (alerting rules are not paused).

**At Hard Limit:**
- **Fail Scrapes**: Skip scrapes to prevent allocation of memory for new samples.
- **Reject OTLP**: Reject incoming OTLP metrics requests.
- **Reject Remote Read**: Reject incoming remote read requests.

### Configuration

The configuration closely follows the OpenTelemetry Collector's memory limiter processor, with added toggles for specific mitigations.

```yaml
memory_limiter:
  # Time between measurements of memory usage. Recommended value is 1s.
  check_interval: 1s

  # Maximum amount of memory, in MiB, targeted to be allocated. Defines the hard limit.
  # limit_mib: 1000

  # Maximum spike expected between measurements.
  # Soft limit = limit_mib - spike_limit_mib
  # spike_limit_mib: 200

  # Maximum amount of total memory targeted to be allocated (percentage).
  limit_percentage: 90

  # Maximum spike expected between measurements (percentage).
  # Soft limit = limit_percentage - spike_limit_percentage
  spike_limit_percentage: 20

  # Granular controls to enable/disable specific mitigations
  enforcement:
    pause_compaction: true
    pause_recording_rules: true
    fail_scrapes: true
    reject_otlp: true
    reject_remote_read: true
```

#### Interaction with `GOMEMLIMIT`

Prometheus already automatically sets `GOMEMLIMIT` to 90% of its total memory limit. When the memory limiter is enabled, we will maintain this automatic behavior but refine it to set `GOMEMLIMIT` to a percentage (default 90%) of the calculated **Soft Limit**.

For example, if the Soft Limit is calculated to be 700 MiB, `GOMEMLIMIT` will be set to 630 MiB. This lowers the threshold for Go's garbage collector, ensuring it attempts to reclaim memory before Prometheus starts pausing background tasks.

### Feature Flag

While the feature is experimental, the Memory Limiter will be gated behind a command-line feature flag: `--enable-feature=memory-limiter`, and will follow the usual process for feature graduation.

If this flag is absent, the memory limiter will not be active and the configuration block will be ignored, even if configured in the prometheus configuration.

### Debuggability and User Experience

Understanding that data is missing or delayed and *why* is critical. This feature caters to two personas:

**1. The Application Owner:**
Application owners need to understand why their specific application failed to be scraped or why their OTLP metrics were rejected.
* **Up Metric:** The `up` metric for their dropped target will record a `0`.
* **UI /targets Page:** A descriptive scrape error (e.g., `memory limit exceeded`) will be attached to the target's state.
* **OTLP/Remote-Read Rejections:** OTLP and remote read requests will receive a 503 Service Unavailable error, indicating overload and signaling clients to retry with backoff.

**2. The Prometheus Server Operator:**
Server operators need to understand the global impact of mitigations, including:
* **Compaction Backlog**: [New] `prometheus_tsdb_compaction_pending_blocks`: Tracks how far behind compaction is in blocks.
* **Scrape Skips:** [New] `prometheus_target_scrapes_skipped_total`: Tracks how many scrapes the server has skipped.
* **Rule Evaluation Pipeline**: [Existing] `prometheus_rule_group_iterations_missed_total`: Tracks how many times rule group iterations have been missed.
* **Rejected Metrics**: [Existing] `prometheus_http_requests_total`: Tracks rejections of OTLP and remote read requests.

## Future Enhancements

### Reject PromQL Queries

Rejecting expensive PromQL queries (or all queries) when memory pressure is high. This was deferred from the initial proposal because determining which queries to reject is complex, and intermittent query failures make debugging hard.

### Gradual Degradation

Future support for degrading scrape load gradually before the hard limit is reached. Instead of a binary drop-everything approach, the limiter would drop an increasing percentage of scrapes as memory usage approaches the hard limit.

### Fairness Mechanisms

The initial implementation of the memory limiter proposed above might inadvertently starve small, critical targets when a noisy neighbor introduces memory pressure. Future iterations could introduce scheduling algorithms to ensure fairness. Advanced approaches like [Deficit Round Robin (DRR)](https://en.wikipedia.org/wiki/Deficit_round_robin) can mathematically guarantee fairness across targets during memory pressure, isolating the disruption to high-cardinality targets.
To implement fairness, the mechanism will need to predict the relative cost of a scrape so that it can throttle targets proportionally to the expected short-term memory usage they will incurr. This prediction should be based on the **total number of samples** from the target's previous scrape, *not* the number of *new series* added. New series are highly volatile (a target rotating a label will add many new series in one scrape, but zero in the next), making them a poor heuristic for proactive load shedding. Total samples accurately correlate with the short-lived parsing overhead the scrape loop will incur.

### Per-Job Controls

Future enhancements could provide support for overriding or specifying memory bounds at the individual scrape-job level. This would grant operators granular control to protect critical monitoring jobs at the expense of less important jobs during memory shortages.
To implement this, Prometheus could leverage Quality of Service (QoS) or criticality metadata (e.g., `severity="critical"`) attached to specific metrics or jobs. This would allow the limiter to intelligently determine which scrapes or series are safe to drop. There is a weighted variant of [DRR](https://en.wikipedia.org/wiki/Deficit_round_robin) that could be used to implement this mechanism.

## Alternatives

1. **Do nothing**
2. **Rejecting only new series ([#16917](https://github.com/prometheus/prometheus/issues/16917), [PR #11124](https://github.com/prometheus/prometheus/pull/11124))**: Instead of dropping the entire scrape, Prometheus would accept updates for time series it already knows about but reject the allocation of *new* series. This violates scrape transactionality, as scrapes should be ingested in full or not at all. Partial ingestion leads to unpredictable query skew (e.g., a success rate query where the success metric is ingested but the newly created error metric is dropped) and breaks fundamental system behavior assumptions. This creates confusing, inconsistent data for the application owner that goes against the principle of least surprise.
3. **Slowing down scrapes**: Dynamically backing off the scrape interval (e.g., from 15s to 60s) for targets under memory pressure. While this might temporarily reduce memory intake, skipping scrapes entirely sends a clearer signal to users (`up = 0`) that something is wrong. Skipping a single scrape is usually acceptable because the query window generally covers at least twice the scrape interval. Conversely, dynamically slowing down scrapes might silently break assumptions users have built into their alerts and recording rules.
4. **Independent GOMEMLIMIT configuration**: Instead of applying the GOMEMLIMIT ratio to the scrape memory limiter's limit, we could keep the two configuration knobs entirely separate. This would allow someone to set a higher GOMEMLIMIT compared to their scrape limit, which isn't really something users would want to do. It would also make the configuration more confusing to reason about.

### Complementary Ideas

The following ideas are compatible and complementary with a Scrape Memory Limiter, but do not try to prevent memory exhaustion from scraping. They instead deal with recovering from an OOM crash loop, or target other sources of memory usage:
1. **Automated WAL Deletion on OOM ([#13939](https://github.com/prometheus/prometheus/issues/13939))**: Automatically deleting the Write-Ahead Log (WAL) when Prometheus is recovering from an OOM crash. While this allows the server to eventually start again, it is a reactive measure that still allows the server to crash (causing global monitoring downtime) and forces the deletion of recent data.
2. **Force Head Compaction/WAL Truncation Before Scraping ([#11306](https://github.com/prometheus/prometheus/issues/11306))**: Pausing scraping on startup until the WAL is fully replayed and compacted. This helps break a specific OOM crash cycle during startup but does not prevent the process from exhausting memory during normal operation.
3. **Limit Label Churn / New Series Over Time ([#17109](https://github.com/prometheus/prometheus/issues/17109))**: Introduce a per-instance or per-job configuration that tracks and limits the number of *new* series a specific target can introduce into the TSDB over a given time window. A Scrape Memory Limiter protects the *active heap* from sudden bursts during a scrape, while a label churn limiter protects the *TSDB* from slow cardinality growth memory leaks over time. They are complementary safeguards.
4. **Early Compaction / Forced GC**: Proactively forcing a Go Garbage Collection or triggering an early TSDB Head compaction when memory pressure builds to flush data to disk and free memory. While this might temporarily relieve pressure, the primary driver of OOMs in sudden-growth scenarios is new series cardinality, not just sample volume. Thus, the new series would immediately cause memory to balloon again.

## Action Plan

* [ ] Propose and finalize initial design
* [ ] Expose configuration via feature flag
* [ ] Implement configuration and memory tracking logic
* [ ] Implement scrape-abort logic and debuggability metrics (Hard Limit)
  * Metric to add: `prometheus_target_scrapes_skipped_total`.
* [ ] Implement logic to pause/resume TSDB compaction (Soft Limit)
  * Metric to add: `prometheus_tsdb_compaction_pending_blocks`.
* [ ] Implement logic to pause/resume recording rule evaluation (Soft Limit)
* [ ] Implement OTLP request rejection logic (Hard Limit)
* [ ] Implement Remote Read request rejection logic (Hard Limit)
