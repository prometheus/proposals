## Remote Write: Restart from segment-based savepoint

* **Owners:**
  * [@kgeckhart](https://github.com/kgeckhart)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**

First issue on the matter https://github.com/prometheus/prometheus/issues/8809 spawned from https://github.com/prometheus/prometheus/pull/7710.

Since then there have been a lot of discussion / attempts but nothing has been merged. See
* https://github.com/prometheus/prometheus/pull/8918
* https://github.com/prometheus/prometheus/pull/9862
* https://github.com/ptodev/prometheus/pull/1

* **Other docs or links:**

> This effort aims to have an agreed upon design with requirements for completing the work to allow remote write to restart data delivery from a savepoint and not from `time.Now()`

## Why

Remote write is backed by a write-ahead-log (WAL) where all data is persisted before it is sent.
If a config is reloaded or prometheus/agent is restarted before flushing pending samples we will skip those samples.
Given we have a persistent WAL this behavior is unexpected by users and can cause a lot of confusion.

## Goals

1. Support resuming from a savepoint for each configured `remote_write` destination via an opt-in feature flag.
2. Taking a savepoint for a remote_write destination should not incur significant overhead.
3. Changing the `queue_configuration` for a `remote_write` destination should not result in losing a savepoint entry.
   * The `queue_configuration` includes fields like min/max shards and other performance tuning parameters.
   * These can be expected to change under normal circumstances and should not trigger a data loss scenario.
4. Guards need to be in place to protect against infinite WAL growth.
5. Stretch: Remote write supports at-least-once delivery of samples in the WAL.
   * Note: This has appeared to be the largest challenge with any existing implementation as it can cause significant overhead.

### Audience

`remote_write` users.

## Non-Goals

* Tracking position within a WAL segment (byte or record-level offsets). The savepoint tracks at segment granularity only.
* Remote write supports exactly-once delivery

## How

A basic replay to accomplish all non-stretch goals would be as follows.

### Implementation flow

**On startup:**

1. Read the savepoint file and load the last saved segment number for each queue.
2. Pass the saved segment to the watcher for each queue so replay begins from that segment rather than the current WAL head.

**At runtime:**

3. On a configurable schedule, write the current segment for each queue to the savepoint file on disk.
4. On clean shutdown, also write the savepoint before exiting.

**Duplicate handling:**

5. Since replay starts at a segment boundary rather than an exact position within the segment, some already-delivered samples may be re-sent. The remote write destination must handle duplicate or out-of-order sample errors gracefully so these do not slow down delivery. The probability of duplicates on startup after replay is high due to redoing whole segments.

This flow should be enough to accomplish Goals 1 and 2. The savepoint write requires a lock but given it happens on a schedule it will be infrequent enough to avoid significant overhead (see testing for further info). Ideally, the implementation could help solve [tsdb/agent: Prevent unread segments from being truncated](https://github.com/prometheus/prometheus/issues/17616) which would require the agent to be made aware when remote write has progressed passed a specific segment.

### Savepoint file format/location

The savepoint would be stored in the `remote.WriteStorage.dir` which would be next to the `/wal` directory.

We only care about the queue hash and the current segment so a json encoded file seems reasonable for this. A key value format should make it easier to evolve over time vs a more basic delimited file.

Example savepoint file (keys are queue hashes, values are savepoint entries):

```json
{
  "abc123def456": { "segment": 42 },
  "789xyz012abc": { "segment": 39 }
}
```

Solving for, Goal 3: Changing the `queue_configuration` for a `remote_write` destination should not result in a new savepoint entry.

This will be done via adding a specific toHash function for RemoteWriteConfig which zeros the QueueConfig before taking the hash. RemoteWriteConfig is managed as a pointer so we'll need to keep the value before, set to empty, and put the original value back but all is reasonably managed. We could look at identifying other "operational" fields which could be excluded from hashing for the same reasons.

This will change existing queue hashes but I don't believe that to be a big problem and if it is we can do this hashing specifically for segment tracking only. It is proposed as the first task so we can reduce the amount of use cases which can trigger data loss.

### Testing / Safety

Goal 4: Guards need to be in place to protect against infinite WAL growth is capable of being accomplished through adjusting config defaults when replaying is enabled. We would require `remote_write.queue_config.sample_age_limit` be non-zero and would have a default of `2h`.

I believe prombench is sufficient to prove Goal 2: Taking a savepoint for a remote_write destination should not incur significant overhead. Open to further benchmarking ideas but given the components + time necessary for a proper test ensuring prombench is capable of covering this would be the most ideal.

### Goal 5: Stretch: Remote write supports at-least-once delivery of samples in the WAL.

The amount of complexity in this goal is large, it is my opinion that our current state where all samples are lost is worse than implementing a replay which does not give us at-least-once delivery. The basic segment replay has a gap: the savepoint advances when the watcher moves to a new segment, but the queue may not have finished sending all samples from the previous segment — a restart between the savepoint being written and the queue flushing that segment still loses those samples. I believe the proposed replay provides a good basis for closing this gap.

An intermediate step would be to track the lowest timestamp successfully delivered in the savepoint. At startup, this timestamp would be used as a marker to skip already-delivered samples within the replayed segment, reducing duplicates. The lowest timestamp is required rather than the latest because the WAL supports out-of-order writes. At worst, replay still starts from the beginning of the segment. This doesn't help solve our at-least-once goal it helps reduce the amount of duplicated data sent on startup.

A true at-least-once solution would require tracking the segments through the queue. Since each queue uses multiple parallel shards to send data to the remote destination we would need every shard to confirm it has finished delivering all samples from a segment before the savepoint advances for that segment. The potential for more blocking here is large and before attempting to solve this problem it would be best to tackle reported remote write contention (see https://github.com/prometheus/prometheus/issues/17277).

## Alternatives

1. **The queue owns syncing its own savepoint** (most early implementations took this approach).
   * Pros: Savepoint logic lives close to the data being tracked.
   * Cons: The queue already has significant responsibilities and will take on more for the at-least-once stretch goal. Centralizing savepoint persistence in the write storage layer keeps the queue focused.

2. **The savepoint is synchronously updated when segments change during WAL watching.**
   * Pros: Simpler implementation — no separate timer needed. Given the queue has limited depth, watcher segment tracking may be a sufficient persistence point.
   * Cons: Synchronously committing on every segment change means the savepoint may advance before the queue has had time to deliver the batch, increasing the amount of data replayed on restart. A periodic delayed approach (e.g., persist every 30s with a ~15s queue delay) gives the queue more time to process a segment before committing. After implementing at-least-once this decision can be revisited.

3. **A `SegmentTracker` component injected into the watcher owns savepoint persistence** (rather than write storage orchestrating it).
   * Pros: Simpler for the basic replay — persistence stays close to where segment changes are observed, and reuses the work from https://github.com/prometheus/prometheus/issues/17616.
   * Cons: This approach breaks down as requirements grow. Adding the lowest timestamp to the savepoint requires the savepoint to move up to the queue. Adding at-least-once requires segment tracking to consider when data was fully sent, which also moves up to the queue. The write storage approach is chosen to avoid migrating ownership multiple times.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Adjust the queue hash function to exclude parameters often adjusted during normal operations (reduces the surface area where data can be lost).
* [ ] Implement the segment change notification pattern proposed in https://github.com/prometheus/prometheus/issues/17616.
* [ ] Add the functionality proposed in the How section (I think it can be accomplished in a single PR without being massive).
