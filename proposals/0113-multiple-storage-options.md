## Supporting Multiple Storage Options in Prometheus

* **Owners:**
  * `<@roidelapluie>`

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [#19080 — Make XOR2 the default Chunk Encoding](https://github.com/prometheus/prometheus/issues/19080): Retain configurable XOR encoding when changing the default to XOR2.
  * [#19188 — Native histograms: explore new chunk format](https://github.com/prometheus/prometheus/issues/19188): Address OTel delta histogram representation and chunk recoding costs.
  * [#12632 — Enable 5 minutes of out-of-order by default](https://github.com/prometheus/prometheus/issues/12632): Consider different storage configuration needs for push-based ingestion.
  * [#5868 — Index files exceeding 64 GiB](https://github.com/prometheus/prometheus/issues/5868): Address cardinality-related index limits blocking Thanos compaction.

* **Other docs or links:**
  * `<Links…>`

> Prometheus aims to provide good performance out of the box across a wide range of workloads.
>
> As Prometheus serves more diverse workloads, including OTLP ingestion, a single storage backend with limited configuration options may not meet every workload's needs.
>
> This proposal aims to support multiple storage backends and more configuration options within the existing TSDB, allowing users to choose the trade-offs that suit their workloads.

## Why

With the introduction of the remote write receiver in 2021, followed by the OTLP receiver in 2023, Prometheus expanded its support for push-based ingestion. We also see workloads with high cardinality. These diverse workloads have different storage requirements, and optimizations that benefit one workload can introduce trade-offs for others.

Other database systems follow this approach. [MariaDB supports multiple storage engines](https://mariadb.com/docs/server/server-usage/storage-engines/storage-engines-storage-engines-overview), including InnoDB for transactional workloads and ColumnStore for analytical workloads. Prometheus could similarly retain a strong default while supporting storage options for different workloads.

### Pitfalls of the current solution

The existing TSDB is evolving with options such as XOR2 and new index formats. However, a single storage model may not suit every workload. This proposal makes support for multiple storage backends explicit, allowing users to choose the backend and configuration that best meet their needs.

## Goals

- Maintain a recommended default that works well for common workloads, and document when users should consider alternative storage options.
- Allow more configuration options within the existing TSDB.
- Support multiple storage backends as alternatives, such as TSDB and a columnar backend.
- Continue supporting existing, proven storage options when new ones are introduced.
- Prefer descriptive names over version numbers, for example “Joint XOR” instead of XOR2 and “Paged Index” instead of Index V4.

## Non-Goals

* Define support for out-of-tree storage backends. Such support may be considered in the future, but is not planned as part of this proposal.
* Require feature parity between all backends or storage formats. For example, XOR encoding does not need to support start timestamps.
* Keep defaults unchanged indefinitely. Defaults can evolve as workloads and storage options change.

## How

This proposal establishes a policy for supporting storage alternatives. It does not prescribe a technical implementation. New backends and configuration options should have clearly identified maintainers, maintenance commitments, and the same code quality standards as the rest of Prometheus.

Configuration options, storage formats, and alternative backends should be evaluated according to their scope. A new backend requires broader consideration of ingestion, querying, operational tooling, and compatibility than an option within the existing TSDB.

New storage options should demonstrate a benefit for an identified workload through reproducible benchmarks or documented functional requirements. Proposals should describe their trade-offs, compatibility and migration implications, testing requirements, and maintenance ownership. The expected benefits should justify the additional maintenance cost.

Existing storage options may be deprecated when their maintenance cost outweighs their benefits. Deprecation proposals should identify affected workloads, document expected performance and feature differences, and provide a migration path. Support for reading existing data should be retained for as long as possible, even after support for writing that format is removed.

## Alternatives

Deprecate existing storage options as new ones are introduced. Deprecation may be appropriate in some cases, but newer options can introduce performance trade-offs. Retaining proven options lets users avoid regressions for their workloads.
