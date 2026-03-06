## Native TSDB Support for Start Timestamp (ST)

* **Owners:**
  * [`@bwplotka`](https://github.com/bwplotka)
  * [`@ywwg`](https://github.com/ywwg)
  * [delta-type-WG](https://docs.google.com/document/d/1G0d_cLHkgrnWhXYG9oXEmjy2qp6GLSX2kxYiurLYUSQ/edit) members

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [WAL](https://github.com/prometheus/prometheus/issues/14218), [PRW2](https://github.com/prometheus/prometheus/issues/14220), [CT Meta](https://github.com/prometheus/prometheus/issues/14217).
  * [initial attempt for ct per sample](https://github.com/prometheus/prometheus/pull/16046)
  * [rw2 proto change for ct per sample](https://github.com/prometheus/prometheus/pull/17036)
  * [rename to ST](https://github.com/prometheus/prometheus/issues/17416)
  * Initial implementation
    * [Appender](https://github.com/prometheus/prometheus/pull/17104)
    * [chunkenc.Iterator](https://github.com/prometheus/prometheus/pull/17176)
  * [float chunk ST format](https://github.com/prometheus/prometheus/pull/17909)
  * [RW2 sending ST support](https://github.com/prometheus/prometheus/pull/18122)

* **Other docs or links:**
  * [PROM-29 (Created Timestamp)](https://github.com/prometheus/proposals/blob/main/proposals/0029-created-timestamp.md)
  * [PROM-48 (Delta type)](https://github.com/prometheus/proposals/pull/48), [Delta WG](https://docs.google.com/document/d/1G0d_cLHkgrnWhXYG9oXEmjy2qp6GLSX2kxYiurLYUSQ/edit)

> TL;DR: We propose to extend Prometheus TSDB storage sample definition to include an extra int64 that will represent the start timestamp (ST) (previously called created timestamp (CT)) for the cumulative types as well for the future delta temporality ([PROM-48](https://github.com/prometheus/proposals/pull/48)).
> We propose introducing persisting ST logic behind a single flag `st-storage`. Once implemented, we propose to eventually remove the `created-timestamps-zero-injection` experimental feature.

## Why

The main goal of this proposal is to make sure [PROM-29's created timestamp (CT)](0029-created-timestamp.md) information is reliably and efficiently stored in Prometheus TSDB, under the new chosen start timestamp (ST) name. This means ST can be:

* Written via TSDB Appender interfaces.
* Query-able via TSDB Querier interfaces.
* Persistent in WAL.
* Watch-able (WAL) by Remote Writer.
* (eventually) Persistent in TSDB block storage.

To do it reliably, we propose to extend TSDB storage to "natively" support ST as something you can attach to a sample and use later on.
Native ST support in Prometheus TSDB would unblock the practical use of ST information for:

* Remote storages (Remote Write 2.0) (e.g. OpenTelemetry, Chronosphere, Google).
* PromQL and other read APIs (including federation) (e.g. increased cumulative based operation accuracy).

Furthermore, it would unblock future Prometheus features for wider range of monitoring cases like:

* Delta temporality support.
* UpAndDown counter (i.e. not monotonic counters) e.g. StatsD.

On top of that this work also allow to improve some existing features, notably various edge cases for native histogram resets hints (e.g. [TSDB chunk merges](https://github.com/prometheus/prometheus/issues/15346)). Arguably, ST can replace resent hint field in native histogram eventually.

### Background: ST feature

[PROM-29](0029-created-timestamp.md) introduced the created timestamp (CT) concept for Prometheus cumulative metrics. Since then [the community adopted the Start Timestamp name](https://github.com/prometheus/prometheus/issues/17416).

Semantically, ST represents the time when "counting" (from 0) started. In other words, ST is the time when the counter started counting from zero.

Conceptually, ST extends the Prometheus data model for cumulative monotonic counters as follows:

* (new) int64 Timestamp (ST): When counting started.
* float64 or [Histogram](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/model/histogram/histogram.go#L50) Value (V): The current value of the count, since the ST time.
* int64 Timestamp (T): When this value was observed.
* Labels: Unique identity of a series.
  * This includes special metadata labels like: `__name__`, `__type__`, `__unit__`
* Exemplars
* Metadata

Since the ST concept introduction in Prometheus we:

* Extended Prometheus protobuf scrape format to include ST per each cumulative sample (TODO link).
* Proposed (for OM 2) text format changes for ST scraping (improvement over existing OM1 `_created` lines) (TODO link).
* Expanded Scrape parser interface to return `CreatedTimestamp` / `StartTimestamp` per sample (aka per line).
* Optimized Protobuf and OpenMetrics parsers for ST use (TODO links).
* Implemented an opt-in, experimental [`created-timestamps-zero-injection`](https://prometheus.io/docs/prometheus/latest/feature_flags/#created-timestamps-zero-injection) feature flag that injects fake sample (V: 0, T: ST).
* Included ST in [Remote Write 2 specification](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/#ioprometheuswritev2request).

### Background: Delta temporality

See the details, motivations and discussions about the delta temporality in [PROM-48](https://github.com/prometheus/proposals/pull/48).

The core TL;DR relevant for this proposal is that the delta temporality counter sample can be conceptually seen as a "mini-cumulative counter". Essentially delta is a single-sample (value) cumulative counter for a period between (sometimes inclusive sometimes exclusive depending on a system) start timestamp and a (end)timestamp.

In other words, instant query for `increase(<cumulative counter>[5m])` produces a single delta sample for a `[t-5m, t]` period (V: `increase(<counter>[5m])`, ST: `now()-5m`, T: `now()`).

This proves that it's worth considering delta when designing a ST feature support.

### Background: ST characteristics for cumulative vs delta

[Previous section](#background-delta-temporality) argues that conceptually the ST logic can be used to implement both cumulatives and deltas. This is why typically they are stored in the same "field" in other system APIs and storages (e.g. [start time](https://github.com/open-telemetry/opentelemetry-proto/blob/d53c5c6fca40cba8d5d5cc4db0d719a07be927f8/opentelemetry/proto/metrics/v1/metrics.proto#L399) in OpenTelemetry).

The notable difference for cumulative vs delta samples is the dynamicity **characteristics** of this timestamp.

* For the cumulative we expect ST to change on every new counter restart, so:
  * Average: in the order of ~weeks/months for stable workloads, ~days/weeks for more dynamic environments (Kubernetes).
  * Best case: it never changes (infinite count) e.g days_since_X_total.
  * Worse case: it changes for every sample.
* For the delta we expect ST to change for every sample.

### Background: Official ST semantics

There are certain semantic constraints on ST values to make them useful for consumers of the known metric types and semantics. Different systems generally have similar semantics, but details and how strong (or practically enforced) those rules are may differ. Let's go through state-of-the-art, just to have an idea what we could propose for Prometheus ST enforcement (if anything):

For the purpose of the example, let's define 3 consecutive samples for the same series (value is skipped for brevity):

```
ST[0], T[0]
ST[1], T[1]
ST[2], T[2]
```

* OM) Descriptive SHOULD rules only: In OpenMetrics 1.0 ST does not have specific technical rules other than it should ["help consumers discern between new metrics and long-running ones" and that it must be set to "reset time"](https://prometheus.io/docs/specs/om/open_metrics_spec/#:~:text=A%20MetricPoint%20in%20a%20Metric%20with%20the%20type%20Counter%20SHOULD,MUST%20also%20be%20set%20to%20the%20timestamp%20of%20the%20reset.).
* RW2) Descriptive SHOULD rules only: Similarly in [Remote Write 2.0 spec, only descriptive STs rules](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/#ioprometheuswritev2request:~:text=created_timestamp%20SHOULD%20be%20provided%20for%20metrics%20that%20follow%20counter%20semantics%20(e.g.%20counters%20and%20histograms).%20Receivers%20MAY%20reject%20those%20series%20without%20created_timestamp%20being%20set.)
  * start_timestamp SHOULD be provided for metrics that follow counter semantics (e.g. counters and histograms).
  * Receivers MAY reject those series without start_timestamp being set.

* Otel) More detailed, but still descriptive SHOULD rule only: In OpenTelemetry data model ([temporality section](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#sums:~:text=name%2Dvalue%20pairs.-,A%20time%20window%20(of%20(start%2C%20end%5D)%20time%20for%20which%20the,The%20time%20interval%20is%20inclusive%20of%20the%20end%20time.,-Times%20are%20specified)) ST is generally optional, but strongly recommended. Rules are also soft and we assume they are "SHOULD" because there is section of [handling overlaps](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#overlap). However, it provides more examples, which allow us to capture some specifics:
  * Time intervals are half open `(ST, T]`.
  * Generally, ST SHOULD:
    * `ST[i] < T[i]` (equal means unknown)
    * For a cumulative, ST SHOULD:
      * Be the same across all samples for the same count:

      ```
      ST[0], T[0]
      ST[0], T[1]
      ST[0], T[2]
      ```

  * For delta, ST SHOULD (`=` because it looks the start time is exclusive):
    * `T[i-1] <= ST[i]`

* OTLP) Descriptive SHOULD rules only (one MUST?): The metric protocol says ST is [optional and recommended](https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/metrics/v1/metrics.proto), however there's a [mention of MUST ST indicating a reset for cumulatives](https://github.com/open-telemetry/opentelemetry-proto/blob/d1315d7f2c1504c36577a82cd42a73e3977fdd88/opentelemetry/proto/metrics/v1/metrics.proto#L318).
* Google) Restrictive MUST: [GCP data model](https://cloud.google.com/monitoring/api/ref_v3/rpc/google.monitoring.v3#google.monitoring.v3.TimeInterval) is strict and reject invalid samples that does not follow:
  * Time intervals are:
    * For reads half open `(ST, T]`.
    * For write closed `[ST, T]`.
  * For gauges, ST MUST:
    * `ST[i] == T[i]`
  * For a cumulative, ST MUST:
    * `ST[i] < T[i]`
    * Be the same across all samples for the same count:

    ```
    ST[0], T[0]
    ST[0], T[1]
    ST[0], T[2]
    ```

  * For delta, ST MUST:
    * `ST[i] < T[i] && T[i-1] < ST[i]`

### Pitfalls of the current solution(s)

* The `created-timestamps-zero-injection` feature allows some ST use cases, but it's limited in practice:
  * It's stateful, which means it can't be used effectively across the ecosystem. Essentially you can't miss a single sample (and/or you have to process all samples since 0) to find ST information per sample. For example:
    * Remote Write ingestion would need to be persistent and stateful, which blocks horizontal scalability of receiving.
    * It limits effectiveness of using ST for PromQL operations like `rate`, `resets` etc.
    * It makes "rolloup" (write time recording rules that pre-calculate rates) difficult to implement.
  * Given immutability invariant (e.g. Prometheus), you can't effectively inject ST at a later time (out of order writes are sometimes possible, but expensive, especially for a single sample to be written in the past per series).
  * It's prone to OOO false positives (we ignore this error for STs now in Prometheus).
  * It's producing an artificial sample, which looks like it was scraped.
* We can't implement delta temporarily effectively.

## Goals

* [MUST] Prometheus can reliably store, query, ingest and export cumulative start timestamp (ST) information (long term plan for [PROM-29](https://github.com/prometheus/proposals/blob/main/proposals/0029-created-timestamp.md#:~:text=For%20those%20reasons%2C%20created%20timestamps%20will%20also%20be%20stored%20as%20metadata%20per%20series%2C%20following%20the%20similar%20logic%20used%20for%20the%20zero%2Dinjection.))
* [SHOULD] Prometheus can reliably store, query, ingest and export delta start time information. This unblocks [PROM-48 delta proposal](https://github.com/prometheus/proposals/pull/48). Notably adding delta feature later on should ideally not require another complex storage design or implementation.
* [SHOULD] Overhead of the solution should be minimal--initial overhead target set to maximum of 10% CPU, 10% of memory and 15% of disk space.
* [SHOULD] Improve complexity/tech-debt of TSDB on the way if possible.
* [SHOULD] Complexity of consuming STs should be minimal (e.g. low amount of knowledge needed to use it).

## Non-goals

In this proposal we don't want to:

* Expand details on delta temporality. For this proposal it's enough to assume about delta, what's described in the [Background: Delta Temporality](#background-delta-temporality).
* Expand or motivate the non-monotonic counter feature.

## How

Native ST support may feel like a big change with a lot of implications. However, we have all the technical pieces to do this, especially if we implement ST with
(more or less) the same guarantees and details as normal sample timestamp (T), just optional.

General decisions and principles affecting smaller technical parts:

1. We propose to stick to the assumption that ST can change for every sample and don't try to prematurely optimize for the special cumulative best case. Rationales:

* This unlocks the most amount of benefits (e.g. also delta) for the same amount of work, it makes code simpler.
* We don't know if we need special cumulative best case optimization (yet); also it would be also for some "best" cases. Once we know we can always add those optimizations.

2. Similarly, we propose to not have special ST storage cases per metric types. TSDB storage is not metric type aware, plus some systems allow optional STs on gauges (e.g. OpenTelemetry). We propose keeping that storage flexibility.

3. We propose to treat ST as an *optional* data everywhere, simply because it's new and because certain metric type do not need it (gauges). For efficiency and consistency with scrape and Remote Write protocols we treat default value `int64(0)` as a "not provided" sentinel. This has a consequence of inability to provide the ST of an exact 0 value (unlikely needed and if needed clients needs to use 1m after or before.

4. Let's go through all the areas that would need to change:

### Feature flag `st-storage`

To develop and give experimental state to users, we propose to add a new feature flag `st-storage`. Similar to [exemplar-storage]https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage) it will tell Prometheus to ingest ST and use new (potentially breaking compatibility) storage formats.

We propose to have a single flag for both WAL, Block storage, etc., to avoid tricky configuration.

Notably, given persistence of this feature, similar to example storage, if users enabled and then disabled this feature, users will might be able to access their STs through all already persistent pieces e.g. WAL).

This feature could be considered to be switched to opt-out, only after it's finished (this proposal is fully implemented) stable, provably adopted and when the previous LTS Prometheus version is compatible with this feature.

### Proposed ST semantics and validation

See the [official ST semantics in the ecosystem](#background-official-st-semantics). In this section we propose what semantics we recommend (or enforce).

ST notion was popularized by OpenMetrics and OpenTelemetry. Early experience exposed a big challenge: ST data is extremely unclean given early adoption, mixed instrumentation support and multiple (all imperfect) ways of ["auto-generation"](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstarttimeprocessor) (`subtract_initial_point` might the most universally "correct", but it added only recently). This means that handling (or reducing ) ST errors is an important detail for consumers of this data.

We propose to not validate ST values on Prometheus write (Appender level). ST is treated as opaque and optional element of the sample. Prometheus will stores whatever int64 value it receives, with `0` meaning **not provided**. This is a deliberate design choice, given:
* ST data in Prometheus ecosystem is a new concept. ST is expected to be missing in many cases (e.g. old SDKs, old exporters, exporters where ST is non-trivial to detect).
* ST in wider ecosystem is often unclean (mixed instrumentation, imperfect auto-generation).
* The exact consumption semantics is still experimental thus we want to stay flexible and don't block future use cases (e.g. exact semantics of ST > T).

Consumers of ST data (PromQL operations, remote write receivers) are expected to handle missing or inconsistent ST values gracefully. Future proposals and Prometheus versions might offer stricter validation modes later on.

### TSDB programmatic interfaces

We propose a heavy modification to the (write) [Appender](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L269) interface and minor one to the (read) [SampleAndChunkQueryable](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L70).

#### Write

We need to have a reliable way for passing ST together with other sample details.

Light modifications (e.g. optional method/interface) could be possible, but there are strong reasons to do a complete refactor for Appender interface at this point:

* Current Appender interface is inconsistent (sometimes separate interfaces) and bloated (9 methods). We pay the heavy maintenance tool, and it hinders dev velocity, even now.
* Current Appender interface disconnects exemplars, metadata and zero ST handling, where in practise those details are always available together. It blocks any optimizations that would join this data or do things together with the sample appends in TSDB (or other appender implementation).
  * Another problem with disconnection is the nuances ordering of methods one need to do.
* It will remove tech debt in [OTLP ingestion](https://github.com/prometheus/prometheus/pull/16951) on converting OTLP appender interface to Prometheus one.

As a result we propose moving to a new improved `AppenderV2` interface, gradually (first scrape, then PRW ingest, then OTLP ingest, then TSDB implementation with https://github.com/prometheus/prometheus/pull/17104.).

// TODO(bwplotka): Add more context on why certain decisions were made
The initial work on the new appender interface started, see [`PR#17104`](https://github.com/prometheus/prometheus/pull/17104). The unified `AppenderV2` interface consolidates float, histogram, and float-histogram appends into a single method:

```go
// AppenderV2 provides batched appends against a storage for all sample types.
// It must be completed with a call to Commit or Rollback and must not be reused afterwards.
type AppenderV2 interface {
	AppenderTransaction // Commit() error; Rollback() error

	// Append appends a sample with optional start timestamp (st) and auxiliary data (opts).
	// st=0 means unknown. Callers provide exactly one of v, h, or fh.
	Append(ref SeriesRef, ls labels.Labels, st, t int64, v float64,
		h *histogram.Histogram, fh *histogram.FloatHistogram,
		opts AppendV2Options) (SeriesRef, error)
}

// AppendableV2 allows creating AppenderV2.
type AppendableV2 interface {
	AppenderV2(ctx context.Context) AppenderV2
}

type AppendV2Options struct { /* metadata, exemplars, etc. */
}
```

#### Read

> NOTE: The `AtST()` addition to `chunkenc.Iterator` has been implemented. See [PR#17176](https://github.com/prometheus/prometheus/pull/17176).

Majority of reads happens through the [Queryable](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L97) interface which offers selecting samples from the storage and iterating on them.

[ChunkQueryable](https://github.com/prometheus/prometheus/blob/main/storage/interface.go#L146) also exists, but it allows
iteration over set of encoded chunks (byte format), so ST is assumed to be encoded there (discussed in [TSDB block format](#tsdb-blocks)). It's only used for Remote Read (streamed) protocol.

Prometheus read APIs are in a much better shape, so we propose a light, additive change to `Queryable` to add a way to retrieve ST when iterating over samples. This unblocks PromQL engine use of ST sample late on.

Eventually `Queryable` unrolls to `Iterator(chunkenc.Iterator) chunkenc.Iterator` that allows per sample access. As a result we propose [chunkenc.Iterator](https://github.com/prometheus/prometheus/blob/main/tsdb/chunkenc/chunk.go#L123) changes as follows:

```
// Iterator is a simple iterator that can only get the next value.
// Iterator iterates over the samples of a time series, in timestamp-increasing order.
type Iterator interface {
	// Next advances the iterator by one and returns the type of the value
	// at the new position (or ValNone if the iterator is exhausted).
	Next() ValueType
	// At returns the current timestamp/value pair if the value is a float.
	// Before the iterator has advanced, the behaviour is unspecified.
	At() (int64, float64)
	// AtT returns the current timestamp.
	// Before the iterator has advanced, the behaviour is unspecified.
	AtT() int64
+	// AtST returns the current start timestamp.
+	// Returns 0 if the start timestamp is not implemented or not set.
+	// Before the iterator has advanced, the behaviour is unspecified.
+	AtST() int64

    // ...
}
```

### Persistent storage interfaces (file formats)

Prometheus TSDB persists data on disk. Changing those formats are required to
ensure persistent ST storage, but also enable export capabilities (within Prometheus itself, Remote Write handler watches WAL records (tail WAL) to export samples).

Extending storage formats would also allow external ecosystem to use STs (e.g. Cortex, Mimir, Thanos) in their LTS storages.

> IMPORTANT: Those formats have to be extended in a backward/forward compatible which touches versioning policy we discussed in [PROM-40](https://github.com/prometheus/proposals/pull/40). While no formal agreement was made we propose generally agree-able consensus to make sure previous LTS version can read new data before making new data a new default.

Let's go through all TSDB artifacts we propose to change:

#### WAL

The Write-Ahead-Log (WAL) with its [format](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/wal.md) is a critical piece of [persistence mechanism](https://en.wikipedia.org/wiki/Write-ahead_logging) that groups recent appends and saves them on disk, allowing durability without delaying writes (due to disk latency). Extending WAL support for ST is a prerequisite to even talk about extending TSDB block or remote write use cases later on.

See [Ganesh's TSDB blog post series](https://ganeshvernekar.com/blog/prometheus-tsdb-wal-and-checkpoint/) to learn more about Prometheus WAL.

> NOTE: WAL records have similar issue as Appender interface ([tech debt, need for uniforming](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/record/record.go#L159))). Here adding new record only for sample for now (instead of redesigning all records into one) might be more pragmatic choice.

In principle, following our [per sample assumption](#how), we need to extend representation of a sample in WAL in a following way:

```go
// RefSample is a timestamp/st/value struct associated with a reference to a series.
// TODO(beorn7): Perhaps make this "polymorphic", including histogram and float-histogram pointers? Then get rid of RefHistogramSample.
type RefSample struct {
	Ref chunks.HeadSeriesRef
-	T   int64
+	ST, T int64
	V   float64
}
```

> NOTE: We are still evaluating performance to determine if we need to implement a separate `type RefSampleWithST struct` or if a single struct is sufficient for both usecases.

With that we need to introduce [a new sample record format](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records) for samples e.g. `SamplesV2` and implement [decoding](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/record/record.go#L305) and [encoding](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/record/record.go#L668). For compatibility, we propose using the new `SamplesV2` record type behind a feature flag (e.g. `st-storage`) until the next Prometheus LTS version. After that, we could consider making it default-enabled.

There are various choices on how the record format should look like (e.g. should gauges use `sample` or unified `SamplesV2`?, should delta use a different record than cumulative?). To answer this it's important to reflect on the access patterns of TSDB.

Notably, Prometheus TSDB "head" appender "logs" a single WAL record for each record type on every [`Appender.Commit`](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/head_append.go#L1494). This means, that:
* All float samples to commit are encoded as a single [Sample record](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records).
* All int histograms to commit are encoded as single [Histogram record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#histogram-records).
* All float histograms to commit are encoded as single [FloatHistogram record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#histogram-records).
* All exemplars to commit are encoded as a single [Exemplar record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#exemplar-records).

For scrape purposes, a single appender "commit" in Prometheus contains all samples from a single scrape, which means **single "sample" (with likely the same timestamp) for multiple series**. With STs this also means "likely" the same values per commit (less likely compared to timestamp). For STs (delta) this is not relevant for scrape. Despite the timestamp likelhood to not change inside each commit, [sample record](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records) is capable of capturing the differences. This tells us that ST should likely follow the same pattern.

Additionally, appender, historically, didn't have access to type of the metric so the same record is used for gauge, counter, classic histogram etc. We propose to keep this logic as diverging and different records for set of different metric types would be complex to maintain for (likely) little gain.

For other ingestion purposes (OTLP/PRW) appender is still used, but here we can't have any assumptions about the characteristic of samples appended within a single commit.

As a result we propose to create a new V2 records that will be used **for all metric types with float sample type**. This means following format:

```
SamplesV2 records encode float counter samples as a list of (series_ref, start_timestamp,
timestamp, value) tuples. The first sample stores absolute values. Subsequent
samples use delta encoding with ST marker bytes.

┌─────────────────────────────────────────────────────────────────────────────────────┐
│ type = 11 <1b>                                                                      │
├─────────────────────────────────────────────────────────────────────────────────────┤
│ ┌─────────────────┬──────────────┬─────────────┬─────────────┐                      │
│ │ ref <varint>    │ T <varint>   │ ST <varint> │ value <8b>  │  (first sample)      │
│ └─────────────────┴──────────────┴─────────────┴─────────────┘                      │
│ ┌──────────────────────────────┬───────────────────────────────┬────────────────┐   │
│ │ ref_delta (vs prev) <varint> │ T_delta (vs first T) <varint> │ st_marker <1b> │   │
│ ├──────────────────────────────┴───────────────────────────────┴────────────────┤   │
│ │ [ST_delta (vs first ST) <varint>]  (only if st_marker = explicitST)           │   │
│ ├───────────────────────────────────────────────────────────────────────────────┤   │
│ │ value <8b>                                                                    │   │
│ └───────────────────────────────────────────────────────────────────────────────┘   │
│                                      . . .                                          │
└─────────────────────────────────────────────────────────────────────────────────────┘

ST marker values:
  0 (noST)       -- sample has no start timestamp (ST=0)
  1 (sameST)     -- same ST as previous sample
  2 (explicitST) -- explicit ST, followed by ST_delta (vs first ST)
```

Similar V2 records will be created for Histogram types.

#### TSDB blocks

ST will be persisted in TSDB blocks using a new chunk encoding currently under development.

#### Memory Snapshots and Head Chunks

There will be likely some code to add to ensure STs are used properly, but the new proposed chunk format from [TSDB Block](#tsdb-blocks) section, should immidately work with the [Memory Snapshot](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/memory_snapshot.md) and [Head Chnks](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/head_chunks.md) formats.

### Remote storage

Remote read is relevant but the newer version of it sends encoded chunks, so [TSDB block](#tsdb-blocks) changes will get us ST for this path.

The [Remote Write 2.0](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0) was designed to include ST per series. This is not aligning well to this proposal idea for representing ST as something that can change per sample. For clarity and since, it's an experimental protocol we propose to do a small breaking change and move it to be per sample (similar for histogram samples):

* Spec change: https://github.com/prometheus/docs/pull/2762
* Implementation change: https://github.com/prometheus/prometheus/pull/17411

## Alternatives

* Separate solution for delta and cumulative.

Given the delta vs cumulative characteristics one could argue separate WAL records, send/receive protocol messages and TSDB chunk formats should be created.

The unified approach is simpler to implement and maintain because both temporalities share the same storage path through AppenderV2, WAL encoding, and chunk format. Separate formats would double the testing surface and complicate the WAL replay and compaction code paths for marginal space savings, since the ST marker byte scheme already handles the "same ST" cumulative case efficiently (1 byte overhead when ST does not change between samples).

## Action Plan

See the [ST storage project board](https://github.com/orgs/prometheus/projects/17/views/2) for current task tracking.
