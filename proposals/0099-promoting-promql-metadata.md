## Promoting Metric Metadata in PromQL

* **Owners:**
  * Julien Pivotto <@roidelapluie>

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/pull/78
  * https://github.com/prometheus/proposals/pull/94
  * https://github.com/prometheus/proposals/pull/97

* **Other docs or links:**
  * `<Links…>`

> TL;DR: Native metadata are coming to Prometheus, but we need a way to query them that does not conflict with allowing unquoted dots and Unicode letters in metric and label names.
>
> This design document proposes mechanisms and keywords to query and promote such metadata.

## Why

We know that Prometheus will need a metadata database to attach resource or target metadata to metrics. The acquisition, storage, and definition of metadata are outside the scope of this proposal.

However, these metadata will need to be returned to users and used in PromQL queries. This proposal defines the syntax and mechanisms that can be used in the future.

### Pitfalls of the current solution

Currently, we have no way to store or query metadata. Prometheus drops many "target labels" during target relabeling. If stored, these labels could be queried by users to gain more insight into their data.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Provide a non-conflicting way to query native metadata.
* Provide syntax that feels familiar to PromQL users.
* Be agnostic to the kind (namespace?) of metadata.

### Audience

PromQL users and OTLP users who push data to Prometheus.

## Non-Goals

* Native metadata retrieval, reception, and storage.

## How

Querying:

1. Native metadata are ignored by default.

Existing PromQL queries do not return native metadata unless they are explicitly promoted. Vector matching does not use metadata by default.

2. Native metadata are opaque, like label names.

In PromQL, native metadata are typed key-value pairs. Any hierarchy that might exist in the backend is split by dots.

3. Native metadata are referenced as `namespace[cpu.foo]` or `namespace["super+name"]` (quoting follows the rules for label and metric names).

4. Native metadata can be used to filter metrics when prefixed with `~`, in which case they are promoted as labels.

`foo{~resource.power.status="down"}`

Example output: `foo{host="bar",resource.power.status="down"}`

`foo{~resource.power.status=~"down|stopped"}`

5. Native metadata can be used to filter metrics without being promoted as labels when prefixed with `~~`.

`foo{~~resource.power.status="down"}`

`foo{~~resource[power.status]=~"down|stopped"}`

6. Native metadata can be aliased with the `as` keyword.

`foo and on (~resource.power.status as power_status) bar`

In this case, the metadata will be promoted on the left, on the right, or on both sides.

Query results:

Metadata are only visible in query outputs once promoted, in which case they appear as labels.

Advantages: The query output format does not change, so tools that graph or display the results work without modification (provided they do not validate or need to understand the input syntax).

## Alternatives

The main alternative is to use dots, but that contradicts https://github.com/prometheus/proposals/pull/94.
The second alternative is to use square brackets: https://github.com/prometheus/proposals/pull/97.

## Action Plan

This task depends on native metadata acquisition and storage.
