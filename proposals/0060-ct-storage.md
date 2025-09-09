## Native TSDB Support for Cumulative Created Timestamp (CT) (and Delta Start Timestamp (ST) on the way)

* **Owners:**
  * [`@bwplotka`](https://github.com/bwplotka)
  * <[delta-type-WG](https://docs.google.com/document/d/1G0d_cLHkgrnWhXYG9oXEmjy2qp6GLSX2kxYiurLYUSQ/edit) members?>

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [WAL](https://github.com/prometheus/prometheus/issues/14218), [PRW2](https://github.com/prometheus/prometheus/issues/14220), [CT Meta](https://github.com/prometheus/prometheus/issues/14217).
  * [initial attempt for ct per sample](https://github.com/prometheus/prometheus/pull/16046)
  * [rw2 proto change for ct per sample](https://github.com/prometheus/prometheus/pull/17036)
  * Initial implementation
    * [Appender](https://github.com/prometheus/prometheus/pull/17104)
    * [chunkenc.Iterator](https://github.com/prometheus/prometheus/pull/17176)

* **Other docs or links:**
  * [PROM-29 (Created Timestamp)](https://github.com/prometheus/proposals/blob/main/proposals/0029-created-timestamp.md)
  * [Delta type proposal](https://github.com/prometheus/proposals/pull/48), [Delta WG](https://docs.google.com/document/d/1G0d_cLHkgrnWhXYG9oXEmjy2qp6GLSX2kxYiurLYUSQ/edit)

> TL;DR: We propose to extend Prometheus TSDB storage sample definition to include an extra int64 that will represent the cumulative created timestamp (CT) and, for the future delta temporality ([PROM-48](https://github.com/prometheus/proposals/pull/48)), a delta start timestamp (ST).
> We propose introducing persisting CT logic behind a single flag `ct-storage`.
> Once implemented, wee propose to deprecate the `created-timestamps-zero-injection` experimental feature.

## Why

The main goal of this proposal is to make sure [PROM-29's created timestamp (CT)](0029-created-timestamp.md) information is reliably and efficiently stored in Prometheus TSDB, so:

* Written via TSDB Appender interfaces.
* Query-able via TSDB Querier interfaces.
* Persistent in WAL.
* Watch-able (WAL) by Remote Writer.
* (eventually) Persistent in TSDB block storage.

To do it reliably, we propose to extend TSDB storage to "natively" support CT as something you can attach to a sample and use later on.
Native CT support in Prometheus TSDB would unblock the practical use of CT information for:

* Remote storages (Remote Write 2.0) (e.g. OpenTelemetry, Chronosphere, Google).
* PromQL and other read APIs (including federation) (e.g. increased cumulative based operation accuracy).

Furthermore, it would unblock future Prometheus features for wider range of monitoring cases like:

* Delta temporality support.
* UpAndDown counter (i.e. not monotonic counters) e.g. StatsD.

On top of that this work also allow to improve some existing features, notably various edge cases for native histogram resets hints (e.g. [TSDB chunk merges](https://github.com/prometheus/prometheus/issues/15346)). Arguably, CT can replace resent hint field in native histogram eventually.

### Background: CT feature

[PROM-29](0029-created-timestamp.md) introduced the "created timestamp" (CT) concept for Prometheus cumulative metrics. Semantically, CT represents the time when "counting" (from 0) started. In other words, CT is the time when the counter "instance" was created.

Conceptually, CT extends the Prometheus data model for cumulative monotonic counters as follows:

* (new) int64 Timestamp (CT): When counting started.
* float64 or [Histogram](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/model/histogram/histogram.go#L50) Value (V): The current value of the count, since the CT time.
* int64 Timestamp (T): When this value was observed.
* Labels: Unique identity of a series.
  * This includes special metadata labels like: `__name__`, `__type__`, `__unit__`
* Exemplars
* Metadata

Since the CT concept introduction in Prometheus we:

* Extended Prometheus protobuf scrape format to include CT per each cumulative sample (TODO link).
* Proposed (for OM 2) text format changes for CT scraping (improvement over existing OM1 `_created` lines) (TODO link).
* Expanded Scrape parser interface to return `CreatedTimestamp` per sample (aka per line).
* Optimized Protobuf and OpenMetrics parsers for CT use (TODO links).
* Implemented an opt-in, experimental [`created-timestamps-zero-injection`](https://prometheus.io/docs/prometheus/latest/feature_flags/#created-timestamps-zero-injection) feature flag that injects fake sample (V: 0, T: CT).
* Included CT in [Remote Write 2 specification](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/#ioprometheuswritev2request).

### Background: Delta temporality

See the details, motivations and discussions about the delta temporality in [PROM-48](https://github.com/prometheus/proposals/pull/48).

The core TL;DR relevant for this proposal is that the delta temporality counter sample can be conceptually seen as a "mini-cumulative counter". Essentially delta is a single-sample (value) cumulative counter for a period between (sometimes inclusive sometimes exclusive depending on a system) start(ST)/create(CT) timestamp and a (end)timestamp (inclusive).

In other words, instant query for `increase(<cumulative counter>[5m])` produces a single delta sample for a `[t-5m, t]` period (V: `increase(<counter>[5m])`, CT/ST: `now()-5m`, T: `now()`).

This proves that it's worth considering delta when designing a CT feature support.

### Background: CT (cumulative) vs ST (delta)

[Previous section](#background-delta-temporality) argues that conceptually the Cumulative Created Timestamp (CT) and Delta Start Timestamp (ST) are essentially the same thing. This is why typically they are stored in the same "field" in other system APIs and storages (e.g. start time in OpenTelemetry TODO link).

The notable difference when this special timestamp is used for cumulative vs delta samples is the dynamicity **characteristics** of this timestamp.

* For the cumulative we expect CT to change on every new counter restart, so:
  * Average: in the order of ~weeks/months for stable workloads, ~days/weeks for more dynamic environments (Kubernetes).
  * Best case: it never changes (infinite count) e.g days_since_X_total.
  * Worse case: it changes for every sample.
* For the delta we expect CT to change for every sample.

### Background: Official CT/ST semantics

There are certain semantic constraints on CT/ST values to make them useful for consumers of the known metric types and semantics. Different systems generally have similar semantics, but details and how strong (or practically enforced) those rules are may differ. Let's go through state-of-the-art, just to have an idea what we could propose for Prometheus CT enforcement (if anything):

For the purpose of the example, let's define 3 consecutive samples for the same series (value is skipped for brevity):

```
CT[0], T[0]
CT[1], T[1]
CT[2], T[2]
```

* OM) Descriptive SHOULD rules only: In OpenMetrics 1.0 CT does not have specific technical rules other than it should ["help consumers discern between new metrics and long-running ones" and that it must be set to "reset time"](https://prometheus.io/docs/specs/om/open_metrics_spec/#:~:text=A%20MetricPoint%20in%20a%20Metric%20with%20the%20type%20Counter%20SHOULD,MUST%20also%20be%20set%20to%20the%20timestamp%20of%20the%20reset.).
* RW2) Descriptive SHOULD rules only: Similarly in [Remote Write 2.0 spec, only descriptive CTs rules](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/#ioprometheuswritev2request:~:text=created_timestamp%20SHOULD%20be%20provided%20for%20metrics%20that%20follow%20counter%20semantics%20(e.g.%20counters%20and%20histograms).%20Receivers%20MAY%20reject%20those%20series%20without%20created_timestamp%20being%20set.)
  * created_timestamp SHOULD be provided for metrics that follow counter semantics (e.g. counters and histograms).
  * Receivers MAY reject those series without created_timestamp being set.

* Otel) More detailed, but still descriptive SHOULD rules only: In OpenTelemetry data model ([temporality section](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#sums:~:text=name%2Dvalue%20pairs.-,A%20time%20window%20(of%20(start%2C%20end%5D)%20time%20for%20which%20the,The%20time%20interval%20is%20inclusive%20of%20the%20end%20time.,-Times%20are%20specified)) CT is generally optional, but strongly recommended. Rules are also soft and we assume they are "SHOULD" because there is section of [handling overlaps](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#overlap). However, it provides more examples, which allow us to capture some specifics:
  * Time intervals are half open `(CT, T]`.
  * Generally, CT SHOULD:
    * `CT[i] < T[i]` (equal means unknown)
    * For a cumulative, CT SHOULD:
      * Be the same across all samples for the same count:

      ```
      CT[0], T[0]
      CT[0], T[1]
      CT[0], T[2]
      ```

  * For delta, CT SHOULD (`=` because it looks the start time is exclusive):
    * `T[i-1] <= CT[i]`

* OTLP) Descriptive SHOULD rules only (one MUST?): The metric protocol says CT is [optional and recommended](https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/metrics/v1/metrics.proto), however there's a [mention of MUST CT indicating a reset for cumulatives](https://github.com/open-telemetry/opentelemetry-proto/blob/d1315d7f2c1504c36577a82cd42a73e3977fdd88/opentelemetry/proto/metrics/v1/metrics.proto#L318).
* Google) Restrictive MUST: [GCP data model](https://cloud.google.com/monitoring/api/ref_v3/rpc/google.monitoring.v3#google.monitoring.v3.TimeInterval) is strict and reject invalid samples that does not follow:
  * Time intervals are:
    * For reads half open `(CT, T]`.
    * For write closed `[CT, T]`.
  * For gauges, CT MUST:
    * `CT[i] == T[i]`
  * For a cumulative, CT MUST:
    * `CT[i] < T[i]`
    * Be the same across all samples for the same count:

    ```
    CT[0], T[0]
    CT[0], T[1]
    CT[0], T[2]
    ```

  * For delta, CT MUST:
    * `CT[i] < T[i] && T[i-1] < CT[i]`

### Pitfalls of the current solution(s)

* The `created-timestamps-zero-injection` feature allows some CT use cases, but it's limited in practice:
  * It's stateful, which means it can't be used effectively across the ecosystem. Essentially you can't miss a single sample (and/or you have to process all samples since 0) to find CT information per sample. For example:
    * Remote Write ingestion would need to be persistent and stateful, which blocks horizontal scalability of receiving.
    * It limits effectiveness of using CT for PromQL operations like `rate`, `resets` etc.
    * It makes "rolloup" (write time recording rules that pre-calculate rates) difficult to implement.
  * Given immutability invariant (e.g. Prometheus), you can't effectively inject CT at a later time (out of order writes are sometimes possible, but expensive, especially for a single sample to be written in the past per series).
  * It's prone to OOO false positives (we ignore this error for CTs now in Prometheus).
  * It's producing an artificial sample, which looks like it was scraped.
* We can't implement delta temporarily effectively.

## Goals

* [MUST] Prometheus can reliably store, query, ingest and export cumulative created timestamp (CT) information (long term plan for [PROM-29](https://github.com/prometheus/proposals/blob/main/proposals/0029-created-timestamp.md#:~:text=For%20those%20reasons%2C%20created%20timestamps%20will%20also%20be%20stored%20as%20metadata%20per%20series%2C%20following%20the%20similar%20logic%20used%20for%20the%20zero%2Dinjection.))
* [SHOULD] Prometheus can reliably store, query, ingest and export delta start time information. This unblocks [PROM-48 delta proposal](https://github.com/prometheus/proposals/pull/48). Notably adding delta feature later on should ideally not require another complex storage design or implementation.
* [SHOULD] Overhead of the solution should be minimal--initial overhead target set to maximum of 10% CPU, 10% of memory and 15% of disk space.
* [SHOULD] Improve complexity/tech-debt of TSDB on the way if possible.
* [SHOULD] Complexity of consuming CTs should be minimal (e.g. low amount of knowledge needed to use it).

## Non-goals

In this proposal we don't want to:

* Expand details on delta temporality. For this proposal it's enough to assume about delta, what's described in the [Background: Delta Temporality](#background-delta-temporality).
* Expand or motivate the non-monotonic counter feature.

## How

Native CT support may feel like a big change with a lot of implications. However, we have all the technical pieces to do this, especially if we implement CT with
(more or less) the same guarantees and details as normal sample timestamp (T), just optional.

General decisions and principles affecting smaller technical parts:

1. We propose to stick to the assumption that CT can change for every sample and don't try to prematurely optimize for the special cumulative best case. Rationales:

* This unlocks the most amount of benefits (e.g. also delta) for the same amount of work, it makes code simpler.
* We don't know if we need special cumulative best case optimization (yet); also it would be also for some "best" cases. Once we know we can always add those optimizations.

2. Similarly, we propose to not have special CT storage cases per metric types. TSDB storage is not metric type aware, plus some systems allow optional CTs on gauges (e.g. OpenTelemetry). We propose keeping that storage flexibility.

3. We propose to treat CT as an *optional* data everywhere, simply because it's new and because certain metric type do not need it (gauges). For efficiency and consistency with scrape and Remote Write protocols we treat default value `int64(0)` as a "not provided" sentinel. This has a consequence of inability to provide the CT of an exact 0 value (unlikely needed and if needed clients needs to use 1m after or before.

4. Given the [CT and ST context](#background-ct-cumulative-vs-st-delta) the CT vs ST meaning blurs. We could rename CT feature now to ST to be consistent with other systems. We propose to stick to "created timestamp" (CT) naming in Prometheus instead of attempting to rename some or all uses to "start timestamp" (ST). The main reason being that CT and ST naming is equally "correct" on storage and given Prometheus is cumulative-first system, we stick to CT. See (and challenge!) the rationales in the [alternative](#rename-ct-to-st).

Given (4) decision, below proposal only uses "CT" naming, but it also means "ST" in delta temporality context.

Let's go through all the areas that would need to change:

### Feature flag `ct-storage`

To develop and give experimental state to users, we propose to add a new feature flag `created-timestamp-storage`. Similar to [exemplar-storage]https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage) it will tell Prometheus to ingest CT and use new (potentially breaking compatibility) storage formats.

We propose to have a single flag for both WAL, Block storage, etc., to avoid tricky configuration.

Notably, given persistence of this feature, similar to example storage, if users enabled and then disabled this feature, users will might be able to access their CTs through all already persistent pieces e.g. WAL).

This feature could be considered to be switched to opt-out, only after it's finished (this proposal is fully implemented) stable, provably adopted and when the previous LTS Prometheus version is compatible with this feature.

### Proposed CT semantics and validation

See the [official CT semantics in the ecosystem](#background-official-ctst-semantics). In this section we propose what semantics we recommend (or enforce).

CT/ST notion was popularized by OpenTelemetry and early experience exposed a big challenge: CT/ST data is extremely unclean given early adoption, mixed instrumentation support and multiple (all imperfect) ways of ["auto-generation"](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstarttimeprocessor) (`subtract_initial_point` might the most universally "correct", but it added only recently). This means that handling (or reducing ) CT errors is an important detail for consumers of this data.

TODO: Just a draft, to be discussed.
TODO: There are questions around:
* Should we do inclusive vs exclusive intervals?
* Given optionality of this feature, can we even reject sample on TSDB Append if CT is invalid? (MUST or SHOULD on interface?)
* Does it even make sense to enforce (MUST?) on Appender? Wouldn't this give user assumption to user that the data is safe? There will be tons of data produced by external writers for TSDB blocks which could ingest errors, also old data will have errors for sure. Still maybe worth to filter?
* Would it be expensive (possible) to validate? (OOO check is simple)?

### TSDB programmatic interfaces

We propose a heavy modification to the (write) [Appender](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L269) interface and minor one to the (read) [SampleAndChunkQueryable](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L70).

#### Write

We need to have a reliable way for passing CT together with other sample details.

Light modifications (e.g. optional method/interface) could be possible, but there are strong reasons to do a complete refactor for Appender interface at this point:

* Current Appender interface is inconsistent (sometimes separate interfaces) and bloated (9 methods). We pay the heavy maintenance tool, and it hinders dev velocity, even now.
* Current Appender interface disconnects exemplars, metadata and zero CT handling, where in practise those details are always available together. It blocks any optimizations that would join this data or do things together with the sample appends in TSDB (or other appender implementation).
  * Another problem with disconnection is the nuances ordering of methods one need to do.
* It will remove tech debt in [OTLP ingestion](https://github.com/prometheus/prometheus/pull/16951) on converting OTLP appender interface to Prometheus one.

As a result we propose moving to a new improved `AppenderV2` interface, gradually (first scrape, then PRW ingest, then OTLP ingest, then TSDB implementation with https://github.com/prometheus/prometheus/pull/17104.).

The initial work on the new appender interface started, see [`PR#17104`](https://github.com/prometheus/prometheus/pull/17104). The current directions seems to a be significantly simpler `AppenderV2` interface like:

```
// AppenderV2 provides batched appends against a storage.
// It must be completed with a call to Commit or Rollback and must not be reused afterwards.
//
// Operations on the Appender interface are not go-routine-safe.
//
// The type of samples (float64, histogram, etc) appended for a given series must remain same within an Appender.
// The behaviour is undefined if samples of different types are appended to the same series in a single Commit().
// TODO(krajorama): Undefined behaviour might change in https://github.com/prometheus/prometheus/issues/15177
//
// NOTE(bwplotka): This interface is experimental, migration of Prometheus pieces is in progress.
// TODO(bwplotka): Explain complex errors for partial error cases.
type AppenderV2 interface {
    // TODO type and unit label semantics? 
	// TODO(play with it): Append(ref SeriesRef, ls labels.Labels, meta metadata.Metadata, ct, t int64, v float64, h *histogram.Histogram, fh *histogram.FloatHistogram, es []exemplar.Exemplar) (SeriesRef, error)
	  
	// AppendSample appends a sample(s) and related exemplars, metadata, and created timestamp to the storage.
	// Implementations MUST attempt to append sample (float or histograms) even if ct, metadata or  exemplar fail.
	// The created timestamp (ct) is optional. ct value of int64(0) means no timestamp.  
	AppendSample(ref SeriesRef, ls labels.Labels, meta Metadata, ct, t int64, v float64, es []exemplar.Exemplar) (SeriesRef, error)

	// AppendHistogram appends a float or int histogram sample and related exemplars, metadata, and created timestamp to the storage.
	AppendHistogram(ref SeriesRef, ls labels.Labels, meta Metadata, ct, t int64, h *histogram.Histogram, fh *histogram.FloatHistogram, es []exemplar.Exemplar) (SeriesRef, error)  

	// Commit submits the collected samples and purges the batch. If Commit
	// returns a non-nil error, it also rolls back all modifications made in
	// the appender so far, as Rollback would do. In any case, an Appender
	// must not be used anymore after Commit has been called.
	Commit() error

	// Rollback rolls back all modifications made in the appender so far.
	// Appender has to be discarded after rollback.
	Rollback() error
}
 
// Appendable allows creating appenders.
type Appendable interface {
	// Appender returns a new appender for the storage. The implementation
	// can choose whether or not to use the context, for deadlines or to check
	// for errors.
	Appender(ctx context.Context) Appender
	
	// Appender returns a new appender for the storage. The implementation
	// can choose whether or not to use the context, for deadlines or to check
	// for errors.
	AppenderV2(ctx context.Context, opts *AppenderV2Options) AppenderV2 
}
  
type AppenderV2Options struct {
    // TODO(bwplotka): This options is inheritted from Appender interface, but it needs some love e.g. why not client doing this? What happens with exemplar, metadata on discard sample?
	DiscardOutOfOrderSamples bool

	// PrependCTAsZero ensures that CT is appended as fake zero sample on all append methods.
	// NOTE(bwplotka): This option might be removed in future.
	PrependCTAsZero bool
} 
```

#### Read

> NOTE: This can be done later on (M2/M3) for CT, but it's required for delta PromQL support M1.
> draft PR: https://github.com/prometheus/prometheus/pull/17176

Majority of reads happens through the [Queryable](https://github.com/prometheus/prometheus/blob/d7e9a2ffb0f0ee0b6835cda6952d12ceee1371d0/storage/interface.go#L97) interface which offers selecting samples from the storage and iterating on them.

[ChunkQueryable](https://github.com/prometheus/prometheus/blob/main/storage/interface.go#L146) also exists, but it allows
iteration over set of encoded chunks (byte format), so CT is assumed to be encoded there (discussed in [TSDB block format](#tsdb-blocks)). It's only used for Remote Read (streamed) protocol.

Prometheus read APIs are in a much better shape, so we propose a light, additive change to `Queryable` to add a way to retrieve CT when iterating over samples. This unblocks PromQL engine use of CT sample late on.

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
+	// AtCT returns the current, optional, created timestamp.
+   // The created timestamp (ct) is optional. The value int64(0) means no timestamp.
+	// Before the iterator has advanced, the behaviour is unspecified.
+	AtCT() int64

    // ...  
} 
```

### Persistent storage interfaces (file formats)

Prometheus TSDB persists data on disk. Changing those formats are required to
ensure persistent CT storage, but also enable export capabilities (within Prometheus itself, Remote Write handler watches WAL records (tail WAL) to export samples).

Extending storage formats would also allow external ecosystem to use CTs (e.g. Cortex, Mimir, Thanos) in their LTS storages.

> IMPORTANT: Those formats have to be extended in a backward/forward compatible which touches versioning policy we discussed in [PROM-40](https://github.com/prometheus/proposals/pull/40). While no formal agreement was made we propose generally agree-able consensus to make sure previous LTS version can read new data before making new data a new default.

Let's go through all TSDB artifacts we propose to change:

#### WAL

The Write-Ahead-Log (WAL) with its [format](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/wal.md) is a critical piece of [persistence mechanism](https://en.wikipedia.org/wiki/Write-ahead_logging) that groups recent appends and saves them on disk, allowing durability without delaying writes (due to disk latency). Extending WAL support for CT is a prerequisite to even talk about extending TSDB block or remote write use cases later on.

See [Ganesh's TSDB blog post series](https://ganeshvernekar.com/blog/prometheus-tsdb-wal-and-checkpoint/) to learn more about Prometheus WAL.

> NOTE: WAL records have similar issue as Appender interface ([tech debt, need for uniforming](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/record/record.go#L159))). Here adding new record only for sample for now (instead of redesigning all records into one) might be more pragmatic choice.

In principle, following our [per sample assumption](#how), we need to extend representation of a sample in WAL in a following way:

```go
// RefSample represents Prometheus sample associated with a reference to a series.
// TODO(beorn7): Perhaps make this "polymorphic", including histogram and float-histogram pointers? Then get rid of RefHistogramSample.
type RefSample struct {
	Ref chunks.HeadSeriesRef
-	T   int64
+	CT, T int64	
	V   float64
}
```

> NOTE: In practice we may need to create a new `type RefSampleWithCT struct`. This is up to the implementation.

With that we need to introduce [a new sample record format](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records) for samples e.g. `sampleWithCT` and implement (by hand) [decoding](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/record/record.go#L305) and [encoding](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/record/record.go#L668). For compatibility, we propose using the new `sampleWithCT` record type behind a feature flag (e.g. `ct-storage`) until the next Prometheus LTS version. After that, we could consider making it default.

TODO: Add alternative that explains why not per series?

There are various choices on how the record format should look like (e.g. should gauges use `sample` or unified `sampleWithCT`?, should delta use different recorde than cumulative?). To answer this it's important to reflect on the access patterns of TSDB.

Notably, Prometheus TSDB "head" appender "logs" a single WAL record for each record type on every [`Appender.Commit`](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/head_append.go#L1494). This means, that:
* All float samples to commit are encoded as a single [Sample record](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records).
* All int histograms to commit are encoded as single [Histogram record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#histogram-records).
* All float histograms to commit are encoded as single [FloatHistogram record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#histogram-records).
* All exemplars to commit are encoded as a single [Exemplar record](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md#exemplar-records).

For scrape purposes, a single appender "commit" in Prometheus contains all samples from a single scrape, which means **single "sample" (with likely the same timestamp) for multiple series**. With CTs this also means "likely" the same values per commit (less likely compared to timestamp). For STs (delta) this is not relevant for scrape. Despite the timestamp likelhood to not change inside each commit, [sample record](https://github.com/prometheus/prometheus/blob/594f9d63a5f9635d48d6e26b68b708e21630f9ee/tsdb/docs/format/wal.md#sample-records) is capable of capturing the differences. This tells us that CT should likely follow the same pattern.

Additionally, appender, historically, didn't have access to type of the metric so the same record is used for gauge, counter, classic histogram etc. We propose to keep this logic as diverging and different records for set of different metric types would be complex to maintain for (likely) little gain.

For other ingestion purposes (OTLP/PRW) appender is still used, but here we can't have any assumptions about the characteristic of samples appended within a single commit.

As a result we propose to create a new `sampleWithCT` record that will be used **for all metric types with float sample type**. This means following format:

```
 
SampleWithCT records encode samples as a list of triples (series_id, created timestamp, timestamp, value). Series reference and timestamps are encoded as deltas w.r.t the first sample. The first row stores the starting id and the starting timestamp (TODO: One for both timestamps?). The first sample record begins at the second row.

┌──────────────────────────────────────────────────────────────────┐
│ type = 2 <1b>                                                    │
├──────────────────────────────────────────────────────────────────┤
│ ┌────────────────────┬───────────────────────────┐               │
│ │ id <8b>            │ timestamp <8b>            │               │
│ └────────────────────┴───────────────────────────┘               │
│ ┌────────────────────┬───────────────────────────┬───────────────────────────────────┬─────────────┐ │
│ │ id_delta <uvarint> │ timestamp_delta <uvarint> │ created_timestamp_delta <uvarint> │ value <8b>  │ │
│ └────────────────────┴───────────────────────────┴───────────────────────────────────┴─────────────┘ │
│                              . . .                               │
└──────────────────────────────────────────────────────────────────┘ 
```

TODO: Explain the decision to use the same timestamp as a start time for both T and CT deltas.

TODO: Any optimizations needed? What's the overhead? Benchmarks!

TODO: explain other choices.

#### TSDB blocks

> NOTE: This can be done later on (M2/M3).

TODO: 120 sample chunks would need to be benchmarked -- if adding CT per sample would be ok OR should we design more complex chunk encoding (CT per set of samples) OR even chunk per CT (what native histograms are doing for reset hints, and it's not idea (see [worst case](#background-ct-cumulative-vs-st-delta)))

TODO: Include learnings from native histogram folks on issues around TSDB chunk per CT/reset hint e.g. https://github.com/prometheus/prometheus/issues/15346

#### Memory Snapshots and Head Chunks

There will be likely some code to add to ensure CTs are used properly, but the new proposed chunk format from [TSDB Block](#tsdb-blocks) section, should immidately work with the [Memory Snapshot](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/memory_snapshot.md) and [Head Chnks](https://github.com/prometheus/prometheus/blob/747c5ee2b19a9e6a51acfafae9fa2c77e224803d/tsdb/docs/format/head_chunks.md) formats.

### Remote storage

Remote read is relevant but the newer version of it sends encoded chunks, so [TSDB block](#tsdb-blocks) changes will get us CT for this path.

The [Remote Write 2.0](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0) was designed to include CT per series. This is not aligning well to this proposal idea for representing CT as something that can change per sample. For clarity and since, it's an experimental protocol we propose to do a small breaking change and move it to be per sample (similar for histogram samples):

```proto
// TimeSeries represents a single series.
message TimeSeries {
  repeated Sample samples = 2;
  
  // (...)
  
  // This field is reserved for backward compatibility with the deprecated fields;
  // previously present in the experimental remote write period.
  reserved 6;
}

// Sample represents series sample.
message Sample {
  // value of the sample.
  double value = 1;
  // timestamp represents timestamp of the sample in ms.
  //
  // For Go, see github.com/prometheus/prometheus/model/timestamp/timestamp.go
  // for conversion from/to time.Time to Prometheus timestamp.
  int64 timestamp = 2;
  // created_timestamp represents an optional created timestamp for the sample,
  // in ms format. This information is typically used for counter, histogram (cumulative)
  // or delta type metrics.
  //
  // For cumulative metrics, the created timestamp represents the time when the
  // counter started counting (sometimes referred to as start timestamp), which
  // can increase the accuracy of certain processing and query semantics (e.g. rates).
  //
  // Note that some receivers might require created timestamps for certain metric
  // types; rejecting such samples within the Request as a result.
  //
  // For Go, see github.com/prometheus/prometheus/model/timestamp/timestamp.go
  // for conversion from/to time.Time to Prometheus timestamp.
  //
  // Note that the "optional" keyword is omitted due to efficiency and consistency.
  // Zero value means value not set. If you need to use exactly zero value for
  // the timestamp, use 1 millisecond before or after.
  int64 created_timestamp = 3;
}
```

This has been partially approved and discussed in https://github.com/prometheus/prometheus/pull/17036

## Alternatives

### Rename CT to ST

See the [CT vs ST context](#background-ct-cumulative-vs-st-delta), but generally given we get close to OpenTelemetry
semantics, we could rename to "Start Time/Timestamp" (ST) naming in all elements.

Pros:
* Consistency with OpenTelemetry and Google
* There are more future users than previous users, explaining differences between CT and ST.

Cons:
* Technically, one could argue that both CT and ST naming are correct in this context. Prometheus is cumulative-first system, which means
  using CT would make sense.
* We already have CT in scrape protocols and ~Remote Write 2.0; do we need to switch them too?
* Changing names often creates confusion
* Having a slight changed name already makes it clear that we talk about Prometheus semantics of the same thing

**Rejected** due to not enough arguments for renaming (feel free to challenge this!).

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one

* [ ] Task two
