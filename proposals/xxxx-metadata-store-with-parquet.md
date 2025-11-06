## Metadata store with parquet

* **Owners:**
  * Jesús Vázquez [@jesusvazquez](https://github.com/jesusvazquez)
  * György Krajcsovits [@krajorama](https://github.com/krajorama)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/12608
  * https://github.com/prometheus/prometheus/issues/15911

* **Other docs or links:**
  * Design doc [Prometheus Metadata Store](https://docs.google.com/document/d/1epBslSSwRO2do4armx40fruStJy_PS6thROnPeDifz8/edit?tab=t.0#heading=h.5sybau7waq2q)
  * Memo [OTel resource attributes from the Prometheus perspective](https://docs.google.com/document/d/17q0H2tHGOC19VsvfqyQ8EMnqMWzZgfRQ4VfHHwL8cj8/edit?tab=t.0#heading=h.hitoxg2o4qh1)

Propose an experimental feature to persist metadata in parquet and make it available seamlessly.

## Why

There has been much discussion about storing metadata in Prometheus, there's even a [design doc](https://docs.google.com/document/d/1epBslSSwRO2do4armx40fruStJy_PS6thROnPeDifz8/edit?tab=t.0#heading=h.4hkvvmp3q5yk). However no consensus has been reached so far. We'd like to do a POC for "Proposal 3: External metadata store", specifically with parquet as storage format.


### Pitfalls of the current solution

The unit, type and help metadata as defined by Prometheus/OpenMetrics is not persisted in Prometheus. Only the latest scraped data is kept in memory as part of the scrape cache. This is not useful for looking back in time. (Unit and type labels solve this for unit and type, but not for help.) Also we cannot support queries on metadata if the data comes in through Remote-Write or OTLP.

Remote-write 2.0 currently has no easy way to get the metadata for sending along with every remote-write request. (The metadata as WAL records feature didn't work out, it's being [deprecated](https://github.com/prometheus/prometheus/issues/15911). Unit and type labels solve this for unit and type, but not for help.)

Querying OTLP resource attributes and/or target info attributes together with regular metrics has always been a pain point for PromQL. (The `info` function helps with this, but the solution is still not seamless.)

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Define metadata as data that is
  * MUST does not change during the lifetime of an application process (i.e. pod).
  * SHOULD BE descriptive, not identifying for time series,
* When a user queries a metric, the associated metadata shall be returned in labels by default (unless the query drops labels).
* User can filter, query based on metadata.
* Add as opt-in feature flag first.
* Remote-write 2.0 to be able to tap into the metadata for sending help efficiently.

The above definition means that the following would be considered metadata:
* metric help,
* metric type, (identifying)
* metric unit, (identifying)
* software version,
* TBD.

### Audience

Prometheus end-users.

## Non-Goals

* Storing start timestamp (formerly known as created timestamp)

## How

### Data layout

* We need a key-value store that maps labels-hash -> labels, series ref, metadata.
* Where metadata contains all the metadata for the time range of the (head) block.
* In parquet this would mean the columns: hash, labels, series ref, metadata.

### Series to metadata lookup

* Calculate the hash for the series labels. Look up in the hash column. If multiple matches, also check the related labels.

### Metadata to series

* 

## Alternatives

The section stating potential alternatives. Highlight the objections reader should have towards your proposal as they read it. Tell them why you still think you should take this path [[ref](https://twitter.com/whereistanya/status/1353853753439490049)]

1. This is why not solution Z...

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one `<GH issue>`
* [ ] Task two `<GH issue>` ...
