## Multiple exemplars per sample

* **Owners:**
  * György (krajo) Krajcsovits [@krajorama](https://github.com/krajorama/) [gyorgy.krajcsovits@grafana.com](mailto:gyorgy.krajcsovits@grafana.com)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * Prometheus [Support for ingesting out of order exemplars](https://github.com/prometheus/prometheus/issues/13577)
  * Prometheus [WIP: tsdb: Add support for out-of-order exemplars](https://github.com/prometheus/prometheus/pull/13580)
  * Prometheus client model [How to add exemplars to pure Native Histograms](https://github.com/prometheus/client_model/issues/61)
  * Prometheus client golang [histograms: Support exemplars in pure Native Histograms](https://github.com/prometheus/client_golang/issues/1126)
  * Prometheus client golang [add native histogram exemplar support](https://github.com/prometheus/client_golang/pull/1471)
  * Prometheus [scrape: Enable ingestion of multiple exemplars per sample](https://github.com/prometheus/prometheus/pull/12557)
  * Prometheus [Native histograms: error on ingesting out-of-order exemplars](https://github.com/prometheus/prometheus/issues/12971)
  * Prometheus [Fix error on ingesting out-of-order exemplars](https://github.com/prometheus/prometheus/pull/13021)
  * Prometheus [Prometheus support parse exemplars from native histogram](https://github.com/prometheus/prometheus/pull/13488)
  * OTEL proto [Base-2 exponential histogram protocol support](https://github.com/open-telemetry/opentelemetry-proto/pull/322)

* **Other docs or links:**
  * [OTEL histogram](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#histogram)
  * [OTEL exemplars](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars)

> This proposal collects the requirements and implementation proposals for supporting multiple exemplars per sample, in particular for native histograms.

## Why

Currently the remote write protocol (1.0 and 2.0) processes exemplars individually, which means that if a native histogram has multiple exemplars, they may arrive in separate remote write requests, making it hard to decide if the exemplar is out of order it belonged to a previous set of exemplars and should be considered a duplicate.

Currently there is no mapping of the "set of exemplars" per sample concept that is in Open Telemetry specification.

### Pitfalls of the current solution

In the current solution we have a circular buffer for all exemplars. The exemplars are organized into two lists. One list links all exemplars from oldest received to newest so that we can make space when maximum number of exemplars is hit on insert. The other link
is per time series, linking exemplars from oldest to newest. Also there is a pointer to the latest exemplar per time series to be able to check for duplicates, out of order.

For availability purposes, exemplars are written to the WAL and are loaded on restart.

Currently when a new exemplar is inserted, it is only compared to the latest exemplar for the time series in question.

This has a couple of issues:

* There is no interface to pass multiple exemplars to head.AppendExemplar, so multiple calls need to be made, increasing the call count and lock contention.
* If a native histogram has 10 exemplars per scrape/sample and all are received in the same remote write request, we currently try appending all in a loop. We consider them out of order if all are out of order, but if there's a duplicate of the last stored exemplar or some are newer than the last stored exemplar, then we just ignore the old exemplars.
* However the logic above fails if exemplars are received in multiple remote write requests, so the logic is a workaround at best.
* Also for the above logic to work, the exemplars must be ordered by timestamp, however not all clients, especially OTEL follow this, so the implementation needs to also sort the exemplars before applying them.

If the current proposal for out of order support [Support for ingesting out of order exemplars](https://github.com/prometheus/prometheus/issues/13577) is implemented, the problems above go away, however it would mean executing a linear search for each of the 10 exemplars, which would probably have a huge overhead.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Solve the issue of exemplars being split across remote write messages.
* Solve the efficiency issue.

### Audience

Prometheus maintainers.

## Non-Goals

N/A

## How

Explain the full overview of the proposed solution. Some guidelines:

* Make it concise and **simple**; put diagrams; be concrete, avoid using “really”, “amazing” and “great” (:
* How you will test and verify?
* How you will migrate users, without downtime. How we solve incompatibilities?
* What open questions are left? (“Known unknowns”)

## Alternatives

The section stating potential alternatives. Highlight the objections reader should have towards your proposal as they read it. Tell them why you still think you should take this path [[ref](https://twitter.com/whereistanya/status/1353853753439490049)]

1. This is why not solution Z...

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
