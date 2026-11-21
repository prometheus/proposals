## Horizontally scalable Prometheus in Rust

* **Owners:**
  * Bartek Plotka [@bwplotka](https://github.com/bwplotka)
  * Matthias Loibl [@metalmatze](https://github.com/metalmatze)
  * Saswata Mukherjee [@saswatamcode](https://github.com/saswatamcode)
  * Alan Protasio [@alanprot](https://github.com/alanprot)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [PROM-115: Establish Prometheus Special Interest Groups](https://github.com/prometheus/proposals/pull/115)
  * [PROM-113: Supporting Multiple Storage Options in Prometheus](https://github.com/prometheus/proposals/pull/113)
  * [PROM-95: Standardize Prometheus GitHub teams and repository access](https://github.com/prometheus/proposals/blob/main/proposals/0095-teams-and-org-permissions.md)
  * [prometheus/prometheus#5868: Index files exceeding 64 GiB](https://github.com/prometheus/prometheus/issues/5868)

* **Other docs or links:**
  * [Prometheus.rs SIG goals and meeting notes](https://docs.google.com/document/d/1uZjrWeAfRaN6fIp4L7pd-lMqc650bClJeg7jGO3gerE/edit)
  * [Thanos 2.0 architecture draft](https://docs.google.com/document/d/1fn8JdEiHe0UBF4MPCVE41GHMtAkQ8n_3T8ovIadfX1A/edit)
  * [Prometheus.rs architecture draft](https://docs.google.com/document/d/1NB5qyEthztPjp2in8AeDq_l8PoYxsAa1QhImanJDQHM/edit)
  * [Prometheus Governance](https://github.com/prometheus/governance/blob/main/GOVERNANCE.md)
  * [Prometheus Community Roles](https://github.com/prometheus/governance/blob/main/ROLES.md)

> TL;DR: Bring horizontally scalable, distributed Prometheus into the Prometheus organization alongside single-node Prometheus. Contributors from Prometheus, Thanos, Cortex, and (potentially) Mimir are rebuilding the next generation of metrics storage and querying from scratch in Rust on an Apache Arrow columnar stack. Rather than splitting that work across competing organizations or inventing a fourth project, we propose building it under the Prometheus umbrella, coordinated by the Prometheus.rs SIG, with explicit structural safeguards that keep single-node monolith Prometheus a first-class priority. Depending on maintainer feedback, this work can live directly in the new Rust Prometheus repository as composable modes or in a separate repository under the `prometheus` organization.

## Why

The core (CNCF related) horizontally scalable Prometheus ecosystem has been split across three projects, Thanos, Cortex, and Mimir, for years. Each project maintained its own ingestion pipeline, object-storage integration, compactor, and query scaling layer on top of Go Prometheus TSDB. As cardinality and ingestion volume grew, the memory and CPU cost of the mutable TSDB head pushed companies like Cloudflare, Shopify, AWS, Red Hat, Grafana, and Dash0 toward internal Rust and columnar prototypes using Apache Arrow, Vortex, and Apache DataFusion. At the same time, upstream OSS maintenance on Go Cortex and Thanos projects slowed down.

Because we are rebuilding the stack from scratch, as outlined in the [Thanos 2.0](https://docs.google.com/document/d/1fn8JdEiHe0UBF4MPCVE41GHMtAkQ8n_3T8ovIadfX1A/edit) and [Prometheus.rs](https://docs.google.com/document/d/1NB5qyEthztPjp2in8AeDq_l8PoYxsAa1QhImanJDQHM/edit) drafts, we have a rare chance to reunite the community in one vendor-neutral home. On November 19, 2026, the [Prometheus.rs SIG](https://docs.google.com/document/d/1uZjrWeAfRaN6fIp4L7pd-lMqc650bClJeg7jGO3gerE/edit?tab=t.ok8vuqesxwve#heading=h.ht6fktvkrxsh) discussed where this combined effort should live. We compared reusing the Thanos organization, creating a brand-new organization such as CorThanos or CorThaMir, and bringing the scope under Prometheus itself. The group agreed that Prometheus, with its refreshed governance, elected Steering Committee, and new energy, is the best neutral home.

Historically, Prometheus maintainers resisted bringing Thanos or Cortex style requirements into Prometheus. That resistance made sense. Single-node Prometheus works so well because it is **an autonomous binary with local TSDB and zero external storage dependencies. You can trust it to fire alerts when everything else is broken**. Maintainers worried that distributed microservices and extreme-scale requirements would bloat the monolith and pull focus away from single-node users, especially since roughly 90% of maintainers work at companies that care more about multi-cluster distributed Prometheus than single-node servers.

That risk is real and we should not wave it away. Prometheus is still a single-binary effort first, and if the interests of single-node Prometheus and horizontally scalable Prometheus ever conflict, single-node Prometheus comes first. At the same time, the past decade has shown how costly ecosystem fragmentation is across separate projects. Four things have changed since that original scope boundary was formed:

1. We can protect monolith priority with structure instead of an informal scope ban. Refreshed Prometheus governance gives us explicit SIG charters in [PROM-115](https://github.com/prometheus/proposals/pull/115), per-repository maintainer teams in [PROM-95](https://github.com/prometheus/proposals/blob/main/proposals/0095-teams-and-org-permissions.md), and clear contributor roles in [ROLES.md](https://github.com/prometheus/governance/blob/main/ROLES.md). We can back those up with hard benchmark gates, clean crate boundaries, and dedicated monolith maintainers.
2. The `github.com/prometheus` organization stopped being only the monolith server binary a long time ago. Today the organization maintains client SDKs in six languages, exporters, Alertmanager, `promtool`, `--agent` mode, [prometheus/prometheus-mcp](https://github.com/prometheus/prometheus-mcp), protocol specifications, and experimental Rust projects in [prometheus/scrape.rs](https://github.com/prometheus/scrape.rs) and [prometheus/prometheus.rs](https://github.com/prometheus/prometheus.rs).
3. `prometheus/prometheus` already absorbs complexity for downstream horizontally scalable backends. The codebase carries methods and options that exist solely for Mimir, Cortex, or Thanos, such as [`DB.CompactSelectedSeries`](https://github.com/prometheus/prometheus/blob/2b311b9762bb5834a17374fcf45a8e5b2043293f/tsdb/db.go#L1940-L1963), [`LeveledCompactorOptions.EnableOverlappingCompaction`](https://github.com/prometheus/prometheus/blob/2b311b9762bb5834a17374fcf45a8e5b2043293f/tsdb/compact.go#L183-L185), [`AppendOptions.MetricFamilyName`](https://github.com/prometheus/prometheus/blob/2b311b9762bb5834a17374fcf45a8e5b2043293f/storage/interface_append.go#L51-L60), and the [`--storage.tsdb.delay-compact-file.path`](https://github.com/prometheus/prometheus/blob/2b311b9762bb5834a17374fcf45a8e5b2043293f/cmd/prometheus/main.go#L575-L576) flag. It also tracks scale limits above 100M series like the 64 GiB index cap in [#5868](https://github.com/prometheus/prometheus/issues/5868), and [`AGENTS.md`](https://github.com/prometheus/prometheus/blob/2b311b9762bb5834a17374fcf45a8e5b2043293f/AGENTS.md#L94-L99) explicitly instructs contributors to check Cortex, Thanos, and Mimir before changing exported Go APIs. We already pay the maintenance tax for distributed backends downstream without getting a shared architecture in return.
4. In the AI era, reusable crates with clear boundaries matter more than glue code. Teams and coding agents can wire up custom binaries or integrations cheaply now, while well-scoped libraries with strict interfaces and thorough tests remain the hard part. Clear crate boundaries also give humans and coding agents small, isolated units to change and review safely. Focusing the [prometheus/prometheus.rs](https://github.com/prometheus/prometheus.rs) monorepo on reusable crates lets monolith and distributed modes share those core libraries without tangling their concerns.

### Pitfalls of the current solution

* Fragmented governance across Thanos, Cortex, and Mimir splits engineering effort across three overlapping codebases and nudges large operators toward closed-source Rust forks.
* Downstream horizontally scalable storage and querying requirements still leak into `prometheus/prometheus` as special-case flags and unused library methods instead of clean shared components.
* Shared Rust building blocks such as [prometheus/scrape.rs](https://github.com/prometheus/scrape.rs) and [prometheus-community/promql-rs](https://github.com/prometheus-community/promql-rs) already live under Prometheus organizations, so putting distributed Prometheus components under a different governance body splits one contributor community across two orgs.

## Goals

* Officially bring horizontally scalable, distributed Prometheus into the scope of the Prometheus organization.
* Give contributors from Prometheus, Thanos, Cortex, and Mimir one vendor-neutral home to build the next-generation Rust and columnar metrics stack together.
* Put concrete organizational and technical safeguards in place so single-node monolith Prometheus remains a first-class priority.
* Set a clear repository and SIG structure focused on reusable crates with clear boundaries so teams can adopt components incrementally without an upfront rewrite of Go Prometheus.

### Audience

Prometheus maintainers, Steering Committee members, Prometheus Members, and contributors or operators from the Prometheus, Thanos, Cortex, and Mimir communities.

## Non-Goals

* Turning Go `prometheus/prometheus` into a distributed microservice system. Go Prometheus remains a single-node server and agent.
* Deprecating or replacing Go `prometheus/prometheus` in any form. If we do this it will be a separate discussion.
* Finalizing technical architecture choices such as Vortex versus Parquet, Kafka versus object-storage WAL, or Iceberg versus DuckLake. Those decisions belong in component design docs and prototypes inside the SIG.
* Making unilateral trademark or CNCF project-boundary changes without coordinating with the Steering Committee, Thanos and Cortex maintainers, and CNCF.

## How

### Scope expansion

This proposal updates the scope of the Prometheus project under [prometheus/governance](https://github.com/prometheus/governance) to include horizontally scalable, distributed Prometheus as an official area of work, alongside single-node Prometheus, agent mode, Alertmanager, exporters, SDKs, and specifications.

Go `prometheus/prometheus` does not change its scope. New horizontally scalable work targets the experimental Rust and columnar ecosystem being developed in the Prometheus.rs SIG.

### Governance and repository structure

The work operates under existing Prometheus governance rules in [GOVERNANCE.md](https://github.com/prometheus/governance/blob/main/GOVERNANCE.md) and [ROLES.md](https://github.com/prometheus/governance/blob/main/ROLES.md):

* Once [PROM-115](https://github.com/prometheus/proposals/pull/115) is accepted, the Prometheus.rs SIG submits a formal SIG charter under `prometheus/governance/sigs/` covering shared Rust crates, the Rust monolith effort, and distributed components, with at least two SIG leads and a Steering Committee liaison.
* Reusable Rust crates with clear boundaries are the primary focus of the [prometheus/prometheus.rs](https://github.com/prometheus/prometheus.rs) monorepo, alongside existing crates like [prometheus/scrape.rs](https://github.com/prometheus/scrape.rs) and [prometheus-community/promql-rs](https://github.com/prometheus-community/promql-rs). Keeping crates small and well-scoped across areas like columnar storage and rule evaluation makes them easier for both humans and coding agents to maintain, and lets teams adopt individual components like a Rust querier or compactor before migrating an entire stack.
* Each repository follows [PROM-95](https://github.com/prometheus/proposals/blob/main/proposals/0095-teams-and-org-permissions.md) with its own `MAINTAINERS.md` and dedicated GitHub maintainer team.
* New distributed components start clearly labeled as `[EXPERIMENTAL]` and graduate to stable status only after meeting conformance tests, operational benchmarks, and multi-company maintainership requirements.

For repository and binary placement, we ask maintainers to weigh in on two options during review of this proposal:

1. Preferred option: bring horizontally scalable Prometheus directly into the [prometheus/prometheus.rs](https://github.com/prometheus/prometheus.rs) monorepo. The workspace keeps core functionality in independent, reusable crates and composes them into a single-node monolith default plus opt-in distributed component modes such as ingester, querier, compactor, ruler, and catalog. This avoids inventing a new brand name, keeps cross-crate changes coordinated during early prototyping, and lets users scale from one binary to distributed components using one mental model.
2. Fallback option, detailed in Alternative 1 below: host horizontally scalable Prometheus in a separate repository and binary under the Prometheus organization, incubating in `prometheus-community` first if preferred, while sharing the same Rust crates and SIG.

```mermaid
flowchart TB
    SC["Prometheus Steering Committee\nGOVERNANCE.md, 2-seat employer cap"] --> SIG["Prometheus.rs SIG\nPROM-115 charter"]
    SIG --> Crates["Shared Rust crates\nscrape.rs, promql-rs, columnar storage, rules"]
    Crates --> Monolith["Monolith & Agent mode\nDedicated monolith maintainers\nStrict footprint & latency CI gates"]
    Crates --> Dist["Horizontally scalable components\nIngester, querier, compactor, catalog\nDedicated distributed maintainers"]
```

### Safeguarding monolith priority

Accepting horizontally scalable Prometheus into the Prometheus organization must not come at the expense of single-node Prometheus users. Whenever the interests of single-node Prometheus and horizontally scalable Prometheus conflict, single-node Prometheus comes first. We back that rule up with four concrete guardrails from day one:

* Monolith remains the default UX. Running the binary without distributed flags starts a self-contained single-node server using local storage, zero external coordination services, and standard Prometheus configuration. Multi-tenancy, object storage, and distributed routing stay strictly opt-in.
* Dependency direction is one-way. Core crates for scraping, PromQL, rule evaluation, and local storage cannot depend on distributed coordination, multi-tenant auth, or cloud object-store SDKs. Distributed layers depend downward on core crates, never the reverse.
* Continuous benchmark gates enforce monolith budgets. CI tracks single-node RSS, CPU, query latency, cold-start time, and binary size on realistic small and medium workloads alongside 100M-series tests. Changes that improve distributed components while regressing monolith footprint or startup simplicity do not merge.
* Separate maintainership protects priorities. Monolith core and distributed components have distinct maintainer rosters or `CODEOWNERS` areas. Monolith maintainers hold approval authority over default behavior, single-node flags, and shared crate interfaces. At the organization level, the Steering Committee's 2-seat-per-employer limit in [GOVERNANCE.md](https://github.com/prometheus/governance/blob/main/GOVERNANCE.md#limitations-on-company-representation) prevents any single vendor from capturing project direction.

### What this means for the ecosystem

Go `prometheus/prometheus` keeps its current focus and release cadence. Nothing in this proposal forces existing Prometheus users to adopt Rust, columnar storage, or distributed components, and Go `prometheus/prometheus` will not take on clustering features.

For Thanos and Cortex, it is up to the maintainers. However, our proposal would be to officially deprecate them with a 1y runway for active maintenance or longer if distributed Prometheus takes more time to reach feature parity. After that period, the Thanos and Cortex CNCF organizations will be officially moved to Prometheus or closed.

For maintainers and heavy users of those systems, Prometheus becomes a shared neutral place to build the next-generation Rust and columnar components together instead of duplicating work across three Go repos or private forks. Because the new stack is modular, existing Thanos and Cortex deployments can adopt pieces incrementally, for example placing a Rust PromQL querier or columnar compactor alongside existing components, so the migration process for that 1y+ deprecation period can be adjusted.

Operators get a single query engine, shared columnar storage formats, and one governance model from a single node up to a multi-cluster deployment, while small deployments keep running one binary.

Contributors across monolith and distributed Prometheus advance on the same [Prometheus contributor ladder](https://github.com/prometheus/governance/blob/main/ROLES.md) and receive CNCF DevStats credit under one umbrella. That lowers the barrier for engineers working on large-scale storage to contribute back to core Prometheus crates, and vice versa.

## Alternatives

### 1. Separate repository and binary under the Prometheus organization

Bring horizontally scalable Prometheus into the Prometheus organization and the Prometheus.rs SIG, sharing the same Rust crates, but place the distributed binary in its own repository under `github.com/prometheus` or incubating in `github.com/prometheus-community`, similar to how Alertmanager lives in `prometheus/alertmanager`.

This creates the cleanest boundary on binary size, CLI flags, release cadence, and issue trackers, with zero risk of distributed issues crowding the core Prometheus repository. The trade-off is that we must choose and build recognition around a new name, coordinate breaking crate changes across more repositories during early prototyping, and give up a single-binary path that transitions cleanly from monolith to microservices. If maintainers feel strongly that monolith and distributed modes should not share `prometheus/prometheus.rs`, this alternative is a direct fallback that still achieves the core goal of this proposal.

### 2. Build under the Thanos organization as Thanos 2.0

Keep horizontally scalable Prometheus out of the Prometheus organization and host the new Rust and columnar backend under `github.com/thanos-io`, which is already a CNCF Incubating project dedicated to horizontally scalable Prometheus.

Reusing Thanos avoids expanding Prometheus scope and builds on an established brand. However, it makes unifying Cortex and Mimir contributors harder under one predecessor's name and governance. Thanos OSS maintenance has also slowed down, while Prometheus now has an active Steering Committee and the Prometheus.rs SIG already building shared Rust crates. Putting the distributed layer under `thanos-io` would split contributors working on `prometheus/scrape.rs`, `promql-rs`, and the distributed backend across two separate CNCF governance bodies.

### 3. Create a new organization such as CorThanos or CorThaMir

Start a fresh GitHub organization and pursue a new CNCF Sandbox project for the combined next-generation distributed system.

A new organization starts with zero historical baggage from Prometheus, Thanos, Cortex, or Mimir. In practice, standing up new governance, security processes, CNCF onboarding, CI infrastructure, and brand trust takes months of non-engineering work and splits contributor credit away from Prometheus. Without strong institutional backing, a fresh org risks becoming a fourth fragmented project rather than uniting the existing three.

### 4. Keep horizontally scalable Prometheus out of scope

Maintain the status quo: keep Prometheus strictly focused on single-node server, agent, and shared libraries, and leave horizontal scalability to downstream projects.

This avoids any scope change and preserves the simple historical boundary that Prometheus does not do distributed storage. The downside is that the status quo is already failing to keep the community together. Companies are writing closed-source Rust and Arrow backends independently, Go Thanos maintenance has slowed, and `prometheus/prometheus` still absorbs downstream hooks for distributed backends like `CompactSelectedSeries` and `EnableOverlappingCompaction` without getting a cohesive architecture in return.

## Action Plan

* [ ] Reach consensus on this proposal in `prometheus/proposals`, including agreement on single-repo modes in `prometheus/prometheus.rs` versus a separate repository under the Prometheus organization.
* [ ] Hold a Steering Committee vote under [GOVERNANCE.md](https://github.com/prometheus/governance/blob/main/GOVERNANCE.md#decision-process) to formally include horizontally scalable Prometheus in project scope.
* [ ] Coordinate with Thanos and Cortex maintainers and the CNCF regarding project boundaries, messaging, and any naming implications.
* [ ] Submit the Prometheus.rs SIG charter PR under `prometheus/governance/sigs/` once [PROM-115](https://github.com/prometheus/proposals/pull/115) is merged, documenting monolith-priority rules, repository scope, leads, and Steering Committee liaison.
* [ ] Configure repository teams, `MAINTAINERS.md` per [PROM-95](https://github.com/prometheus/proposals/blob/main/proposals/0095-teams-and-org-permissions.md), crate dependency checks, and monolith benchmark gates before accepting distributed component code.
