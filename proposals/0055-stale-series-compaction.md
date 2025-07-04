# Early Compaction of Stale Series from the Head Block

* **Owners:**
    * Ganesh Vernekar (@codesome)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
    * https://github.com/prometheus/prometheus/issues/13616 

> TL;DR: This document is proposing a way of tracking stale series and compacting them (i.e. remove from in-memory head block) early when there are a lot of stale series.

## Why

During rollouts, it is common to change some common labels on the series (like pod name), creating a whole new set of series and turning the old series stale. There are other scenarios that cause this series rotation (i.e. create a new batch of series and turn the old ones stale). In default configuration, Prometheus performs head compaction every 2 hours. This head compaction is performed on the older 2hr of data when Prometheus is holding 3hrs of data (1.5x). Until then, it holds onto all the series (including stale) in the memory for up to last 3 hrs.

While this is a problem for Prometheus of all sizes, it is a bigger headache for huge Prometheus instances (think 100s of gigs of memory) where there are eventual limits on how big the memory allocation can be and restarts on OOM or scale up take too long. The problem is exaggerated when there are multiple rollouts in a short span (“short” \= within 1-2 hours) and Prometheus accumulates a lot of stale series. With the huge spikes in memory, this essentially prohibits how fast you can roll out your code (even rollback of problematic code that causes cardinality explosion is difficult).

Glossary:
- Head / head block: The in-memory portion of the TSDB.
- Stale series: A time series that stopped getting any new samples.
- Head GC: Removing old time series data from the head block.
- Head Compaction: Process of creating persistent data blocks out of series present in the head block and performing head GC.

### Pitfalls of the current solution

There is no mechanism to proactively get rid of stale series from the head block. Prometheus has to wait until the next compaction to get rid of them.

## Goals

* Have a simple and efficient  mechanism in the TSDB to track and identify stale series.
* Compact the stale series when they reach a certain configurable threshold (% of total series).

## Non-Goals

* Preventing cardinality at source
* Detailing out how exactly we will compact the stale series once we have identified it. That will be some implementation detail when we get to it.

## How

### Tracking Stale Series

Scraper already puts staleness markers (a [unique sample value](https://github.com/prometheus/prometheus/blob/c3276ea40c2241b85ee35da30048bb6fc4b6d63b/model/value/value.go#L28) to identify stale series) for series that stopped giving samples or targets that disappeared. We also store the [lastValue](https://github.com/prometheus/prometheus/blob/c3276ea40c2241b85ee35da30048bb6fc4b6d63b/tsdb/head.go#L2177) for every series, allowing us to identify stale series without any additional overhead in memory. While there can be edge cases (e.g. during restarts) where we missed putting staleness markers, this should cover most of the use cases while keeping the code very simple.

We can keep a running counter that tracks how many series are stale at the moment. Incremented or decremented based on the incoming sample and the last sample of the series.

### Compacting Stale Series

We will have two thresholds to trigger stale series compaction, `p%` and `q%`, `q > p` (both indicating % of total series that are stale in the head). Both will be configurable and default to 0% (meaning stale series compaction is disabled).

**Part 1**

At a regular interval (say 15 mins), we check if the stale series have crossed p% of the total series. If it has, we trigger a compaction that simply flushes these stale series into a block and removes it from the Head block (can be more than one block if the series crosses the block boundary). We skip WAL truncation and m-map files truncation at this stage and let the usual compaction cycle handle it. How we drop these compacted series during WAL replay is TBD during implementation (may need a new WAL record or use tombstone records).

Since these are stale series, there won’t be any races when compacting it in most cases. We will still lock the series and take required measures so that we don’t cause race with an incoming sample for any stale series.

This way of compaction will make it more predictable when the stale series compaction happens.

**Part 2**

To be more reactive to sudden rise in stale series, we will perform the stale series compaction as soon as the stale series crosses the higher q% threshold.

To avoid back to back stale series compactions, we can choose to have a cooldown period after a stale series compaction where it does not trigger again (e.g. 5-10 mins).

Implementation detail: if the usual head compaction is about to happen very soon, we should skip the stale series compaction and simply wait for the usual head compaction. The buffer can be hardcoded.

## Alternatives

### Alternative for tracking stale series

Consider when was the last sample scraped *in addition to* the above proposal.

For edge cases where we did not put the staleness markers, we can look at the difference between the last sample timestamp of the series and the max time of the head block, and if it crosses a threshold, call it stale. For example a series did not get a sample for 5 mins (i.e. head’s max time is 5 mins more than series’ last sample timestamp).

Pros over only the above proposal:
* Covers the edge cases that is not caught by just staleness markers

Cons over only the above proposal:
* Will have to scan all series periodically to identify how many stale series we have. Can be expensive if we have too many series.

Purely because of the added complexity of proposal 2, we can start with proposal 1 and consider proposal 2 as a follow up in the future.

### Alternative for stale series compaction

Only do either part 1 or part 2 from the above proposal. PS: doing both is not a big jump in work and probably a good tradeoff.

## Action Plan

- [ ] Implement staleness tracking with appropriate metrics.
- [ ] Implement stale series compaction.

# Future Consideration

* Dynamic adjustment of the thresholds based on memory pressure.

# Consensus

