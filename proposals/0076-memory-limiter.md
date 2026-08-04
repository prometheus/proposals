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
  * Promcon 2025 - Scrape Trolley Dilemma talk (credit to @bwplotka)
    * [YouTube Recording](https://www.youtube.com/watch?v=ulHQUCarjjo)
    * [Slides](https://docs.google.com/presentation/d/1jKrUklPdAor9292HrPWtJkIa6ruUhOGo9IFO7fNj-DE/edit?slide=id.p#slide=id.p)

> TL;DR: This proposal introduces a Memory Limiter for Prometheus. It allows the server to proactively and gracefully apply mitigations (such as pausing compaction, pausing recording rules, and dropping scrapes or rejecting OTLP metrics) when memory usage approaches configured limits, preventing out-of-memory (OOM) crashes.

## Why

Memory exhaustion is a common cause of Prometheus crashes (OOM kills). This can be triggered by many factors:
- Spikes in scrape load or metric cardinality (e.g., new workloads spun up in Kubernetes).
- Expensive PromQL queries or recording rules.
- High volume of incoming OTLP metrics, remote write, remote read, or federation requests.
- TSDB compaction requiring significant memory.

When Prometheus runs out of memory and crashes, it causes total monitoring unavailability, affecting all targets and users.

### Pitfalls of the current solution

Current mitigations are fragmented and often static:
- `sample_limit` applies on a per-scrape basis and requires prior knowledge of target sizes.
- There is no global mechanism to coordinate load shedding across different sources of memory usage (scrapes, OTLP, rules, etc.).
- Relying on OS-level boundaries (like cgroup limits) guarantees a hard crash of the entire process.

## Goals

- Prevent Prometheus from crashing due to memory exhaustion by applying graceful mitigations.
- Provide a unified global configuration under the runtime section to coordinate load shedding across all subsystems.
- Support both "soft" limits (non-destructive mitigations like pausing compaction) and "hard" limits (destructive mitigations like dropping data).
- Allow operators to enable/disable specific mitigations based on their needs.
- Provide clear debuggability when mitigations are triggered.

### Audience

Prometheus operators running in memory-constrained environments who need to protect the server from unpredictable memory spikes from various sources.

## Non-Goals

- Fairness and per-job QoS controls are out of scope for the initial implementation.
- This does not address long-term memory leaks. It is designed to handle spikes and overload scenarios.
- Long-term baseline cardinality saturation (where retained live time series permanently exceed available RAM) cannot be solved by load shedding alone and belongs in separate proposals (such as per-job label churn limiting in #17109 and selective series head eviction). This proposal strictly targets preventing OOMs from transient overload and bursts.

## How

The Memory Limiter acts as a proactive circuit breaker. Because post-GC live heap is invariant under load shedding (skipping scrapes stops new allocations but does not remove resident series from the TSDB Head), the limiter monitors **in-use total memory** (`/memory/classes/total:bytes` minus `/memory/classes/heap/released:bytes`) relative to `GOMEMLIMIT` (`/gc/gomemlimit:bytes`) via non-stop-the-world `runtime/metrics`.

In-use memory responds immediately when load is shed, enabling the server to achieve a dynamic equilibrium where mitigations engage during acute bursts, memory recovers, and normal scraping disengages and resumes cleanly.

Periodically (default `check_interval: 100ms`, consuming ~0.001% CPU at 10 Hz), a background routine calculates the memory pressure ratio:
`pressure_ratio = in_use_memory / GOMEMLIMIT`

The limiter maintains two state thresholds:
* **Soft Limit**: Reached when `pressure_ratio >= soft_limit_ratio` (default `0.70`).
* **Hard Limit**: Reached when `pressure_ratio >= hard_limit_ratio` (default `0.85`), or immediately if Go's runtime GC CPU limiter engages (`/gc/limiter/last-enabled:gc-cycle`). These default ratios provide a balanced safety margin: 70% triggers early, non-destructive load shedding, while 85% leaves enough remaining heap headroom for Go's garbage collector to reclaim transient memory before hitting an OOM crash.

### Mitigations

Mitigations are divided into non-destructive actions that delay work (Soft Limit) and lossy actions that discard data (Hard Limit):

**At Soft Limit (Delay work without data loss):**
- **Pause Block Compaction**: Pause on-disk block merging (`DB.compactBlocks`). Head-to-block compaction and WAL truncation continue uninterrupted so active Head memory and WAL size remain bounded.
- **Reject Remote Read & Federation**: Reject incoming remote read and federation requests with a 503 Service Unavailable and `Retry-After` header, shedding heavy series materialization overhead.

**At Hard Limit (Discard work to prevent crashes):**
- **Fail Scrapes**: Skip scrapes to prevent allocation of memory for new samples. To avoid causing a synchronized WAL append storm when memory is exhausted, skipped scrapes bypass appending per-series staleness markers, letting values carry forward under the standard 5-minute lookback.
- **Reject OTLP & Remote Write**: Reject incoming OTLP and remote write requests with a 503 and `Retry-After` header. Rejection occurs at handler entry before reading or decoding the request body to prevent transient payload allocations.
- **Pause Recording Rules**: Pause evaluation of recording rules (alerting rules are not paused). Because missed evaluations leave permanent data gaps, this is treated as lossy. To prevent dependent alerting rules from silently resolving when lookbacks expire, only recording rules with **no local dependent rules** are paused. Because Prometheus cannot detect when external evaluation engines (such as Thanos Ruler or centralized alerting architectures) depend on derived rules over Remote Read or Federation, operators running distributed alerting pipelines are strongly advised to disable this mitigation (`enforcement.pause_recording_rules: false`).

### Configuration

The configuration is placed under the runtime configuration section alongside gogc, and provides granular toggles for specific mitigations.

```yaml
runtime:
  memory_limiter:
    # Time between checks of memory pressure ratio. Recommended value is 100ms.
    check_interval: 100ms

    # Fraction of GOMEMLIMIT (in-use memory) at which non-destructive mitigations engage.
    soft_limit_ratio: 0.70

    # Fraction of GOMEMLIMIT (in-use memory) at which destructive mitigations engage.
    hard_limit_ratio: 0.85

    # Granular controls to enable/disable specific mitigations
    enforcement:
      # Soft Limit
      pause_block_compaction: true
      reject_remote_read: true
      reject_federation: true
      # Hard Limit
      fail_scrapes: true
      reject_otlp: true
      reject_remote_write: true
      pause_recording_rules: true
```

#### Relationship to Go Runtime Parameters and Capacity Planning

In accordance with the architectural principle that **the limiter reads runtime parameters and never writes them**, both `GOMEMLIMIT` and `GOGC` (`runtime.gogc`) are treated purely as read-only **inputs**. The limiter manages application load while letting the Go runtime natively manage memory and garbage collection scheduling.

Unlike designs that derive or lower `GOMEMLIMIT` from configured memory thresholds, Prometheus continues to automatically set `GOMEMLIMIT` from `--auto-gomemlimit` (defaulting to 90% of total container memory), and the limiter reads this value directly. This ensures that enabling the memory limiter never silently reduces the available memory budget or forces unnecessary GC CPU churn to defend an artificially lowered heap ceiling.

If `GOMEMLIMIT` is unset (returning `math.MaxInt64` in `runtime/metrics`, which occurs if `--auto-gomemlimit=false` without an explicit environment variable or if auto-detection fails), Prometheus will **fail to start** with an explicit configuration error rather than operating with a silently inert limiter where `pressure_ratio ≈ 0`.

##### Baseline Capacity & `GOGC` Tuning

Because Go triggers garbage collections based on target heap expansion over the surviving live set (`live_heap * (1 + GOGC/100)`), the limiter can only remain disengaged during steady-state operation if normal GC oscillations do not breach the Soft Limit threshold:
`live_heap * (1 + GOGC/100) < soft_limit_ratio * GOMEMLIMIT`

At default settings (`GOGC=100`, `soft_limit_ratio: 0.70`), Go permits the heap to double between collections (`1 + 100/100 = 2x`). Thus, to avoid engaging soft load shedding during normal operations, an operator's baseline live heap must remain below **35% of `GOMEMLIMIT`** (half of 70%).

If persistent time-series growth pushes baseline live heap above this 35% boundary, operators have three clear, predictable options to adapt without requiring automated runtime heuristics:
1. **Provision more container memory:** Increases total available RAM to support higher baseline time series cardinality.
2. **Statically lower `GOGC`:** Configuring `--runtime.gogc=50` compresses allowable heap expansion between collections, raising the clean baseline live heap ceiling from 35% up to ~46% of `GOMEMLIMIT` at the cost of additional GC CPU usage.
3. **Raise limit ratios:** Increasing `soft_limit_ratio` creates extra breathing room before non-destructive delays engage.

### Feature Flag

While the feature is experimental, the Memory Limiter will be gated behind a command-line feature flag: `--enable-feature=memory-limiter`, and will follow the usual process for feature graduation.

If this flag is absent, the memory limiter will not be active and the configuration block will be ignored, even if configured in the prometheus configuration.

### Debuggability and User Experience

Understanding that data is missing or delayed and *why* is critical. This feature caters to two personas:

**1. The Application Owner:**
Application owners need to understand why their specific application failed to be scraped or why their OTLP metrics were rejected.
* **Up Metric:** The `up` metric for their dropped target will record a `0`.
* **UI /targets Page:** A descriptive scrape error (e.g., `memory limit exceeded`) will be attached to the target's state.
* **OTLP/Remote-Read/Remote-Write Rejections:** Requesting clients receive a 503 Service Unavailable error with a `Retry-After` header, indicating overload and signaling clients to back off and retry.

**2. The Prometheus Server Operator:**
Server operators need to understand the global impact of mitigations, including:
* **Limiter State & Thresholds:** [New] Introduces a boolean gauge, `prometheus_memory_limiter_active{limit="soft|hard"}`, indicating when mitigations are currently engaged, alongside `prometheus_memory_limiter_limit_bytes{limit="soft|hard"}` to expose the evaluated byte thresholds. Because configured percentage ratios (e.g., `0.70`) vary across servers and `--auto-gomemlimit` detects container RAM dynamically, exposing explicit byte limits allows operators managing large fleets to build unified alerts and dashboards without fine-tuning queries per server configuration. In accordance with best practices against exporting pre-calculated percentage ratios, operators monitor real-time memory pressure directly against these thresholds via existing Go runtime metrics already exposed by `client_golang` (e.g., comparing in-use memory against `go_gc_gomemlimit_bytes`).
* **Compaction Status:** [Existing/New] Reuses existing `prometheus_tsdb_compactions_skipped_total` (for disabled auto-compaction) plus a new `prometheus_tsdb_block_compaction_paused` boolean gauge.
* **Scrape Skips:** [New] `prometheus_target_scrapes_skipped_total`: Tracks how many scrapes the server has skipped.
* **Rule Evaluation Pipeline:** [New] `prometheus_rule_group_iterations_skipped_total`: Tracks rule evaluations skipped due to memory limits (existing missed metrics only increment when ticks fall behind time, not on no-op pauses).
* **Rejected Traffic:** [Existing] `prometheus_http_requests_total`: Tracks rejections of OTLP, remote write, remote read, and federation requests.

## How We Test and Verify

To ensure the limiter protects against OOM crashes without introducing false positives during normal operations, implementation requires the following validation suite:
1. **False-Positive Steady-State Test:** A healthy Prometheus operating at realistic steady-state utilization (<35% baseline live heap, matching the maximum allowable threshold before default `GOGC=100` oscillations breach the 70% Soft Limit) under continuous scrape and rule evaluation load must remain in state `ok` indefinitely, with `prometheus_memory_limiter_state_seconds_total{state="soft|hard"}` remaining zero.
2. **Dynamic Equilibrium & Recovery Test:** Under an acute load burst, the server must shed load, stabilize in-use memory below the limit, and return cleanly to `ok` state (with targets returning to `up == 1`) within a bounded recovery window once the burst ends.
3. **Skip-Path Regression Test:** Asserts that a memory-limited skipped scrape performs O(1) appends (reporting `up = 0` without walking `seriesPrev` to emit per-series staleness markers).
4. **Compaction Scoping Test:** Asserts that when on-disk block compaction is paused by the Soft Limit, head-to-block compaction (`DB.CompactHead`) and WAL truncation execute unimpeded, keeping active head memory and WAL disk size bounded.

## Future Enhancements

### Reject PromQL Queries

Rejecting expensive PromQL queries (or all queries) when memory pressure is high. This was deferred from the initial proposal because determining which queries to reject is complex, and intermittent query failures make debugging hard.

### Gradual Degradation

Future support for degrading scrape load gradually before the hard limit is reached. Instead of a binary drop-everything approach, the limiter would drop an increasing percentage of scrapes as memory usage approaches the hard limit.

### Fairness and Criticality Mechanisms

The initial implementation of the memory limiter proposed above might inadvertently starve small, critical targets when a noisy neighbor introduces memory pressure. Future iterations could introduce scheduling algorithms like Deficit Round Robin (DRR) to help distribute throttling across targets.

However, purely size-based or cost-proportional fairness schemes fail when target size is anticorrelated with importance—a frequent reality in observability where massive endpoints like `kube-state-metrics` or Prometheus's own `/metrics` endpoint are simultaneously the largest consumers of transient parsing memory and the most critical telemetry during an incident. Because **size does not equal criticality**, future load shedding will need to pair sample count heuristics with explicit Quality of Service (QoS) or priority metadata to prevent noisy neighbors from starving critical infrastructure monitoring.

### Per-Job Controls

Future enhancements could provide support for overriding or specifying memory bounds at the individual scrape-job level. This would grant operators granular control to protect critical monitoring jobs at the expense of less important jobs during memory shortages.
To implement this, Prometheus could leverage Quality of Service (QoS) or criticality metadata (e.g., `severity="critical"`) attached to specific metrics or jobs. This would allow the limiter to intelligently determine which scrapes or series are safe to drop. There is a weighted variant of [DRR](https://en.wikipedia.org/wiki/Deficit_round_robin) that could be used to implement this mechanism.

## Alternatives

1. **Do nothing**
2. **Rejecting only new series ([#16917](https://github.com/prometheus/prometheus/issues/16917), [PR #11124](https://github.com/prometheus/prometheus/pull/11124))**: Instead of dropping the entire scrape, Prometheus would accept updates for time series it already knows about but reject the allocation of *new* series. This violates scrape transactionality, as scrapes should be ingested in full or not at all. Partial ingestion leads to unpredictable query skew (e.g., a success rate query where the success metric is ingested but the newly created error metric is dropped) and breaks fundamental system behavior assumptions. This creates confusing, inconsistent data for the application owner that goes against the principle of least surprise.
3. **Slowing down scrapes**: Dynamically backing off the scrape interval (e.g., from 15s to 60s) for targets under memory pressure. While this might temporarily reduce memory intake, skipping scrapes entirely sends a clearer signal to users (`up = 0`) that something is wrong. Skipping a single scrape is usually acceptable because the query window generally covers at least twice the scrape interval. Conversely, dynamically slowing down scrapes might silently break assumptions users have built into their alerts and recording rules.
4. **Post-GC live heap ratio as the control signal**: Using post-GC retained live heap (`/gc/heap/live:bytes`) instead of total in-use memory to prevent false positives caused by Go's normal garbage collection sawtooth curve. While this accurately isolates retained data, it introduces a fundamental sensor/actuator mismatch: skipping scrapes stops new allocations, but it does not remove resident series structures from the TSDB Head. In software experiments, post-GC live heap remains flat when load is shed and only declines when TSDB Head compaction (`Truncate`) eventually executes hours later. Using a live heap sensor would trap the limiter in an extended brownout because the sensor cannot observe the real memory recovery caused by its own load-shedding mitigations.
5. **Forcing manual garbage collections (`runtime.GC()`) or OS page scavenging**: Automatically invoking `runtime.GC()` or manual OS page unmapping (`debug.FreeOSMemory()`) when memory pressure rises to force early memory reclamation before shedding load. Modern Go (since 1.19) already automatically accelerates collection frequency and background memory scavenging (`runtime.bgscavenge`) as total heap approaches `GOMEMLIMIT`. Simply calling `runtime.GC()` frees dead objects in internal Go memory arenas but leaves physical memory pages mapped to the operating system until the background scavenger returns them, resulting in zero immediate reduction in total in-use RAM or container RSS. Furthermore, forcing synchronous OS page unmapping (`debug.FreeOSMemory()`) merely turns an otherwise smooth, asynchronous background cleaning task into a synchronous, blocking wall-clock CPU stall (costing upwards of hundreds of milliseconds on large heaps), risking severe CPU thrashing and scheduler lockup during acute traffic incidents.

### Complementary Ideas

The following ideas are compatible and complementary with a Scrape Memory Limiter, but do not try to prevent memory exhaustion from scraping. They instead deal with recovering from an OOM crash loop, or target other sources of memory usage:
1. **Automated WAL Deletion on OOM ([#13939](https://github.com/prometheus/prometheus/issues/13939))**: Automatically deleting the Write-Ahead Log (WAL) when Prometheus is recovering from an OOM crash. While this allows the server to eventually start again, it is a reactive measure that still allows the server to crash (causing global monitoring downtime) and forces the deletion of recent data.
2. **Force Head Compaction/WAL Truncation Before Scraping ([#11306](https://github.com/prometheus/prometheus/issues/11306))**: Pausing scraping on startup until the WAL is fully replayed and compacted. This helps break a specific OOM crash cycle during startup but does not prevent the process from exhausting memory during normal operation.
3. **Limit Label Churn / New Series Over Time ([#17109](https://github.com/prometheus/prometheus/issues/17109))**: Introduce a per-instance or per-job configuration that tracks and limits the number of *new* series a specific target can introduce into the TSDB over a given time window. A Scrape Memory Limiter protects the *active heap* from sudden bursts during a scrape, while a label churn limiter protects the *TSDB* from slow cardinality growth memory leaks over time. They are complementary safeguards.
4. **Early TSDB Head Compaction**: Proactively triggering an early TSDB Head compaction when memory pressure builds to flush data to disk and free memory. While this might temporarily relieve pressure, the primary driver of OOMs in sudden-growth scenarios is new series cardinality, not just sample volume. Thus, the new series would immediately cause memory to balloon again.

## Action Plan

To simplify review and merging, implementation will be staged from core controller logic to individual mitigations:

**Stage 1: Controller & Scrape Mitigation**
* [ ] Propose and finalize initial design
* [ ] Expose configuration via feature flag and implement memory tracking logic
* [ ] Implement scrape-abort logic without staleness marker injection (Hard Limit)
  * Metric to add: `prometheus_target_scrapes_skipped_total`.

**Stage 2: Deferrable Mitigations (Soft Limit)**
* [ ] Implement logic to pause/resume on-disk block compaction only
  * Metric to add: `prometheus_tsdb_block_compaction_paused`.
* [ ] Implement Remote Read and Federation request rejection logic with 503 / `Retry-After`

**Stage 3: Lossy Mitigations (Hard Limit)**
* [ ] Implement OTLP and Remote Write request rejection logic at handler entry
* [ ] Implement logic to pause/resume independent recording rules
  * Metric to add: `prometheus_rule_group_iterations_skipped_total`.
