# Scrape Memory Limiter

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

> TL;DR: This proposal introduces a Scrape Memory Limiter. It allows Prometheus to proactively and gracefully drop scrapes when the server's memory usage approaches a configured limit, preventing out-of-memory (OOM) crashes.

## Why

Dynamic service discovery can lead to growth in the number of targets (e.g., when new workloads are spun up in Kubernetes). These new targets, which may have high cardinality or expose large amounts of metrics, can cause memory growth in Prometheus, leading to OOM kills and total monitoring unavailability.

When Prometheus runs out of memory, it crashes. This not only stops data collection for the newly added workloads but also stops data collection for all other workloads being monitored by that Prometheus instance.

### Pitfalls of the current solution

Current mitigations, such as the static per-job `sample_limit`, are insufficient since they require prior knowledge of target sizes and apply on a per-scrape basis. They do not dynamically protect the global heap across all targets.

Relying on OS-level boundaries (such as a container memory limit) guarantees a hard crash of the entire Prometheus process when memory is exhausted, affecting the monitoring of all other targets.

## Goals

- Prevent Prometheus from crashing due to memory exhaustion when scrape load increases beyond what the server can handle.
- Provide a simple, top-level global configuration to enable the feature.
- Provide clear debuggability when scrapes are failed due to memory pressure.
- Maintain transactionality when a scrape is failed due to memory pressure.

### Audience

Prometheus operators running in memory-constrained environments (like Kubernetes) who have to deal with OOM kills, and/or who do not have full control over the applications being scraped.

## Non-Goals

- Soft limits, fairness, and per-job QoS controls are out of scope for the initial implementation.
- This does not address long-term memory leaks. It is only designed to prevent OOMs caused by short-term spikes in memory usage from scraping.

## How

The Scrape Memory Limiter acts as a proactive circuit breaker for the Prometheus server. Periodically, a background routine checks the current memory usage of the Prometheus process against a configured global limit.

Right before initiating an HTTP request to scrape a target, the scrape loop will check the memory limiter status. If the memory usage is currently above the configured limit, the scrape transaction is aborted early. This ensures transactionality—-the scrape is skipped in its entirety, preventing the allocation of memory for a potentially large influx of metrics that the system cannot currently handle.

### Configuration

A new top-level `scrape_memory_limiter` configuration block will be introduced in the Prometheus configuration file.

The configuration is a subset of the configuration of the OpenTelemetry Collector's memory limiter processor, which has been used widely in production. It will be defined as a top-level block in the Prometheus configuration file.

```yaml
# A new top-level block for the Scrape Memory Limiter.
scrape_memory_limiter:
  # Target a maximum of 80% of total system memory.
  # If total memory usage exceeds this percentage, scrapes are dropped.
  limit_percentage: 80 
  
  # Alternatively, an absolute limit in MiB can be used:
  # limit_mib: 1000
```

### Feature Flag

While the feature is experimental, the Scrape Memory Limiter will be gated behind a command-line feature flag: `--enable-feature=scrape-memory-limiter`, and will follow the usual process for feature graduation.

If this flag is absent, the memory limiter will not be active and the configuration block will be ignored, even if configured in the prometheus configuration.

### Debuggability and User Experience

Understanding that data is missing and *why* it is missing is a critical part of the user experience. This feature caters to two personas:

**1. The Application Owner:**
Application owners need to understand why their specific application failed to be scraped.
* **Up Metric:** The `up` metric for their dropped target will record a `0`. This is the standard mechanism to indicate a failed scrape, which preserves their existing alerts on the `up` metric.
* **UI /targets Page:** A descriptive scrape error (e.g., `scrape memory limit exceeded`) will be attached to the target's state. This error message will be visible on the Prometheus `/targets` UI page so the application owner knows the failure was due to Prometheus memory limits rather than their own application being down.

**2. The Prometheus Server Operator:**
Server operators need to understand the global impact of memory limiting so they can take corrective action (e.g., increasing memory limits, adding Prometheus replicas, or investigating massive targets).
* **Counter for aborted scrapes:** A new internal Prometheus metric (e.g., `prometheus_target_scrapes_skipped_memory_limit_total`) will be introduced to track the total number of aborted scrapes globally. Operators can set alerts on this metric to be notified of memory pressure, allowing them to intervene if data loss becomes too widespread.

## Future Enhancements

### Gradual Degradation (Soft Limits)

Future support for soft memory limits (e.g., a `spike_limit_mib` parameter) will allow the limiter to degrade scrape load gradually before the hard limit is reached. Instead of a binary drop-everything approach, the limiter would drop an increasing percentage of scrapes as memory usage approaches the hard limit.

### Fairness Mechanisms

The initial implementation of the memory limiter proposed above might inadvertently starve small, critical targets when a noisy neighbor introduces memory pressure. Future iterations could introduce scheduling algorithms to ensure fairness. Advanced approaches like [Deficit Round Robin (DRR)](https://en.wikipedia.org/wiki/Deficit_round_robin) can mathematically guarantee fairness across targets during memory pressure, isolating the disruption to high-cardinality targets.
To implement fairness, the mechanism will need to predict the cost of a scrape. This prediction should be based on the **total number of samples** from the target's previous scrape, *not* the number of *new series* added. New series are highly volatile (a target rotating a label will add many new series in one scrape, but zero in the next), making them a poor heuristic for proactive load shedding. Total samples accurately correlate with the short-lived parsing overhead the scrape loop will incur.

### Per-Job Controls

Future enhancements could provide support for overriding or specifying memory bounds at the individual scrape-job level. This would grant operators granular control to protect critical monitoring jobs at the expense of less important jobs during memory shortages.
To implement this, Prometheus could leverage Quality of Service (QoS) or criticality metadata (e.g., `severity="critical"`) attached to specific metrics or jobs. This would allow the limiter to intelligently determine which scrapes or series are safe to drop. There is a weighted variant of [DRR](https://en.wikipedia.org/wiki/Deficit_round_robin) that could be used to implement this mechanism.

## Alternatives

1. **Do nothing**
2. **Rejecting only new series ([#16917](https://github.com/prometheus/prometheus/issues/16917), [PR #11124](https://github.com/prometheus/prometheus/pull/11124))**: Instead of dropping the entire scrape, Prometheus would accept updates for time series it already knows about but reject the allocation of *new* series. This violates scrape transactionality, as scrapes should be ingested in full or not at all. Partial ingestion leads to unpredictable query skew (e.g., a success rate query where the success metric is ingested but the newly created error metric is dropped) and breaks fundamental system behavior assumptions. This creates confusing, inconsistent data for the application owner that goes against the principle of least surprise.
3. **Slowing down scrapes**: Dynamically backing off the scrape interval (e.g., from 15s to 60s) for targets under memory pressure. While this might temporarily reduce memory intake, skipping scrapes entirely sends a clearer signal to users (`up = 0`) that something is wrong. Skipping a single scrape is usually acceptable because the query window generally covers at least twice the scrape interval. Conversely, dynamically slowing down scrapes might silently break assumptions users have built into their alerts and recording rules.

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
* [ ] Add scrape-abort logic and debuggability metrics
