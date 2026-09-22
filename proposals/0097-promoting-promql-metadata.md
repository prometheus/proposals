## Promoting Metric Metadata in PromQL

* **Owners:**
  * Julien Pivotto <@roidelapluie>

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/pull/78
  * https://github.com/prometheus/proposals/pull/94

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

2. Native metadata have a namespace.

Native metadata have namespaces or scopes, such as resource or target.

3. Native metadata are referenced as `namespace[cpu.foo]` or `namespace["super+name"]` (quoting follows the rules for label and metric names).

4. Native metadata can optionally be promoted to labels with the `as` keyword.

`foo{resource[power.status] as power_status}` `foo{namespace["super+name"] as "supername"}`

In the first example, the `power.status` metadata in the `resource` namespace become the `power_status` label, which is used in vector matching, query outputs, etc.

5. Native metadata can be used to filter without promotion.

`foo{resource[power.status]="down"}`

6. Native metadata can be used to filter with promotion.

`foo{resource[power.status]="down" as power.status}`

7. Native metadata can be promoted with `group_right`, `group_left`, and other keywords that take labels.

`foo and on (resource[power.status] as power.status) bar`

In this case, the metadata will be promoted on the left, on the right, or on both sides.

Query results:

Metadata are only visible in query outputs once promoted, in which case they appear as labels.

Advantages: The query output format does not change, so tools that graph or display the results work without modification (provided they do not validate or need to understand the input syntax).

## Alternatives

The main alternative is to use dots, but that contradicts https://github.com/prometheus/proposals/pull/94.

## Action Plan

Tasks required to adopt the proposed approach:

* [ ] Task one `<GH issue>`
* [ ] Task two `<GH issue>` ...
