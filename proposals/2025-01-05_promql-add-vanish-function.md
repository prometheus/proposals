## promql: add vanish function

* **Owners:**
  * Jérôme Loyet @fatpat

* **Implementation Status:** `Not Implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/pull/15783

> This design doc is proposing a new promQL function that detect if a metric has vanished in the time range.

## Why

How to alert when a metric disappears without having to specify a label set ?

A cluster is handling thousands of applications and there are several metrics for each applications.
There's the need to detect if a metric vanishes but there are too many metrics to write an alert
specifically for each unique application while alerts must be aware of the affected application.

### Pitfalls of the current solution

`absent` and `absent_over_time` requires to specify a complete labelset if the labelset is required
in the results. There are many situations where it's not suitable to specify all the possible
labelsets as it would results in a unrealistic number of alerts to be written.

`present_over_time` handles labelsets correctly but only returns a value (1) when there's at least
one value in the range. It can't be used to detect absence simply/directly.

## Goals

* Allow to easily detect when a metric disappears

### Audience

Prometheus users.

## Non-Goals

*N/A*

## How

* add a new `vanish(v range-vector, threshold=5m scalar)`
* make it experimental
* allow to specify a threshold which defaults to the `lookback delta` default value (`5m`)
* add automatic tests

### What open questions are left? (“Known unknowns”)
* does it make sens to specify a threshold ?
* would it make sens to retrieve the configured `lookback delta` value instead of using
  the default or having to specify an optional argument ?

## Alternatives
* `absent` and `absent_over_time` which eats the labels if a complete labelset is not specified
* `count (metric offset 1h != nan) by (labels) unless count(metric) by (labels)`
  * less comprehensible
  * labels have to be specified
  * changing the offset, will either improve precision or duration of the result but both are
    mutually exclusive.
* `count (our_metric offset 1h > 0) by (some_name) unless count(our_metric) by (some_name)`.
  * *same as above*

## Action Plan

* [ ] Merge PR https://github.com/prometheus/prometheus/pull/15783
