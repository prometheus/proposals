## Use start timestamps in `rate`-like functions for delta timeseries support

* **Owners:**
  * @vpranckaitis

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * PR: [PromQL: use start timestamps for rate()-like calculations](https://github.com/prometheus/prometheus/pull/18344)
  * PR: [PromQL: resets() function considers start timestamp resets](https://github.com/prometheus/prometheus/pull/18627)
  * PR: [PromQL: use start timestamps for rate extrapolation](https://github.com/prometheus/prometheus/pull/18619)

* **Other docs or links:**
  * –

> TL;DR: This document describes how start timestamps could be implemented in `rate`-like functions to enable delta timeseries support. Additionally, start timestamps will improve the accuracy of rate calculations for cumulative timeseries.

## Why

The primary motivation for this proposal is the ["OTEL delta temporality support" project](https://github.com/prometheus/proposals/pull/48). This proposal aims to describe and detail the implementation of the ["mini-cumulative" approach](https://github.com/prometheus/proposals/pull/48/changes#diff-a136211c73194731ce3a0cc5faadef9656ba10fa2f710aa2af25d246d2a09821R434-R453) for querying delta counters using `rate`-like functions.

The implementation builds on the Start Timestamp (ST) concept, which is an evolution of the Created Timestamps concept for cumulative counters (see ["Created Timestamp" proposal](0029-created-timestamp.md)). This proposal will also glance into whether some of the problems of the "Created Timestamp" proposal could be addressed (or at least not made worse), even if this is not the primary motivator for this proposal.

### Pitfalls of the current solution

Currently, Prometheus doesn't have first-class support for delta counters. It is possible to ingest them as gauges and query them using the `sum_over_time()` function. However, the preferred way to calculate the rate of a counter in Prometheus is the `rate()` function (and `increase()` for calculating increase), which currently doesn't work for delta counters.

## Goals

* Enable querying rate and increase of delta counters that have valid start timestamps.
* Improve increase detection of low-rate counters.
* The solution should be compatible with recently introduced `anchored` and `smoothed` modifiers.

### Audience

* Users of OTel or other metrics ecosystems who would like to ingest delta counters and query them using the PromQL engine.

## Non-Goals

* Try to fix the cases of invalid or conflicting start timestamps in a query.

## How

For rate calculations, `rate`-like functions consider:
* Whether a counter reset has happened between each pair of successive datapoints. This is needed to calculate the total increase between the first and the last datapoint in the rate window.
* The gaps from the rate window start to the first datapoint in the window, and from the last datapoint in the window to the window end. This is needed for rate extrapolation, and estimates the size of the increase that should have happened at the ends of the rate window.

### Short introduction to start timestamps in OTel

According to [OTel documentation](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality), start timestamps are recommended for Sum, Histogram and ExponentialHistogram datapoints. They describe the start of an interval over which the value is accumulated. For a cumulative temporality timeseries starting at time `t[0]`, you get intervals `(t[0], t[1]]`, `(t[0], t[2]]`, `(t[0], t[3]]` and so on. For delta temporality, the accumulation is reset after every datapoint, so the intervals are `(t[0], t[1]]`, `(t[1], t[2]]`, `(t[2], t[3]]`, etc. In an unbroken sequence, start timestamps always match either the datapoint timestamp or the start timestamp of another datapoint in the sequence. See the picture below for an illustration of this.

![start_timestamps.png](../assets/0077-use-start-timestamp-in-rate-like-functions/start_timestamps.png)

There is also a special case of an unknown start timestamp in a cumulative sequence. It is expressed by setting the start timestamp of the first datapoint in the sequence equal to its datapoint timestamp `(ST[0] = T[0])`. Following datapoints in the same sequence have the start time set equal to the start timestamp of the first datapoint, as in a regular cumulative sequence. Care has to be taken to accurately calculate the rate contribution with such sequences.

Earlier paragraphs have described start timestamps of unbroken sequences. However, things become more complex when a sequence is restarted, which would likely lead to gaps in the timeseries not covered by any datapoints. In real life, misconfigurations might cause multiple sequences to be written into a single timeseries. This could introduce partial overlaps between start time intervals, completely throwing off rate calculations.

### Short introduction to start timestamps in Google Cloud Monitoring

Google Cloud Monitoring has strict guidelines for timeseries datapoint start timestamps and datapoint timestamps. The intervals between these two points are closed [ST, T]. The rules for acceptable values depend on the metric type:

* For gauges, the start timestamp is optional, or, if set, has to be equal to the datapoint timestamp (i.e. ST=T, zero-size interval).
* For delta metrics, start and datapoint timestamps must specify a non-zero interval, and a sequence of datapoints should specify contiguous and non-overlapping intervals, i.e. `ST[0] < T[0] < ST[1] < T[1] < …`.
* For cumulative metrics, start and datapoint timestamps must specify non-zero intervals (`ST < T`). Subsequent datapoints specify the same start timestamp, but increasing datapoint timestamps, i.e. `ST[0] = ST[1] = ST[2] = … < T[0] < T[1] < T[2] < …`. If there is a reset, the new start timestamp must be at least a millisecond after the previous interval end time, i.e. `T[n] < ST[n+1]`.

### OTel vs GCP start time intervals

As described, OTel and GCP start time intervals have some fundamental differences:
* Half-open intervals in OTel, closed intervals in GCP.
* For unbroken streams in OTel, start timestamps match the start or datapoint timestamp of some other datapoint. In GCP, matching start timestamp values are only allowed for unbroken cumulative streams.
* Unknown start timestamp case for cumulative streams in OTel, where ST=T. In GCP, ST=T intervals are only allowed for gauges (for which the start timestamp is optional).

The differences are significant and not cross-compatible from a write perspective – an OTel datapoint stream might require start timestamp adjustment before it can be ingested into Google Cloud Monitoring. However, from a read and query perspective, the start timestamp intervals express the same notion with slight variations in the underlying principles. Thus it should be possible to interpret start timestamps in `rate`-like functions in a way that would work with both OTel and GCP compatible datapoint streams.

The box below displays how start timestamp intervals would look for equivalent timeseries, just expressed as delta or cumulative metrics, in OTel or Google Cloud Monitoring.

```
OTel delta:
  (ST0;  T0]
           (ST1;  T1]
                    (ST2;  T2]
                               ... (ST3;  T3] // new sequence

OTel cumulative:
  (ST0;  T0]
  (ST1; --------- T1]
  (ST2; ------------------ T2]
                               ... (ST3;  T3]  // new sequence

OTel cumulative with an unknown start time:
           (ST0
         T0]
           (ST1;  T1]
           (ST2; --------- T2]
                                            (ST3;  // new or interrupted
                                          T3]      // sequence

GCP delta:
   [ST0; T0]
            [ST1; T1]
                     [ST2; T2]
                               ...  [ST3; T3]  // new sequence

GCP cumulative:
   [ST0; - T0]
   [ST1; -------- T1]
   [ST2; ----------------- T2]
                               ...  [ST3; T3]  // new sequence
```

### Detecting ST counter resets between two successive datapoints

This proposal suggests looking at no more than two successive datapoints at a time for reset detection, and thus processing the datapoints inside the `rate`-like function window pair by pair. To tell whether there was a reset between two datapoints, it is enough to look at the start and datapoint timestamps of those two datapoints.

One might argue that looking at more datapoints might provide more insight into the behavior of the timeseries that is being processed. However, it might also increase the likelihood of inconsistent results between query steps. For example, at some query step the `rate()` function might make a decision by judging in tandem datapoints at `T[1]`, `T[2]` and `T[3]`.
However, the same `rate()` function will only see datapoints `T[1]` and `T[2]` at an earlier step, and only datapoints `T[2]` and `T[3]` at a later step. If this leads to a drastically different decision, the `rate()` function could produce non-uniform results across the steps.

Nevertheless, more than two datapoints could be analyzed for producing info and warning messages about ST values (e.g. if they are invalid, or if there is a collision between two datapoint streams).

The code snippet below shows the general logic needed to detect the counter resets.

NB: the code adopts the idea of transforming OTel unknown timestamp datapoints ST=T into ST=0, T. This idea was proposed in [PROM-60 proposal](https://github.com/prometheus/proposals/pull/60), and it works well with the Prometheus interpretation of ST=0, which means that the timestamp is unknown.

```golang
type datapoint struct {
    ST, T int64
    // ...
}

func detectResetFromStartTimestamp(prev, curr datapoint) bool {
    if prev.ST == curr.ST || curr.ST == 0 || curr.ST >= curr.T {
        // Start time has not changed, is unknown or is invalid.
        return false
    }

    if curr.ST > prev.T {
        // OTel – new cumulative/delta sequence. 
        // GCP – next delta datapoint in sequence, 
        // or new cumulative/delta sequence.
        return true
    }
    if curr.ST < prev.T {
        // OTel and GCP – continuation of cumulative sequence.
        return false
    }

    // If this place is reached, current ST is pointing to 
    // a previous datapoint. Thus this is OTel cumulative or 
    // delta sequence.

    if prev.ST == 0 {
        // Continuation of OTel cumulative stream with 
        // unknown start time.
        return false
    }
    return true
}
```

The following sections will describe in more detail the different cases of start timestamp counter reset detection.

#### Current datapoint with unknown ST

If the current datapoint has an unknown start time (ST = 0), then there's not much we can do other than falling back to counter reset detection from the datapoint value. Note that due to this, unknown start timestamps should not be used for delta counters, since reset detection from values would produce invalid results.

#### Current datapoint has a known ST

For the cases where the current datapoint has a known start timestamp, it has to be considered in relation to the previous datapoint in the stream. If the start timestamp points further away into the past than the previous datapoint (`T[0] < ST[1]`), then we assume that no reset has happened in between the current and previous datapoints. This is a normal situation for cumulative counter streams.

If the start timestamp points into the gap between previous and current datapoints (`T[0] < ST[1] < T[1]`), then we assume that there was a counter reset. This might happen if an old cumulative or delta counter stream (OTel or GCP) has finished and a new one has started after some delay. This is also a normal case for a GCP delta sequence.

The situation where the start timestamp points to the previous datapoint (`T[0] = ST[1]`) is slightly more complicated. This case is indicative of an OTel datapoint sequence, since that is invalid in GCP. This might be a continuation of a delta sequence, or it might be the second datapoint in a cumulative sequence with an unknown start time. For deltas, we should assume a counter reset, while there should be no counter reset in the cumulative sequence case. To discern between these two cases, the previous datapoint has to be checked for an unknown start time (`ST[0] = 0`).

### Rate extrapolation

Rate extrapolation is special logic in the `rate()` and `increase()` functions. It tries to estimate how much a counter has increased before the first datapoint in the rate window, and after the last datapoint in the rate window. A detailed description of how it works can be found in this [blog post by Julius Volz](https://promlabs.com/blog/2021/01/29/how-exactly-does-promql-calculate-rates/).

Start Timestamps could be used to also substitute rate extrapolation at the start of the rate window. If the ST of the first datapoint in the rate window also falls inside the rate window, we may treat that as if there is a datapoint with a value of zero at the ST. See an example in the picture below.

![rate_extrapolation_inside_rate_window.png](../assets/0077-use-start-timestamp-in-rate-like-functions/rate_extrapolation_inside_rate_window.png)

It is important that the first datapoint's ST falls inside the rate window. If it doesn't, we cannot use it instead of rate extrapolation, because the `rate()`/`increase()` function wouldn't have a complete view of the time span between ST and T of the first datapoint in the range. There might be datapoints that fall inside this ST–T span but outside the rate window (see the picture below), and thus it would be incorrect to project a 0 datapoint at ST. In an extreme case, the rate window might be far away from the cumulative series start and thus also far away from the point in time that the ST of the first datapoint in the rate window points to. In such a case it would make little sense to use ST info to influence current rate window results, since it would in essence represent the averaged rate since the start of the counter.

![rate_extrapolation_outside_rate_window.png](../assets/0077-use-start-timestamp-in-rate-like-functions/rate_extrapolation_outside_rate_window.png)

Rate extrapolation also has special logic to limit the extrapolation distance (1.1 extrapolation range) and to avoid extrapolation below zero. Start Timestamps make these irrelevant, because we know that the count was zero at ST, and extrapolating beyond that would lead to values below zero (or at best the extrapolated value would be zero if the counter had no increases). See the picture below for an illustration of these cases. Note that we do have to follow extrapolation-distance and extrapolation-below-zero logic if the first ST falls outside the rate window.

![rate_extrapolation_range.png](../assets/0077-use-start-timestamp-in-rate-like-functions/rate_extrapolation_range.png)

Treating the first ST as zero would also help to get more accurate results for low-rate counters that begin with a non-zero value (see the picture below). Currently, the `rate()` function returns 0 rate in such cases, and it is quite difficult to compose a query that would manage to capture such an increase. This is a big problem for a particular class of use cases (e.g. measuring HTTP error status codes that happen rarely and where it is wasteful to initialize in advance a counter for each possible value).

![rate_extrapolation_uninitialized_counter.png](../assets/0077-use-start-timestamp-in-rate-like-functions/rate_extrapolation_uninitialized_counter.png)

In addition, treating the first ST as zero would allow calculating rate with just a single datapoint inside the rate window (see the picture below). This would be very helpful for querying the rate of a timeseries that consists solely of delta datapoints which are emitted from time to time without a stable cadence. Currently `rate()`-like functions require that the datapoints be emitted at a predictable and reasonably frequent cadence, otherwise it is difficult to choose a rate window size that would cover at least 2 (or better, more) datapoints. With STs one would need to choose a rate window size that would exceed the ST–T span sizes of all (or the majority of) the datapoints.

![rate_extrapolation_single_datapoint.png](../assets/0077-use-start-timestamp-in-rate-like-functions/rate_extrapolation_single_datapoint.png)

However, when calculating rate from a single datapoint, it is impossible to find the average distance between datapoints. So extrapolation to the right cannot be done, because we don't know how far we should extrapolate.

Note that while the first ST could be treated as a zero-value datapoint, it should not be treated as a real datapoint. For example, it should not be included in the calculation of the average duration between successive datapoints. Including it would throw off the results, because depending on how a timeseries is ingested, ST is unlikely to be a whole step size before the initial datapoint in the timeseries.

It is also important to note that the first datapoint of a cumulative counter timeseries is equivalent to a datapoint of a delta timeseries. So ST treatment for rate extrapolation will be exactly the same for cumulative and delta series.

### Extended range selectors: `anchored` and `smoothed` modifiers

Start timestamp support will also have to be implemented for extended range selectors. Unlike the original `rate()` function, extended range selectors take a wider view of the rate window, which allows substituting extrapolation to the edges of the range window for interpolation at the edges of the window. So the handling of the start timestamps has to differ for the successive datapoints that cross the range window's edges. On the other hand, the handling is exactly the same for successive datapoints that fall fully inside the range window.

This section looks into different configurations of datapoints, their start timestamps and range window edges in relation to each other. It also describes how datapoints should be projected or interpolated in such cases.

The first case to consider is when there are two datapoints surrounding the range window's edge, but there is no ST reset between them (see the picture below). This might be because ST is unset (equal to 0), or because the ST points beyond the previous datapoint (as depicted in the picture below). In this case, we do not use ST for interpolation/projection and fall back to the reset detection from counter values.

![extended_selectors_st_before_prev_datapoint.png](../assets/0077-use-start-timestamp-in-rate-like-functions/extended_selectors_st_before_prev_datapoint.png)

However, a different treatment is needed when there is an ST reset between the datapoints surrounding the edge of the range window (see the picture below). If ST crosses the edge of the window, we then use it for interpolating the datapoints at the edge. For the `anchored` case, we simply project a 0 datapoint at the timestamp of the rate window's edge (the yellow circle in the picture below). For the `smoothed` case, we interpolate a point along the line between the points `(ST, 0)` and `(T, <datapoint_value>)` (the blue circle in the picture below). It is important to note that for the right edge of the rate window, the interpolated point might be above or below the previous datapoint. However, in both of these cases we should apply reset logic, since according to ST there was a reset between the last datapoint in the rate window and the right edge of the window.

![extended_selector_st_crosses_windows_edge.png](../assets/0077-use-start-timestamp-in-rate-like-functions/extended_selector_st_crosses_windows_edge.png)

There's a special case for OTel timeseries, where ST points to the timestamp of the previous datapoint (see the picture below). We then have to check whether it's an unknown start time. If it's unknown, there is no ST reset, and we fall back to the reset detection from counter values as described earlier. However, if the start time is known, we use the ST–T line to interpolate as described in the previous paragraph (as depicted in the picture below).

![extended_selector_st_at_prev_datapoint.png](../assets/0077-use-start-timestamp-in-rate-like-functions/extended_selector_st_at_prev_datapoint.png)

One more case to consider is where the datapoints that surround the range window's edge have an ST reset between them, but the ST doesn't cross the window's edge (see the picture below). In this case, we would not use the ST–T line for interpolation. However, we do have to take into account that there's a reset when interpolating the datapoints at the edge of the window, and also we have to consider this reset when taking into account counter resets inside the rate window. For example, in the picture below, for the `anchored` case with the yellow circle, we have to detect an ST counter reset after it, which cannot be detected just by looking at the datapoint values. This means that we have to check whether ST points before or after the interpolated point.

![extended_selector_st_doesnt_cross_windows_edge.png](../assets/0077-use-start-timestamp-in-rate-like-functions/extended_selector_st_doesnt_cross_windows_edge.png)

There are also special cases related to sparse datapoints. When there are datapoints inside the range window, but there are no datapoints to the left of the window, we still have to check the ST location. If it falls inside the window (see the picture below, diagram on the left), we have to make sure that we set the value of the interpolated/projected datapoint to 0 (instead of using the value of the first datapoint in the window, which would happen if ST was not set).

![extended_selector_st_other_cases.png](../assets/0077-use-start-timestamp-in-rate-like-functions/extended_selector_st_other_cases.png)

Another interesting case is when there are no datapoints inside or to the left of the window, but there's a datapoint to the right of the window that has an ST (see the picture above, diagram on the right). Even in this case we could calculate a rate if the ST–T line crosses one or both of the window edges (as long as the ST doesn't go too far to the left, beyond the lookback of the extended range).

### Performance impact

For the proposed functionality to work, the PromQL engine will have to read and propagate start timestamp values. These values could be placed in `FPoint` and `HPoint` structs, so that they could be carried together with the sample timestamp and value. However, this would increase memory usage, even in situations where start timestamp support in PromQL is disabled, or when the PromQL functions used in the query don't use start timestamps. Thus, an alternative approach is chosen, where start timestamp values are kept in a separate array. This allows the array to be kept empty when start timestamps are not used, thus avoiding unnecessary memory consumption.

Regarding CPU usage impact, start timestamp reset detection consists of several comparisons of `int64` values. While this is extra work, the calculations are fairly simple and should not add too much to CPU usage. In some cases it might even be an efficiency gain, because it could potentially substitute histogram reset detection, which is quite expensive for bigger histograms.

## Alternatives

The ["OTEL delta temporality support"](https://github.com/prometheus/proposals/pull/48/changes#diff-a136211c73194731ce3a0cc5faadef9656ba10fa2f710aa2af25d246d2a09821) proposal mentions a few alternative approaches for querying delta counters, which were not selected due to technical or other reasons.

## Action Plan

* [X] Implement start timestamp support in `rate`-like functions for detecting resets between datapoints [PR #18344](https://github.com/prometheus/prometheus/pull/18344)
* [X] Use start timestamp as an alternative for rate extrapolation [PR #18619](https://github.com/prometheus/prometheus/pull/18619)
* [X] Implement start timestamp support in `resets()` function [PR #18627](https://github.com/prometheus/prometheus/pull/18627)
* [ ] Implement start timestamp support for extended rate [PR #18966](https://github.com/prometheus/prometheus/pull/18966)
