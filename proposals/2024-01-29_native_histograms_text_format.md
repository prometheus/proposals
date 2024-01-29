## Native Histograms Text Format

* **Owners:**
  * Chris Marchbanks [@csmarchbanks](https://github.com/csmarchbanks)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * `<GH Issues/PRs>`

* **Other docs or links:**
  * [Design Doc for choosing a proposal](https://docs.google.com/document/d/1qoHf24cKMpa1QHskIjgzyf3oFhIPvacyJj8Tbe6fIrY/edit#heading=h.5sybau7waq2q)

> TL;DR: This design doc is proposing a format for exposing native histograms in the OpenMetrics text format.

## Why

Today it is only possible to export native histograms using the protobuf scrape format. Many users prefer the text format, and some client libraries, such as the Python client, want to avoid adding a dependency on protobuf. 

During a [dev summit in 2022](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit#bookmark=id.c3e7ur6rn5d2) there was consensus we would continue to support the text format. Including native histograms as part of the text format shows commitment to that consensus.

See the linked design doc in Google Docs for additional background information.

### Pitfalls of the current solution

Prometheus client libraries such as Python do not want to require a dependency on protobuf in order to expose native histograms, and in some languages protobuf is painful to use. Gating native histograms only to clients/users willing to use protobuf hurts adoption of native histograms, therefore, we would like a way to represent a histogram in the text based format.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Support native histograms in the text format
* (Secondary) Encode/decode efficiency
* (Secondary) Ease of implementation for client libraries
* (Secondary) Human readibility of the format

Note that the goals of efficiency and human readability are commonly at odds with each other.

### Audience

Client library maintainers, OpenMetrics, and Prometheus scrape maintainers.

## Non-Goals

* Requiring backwards compatability (OpenMetrics 2.0 would be ok)

## How

To be filled out after one of the proposals in the linked design doc has support.

## Alternatives

To be filled out after one of the proposals in the linked design doc has support.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Task one <GH issue>
* [ ] Task two <GH issue> ...
